//
//  ContentView.swift
//  AppleLocalizationSwitcher
//
//  Created by Kiryl Shcherba on 31/05/2026.
//

import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        Text("Current: \(controller.currentSourceName)")
        Text(controller.statusText)
        Text("Accessibility: \(controller.accessibilityTrusted ? "Granted" : "Required")")
        Text("Input Monitoring: \(controller.inputMonitoringPermission.rawValue)")
        Text("CGEvent: \(controller.tapInstalled ? "Active" : "Inactive")")
        Text("IOHID: \(controller.hidMonitorInstalled ? "Active" : "Inactive")")
        Text("Last Trigger: \(controller.lastTriggerSource)")
        Text("Last Target: \(controller.lastTargetName)")
        Text("Last Error: \(controller.lastError)")

        Divider()

        Button {
            controller.switchToNextInputSource()
        } label: {
            Label("Switch Now", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!controller.canSwitch)

        Toggle(isOn: Binding(
            get: { controller.isSwitcherEnabled },
            set: { controller.setSwitcherEnabled($0) }
        )) {
            Label("Enable Fn Switcher", systemImage: "keyboard")
        }

        Toggle(isOn: Binding(
            get: { controller.launchAtLoginEnabled },
            set: { controller.setLaunchAtLoginEnabled($0) }
        )) {
            Label("Launch at Login", systemImage: "power")
        }

        Divider()

        Button {
            controller.refreshInputSources()
        } label: {
            Label("Refresh Input Sources", systemImage: "arrow.clockwise")
        }

        Button {
            controller.requestAccessibilityPermission()
        } label: {
            Label("Open Accessibility Settings", systemImage: "accessibility")
        }

        Button {
            controller.requestInputMonitoringPermission()
        } label: {
            Label("Open Input Monitoring Settings", systemImage: "keyboard.badge.eye")
        }

        Button {
            controller.copyDiagnostics()
        } label: {
            Label("Copy Diagnostics", systemImage: "doc.on.doc")
        }

        Divider()

        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Quit", systemImage: "xmark.circle")
        }
    }
}
