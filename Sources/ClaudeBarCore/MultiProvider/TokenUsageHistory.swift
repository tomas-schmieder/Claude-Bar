import Foundation

/// Provider-neutral token usage for one local calendar day.
///
/// Token buckets are normalized so they never overlap:
/// - `inputTokens`: uncached prompt tokens
/// - `cacheReadTokens`: prompt tokens served from cache
/// - `cacheWriteTokens`: prompt tokens written to cache
/// - `outputTokens`: completion tokens (including reasoning)
public struct TokenUsageDay: Codable, Equatable, Sendable, Identifiable {
    public struct Model: Codable, Equatable, Sendable {
        public let name: String
        public let totalTokens: Int
        public let costUSD: Double?

        public init(name: String, totalTokens: Int, costUSD: Double?) {
            self.name = name
            self.totalTokens = totalTokens
            self.costUSD = costUSD
        }
    }

    /// `yyyy-MM-dd` in the user's local calendar.
    public let dayKey: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    /// Estimated cost at public API list prices. `nil` when no model on this day could be priced.
    public let costUSD: Double?
    /// Models sorted by descending token count.
    public let models: [Model]

    public var id: String {
        self.dayKey
    }

    public var totalTokens: Int {
        self.inputTokens + self.outputTokens + self.cacheReadTokens + self.cacheWriteTokens
    }

    public init(
        dayKey: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        costUSD: Double?,
        models: [Model])
    {
        self.dayKey = dayKey
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.cacheWriteTokens = max(0, cacheWriteTokens)
        self.costUSD = costUSD
        self.models = models
    }

    /// Start of the local day this entry represents.
    public func date(calendar: Calendar = .current) -> Date? {
        TokenUsageDayKey.date(from: self.dayKey, calendar: calendar)
    }
}

/// A rolling window of daily token usage for a single provider.
public struct TokenUsageHistory: Codable, Equatable, Sendable {
    /// Sorted ascending by day. Days without usage may be omitted.
    public let days: [TokenUsageDay]
    public let updatedAt: Date
    /// Human-readable description of where the numbers come from.
    public let sourceDescription: String

    public init(days: [TokenUsageDay], updatedAt: Date, sourceDescription: String) {
        self.days = days.sorted { $0.dayKey < $1.dayKey }
        self.updatedAt = updatedAt
        self.sourceDescription = sourceDescription
    }

    /// Returns exactly `count` days ending today (oldest first), filling gaps with empty days.
    public func filledDays(last count: Int, now: Date = Date(), calendar: Calendar = .current) -> [TokenUsageDay] {
        guard count > 0 else { return [] }
        let byKey = Dictionary(self.days.map { ($0.dayKey, $0) }, uniquingKeysWith: { _, latest in latest })
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().compactMap { offset -> TokenUsageDay? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = TokenUsageDayKey.key(from: date, calendar: calendar)
            return byKey[key] ?? TokenUsageDay(
                dayKey: key,
                inputTokens: 0,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                costUSD: nil,
                models: [])
        }
    }

    public func summary(last count: Int, now: Date = Date(), calendar: Calendar = .current) -> TokenUsageSummary {
        TokenUsageSummary(days: self.filledDays(last: count, now: now, calendar: calendar))
    }
}

/// Totals over a set of days.
public struct TokenUsageSummary: Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let costUSD: Double?
    public let topModel: String?

    public var totalTokens: Int {
        self.inputTokens + self.outputTokens + self.cacheReadTokens + self.cacheWriteTokens
    }

    public init(days: [TokenUsageDay]) {
        self.inputTokens = days.reduce(0) { $0 + $1.inputTokens }
        self.outputTokens = days.reduce(0) { $0 + $1.outputTokens }
        self.cacheReadTokens = days.reduce(0) { $0 + $1.cacheReadTokens }
        self.cacheWriteTokens = days.reduce(0) { $0 + $1.cacheWriteTokens }
        let costs = days.compactMap(\.costUSD)
        self.costUSD = costs.isEmpty ? nil : costs.reduce(0, +)

        var tokensByModel: [String: Int] = [:]
        for day in days {
            for model in day.models {
                tokensByModel[model.name, default: 0] += model.totalTokens
            }
        }
        self.topModel = tokensByModel.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
    }
}

