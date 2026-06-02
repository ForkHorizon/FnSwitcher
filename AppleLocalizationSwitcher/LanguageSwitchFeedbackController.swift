//
//  LanguageSwitchFeedbackController.swift
//  AppleLocalizationSwitcher
//

import AppKit
import SwiftUI

struct LanguageSwitchFeedbackItem: Identifiable, Equatable {
    let id: String
    let name: String
}

struct LanguageSwitchFeedbackSnapshot: Equatable {
    private static let itemWidth: CGFloat = 36
    private static let itemSpacing: CGFloat = 2
    private static let horizontalPadding: CGFloat = 4
    private static let panelHeight: CGFloat = 40

    let sources: [LanguageSwitchFeedbackItem]
    let selectedSourceID: String

    var selectedSourceName: String {
        sources.first { $0.id == selectedSourceID }?.name ?? "Unknown"
    }

    var displayedSources: [LanguageSwitchFeedbackItem] {
        if sources.count <= 4 {
            return sources
        }

        guard let selectedIndex = sources.firstIndex(where: { $0.id == selectedSourceID }),
              selectedIndex >= 4 else {
            return Array(sources.prefix(4))
        }

        return Array(sources.prefix(3)) + [sources[selectedIndex]]
    }

    var panelSize: NSSize {
        let count = max(displayedSources.count, 1)
        let width = Self.horizontalPadding
            + CGFloat(count) * Self.itemWidth
            + CGFloat(max(count - 1, 0)) * Self.itemSpacing
        return NSSize(width: width, height: Self.panelHeight)
    }
}

@MainActor
final class LanguageSwitchFeedbackController {
    private enum PresentationState {
        case hidden
        case showing
        case visible
        case hiding
    }

    private static let visibleDuration: UInt64 = 900_000_000
    private static let fadeInDuration = 0.12
    private static let fadeOutDuration = 0.18

    private var state: PresentationState = .hidden
    private var panel: LanguageSwitchFeedbackPanel?
    private var hostingController: NSHostingController<LanguageSwitchFeedbackView>?
    private var contentModel: LanguageSwitchFeedbackContentModel?
    private var hideTask: Task<Void, Never>?
    private var animationTask: Task<Void, Never>?
    private var presentationToken: UInt64 = 0

    func show(inputSources: [KeyboardInputSource], selectedInputSource: KeyboardInputSource) {
        let snapshot = LanguageSwitchFeedbackSnapshot(
            sources: inputSources.map { LanguageSwitchFeedbackItem(id: $0.id, name: $0.name) },
            selectedSourceID: selectedInputSource.id
        )

        show(snapshot)
    }

    func close() {
        presentationToken &+= 1
        hideTask?.cancel()
        hideTask = nil
        animationTask?.cancel()
        animationTask = nil
        state = .hidden
        panel?.alphaValue = 0
        panel?.orderOut(nil)
    }

    private func show(_ snapshot: LanguageSwitchFeedbackSnapshot) {
        presentationToken &+= 1
        let token = presentationToken
        hideTask?.cancel()
        hideTask = nil
        animationTask?.cancel()
        animationTask = nil

        let model = resolvedContentModel(for: snapshot)
        let panel = resolvedPanel(with: model, size: snapshot.panelSize)
        model.snapshot = snapshot
        position(panel, size: snapshot.panelSize)

        switch state {
        case .hidden:
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            state = .showing
            animate(panel, to: 1, duration: Self.fadeInDuration, token: token) { [weak self] in
                guard let self, self.presentationToken == token else {
                    return
                }

                self.state = .visible
            }
        case .showing, .visible, .hiding:
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            state = .visible
        }

        scheduleHide(token: token)
    }

    private func resolvedContentModel(for snapshot: LanguageSwitchFeedbackSnapshot) -> LanguageSwitchFeedbackContentModel {
        if let contentModel {
            return contentModel
        }

        let contentModel = LanguageSwitchFeedbackContentModel(snapshot: snapshot)
        self.contentModel = contentModel
        return contentModel
    }

    private func resolvedPanel(
        with model: LanguageSwitchFeedbackContentModel,
        size: NSSize
    ) -> LanguageSwitchFeedbackPanel {
        if let panel {
            return panel
        }

        let panel = LanguageSwitchFeedbackPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.invalidateShadow()
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.alphaValue = 0

        let containerView = NSView(frame: NSRect(origin: .zero, size: size))
        containerView.autoresizingMask = [.width, .height]
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.layer?.allowsEdgeAntialiasing = false

        let hostingController = NSHostingController(rootView: LanguageSwitchFeedbackView(model: model))
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        hostingController.view.layer?.allowsEdgeAntialiasing = false

        containerView.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        panel.contentView = containerView
        self.hostingController = hostingController
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel, size: NSSize) {
        guard let screen = screenForPresentation() else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
    }

    private func screenForPresentation() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func scheduleHide(token: UInt64) {
        hideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.visibleDuration)
            } catch {
                return
            }

            guard let self, self.presentationToken == token else {
                return
            }

            self.hide(token: token)
        }
    }

    private func hide(token: UInt64) {
        guard presentationToken == token, let panel else {
            return
        }

        state = .hiding
        animate(panel, to: 0, duration: Self.fadeOutDuration, token: token) { [weak self] in
            guard let self, self.presentationToken == token else {
                return
            }

            panel.orderOut(nil)
            self.state = .hidden
        }
    }

    private func animate(
        _ panel: NSPanel,
        to alphaValue: CGFloat,
        duration: TimeInterval,
        token: UInt64,
        completion: @escaping @MainActor () -> Void
    ) {
        animationTask?.cancel()
        let startAlpha = panel.alphaValue

        animationTask = Task { @MainActor [weak self, weak panel] in
            let startTime = ProcessInfo.processInfo.systemUptime

            while !Task.isCancelled {
                guard let self, let panel, self.presentationToken == token else {
                    return
                }

                let elapsed = ProcessInfo.processInfo.systemUptime - startTime
                let progress = min(max(elapsed / duration, 0), 1)
                let easedProgress = progress * progress * (3 - 2 * progress)
                panel.alphaValue = startAlpha + (alphaValue - startAlpha) * easedProgress

                if progress >= 1 {
                    break
                }

                do {
                    try await Task.sleep(nanoseconds: 16_000_000)
                } catch {
                    return
                }
            }

            guard let self, let panel, self.presentationToken == token else {
                return
            }

            panel.alphaValue = alphaValue
            self.animationTask = nil
            completion()
        }
    }
}

private final class LanguageSwitchFeedbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
