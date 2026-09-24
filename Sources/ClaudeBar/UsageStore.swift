import ClaudeBarCore
import Foundation
import Observation

/// Live state for every tracked provider: plan limits plus daily token history.
@MainActor
@Observable
final class UsageStore {
    struct ProviderState {
        var limits: ProviderLimitSnapshot?
        var history: TokenUsageHistory?
        var limitsError: String?
        var historyError: String?
        var isRefreshingLimits = false
        var isRefreshingHistory = false
        /// Limits restored from disk (or a failed refresh) rather than fetched this session.
        var limitsAreStale = false

        var isRefreshing: Bool {
            self.isRefreshingLimits || self.isRefreshingHistory
        }
    }

    static let historyDays = 30
    private static let historyRefreshInterval: TimeInterval = 15 * 60

    private(set) var states: [AIProvider: ProviderState] = [:]
    private(set) var enabledProviders: [AIProvider] = AppPreferences.enabledProviders

    /// Called after any state change so the status item icon can follow along.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var limitTasks: [AIProvider: Task<Void, Never>] = [:]
    @ObservationIgnored private var historyTasks: [AIProvider: Task<Void, Never>] = [:]
    @ObservationIgnored private var keepClaudeCLISessionsAlive = false
    private let codexClient = CodexUsageClient()
    private let cursorClient = CursorUsageClient()
    /// Offline Codex limits parsed from session logs, used when the live API is unavailable.
    @ObservationIgnored private var codexLocalLimits: ProviderLimitSnapshot?
    /// Providers whose history was refreshed since launch (cached history alone does not count).
    @ObservationIgnored private var historyFetchedThisSession: Set<AIProvider> = []

    init() {
        for provider in AIProvider.allCases {
            var state = ProviderState()
            if let cached = ProviderStateCache.load(provider) {
                state.limits = cached.limits
                state.history = cached.history
                state.limitsAreStale = cached.limits != nil
            }
            self.states[provider] = state
        }
    }

    func state(for provider: AIProvider) -> ProviderState {
        self.states[provider] ?? ProviderState()
    }

    func isEnabled(_ provider: AIProvider) -> Bool {
        self.enabledProviders.contains(provider)
    }

    func setEnabled(_ provider: AIProvider, _ enabled: Bool) {
        var set = Set(self.enabledProviders)
        if enabled {
            set.insert(provider)
        } else {
            // Always keep at least one provider visible.
            guard set.count > 1 else { return }
            set.remove(provider)
        }
        self.enabledProviders = AIProvider.allCases.filter { set.contains($0) }
        AppPreferences.enabledProviders = self.enabledProviders
        if enabled {
            self.refresh(provider, userInitiated: true)
        } else {
            self.limitTasks[provider]?.cancel()
            self.historyTasks[provider]?.cancel()
        }
        self.onChange?()
    }

    // MARK: Refresh

    func refreshAll(userInitiated: Bool) {
        for provider in self.enabledProviders {
            self.refresh(provider, userInitiated: userInitiated)
        }
    }

    func refresh(_ provider: AIProvider, userInitiated: Bool) {
        self.refreshLimits(provider, userInitiated: userInitiated)
        let lastHistory = self.state(for: provider).history?.updatedAt ?? .distantPast
        if userInitiated
            || !self.historyFetchedThisSession.contains(provider)
            || Date().timeIntervalSince(lastHistory) > Self.historyRefreshInterval
        {
            self.refreshHistory(provider, force: userInitiated)
        }
    }

    /// Refresh when the popover opens, unless data is very fresh.
    func refreshIfStale(maxAge: TimeInterval = 120) {
        for provider in self.enabledProviders {
            let state = self.state(for: provider)
            let updated = state.limits?.updatedAt ?? .distantPast
            if state.limitsAreStale || Date().timeIntervalSince(updated) > maxAge {
                self.refresh(provider, userInitiated: false)
            }
        }
    }

    func cancelAll() {
        self.limitTasks.values.forEach { $0.cancel() }
        self.historyTasks.values.forEach { $0.cancel() }
    }

