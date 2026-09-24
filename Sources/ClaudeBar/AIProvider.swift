import AppKit
import SwiftUI

/// The AI coding tools ClaudeBar tracks.
enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case claude
    case codex
    case cursor

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    var dashboardURL: URL {
        switch self {
        case .claude: URL(string: "https://claude.ai/settings/usage")!
        case .codex: URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .cursor: URL(string: "https://cursor.com/dashboard?tab=usage")!
        }
    }

    var statusPageURL: URL {
        switch self {
        case .claude: URL(string: "https://status.claude.com/")!
        case .codex: URL(string: "https://status.openai.com/")!
        case .cursor: URL(string: "https://status.cursor.com/")!
        }
    }

    /// Validated categorical slots (orange / blue / aqua), stepped separately for light and dark.
    var accentColor: Color {
        Color(nsColor: self.nsAccentColor)
    }

    var nsAccentColor: NSColor {
        let hex: (light: UInt32, dark: UInt32) = switch self {
        case .claude: (0xEB6834, 0xD95926)
        case .codex: (0x2A78D6, 0x3987E5)
        case .cursor: (0x1BAF7A, 0x199E70)
        }
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? hex.dark : hex.light)
        }
    }

    /// Where the token history comes from, shown under the chart.
    var historyFootnote: String {
        switch self {
        case .claude:
            "Estimated from local Claude Code logs at Anthropic API list prices."
        case .codex:
            "Estimated from local Codex CLI logs at OpenAI API list prices."
        case .cursor:
            "From cursor.com usage events at vendor API list prices."
        }
    }
}

extension NSColor {
    fileprivate convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

/// User preferences stored in `UserDefaults`.
enum AppPreferences {
    private static let enabledKey = "enabledProviders"
    private static let menuBarProviderKey = "menuBarProvider"
    private static let selectedTabKey = "selectedProviderTab"

    static var enabledProviders: [AIProvider] {
        get {
            guard let raw = UserDefaults.standard.array(forKey: self.enabledKey) as? [String] else {
                return AIProvider.allCases
            }
            let enabled = Set(raw.compactMap(AIProvider.init(rawValue:)))
            return AIProvider.allCases.filter { enabled.contains($0) }
        }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: self.enabledKey)
        }
    }

    static var menuBarProvider: AIProvider {
        get {
            UserDefaults.standard.string(forKey: self.menuBarProviderKey).flatMap(AIProvider.init(rawValue:)) ?? .claude
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: self.menuBarProviderKey)
        }
    }

    static var selectedTab: AIProvider {
        get {
            UserDefaults.standard.string(forKey: self.selectedTabKey).flatMap(AIProvider.init(rawValue:)) ?? .claude
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: self.selectedTabKey)
        }
    }
}
