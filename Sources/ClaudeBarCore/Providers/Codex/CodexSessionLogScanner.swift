import Foundation

/// Result of scanning the Codex CLI's local session logs.
public struct CodexLocalUsage: Sendable {
    public let history: TokenUsageHistory
    /// Plan limits as last reported inside a session log (offline fallback for the live API).
    public let limits: ProviderLimitSnapshot?
}

/// Reads Codex CLI rollout logs (`$CODEX_HOME/sessions/**/rollout-*.jsonl`) and turns
/// `token_count` events into daily token totals priced at OpenAI API list rates.
///
/// Each file is parsed incrementally: the byte offset and running totals are cached, so a
/// refresh only reads what Codex appended since the last scan.
public struct CodexSessionLogScanner: Sendable {
    private static let cacheVersion = 1
    private static let defaultPricingModel = "gpt-5"

    private let codexHome: URL
    private let cacheURL: URL?

    public init(codexHome: URL = CodexHome.url(), cacheURL: URL? = nil) {
        self.codexHome = codexHome
        self.cacheURL = cacheURL
    }

    public func scan(historyDays: Int = 30, now: Date = Date()) throws -> CodexLocalUsage {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let since = calendar.date(byAdding: .day, value: -(max(1, historyDays) - 1), to: today) ?? today
        let sinceKey = TokenUsageDayKey.key(from: since, calendar: calendar)

        var cache = self.loadCache()
        var seenPaths: Set<String> = []
        let catalog = CostUsagePricing.modelsDevCatalog() ?? ModelsDevCatalog(providers: [:])

        for file in self.sessionFiles(modifiedSince: since) {
            try Task.checkCancellation()
            seenPaths.insert(file.url.path)
            let previous = cache.files[file.url.path]
            if let previous, previous.size == file.size, previous.mtime == file.mtime {
                continue
            }
            // Resume only when the file grew; a rewritten/truncated file is reparsed from scratch.
            let start = previous.flatMap { $0.size <= file.size && $0.offset <= file.size ? $0 : nil }
                ?? CodexFileState()
            var state = start
            try Self.parse(fileURL: file.url, state: &state, catalog: catalog)
            state.size = file.size
            state.mtime = file.mtime
            cache.files[file.url.path] = state
        }
        // Drop files that fell out of the window (or were deleted) so the cache stays small.
        cache.files = cache.files.filter { seenPaths.contains($0.key) }
        self.saveCache(cache)

        var accumulator = TokenUsageAccumulator()
        var latestSample: CodexRateLimitSample?
        for state in cache.files.values {
            accumulator.merge(state.days)
            if let sample = state.latestRateLimits,
               latestSample.map({ sample.timestamp > $0.timestamp }) ?? true
            {
                latestSample = sample
            }
        }

        let history = accumulator.history(
            sinceKey: sinceKey,
            updatedAt: now,
            sourceDescription: "Local Codex CLI session logs (~/.codex/sessions)")
        return CodexLocalUsage(history: history, limits: latestSample.map { $0.limitSnapshot(now: now) })
    }

    // MARK: - Files

    private struct SessionFile {
        let url: URL
        let size: Int64
        let mtime: Double
    }

