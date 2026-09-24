import AppKit
import ClaudeBarCore
import SwiftUI

/// Everything shown when the status item is clicked: provider tabs, plan limits,
/// estimated spend and a labelled token-usage chart.
struct PopoverView: View {
    let store: UsageStore
    /// Called when a preference that affects the status item changes.
    let onPreferencesChanged: () -> Void

    @State private var selected: AIProvider = AppPreferences.selectedTab
    @State private var metric: ChartMetric = .tokens
    @State private var range: ChartRange = .month
    @State private var menuBarProvider: AIProvider = AppPreferences.menuBarProvider
    @State private var iconStyle: MenuBarIconStyle = MenuBarIconStylePreference.current

    static let width: CGFloat = 380

    var body: some View {
        let providers = self.store.enabledProviders
        let provider = providers.contains(self.selected) ? self.selected : (providers.first ?? .claude)
        let state = self.store.state(for: provider)

        VStack(alignment: .leading, spacing: 0) {
            if providers.count > 1 {
                self.tabs(providers, selected: provider)
                    .padding(.bottom, 12)
            }
            ProviderHeaderView(provider: provider, state: state)
            Divider().padding(.vertical, 10)
            LimitsSectionView(provider: provider, state: state)

            if let history = state.history {
                Divider().padding(.vertical, 10)
                SpendTilesView(history: history)
                    .padding(.bottom, 12)
                TokenUsageChartView(
                    history: history,
                    accent: provider.accentColor,
                    footnote: "\(provider.historyFootnote) You pay a flat subscription; "
                        + "this is what the same usage would cost on the API.",
                    metric: self.$metric,
                    range: self.$range)
            } else if let error = state.historyError {
                Divider().padding(.vertical, 10)
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
            } else if state.isRefreshingHistory {
                Divider().padding(.vertical, 10)
                Text("Scanning token usage…")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
            }

            Divider().padding(.top, 12).padding(.bottom, 8)
            self.footer(provider: provider)
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
    }

    // MARK: Tabs

    private func tabs(_ providers: [AIProvider], selected: AIProvider) -> some View {
        HStack(spacing: 6) {
            ForEach(providers) { provider in
                let isSelected = provider == selected
                let remaining = self.store.state(for: provider).limits?.windows.first?.window.remainingPercent
                Button {
                    self.selected = provider
                    AppPreferences.selectedTab = provider
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(provider.accentColor)
                            .frame(width: 7, height: 7)
                        Text(provider.displayName)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        if let remaining {
                            Text("\(Int(remaining.rounded()))%")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(provider.displayName) tab")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    // MARK: Footer

    private func footer(provider: AIProvider) -> some View {
        HStack(spacing: 12) {
            Button("Dashboard") { NSWorkspace.shared.open(provider.dashboardURL) }
            Button("Status") { NSWorkspace.shared.open(provider.statusPageURL) }
            Spacer(minLength: 8)
            Button {
                self.store.refreshAll(userInitiated: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh all providers")
            .keyboardShortcut("r")
            self.settingsMenu
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Menu Bar Shows", selection: self.$menuBarProvider) {
                ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
            }
            .onChange(of: self.menuBarProvider) { _, newValue in
                AppPreferences.menuBarProvider = newValue
                self.onPreferencesChanged()
            }

            Picker("Menu Bar Icon", selection: self.$iconStyle) {
                ForEach(MenuBarIconStyle.allCases, id: \.self) { Text($0.menuTitle).tag($0) }
            }
            .onChange(of: self.iconStyle) { _, newValue in
                MenuBarIconStylePreference.set(newValue)
                self.onPreferencesChanged()
            }

            Section("Providers") {
                ForEach(AIProvider.allCases) { provider in
                    Toggle(provider.displayName, isOn: Binding(
                        get: { self.store.isEnabled(provider) },
                        set: { self.store.setEnabled(provider, $0) }))
                }
            }

            Divider()
            Button("Quit ClaudeBar") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
    }
}

// MARK: - Header

struct ProviderHeaderView: View {
    let provider: AIProvider
    let state: UsageStore.ProviderState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if let email = self.state.limits?.accountEmail, !email.isEmpty {
                    Text(email)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(self.statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                Spacer(minLength: 8)
                if let plan = self.state.limits?.planName, !plan.isEmpty {
                    Text(plan)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }

    private var statusLine: String {
        var parts: [String] = []
        if let updated = self.state.limits?.updatedAt {
            parts.append(UsageFormatter.updatedString(from: updated))
        }
        if self.state.isRefreshing {
            parts.append("Refreshing…")
        } else if self.state.limitsAreStale {
            parts.append("cached")
        }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }
}

// MARK: - Limits

struct LimitsSectionView: View {
    let provider: AIProvider
    let state: UsageStore.ProviderState

    var body: some View {
        let rows = self.state.limits.map { LimitRowModel.rows(provider: self.provider, limits: $0) } ?? []
        VStack(alignment: .leading, spacing: 0) {
            if let error = self.state.limitsError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(self.state.limits == nil ? Color.red.opacity(0.9) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, rows.isEmpty ? 0 : 10)
            } else if rows.isEmpty {
                Text(self.state.isRefreshingLimits ? "Loading limits…" : "No plan limits reported.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
            }

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                LimitRowView(row: row, accent: self.provider.accentColor)
                if index < rows.count - 1 {
                    Spacer().frame(height: 12)
                }
            }

            ForEach(self.state.limits?.notes ?? [], id: \.self) { note in
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                    .padding(.top, 6)
            }
        }
    }
}

struct LimitRowModel: Identifiable {
    let id: String
    let title: String
    let remainingPercent: Double
    let resetText: String?
    let paceLeft: String?
    let paceRight: String?
    let paceMarkerPercent: Double?
    let footnotes: [String]

    static func rows(provider: AIProvider, limits: ProviderLimitSnapshot, now: Date = .init()) -> [LimitRowModel] {
        let session = limits.windows.first { $0.id == ClaudeLimitAdapter.sessionID }?.window
        return limits.windows.filter(\.usageKnown).map { named in
            let window = named.window
            let pace = UsagePace.weekly(
                window: window,
                now: now,
                defaultWindowMinutes: window.windowMinutes ?? 10080)
            let detail = pace.map { UsagePaceText.weeklyDetail(pace: $0) }
            // Pace wording only reads well for day-plus windows; short windows just get the marker.
            let showsPaceText = (window.windowMinutes ?? 0) >= 24 * 60
            var footnotes: [String] = []
            if provider == .claude, named.id == ClaudeLimitAdapter.weeklyID, let session,
               let equivalent = UsagePaceText.sessionEquivalentDetail(session: session, weekly: window, now: now)
            {
                footnotes = [equivalent.verdictText, equivalent.numberText]
            }
            return LimitRowModel(
                id: named.id,
                title: named.title,
                remainingPercent: window.remainingPercent,
                resetText: UsageFormatter.resetLine(for: window, style: .countdown, now: now),
                paceLeft: showsPaceText ? detail?.leftLabel : nil,
                paceRight: showsPaceText ? detail?.rightLabel : nil,
                paceMarkerPercent: detail.map { 100 - $0.expectedUsedPercent },
                footnotes: footnotes)
        }
    }
}

struct LimitRowView: View {
    let row: LimitRowModel
    let accent: Color

    var body: some View {
        let remaining = min(100, max(0, self.row.remainingPercent))
        VStack(alignment: .leading, spacing: 5) {
            Text(self.row.title)
                .font(.system(size: 12, weight: .semibold))
            SegmentedBar(remaining: remaining, paceMarker: self.row.paceMarkerPercent, accent: self.accent)
                .accessibilityLabel("\(self.row.title): \(Int(remaining.rounded())) percent left")
            HStack(alignment: .firstTextBaseline) {
                Text(UsageFormatter.percentText(remaining, suffix: "left"))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.secondary)
                Spacer(minLength: 8)
                if let reset = self.row.resetText {
                    Text(reset)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                }
            }
            if self.row.paceLeft != nil || self.row.paceRight != nil {
                HStack(alignment: .firstTextBaseline) {
                    Text(self.row.paceLeft ?? "")
                    Spacer(minLength: 8)
                    Text(self.row.paceRight ?? "")
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary)
            }
            ForEach(self.row.footnotes, id: \.self) { line in
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Five-segment remaining bar with an optional pace marker (where you "should" be).
struct SegmentedBar: View {
    let remaining: Double
    let paceMarker: Double?
    let accent: Color

    private let segments = 5
    private let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let totalGap = self.gap * CGFloat(self.segments - 1)
            let segmentWidth = max(0, (geo.size.width - totalGap) / CGFloat(self.segments))
            let fill = self.remaining / 100
            ZStack(alignment: .leading) {
                HStack(spacing: self.gap) {
                    ForEach(0..<self.segments, id: \.self) { index in
                        let start = Double(index) / Double(self.segments)
                        let end = Double(index + 1) / Double(self.segments)
                        let local = max(0, min(1, (fill - start) / (end - start)))
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.14))
                            Capsule().fill(self.accent).frame(width: segmentWidth * local)
                        }
                        .frame(width: segmentWidth, height: 7)
                    }
                }
                if let paceMarker {
                    let x = geo.size.width * CGFloat(min(100, max(0, paceMarker)) / 100)
                    Capsule()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 2, height: 11)
                        .offset(x: max(0, x - 1), y: 0)
                        .help("Even-pace marker")
                }
            }
        }
        .frame(height: 11)
    }
}

// MARK: - Spend tiles

/// Headline estimated spend (API list price) for today, 7 and 30 days.
struct SpendTilesView: View {
    let history: TokenUsageHistory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            self.tile(title: "Today", summary: self.history.summary(last: 1))
            self.tile(title: "7 days", summary: self.history.summary(last: 7))
            self.tile(title: "30 days", summary: self.history.summary(last: 30))
        }
    }

    private func tile(title: String, summary: TokenUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(title) · est. API cost")
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(summary.costUSD.map { UsageFormatter.usdString($0) } ?? "—")
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
            Text("\(UsageFormatter.tokenCountString(summary.totalTokens)) tokens")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
