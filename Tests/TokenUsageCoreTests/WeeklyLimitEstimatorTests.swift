import Foundation
import Testing
@testable import TokenUsageCore

@Test("Weekly projection prefers the Codex weekly bucket regardless of primary or secondary")
func weeklyProjectionPrefersCodexBucket() throws {
    let report = try weeklyReport(
        id: "preferred",
        generatedAt: "2026-08-20T12:00:00Z",
        samples: [weeklySample("2026-08-20T10:00:00Z", input: 1_000_000)],
        snapshots: [
            weeklySnapshot(
                observedAt: "2026-08-20T11:30:00Z",
                limitId: "other",
                bucket: "primary",
                usedPercent: 80,
                windowMinutes: 10_080,
                resetsAt: "2026-08-24T00:00:00Z"
            ),
            weeklySnapshot(
                observedAt: "2026-08-20T11:00:00Z",
                limitId: "codex",
                limitName: "Codex",
                bucket: "secondary",
                usedPercent: 25,
                windowMinutes: 10_080,
                resetsAt: "2026-08-24T00:00:00Z"
            ),
            weeklySnapshot(
                observedAt: "2026-08-20T11:45:00Z",
                limitId: "codex",
                bucket: "primary",
                usedPercent: 99,
                windowMinutes: 300,
                resetsAt: "2026-08-20T16:00:00Z"
            )
        ]
    )

    let projection = try #require(weeklyEstimator().estimate(
        reports: [report],
        now: weeklyDate("2026-08-20T12:00:00Z")
    ))

    #expect(projection.snapshot.limitId == "codex")
    #expect(projection.snapshot.bucket == "secondary")
    #expect(projection.snapshot.usedPercent == 25)
    #expect(projection.currentAPIUSD == Decimal(string: "1"))
    #expect(projection.projectedAPIUSD == Decimal(string: "4"))
    #expect(projection.projectedFullTokens == 4_000_000)
    #expect(projection.isCompleted == false)
    #expect(projection.apiUSD.pricedTokens == 1_000_000)
    #expect(projection.confidence == .higher)
    #expect(projection.isApproximate == false)
}

@Test("Weekly confidence uses the documented percentage boundaries")
func weeklyConfidenceBoundaries() {
    #expect(WeeklyLimitConfidence(usedPercent: 0) == .insufficient)
    #expect(WeeklyLimitConfidence(usedPercent: 4.999) == .insufficient)
    #expect(WeeklyLimitConfidence(usedPercent: 5) == .low)
    #expect(WeeklyLimitConfidence(usedPercent: 9.999) == .low)
    #expect(WeeklyLimitConfidence(usedPercent: 10) == .medium)
    #expect(WeeklyLimitConfidence(usedPercent: 19.999) == .medium)
    #expect(WeeklyLimitConfidence(usedPercent: 20) == .higher)
    #expect(WeeklyLimitConfidence(usedPercent: 100) == .higher)
}

@Test("Zero percent retains current price but does not project")
func weeklyZeroPercentDoesNotProject() throws {
    let report = try weeklyReport(
        samples: [weeklySample("2026-08-20T10:00:00Z", input: 1_000_000)],
        snapshots: [weeklySnapshot(usedPercent: 0)]
    )

    let projection = try #require(weeklyEstimator().estimate(
        reports: [report],
        now: weeklyDate("2026-08-20T12:00:00Z")
    ))

    #expect(projection.currentAPIUSD == Decimal(string: "1"))
    #expect(projection.projectedAPIUSD == nil)
    #expect(projection.confidence == .insufficient)
    #expect(projection.warnings.contains { $0.contains("0%") })
}

@Test("A positive server percentage without local priced usage does not project zero dollars")
func weeklyMissingLocalUsageDoesNotProjectZero() throws {
    let report = try weeklyReport(
        samples: [],
        snapshots: [weeklySnapshot(usedPercent: 20)]
    )

    let projection = try #require(weeklyEstimator().estimate(
        reports: [report],
        now: weeklyDate("2026-08-20T12:00:00Z")
    ))

    #expect(projection.currentAPIUSD == nil)
    #expect(projection.projectedAPIUSD == nil)
    #expect(projection.warnings.contains { $0.contains("没有可用") })
}