    private func refreshLimits(_ provider: AIProvider, userInitiated: Bool) {
        guard self.limitTasks[provider] == nil else { return }
        self.update(provider) {
            $0.isRefreshingLimits = true
        }
        let keepAlive = self.keepClaudeCLISessionsAlive
        let codexClient = self.codexClient
        let cursorClient = self.cursorClient
        self.limitTasks[provider] = Task { [weak self] in
            let result: Result<ProviderLimitSnapshot, Error>
            do {
                let limits: ProviderLimitSnapshot
                switch provider {
                case .claude:
                    limits = try await Self.fetchClaudeLimits(
                        userInitiated: userInitiated,
                        keepCLISessionsAlive: keepAlive)
                case .codex:
                    limits = try await codexClient.fetchLimits()
                case .cursor:
                    limits = try await cursorClient.fetchLimits()
                }
                result = .success(limits)
            } catch {
                result = .failure(error)
            }
            self?.finishLimits(provider, result: result)
        }
    }

    private func finishLimits(_ provider: AIProvider, result: Result<ProviderLimitSnapshot, Error>) {
        self.limitTasks[provider] = nil
        switch result {
        case let .success(limits):
            if provider == .claude {
                // After a successful path that may have used the CLI, keep it warm.
                self.keepClaudeCLISessionsAlive = true
            }
            self.update(provider) {
                $0.limits = limits
                $0.limitsError = nil
                $0.limitsAreStale = false
                $0.isRefreshingLimits = false
            }
        case let .failure(error):
            if error is CancellationError {
                self.update(provider) { $0.isRefreshingLimits = false }
                return
            }
            if provider == .codex, let local = self.codexLocalLimits {
                self.update(provider) {
                    $0.limits = local
                    $0.limitsError = nil
                    $0.limitsAreStale = false
                    $0.isRefreshingLimits = false
                }
                return
            }
            self.update(provider) {
                $0.limitsError = error.localizedDescription
                $0.limitsAreStale = $0.limits != nil
                $0.isRefreshingLimits = false
            }
        }
        self.persist(provider)
    }

    private func refreshHistory(_ provider: AIProvider, force: Bool) {
        guard self.historyTasks[provider] == nil else { return }
        self.update(provider) {
            $0.isRefreshingHistory = true
        }
        let days = Self.historyDays
        let cursorClient = self.cursorClient
        self.historyTasks[provider] = Task { [weak self] in
            var localCodexLimits: ProviderLimitSnapshot?
            let result: Result<TokenUsageHistory, Error>
            do {
                switch provider {
                case .claude:
                    let snapshot = try await CostUsageFetcher.loadClaudeTokenSnapshot(
                        forceRefresh: force,
                        historyDays: days)
                    result = .success(TokenUsageHistory(claude: snapshot))
                case .codex:
                    let scanner = CodexSessionLogScanner(
                        cacheURL: AppSupport.directory.appendingPathComponent("codex-scan-cache.json"))
                    let usage = try await Task.detached(priority: .utility) {
                        try scanner.scan(historyDays: days)
                    }.value
                    localCodexLimits = usage.limits
                    result = .success(usage.history)
                case .cursor:
                    let history = try await cursorClient.fetchHistory(historyDays: days)
                    result = .success(history)
                }
            } catch {
                result = .failure(error)
            }
            self?.finishHistory(provider, result: result, codexLocalLimits: localCodexLimits)
        }
    }