public enum TokenUsageDayKey {
    public static func key(from date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1)
    }

    public static func date(from key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar.date(from: components)
    }
}

/// Accumulates per-day, per-model token counts and prices, then builds a `TokenUsageHistory`.
public struct TokenUsageAccumulator: Sendable {
    public struct Totals: Codable, Equatable, Sendable {
        public var input = 0
        public var output = 0
        public var cacheRead = 0
        public var cacheWrite = 0
        public var costUSD: Double?

        public init() {}

        public var total: Int {
            self.input + self.output + self.cacheRead + self.cacheWrite
        }

        public mutating func add(_ other: Totals) {
            self.input += other.input
            self.output += other.output
            self.cacheRead += other.cacheRead
            self.cacheWrite += other.cacheWrite
            if let cost = other.costUSD {
                self.costUSD = (self.costUSD ?? 0) + cost
            }
        }
    }

    /// dayKey -> model -> totals
    public private(set) var days: [String: [String: Totals]] = [:]

    public init() {}

    public mutating func add(dayKey: String, model: String, totals: Totals) {
        var models = self.days[dayKey] ?? [:]
        var existing = models[model] ?? Totals()
        existing.add(totals)
        models[model] = existing
        self.days[dayKey] = models
    }

    public mutating func merge(_ other: [String: [String: Totals]]) {
        for (dayKey, models) in other {
            for (model, totals) in models {
                self.add(dayKey: dayKey, model: model, totals: totals)
            }
        }
    }

    public func history(
        sinceKey: String? = nil,
        updatedAt: Date = Date(),
        sourceDescription: String) -> TokenUsageHistory
    {
        let days = self.days.compactMap { dayKey, models -> TokenUsageDay? in
            if let sinceKey, dayKey < sinceKey { return nil }
            var sum = Totals()
            for totals in models.values {
                sum.add(totals)
            }
            guard sum.total > 0 else { return nil }
            let modelRows = models
                .map { TokenUsageDay.Model(name: $0.key, totalTokens: $0.value.total, costUSD: $0.value.costUSD) }
                .sorted { $0.totalTokens == $1.totalTokens ? $0.name < $1.name : $0.totalTokens > $1.totalTokens }
            return TokenUsageDay(
                dayKey: dayKey,
                inputTokens: sum.input,
                outputTokens: sum.output,
                cacheReadTokens: sum.cacheRead,
                cacheWriteTokens: sum.cacheWrite,
                costUSD: sum.costUSD,
                models: modelRows)
        }
        return TokenUsageHistory(days: days, updatedAt: updatedAt, sourceDescription: sourceDescription)
    }
}

extension TokenUsageHistory {
    /// Adapts the Claude local-log cost scan into the provider-neutral history.
    public init(claude snapshot: CostUsageTokenSnapshot) {
        let days = snapshot.daily.map { entry -> TokenUsageDay in
            let input = entry.inputTokens ?? 0
            let output = entry.outputTokens ?? 0
            let cacheRead = entry.cacheReadTokens ?? 0
            let cacheWrite = entry.cacheCreationTokens ?? 0
            let bucketSum = input + output + cacheRead + cacheWrite
            // Some rows only carry a total; keep it visible as uncached input.
            let adjustedInput = bucketSum == 0 ? (entry.totalTokens ?? 0) : input
            let models = (entry.modelBreakdowns ?? [])
                .map { TokenUsageDay.Model(
                    name: $0.modelName,
                    totalTokens: $0.totalTokens ?? 0,
                    costUSD: $0.costUSD) }
                .sorted { $0.totalTokens > $1.totalTokens }
            return TokenUsageDay(
                dayKey: entry.date,
                inputTokens: adjustedInput,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite,
                costUSD: entry.costUSD,
                models: models)
        }
        self.init(
            days: days,
            updatedAt: snapshot.updatedAt,
            sourceDescription: "Local Claude Code logs (~/.claude/projects)")
    }
}