@Test("Expired, future-observed, invalid-percentage, and non-weekly snapshots are ignored")
func weeklyInvalidSnapshotsAreIgnored() throws {
    let report = try weeklyReport(
        samples: [],
        snapshots: [
            weeklySnapshot(
                observedAt: "2026-08-20T11:00:00Z",
                usedPercent: 20,
                resetsAt: "2026-08-20T12:00:00Z"
            ),
            weeklySnapshot(
                observedAt: "2026-08-20T12:01:00Z",
                usedPercent: 20
            ),
            weeklySnapshot(usedPercent: 100.1),
            weeklySnapshot(usedPercent: 20, windowMinutes: 300)
        ]
    )

    let projection = try weeklyEstimator().estimate(
        reports: [report],
        now: try weeklyDate("2026-08-20T12:00:00Z")
    )

    #expect(projection == nil)
}

@Test("Latest valid non-Codex weekly bucket is used as a fallback")
func weeklySnapshotFallsBackToLatestBucket() throws {
    let report = try weeklyReport(
        samples: [],
        snapshots: [
            weeklySnapshot(
                observedAt: "2026-08-20T10:00:00Z",
                limitId: "alpha",
                usedPercent: 20
            ),
            weeklySnapshot(
                observedAt: "2026-08-20T11:00:00Z",
                limitId: "beta",
                usedPercent: 30
            ),
            weeklySnapshot(
                observedAt: "2026-08-20T11:30:00Z",
                limitId: "codex",
                usedPercent: 90,
                resetsAt: "2026-08-20T11:59:59Z"
            )
        ]
    )

    let projection = try #require(weeklyEstimator().estimate(
        reports: [report],
        now: weeklyDate("2026-08-20T12:00:00Z")
    ))

    #expect(projection.snapshot.limitId == "beta")
    #expect(projection.snapshot.usedPercent == 30)
}

@Test("Weekly projection clips usage to the reset window and observation minute")
func weeklyProjectionClipsUsageWindow() throws {
    let report = try weeklyReport(
        samples: [
            weeklySample("2026-08-16T23:59:00Z", input: 8_000_000),
            weeklySample("2026-08-17T00:00:00Z", input: 1_000_000),
            weeklySample("2026-08-20T12:00:00Z", input: 1_000_000),
            weeklySample("2026-08-20T12:01:00Z", input: 8_000_000)
        ],
        snapshots: [
            weeklySnapshot(
                observedAt: "2026-08-20T12:00:00Z",
                usedPercent: 50,
                resetsAt: "2026-08-24T00:00:00Z"
            )
        ]
    )

    let projection = try #require(weeklyEstimator().estimate(
        reports: [report],
        now: weeklyDate("2026-08-20T12:00:00Z")
    ))

    let expectedPeriodStart = try weeklyDate("2026-08-17T00:00:00Z")
    #expect(projection.periodStart == expectedPeriodStart)
    #expect(projection.currentAPIUSD == Decimal(string: "2"))
    #expect(projection.projectedAPIUSD == Decimal(string: "4"))
}

@Test("Duplicate root reports use only the newest generated report")
func weeklyProjectionDeduplicatesRootReports() throws {
    let old = try weeklyReport(
        id: "duplicate",
        generatedAt: "2026-08-20T10:00:00Z",
        samples: [weeklySample("2026-08-20T09:00:00Z", input: 10_000_000)],
        snapshots: [
            weeklySnapshot(observedAt: "2026-08-20T11:59:00Z", usedPercent: 90)
        ]
    )
    let newest = try weeklyReport(
        id: "duplicate",
        generatedAt: "2026-08-20T11:00:00Z",
        samples: [weeklySample("2026-08-20T09:00:00Z", input: 1_000_000)],
        snapshots: [
            weeklySnapshot(observedAt: "2026-08-20T11:00:00Z", usedPercent: 50)
        ]
    )
    let other = try weeklyReport(
        id: "other-root",
        generatedAt: "2026-08-20T11:00:00Z",
        samples: [weeklySample("2026-08-20T09:00:00Z", input: 2_000_000)],
        snapshots: []
    )

    let projection = try #require(weeklyEstimator().estimate(
        reports: [old, newest, other],
        now: weeklyDate("2026-08-20T12:00:00Z")
    ))

    #expect(projection.snapshot.usedPercent == 50)
    #expect(projection.currentAPIUSD == Decimal(string: "3"))
    #expect(projection.projectedAPIUSD == Decimal(string: "6"))
    #expect(projection.warnings.contains { $0.contains("重复会话 ID") })
}

