import Charts
import SwiftUI
import TokenUsageCore

struct TrendDashboardView: View {
    let result: UsageTrendResult
    let weeklyLimitOverview: WeeklyLimitOverview?

    @State private var visibleTokenMetrics = Set(TrendTokenMetric.allCases)
    @State private var priceMetric: TrendPriceMetric = .apiUSD

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                WeeklyLimitProjectionCard(projection: weeklyLimitOverview?.current)
                WeeklyLimitHistoryCard(
                    history: Array((weeklyLimitOverview?.history ?? []).prefix(8)),
                    computedAt: weeklyLimitOverview?.computedAt
                )

                if result.series.isEmpty {
                    ContentUnavailableView {
                        Label("没有符合条件的趋势数据", systemImage: "chart.xyaxis.line")
                    } description: {
                        Text("调整时间、模型、推理强度或速度筛选；旧报告也可以先同步为分钟级报告。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
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
            }
            .padding(16)
        }
    }
}

private struct WeeklyLimitProjectionCard: View {
    let projection: WeeklyLimitProjection?

    var body: some View {
        TrendCard(
            title: "当前周限额预估",
            subtitle: "按服务端本次 7 天窗口的本地用量结构线性估算；Token 与 API USD 都是等价值，不是固定配额或账单。"
        ) {
            if let projection {
                HStack(spacing: 6) {
                    Text(limitName(projection))
                        .lineLimit(1)
                    confidenceBadge(projection.confidence)
                    if projection.isApproximate {
                        badge("近似数据", color: .orange)
                    }
                }
                .font(.caption)
            }
        } content: {
            if let projection {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("预计用满 API USD")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(priceText(projection.projectedAPIUSD, projection: projection))
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .accessibilityLabel("预计用满 \(priceText(projection.projectedAPIUSD, projection: projection))")
                    }

                    Divider()

                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 130), spacing: 18, alignment: .leading)
                        ],
                        alignment: .leading,
                        spacing: 10
                    ) {
                        WeeklyLimitMetric(
                            title: "截至快照 API USD",
                            value: priceText(projection.currentAPIUSD, projection: projection)
                        )
                        WeeklyLimitMetric(
                            title: "截至快照 Token",
                            value: observedTokenText(projection)
                        )
                        WeeklyLimitMetric(
                            title: "已用",
                            value: percentText(projection.snapshot.usedPercent)
                        )
                        WeeklyLimitMetric(
                            title: "100% Token 等价",
                            value: projectedTokenText(projection.projectedFullTokens)
                        )
                        WeeklyLimitMetric(
                            title: "重置",
                            value: compactDateTime(projection.snapshot.resetsAt)
                        )
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            WeeklyLimitMetric(
                                title: "周期剩余",
                                value: remainingTimeText(
                                    until: projection.snapshot.resetsAt,
                                    now: context.date
                                )
                            )
                        }
                        WeeklyLimitMetric(
                            title: "截至",
                            value: compactDateTime(projection.snapshot.observedAt)
                        )
                    }

                    if let firstWarning = projection.warnings.first {
                        Label {
                            Text(warningSummary(firstWarning, count: projection.warnings.count))
                                .lineLimit(2)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(projection.warnings.joined(separator: "\n"))
                    }
                }
                .help(projectionHelp(projection))
            } else {
                Label(
                    "完成新回合或同步当前日期范围后可估算",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
            }
        }
    }

    private func confidenceBadge(_ confidence: WeeklyLimitConfidence) -> some View {
        let color: Color = switch confidence {
        case .insufficient, .low: .orange
        case .medium: .blue
        case .higher: .green
        }
        return badge("置信度：\(confidence.displayName)", color: color)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.11), in: Capsule())
            .overlay {
                Capsule().stroke(color.opacity(0.35), lineWidth: 0.5)
            }
    }

    private func priceText(
        _ amount: Decimal?,
        projection: WeeklyLimitProjection
    ) -> String {
        guard let amount else { return "—" }
        let prefix = projection.apiUSD.isPartial || projection.apiUSD.isSuppressed
            ? "部分≈ "
            : "≈ "
        return prefix + TrendPriceTooltipFormatter.string(amount, metric: .apiUSD)
    }

    private func percentText(_ value: Double) -> String {
        let fraction = value.rounded() == value ? 0 : 1
        return String(format: "%.*f%%", fraction, value)
    }

    private func observedTokenText(_ projection: WeeklyLimitProjection) -> String {
        let prefix = projection.isApproximate ? "≈ " : ""
        return prefix + TokenFormatter.compact(projection.observedTokens)
    }

    private func projectedTokenText(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return "≈ " + TokenFormatter.compact(value)
    }

    private func compactDateTime(_ date: Date) -> String {
        date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }

    private func remainingTimeText(until reset: Date, now: Date) -> String {
        let interval = reset.timeIntervalSince(now)
        guard interval > 0 else { return "已到重置时间" }

        let totalMinutes = max(Int(ceil(interval / 60)), 1)
        let days = totalMinutes / (24 * 60)
        let hours = totalMinutes % (24 * 60) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0 ? "\(days) 天 \(hours) 小时" : "\(days) 天"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours) 小时 \(minutes) 分" : "\(hours) 小时"
        }
        return "\(minutes) 分钟"
    }

    private func limitName(_ projection: WeeklyLimitProjection) -> String {
        guard let name = projection.snapshot.limitName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return projection.snapshot.limitId
        }
        return name
    }

    private func warningSummary(_ warning: String, count: Int) -> String {
        guard count > 1 else { return warning }
        return "\(warning)（另有 \(count - 1) 项提示）"
    }

    private func projectionHelp(_ projection: WeeklyLimitProjection) -> String {
        let period = "限额周期：\(compactDateTime(projection.periodStart)) – \(compactDateTime(projection.snapshot.resetsAt))"
        let source = "限额：\(limitName(projection))（\(projection.snapshot.limitId) / \(projection.snapshot.bucket)）"
        return [period, source].joined(separator: "\n")
    }
}

