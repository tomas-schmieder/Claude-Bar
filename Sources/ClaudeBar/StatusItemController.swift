import AppKit
import ClaudeBarCore
import SwiftUI

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private var snapshot: ClaudeUsageSnapshot?
    private var tokenSnapshot: CostUsageTokenSnapshot?
    private var lastError: String?
    private var isRefreshing = false
    private var refreshTask: Task<Void, Never>?
    private var costTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var keepCLISessionsAlive = false
    private var isIconStale = false

    private let cardWidth: CGFloat = 300
    private let refreshInterval: Duration = .seconds(5 * 60)

    init() {
        // Never show interactive Keychain UI for "Claude Code-credentials".
        // Usage comes from Claude CLI / Web / silent OAuth cache instead.
        ClaudeOAuthKeychainPromptPreference.setStoredMode(.never)

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem.button?.imagePosition = .imageOnly
        self.statusItem.button?.toolTip = "ClaudeBar"
        self.statusItem.button?.setAccessibilityTitle("ClaudeBar")

        if let cached = UsageSnapshotCache.load() {
            self.snapshot = cached
            self.applyIcon(from: cached, stale: true)
        } else {
            self.applyPlaceholderIcon()
        }
        self.rebuildMenu()
    }

    func start() {
        // Restore cached quotas immediately; refresh live data + cost in parallel.
        self.refreshCostInBackground(force: false)
        self.refresh(userInitiated: true)
        self.timerTask?.cancel()
        self.timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5 * 60))
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self?.refresh(userInitiated: false)
                }
            }
        }
    }

    func stop() {
        self.refreshTask?.cancel()
        self.costTask?.cancel()
        self.timerTask?.cancel()
    }

    @objc func refreshMenuAction(_ sender: Any?) {
        self.refresh(userInitiated: true)
    }

    @objc func openUsageDashboard(_ sender: Any?) {
        self.openURL("https://claude.ai/settings/usage")
    }

    @objc func openStatusPage(_ sender: Any?) {
        self.openURL("https://status.claude.com/")
    }

    @objc func openBilling(_ sender: Any?) {
        self.openURL("https://console.anthropic.com/settings/billing")
    }

    @objc func selectMenuBarIconStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = MenuBarIconStyle(rawValue: raw)
        else { return }
        MenuBarIconStylePreference.set(style)
        self.reapplyCurrentIcon()
        self.rebuildMenu()
    }

    private func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    private func refresh(userInitiated: Bool) {
        self.refreshTask?.cancel()
        self.isRefreshing = true
        self.lastError = nil
        self.rebuildMenu()

        let keepAlive = self.keepCLISessionsAlive
        self.refreshTask = Task { [weak self] in
            let interaction: ProviderInteraction = userInitiated ? .userInitiated : .background
            do {
                let snapshot = try await ProviderInteractionContext.$current.withValue(interaction) {
                    try await Self.fetchUsage(keepCLISessionsAlive: keepAlive)
                }
                await MainActor.run {
                    guard let self else { return }
                    self.snapshot = snapshot
                    self.lastError = nil
                    self.isRefreshing = false
                    // After a successful path that may have used CLI, keep it warm.
                    self.keepCLISessionsAlive = true
                    UsageSnapshotCache.save(snapshot)
                    self.applyIcon(from: snapshot)
                    self.rebuildMenu()
                    self.refreshCostInBackground(force: userInitiated)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.lastError = error.localizedDescription
                    self.isRefreshing = false
                    if let snapshot = self.snapshot {
                        self.applyIcon(from: snapshot, stale: true)
                    } else {
                        self.applyPlaceholderIcon(stale: true)
                    }
                    self.rebuildMenu()
                }
            }
        }
    }

    /// Prefer silent OAuth cache when available; otherwise CLI (no Keychain prompts).
    private static func fetchUsage(keepCLISessionsAlive: Bool) async throws -> ClaudeUsageSnapshot {
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

    private func refreshCostInBackground(force: Bool) {
        self.costTask?.cancel()
        self.costTask = Task { [weak self] in
            do {
                let token = try await CostUsageFetcher.loadClaudeTokenSnapshot(
                    forceRefresh: force)
                await MainActor.run {
                    guard let self else { return }
                    self.tokenSnapshot = token
                    self.rebuildMenu()
                }
            } catch {
                // Cost is best-effort; keep quota UI working.
            }
        }
    }

    private func applyPlaceholderIcon(stale: Bool = false) {
        self.isIconStale = stale
        self.statusItem.button?.image = IconRenderer.makeClaudeIcon(
            sessionRemaining: nil,
            weeklyRemaining: nil,
            stale: stale)
        self.statusItem.button?.title = ""
    }

    private func applyIcon(from snapshot: ClaudeUsageSnapshot, stale: Bool = false) {
        self.isIconStale = stale
        self.statusItem.button?.image = IconRenderer.makeClaudeIcon(
            sessionRemaining: snapshot.primary.remainingPercent,
            weeklyRemaining: snapshot.secondary?.remainingPercent,
            stale: stale)
        self.statusItem.button?.title = ""

        let session = Int(snapshot.primary.remainingPercent.rounded())
        if let weekly = snapshot.secondary {
            let weeklyLeft = Int(weekly.remainingPercent.rounded())
            self.statusItem.button?.toolTip =
                "Claude · Session \(session)% left · Weekly \(weeklyLeft)% left"
        } else {
            self.statusItem.button?.toolTip = "Claude · Session \(session)% left"
        }
    }

    private func reapplyCurrentIcon() {
        if let snapshot = self.snapshot {
            self.applyIcon(from: snapshot, stale: self.isIconStale)
        } else {
            self.applyPlaceholderIcon(stale: self.isIconStale)
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(self.makeCardItem())
        menu.addItem(.separator())

        for (title, action) in [
            ("Usage Dashboard", #selector(openUsageDashboard(_:))),
            ("Status Page", #selector(openStatusPage(_:))),
            ("Billing", #selector(openBilling(_:))),
        ] as [(String, Selector)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            menu.addItem(item)
        }

        menu.addItem(self.makeMenuBarIconStyleItem())
        menu.addItem(.separator())

        let refresh = NSMenuItem(
            title: self.isRefreshing ? "Refreshing…" : "Refresh",
            action: #selector(refreshMenuAction(_:)),
            keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = !self.isRefreshing
        menu.addItem(refresh)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit ClaudeBar",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        quit.isEnabled = true
        menu.addItem(quit)

        self.statusItem.menu = menu
    }

    private func makeMenuBarIconStyleItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Menu Bar Icon", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = MenuBarIconStylePreference.current
        for style in MenuBarIconStyle.allCases {
            let styleItem = NSMenuItem(
                title: style.menuTitle,
                action: #selector(selectMenuBarIconStyle(_:)),
                keyEquivalent: "")
            styleItem.target = self
            styleItem.representedObject = style.rawValue
            styleItem.state = style == current ? .on : .off
            styleItem.isEnabled = true
            submenu.addItem(styleItem)
        }
        item.submenu = submenu
        item.isEnabled = true
        return item
    }

    private func makeCardItem() -> NSMenuItem {
        let card: ClaudeUsageCardView
        if let snapshot = self.snapshot {
            card = .from(
                snapshot: snapshot,
                tokenSnapshot: self.tokenSnapshot,
                isRefreshing: self.isRefreshing,
                width: self.cardWidth)
        } else if let lastError = self.lastError {
            card = .error(lastError, width: self.cardWidth)
        } else {
            card = .loading(width: self.cardWidth)
        }

        let hosting = NSHostingView(
            rootView: card.frame(width: self.cardWidth, alignment: .leading))
        let size = hosting.fittingSize
        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: self.cardWidth,
            height: max(size.height, 100))

        let item = NSMenuItem()
        item.isEnabled = false
        item.view = hosting
        return item
    }
}