@Test("Partial API pricing is projected as an explicitly partial subtotal")
func weeklyProjectionPreservesPartialPricing() throws {
    let report = try weeklyReport(
        samples: [
            weeklySample("2026-08-20T10:00:00Z", model: "priced-model", input: 1_000_000),
            weeklySample("2026-08-20T10:01:00Z", model: "unknown-model", input: 1_000_000)
        ],
        snapshots: [weeklySnapshot(usedPercent: 50)]
    )

    let projection = try #require(weeklyEstimator().estimate(
        reports: [report],
        now: weeklyDate("2026-08-20T12:00:00Z")
    ))

    #expect(projection.apiUSD.amount == Decimal(string: "1"))
    #expect(projection.apiUSD.pricedTokens == 1_000_000)
    #expect(projection.apiUSD.totalTokens == 2_000_000)
    #expect(projection.apiUSD.isPartial)
    #expect(projection.projectedAPIUSD == Decimal(string: "2"))
    #expect(projection.warnings.contains { $0.contains("覆盖不完整") })
}

@Test("Legacy segment fallback propagates its approximation marker")
func weeklyProjectionPreservesApproximation() throws {
    let report = try weeklyReport(
        samples: nil,
        segments: [weeklySegment("2026-08-20T10:00:00Z", input: 1_000_000)],
        snapshots: [weeklySnapshot(usedPercent: 20)]
    )

    let projection = try #require(weeklyEstimator().estimate(
        reports: [report],
        now: weeklyDate("2026-08-20T12:00:00Z")
    ))

    #expect(projection.isApproximate)
    #expect(projection.warnings.contains { $0.contains("旧报告") })
}

@Test("Weekly overview clusters reset jitter across buckets and uses the latest observation")
func weeklyOverviewClustersJitterAcrossBuckets() throws {
    let report = try weeklyReport(
        samples: [
            weeklySample("2026-08-16T11:00:00Z", input: 1_000_000),
            weeklySample("2026-08-20T10:00:00Z", input: 2_000_000)
        ],
        snapshots: [
            weeklySnapshot(
                observedAt: "2026-08-16T10:00:00Z",
                bucket: "primary",
                usedPercent: 90,
                resetsAt: "2026-08-17T00:00:00Z"
            ),
            weeklySnapshot(
                observedAt: "2026-08-16T12:00:00Z",
                bucket: "secondary",
                usedPercent: 50,
                resetsAt: "2026-08-17T00:00:28Z"
            ),
            weeklySnapshot(
                observedAt: "2026-08-20T11:00:00Z",
                bucket: "primary",
                usedPercent: 20,
                resetsAt: "2026-08-24T00:00:28Z"
            )
        ]
    )

    let overview = try weeklyEstimator().overview(
        reports: [report],
        now: weeklyDate("2026-08-20T12:00:00Z")
    )
    let current = try #require(overview.current)
    let history = try #require(overview.history.first)
    let expectedHistoryEnd = try weeklyDate("2026-08-17T00:00:28Z")
    let expectedHistoryCutoff = try weeklyDate("2026-08-16T12:00:00Z")

    #expect(current.snapshot.usedPercent == 20)
    #expect(current.isCompleted == false)
    #expect(overview.history.count == 1)
    #expect(history.snapshot.bucket == "secondary")
    #expect(history.snapshot.usedPercent == 50)
    #expect(history.periodEnd == expectedHistoryEnd)
    #expect(history.observationCutoff == expectedHistoryCutoff)
    #expect(history.observedTokens == 1_000_000)
    #expect(history.currentAPIUSD == Decimal(string: "1"))
    #expect(history.projectedFullTokens == 2_000_000)
    #expect(history.projectedFullAPIUSD == Decimal(string: "2"))
    #expect(history.isCompleted)
}