    private func sessionFiles(modifiedSince since: Date) -> [SessionFile] {
        let roots = [
            self.codexHome.appendingPathComponent("sessions", isDirectory: true),
            self.codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var files: [SessionFile] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      modified >= since
                else { continue }
                files.append(SessionFile(
                    url: url,
                    size: Int64(values.fileSize ?? 0),
                    mtime: modified.timeIntervalSince1970))
            }
        }
        return files
    }

    // MARK: - Parsing

    private static let tokenCountMarker = Data(#""token_count""#.utf8)
    private static let turnContextMarker = Data(#""turn_context""#.utf8)

    private static func parse(fileURL: URL, state: inout CodexFileState, catalog: ModelsDevCatalog) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, state.offset)))

        let parser = TimestampParser()
        var buffer = Data()
        var offset = state.offset
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            buffer.append(chunk)
            var lineStart = buffer.startIndex
            while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                let line = buffer[lineStart..<newline]
                if line.range(of: self.tokenCountMarker) != nil || line.range(of: self.turnContextMarker) != nil {
                    self.handle(line: line, state: &state, catalog: catalog, parser: parser)
                }
                lineStart = buffer.index(after: newline)
            }
            offset += Int64(buffer.distance(from: buffer.startIndex, to: lineStart))
            buffer = Data(buffer[lineStart...])
        }
        // A trailing partial line is left for the next scan (Codex may still be writing it).
        state.offset = offset
    }

    private static func handle(
        line: Data,
        state: inout CodexFileState,
        catalog: ModelsDevCatalog,
        parser: TimestampParser)
    {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any]
        else { return }

        if type == "turn_context" {
            if let model = (payload["model"] as? String) ?? (payload["model_name"] as? String), !model.isEmpty {
                state.model = model
            }
            return
        }

        guard type == "event_msg",
              payload["type"] as? String == "token_count",
              let timestampText = object["timestamp"] as? String,
              let timestamp = parser.parse(timestampText)
        else { return }

        if let rateLimits = payload["rate_limits"] as? [String: Any],
           let sample = CodexRateLimitSample(rateLimits, timestamp: timestamp),
           state.latestRateLimits.map({ timestamp >= $0.timestamp }) ?? true
        {
            state.latestRateLimits = sample
        }

        guard let info = payload["info"] as? [String: Any] else { return }
        if let model = (info["model"] as? String) ?? (info["model_name"] as? String), !model.isEmpty {
            state.model = model
        }
        let total = (info["total_token_usage"] as? [String: Any]).map { CodexTokenTriple($0) }
        let last = (info["last_token_usage"] as? [String: Any]).map { CodexTokenTriple($0) }

        let delta: CodexTokenTriple?
        if let total, let previous = state.lastTotals {
            if total == previous {
                // Codex re-emits token_count with unchanged totals (e.g. rate-limit updates).
                delta = nil
            } else if let last {
                delta = last
            } else {
                delta = total.subtracting(previous)
            }
        } else {
            // First event in this file: trust `last` so history copied into a resumed/forked
            // session's cumulative total is not counted again.
            delta = last ?? total
        }
        if let total {
            state.lastTotals = total
        }
        guard let delta, delta.input + delta.output > 0 else { return }

        let model = state.model ?? "unknown"
        let pricingModel = model == "unknown" ? self.defaultPricingModel : model
        let cached = min(delta.cached, delta.input)
        var totals = TokenUsageAccumulator.Totals()
        totals.input = delta.input - cached
        totals.cacheRead = cached
        totals.output = delta.output
        totals.costUSD = CostUsagePricing.codexCostUSD(
            model: pricingModel,
            inputTokens: delta.input,
            cachedInputTokens: cached,
            outputTokens: delta.output,
            modelsDevCatalog: catalog)

        let dayKey = TokenUsageDayKey.key(from: timestamp)
        var models = state.days[dayKey] ?? [:]
        var existing = models[model] ?? TokenUsageAccumulator.Totals()
        existing.add(totals)
        models[model] = existing
        state.days[dayKey] = models
    }

    // MARK: - Cache

    private func loadCache() -> CodexScanCache {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(CodexScanCache.self, from: data),
              cache.version == Self.cacheVersion
        else { return CodexScanCache(version: Self.cacheVersion, files: [:]) }
        return cache
    }

    private func saveCache(_ cache: CodexScanCache) {
        guard let cacheURL else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}

// MARK: - Models

/// `input` includes cached prompt tokens (OpenAI semantics); `output` includes reasoning tokens.
struct CodexTokenTriple: Codable, Equatable, Sendable {
    var input: Int
    var cached: Int
    var output: Int

