import Foundation

/// Provider-neutral plan limits (session / weekly / monthly windows) plus account metadata.
public struct ProviderLimitSnapshot: Codable, Equatable, Sendable {
    /// Ordered for display; the first window drives the menu-bar icon's top bar, the second its bottom bar.
    public let windows: [NamedRateWindow]
    public let accountEmail: String?
    public let planName: String?
    /// Short extra facts, e.g. "On-demand: $3.20 of $50" or "Credits: 120".
    public let notes: [String]
    public let updatedAt: Date

    public init(
        windows: [NamedRateWindow],
        accountEmail: String?,
        planName: String?,
        notes: [String] = [],
        updatedAt: Date = Date())
    {
        self.windows = windows
        self.accountEmail = accountEmail
        self.planName = planName
        self.notes = notes
        self.updatedAt = updatedAt
    }
}

/// Human-friendly label for a rate window length ("5-hour", "Weekly", …).
public enum RateWindowLabel {
    public static func title(forWindowMinutes minutes: Int?, fallback: String) -> String {
        guard let minutes, minutes > 0 else { return fallback }
        switch minutes {
        case ..<60:
            return "\(minutes)-minute"
        case ..<(24 * 60):
            let hours = Int((Double(minutes) / 60).rounded())
            return "\(hours)-hour"
        case (24 * 60)..<(2 * 24 * 60):
            return "Daily"
        case (6 * 24 * 60)..<(8 * 24 * 60):
            return "Weekly"
        case (28 * 24 * 60)..<(32 * 24 * 60):
            return "Monthly"
        default:
            let days = Int((Double(minutes) / (24 * 60)).rounded())
            return "\(days)-day"
        }
    }
}