@Test("Completed weekly periods count only through their latest observation cutoff")
func weeklyOverviewClipsCompletedPeriodBoundaries() throws {
    let report = try weeklyReport(
        samples: [
            weeklySample("2026-08-09T23:59:00Z", input: 8_000_000),
            weeklySample("2026-08-10T00:00:00Z", input: 1_000_000),
            weeklySample("2026-08-16T23:58:00Z", input: 1_000_000),
            weeklySample("2026-08-16T23:59:00Z", input: 8_000_000)
        ],
        snapshots: [
            weeklySnapshot(
                observedAt: "2026-08-16T23:58:00Z",
                usedPercent: 50,
                resetsAt: "2026-08-17T00:00:00Z"
            )
        ]
    )

    let overview = try weeklyEstimator().overview(
        reports: [report],
        now: weeklyDate("2026-08-20T12:00:00Z")
    )
    let history = try #require(overview.history.first)
    let expectedStart = try weeklyDate("2026-08-10T00:00:00Z")
    let expectedCutoff = try weeklyDate("2026-08-16T23:58:00Z")

    #expect(overview.current == nil)
    #expect(history.periodStart == expectedStart)
    #expect(history.observationCutoff == expectedCutoff)
    #expect(history.observedTokens == 2_000_000)
    #expect(history.projectedFullTokens == 4_000_000)
    #expect(history.isCompleted)
}

@Test("Completed history warns when its final observation is stale")
func weeklyOverviewWarnsAboutStaleHistoryObservation() throws {
    let report = try weeklyReport(
        samples: [weeklySample("2026-08-15T12:00:00Z", input: 1_000_000)],
        snapshots: [
            weeklySnapshot(
                observedAt: "2026-08-15T12:00:00Z",
                usedPercent: 25,
                resetsAt: "2026-08-17T00:00:00Z"
            )
        ]
    )

    let overview = try weeklyEstimator().overview(
        reports: [report],
        now: weeklyDate("2026-08-20T12:00:00Z")
    )
    let history = try #require(overview.history.first)

    #expect(history.isFinalObservationStale)
    #expect(history.observationLagToReset == 36 * 60 * 60)
    #expect(history.warnings.contains { $0.contains("最终使用可能不完整") })
}

@Test("Weekly history is newest-first and defaults and clamps to eight periods")
func weeklyOverviewHistoryOrderingAndLimit() throws {
    let snapshots = [
        ("2026-08-16T23:00:00Z", "2026-08-17T00:00:00Z"),
        ("2026-08-09T23:00:00Z", "2026-08-10T00:00:00Z"),
        ("2026-08-02T23:00:00Z", "2026-08-03T00:00:00Z"),
        ("2026-07-26T23:00:00Z", "2026-07-27T00:00:00Z"),
        ("2026-07-19T23:00:00Z", "2026-07-20T00:00:00Z"),
        ("2026-07-12T23:00:00Z", "2026-07-13T00:00:00Z"),
        ("2026-07-05T23:00:00Z", "2026-07-06T00:00:00Z"),
        ("2026-06-28T23:00:00Z", "2026-06-29T00:00:00Z"),
        ("2026-06-21T23:00:00Z", "2026-06-22T00:00:00Z")
    ].map { observedAt, resetsAt in
        weeklySnapshot(
            observedAt: observedAt,
            usedPercent: 25,
            resetsAt: resetsAt
        )
    }
    let report = try weeklyReport(samples: [], snapshots: snapshots)
    let now = try weeklyDate("2026-08-20T12:00:00Z")
    let expectedNewestEnd = try weeklyDate("2026-08-17T00:00:00Z")
    let expectedOldestRetainedEnd = try weeklyDate("2026-06-29T00:00:00Z")

    let defaultOverview = try weeklyEstimator().overview(reports: [report], now: now)
    let oversizedOverview = try weeklyEstimator().overview(
        reports: [report],
        now: now,
        historyLimit: 99
    )
    let shortOverview = try weeklyEstimator().overview(
        reports: [report],
        now: now,
        historyLimit: 2
    )

    #expect(defaultOverview.computedAt == now)
    #expect(defaultOverview.history.count == 8)
    #expect(oversizedOverview.history.count == WeeklyLimitEstimator.maximumHistoryPeriods)
    #expect(shortOverview.history.count == 2)
    #expect(defaultOverview.history.first?.periodEnd == expectedNewestEnd)
    #expect(defaultOverview.history.last?.periodEnd == expectedOldestRetainedEnd)
    #expect(defaultOverview.history.allSatisfy { $0.isCompleted })
}

@Test("Projected weekly token equivalent saturates safely")
func weeklyProjectedTokensSaturate() throws {
    let report = try weeklyReport(
        samples: [weeklySample("2026-08-20T10:00:00Z", input: Int64.max)],
        snapshots: [weeklySnapshot(usedPercent: 50)]
    )

    let projection = try #require(weeklyEstimator().estimate(
        reports: [report],
        now: weeklyDate("2026-08-20T12:00:00Z")
    ))

    #expect(projection.observedTokens == Int64.max)
    #expect(projection.projectedFullTokens == Int64.max)
}

