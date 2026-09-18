import Foundation

/// A point at the last observation of one weekly-limit period on a local day.
/// A reset can therefore produce more than one point for the same day.
public struct DailyQuotaPoint: Identifiable, Equatable, Sendable {
    public let day: Date
    public let segmentStart: Date
    public let observedAt: Date
    public let startRemainingPercent: Double?
    public let cumulativeUsedPercent: Double?
    public let usdPerPercent: Decimal?
    public let isApproximate: Bool
    public let isReset: Bool

    public var id: String {
        "\(day.timeIntervalSince1970):\(segmentStart.timeIntervalSince1970):\(observedAt.timeIntervalSince1970):\(isReset)"
    }

    public init(
        day: Date,
        segmentStart: Date,
        observedAt: Date,
        startRemainingPercent: Double?,
        cumulativeUsedPercent: Double?,
        usdPerPercent: Decimal?,
        isApproximate: Bool,
        isReset: Bool
    ) {
        self.day = day
        self.segmentStart = segmentStart
        self.observedAt = observedAt
        self.startRemainingPercent = startRemainingPercent
        self.cumulativeUsedPercent = cumulativeUsedPercent
        self.usdPerPercent = usdPerPercent
        self.isApproximate = isApproximate
        self.isReset = isReset
    }
}

public struct DailyQuotaTrend: Sendable {
    public let points: [DailyQuotaPoint]
    public let warnings: [String]

    public init(points: [DailyQuotaPoint], warnings: [String]) {
        self.points = points
        self.warnings = warnings
    }
}

/// Builds a local-day view of the *observed* Codex weekly-limit percentage.
/// Pass reports from one Codex Home only, so the USD numerator and quota
/// denominator refer to the same account. The parser's historical
/// `rateLimitSnapshots` remains a supported, less complete fallback.
public struct DailyQuotaTrendAggregator: Sendable {
    private let calendar: Calendar
    private let priceEstimator: CreditEstimator

    public init(catalog: PricingCatalog, calendar: Calendar = .current) {
        self.calendar = calendar
        self.priceEstimator = CreditEstimator(catalog: catalog)
    }

