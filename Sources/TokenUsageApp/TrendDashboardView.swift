import Charts
import SwiftUI
import TokenUsageCore

struct TrendDashboardView: View {
    let result: UsageTrendResult

    @State private var visibleTokenMetrics = Set(TrendTokenMetric.allCases)
    @State private var priceMetric: TrendPriceMetric = .credits

    var body: some View {
        if result.series.isEmpty {
            ContentUnavailableView {
                Label("没有符合条件的趋势数据", systemImage: "chart.xyaxis.line")
            } description: {
                Text("调整时间、模型、推理强度或速度筛选；旧报告也可以先同步为分钟级报告。")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if !result.warnings.isEmpty {
                        TrendWarningCard(warnings: result.warnings)
                    }

                    TrendTokenChart(
                        result: result,
                        visibleMetrics: $visibleTokenMetrics
                    )

                    TrendPriceChart(
                        result: result,
                        metric: $priceMetric
                    )

                    TrendSummaryTable(result: result)
                }
                .padding(16)
            }
        }
    }
}

enum TrendTokenMetric: String, CaseIterable, Identifiable, Hashable {
    case total
    case nonCachedInput
    case cachedInput
    case cacheWrite
    case output
    case reasoning

    var id: String { rawValue }

    var title: String {
        switch self {
        case .total: "Token 总量"
        case .nonCachedInput: "非缓存输入"
        case .cachedInput: "缓存读"
        case .cacheWrite: "缓存写"
        case .output: "输出"
        case .reasoning: "推理输出"
        }
    }

    func value(_ tokens: UsageTrendTokenBreakdown) -> Int64 {
        switch self {
        case .total: tokens.totalTokens
        case .nonCachedInput: tokens.nonCachedInputTokens
        case .cachedInput: tokens.cachedInputTokens
        case .cacheWrite: tokens.cacheWriteInputTokens
        case .output: tokens.outputTokens
        case .reasoning: tokens.reasoningOutputTokens
        }
    }

    var color: Color {
        switch self {
        case .total: .blue
        case .nonCachedInput: .orange
        case .cachedInput: .green
        case .cacheWrite: .purple
        case .output: .pink
        case .reasoning: .teal
        }
    }
}

enum TrendPriceMetric: String, CaseIterable, Identifiable {
    case credits
    case apiUSD

    var id: String { rawValue }
    var title: String { self == .credits ? "Credits 估算" : "API USD 等价" }
}

private struct TrendTokenChart: View {
    let result: UsageTrendResult
    @Binding var visibleMetrics: Set<TrendTokenMetric>

