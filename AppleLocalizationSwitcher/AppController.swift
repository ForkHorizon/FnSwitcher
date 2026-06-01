//
//  AppController.swift
//  AppleLocalizationSwitcher
//
//  Created by Kiryl Shcherba on 31/05/2026.
//

import ApplicationServices
import AppKit
import Carbon
import Combine
import Foundation
import ServiceManagement

enum GlobeKeyEventSource: String {
    case cgEvent = "CGEvent"
    case ioHID = "IOHID"
    case menu = "Menu"
}

@MainActor
final class AppController: ObservableObject {
    @Published private(set) var inputSources: [KeyboardInputSource] = []
    @Published private(set) var currentInputSource: KeyboardInputSource?
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var inputMonitoringPermission: InputMonitoringPermission = .unknown
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var tapInstalled = false
    @Published private(set) var hidMonitorInstalled = false
    @Published private(set) var lastTriggerSource = "None"
    @Published private(set) var lastTargetName = "None"
    @Published private(set) var lastError = "None"
    @Published private(set) var diagnostics: [String] = []
    @Published var isSwitcherEnabled: Bool

    private let inputSourceService = InputSourceService()
    private lazy var eventTap = FnEventTap { [weak self] detail in
        self?.handleGlobeKeyPress(from: .cgEvent, detail: detail)
    }
    private lazy var globeKeyMonitor = GlobeKeyMonitor { [weak self] detail in
        self?.handleGlobeKeyPress(from: .ioHID, detail: detail)
    }
    private var permissionTimer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var pendingCGFallbackTask: Task<Void, Never>?
    private var reapplyTasks: [Task<Void, Never>] = []
    private var lastCommittedGlobePressTime: TimeInterval = 0
    private var lastCommittedGlobePressSource: GlobeKeyEventSource?
    private var switchGeneration = 0
    private var lastActionMessage = "Ready"

    var currentSourceName: String {
        currentInputSource?.name ?? "Unknown"
    }

    var canSwitch: Bool {
        inputSources.count >= 2
    }

    var statusText: String {
        if !accessibilityTrusted {
            if inputMonitoringPermission == .granted {
                return lastActionMessage
            }

            return "Keyboard permissions required"
        }

        if !canSwitch {
            return "Enable at least two input sources"
        }

        if !isSwitcherEnabled {
            return "Fn switcher is off"
        }

        if !tapInstalled && !hidMonitorInstalled {
            return "No keyboard monitor is active"
        }

        return lastActionMessage
    }

    var diagnosticsText: String {
        """
        AppleLocalizationSwitcher Diagnostics
        Current Source: \(currentSourceName)
        Enabled Sources: \(inputSources.map(\.name).joined(separator: ", "))
        Fn Switcher Enabled: \(isSwitcherEnabled)
        Accessibility: \(accessibilityTrusted ? "Granted" : "Missing")
        Input Monitoring: \(inputMonitoringPermission.rawValue)
        CGEvent Monitor: \(tapInstalled ? "Active" : "Inactive")
        IOHID Monitor: \(hidMonitorInstalled ? "Active" : "Inactive")
        Last Trigger: \(lastTriggerSource)
        Last Target: \(lastTargetName)
        Last Error: \(lastError)
        Recent Events:
        \(diagnostics.suffix(20).joined(separator: "\n"))
        """
    }

    init() {
        isSwitcherEnabled = UserDefaults.standard.object(forKey: DefaultsKey.switcherEnabled) as? Bool ?? true
        refreshAccessibilityTrust()
        refreshInputMonitoringPermission()
        refreshInputSources()
        refreshLaunchAtLoginStatus()
        observeInputSourceChanges()
        startPermissionPolling()
        configureMonitors()
    }

    @MainActor
    deinit {
        eventTap.stop()
        globeKeyMonitor.stop()
        pendingCGFallbackTask?.cancel()
        reapplyTasks.forEach { $0.cancel() }
        permissionTimer?.invalidate()
        notificationTokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }

    func setSwitcherEnabled(_ enabled: Bool) {
        isSwitcherEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.switcherEnabled)

        if enabled && !accessibilityTrusted && inputMonitoringPermission != .granted {
            requestAccessibilityPermission()
        }

