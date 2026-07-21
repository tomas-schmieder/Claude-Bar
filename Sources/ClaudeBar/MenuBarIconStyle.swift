import Foundation

/// Visual styles for the menu-bar status item icon.
enum MenuBarIconStyle: String, CaseIterable, Sendable {
    /// Session bar with Claude “crab” notches + weekly bar underneath.
    case claudeAndBar
    /// Claude face only; session remaining fills the face body.
    case claudeOnly
    /// Two plain progress pills (no face / notches).
    case barsOnly

    var menuTitle: String {
        switch self {
        case .claudeAndBar: "Claude + Bar"
        case .claudeOnly: "Claude"
        case .barsOnly: "Bars Only"
        }
    }
}

enum MenuBarIconStylePreference {
    private static let userDefaultsKey = "menuBarIconStyle"

    static var current: MenuBarIconStyle {
        if let raw = UserDefaults.standard.string(forKey: self.userDefaultsKey),
           let style = MenuBarIconStyle(rawValue: raw)
        {
            return style
        }
        return .claudeAndBar
    }

    static func set(_ style: MenuBarIconStyle) {
        UserDefaults.standard.set(style.rawValue, forKey: self.userDefaultsKey)
    }
}