    public func aggregate(
        reports: [UsageReport],
        startDate: Date,
        endDate: Date,
        limitID: String? = nil
    ) -> DailyQuotaTrend {
        let firstDay = calendar.startOfDay(for: min(startDate, endDate))
        let lastDay = calendar.startOfDay(for: max(startDate, endDate))
        let uniqueReports = newestReportsByRootID(reports)
        var warnings: [String] = []
        if uniqueReports.count != reports.count {
            warnings.append("发现重复会话报告；每日配额和价格仅采用各会话最新报告。")
        }

        let newSnapshots = Set(uniqueReports.flatMap { $0.rateLimitObservations ?? [] })
        let candidates = Array(Set(uniqueReports.flatMap { report in
            report.rateLimitObservations ?? report.rateLimitSnapshots ?? []
        })).filter(isValidWeeklyObservation)
        if candidates.isEmpty {
            return DailyQuotaTrend(points: [], warnings: warnings)
        }
        if candidates.contains(where: { !newSnapshots.contains($0) }) {
            warnings.append("部分旧报告只保存每个会话的末次配额观测；历史每日曲线可能低估。")
        }

        let selectedLimitID: String
        if let limitID {
            selectedLimitID = limitID
        } else if candidates.contains(where: { $0.limitId == "codex" }) {
            selectedLimitID = "codex"
        } else {
            selectedLimitID = candidates.max {
                $0.observedAt < $1.observedAt
            }!.limitId
        }
        let observations = periodized(
            candidates.filter { $0.limitId == selectedLimitID },
            newSnapshots: newSnapshots
        )
        let byDay = Dictionary(grouping: observations) { calendar.startOfDay(for: $0.snapshot.observedAt) }
        let orderedDays = byDay.keys.filter { $0 >= firstDay && $0 <= lastDay }.sorted()
        let priceEventsByDay = Dictionary(grouping: priceEvents(in: uniqueReports)) {
            calendar.startOfDay(for: $0.at)
        }
        var points: [DailyQuotaPoint] = []

        for day in orderedDays {
            guard let dayObservations = byDay[day] else { continue }
            let sorted = dayObservations.sorted(by: observationLessThan)
            let segments = consecutiveSegments(sorted)
            var cumulative: Double? = 0
            var earlierPeriod = observations.last { $0.snapshot.observedAt < day }?.period
            let priceEvents = (priceEventsByDay[day] ?? []).sorted { $0.at < $1.at }
            var priceCursor = 0
            var priceRunning = PriceRunning()

            for (index, segment) in segments.enumerated() {
                guard let first = segment.first, let last = segment.last else { continue }
                let reset = earlierPeriod != first.period
                    && (index > 0 || first.period.start >= day)
                let previousDay = calendar.date(byAdding: .day, value: -1, to: day)
                    ?? day.addingTimeInterval(-86_400)
                let yesterdayLast = byDay[previousDay]?
                    .filter { $0.period == first.period }
                    .max(by: observationLessThan)

                let baseline: Double
                let approximateBaseline: Bool
                if reset {
                    // The new window begins at zero used. The exact value at
                    // the reset instant is inferred rather than observed.
                    baseline = 0
                    approximateBaseline = true
                } else if index == 0, let yesterdayLast {
                    baseline = yesterdayLast.snapshot.usedPercent
                    // The last observation yesterday is only a proxy for
                    // midnight; usage after it cannot be recovered.
                    approximateBaseline = true
                } else {
                    // Without the preceding daily boundary, the first
                    // observation is the conservative start approximation.
                    baseline = first.snapshot.usedPercent
                    approximateBaseline = true
                }

                let used = segmentUsage(segment, baseline: baseline)
                if let used, let running = cumulative {
                    cumulative = running + used
                } else {
                    cumulative = nil
                    warnings.append("有配额观测在同一周期内下降；对应日期的使用量留空。")
                }
                while priceCursor < priceEvents.count,
                      priceEvents[priceCursor].at <= last.snapshot.observedAt {
                    priceRunning.add(priceEvents[priceCursor])
                    priceCursor += 1
                }
                let price = cumulative.flatMap { used -> PriceResult? in
                    guard used > 0 else { return nil }
                    return priceRunning.result(denominator: used)
                }
                if price?.partial == true {
                    warnings.append("部分 Token 缺少 API USD 价格；每 1% 的金额仅覆盖已定价部分。")
                }
                let point = DailyQuotaPoint(
                    day: day,
                    segmentStart: reset
                        ? max(day, first.period.start)
                        : day,
                    observedAt: last.snapshot.observedAt,
                    startRemainingPercent: 100 - baseline,
                    cumulativeUsedPercent: cumulative,
                    usdPerPercent: price?.amount,
                    isApproximate: approximateBaseline
                        || segment.contains(where: \.isLegacy)
                        || price?.approximate == true,
                    isReset: reset
                )
                points.append(point)
                earlierPeriod = first.period
            }
        }
        return DailyQuotaTrend(points: points, warnings: unique(warnings))
    }

    private func newestReportsByRootID(_ reports: [UsageReport]) -> [UsageReport] {
        var newest: [String: UsageReport] = [:]
        for report in reports {
            if let previous = newest[report.rootThreadId], previous.generatedAt >= report.generatedAt {
                continue
            }
            newest[report.rootThreadId] = report
        }
        return Array(newest.values)
    }

    private func isValidWeeklyObservation(_ snapshot: RateLimitSnapshot) -> Bool {
        snapshot.windowMinutes == WeeklyLimitEstimator.weeklyWindowMinutes
            && snapshot.usedPercent.isFinite
            && (0 ... 100).contains(snapshot.usedPercent)
            && snapshot.observedAt <= snapshot.resetsAt
            && snapshot.observedAt >= snapshot.resetsAt.addingTimeInterval(
                -TimeInterval(WeeklyLimitEstimator.weeklyWindowMinutes * 60)
            )
    }

    private func periodized(
        _ snapshots: [RateLimitSnapshot],
        newSnapshots: Set<RateLimitSnapshot>
    ) -> [QuotaObservation] {
        let orderedByReset = snapshots.sorted {
            if $0.resetsAt != $1.resetsAt { return $0.resetsAt < $1.resetsAt }
            return $0.observedAt < $1.observedAt
        }
        var clusters: [[RateLimitSnapshot]] = []
        for snapshot in orderedByReset {
            if let last = clusters.indices.last,
               let anchor = clusters[last].first?.resetsAt,
               snapshot.resetsAt.timeIntervalSince(anchor)
                <= WeeklyLimitEstimator.resetClusteringTolerance {
                clusters[last].append(snapshot)
            } else {
                clusters.append([snapshot])
            }
        }
        return clusters.enumerated().flatMap { index, cluster in
            let reset = cluster[0].resetsAt
            let period = QuotaPeriod(
                index: index,
                start: reset.addingTimeInterval(
                    -TimeInterval(WeeklyLimitEstimator.weeklyWindowMinutes * 60)
                )
            )
            return cluster.map { snapshot in
                QuotaObservation(
                    snapshot: snapshot,
                    period: period,
                    isLegacy: !newSnapshots.contains(snapshot)
                )
            }
        }
        .sorted(by: observationLessThan)
    }