        configureMonitors()
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                lastActionMessage = "Launch at login enabled"
            } else {
                try SMAppService.mainApp.unregister()
                lastActionMessage = "Launch at login disabled"
            }
        } catch {
            lastActionMessage = "Launch at login failed: \(error.localizedDescription)"
        }

        refreshLaunchAtLoginStatus()
    }

    func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }

        configureMonitors()
    }

    func requestInputMonitoringPermission() {
        _ = GlobeKeyMonitor.requestInputMonitoringAccess()

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }

        refreshInputMonitoringPermission()
        configureMonitors()
    }

    func refreshInputSources() {
        inputSources = inputSourceService.enabledSelectableKeyboardInputSources()
        refreshCurrentInputSource()
        configureMonitors()
    }

    func switchToNextInputSource() {
        performCoordinatedSwitch(trigger: .menu, detail: "manual menu action")
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsText, forType: .string)
        lastActionMessage = "Diagnostics copied"
    }

    private func handleGlobeKeyPress(from source: GlobeKeyEventSource, detail: String) {
        appendDiagnostic("\(source.rawValue) press: \(detail)")

        if source == .cgEvent && hidMonitorInstalled {
            pendingCGFallbackTask?.cancel()
            pendingCGFallbackTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }

                self?.commitGlobeKeyPress(from: .cgEvent, detail: "delayed fallback after IOHID wait")
            }
            return
        }

        if source == .ioHID {
            pendingCGFallbackTask?.cancel()
            pendingCGFallbackTask = nil
        }

        commitGlobeKeyPress(from: source, detail: detail)
    }

    private func commitGlobeKeyPress(from source: GlobeKeyEventSource, detail: String) {
        let now = ProcessInfo.processInfo.systemUptime
        let isCrossMonitorDuplicate = lastCommittedGlobePressSource != source && now - lastCommittedGlobePressTime < 0.12
        guard !isCrossMonitorDuplicate else {
            appendDiagnostic("Ignored duplicate \(source.rawValue) press: \(detail)")
            return
        }

        lastCommittedGlobePressTime = now
        lastCommittedGlobePressSource = source
        performCoordinatedSwitch(trigger: source, detail: detail)
    }

    private func performCoordinatedSwitch(trigger: GlobeKeyEventSource, detail: String) {
        refreshCurrentInputSource()

        guard inputSources.count >= 2 else {
            lastActionMessage = "Enable at least two input sources"
            lastError = lastActionMessage
            configureMonitors()
            return
        }

        let currentID = currentInputSource?.id
        let nextIndex: Int

        if let currentID, let currentIndex = inputSources.firstIndex(where: { $0.id == currentID }) {
            nextIndex = inputSources.index(after: currentIndex) == inputSources.endIndex ? inputSources.startIndex : inputSources.index(after: currentIndex)
        } else {
            nextIndex = inputSources.startIndex
        }

        let nextSource = inputSources[nextIndex]
        switchGeneration += 1
        let generation = switchGeneration
        reapplyTasks.forEach { $0.cancel() }
        reapplyTasks.removeAll()

        lastTriggerSource = trigger.rawValue
        lastTargetName = nextSource.name
        lastError = "None"
        appendDiagnostic("Switch target=\(nextSource.name) trigger=\(trigger.rawValue) detail=\(detail)")

        apply(target: nextSource, phase: "initial", generation: generation)

        for delay in [0.08, 0.18, 0.35] {
            let task = Task { @MainActor [weak self, nextSource] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }

                guard self?.switchGeneration == generation else {
                    return
                }

                self?.apply(target: nextSource, phase: "\(Int(delay * 1000))ms reapply", generation: generation)
            }
            reapplyTasks.append(task)
        }

        configureMonitors()
    }

    private func apply(target: KeyboardInputSource, phase: String, generation: Int) {
        guard generation == switchGeneration else {
            return
        }

        let status = inputSourceService.select(target)

        if status == noErr {
            currentInputSource = target
            lastActionMessage = "Switched to \(target.name)"
            appendDiagnostic("\(phase): selected \(target.name)")
        } else {
            lastError = "Switch failed (\(status))"
            lastActionMessage = lastError
            appendDiagnostic("\(phase): \(lastError)")
        }
    }

    private func refreshCurrentInputSource() {
        guard let currentID = inputSourceService.currentKeyboardInputSourceID() else {
            currentInputSource = nil
            return
        }

        currentInputSource = inputSources.first { $0.id == currentID }
    }

    private func refreshAccessibilityTrust() {
        let trusted = AXIsProcessTrusted()

        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
            configureMonitors()
        } else {
            accessibilityTrusted = trusted
        }
    }

    private func refreshInputMonitoringPermission() {
        let permission = InputMonitoringPermission.current

        if permission != inputMonitoringPermission {
            inputMonitoringPermission = permission
            configureMonitors()
        } else {
            inputMonitoringPermission = permission
        }
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    private func configureMonitors() {
        guard isSwitcherEnabled, canSwitch else {
            eventTap.stop()
            globeKeyMonitor.stop()
            tapInstalled = false
            hidMonitorInstalled = false
            return
        }

        if accessibilityTrusted {
            tapInstalled = eventTap.start()
        } else {
            eventTap.stop()
            tapInstalled = false
        }

        if inputMonitoringPermission == .granted {
            hidMonitorInstalled = globeKeyMonitor.start()
        } else {
            globeKeyMonitor.stop()
            hidMonitorInstalled = false
        }

        if (tapInstalled || hidMonitorInstalled), lastActionMessage == "Ready" {
            lastActionMessage = "Fn switcher ready"
        } else if !tapInstalled && !hidMonitorInstalled {
            lastActionMessage = "Could not install keyboard monitors"
        }
    }

    private func observeInputSourceChanges() {
        let center = DistributedNotificationCenter.default()
        let selectedName = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        let enabledName = Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String)

        notificationTokens.append(center.addObserver(forName: selectedName, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshCurrentInputSource()
            }
        })

        notificationTokens.append(center.addObserver(forName: enabledName, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshInputSources()
            }
        })
    }

    private func startPermissionPolling() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAccessibilityTrust()
                self?.refreshInputMonitoringPermission()
            }
        }
    }

    private func appendDiagnostic(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        diagnostics.append("[\(timestamp)] \(message)")

        if diagnostics.count > 80 {
            diagnostics.removeFirst(diagnostics.count - 80)
        }
    }
}

private enum DefaultsKey {
    static let switcherEnabled = "switcherEnabled"
}
