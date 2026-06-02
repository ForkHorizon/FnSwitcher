//
//  LanguageSwitchFeedbackView.swift
//  AppleLocalizationSwitcher
//

import Combine
import SwiftUI

@MainActor
final class LanguageSwitchFeedbackContentModel: ObservableObject {
    @Published var snapshot: LanguageSwitchFeedbackSnapshot

    init(snapshot: LanguageSwitchFeedbackSnapshot) {
        self.snapshot = snapshot
    }
}

struct LanguageSwitchFeedbackView: View {
    private static let itemWidth: CGFloat = 36
    private static let itemHeight: CGFloat = 36
    private static let containerHeight: CGFloat = 40
    private static let itemCornerRadius: CGFloat = 20
    private static let activeBackground = Color(red: 0.05, green: 0.05, blue: 0.05)
    private static let inactiveBackground = Color.white

    @ObservedObject var model: LanguageSwitchFeedbackContentModel

    var body: some View {
        let snapshot = model.snapshot

        HStack(spacing: 2) {
            ForEach(snapshot.displayedSources) { source in
                sourceChip(source, selectedSourceID: snapshot.selectedSourceID)
            }
        }
        .padding(2)
        .frame(width: snapshot.panelSize.width, height: Self.containerHeight)
        .background(Self.inactiveBackground)
        .clipShape(Capsule(), style: FillStyle(eoFill: false, antialiased: false))
        .frame(width: snapshot.panelSize.width, height: snapshot.panelSize.height)
        .animation(.smooth(duration: 0.16), value: snapshot)
    }

    private func sourceChip(_ source: LanguageSwitchFeedbackItem, selectedSourceID: String) -> some View {
        let isSelected = source.id == selectedSourceID

        return Text(shortLanguageCode(for: source))
            .font(.system(size: 12, weight: .black, design: .monospaced))
            .foregroundStyle(isSelected ? Color.white : Self.activeBackground)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: Self.itemWidth, height: Self.itemHeight)
            .background(isSelected ? Self.activeBackground : Self.inactiveBackground)
            .clipShape(RoundedRectangle(cornerRadius: Self.itemCornerRadius, style: .continuous))
            .accessibilityLabel(source.name)
    }

    private func shortLanguageCode(for source: LanguageSwitchFeedbackItem) -> String {
        let searchableText = "\(source.name) \(source.id)"
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        let knownCodes: [(token: String, code: String)] = [
            ("russian", "Ru"),
            ("russk", "Ru"),
            ("spanish", "Es"),
            ("espan", "Es"),
            ("abc", "En"),
            ("u.s", "En"),
            (" us", "En"),
            ("english", "En"),
            ("british", "En"),
            ("ukrainian", "Uk"),
            ("french", "Fr"),
            ("german", "De"),
            ("italian", "It"),
            ("portuguese", "Pt"),
            ("polish", "Pl"),
            ("turkish", "Tr"),
            ("hebrew", "He"),
            ("arabic", "Ar"),
            ("chinese", "Zh"),
            ("pinyin", "Zh"),
            ("japanese", "Ja"),
            ("korean", "Ko")
        ]

        if let code = knownCodes.first(where: { searchableText.contains($0.token) })?.code {
            return code
        }

        return fallbackCode(for: source.name)
    }

    private func fallbackCode(for name: String) -> String {
        let words = name
            .split { character in
                character == " " || character == "-" || character == "_" || character == "."
            }
            .filter { !$0.isEmpty }

        let token = words.first.map(String.init) ?? name
        let prefix = String(token.prefix(2))

        guard let first = prefix.first else {
            return "??"
        }

        let second = prefix.dropFirst().lowercased()
        return String(first).uppercased() + second
    }
}
