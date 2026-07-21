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
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
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
