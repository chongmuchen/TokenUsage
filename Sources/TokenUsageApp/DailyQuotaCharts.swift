import Charts
import SwiftUI
import TokenUsageCore

enum DailyQuotaMetric: String, CaseIterable, Identifiable {
    case startRemaining
    case dailyUsed
    case usdPerPercent

    var id: Self { self }

    var title: String {
        switch self {
        case .startRemaining: "每天开始剩余配额"
        case .dailyUsed: "当天累计使用配额"
        case .usdPerPercent: "1% 配额的平均使用额度"
        }
    }

    var axisTitle: String {
        self == .usdPerPercent ? "USD / 1%" : "%"
    }

    func value(for point: DailyQuotaPoint) -> Double? {
        switch self {
        case .startRemaining: point.startRemainingPercent
        case .dailyUsed: point.cumulativeUsedPercent
        case .usdPerPercent:
            point.usdPerPercent.map { NSDecimalNumber(decimal: $0).doubleValue }
        }
    }

    func formatted(_ value: Double) -> String {
        switch self {
        case .startRemaining, .dailyUsed:
            return String(format: "%.1f%%", value)
        case .usdPerPercent:
            let digits = value < 0.01 ? 6 : 4
            return "$\(value.formatted(.number.precision(.fractionLength(2...digits)))) / 1%"
        }
    }

    func axisLabel(_ value: Double) -> String {
        switch self {
        case .startRemaining, .dailyUsed:
            return String(format: "%.0f%%", value)
        case .usdPerPercent:
            return String(format: value < 0.01 ? "$%.4f" : "$%.2f", value)
        }
    }
}

struct DailyQuotaChart: View {
    let points: [DailyQuotaPoint]
    @Binding var metric: DailyQuotaMetric
    let homeName: String?

    var body: some View {
        TrendCard(
            title: "每日配额百分比",
            subtitle: subtitle
        ) {
            Picker("配额指标", selection: $metric) {
                Text("每天开始剩余配额").tag(DailyQuotaMetric.startRemaining)
                Text("当天累计使用配额").tag(DailyQuotaMetric.dailyUsed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)
        } content: {
            DailyQuotaPlot(points: points, metric: metric)
        }
    }

    private var subtitle: String {
        let source = homeName.map { "\($0) · " } ?? ""
        return source + "基于本地周配额观测估算；重置当天按配额段顺序显示多个点。"
    }
}

struct DailyQuotaUSDChart: View {
    let points: [DailyQuotaPoint]
    let homeName: String?

    var body: some View {
        TrendCard(
            title: "1% 配额的平均使用额度",
            subtitle: subtitle
        ) {
            EmptyView()
        } content: {
            DailyQuotaPlot(points: points, metric: .usdPerPercent)
        }
    }

    private var subtitle: String {
        let source = homeName.map { "\($0) · " } ?? ""
        return source + "同日 API USD 等价估算 ÷ 已用配额百分点；无有效分母时留空。"
    }
}

private struct DailyQuotaPlot: View {
    let points: [DailyQuotaPoint]
    let metric: DailyQuotaMetric

    @State private var hoveredPointID: String?
    @Environment(\.calendar) private var calendar

    private let hoverHitRadius: CGFloat = 22

