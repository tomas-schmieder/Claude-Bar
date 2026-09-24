import ClaudeBarCore
import Foundation

@main
enum ClaudeBarDebugMain {
    static func main() async {
        print("ClaudeBarDebug: fetching Claude usage…")
        let started = Date()
        do {
            let snapshot = try await fetchUsage()
            let elapsed = Date().timeIntervalSince(started)
            print(String(format: "elapsed: %.1fs", elapsed))
            print("updatedAt: \(snapshot.updatedAt)")
            print("session: \(format(snapshot.primary))")
            if let weekly = snapshot.secondary {
                print("weekly:  \(format(weekly))")
            }
            if !snapshot.extraRateWindows.isEmpty {
                print("extras:")
                for window in snapshot.extraRateWindows {
                    print("  - \(window.title): \(format(window.window))")
                }
            }
            if let email = snapshot.accountEmail {
                print("account: \(email)")
            }
            if let method = snapshot.loginMethod {
                print("login:   \(method)")
            }

            print("ClaudeBarDebug: scanning local cost usage…")
            let costStarted = Date()
            if let token = try? await CostUsageFetcher.loadClaudeTokenSnapshot() {
                print(String(format: "cost elapsed: %.1fs", Date().timeIntervalSince(costStarted)))
                if let today = token.sessionCostUSD {
                    print("today:   \(UsageFormatter.usdString(today))")
                }
                if let month = token.last30DaysCostUSD {
                    print("30d:     \(UsageFormatter.usdString(month))")
                }
                if let tokens = token.last30DaysTokens {
                    print("30d tok: \(UsageFormatter.tokenCountString(tokens))")
                }
            } else {
                print("cost: unavailable")
            }
        } catch {
            fputs("claude error: \(error.localizedDescription)\n", stderr)
        }

        await self.debugCodex()
        await self.debugCursor()
    }

    private static func debugCodex() async {
        print("\nClaudeBarDebug: fetching Codex usage…")
        do {
            let limits = try await CodexUsageClient().fetchLimits()
            self.printLimits(limits)
        } catch {
            fputs("codex limits error: \(error.localizedDescription)\n", stderr)
        }
        do {
            let local = try CodexSessionLogScanner().scan()
            self.printHistory(local.history)
            if let limits = local.limits {
                print("limits from local logs:")
                self.printLimits(limits)
            }
        } catch {
            fputs("codex history error: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func debugCursor() async {
        print("\nClaudeBarDebug: fetching Cursor usage…")
        let client = CursorUsageClient()
        do {
            let limits = try await client.fetchLimits()
            self.printLimits(limits)
        } catch {
            fputs("cursor limits error: \(error.localizedDescription)\n", stderr)
        }
        do {
            let history = try await client.fetchHistory()
            self.printHistory(history)
        } catch {
            fputs("cursor history error: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func printLimits(_ limits: ProviderLimitSnapshot) {
        if let email = limits.accountEmail {
            print("account: \(email)")
        }
        if let plan = limits.planName {
            print("plan:    \(plan)")
        }
        for named in limits.windows {
            print("  - \(named.title): \(format(named.window))")
        }
        for note in limits.notes {
            print("  \(note)")
        }
    }

    private static func printHistory(_ history: TokenUsageHistory) {
        let today = history.summary(last: 1)
        let month = history.summary(last: 30)
        print("source:  \(history.sourceDescription)")
        print("today:   \(UsageFormatter.tokenCountString(today.totalTokens)) tokens, "
            + (today.costUSD.map { UsageFormatter.usdString($0) } ?? "cost n/a"))
        print("30d:     \(UsageFormatter.tokenCountString(month.totalTokens)) tokens, "
            + (month.costUSD.map { UsageFormatter.usdString($0) } ?? "cost n/a"))
        if let top = month.topModel {
            print("top:     \(top)")
        }
    }

    private static func fetchUsage() async throws -> ClaudeUsageSnapshot {
        let browser = BrowserDetection()
        let environment = ProcessInfo.processInfo.environment
        if ClaudeOAuthCredentialsStore.hasCachedCredentials()
            || ClaudeOAuthPlanningAvailability.isAvailable(
                runtime: .cli,
                sourceMode: .oauth,
                environment: environment)
        {
            do {
                return try await ClaudeUsageFetcher(
                    browserDetection: browser,
                    environment: environment,
                    runtime: .cli,
                    dataSource: .oauth).loadLatestUsage()
            } catch {
                print("oauth failed (\(error.localizedDescription)); falling back to auto")
            }
        } else {
            print("no oauth cache; using auto (may use CLI)")
        }
        return try await ClaudeUsageFetcher(
            browserDetection: browser,
            environment: environment,
            runtime: .cli,
            dataSource: .auto,
            keepCLISessionsAlive: true).loadLatestUsage()
    }

    private static func format(_ window: RateWindow) -> String {
        let pct = String(format: "%.1f%%", window.usedPercent)
        if let resetsAt = window.resetsAt {
            return "\(pct) used, resets \(resetsAt)"
        }
        if let description = window.resetDescription, !description.isEmpty {
            return "\(pct) used, \(description)"
        }
        return "\(pct) used"
    }
}
