import Foundation
import XCTest
@testable import ClaudeBarCore

final class CodexSessionLogScannerTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        self.home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudebar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: self.home.appendingPathComponent("sessions/2026/01/01", isDirectory: true),
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.home)
    }

    private func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func tokenCount(total: (Int, Int, Int), last: (Int, Int, Int), rateLimits: String = "null") -> String {
        """
        {"timestamp":"\(self.timestamp())","type":"event_msg","payload":{"type":"token_count","info":{\
        "total_token_usage":{"input_tokens":\(total.0),"cached_input_tokens":\(total.1),"output_tokens":\(total.2)},\
        "last_token_usage":{"input_tokens":\(last.0),"cached_input_tokens":\(last.1),"output_tokens":\(last.2)}},\
        "rate_limits":\(rateLimits)}}
        """
    }

    func testCountsDeltasSkipsDuplicatesAndResumesIncrementally() throws {
        let file = self.home.appendingPathComponent("sessions/2026/01/01/rollout-test.jsonl")
        let cacheURL = self.home.appendingPathComponent("cache.json")
        let turnContext = #"{"timestamp":"\#(self.timestamp())","type":"turn_context","payload":{"model":"gpt-5-codex"}}"#
        let rateLimits = #"{"primary":{"used_percent":42.0,"window_minutes":300,"resets_in_seconds":3600},"secondary":{"used_percent":10.0,"window_minutes":10080,"resets_in_seconds":86400}}"#
        let lines = [
            turnContext,
            self.tokenCount(total: (1000, 200, 100), last: (1000, 200, 100)),
            // Duplicate re-emission with unchanged totals must not be counted again.
            self.tokenCount(total: (1000, 200, 100), last: (1000, 200, 100), rateLimits: rateLimits),
            self.tokenCount(total: (1500, 300, 150), last: (500, 100, 50)),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let scanner = CodexSessionLogScanner(codexHome: self.home, cacheURL: cacheURL)
        var usage = try scanner.scan(historyDays: 7)
        var today = usage.history.summary(last: 1)
        XCTAssertEqual(today.inputTokens, 1200)
        XCTAssertEqual(today.cacheReadTokens, 300)
        XCTAssertEqual(today.outputTokens, 150)
        XCTAssertEqual(today.topModel, "gpt-5-codex")
        XCTAssertNotNil(today.costUSD)

        let limits = try XCTUnwrap(usage.limits)
        XCTAssertEqual(limits.windows.map(\.title), ["5-hour", "Weekly"])
        XCTAssertEqual(limits.windows.first?.window.usedPercent, 42)

        // Append one more turn; the cached offset means only the new line is read.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((self.tokenCount(total: (1600, 300, 160), last: (100, 0, 10)) + "\n").utf8))
        try handle.close()

        usage = try scanner.scan(historyDays: 7)
        today = usage.history.summary(last: 1)
        XCTAssertEqual(today.inputTokens, 1300)
        XCTAssertEqual(today.cacheReadTokens, 300)
        XCTAssertEqual(today.outputTokens, 160)
    }

    func testIgnoresTrailingPartialLine() throws {
        let file = self.home.appendingPathComponent("sessions/2026/01/01/rollout-partial.jsonl")
        let complete = self.tokenCount(total: (100, 0, 10), last: (100, 0, 10))
        try (complete + "\n" + #"{"timestamp":"#).write(to: file, atomically: true, encoding: .utf8)
        let usage = try CodexSessionLogScanner(codexHome: self.home).scan(historyDays: 1)
        XCTAssertEqual(usage.history.summary(last: 1).totalTokens, 110)
    }
}

final class CursorUsageClientTests: XCTestCase {
    func testMapsUsageSummary() throws {
        let json = """
        {"billingCycleStart":"2026-09-01T00:00:00.000Z","billingCycleEnd":"2026-10-01T00:00:00.000Z",
         "membershipType":"pro","isUnlimited":false,
         "individualUsage":{"plan":{"enabled":true,"used":1500,"limit":2000,"autoPercentUsed":12.5,
           "apiPercentUsed":60,"totalPercentUsed":75},"onDemand":{"enabled":true,"used":320,"limit":5000}}}
        """
        let summary = try JSONDecoder().decode(CursorUsageSummary.self, from: Data(json.utf8))
        let limits = CursorUsageClient.limits(from: summary, email: "me@example.com", now: Date())
        XCTAssertEqual(limits.windows.map(\.id), ["cursor-total", "cursor-auto", "cursor-api"])
        XCTAssertEqual(limits.windows.first?.window.remainingPercent, 25)
        XCTAssertEqual(limits.windows.first?.window.windowMinutes, 30 * 24 * 60)
        XCTAssertEqual(limits.planName, "Pro")
        XCTAssertEqual(limits.notes, ["Included: $15.00 of $20.00", "On-demand: $3.20 of $50.00"])
    }

    func testAggregatesUsageEventsByDayAndModel() {
        var accumulator = TokenUsageAccumulator()
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let ms = String(Int64(noon.timeIntervalSince1970 * 1000))
        let events: [[String: Any]] = [
            ["timestamp": ms, "model": "claude-4.5-sonnet", "tokenUsage": [
                "inputTokens": 100, "outputTokens": 50, "cacheReadTokens": 1000, "cacheWriteTokens": 10,
                "totalCents": 1.5,
            ] as [String: Any]],
            ["timestamp": ms, "model": "gpt-5", "tokenUsage": ["inputTokens": "20", "outputTokens": 5] as [String: Any]],
            // No token usage: skipped.
            ["timestamp": ms, "model": "gpt-5"],
        ]
        for event in events {
            CursorUsageClient.add(event: event, to: &accumulator, calendar: .current)
        }
        let today = accumulator.history(sourceDescription: "test").summary(last: 1)
        XCTAssertEqual(today.inputTokens, 120)
        XCTAssertEqual(today.outputTokens, 55)
        XCTAssertEqual(today.cacheReadTokens, 1000)
        XCTAssertEqual(today.cacheWriteTokens, 10)
        XCTAssertEqual(today.costUSD ?? 0, 0.015, accuracy: 1e-9)
        XCTAssertEqual(today.topModel, "claude-4.5-sonnet")
    }
}

final class TokenUsageHistoryTests: XCTestCase {
    func testFilledDaysPadsMissingDays() {
        let now = Date()
        let calendar = Calendar.current
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: now)!
        let history = TokenUsageHistory(
            days: [TokenUsageDay(
                dayKey: TokenUsageDayKey.key(from: twoDaysAgo),
                inputTokens: 10,
                outputTokens: 5,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                costUSD: 0.25,
                models: [])],
            updatedAt: now,
            sourceDescription: "test")
        let days = history.filledDays(last: 7, now: now)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.last?.dayKey, TokenUsageDayKey.key(from: now))
        XCTAssertEqual(days[4].totalTokens, 15)
        XCTAssertEqual(history.summary(last: 7, now: now).costUSD, 0.25)
        XCTAssertNil(history.summary(last: 1, now: now).costUSD)
    }

    func testRateWindowLabels() {
        XCTAssertEqual(RateWindowLabel.title(forWindowMinutes: 300, fallback: "x"), "5-hour")
        XCTAssertEqual(RateWindowLabel.title(forWindowMinutes: 10080, fallback: "x"), "Weekly")
        XCTAssertEqual(RateWindowLabel.title(forWindowMinutes: nil, fallback: "Session"), "Session")
    }
}
