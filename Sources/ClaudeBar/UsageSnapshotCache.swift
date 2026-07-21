import ClaudeBarCore
import Foundation

/// Persists the last good Claude usage snapshot so the menu can paint instantly on launch.
enum UsageSnapshotCache {
    private static let fileName = "claude-usage-snapshot.json"

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ClaudeBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    static func load() -> ClaudeUsageSnapshot? {
        guard let data = try? Data(contentsOf: self.fileURL) else { return nil }
        return try? JSONDecoder().decode(CachedClaudeUsageSnapshot.self, from: data).snapshot
    }

    static func save(_ snapshot: ClaudeUsageSnapshot) {
        let cached = CachedClaudeUsageSnapshot(snapshot: snapshot)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: self.fileURL, options: .atomic)
    }
}

/// Codable mirror of the fields ClaudeBar needs for cache-first UI.
private struct CachedClaudeUsageSnapshot: Codable {
    var primary: RateWindow
    var secondary: RateWindow?
    var opus: RateWindow?
    var extraRateWindows: [NamedRateWindow]
    var updatedAt: Date
    var accountEmail: String?
    var accountOrganization: String?
    var loginMethod: String?

    init(snapshot: ClaudeUsageSnapshot) {
        self.primary = snapshot.primary
        self.secondary = snapshot.secondary
        self.opus = snapshot.opus
        self.extraRateWindows = snapshot.extraRateWindows
        self.updatedAt = snapshot.updatedAt
        self.accountEmail = snapshot.accountEmail
        self.accountOrganization = snapshot.accountOrganization
        self.loginMethod = snapshot.loginMethod
    }

    var snapshot: ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            primary: self.primary,
            secondary: self.secondary,
            opus: self.opus,
            extraRateWindows: self.extraRateWindows,
            updatedAt: self.updatedAt,
            accountEmail: self.accountEmail,
            accountOrganization: self.accountOrganization,
            loginMethod: self.loginMethod,
            rawText: nil)
    }
}
