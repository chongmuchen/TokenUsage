import Foundation

public struct UsageTrendAggregator: Sendable {
    public static let unknownModelID = "<unknown-model>"
    public static let unknownEffort = "未知推理强度"

    private let catalog: PricingCatalog
    private let estimator: CreditEstimator
    private let calendar: Calendar

    public init(catalog: PricingCatalog, calendar: Calendar = .current) {
        self.catalog = catalog
        self.estimator = CreditEstimator(catalog: catalog)
        self.calendar = calendar
    }

    /// Aggregates exactly one accounting plane per root report. Duplicate root
    /// IDs (for example the same CODEX_HOME added twice) keep only the newest
    /// generated snapshot.
    public func aggregate(
        reports: [UsageReport],
        filter: UsageTrendFilter
    ) -> UsageTrendResult {
        let startMinute = minuteStart(min(filter.startMinute, filter.endMinute))
        let endMinute = minuteStart(max(filter.startMinute, filter.endMinute))
        let endExclusive = calendar.date(byAdding: .minute, value: 1, to: endMinute)
            ?? endMinute.addingTimeInterval(60)
        let days = daySequence(from: startMinute, through: endMinute)

        var warnings: [String] = []
        let uniqueReports = newestReportsByRootID(reports, warnings: &warnings)
        let allAtoms = uniqueReports.flatMap { atoms(for: $0, warnings: &warnings) }
        let atomsInRange = allAtoms.filter { $0.at >= startMinute && $0.at < endExclusive }

        let dimensions = dimensions(for: atomsInRange)
        let filteredAtoms = atomsInRange.filter { atom in
            (filter.selectedModels.isEmpty || filter.selectedModels.contains(atom.configuration.modelID))
                && (filter.selectedEfforts.isEmpty || filter.selectedEfforts.contains(atom.configuration.effort))
                && (filter.selectedSpeeds.isEmpty || filter.selectedSpeeds.contains(atom.configuration.speed))
        }

        var pointAccumulators: [UsageTrendSeriesKey: [Date: TrendAccumulator]] = [:]
        var summaryAccumulators: [UsageTrendSeriesKey: TrendAccumulator] = [:]
        if filter.groupMode == .all, !filteredAtoms.isEmpty {
            pointAccumulators[.all] = [:]
            summaryAccumulators[.all] = TrendAccumulator()
        }

        for atom in filteredAtoms {
            let key: UsageTrendSeriesKey = filter.groupMode == .all
                ? .all
                : .configuration(atom.configuration)
            let day = calendar.startOfDay(for: atom.at)
            var point = pointAccumulators[key, default: [:]][day] ?? TrendAccumulator()
            point.add(atom, estimator: estimator)
            pointAccumulators[key, default: [:]][day] = point

            var summary = summaryAccumulators[key] ?? TrendAccumulator()
            summary.add(atom, estimator: estimator)
            summaryAccumulators[key] = summary
        }

        let orderedKeys = pointAccumulators.keys.sorted(by: seriesKeyLessThan)
        let series = orderedKeys.map { key in
            let byDay = pointAccumulators[key] ?? [:]
            let points = days.map { day in
                UsageTrendPoint(
                    day: day,
                    aggregate: (byDay[day] ?? TrendAccumulator()).finalized()
                )
            }
            return UsageTrendSeries(
                id: key,
                name: seriesName(key),
                points: points,
                summary: (summaryAccumulators[key] ?? TrendAccumulator()).finalized()
            )
        }

        return UsageTrendResult(
            startMinute: startMinute,
            endMinute: endMinute,
            days: days,
            dimensions: dimensions,
            series: series,
            warnings: uniqueWarnings(warnings)
        )
    }

    private func newestReportsByRootID(
        _ reports: [UsageReport],
        warnings: inout [String]
    ) -> [UsageReport] {
        var result: [String: UsageReport] = [:]
        var duplicateIDs = Set<String>()
        for report in reports {
            if let existing = result[report.rootThreadId] {
                duplicateIDs.insert(report.rootThreadId)
                if report.generatedAt > existing.generatedAt {
                    result[report.rootThreadId] = report
                }
            } else {
                result[report.rootThreadId] = report
            }
        }
        if !duplicateIDs.isEmpty {
            warnings.append("发现 \(duplicateIDs.count) 个重复会话 ID；趋势统计仅采用各自最新报告。")
        }
        return Array(result.values)
    }

