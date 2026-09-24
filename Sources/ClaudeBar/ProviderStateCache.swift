import ClaudeBarCore
import Foundation

enum AppSupport {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ClaudeBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Persists the last good limits + token history per provider so the popover paints instantly on launch.
enum ProviderStateCache {
    struct Entry: Codable {
        var limits: ProviderLimitSnapshot?
        var history: TokenUsageHistory?
    }

    private static func fileURL(for provider: AIProvider) -> URL {
        AppSupport.directory.appendingPathComponent("\(provider.rawValue)-state.json")
    }

    static func load(_ provider: AIProvider) -> Entry? {
        guard let data = try? Data(contentsOf: self.fileURL(for: provider)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    static func save(_ entry: Entry, for provider: AIProvider) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: self.fileURL(for: provider), options: .atomic)
    }
}