@Test("An early reset retains the previous weekly period and its observed usage")
func weeklyOverviewRetainsEarlyResetHistory() throws {
    let report = try weeklyReport(
        generatedAt: "2026-09-10T02:00:00Z",
        samples: [
            weeklySample("2026-09-08T01:23:00Z", input: 8_000_000),
            weeklySample("2026-09-08T01:24:00Z", input: 1_000_000),
            weeklySample("2026-09-09T03:00:00Z", input: 2_000_000),
            weeklySample("2026-09-10T00:10:00Z", input: 3_000_000),
            weeklySample("2026-09-10T00:11:00Z", input: 8_000_000),
            weeklySample("2026-09-10T01:50:00Z", input: 4_000_000),
            weeklySample("2026-09-10T02:01:00Z", input: 8_000_000)
        ],
        snapshots: [
            weeklySnapshot(
                observedAt: "2026-09-07T23:00:00Z",
                usedPercent: 90,
                resetsAt: "2026-09-08T01:24:00Z"
            ),
            weeklySnapshot(
                observedAt: "2026-09-10T00:10:00Z",
                usedPercent: 98,
                resetsAt: "2026-09-15T01:24:00Z"
            ),
            weeklySnapshot(
                observedAt: "2026-09-10T01:49:34Z",
                usedPercent: 0,
                resetsAt: "2026-09-17T01:49:14Z"
            ),
            weeklySnapshot(
                observedAt: "2026-09-10T02:00:00Z",
                bucket: "primary",
                usedPercent: 1,
                resetsAt: "2026-09-17T01:49:27Z"
            )
        ]
    )
    let overview = try weeklyEstimator().overview(
        reports: [report],
        now: weeklyDate("2026-09-10T02:00:00Z")
    )
    let current = try #require(overview.current)
    let history = try #require(overview.history.first)
    let oldStart = try weeklyDate("2026-09-08T01:24:00Z")
    let oldScheduledReset = try weeklyDate("2026-09-15T01:24:00Z")
    let newStart = try weeklyDate("2026-09-10T01:49:27Z")
    let newReset = try weeklyDate("2026-09-17T01:49:27Z")
    let oldCutoff = try weeklyDate("2026-09-10T00:10:00Z")

    #expect(overview.history.count == 2)
    #expect(history.periodStart == oldStart)
    #expect(history.periodEnd == newStart)
    #expect(history.snapshot.resetsAt == oldScheduledReset)
    #expect(history.observationCutoff == oldCutoff)
    #expect(history.snapshot.usedPercent == 98)
    #expect(history.observedTokens == 6_000_000)
    #expect(history.currentAPIUSD == Decimal(string: "6"))
    #expect(history.isCompleted)
    #expect(history.observationLagToReset == 5_967)
    #expect(!history.isFinalObservationStale)
    #expect(!history.warnings.contains { $0.contains("最终使用可能不完整") })
    #expect(overview.history.last?.periodEnd == oldStart)
    #expect(current.periodStart == newStart)
    #expect(current.periodEnd == newReset)
    #expect(current.snapshot.usedPercent == 1)
    #expect(current.observedTokens == 4_000_000)
    #expect(current.currentAPIUSD == Decimal(string: "4"))
    #expect(!current.isCompleted)
}

@Test("Reset jitter alone never ends an active weekly period")
func weeklyOverviewDoesNotTreatResetJitterAsEarlyReset() throws {
    let report = try weeklyReport(
        samples: [],
        snapshots: [
            weeklySnapshot(
                observedAt: "2026-08-20T10:00:00Z",
                bucket: "primary",
                usedPercent: 20,
                resetsAt: "2026-08-24T00:00:00Z"
            ),
            weeklySnapshot(
                observedAt: "2026-08-20T11:00:00Z",
                bucket: "secondary",
                usedPercent: 21,
                resetsAt: "2026-08-24T00:00:28Z"
            )
        ]
    )
    let overview = try weeklyEstimator().overview(
        reports: [report],
        now: weeklyDate("2026-08-20T12:00:00Z")
    )
    let current = try #require(overview.current)
    let expectedReset = try weeklyDate("2026-08-24T00:00:28Z")

    #expect(overview.history.isEmpty)
    #expect(current.snapshot.usedPercent == 21)
    #expect(current.periodEnd == expectedReset)
    #expect(!current.isCompleted)
}

