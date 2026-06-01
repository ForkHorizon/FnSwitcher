//
//  AppleLocalizationSwitcherApp.swift
//  AppleLocalizationSwitcher
//
//  Created by Kiryl Shcherba on 31/05/2026.
//

import Darwin
import SwiftUI

@main
struct AppleLocalizationSwitcherApp: App {
    @StateObject private var controller: AppController

    init() {
        if Self.hasExistingInstance() || !SingleInstanceGuard.acquire() {
            exit(0)
        }

        _controller = StateObject(wrappedValue: AppController())
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(controller)
        } label: {
            Image(systemName: "globe")
        }
        .menuBarExtraStyle(.menu)
    }

    private static func hasExistingInstance() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }

        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.contains { application in
            application.bundleIdentifier == bundleIdentifier &&
                application.processIdentifier != currentProcessIdentifier &&
                !application.isTerminated
        }
    }

}

private enum SingleInstanceGuard {
    private static var lockFileDescriptor: Int32 = -1

    static func acquire() -> Bool {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "AppleLocalizationSwitcher"
        let lockPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(bundleIdentifier).lock")
        let fileDescriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)

        guard fileDescriptor >= 0 else {
            return true
        }

        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(fileDescriptor)
            return false
        }

        lockFileDescriptor = fileDescriptor
        return true
    }
}
