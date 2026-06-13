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

private enum InputSourceApplyReason {
    case userSwitch
    case languagePersistenceRestore
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
    @Published var isLanguagePersistenceEnabled: Bool
    @Published private(set) var languagePersistenceApplications: [LanguagePersistenceApplication] = []
    @Published private(set) var focusedApplicationName = "Global Default"
    @Published private(set) var globalDefaultSourceName = "Not Set"

    private let inputSourceService = InputSourceService()
    private let languagePersistenceStore: LanguagePersistenceStore
    private let languageSwitchFeedbackController = LanguageSwitchFeedbackController()
    private lazy var eventTap = FnEventTap(
        onFnPress: { [weak self] detail in
            self?.handleGlobeKeyPress(from: .cgEvent, detail: detail)
        },
        onTypingAfterSwitch: { [weak self] detail in
            self?.handleTypingAfterSwitch(detail: detail)
        }
    )
    private lazy var globeKeyMonitor = GlobeKeyMonitor { [weak self] detail in
        self?.handleGlobeKeyPress(from: .ioHID, detail: detail)
    }
    private var permissionTimer: Timer?
    private var launchPermissionRequestTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []
    private var workspaceNotificationTokens: [NSObjectProtocol] = []
    private var pendingCGFallbackTask: Task<Void, Never>?
    private var reapplyTasks: [Task<Void, Never>] = []
    private var pendingUserSwitchRetryCount = 0
    private var inputSourceSuppressionTasks: [Task<Void, Never>] = []
    private var inputSourceNotificationSuppressions: [String: Int] = [:]
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

    var needsKeyboardPermissions: Bool {
        !accessibilityTrusted || inputMonitoringPermission != .granted
    }

