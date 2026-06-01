//
//  GlobeKeyMonitor.swift
//  AppleLocalizationSwitcher
//
//  Created by Kiryl Shcherba on 01/06/2026.
//

import Foundation
import IOKit.hid
import IOKit.hidsystem

enum InputMonitoringPermission: String {
    case granted = "Granted"
    case denied = "Denied"
    case unknown = "Unknown"

    static var current: InputMonitoringPermission {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            return .granted
        case kIOHIDAccessTypeDenied:
            return .denied
        default:
            return .unknown
        }
    }
}

nonisolated final class GlobeKeyMonitor {
    private let onGlobePress: @MainActor (String) -> Void
    private var manager: IOHIDManager?
    private var isGlobeDown = false

    init(onGlobePress: @escaping @MainActor (String) -> Void) {
        self.onGlobePress = onGlobePress
    }

    var isRunning: Bool {
        manager != nil
    }

    @discardableResult
    func start() -> Bool {
        guard manager == nil else {
            return true
        }

        guard Self.hasInputMonitoringAccess else {
            return false
        }

        let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(hidManager, nil)
        IOHIDManagerSetInputValueMatchingMultiple(hidManager, Self.globeElementMatches as CFArray)
        IOHIDManagerRegisterInputValueCallback(hidManager, Self.inputValueCallback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let result = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return false
        }

        manager = hidManager
        return true
    }

    func stop() {
        guard let manager else {
            return
        }

        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        isGlobeDown = false
    }

    @discardableResult
    static func requestInputMonitoringAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    private static let inputValueCallback: IOHIDValueCallback = { context, _, _, value in
        guard let context else {
            return
        }

        let monitor = Unmanaged<GlobeKeyMonitor>.fromOpaque(context).takeUnretainedValue()
        monitor.handle(value: value)
    }

    private static var hasInputMonitoringAccess: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)

        guard Self.isGlobeElement(usagePage: usagePage, usage: usage) else {
            return
        }

        let isDown = IOHIDValueGetIntegerValue(value) != 0
        let detail = "usagePage=0x\(String(usagePage, radix: 16)) usage=0x\(String(usage, radix: 16)) value=\(IOHIDValueGetIntegerValue(value))"

        if isDown {
            guard !isGlobeDown else {
                return
            }

            isGlobeDown = true
            Task { @MainActor [onGlobePress, detail] in
                onGlobePress(detail)
            }
        } else {
            isGlobeDown = false
        }
    }

    private static func isGlobeElement(usagePage: UInt32, usage: UInt32) -> Bool {
        globeUsagePairs.contains { pair in
            pair.usagePage == usagePage && pair.usage == usage
        }
    }

    private static let globeUsagePairs: [(usagePage: UInt32, usage: UInt32)] = [
        (0xff, 0x03),
        (0xff00, 0x03)
    ]

    private static let globeElementMatches: [[String: Any]] = globeUsagePairs.map { pair in
        [
            kIOHIDElementUsagePageKey: pair.usagePage,
            kIOHIDElementUsageKey: pair.usage
        ]
    }
}
