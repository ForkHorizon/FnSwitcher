//
//  FnEventTap.swift
//  AppleLocalizationSwitcher
//
//  Created by Kiryl Shcherba on 31/05/2026.
//

import Carbon.HIToolbox
import CoreGraphics
import Foundation

nonisolated final class FnEventTap {
    private let onFnPress: @MainActor (String) -> Void
    private let onTypingAfterSwitch: @MainActor (String) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnIsDown = false
    private var handledCurrentFnPress = false
    private var typingAfterSwitchDeadline: TimeInterval?

    init(
        onFnPress: @escaping @MainActor (String) -> Void,
        onTypingAfterSwitch: @escaping @MainActor (String) -> Void
    ) {
        self.onFnPress = onFnPress
        self.onTypingAfterSwitch = onTypingAfterSwitch
    }

    var isRunning: Bool {
        eventTap != nil
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else {
            return true
        }

        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) |
            CGEventMask(1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: userInfo
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        eventTap = nil
        runLoopSource = nil
        fnIsDown = false
        handledCurrentFnPress = false
        typingAfterSwitchDeadline = nil
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let eventTap = Unmanaged<FnEventTap>.fromOpaque(userInfo).takeUnretainedValue()
        return eventTap.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }

            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            handleKeyDown(event)
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        guard keyCode == CGKeyCode(kVK_Function) else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let fnDown = flags.contains(.maskSecondaryFn)
        let hasOtherModifier = !flags.intersection(Self.nonFnModifierFlags).isEmpty

        if fnDown {
            let firstFnDownEvent = !fnIsDown
            fnIsDown = true

            if firstFnDownEvent && !hasOtherModifier {
                handledCurrentFnPress = true
                typingAfterSwitchDeadline = ProcessInfo.processInfo.systemUptime + Self.typingAfterSwitchWatchInterval
                let detail = "keyCode=\(keyCode) flags=\(flags.rawValue)"
                Task { @MainActor [onFnPress, detail] in
                    onFnPress(detail)
                }
            }

            return handledCurrentFnPress ? nil : Unmanaged.passUnretained(event)
        }

        let shouldSuppressRelease = handledCurrentFnPress
        fnIsDown = false
        handledCurrentFnPress = false

        return shouldSuppressRelease ? nil : Unmanaged.passUnretained(event)
    }

    private func handleKeyDown(_ event: CGEvent) {
        guard let deadline = typingAfterSwitchDeadline else {
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now <= deadline else {
            typingAfterSwitchDeadline = nil
            return
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode != CGKeyCode(kVK_Function) else {
            return
        }

        typingAfterSwitchDeadline = nil
        let flags = event.flags
        let detail = "keyCode=\(keyCode) flags=\(flags.rawValue)"
        Task { @MainActor [onTypingAfterSwitch, detail] in
            onTypingAfterSwitch(detail)
        }
    }

    private static let typingAfterSwitchWatchInterval: TimeInterval = 0.40

    private static let nonFnModifierFlags: CGEventFlags = [
        .maskAlphaShift,
        .maskShift,
        .maskControl,
        .maskAlternate,
        .maskCommand,
        .maskHelp
    ]
}