    var body: some View {
        let points = makeTokenPoints()
        let visibleMaximum = points.lazy.map(\.amount).max() ?? 0
        let plotMaximum = max(visibleMaximum, 1)
        let axisValues = makeYAxisValues(visibleMaximum: visibleMaximum)

        TrendCard(title: "每日 Token", subtitle: subtitle) {
            TrendTokenMetricToggleBar(visibleMetrics: $visibleMetrics)
        } content: {
            ZStack {
                Chart(points) { point in
                    LineMark(
                        x: .value("日期", point.day, unit: .day),
                        y: .value("Token", point.amount),
                        series: .value("曲线", point.lineID)
                    )
                    .foregroundStyle(point.metric.color)
                    .lineStyle(TrendConfigurationStyle.stroke(at: point.configurationIndex))
                    .interpolationMethod(.linear)

                    PointMark(
                        x: .value("日期", point.day, unit: .day),
                        y: .value("Token", point.amount)
                    )
                    .foregroundStyle(point.metric.color)
                    .symbol(TrendConfigurationStyle.symbol(at: point.configurationIndex))
                    .symbolSize(pointSize)
                }

                if visibleMetrics.isEmpty {
                    Text("点击上方指标以显示曲线")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .chartYScale(
                domain: 0 ... plotMaximum,
                range: .plotDimension(startPadding: 0, endPadding: 6)
            )
            .chartYAxis {
                AxisMarks(position: .leading, values: axisValues) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(tokenAxisLabel(number))
                                .monospacedDigit()
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: min(max(result.days.count, 2), 10))) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.twoDigits).day(.twoDigits))
                }
            }
            .chartLegend(.hidden)
            .frame(height: 260)
            .accessibilityLabel("按日 Token 分类曲线")

            if result.series.count > 1 {
                TrendConfigurationLineLegend(result: result)
            }
        }
    }

    private var subtitle: String {
        "颜色区分指标，线型区分配置；纵轴上限等于当前可见曲线的最大值。缓存写属于非缓存输入，推理属于输出。"
    }

    private func makeTokenPoints() -> [TrendTokenPlotPoint] {
        let metrics = TrendTokenMetric.allCases.filter(visibleMetrics.contains)
        return result.series.enumerated().flatMap { configurationIndex, series in
            metrics.flatMap { metric in
                series.points.map { point in
                    TrendTokenPlotPoint(
                        configurationIndex: configurationIndex,
                        metric: metric,
                        day: point.day,
                        amount: Double(metric.value(point.aggregate.tokens))
                    )
                }
            }
        }
    }

    private func makeYAxisValues(visibleMaximum: Double) -> [Double] {
        guard visibleMaximum > 0 else { return [0] }
        return [0, 0.25, 0.5, 0.75, 1].map { visibleMaximum * $0 }
    }

    private var pointSize: CGFloat {
        if result.series.count > 3 { return 5 }
        return result.days.count <= 45 ? 18 : 7
    }

    private func tokenAxisLabel(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let magnitude = abs(value)
        let divisor: Double
        let suffix: String
        switch magnitude {
        case 1_000_000_000...:
            divisor = 1_000_000_000
            suffix = "B"
        case 1_000_000...:
            divisor = 1_000_000
            suffix = "M"
        case 1_000...:
            divisor = 1_000
            suffix = "k"
        default:
            divisor = 1
            suffix = ""
        }
        return String(format: "%.2f%@", value / divisor, suffix)
    }
}

private struct TrendTokenPlotPoint: Identifiable {
    let configurationIndex: Int
    let metric: TrendTokenMetric
    let day: Date
    let amount: Double

    var lineID: String { "\(configurationIndex)#\(metric.rawValue)" }
    var id: String { "\(lineID)#\(day.timeIntervalSinceReferenceDate)" }
}

private struct TrendTokenMetricToggleBar: View {
    @Binding var visibleMetrics: Set<TrendTokenMetric>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(TrendTokenMetric.allCases) { metric in
                    let isVisible = visibleMetrics.contains(metric)
                    Button {
                        if isVisible {
                            visibleMetrics.remove(metric)
                        } else {
                            visibleMetrics.insert(metric)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(isVisible ? metric.color : Color.secondary.opacity(0.35))
                                .frame(width: 7, height: 7)
                            Text(metric.title)
                                .lineLimit(1)
                        }
                        .font(.caption.weight(isVisible ? .semibold : .regular))
                        .foregroundStyle(isVisible ? Color.primary : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            isVisible ? metric.color.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    isVisible ? metric.color.opacity(0.5) : Color.secondary.opacity(0.22),
                                    lineWidth: 0.7
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .help(isVisible ? "点击隐藏\(metric.title)" : "点击显示\(metric.title)")
                    .accessibilityLabel(metric.title)
                    .accessibilityValue(isVisible ? "已显示" : "已隐藏")
                }
            }
            .padding(1)
        }
        .frame(maxWidth: 780)
    }
}

private struct TrendConfigurationLineLegend: View {
    let result: UsageTrendResult

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Text("线型")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(result.series.enumerated()), id: \.element.id) { index, series in
                    HStack(spacing: 5) {
                        ZStack {
                            Canvas { context, size in
                                var path = Path()
                                path.move(to: CGPoint(x: 0, y: size.height / 2))
                                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                                context.stroke(
                                    path,
                                    with: .color(.secondary),
                                    style: TrendConfigurationStyle.stroke(at: index)
                                )
                            }
                            TrendConfigurationStyle.symbol(at: index)
                                .fill(.secondary)
                                .frame(width: 6, height: 6)
                        }
                        .frame(width: 26, height: 8)
                        Text(series.name)
                            .lineLimit(1)
                    }
                    .font(.caption)
                }
            }
        }
        .accessibilityLabel("配置线型图例")
    }
}