    private func finishHistory(
        _ provider: AIProvider,
        result: Result<TokenUsageHistory, Error>,
        codexLocalLimits: ProviderLimitSnapshot?)
    {
        self.historyTasks[provider] = nil
        if let codexLocalLimits {
            self.codexLocalLimits = codexLocalLimits
            // The live API failed before the scan finished: fall back now.
            let state = self.state(for: .codex)
            if state.limitsError != nil, !state.isRefreshingLimits {
                self.update(.codex) {
                    $0.limits = codexLocalLimits
                    $0.limitsError = nil
                    $0.limitsAreStale = false
                }
            }
        }
        switch result {
        case let .success(history):
            self.historyFetchedThisSession.insert(provider)
            self.update(provider) {
                $0.history = history
                $0.historyError = nil
                $0.isRefreshingHistory = false
            }
        case let .failure(error):
            self.update(provider) {
                if !(error is CancellationError) {
                    $0.historyError = error.localizedDescription
                }
                $0.isRefreshingHistory = false
            }
        }
        self.persist(provider)
    }

    private func update(_ provider: AIProvider, _ mutate: (inout ProviderState) -> Void) {
        var state = self.states[provider] ?? ProviderState()
        mutate(&state)
        self.states[provider] = state
        self.onChange?()
    }

    private func persist(_ provider: AIProvider) {
        let state = self.state(for: provider)
        ProviderStateCache.save(
            ProviderStateCache.Entry(limits: state.limits, history: state.history),
            for: provider)
    }

    // MARK: Claude

    /// Prefer the silent OAuth cache when available; otherwise the Claude CLI (never shows Keychain prompts).
    private nonisolated static func fetchClaudeLimits(
        userInitiated: Bool,
        keepCLISessionsAlive: Bool) async throws -> ProviderLimitSnapshot
    {
        let interaction: ProviderInteraction = userInitiated ? .userInitiated : .background
        let snapshot = try await ProviderInteractionContext.$current.withValue(interaction) {
            try await Self.fetchClaudeUsage(keepCLISessionsAlive: keepCLISessionsAlive)
        }
        return ClaudeLimitAdapter.limits(from: snapshot)
    }

    private nonisolated static func fetchClaudeUsage(keepCLISessionsAlive: Bool) async throws -> ClaudeUsageSnapshot {
        let browser = BrowserDetection()
        let environment = ProcessInfo.processInfo.environment

        // Only use OAuth when credentials are already readable without a Keychain dialog.
        if ClaudeOAuthCredentialsStore.hasCachedCredentials(environment: environment) {
            do {
                return try await ClaudeUsageFetcher(
                    browserDetection: browser,
                    environment: environment,
                    runtime: .app,
                    dataSource: .oauth,
                    allowBackgroundDelegatedRefresh: false,
                    keepCLISessionsAlive: keepCLISessionsAlive).loadLatestUsage()
            } catch {
                // Fall through to CLI.
            }
        }

        return try await ClaudeUsageFetcher(
            browserDetection: browser,
            environment: environment,
            runtime: .app,
            dataSource: .cli,
            allowBackgroundDelegatedRefresh: false,
            keepCLISessionsAlive: keepCLISessionsAlive).loadLatestUsage()
    }
}

/// Maps the rich Claude snapshot onto the provider-neutral limits model.
enum ClaudeLimitAdapter {
    static let sessionID = "claude-session"
    static let weeklyID = "claude-weekly"

    static func limits(from snapshot: ClaudeUsageSnapshot) -> ProviderLimitSnapshot {
        var windows = [NamedRateWindow(
            id: self.sessionID,
            title: snapshot.primaryWindowKind == .spendLimit ? "Spend limit" : "Session",
            window: snapshot.primary)]
        if let weekly = snapshot.secondary {
            windows.append(NamedRateWindow(id: self.weeklyID, title: "Weekly", window: weekly))
        }
        windows.append(contentsOf: snapshot.extraRateWindows)
        if let opus = snapshot.opus,
           !snapshot.extraRateWindows.contains(where: {
               $0.id.contains("sonnet") || $0.title.lowercased().contains("sonnet")
           })
        {
            windows.append(NamedRateWindow(id: "claude-sonnet", title: "Sonnet", window: opus))
        }
        return ProviderLimitSnapshot(
            windows: windows,
            accountEmail: snapshot.accountEmail,
            planName: snapshot.loginMethod.map { UsageFormatter.cleanPlanName($0) },
            notes: [],
            updatedAt: snapshot.updatedAt)
    }
}