@Test("A slightly early natural rollover keeps the original historical reset")
func weeklyOverviewPreservesNaturalResetDespiteJitter() throws {
    let report = try weeklyReport(
        samples: [],
        snapshots: [
            weeklySnapshot(
                observedAt: "2026-08-16T23:00:00Z",
                usedPercent: 95,
                resetsAt: "2026-08-17T00:00:28Z"
            ),
            weeklySnapshot(
                observedAt: "2026-08-20T11:00:00Z",
                usedPercent: 20,
                resetsAt: "2026-08-24T00:00:00Z"
            )
        ]
    )
    let overview = try weeklyEstimator().overview(
        reports: [report],
        now: weeklyDate("2026-08-20T12:00:00Z")
    )
    let history = try #require(overview.history.first)

    #expect(overview.history.count == 1)
    #expect(history.periodEnd == history.snapshot.resetsAt)
    #expect(history.observationLagToReset == 3_628)
}

@Test("Another limit ID cannot end the Codex weekly period")
func weeklyOverviewDoesNotMixLimitIDsWhenInferringEarlyResets() throws {
    let report = try weeklyReport(
        samples: [],
        snapshots: [
            weeklySnapshot(
                observedAt: "2026-09-09T12:00:00Z",
                usedPercent: 98,
                resetsAt: "2026-09-15T01:24:00Z"
            ),
            weeklySnapshot(
                observedAt: "2026-09-10T02:00:00Z",
                limitId: "other",
                usedPercent: 1,
                resetsAt: "2026-09-17T01:49:00Z"
            )
        ]
    )
    let overview = try weeklyEstimator().overview(
        reports: [report],
        now: weeklyDate("2026-09-10T02:00:00Z")
    )
    let current = try #require(overview.current)

    #expect(overview.history.isEmpty)
    #expect(current.snapshot.limitId == "codex")
    #expect(current.snapshot.usedPercent == 98)
    #expect(current.periodEnd == current.snapshot.resetsAt)
}

@Test("Conflicting old snapshots and stale buckets cannot falsely close a current period",
      arguments: ["2026-09-10T01:40:00Z", "2026-09-10T02:10:00Z"])
func weeklyOverviewDoesNotInferEarlyResetAcrossConflictingObservations(
    laterResetObservedAt: String
) throws {
    let report = try weeklyReport(
        samples: [],
        snapshots: [
            weeklySnapshot(
                observedAt: "2026-09-10T02:00:00Z",
                bucket: "secondary",
                usedPercent: 98,
                resetsAt: "2026-09-15T01:24:00Z"
            ),
            weeklySnapshot(
                observedAt: laterResetObservedAt,
                bucket: "primary",
                usedPercent: 1,
                resetsAt: "2026-09-17T01:30:00Z"
            )
        ]
    )
    let overview = try weeklyEstimator().overview(
        reports: [report],
        now: weeklyDate("2026-09-10T03:00:00Z")
    )
    let current = try #require(overview.current)

    #expect(overview.history.isEmpty)
    #expect(current.snapshot.bucket == (laterResetObservedAt == "2026-09-10T01:40:00Z"
        ? "secondary" : "primary"))
    #expect(current.periodEnd == current.snapshot.resetsAt)
    #expect(!current.isCompleted)
}

@Test("Early reset history measures stale observation warnings against its actual end")
func weeklyOverviewEarlyResetStalenessUsesEffectiveEnd() throws {
    let report = try weeklyReport(
        samples: [],
        snapshots: [
            weeklySnapshot(
                observedAt: "2026-09-09T18:49:00Z",
                usedPercent: 98,
                resetsAt: "2026-09-15T01:24:00Z"
            ),
            weeklySnapshot(
                observedAt: "2026-09-10T02:00:00Z",
                usedPercent: 1,
                resetsAt: "2026-09-17T01:49:00Z"
            )
        ]
    )
    let overview = try weeklyEstimator().overview(
        reports: [report],
        now: weeklyDate("2026-09-10T02:00:00Z")
    )
    let history = try #require(overview.history.first)

    #expect(history.isFinalObservationStale)
    #expect(history.observationLagToReset == 7 * 60 * 60)
    #expect(history.warnings.contains { $0.contains("距离重置约 7 小时") })
}

private func weeklyEstimator() throws -> WeeklyLimitEstimator {
    WeeklyLimitEstimator(catalog: try weeklyCatalog(), calendar: weeklyCalendar())
}