    private func atoms(for report: UsageReport, warnings: inout [String]) -> [TrendAtom] {
        let suppressed = report.task.cost.costSuppressed == true
        if let samples = report.task.usageSamples {
            let sampleUsage = TokenUsage.sum(samples.map(\.usage))
            if sampleUsage != report.task.usage {
                warnings.append("会话 \(shortID(report.rootThreadId)) 的分钟样本与任务总量无法对账。")
            }
            if report.task.usageIsLowerBound {
                warnings.append("会话 \(shortID(report.rootThreadId)) 的统计是已观测下界。")
            }
            return samples.map { sample in
                let approximate = sample.minute == nil
                if approximate {
                    warnings.append("部分分钟样本缺少时间，已按报告生成时间近似归档。")
                }
                return TrendAtom(
                    at: sample.minute ?? minuteStart(report.generatedAt),
                    configuration: configuration(
                        model: sample.model,
                        effort: sample.effort,
                        tier: sample.tier
                    ),
                    segment: UsageSegment(
                        model: sample.model,
                        effort: sample.effort,
                        tier: sample.tier,
                        tierSource: sample.tierSource,
                        taskEpoch: sample.taskEpoch,
                        longContext: sample.longContext,
                        usage: sample.usage,
                        firstAt: sample.minute,
                        lastAt: sample.minute,
                        requestCount: sample.requestCount
                    ),
                    costSuppressed: suppressed,
                    approximate: approximate
                )
            }
        }

        warnings.append("会话 \(shortID(report.rootThreadId)) 是旧报告；已按各段最后用量时间近似归档。")
        return report.task.segments.map { segment in
            TrendAtom(
                at: segment.lastAt ?? segment.firstAt ?? minuteStart(report.generatedAt),
                configuration: configuration(
                    model: segment.model,
                    effort: segment.effort,
                    tier: segment.tier
                ),
                segment: segment,
                costSuppressed: suppressed,
                approximate: true
            )
        }
    }

    private func configuration(
        model: String?,
        effort: String?,
        tier: String?
    ) -> UsageTrendConfiguration {
        let rawModel = normalizedText(model)
        let catalogEntry = catalog.entry(for: rawModel)
        let modelID = catalogEntry?.key ?? rawModel ?? Self.unknownModelID
        let modelName = catalogEntry?.value.displayName ?? rawModel ?? "未知模型"
        let normalizedEffort = normalizedText(effort)?.lowercased() ?? Self.unknownEffort
        return UsageTrendConfiguration(
            modelID: modelID,
            modelName: modelName,
            effort: normalizedEffort,
            speed: speed(for: tier)
        )
    }

    private func speed(for tier: String?) -> UsageTrendSpeed {
        switch normalizedText(tier)?.lowercased() {
        case "default", "standard": .standard
        case "fast", "priority": .fast
        default: .unknown
        }
    }

