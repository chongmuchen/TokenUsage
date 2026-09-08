import Foundation

public enum WeeklyLimitConfidence: String, Codable, CaseIterable, Sendable {
    case insufficient
    case low
    case medium
    case higher

    public init(usedPercent: Double) {
        guard usedPercent.isFinite else {
            self = .insufficient
            return
        }
        switch usedPercent {
        case ..<5:
            self = .insufficient
        case ..<10:
            self = .low
        case ..<20:
            self = .medium
        default:
            self = .higher
        }
    }

    public var displayName: String {
        switch self {
        case .insufficient: "样本不足"
        case .low: "较低"
        case .medium: "中等"
        case .higher: "较高"
        }
    }
}

public struct WeeklyLimitProjection: Equatable, Sendable {
    public let snapshot: RateLimitSnapshot
    public let periodStart: Date
    public let apiUSD: UsageTrendPriceSummary
    public let currentAPIUSD: Decimal?
    public let projectedAPIUSD: Decimal?
    public let projectedFullTokens: Int64?
    public let isCompleted: Bool
    public let confidence: WeeklyLimitConfidence
    public let isApproximate: Bool
    public let warnings: [String]

    public init(
        snapshot: RateLimitSnapshot,
        periodStart: Date,
        apiUSD: UsageTrendPriceSummary,
        currentAPIUSD: Decimal?,
        projectedAPIUSD: Decimal?,
        projectedFullTokens: Int64? = nil,
        isCompleted: Bool = false,
        confidence: WeeklyLimitConfidence,
        isApproximate: Bool,
        warnings: [String]
    ) {
        self.snapshot = snapshot
        self.periodStart = periodStart
        self.apiUSD = apiUSD
        self.currentAPIUSD = currentAPIUSD
        self.projectedAPIUSD = projectedAPIUSD
        self.projectedFullTokens = projectedFullTokens
        self.isCompleted = isCompleted
        self.confidence = confidence
        self.isApproximate = isApproximate
        self.warnings = warnings
    }

    public var observedTokens: Int64 { apiUSD.totalTokens }
    public var observationCutoff: Date { snapshot.observedAt }
    public var periodEnd: Date { snapshot.resetsAt }
    public var projectedFullAPIUSD: Decimal? { projectedAPIUSD }
    public var observationLagToReset: TimeInterval {
        max(periodEnd.timeIntervalSince(observationCutoff), 0)
    }
    public var isFinalObservationStale: Bool {
        isCompleted && observationLagToReset > WeeklyLimitEstimator.staleObservationThreshold
    }
}

public struct WeeklyLimitOverview: Equatable, Sendable {
    public let current: WeeklyLimitProjection?
    public let history: [WeeklyLimitProjection]
    public let computedAt: Date

    public init(
        current: WeeklyLimitProjection?,
        history: [WeeklyLimitProjection],
        computedAt: Date
    ) {
        self.current = current
        self.history = history
        self.computedAt = computedAt
    }
}

public struct WeeklyLimitEstimator: Sendable {
    public static let weeklyWindowMinutes: Int64 = 10_080
    public static let maximumHistoryPeriods = 8
    public static let resetClusteringTolerance: TimeInterval = 5 * 60
    public static let staleObservationThreshold: TimeInterval = 6 * 60 * 60

    private let trendAggregator: UsageTrendAggregator

    public init(catalog: PricingCatalog, calendar: Calendar = .current) {
        self.trendAggregator = UsageTrendAggregator(catalog: catalog, calendar: calendar)
    }

    /// Estimates the API-USD equivalent of consuming 100% of the current
    /// weekly limit, assuming the observed usage mix remains representative.
    /// Returns `nil` when no current weekly-limit snapshot is available.
    public func estimate(
        reports: [UsageReport],
        now: Date = Date()
    ) -> WeeklyLimitProjection? {
        overview(reports: reports, now: now, historyLimit: 0).current
    }

