import ClaudeBarCore
import SwiftUI

/// CodexBar-style Claude usage card: header, paced bars, extras, cost grid, daily chart.
struct ClaudeUsageCardView: View {
    struct Metric: Identifiable {
        let id: String
        let title: String
        let remainingPercent: Double
        let resetText: String?
        let paceLeft: String?
        let paceRight: String?
        let paceMarkerPercent: Double?
        let equivalentVerdict: String?
        let equivalentNumber: String?
    }

    struct CostStats {
        let todayCost: String?
        let monthCost: String?
        let latestTokens: String?
        let monthTokens: String?
        let daily: [(id: String, cost: Double)]
        let peakLabel: String?
        let peakIndex: Int?
        let topModel: String?
        let footnote: String?
    }

    let providerName: String
    let email: String?
    let planText: String?
    let updatedText: String?
    let subtitle: String?
    let isError: Bool
    let isRefreshing: Bool
    let metrics: [Metric]
    let cost: CostStats?
    let width: CGFloat

    private let accent = Color(red: 0.80, green: 0.47, blue: 0.35)
    private let track = Color.primary.opacity(0.14)
    private let segmentGap: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            Divider()
                .padding(.top, 8)
                .padding(.bottom, 10)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(self.isError ? Color.red.opacity(0.9) : Color.secondary)
                    .padding(.bottom, self.metrics.isEmpty ? 0 : 10)
            }

            ForEach(Array(self.metrics.enumerated()), id: \.element.id) { index, metric in
                self.metricBlock(metric)
                if index < self.metrics.count - 1 {
                    Spacer().frame(height: 14)
                }
            }

            if let cost, self.hasCostContent(cost) {
                Spacer().frame(height: 14)
                self.costGrid(cost)
                if !cost.daily.isEmpty {
                    Spacer().frame(height: 12)
                    self.costChart(cost)
                }
                if let topModel = cost.topModel {
                    Text("Top model: \(topModel)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                        .padding(.top, 8)
                }
                if let footnote = cost.footnote {
                    Text(footnote)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary.opacity(0.85))
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: self.width, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.providerName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if let email, !email.isEmpty {
                    Text(email)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    if let updatedText {
                        Text(updatedText)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondary)
                    }
                    if self.isRefreshing {
                        Text("Refreshing…")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let planText, !planText.isEmpty {
                    Text(planText)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }

    private func metricBlock(_ metric: Metric) -> some View {
        let clamped = min(100, max(0, metric.remainingPercent))
        return VStack(alignment: .leading, spacing: 5) {
            Text(metric.title)
                .font(.system(size: 12, weight: .semibold))

            self.segmentedBar(
                remaining: clamped,
                paceMarker: metric.paceMarkerPercent)

            HStack(alignment: .firstTextBaseline) {
                Text(UsageFormatter.percentText(clamped, suffix: "left"))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.secondary)
                Spacer(minLength: 8)
                if let resetText = metric.resetText, !resetText.isEmpty {
                    Text(resetText)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                }
            }

            if metric.paceLeft != nil || metric.paceRight != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let paceLeft = metric.paceLeft {
                        Text(paceLeft)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer(minLength: 8)
                    if let paceRight = metric.paceRight {
                        Text(paceRight)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondary)
                    }
                }
            }

            if let verdict = metric.equivalentVerdict {
                Text(verdict)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let number = metric.equivalentNumber {
                Text(number)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func segmentedBar(remaining: Double, paceMarker: Double?) -> some View {
        let segments = 5
        let fillFraction = remaining / 100
        return GeometryReader { geo in
            let totalGap = self.segmentGap * CGFloat(segments - 1)
            let segWidth = max(0, (geo.size.width - totalGap) / CGFloat(segments))
            ZStack(alignment: .leading) {
                HStack(spacing: self.segmentGap) {
                    ForEach(0..<segments, id: \.self) { index in
                        let start = Double(index) / Double(segments)
                        let end = Double(index + 1) / Double(segments)
                        let localFill = max(0, min(1, (fillFraction - start) / (end - start)))
                        ZStack(alignment: .leading) {
                            Capsule().fill(self.track)
                            Capsule()
                                .fill(self.accent)
                                .frame(width: segWidth * localFill)
                        }
                        .frame(width: segWidth, height: 7)
                    }
                }
                if let paceMarker {
                    let x = geo.size.width * CGFloat(min(100, max(0, paceMarker)) / 100)
                    Capsule()
                        .fill(Color.green.opacity(0.85))
                        .frame(width: 3, height: 9)
                        .offset(x: max(0, x - 1.5), y: -1)
                }
            }
        }
        .frame(height: 9)
    }

    private func costGrid(_ cost: CostStats) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                self.costCell(title: "Today", value: cost.todayCost)
                self.costCell(title: "Latest tokens", value: cost.latestTokens)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                self.costCell(title: "30d cost", value: cost.monthCost)
                self.costCell(title: "30d tokens", value: cost.monthTokens)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func costCell(title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary)
            Text(value ?? "—")
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.primary)
        }
    }

    private func costChart(_ cost: CostStats) -> some View {
        let maxCost = max(cost.daily.map(\.cost).max() ?? 1, 1)
        return GeometryReader { geo in
            let barWidth = max(2, (geo.size.width - CGFloat(cost.daily.count - 1) * 2) / CGFloat(max(cost.daily.count, 1)))
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(cost.daily.enumerated()), id: \.offset) { index, day in
                    let height = max(2, geo.size.height * CGFloat(day.cost / maxCost))
                    ZStack(alignment: .top) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(self.accent.opacity(0.9))
                            .frame(width: barWidth, height: height)
                        if let peakIndex = cost.peakIndex, peakIndex == index, let peakLabel = cost.peakLabel {
                            Text(peakLabel)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.yellow)
                                .offset(y: -12)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .frame(height: 56)
        .padding(.top, 10)
    }

    private func hasCostContent(_ cost: CostStats) -> Bool {
        cost.todayCost != nil ||
            cost.monthCost != nil ||
            cost.latestTokens != nil ||
            cost.monthTokens != nil ||
            !cost.daily.isEmpty
    }
}

extension ClaudeUsageCardView {
    static func from(
        snapshot: ClaudeUsageSnapshot,
        tokenSnapshot: CostUsageTokenSnapshot? = nil,
        isRefreshing: Bool = false,
        width: CGFloat = 300,
        now: Date = .init()) -> ClaudeUsageCardView
    {
        var metrics: [Metric] = []

        let sessionPace = UsagePace.weekly(
            window: snapshot.primary,
            now: now,
            defaultWindowMinutes: snapshot.primary.windowMinutes ?? 300)
        let sessionDetail = sessionPace.map { UsagePaceText.weeklyDetail(pace: $0) }
        metrics.append(
            Metric(
                id: "session",
                title: "Session",
                remainingPercent: snapshot.primary.remainingPercent,
                resetText: UsageFormatter.resetLine(for: snapshot.primary, style: .countdown, now: now),
                paceLeft: nil,
                paceRight: nil,
                paceMarkerPercent: sessionDetail.map { 100 - $0.expectedUsedPercent },
                equivalentVerdict: nil,
                equivalentNumber: nil))

        if let weekly = snapshot.secondary {
            let weeklyPace = UsagePace.weekly(window: weekly, now: now)
            let detail = weeklyPace.map { UsagePaceText.weeklyDetail(pace: $0) }
            let equivalent = UsagePaceText.sessionEquivalentDetail(
                session: snapshot.primary,
                weekly: weekly,
                now: now)
            metrics.append(
                Metric(
                    id: "weekly",
                    title: "Weekly",
                    remainingPercent: weekly.remainingPercent,
                    resetText: UsageFormatter.resetLine(for: weekly, style: .countdown, now: now),
                    paceLeft: detail?.leftLabel,
                    paceRight: detail?.rightLabel,
                    paceMarkerPercent: detail.map { 100 - $0.expectedUsedPercent },
                    equivalentVerdict: equivalent?.verdictText,
                    equivalentNumber: equivalent?.numberText))
        }

        for extra in snapshot.extraRateWindows {
            metrics.append(
                Metric(
                    id: extra.id,
                    title: extra.title,
                    remainingPercent: extra.window.remainingPercent,
                    resetText: UsageFormatter.resetLine(for: extra.window, style: .countdown, now: now),
                    paceLeft: nil,
                    paceRight: nil,
                    paceMarkerPercent: nil,
                    equivalentVerdict: nil,
                    equivalentNumber: nil))
        }

        if let opus = snapshot.opus,
           !snapshot.extraRateWindows.contains(where: { $0.id.contains("sonnet") || $0.title.lowercased().contains("sonnet") })
        {
            metrics.append(
                Metric(
                    id: "opus",
                    title: "Sonnet",
                    remainingPercent: opus.remainingPercent,
                    resetText: UsageFormatter.resetLine(for: opus, style: .countdown, now: now),
                    paceLeft: nil,
                    paceRight: nil,
                    paceMarkerPercent: nil,
                    equivalentVerdict: nil,
                    equivalentNumber: nil))
        }

        let cost = tokenSnapshot.map(Self.makeCostStats)
        let plan = snapshot.loginMethod.map { UsageFormatter.cleanPlanName($0) }

        return ClaudeUsageCardView(
            providerName: "Claude",
            email: snapshot.accountEmail,
            planText: plan,
            updatedText: UsageFormatter.updatedString(from: snapshot.updatedAt, now: now),
            subtitle: nil,
            isError: false,
            isRefreshing: isRefreshing,
            metrics: metrics,
            cost: cost,
            width: width)
    }

    static func loading(width: CGFloat = 300) -> ClaudeUsageCardView {
        ClaudeUsageCardView(
            providerName: "Claude",
            email: nil,
            planText: nil,
            updatedText: nil,
            subtitle: "Refreshing…",
            isError: false,
            isRefreshing: true,
            metrics: [],
            cost: nil,
            width: width)
    }

    static func error(_ message: String, width: CGFloat = 300) -> ClaudeUsageCardView {
        ClaudeUsageCardView(
            providerName: "Claude",
            email: nil,
            planText: nil,
            updatedText: nil,
            subtitle: message,
            isError: true,
            isRefreshing: false,
            metrics: [],
            cost: nil,
            width: width)
    }

    private static func makeCostStats(_ token: CostUsageTokenSnapshot) -> CostStats {
        let daily: [(id: String, cost: Double)] = token.daily.compactMap { entry in
            guard let cost = entry.costUSD, cost > 0 else {
                return (id: entry.date, cost: 0)
            }
            return (id: entry.date, cost: cost)
        }
        let peak = daily.enumerated().max(by: { $0.element.cost < $1.element.cost })
        let peakLabel = peak.flatMap { $0.element.cost > 0 ? UsageFormatter.usdString($0.element.cost) : nil }

        var modelCosts: [String: Double] = [:]
        for entry in token.daily {
            for breakdown in entry.modelBreakdowns ?? [] {
                modelCosts[breakdown.modelName, default: 0] += breakdown.costUSD ?? 0
            }
        }
        let topModel = modelCosts.max(by: { $0.value < $1.value })?.key

        return CostStats(
            todayCost: token.sessionCostUSD.map { UsageFormatter.usdString($0) },
            monthCost: token.last30DaysCostUSD.map { UsageFormatter.usdString($0) },
            latestTokens: token.sessionTokens.map { UsageFormatter.tokenCountString($0) },
            monthTokens: token.last30DaysTokens.map { UsageFormatter.tokenCountString($0) },
            daily: daily,
            peakLabel: peakLabel,
            peakIndex: peak?.offset,
            topModel: topModel,
            footnote: "Estimated from local Claude logs at API rates; token totals approximate.")
    }
}