private func weeklyCatalog() throws -> PricingCatalog {
    let object: [String: Any] = [
        "schema_version": 1,
        "catalog_id": "weekly-limit-tests",
        "observed_at": "2026-08-20",
        "token_unit": 1_000_000,
        "scope": "tests",
        "models": [
            "priced-model": [
                "display_name": "Priced Model",
                "aliases": [],
                "api_usd": [
                    "standard": [
                        "short": [
                            "input": "1",
                            "cached_input": "0.1",
                            "cache_write": "1.25",
                            "output": "2"
                        ]
                    ]
                ]
            ]
        ]
    ]
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(
        PricingCatalog.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
}

private func weeklyReport(
    id: String = UUID().uuidString,
    generatedAt: String = "2026-08-20T12:00:00Z",
    samples: [[String: Any]]?,
    segments: [[String: Any]] = [],
    snapshots: [[String: Any]]
) throws -> UsageReport {
    let usageObjects = (samples ?? segments).compactMap { $0["usage"] as? [String: Any] }
    let usage = weeklySumUsage(usageObjects)
    let zero = weeklyUsage()
    let counts: [String: Any] = [
        "image_inputs": 0,
        "audio_inputs": 0,
        "image_generations": 0,
        "web_searches": 0,
        "mcp_calls": 0,
        "tool_calls": 0
    ]
    var task: [String: Any] = [
        "usage": usage,
        "counts": counts,
        "root_usage": usage,
        "agents_usage": zero,
        "segments": segments,
        "cost": [:],
        "linked_agent_threads": 0,
        "usage_is_lower_bound": false
    ]
    if let samples { task["usage_samples"] = samples }
    let object: [String: Any] = [
        "report_schema_version": 1,
        "generated_at": generatedAt,
        "root_thread_id": id,
        "rate_limit_snapshots": snapshots,
        "current_turn": [
            "available": false,
            "usage_is_provisional": false,
            "usage": zero,
            "counts": counts,
            "root_usage": zero,
            "agents_usage": zero,
            "segments": [],
            "cost": [:]
        ],
        "task": task,
        "threads": [],
        "completeness": [:],
        "warnings": [],
        "pricing_catalog": [:]
    ]
    return try UsageReportDecoder.decode(JSONSerialization.data(withJSONObject: object))
}

private func weeklySnapshot(
    observedAt: String = "2026-08-20T11:00:00Z",
    limitId: String = "codex",
    limitName: String? = nil,
    bucket: String = "secondary",
    usedPercent: Double,
    windowMinutes: Int64 = 10_080,
    resetsAt: String = "2026-08-24T00:00:00Z"
) -> [String: Any] {
    var snapshot: [String: Any] = [
        "observed_at": observedAt,
        "limit_id": limitId,
        "bucket": bucket,
        "used_percent": usedPercent,
        "window_minutes": windowMinutes,
        "resets_at": resetsAt
    ]
    if let limitName { snapshot["limit_name"] = limitName }
    return snapshot
}

private func weeklySample(
    _ minute: String,
    model: String = "priced-model",
    input: Int64
) -> [String: Any] {
    [
        "minute": minute,
        "model": model,
        "effort": "medium",
        "tier": "default",
        "tier_source": "thread_settings",
        "long_context": false,
        "usage": weeklyUsage(input: input),
        "request_count": 1
    ]
}

private func weeklySegment(
    _ lastAt: String,
    model: String = "priced-model",
    input: Int64
) -> [String: Any] {
    var segment = weeklySample(lastAt, model: model, input: input)
    segment.removeValue(forKey: "minute")
    segment["first_at"] = lastAt
    segment["last_at"] = lastAt
    return segment
}

private func weeklyUsage(input: Int64 = 0) -> [String: Any] {
    [
        "input_tokens": input,
        "cached_input_tokens": 0,
        "cache_write_input_tokens": 0,
        "output_tokens": 0,
        "reasoning_output_tokens": 0,
        "total_tokens": input
    ]
}

private func weeklySumUsage(_ values: [[String: Any]]) -> [String: Any] {
    weeklyUsage(input: values.reduce(Int64.zero) { partial, usage in
        partial + (usage["input_tokens"] as? Int64 ?? 0)
    })
}

private func weeklyDate(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return try #require(formatter.date(from: value))
}

private func weeklyCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}
