import Charts
import ClaudeBarCore
import SwiftUI

enum ChartMetric: String, CaseIterable, Identifiable {
    case tokens
    case cost

    var id: String {
        self.rawValue
    }

    var title: String {
        switch self {
        case .tokens: "Tokens"
        case .cost: "Est. cost"
        }
    }
}

enum ChartRange: Int, CaseIterable, Identifiable {
    case week = 7
    case twoWeeks = 14
    case month = 30

    var id: Int {
        self.rawValue
    }

    var title: String {
        "\(self.rawValue)D"
    }

    /// Days between x-axis labels, so labels never collide at popover width.
    var labelStride: Int {
        switch self {
        case .week: 1
        case .twoWeeks: 2
        case .month: 6
        }
    }
}

/// Labelled daily bar chart of token usage (or estimated API cost) for one provider,
/// with a hover readout of the day's breakdown above the plot.
struct TokenUsageChartView: View {
    let history: TokenUsageHistory
    let accent: Color
    let footnote: String

    @Binding var metric: ChartMetric
    @Binding var range: ChartRange
    @State private var hoveredDate: Date?

    private struct Point: Identifiable {
        let day: TokenUsageDay
        let date: Date
        let value: Double

        var id: String {
            self.day.dayKey
        }
    }

    var body: some View {
        let days = self.history.filledDays(last: self.range.rawValue)
        let points = days.compactMap { day -> Point? in
            guard let date = day.date() else { return nil }
            let value = self.metric == .tokens ? Double(day.totalTokens) : (day.costUSD ?? 0)
            return Point(day: day, date: date, value: value)
        }
        let hovered = self.hoveredDate.flatMap { date in
            points.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
        }
        let peak = points.max { $0.value < $1.value }.flatMap { $0.value > 0 ? $0 : nil }

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Token usage")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Picker("Metric", selection: self.$metric) {
                    ForEach(ChartMetric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                Picker("Range", selection: self.$range) {
                    ForEach(ChartRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
            }

            self.readout(hovered: hovered?.day, days: days)

            Chart(points) { point in
                BarMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value(self.metric.title, point.value),
                    width: .ratio(0.72))
                    .cornerRadius(3)
                    .foregroundStyle(self.accent.opacity(hovered == nil || hovered?.id == point.id ? 1 : 0.35))
                    .annotation(position: .top, spacing: 2) {
                        // Selective direct label: only the peak bar carries its value.
                        if point.id == peak?.id, hovered == nil {
                            Text(self.format(point.value, compact: true))
                                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Color.secondary)
                        }
                    }
            }
            .chartXSelection(value: self.$hoveredDate)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(self.format(number, compact: true))
                                .font(.system(size: 9).monospacedDigit())
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: self.range.labelStride)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                        .font(.system(size: 9))
                }
            }
            .chartYScale(domain: 0...max(peak?.value ?? 0, self.metric == .tokens ? 1000 : 0.01) * 1.18)
            .frame(height: 130)
            .accessibilityLabel("Daily \(self.metric.title.lowercased()) for the last \(self.range.rawValue) days")

            Text(self.footnote)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One line above the plot: the hovered day's numbers, or the range total when not hovering.
    private func readout(hovered: TokenUsageDay?, days: [TokenUsageDay]) -> some View {
        let summary = hovered.map { TokenUsageSummary(days: [$0]) } ?? TokenUsageSummary(days: days)
        let title: String = if let hovered, let date = hovered.date() {
            date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        } else {
            "Last \(self.range.rawValue) days"
        }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text("·").foregroundStyle(Color.secondary)
                Text("\(UsageFormatter.tokenCountString(summary.totalTokens)) tokens")
                    .font(.system(size: 11).monospacedDigit())
                Text("·").foregroundStyle(Color.secondary)
                Text(summary.costUSD.map { "≈ \(UsageFormatter.usdString($0))" } ?? "cost n/a")
                    .font(.system(size: 11).monospacedDigit())
            }
            Text(TokenBreakdownText.make(summary))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func format(_ value: Double, compact: Bool) -> String {
        switch self.metric {
        case .tokens:
            return UsageFormatter.tokenCountString(Int(value.rounded()))
        case .cost:
            if compact, value >= 100 {
                return "$\(Int(value.rounded()))"
            }
            return UsageFormatter.usdString(value)
        }
    }
}

enum TokenBreakdownText {
    static func make(_ summary: TokenUsageSummary) -> String {
        [
            "In \(UsageFormatter.tokenCountString(summary.inputTokens))",
            "Out \(UsageFormatter.tokenCountString(summary.outputTokens))",
            "Cache read \(UsageFormatter.tokenCountString(summary.cacheReadTokens))",
            "Cache write \(UsageFormatter.tokenCountString(summary.cacheWriteTokens))",
        ].joined(separator: " · ")
    }
}