private struct WeeklyLimitHistoryCard: View {
    let history: [WeeklyLimitProjection]
    let computedAt: Date?

    var body: some View {
        TrendCard(
            title: "历史周限额（本地近似）",
            subtitle: "按各周期最后观测值线性回推；提前重置的周期截至新周期开始，仅覆盖本地已有报告。"
        ) {
            if let computedAt {
                Text("本地计算于 \(computedAt, format: .dateTime.hour().minute())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } content: {
            if history.isEmpty {
                Label(
                    "尚无历史快照；可同步包含过去日期的范围进行近似回填",
                    systemImage: "calendar.badge.clock"
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
            } else {
                ScrollView(.horizontal) {
                    Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 8) {
                        GridRow {
                            header("周期", alignment: .leading)
                            header("100% API USD")
                            header("100% Token 等价")
                            header("最后观测实际 API USD")
                            header("最后观测实际 Token")
                            header("最后观测已用%")
                            header("观测截止")
                        }

                        Divider().gridCellColumns(7)

                        ForEach(Array(history.enumerated()), id: \.offset) { _, projection in
                            GridRow {
                                HStack(spacing: 5) {
                                    Text(periodText(projection))
                                    if projection.periodEnd < projection.snapshot.resetsAt {
                                        Text("提前重置")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if projection.isFinalObservationStale {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                    }
                                }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                value(priceText(projection.projectedAPIUSD, projection: projection))
                                value(projectedTokenText(projection.projectedFullTokens))
                                value(priceText(projection.currentAPIUSD, projection: projection))
                                value(TokenFormatter.compact(projection.observedTokens))
                                value(percentText(projection.snapshot.usedPercent))
                                value(compactDateTime(projection.observationCutoff))
                            }
                            .help(rowHelp(projection))
                        }
                    }
                    .font(.callout)
                    .frame(minWidth: 1_120)
                }
            }
        }
    }

    private func header(_ text: String, alignment: Alignment = .trailing) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .monospacedDigit()
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func priceText(
        _ amount: Decimal?,
        projection: WeeklyLimitProjection
    ) -> String {
        guard let amount else { return "—" }
        let prefix = projection.apiUSD.isPartial || projection.apiUSD.isSuppressed
            ? "部分≈ "
            : "≈ "
        return prefix + TrendPriceTooltipFormatter.string(amount, metric: .apiUSD)
    }

    private func projectedTokenText(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return "≈ " + TokenFormatter.compact(value)
    }

    private func percentText(_ value: Double) -> String {
        let fraction = value.rounded() == value ? 0 : 1
        return String(format: "%.*f%%", fraction, value)
    }

    private func compactDateTime(_ date: Date) -> String {
        date.formatted(.dateTime.year(.twoDigits).month(.twoDigits).day(.twoDigits).hour().minute())
    }

    private func periodText(_ projection: WeeklyLimitProjection) -> String {
        let start = projection.periodStart.formatted(
            .dateTime.year(.twoDigits).month(.twoDigits).day(.twoDigits)
        )
        let end = projection.periodEnd.formatted(
            .dateTime.year(.twoDigits).month(.twoDigits).day(.twoDigits)
        )
        return "\(start) – \(end)"
    }

    private func rowHelp(_ projection: WeeklyLimitProjection) -> String {
        var lines = [
            projection.isCompleted ? "已结束的限额周期" : "尚未结束的限额周期",
            "周期：\(compactDateTime(projection.periodStart)) – \(compactDateTime(projection.periodEnd))",
            "最后观测：\(compactDateTime(projection.observationCutoff))"
        ]
        if projection.periodEnd < projection.snapshot.resetsAt {
            lines.append("因新周期开始而提前结束；原定重置：\(compactDateTime(projection.snapshot.resetsAt))")
        }
        if !projection.warnings.isEmpty {
            lines.append(contentsOf: projection.warnings)
        }
        return lines.joined(separator: "\n")
    }
}

private struct WeeklyLimitMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
    case apiUSD
    case credits

    var id: String { rawValue }
    var title: String {
        switch self {
        case .apiUSD: "API USD 等价"
        case .credits: "Credits 估算"
        }
    }
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
    @State private var hoveredPointID: TrendPricePoint.ID?
    @Environment(\.calendar) private var calendar

    private let hoverHitRadius: CGFloat = 20

    var body: some View {
        let points = pricePoints

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
            Chart(points) { point in
                LineMark(
                    x: .value("日期", point.day, unit: .day, calendar: calendar),
                    y: .value(metric.title, point.amount),
                    series: .value("连续定价区间", point.runID)
                )
                .foregroundStyle(by: .value("曲线", point.seriesName))
                .interpolationMethod(.linear)

                PointMark(
                    x: .value("日期", point.day, unit: .day, calendar: calendar),
                    y: .value(metric.title, point.amount)
                )
                .foregroundStyle(by: .value("曲线", point.seriesName))
                .symbolSize(result.days.count <= 45 ? 22 : 9)

                if point.id == hoveredPointID {
                    PointMark(
                        x: .value("悬浮日期", point.day, unit: .day, calendar: calendar),
                        y: .value("悬浮数值", point.amount)
                    )
                    .foregroundStyle(by: .value("曲线", point.seriesName))
                    .symbolSize(78)
                    .annotation(
                        position: .top,
                        spacing: 8,
                        overflowResolution: .init(
                            x: .fit(to: .chart),
                            y: .fit(to: .chart)
                        )
                    ) {
                        TrendPriceTooltip(
                            point: point,
                            metric: metric,
                            showsSeriesName: result.series.count > 1
                        )
                    }
                }
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
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(location):
                                updateHoveredPoint(
                                    at: location,
                                    points: points,
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
            .accessibilityLabel("按日\(metric.title)曲线")
        }
        .onChange(of: metric) { _, _ in
            hoveredPointID = nil
        }
        .onChange(of: points) { _, _ in
            hoveredPointID = nil
        }
    }

    private func updateHoveredPoint(
        at location: CGPoint,
        points: [TrendPricePoint],
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let plotFrameAnchor = proxy.plotFrame else {
            hoveredPointID = nil
            return
        }
        let plotFrame = geometry[plotFrameAnchor]
        guard plotFrame.contains(location) else {
            hoveredPointID = nil
            return
        }

        let plotLocation = CGPoint(
            x: location.x - plotFrame.minX,
            y: location.y - plotFrame.minY
        )
        let closestID = closestPointID(
            to: plotLocation,
            points: points,
            proxy: proxy
        )
        if hoveredPointID != closestID {
            hoveredPointID = closestID
        }
    }

    private func closestPointID(
        to location: CGPoint,
        points: [TrendPricePoint],
        proxy: ChartProxy
    ) -> TrendPricePoint.ID? {
        var bestMatch: (distance: CGFloat, pointID: TrendPricePoint.ID)?

        for point in points {
            guard let position = proxy.position(
                for: (x: plottedDay(for: point.day), y: point.amount)
            ) else { continue }
            considerMatch(
                distance: distance(from: location, to: position),
                pointID: point.id,
                bestMatch: &bestMatch
            )
        }

        guard let bestMatch, bestMatch.distance <= hoverHitRadius else { return nil }
        return bestMatch.pointID
    }

    private func considerMatch(
        distance: CGFloat,
        pointID: TrendPricePoint.ID,
        bestMatch: inout (distance: CGFloat, pointID: TrendPricePoint.ID)?
    ) {
        guard distance < (bestMatch?.distance ?? .infinity) else { return }
        bestMatch = (distance, pointID)
    }

    private func distance(from point: CGPoint, to target: CGPoint) -> CGFloat {
        hypot(point.x - target.x, point.y - target.y)
    }

    /// Date marks plotted with `unit: .day` sit at the middle of the calendar
    /// day. ChartProxy positions a raw Date at its exact time, so using the
    /// bucket's midnight would miss the visible point by half a day.
    private func plottedDay(for day: Date) -> Date {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return day }
        return interval.start.addingTimeInterval(interval.duration / 2)
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
                    amount: decimalDouble(amount),
                    exactAmount: amount
                )
            }
        }
    }
}

private struct TrendPricePoint: Identifiable, Equatable {
    let seriesName: String
    let runID: String
    let day: Date
    let amount: Double
    let exactAmount: Decimal

    var id: String { "\(runID)#\(day.timeIntervalSinceReferenceDate)" }
}

private struct TrendPriceTooltip: View {
    let point: TrendPricePoint
    let metric: TrendPriceMetric
    let showsSeriesName: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(point.day, format: .dateTime.year().month(.twoDigits).day(.twoDigits))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if showsSeriesName {
                Text(point.seriesName)
                    .font(.caption2)
                    .lineLimit(1)
            }
            Text(TrendPriceTooltipFormatter.string(point.exactAmount, metric: metric))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
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

private enum TrendPriceTooltipFormatter {
    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 6
        return formatter
    }()

    static func string(_ value: Decimal, metric: TrendPriceMetric) -> String {
        let amount = formatter.string(from: value as NSDecimalNumber)
            ?? (value as NSDecimalNumber).stringValue
        return metric == .apiUSD ? "$\(amount)" : "\(amount) cr"
    }
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
