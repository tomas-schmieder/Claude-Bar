import ClaudeBarCore
import Foundation

/// English-only pace labels matching CodexBar’s Claude weekly/session detail rows.
enum UsagePaceText {
    struct WeeklyDetail {
        let leftLabel: String
        let rightLabel: String?
        let expectedUsedPercent: Double
        let stage: UsagePace.Stage
    }

    struct SessionEquivalentDetail: Equatable {
        let verdictText: String
        let numberText: String
    }

    static func weeklyDetail(pace: UsagePace) -> WeeklyDetail {
        WeeklyDetail(
            leftLabel: self.detailLeftLabel(for: pace),
            rightLabel: self.detailRightLabel(for: pace),
            expectedUsedPercent: pace.expectedUsedPercent,
            stage: pace.stage)
    }

    /// Lightweight forecast without historical burn samples (CodexBar uses stored history).
    static func sessionEquivalentDetail(
        session: RateWindow,
        weekly: RateWindow,
        now: Date = .init()) -> SessionEquivalentDetail?
    {
        guard let weeklyResetsAt = weekly.resetsAt,
              weeklyResetsAt > now,
              weekly.remainingPercent > 0
        else { return nil }

        let sessionMinutes = Double(session.windowMinutes ?? 300)
        let weeklyMinutes = Double(weekly.windowMinutes ?? 10_080)
        guard sessionMinutes > 0, weeklyMinutes > 0 else { return nil }

        let weeklyRemainingSeconds = weeklyResetsAt.timeIntervalSince(now)
        let windowsUntilReset = max(0, Int(floor(weeklyRemainingSeconds / (sessionMinutes * 60))))
        let availableWindows = weeklyRemainingSeconds / (sessionMinutes * 60)

        // Prefer observed session burn; fall back to even weekly burn so far.
        let burnPerWindow: Double
        if session.usedPercent > 1 {
            // Session % is session-quota burn, not weekly — scale roughly by window ratio.
            burnPerWindow = max(0.5, (session.usedPercent / 100) * (sessionMinutes / weeklyMinutes) * 100)
        } else if let elapsedFraction = Self.elapsedFraction(for: weekly, now: now), elapsedFraction > 0.02 {
            burnPerWindow = (weekly.usedPercent / max(1, elapsedFraction * (weeklyMinutes / sessionMinutes)))
        } else {
            return nil
        }
        guard burnPerWindow > 0.05 else { return nil }

        let estimatedWindows = weekly.remainingPercent / burnPerWindow
        let displayedEstimate = max(0, Int(floor(min(estimatedWindows, 1_000_000))))
        let windowsEarly = availableWindows - estimatedWindows

        let verdictText: String
        if estimatedWindows >= availableWindows {
            verdictText = "Weekly cannot run out before reset at this pace"
        } else {
            let early = max(1, Int(windowsEarly.rounded()))
            verdictText = "Weekly can run out ≈\(early) windows early"
        }

        let numberText =
            "≈\(displayedEstimate) full 5h windows of weekly left · \(windowsUntilReset) windows until reset"

        return SessionEquivalentDetail(verdictText: verdictText, numberText: numberText)
    }

    private static func elapsedFraction(for window: RateWindow, now: Date) -> Double? {
        guard let resetsAt = window.resetsAt else { return nil }
        let minutes = Double(window.windowMinutes ?? 10_080)
        let duration = minutes * 60
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0, remaining <= duration else { return nil }
        return ((duration - remaining) / duration).clamped(to: 0...1)
    }

    private static func detailLeftLabel(for pace: UsagePace) -> String {
        let deltaValue = Int(abs(pace.deltaPercent).rounded())
        if deltaValue == 0 { return "On pace" }
        switch pace.stage {
        case .onTrack:
            return "On pace"
        case .slightlyAhead, .ahead, .farAhead:
            return "\(deltaValue)% in deficit"
        case .slightlyBehind, .behind, .farBehind:
            return "\(deltaValue)% in reserve"
        }
    }

    private static func detailRightLabel(for pace: UsagePace) -> String? {
        if pace.willLastToReset {
            return "Lasts until reset"
        }
        if let etaSeconds = pace.etaSeconds {
            let etaText = UsageFormatter.resetCountdownDescription(
                from: Date().addingTimeInterval(etaSeconds),
                now: Date())
            return etaText == "now" ? "Runs out now" : "Runs out in \(etaText)"
        }
        return nil
    }
}