    private func observationLessThan(_ lhs: QuotaObservation, _ rhs: QuotaObservation) -> Bool {
        if lhs.snapshot.observedAt != rhs.snapshot.observedAt {
            return lhs.snapshot.observedAt < rhs.snapshot.observedAt
        }
        if lhs.period.index != rhs.period.index { return lhs.period.index < rhs.period.index }
        return lhs.snapshot.usedPercent < rhs.snapshot.usedPercent
    }

    private func consecutiveSegments(_ observations: [QuotaObservation]) -> [[QuotaObservation]] {
        var segments: [[QuotaObservation]] = []
        for observation in observations {
            if let index = segments.indices.last,
               segments[index].first?.period == observation.period {
                segments[index].append(observation)
            } else {
                segments.append([observation])
            }
        }
        return segments
    }

    private func segmentUsage(_ observations: [QuotaObservation], baseline: Double) -> Double? {
        var previous = baseline
        for observation in observations {
            let current = observation.snapshot.usedPercent
            if current + 0.001 < previous { return nil }
            previous = max(previous, current)
        }
        return max(previous - baseline, 0)
    }

    private func priceEvents(in reports: [UsageReport]) -> [PriceEvent] {
        reports.flatMap { report -> [PriceEvent] in
            let suppressed = report.task.cost.costSuppressed == true
            if let samples = report.task.usageSamples {
                return samples.map { sample in
                    let at = sample.minute ?? report.generatedAt
                    let segment = UsageSegment(
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
                    )
                    return priceEvent(
                        at: at,
                        segment: segment,
                        suppressed: suppressed,
                        approximate: sample.minute == nil
                    )
                }
            }
            return report.task.segments.map { segment in
                priceEvent(
                    at: segment.lastAt ?? segment.firstAt ?? report.generatedAt,
                    segment: segment,
                    suppressed: suppressed,
                    approximate: true
                )
            }
        }
    }

    private func priceEvent(
        at: Date,
        segment: UsageSegment,
        suppressed: Bool,
        approximate: Bool
    ) -> PriceEvent {
        let totalTokens = max(segment.usage.totalTokens, 0)
        let estimate = suppressed ? nil : priceEstimator.estimateAPI(
            [segment],
            expectedTotalTokens: totalTokens
        )
        return PriceEvent(
            at: at,
            amount: estimate?.amount,
            pricedTokens: estimate?.pricedTokens ?? 0,
            totalTokens: totalTokens,
            approximate: approximate
        )
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private struct QuotaPeriod: Equatable {
    let index: Int
    let start: Date
}

private struct QuotaObservation {
    let snapshot: RateLimitSnapshot
    let period: QuotaPeriod
    let isLegacy: Bool
}

private struct PriceResult {
    let amount: Decimal
    let partial: Bool
    let approximate: Bool
}

private struct PriceEvent {
    let at: Date
    let amount: Decimal?
    let pricedTokens: Int64
    let totalTokens: Int64
    let approximate: Bool
}

private struct PriceRunning {
    private var amount = Decimal.zero
    private var hasPrice = false
    private var pricedTokens: Int64 = 0
    private var totalTokens: Int64 = 0
    private var approximate = false

    mutating func add(_ event: PriceEvent) {
        totalTokens = saturatedAdd(totalTokens, event.totalTokens)
        pricedTokens = saturatedAdd(pricedTokens, event.pricedTokens)
        approximate = approximate || event.approximate
        if let value = event.amount {
            amount += value
            hasPrice = true
        }
    }

    func result(denominator: Double) -> PriceResult? {
        guard hasPrice,
              let divisor = Decimal(
                string: String(denominator),
                locale: Locale(identifier: "en_US_POSIX")
              ), divisor > 0
        else { return nil }
        let partial = pricedTokens < totalTokens
        return PriceResult(
            amount: amount / divisor,
            partial: partial,
            approximate: approximate || partial
        )
    }

    private func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }
}
