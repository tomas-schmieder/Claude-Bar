import Foundation

/// Host runtime that requested a Claude usage fetch.
public enum ProviderRuntime: Sendable {
    case app
    case cli
}

/// Explicit Claude usage-source mode (Auto / Web / CLI / OAuth / API).
public enum ProviderSourceMode: String, CaseIterable, Sendable, Codable {
    case auto
    case web
    case cli
    case oauth
    case api

    public var usesWeb: Bool {
        self == .auto || self == .web
    }
}