    private func dimensions(for atoms: [TrendAtom]) -> UsageTrendDimensions {
        let configurations = Set(atoms.map(\.configuration))
        var modelNames: [String: String] = [:]
        for configuration in configurations {
            modelNames[configuration.modelID] = configuration.modelName
        }
        let models = modelNames
            .map { UsageTrendModelOption(id: $0.key, displayName: $0.value) }
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        let efforts = Set(configurations.map(\.effort)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let presentSpeeds = Set(configurations.map(\.speed))
        let speeds = UsageTrendSpeed.allCases.filter(presentSpeeds.contains)
        return UsageTrendDimensions(models: models, efforts: efforts, speeds: speeds)
    }

    private func minuteStart(_ date: Date) -> Date {
        calendar.dateInterval(of: .minute, for: date)?.start ?? date
    }

    private func daySequence(from start: Date, through end: Date) -> [Date] {
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        var result: [Date] = []
        var cursor = first
        while cursor <= last {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else {
                break
            }
            cursor = next
        }
        return result
    }

    private func seriesKeyLessThan(_ lhs: UsageTrendSeriesKey, _ rhs: UsageTrendSeriesKey) -> Bool {
        switch (lhs, rhs) {
        case (.all, .all): false
        case (.all, _): true
        case (_, .all): false
        case (.configuration(let left), .configuration(let right)):
            left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
        }
    }

    private func seriesName(_ key: UsageTrendSeriesKey) -> String {
        switch key {
        case .all: "全部配置"
        case .configuration(let configuration): configuration.displayName
        }
    }

    private func normalizedText(_ value: String?) -> String? {
        guard let result = value?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else {
            return nil
        }
        return result
    }

    private func shortID(_ value: String) -> String {
        String(value.prefix(8))
    }

    private func uniqueWarnings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private struct TrendAtom: Sendable {
    let at: Date
    let configuration: UsageTrendConfiguration
    let segment: UsageSegment
    let costSuppressed: Bool
    let approximate: Bool
}

private struct TrendAccumulator: Sendable {
    private var tokens = UsageTrendTokenBreakdown.zero
    private var credits = TrendPriceAccumulator()
    private var apiUSD = TrendPriceAccumulator()
    private var approximate = false

    mutating func add(_ atom: TrendAtom, estimator: CreditEstimator) {
        let totalTokens = atom.segment.usage.totalTokens
        tokens = tokens + UsageTrendTokenBreakdown(usage: atom.segment.usage)
        approximate = approximate || atom.approximate

        if atom.costSuppressed {
            credits.addSuppressed(tokens: totalTokens)
            apiUSD.addSuppressed(tokens: totalTokens)
            return
        }
        credits.add(estimator.estimate([atom.segment], expectedTotalTokens: totalTokens))
        apiUSD.add(estimator.estimateAPI([atom.segment], expectedTotalTokens: totalTokens))
    }

    func finalized() -> UsageTrendAggregate {
        UsageTrendAggregate(
            tokens: tokens,
            credits: credits.finalized(),
            apiUSD: apiUSD.finalized(),
            isApproximate: approximate
        )
    }
}

private struct TrendPriceAccumulator: Sendable {
    private var amount = Decimal.zero
    private var hasAmount = false
    private var bases = Set<UsageTrendPriceBasis>()
    private var pricedTokens: Int64 = 0
    private var totalTokens: Int64 = 0
    private var suppressedTokens: Int64 = 0

    mutating func add(_ estimate: CreditEstimate) {
        add(
            amount: estimate.amount,
            basis: estimate.basis == .configured ? .configured : .standard,
            pricedTokens: estimate.pricedTokens,
            totalTokens: estimate.totalTokens
        )
    }

    mutating func add(_ estimate: APIPriceEstimate) {
        add(
            amount: estimate.amount,
            basis: estimate.basis == .configured ? .configured : .standard,
            pricedTokens: estimate.pricedTokens,
            totalTokens: estimate.totalTokens
        )
    }

    mutating func addSuppressed(tokens: Int64) {
        totalTokens = trendAdd(totalTokens, max(tokens, 0))
        suppressedTokens = trendAdd(suppressedTokens, max(tokens, 0))
    }

    func finalized() -> UsageTrendPriceSummary {
        let basis: UsageTrendPriceBasis
        if bases.count > 1 {
            basis = .mixed
        } else {
            basis = bases.first ?? .unavailable
        }
        return UsageTrendPriceSummary(
            amount: totalTokens == 0 ? .zero : (hasAmount ? amount : nil),
            basis: basis,
            pricedTokens: min(pricedTokens, totalTokens),
            totalTokens: totalTokens,
            suppressedTokens: min(suppressedTokens, totalTokens)
        )
    }

    private mutating func add(
        amount value: Decimal?,
        basis: UsageTrendPriceBasis,
        pricedTokens: Int64,
        totalTokens: Int64
    ) {
        self.totalTokens = trendAdd(self.totalTokens, max(totalTokens, 0))
        self.pricedTokens = trendAdd(self.pricedTokens, max(pricedTokens, 0))
        guard let value else { return }
        amount += value
        hasAmount = true
        bases.insert(basis)
    }
}

@inline(__always)
private func trendAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int64.max : value
}