    /// Builds the current weekly-limit projection and a bounded, newest-first
    /// history from local report snapshots. The same logical reset may be
    /// reported a few seconds apart and under different bucket names, so
    /// periods are clustered by limit ID with a five-minute reset tolerance.
    public func overview(
        reports: [UsageReport],
        now: Date = Date(),
        historyLimit: Int = Self.maximumHistoryPeriods
    ) -> WeeklyLimitOverview {
        let newestReports = newestReportsByRootID(reports)
        let duplicateRootCount = duplicateRootIDs(in: reports).count
        let clusters = weeklySnapshotClusters(in: newestReports, now: now)
        let activeClusters = clusters.filter { cluster in
            let snapshot = cluster.snapshot
            let periodStart = weeklyPeriodStart(for: snapshot)
            return periodStart <= now && snapshot.resetsAt > now
        }
        let currentCluster = preferredCluster(in: activeClusters)
        let selectedLimitID = currentCluster?.snapshot.limitId
            ?? preferredCluster(in: clusters)?.snapshot.limitId
        let boundedHistoryLimit = min(max(historyLimit, 0), Self.maximumHistoryPeriods)

        let current = currentCluster.map {
            projection(
                for: $0.snapshot,
                reports: newestReports,
                now: now,
                duplicateRootCount: duplicateRootCount
            )
        }
        var history: [WeeklyLimitProjection] = []
        if let selectedLimitID, boundedHistoryLimit > 0 {
            let historicalClusters = clusters
                .filter {
                    $0.snapshot.limitId == selectedLimitID
                        && $0.snapshot.resetsAt <= now
                }
                .sorted(by: clusterNewestFirst)
                .prefix(boundedHistoryLimit)
            for cluster in historicalClusters {
                guard !Task.isCancelled else { break }
                history.append(
                    projection(
                        for: cluster.snapshot,
                        reports: newestReports,
                        now: now,
                        duplicateRootCount: duplicateRootCount
                    )
                )
            }
        }

        return WeeklyLimitOverview(current: current, history: history, computedAt: now)
    }

    private func projection(
        for snapshot: RateLimitSnapshot,
        reports: [UsageReport],
        now: Date,
        duplicateRootCount: Int
    ) -> WeeklyLimitProjection {
        let periodStart = weeklyPeriodStart(for: snapshot)

        let trend = trendAggregator.aggregate(
            reports: reports,
            filter: UsageTrendFilter(
                startMinute: periodStart,
                endMinute: snapshot.observedAt,
                groupMode: .all
            )
        )
        let aggregate = trend.series.first { $0.id == .all }?.summary
        let apiUSD = aggregate?.apiUSD ?? UsageTrendPriceSummary(
            amount: nil,
            basis: .unavailable,
            pricedTokens: 0,
            totalTokens: 0,
            suppressedTokens: 0
        )
        let currentAPIUSD = apiUSD.amount
        let confidence = WeeklyLimitConfidence(usedPercent: snapshot.usedPercent)
        let projectedAPIUSD = projectedAmount(
            currentAmount: currentAPIUSD,
            usedPercent: snapshot.usedPercent
        )
        let projectedFullTokens = projectedTokenCount(
            currentTokens: aggregate?.tokens.totalTokens,
            usedPercent: snapshot.usedPercent
        )

        var warnings = trend.warnings
        if duplicateRootCount > 0 {
            warnings.append("发现 \(duplicateRootCount) 个重复会话 ID；周限额统计仅采用各自最新报告。")
        }
        if snapshot.usedPercent == 0 {
            warnings.append("周限额当前为 0%，暂时无法外推用满后的 API USD 等价总价。")
        } else if confidence == .insufficient {
            warnings.append("周限额用量低于 5%，当前外推样本不足。")
        }
        if currentAPIUSD == nil {
            warnings.append("本周期没有可用的 API USD 价格，暂时无法计算预计总价。")
        }
        if apiUSD.isPartial {
            warnings.append("本周期 API USD 价格覆盖不完整；当前金额和预计总价仅代表已定价部分。")
        }
        if apiUSD.isSuppressed {
            warnings.append("本周期部分价格因数据一致性问题被抑制。")
        }
        let isCompleted = snapshot.resetsAt <= now
        let observationLag = snapshot.resetsAt.timeIntervalSince(snapshot.observedAt)
        if isCompleted, observationLag > Self.staleObservationThreshold {
            warnings.append(
                "历史周期最后观测距离重置约 \(observationLagText(observationLag))，最终使用可能不完整。"
            )
        } else if !isCompleted,
                  now.timeIntervalSince(snapshot.observedAt) > Self.staleObservationThreshold {
            warnings.append("当前周限额快照已超过 6 小时未更新。")
        }

        return WeeklyLimitProjection(
            snapshot: snapshot,
            periodStart: periodStart,
            apiUSD: apiUSD,
            currentAPIUSD: currentAPIUSD,
            projectedAPIUSD: projectedAPIUSD,
            projectedFullTokens: projectedFullTokens,
            isCompleted: isCompleted,
            confidence: confidence,
            isApproximate: trend.isApproximate,
            warnings: uniqueWarnings(warnings)
        )
    }

    private func newestReportsByRootID(_ reports: [UsageReport]) -> [UsageReport] {
        var newest: [String: UsageReport] = [:]
        for report in reports {
            if let existing = newest[report.rootThreadId], existing.generatedAt >= report.generatedAt {
                continue
            }
            newest[report.rootThreadId] = report
        }
        return Array(newest.values)
    }