private enum TrendConfigurationStyle {
    private static let dashPatterns: [[CGFloat]] = [
        [], [8, 4], [3, 3], [12, 4, 3, 4], [1, 3], [10, 3, 1, 3],
        [14, 3], [5, 2], [2, 2, 8, 2]
    ]

    static func stroke(at index: Int) -> StrokeStyle {
        StrokeStyle(lineWidth: 1.9, dash: dashPatterns[index % dashPatterns.count])
    }

    static func symbol(at index: Int) -> BasicChartSymbolShape {
        switch (index / dashPatterns.count) % 8 {
        case 0: .circle
        case 1: .square
        case 2: .triangle
        case 3: .diamond
        case 4: .pentagon
        case 5: .plus
        case 6: .cross
        default: .asterisk
        }
    }
}

private struct TrendPriceChart: View {
    let result: UsageTrendResult
    @Binding var metric: TrendPriceMetric

    var body: some View {
        TrendCard(
            title: "每日价格",
            subtitle: "公开价估算；Credits 与 API USD 是两种口径，不应相加。"
        ) {
            Picker("价格指标", selection: $metric) {
                ForEach(TrendPriceMetric.allCases) { metric in
                    Text(metric.title).tag(metric)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 250)
        } content: {
            Chart(pricePoints) { point in
                LineMark(
                    x: .value("日期", point.day, unit: .day),
                    y: .value(metric.title, point.amount),
                    series: .value("连续定价区间", point.runID)
                )
                .foregroundStyle(by: .value("曲线", point.seriesName))
                .interpolationMethod(.linear)

                PointMark(
                    x: .value("日期", point.day, unit: .day),
                    y: .value(metric.title, point.amount)
                )
                .foregroundStyle(by: .value("曲线", point.seriesName))
                .symbolSize(result.days.count <= 45 ? 22 : 9)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(priceAxis(number))
                                .monospacedDigit()
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: min(max(result.days.count, 2), 10))) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.twoDigits).day(.twoDigits))
                }
            }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
            .chartForegroundStyleScale(
                domain: result.series.map(\.name),
                range: result.series.indices.map { TrendSeriesPalette.color(at: $0) }
            )
            .chartLegend(result.series.count <= 6 ? .visible : .hidden)
            .frame(height: 240)
            .accessibilityLabel("按日\(metric.title)曲线")
        }
    }

    private func price(_ aggregate: UsageTrendAggregate) -> Decimal? {
        metric == .credits ? aggregate.credits.amount : aggregate.apiUSD.amount
    }

    private func priceAxis(_ value: Double) -> String {
        metric == .credits
            ? String(format: "%.2f cr", value)
            : String(format: "$%.2f", value)
    }

    private var pricePoints: [TrendPricePoint] {
        result.series.flatMap { series in
            var run = 0
            var previousWasPriced = false
            return series.points.compactMap { point -> TrendPricePoint? in
                guard let amount = price(point.aggregate) else {
                    previousWasPriced = false
                    return nil
                }
                if !previousWasPriced { run += 1 }
                previousWasPriced = true
                return TrendPricePoint(
                    seriesName: series.name,
                    runID: "\(series.name)#\(run)",
                    day: point.day,
                    amount: decimalDouble(amount)
                )
            }
        }
    }
}

private struct TrendPricePoint: Identifiable {
    let seriesName: String
    let runID: String
    let day: Date
    let amount: Double

    var id: String { "\(runID)#\(day.timeIntervalSinceReferenceDate)" }
}

private struct TrendCard<Accessory: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                accessory
            }
            content
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
        }
    }
}

private struct TrendWarningCard: View {
    let warnings: [String]
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(warnings.prefix(50)), id: \.self) { warning in
                    Text("• \(warning)")
                }
                if warnings.count > 50 {
                    Text("另有 \(warnings.count - 50) 条同类提示未展开显示。")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 5)
        } label: {
            Label(
                "趋势完整性提示（\(warnings.count)）",
                systemImage: "exclamationmark.triangle.fill"
            )
            .fontWeight(.semibold)
            .foregroundStyle(.orange)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }
}

private func decimalDouble(_ value: Decimal) -> Double {
    NSDecimalNumber(decimal: value).doubleValue
}