    init(input: Int, cached: Int, output: Int) {
        self.input = input
        self.cached = cached
        self.output = output
    }

    init(_ usage: [String: Any]) {
        func int(_ key: String) -> Int {
            max(0, (usage[key] as? NSNumber)?.intValue ?? 0)
        }
        self.input = int("input_tokens")
        self.cached = max(int("cached_input_tokens"), int("cache_read_input_tokens"))
        self.output = int("output_tokens")
    }

    func subtracting(_ other: CodexTokenTriple) -> CodexTokenTriple {
        CodexTokenTriple(
            input: max(0, self.input - other.input),
            cached: max(0, self.cached - other.cached),
            output: max(0, self.output - other.output))
    }
}

struct CodexRateLimitSample: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        let usedPercent: Double
        let windowMinutes: Int?
        let resetsAt: Date?
    }

    let timestamp: Date
    let primary: Window?
    let secondary: Window?

    init?(_ json: [String: Any], timestamp: Date) {
        func window(_ raw: Any?) -> Window? {
            guard let raw = raw as? [String: Any],
                  let used = (raw["used_percent"] as? NSNumber)?.doubleValue
            else { return nil }
            let resetsAt: Date? = if let absolute = (raw["resets_at"] as? NSNumber)?.doubleValue, absolute > 0 {
                Date(timeIntervalSince1970: absolute)
            } else if let relative = (raw["resets_in_seconds"] as? NSNumber)?.doubleValue {
                timestamp.addingTimeInterval(relative)
            } else {
                nil
            }
            return Window(
                usedPercent: min(100, max(0, used)),
                windowMinutes: (raw["window_minutes"] as? NSNumber)?.intValue,
                resetsAt: resetsAt)
        }
        self.timestamp = timestamp
        self.primary = window(json["primary"])
        self.secondary = window(json["secondary"])
        if self.primary == nil, self.secondary == nil {
            return nil
        }
    }

    func limitSnapshot(now: Date) -> ProviderLimitSnapshot {
        func named(_ window: Window?, id: String, fallback: String) -> NamedRateWindow? {
            guard let window else { return nil }
            // If the window already reset since Codex last reported it, the lane is empty again.
            let hasReset = window.resetsAt.map { $0 <= now } ?? false
            return NamedRateWindow(
                id: id,
                title: RateWindowLabel.title(forWindowMinutes: window.windowMinutes, fallback: fallback),
                window: RateWindow(
                    usedPercent: hasReset ? 0 : window.usedPercent,
                    windowMinutes: window.windowMinutes,
                    resetsAt: hasReset ? nil : window.resetsAt,
                    resetDescription: hasReset ? "since last Codex run" : nil))
        }
        return ProviderLimitSnapshot(
            windows: [
                named(self.primary, id: "codex-primary", fallback: "Session"),
                named(self.secondary, id: "codex-secondary", fallback: "Weekly"),
            ].compactMap(\.self),
            accountEmail: CodexAuthTokens.load(codexHome: CodexHome.url())?.email,
            planName: nil,
            notes: ["From local Codex logs; live limits unavailable."],
            updatedAt: self.timestamp)
    }
}

struct CodexFileState: Codable, Sendable {
    var size: Int64 = 0
    var mtime: Double = 0
    var offset: Int64 = 0
    var lastTotals: CodexTokenTriple?
    var model: String?
    var days: [String: [String: TokenUsageAccumulator.Totals]] = [:]
    var latestRateLimits: CodexRateLimitSample?
}

struct CodexScanCache: Codable, Sendable {
    var version: Int
    var files: [String: CodexFileState]
}

/// ISO-8601 timestamps with or without fractional seconds.
final class TimestampParser {
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func parse(_ text: String) -> Date? {
        self.fractional.date(from: text) ?? self.plain.date(from: text)
    }
}