    private func duplicateRootIDs(in reports: [UsageReport]) -> Set<String> {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for report in reports where !seen.insert(report.rootThreadId).inserted {
            duplicates.insert(report.rootThreadId)
        }
        return duplicates
    }

    private func weeklySnapshotClusters(
        in reports: [UsageReport],
        now: Date
    ) -> [WeeklySnapshotCluster] {
        let candidates = Array(Set(reports
            .flatMap { $0.rateLimitSnapshots ?? [] }
            .filter { snapshot in
                snapshot.windowMinutes == Self.weeklyWindowMinutes
                    && snapshot.observedAt <= now
                    && snapshot.usedPercent.isFinite
                    && (0 ... 100).contains(snapshot.usedPercent)
                    && weeklyPeriodStart(for: snapshot) <= snapshot.observedAt
                    && snapshot.observedAt <= snapshot.resetsAt
            }))

        return Dictionary(grouping: candidates, by: \.limitId).values.flatMap { values in
            let ordered = values.sorted { lhs, rhs in
                if lhs.resetsAt != rhs.resetsAt { return lhs.resetsAt < rhs.resetsAt }
                return snapshotLessThan(lhs, rhs)
            }
            var clusters: [WeeklySnapshotCluster] = []
            for snapshot in ordered {
                if let index = clusters.indices.last,
                   snapshot.resetsAt.timeIntervalSince(clusters[index].anchorResetsAt)
                    <= Self.resetClusteringTolerance {
                    if snapshotLessThan(clusters[index].snapshot, snapshot) {
                        clusters[index].snapshot = snapshot
                    }
                } else {
                    clusters.append(
                        WeeklySnapshotCluster(
                            anchorResetsAt: snapshot.resetsAt,
                            snapshot: snapshot
                        )
                    )
                }
            }
            return clusters
        }
    }

    private func preferredCluster(
        in clusters: [WeeklySnapshotCluster]
    ) -> WeeklySnapshotCluster? {
        let codexClusters = clusters.filter { $0.snapshot.limitId == "codex" }
        return (codexClusters.isEmpty ? clusters : codexClusters).max { lhs, rhs in
            snapshotLessThan(lhs.snapshot, rhs.snapshot)
        }
    }

    private func clusterNewestFirst(
        _ lhs: WeeklySnapshotCluster,
        _ rhs: WeeklySnapshotCluster
    ) -> Bool {
        if lhs.snapshot.resetsAt != rhs.snapshot.resetsAt {
            return lhs.snapshot.resetsAt > rhs.snapshot.resetsAt
        }
        return snapshotLessThan(rhs.snapshot, lhs.snapshot)
    }

    private func weeklyPeriodStart(for snapshot: RateLimitSnapshot) -> Date {
        snapshot.resetsAt.addingTimeInterval(
            -TimeInterval(Self.weeklyWindowMinutes * 60)
        )
    }

    private func snapshotLessThan(_ lhs: RateLimitSnapshot, _ rhs: RateLimitSnapshot) -> Bool {
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
        if lhs.resetsAt != rhs.resetsAt { return lhs.resetsAt < rhs.resetsAt }
        if lhs.limitId != rhs.limitId { return lhs.limitId < rhs.limitId }
        return lhs.bucket < rhs.bucket
    }

    private func projectedAmount(currentAmount: Decimal?, usedPercent: Double) -> Decimal? {
        guard
            usedPercent > 0,
            let currentAmount,
            let percent = Decimal(
                string: String(usedPercent),
                locale: Locale(identifier: "en_US_POSIX")
            )
        else { return nil }
        return currentAmount * 100 / percent
    }

    private func projectedTokenCount(
        currentTokens: Int64?,
        usedPercent: Double
    ) -> Int64? {
        guard usedPercent > 0, let currentTokens else { return nil }
        guard currentTokens > 0 else { return 0 }
        guard let percent = Decimal(
            string: String(usedPercent),
            locale: Locale(identifier: "en_US_POSIX")
        ) else {
            return Int64.max
        }

        var projected = Decimal(currentTokens) * 100 / percent
        let maximum = Decimal(Int64.max)
        if projected.isNaN || projected >= maximum { return Int64.max }
        if projected <= 0 { return 0 }

        var rounded = Decimal()
        NSDecimalRound(&rounded, &projected, 0, .plain)
        if rounded >= maximum { return Int64.max }
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    private func uniqueWarnings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func observationLagText(_ interval: TimeInterval) -> String {
        let hours = max(Int(interval / 3_600), 1)
        if hours >= 48 { return "\(hours / 24) 天" }
        return "\(hours) 小时"
    }
}

private struct WeeklySnapshotCluster: Sendable {
    let anchorResetsAt: Date
    var snapshot: RateLimitSnapshot
}