    var statusText: String {
        if needsKeyboardPermissions {
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
        FnSwitcher Diagnostics
        Current Source: \(currentSourceName)
        Enabled Sources: \(inputSources.map(\.name).joined(separator: ", "))
        Fn Switcher Enabled: \(isSwitcherEnabled)
        Accessibility: \(accessibilityTrusted ? "Granted" : "Missing")
        Input Monitoring: \(inputMonitoringPermission.rawValue)
        CGEvent Monitor: \(tapInstalled ? "Active" : "Inactive")
        IOHID Monitor: \(hidMonitorInstalled ? "Active" : "Inactive")
        Language Persistence: \(isLanguagePersistenceEnabled ? "Enabled" : "Disabled")
        Focused App Context: \(focusedApplicationName)
        Global Default Source: \(globalDefaultSourceName)
        Last Trigger: \(lastTriggerSource)
        Last Target: \(lastTargetName)
        Last Error: \(lastError)
        Recent Events:
        \(diagnostics.suffix(20).joined(separator: "\n"))
        """
    }

    init() {
        let languagePersistenceStore = LanguagePersistenceStore()
        self.languagePersistenceStore = languagePersistenceStore
        isSwitcherEnabled = UserDefaults.standard.object(forKey: DefaultsKey.switcherEnabled) as? Bool ?? true
        isLanguagePersistenceEnabled = languagePersistenceStore.isEnabled
        refreshAccessibilityTrust()
        refreshInputMonitoringPermission()
        refreshInputSources()
        refreshLaunchAtLoginStatus()
        refreshLanguagePersistenceApplications()
        refreshFocusedApplicationForLanguagePersistence(applyLayout: false)
        observeInputSourceChanges()
        observeApplicationChanges()
        startPermissionPolling()
        configureMonitors()
        requestMissingKeyboardPermissionsOnLaunch()
    }

    @MainActor
    deinit {
        eventTap.stop()
        globeKeyMonitor.stop()
        launchPermissionRequestTask?.cancel()
        pendingCGFallbackTask?.cancel()
        reapplyTasks.forEach { $0.cancel() }
        pendingUserSwitchRetryCount = 0
        inputSourceSuppressionTasks.forEach { $0.cancel() }
        languageSwitchFeedbackController.close()
        permissionTimer?.invalidate()
        notificationTokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        workspaceNotificationTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    func setSwitcherEnabled(_ enabled: Bool) {
        isSwitcherEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.switcherEnabled)

        if enabled && needsKeyboardPermissions {
            requestKeyboardPermissions(openSettings: true, reason: "switcher enabled")
        } else {
            configureMonitors()
        }
    }

    func setLanguagePersistenceEnabled(_ enabled: Bool) {
        languagePersistenceStore.setEnabled(enabled)
        isLanguagePersistenceEnabled = enabled

        if let currentInputSourceID = currentInputSource?.id {
            languagePersistenceStore.initializeGlobalDefaultIfNeeded(currentInputSourceID: currentInputSourceID)
        }

        publishLanguagePersistenceState()

        if enabled {
            lastActionMessage = "Language persistence enabled"
            restoreLanguageLayoutForCurrentFocus(reason: "language persistence enabled")
        } else {
            cancelPendingLanguageRestores()
            lastActionMessage = "Language persistence disabled"
        }
    }

    func setRememberLanguageLayout(for bundleIdentifier: String, enabled: Bool) {
        languagePersistenceStore.setRememberLayout(for: bundleIdentifier, enabled: enabled)

        if languagePersistenceStore.focusedApplication?.bundleIdentifier == bundleIdentifier,
           let currentInputSourceID = currentInputSource?.id {
            languagePersistenceStore.recordSelectedInputSourceID(currentInputSourceID)
        }

        publishLanguagePersistenceState()

        if languagePersistenceStore.isEnabled {
            restoreLanguageLayoutForCurrentFocus(reason: "per-app setting changed")
        }
    }

    func refreshLanguagePersistenceApplications() {
        languagePersistenceStore.refreshRunningApplications(
            NSWorkspace.shared.runningApplications,
            ownBundleIdentifier: Bundle.main.bundleIdentifier
        )
        publishLanguagePersistenceState()
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
        accessibilityTrusted = requestAccessibilityPrompt()
        openAccessibilitySettings()
        refreshAccessibilityTrust()
        configureMonitors()
    }

    func requestInputMonitoringPermission() {
        _ = requestInputMonitoringPrompt()
        openInputMonitoringSettings()
        refreshInputMonitoringPermission()
        configureMonitors()
    }

    func requestKeyboardPermissions() {
        requestKeyboardPermissions(openSettings: true, reason: "menu action")
    }

    func refreshInputSources() {
        inputSources = inputSourceService.enabledSelectableKeyboardInputSources()
        languagePersistenceStore.updateInputSources(inputSources)
        refreshCurrentInputSource()

        if let currentInputSourceID = currentInputSource?.id {
            languagePersistenceStore.initializeGlobalDefaultIfNeeded(currentInputSourceID: currentInputSourceID)
        }

        publishLanguagePersistenceState()
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

    private func handleTypingAfterSwitch(detail: String) {
        guard pendingUserSwitchRetryCount > 0 else {
            return
        }

        reapplyTasks.forEach { $0.cancel() }
        reapplyTasks.removeAll()
        pendingUserSwitchRetryCount = 0
        appendDiagnostic("Cancelled pending switch retries after typing: \(detail)")
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
        cancelPendingLanguageRestores()
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
        pendingUserSwitchRetryCount = 0

        lastTriggerSource = trigger.rawValue
        lastTargetName = nextSource.name
        lastError = "None"
        appendDiagnostic("Switch target=\(nextSource.name) trigger=\(trigger.rawValue) detail=\(detail)")

        apply(
            target: nextSource,
            phase: "initial",
            generation: generation,
            reason: .userSwitch,
            showsFeedback: true
        )

        let retryDelays = [0.08, 0.18, 0.35]
        pendingUserSwitchRetryCount = retryDelays.count

        for delay in retryDelays {
            let task = Task { @MainActor [weak self, nextSource] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }

                guard let self, self.switchGeneration == generation else {
                    return
                }

                self.pendingUserSwitchRetryCount = max(0, self.pendingUserSwitchRetryCount - 1)
                self.reapplyUserSwitchIfNeeded(
                    target: nextSource,
                    phase: "\(Int(delay * 1000))ms reapply",
                    generation: generation
                )
            }
            reapplyTasks.append(task)
        }

        configureMonitors()
    }

    private func reapplyUserSwitchIfNeeded(
        target: KeyboardInputSource,
        phase: String,
        generation: Int
    ) {
        guard generation == switchGeneration else {
            return
        }

        refreshCurrentInputSource()

        guard currentInputSource?.id != target.id else {
            appendDiagnostic("\(phase): skipped reapply; \(target.name) already active")
            return
        }

        apply(
            target: target,
            phase: phase,
            generation: generation,
            reason: .userSwitch,
            showsFeedback: false
        )
    }

    private func apply(
        target: KeyboardInputSource,
        phase: String,
        generation: Int,
        reason: InputSourceApplyReason,
        showsFeedback: Bool
    ) {
        guard generation == switchGeneration else {
            return
        }

        if reason == .languagePersistenceRestore {
            suppressNextInputSourceChangeNotification(for: target.id)
        }

        let status = inputSourceService.select(target)

        if status == noErr {
            currentInputSource = target

            switch reason {
            case .userSwitch:
                languagePersistenceStore.recordSelectedInputSourceID(target.id)
                publishLanguagePersistenceState()
                lastActionMessage = "Switched to \(target.name)"
                if showsFeedback {
                    languageSwitchFeedbackController.show(inputSources: inputSources, selectedInputSource: target)
                }
            case .languagePersistenceRestore:
                lastActionMessage = "Applied \(target.name) for \(focusedApplicationName)"
            }

            appendDiagnostic("\(phase): selected \(target.name)")
        } else {
            if reason == .languagePersistenceRestore {
                consumeSuppressedInputSourceChangeNotification(for: target.id)
            }

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

    private func requestMissingKeyboardPermissionsOnLaunch() {
        launchPermissionRequestTask?.cancel()
        launchPermissionRequestTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }

            guard let self, self.isSwitcherEnabled, self.canSwitch, self.needsKeyboardPermissions else {
                return
            }

            self.requestKeyboardPermissions(openSettings: false, reason: "launch")
        }
    }

    private func requestKeyboardPermissions(openSettings: Bool, reason: String) {
        refreshAccessibilityTrust()
        refreshInputMonitoringPermission()

        guard needsKeyboardPermissions else {
            lastActionMessage = "Keyboard permissions granted"
            appendDiagnostic("Keyboard permission request skipped: already granted")
            configureMonitors()
            return
        }

        let needsAccessibility = !accessibilityTrusted
        let needsInputMonitoring = inputMonitoringPermission != .granted
        appendDiagnostic("Requesting keyboard permissions reason=\(reason) accessibility=\(needsAccessibility) inputMonitoring=\(needsInputMonitoring)")

        if needsAccessibility {
            accessibilityTrusted = requestAccessibilityPrompt()
        }

        if needsInputMonitoring {
            _ = requestInputMonitoringPrompt()
        }

        refreshAccessibilityTrust()
        refreshInputMonitoringPermission()

        if openSettings && needsKeyboardPermissions {
            openFirstMissingPermissionSettings()
        }

        lastActionMessage = needsKeyboardPermissions ? "Grant keyboard permissions in System Settings" : "Keyboard permissions granted"
        configureMonitors()
    }

    @discardableResult
    private func requestAccessibilityPrompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    private func requestInputMonitoringPrompt() -> Bool {
        GlobeKeyMonitor.requestInputMonitoringAccess()
    }

    private func openFirstMissingPermissionSettings() {
        if !accessibilityTrusted {
            openAccessibilitySettings()
        } else if inputMonitoringPermission != .granted {
            openInputMonitoringSettings()
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
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
                self?.handleSelectedInputSourceChanged()
            }
        })

        notificationTokens.append(center.addObserver(forName: enabledName, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshInputSources()
            }
        })
    }

    private func observeApplicationChanges() {
        let center = NSWorkspace.shared.notificationCenter

        workspaceNotificationTokens.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self, application] in
                self?.handleActivatedApplication(application)
            }
        })

        workspaceNotificationTokens.append(center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 80_000_000)
                } catch {
                    return
                }

                guard NSWorkspace.shared.frontmostApplication == nil else {
                    return
                }

                self?.languagePersistenceStore.focus(application: nil, ownBundleIdentifier: Bundle.main.bundleIdentifier)
                self?.publishLanguagePersistenceState()
                self?.restoreLanguageLayoutForCurrentFocus(reason: "no focused app")
            }
        })

        workspaceNotificationTokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLanguagePersistenceApplications()
                self?.refreshFocusedApplicationForLanguagePersistence(applyLayout: true)
            }
        })
    }

    private func handleSelectedInputSourceChanged() {
        refreshCurrentInputSource()

        guard let currentInputSourceID = currentInputSource?.id else {
            publishLanguagePersistenceState()
            return
        }

        if consumeSuppressedInputSourceChangeNotification(for: currentInputSourceID) {
            appendDiagnostic("Ignored persistence restore input-source notification for \(currentInputSourceID)")
            publishLanguagePersistenceState()
            return
        }

        languagePersistenceStore.recordSelectedInputSourceID(currentInputSourceID)
        publishLanguagePersistenceState()
    }

    private func handleActivatedApplication(_ application: NSRunningApplication?) {
        languagePersistenceStore.focus(application: application, ownBundleIdentifier: Bundle.main.bundleIdentifier)
        refreshLanguagePersistenceApplications()
        publishLanguagePersistenceState()
        restoreLanguageLayoutForCurrentFocus(reason: "app activated")
    }

    private func refreshFocusedApplicationForLanguagePersistence(applyLayout: Bool) {
        languagePersistenceStore.focus(
            application: NSWorkspace.shared.frontmostApplication,
            ownBundleIdentifier: Bundle.main.bundleIdentifier
        )
        publishLanguagePersistenceState()

        if applyLayout {
            restoreLanguageLayoutForCurrentFocus(reason: "focused app refreshed")
        }
    }

    private func restoreLanguageLayoutForCurrentFocus(reason: String) {
        guard languagePersistenceStore.isEnabled else {
            return
        }

        refreshCurrentInputSource()

        guard let targetInputSourceID = languagePersistenceStore.targetInputSourceID(currentInputSourceID: currentInputSource?.id),
              let targetInputSource = inputSources.first(where: { $0.id == targetInputSourceID }) else {
            publishLanguagePersistenceState()
            return
        }

        guard currentInputSource?.id != targetInputSource.id else {
            appendDiagnostic("Persistence restore skipped: already using \(targetInputSource.name) for \(focusedApplicationName)")
            publishLanguagePersistenceState()
            return
        }

        cancelPendingLanguageRestores()
        switchGeneration += 1
        let generation = switchGeneration

        lastTriggerSource = "App Focus"
        lastTargetName = targetInputSource.name
        lastError = "None"
        appendDiagnostic("Persistence restore target=\(targetInputSource.name) context=\(focusedApplicationName) reason=\(reason)")

        apply(
            target: targetInputSource,
            phase: "persistence restore",
            generation: generation,
            reason: .languagePersistenceRestore,
            showsFeedback: false
        )
    }

    private func publishLanguagePersistenceState() {
        isLanguagePersistenceEnabled = languagePersistenceStore.isEnabled
        languagePersistenceApplications = languagePersistenceStore.applications
        focusedApplicationName = languagePersistenceStore.focusedApplicationName
        globalDefaultSourceName = languagePersistenceStore.globalDefaultInputSourceName
    }

    private func cancelPendingLanguageRestores() {
        reapplyTasks.forEach { $0.cancel() }
        reapplyTasks.removeAll()
        pendingUserSwitchRetryCount = 0
    }

    private func suppressNextInputSourceChangeNotification(for inputSourceID: String) {
        inputSourceNotificationSuppressions[inputSourceID, default: 0] += 1

        let task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 700_000_000)
            } catch {
                return
            }

            _ = self?.consumeSuppressedInputSourceChangeNotification(for: inputSourceID)
        }

        inputSourceSuppressionTasks.append(task)
    }

    @discardableResult
    private func consumeSuppressedInputSourceChangeNotification(for inputSourceID: String) -> Bool {
        guard let count = inputSourceNotificationSuppressions[inputSourceID], count > 0 else {
            return false
        }

        if count == 1 {
            inputSourceNotificationSuppressions[inputSourceID] = nil
        } else {
            inputSourceNotificationSuppressions[inputSourceID] = count - 1
        }

        return true
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