    var body: some View {
        let values = chartValues

        Group {
            if values.isEmpty {
                ContentUnavailableView {
                    Label("没有配额观测", systemImage: "chart.xyaxis.line")
                } description: {
                    Text(emptyMessage)
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                Chart(values) { value in
                    LineMark(
                        x: .value("时间", value.plottedAt),
                        y: .value(metric.axisTitle, value.amount),
                        series: .value("连续观测区间", value.runID)
                    )
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.linear)

                    PointMark(
                        x: .value("时间", value.plottedAt),
                        y: .value(metric.axisTitle, value.amount)
                    )
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(values.count <= 45 ? 34 : 19)

                    if hoveredPointID == value.id {
                        PointMark(
                            x: .value("悬浮时间", value.plottedAt),
                            y: .value("悬浮数值", value.amount)
                        )
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(88)
                        .annotation(
                            position: .top,
                            spacing: 8,
                            overflowResolution: .init(
                                x: .fit(to: .chart),
                                y: .fit(to: .chart)
                            )
                        ) {
                            DailyQuotaTooltip(value: value, metric: metric)
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { axisValue in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let number = axisValue.as(Double.self) {
                                Text(metric.axisLabel(number))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: min(max(values.count, 2), 10))) { axisValue in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let date = axisValue.as(Date.self) {
                                if values.first?.point.day == values.last?.point.day {
                                    Text(date, format: .dateTime.hour().minute())
                                } else {
                                    Text(date, format: .dateTime.month(.twoDigits).day(.twoDigits))
                                }
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case let .active(location):
                                    hoveredPointID = closestPointID(
                                        to: location,
                                        values: values,
                                        proxy: proxy,
                                        geometry: geometry
                                    )
                                case .ended:
                                    hoveredPointID = nil
                                }
                            }
                    }
                }
                .frame(height: 240)
                .accessibilityLabel("\(metric.title)折线图")
            }
        }
        .onChange(of: metric) { _, _ in hoveredPointID = nil }
        .onChange(of: values.map(\.id)) { _, _ in hoveredPointID = nil }
    }

    private var emptyMessage: String {
        switch metric {
        case .startRemaining:
            "所选日期没有可用的日初配额估算；需要相邻的周配额观测。"
        case .dailyUsed:
            "所选日期没有可用的每日配额增量；可以同步历史报告后重试。"
        case .usdPerPercent:
            "所选日期缺少可用的配额增量或 API USD 价格估算。"
        }
    }

    private var chartValues: [DailyQuotaChartValue] {
        let valid = points.compactMap { point -> (point: DailyQuotaPoint, amount: Double)? in
            guard let amount = metric.value(for: point), amount.isFinite else { return nil }
            return (point, amount)
        }
        let countByDay = Dictionary(grouping: valid, by: { $0.point.day }).mapValues(\.count)
        var indexByDay: [Date: Int] = [:]
        var run = 0
        var previousDay: Date?
        return valid.map { point, amount in
            if let previousDay {
                let gap = calendar.dateComponents([.day], from: previousDay, to: point.day).day ?? 0
                if gap > 1 { run += 1 }
            }
            previousDay = point.day
            let index = indexByDay[point.day, default: 0]
            indexByDay[point.day] = index + 1
            let nextDay = calendar.date(byAdding: .day, value: 1, to: point.day)
                ?? point.day.addingTimeInterval(86_400)
            let fraction = Double(index + 1) / Double((countByDay[point.day] ?? 1) + 1)
            return DailyQuotaChartValue(
                point: point,
                amount: amount,
                plottedAt: point.day.addingTimeInterval(nextDay.timeIntervalSince(point.day) * fraction),
                runID: "quota-\(run)"
            )
        }
    }

    private func closestPointID(
        to location: CGPoint,
        values: [DailyQuotaChartValue],
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> String? {
        guard let anchor = proxy.plotFrame else { return nil }
        let frame = geometry[anchor]
        guard frame.contains(location) else { return nil }
        let plotLocation = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
        var nearest: (distance: CGFloat, id: String)?
        for value in values {
            guard let position = proxy.position(for: (x: value.plottedAt, y: value.amount)) else {
                continue
            }
            let distance = hypot(plotLocation.x - position.x, plotLocation.y - position.y)
            if distance < (nearest?.distance ?? .infinity) {
                nearest = (distance, value.id)
            }
        }
        guard let nearest, nearest.distance <= hoverHitRadius else { return nil }
        return nearest.id
    }
}

private struct DailyQuotaChartValue: Identifiable {
    let point: DailyQuotaPoint
    let amount: Double
    let plottedAt: Date
    let runID: String

    var id: String { point.id }
}

private struct DailyQuotaTooltip: View {
    let value: DailyQuotaChartValue
    let metric: DailyQuotaMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value.point.day.formatted(date: .numeric, time: .omitted))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if metric == .startRemaining {
                Text("起点 \(value.point.segmentStart.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("观测截至 \(value.point.observedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if value.point.isReset {
                Text("重置后配额段")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("\(value.point.isApproximate ? "≈ " : "")\(metric.formatted(value.amount))")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            if value.point.isApproximate {
                Text("依据相邻观测估算")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}
