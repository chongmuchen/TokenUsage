import Foundation
import Testing
@testable import TokenUsageCore

@Test("Daily quota uses yesterday's final weekly observation as today's start")
func dailyQuotaCarriesPreviousDay() throws {
    let report = try quotaReport(observations: [
        quotaSnapshot("2026-08-19T23:00:00Z", used: 20),
        quotaSnapshot("2026-08-20T09:00:00Z", used: 25),
        quotaSnapshot("2026-08-20T18:00:00Z", used: 35)
    ])
    let result = try quotaTrend([report], from: "2026-08-20T00:00:00Z", through: "2026-08-20T23:00:00Z")

    #expect(result.points.count == 1)
    let point = try #require(result.points.first)
    #expect(point.startRemainingPercent == 80)
    #expect(point.cumulativeUsedPercent == 15)
    #expect(point.isReset == false)
    #expect(point.isApproximate)
    #expect(point.day == quotaDate("2026-08-20T00:00:00Z"))
}

@Test("Reset day has two real observation points and does not fill old window to 100")
func dailyQuotaResetAndPrice() throws {
    let report = try quotaReport(
        samples: [
            quotaSample("2026-08-20T09:00:00Z", input: 1_000_000),
            quotaSample("2026-08-20T13:00:00Z", input: 1_000_000)
        ],
        observations: [
            quotaSnapshot("2026-08-19T23:00:00Z", used: 20),
            quotaSnapshot("2026-08-20T10:00:00Z", used: 30),
            quotaSnapshot("2026-08-20T14:00:00Z", used: 5, reset: "2026-08-27T12:00:00Z")
        ]
    )
    let points = try quotaTrend([report], from: "2026-08-20T00:00:00Z", through: "2026-08-20T23:00:00Z").points

    #expect(points.count == 2)
    #expect(points[0].startRemainingPercent == 80)
    #expect(points[0].cumulativeUsedPercent == 10)
    #expect(points[0].usdPerPercent == Decimal(string: "0.1"))
    #expect(points[1].startRemainingPercent == 100)
    #expect(points[1].cumulativeUsedPercent == 15)
    let secondPrice = try #require(points[1].usdPerPercent)
    #expect(abs(NSDecimalNumber(decimal: secondPrice).doubleValue - 2.0 / 15.0) < 0.0000001)
    #expect(points[1].isReset)
    #expect(points[1].isApproximate)
}

@Test("Multiple resets on one local day retain each segment")
func dailyQuotaMultipleResets() throws {
    let report = try quotaReport(observations: [
        quotaSnapshot("2026-08-19T23:00:00Z", used: 40),
        quotaSnapshot("2026-08-20T10:00:00Z", used: 45),
        quotaSnapshot("2026-08-20T13:00:00Z", used: 4, reset: "2026-08-27T12:00:00Z"),
        quotaSnapshot("2026-08-20T20:00:00Z", used: 7, reset: "2026-08-27T19:00:00Z")
    ])
    let points = try quotaTrend([report], from: "2026-08-20T00:00:00Z", through: "2026-08-20T23:00:00Z").points

    #expect(points.count == 3)
    #expect(points.map(\.cumulativeUsedPercent) == [5, 9, 16])
    #expect(points.map(\.isReset) == [false, true, true])
    #expect(Set(points.map(\.id)).count == 3)
}

@Test("The first observed window starting today infers a zero-used reset baseline")
func dailyQuotaFirstWindowStartToday() throws {
    let report = try quotaReport(observations: [
        quotaSnapshot("2026-08-20T13:00:00Z", used: 4, reset: "2026-08-27T12:00:00Z")
    ])
    let points = try quotaTrend([report], from: "2026-08-20T00:00:00Z", through: "2026-08-20T23:00:00Z").points

    #expect(points.count == 1)
    #expect(points[0].startRemainingPercent == 100)
    #expect(points[0].cumulativeUsedPercent == 4)
    #expect(points[0].isReset)
    #expect(points[0].isApproximate)
}

@Test("Small reset timestamp jitter stays in one weekly period")
func dailyQuotaResetJitter() throws {
    let report = try quotaReport(observations: [
        quotaSnapshot("2026-08-19T23:00:00Z", used: 20),
        quotaSnapshot("2026-08-20T10:00:00Z", used: 30),
        quotaSnapshot("2026-08-20T18:00:00Z", used: 40, reset: "2026-08-24T00:03:00Z")
    ])
    let points = try quotaTrend([report], from: "2026-08-20T00:00:00Z", through: "2026-08-20T23:00:00Z").points

    #expect(points.count == 1)
    #expect(points[0].cumulativeUsedPercent == 20)
    #expect(points[0].isReset == false)
}

@Test("A missing day stays empty; the next day starts at its first observation")
func dailyQuotaMissingDayDoesNotInventUse() throws {
    let report = try quotaReport(observations: [
        quotaSnapshot("2026-08-18T12:00:00Z", used: 20),
        quotaSnapshot("2026-08-20T09:00:00Z", used: 30),
        quotaSnapshot("2026-08-20T17:00:00Z", used: 35)
    ])
    let result = try quotaTrend([report], from: "2026-08-19T00:00:00Z", through: "2026-08-20T23:00:00Z")

    #expect(result.points.count == 1)
    #expect(result.points[0].startRemainingPercent == 70)
    #expect(result.points[0].cumulativeUsedPercent == 5)
    #expect(result.points[0].isApproximate)
    #expect(result.points[0].isReset == false)
}

@Test("A quota drop within one period leaves usage and USD blank")
func dailyQuotaUnexplainedDropIsGap() throws {
    let report = try quotaReport(
        samples: [quotaSample("2026-08-20T09:00:00Z", input: 1_000_000)],
        observations: [
            quotaSnapshot("2026-08-19T23:00:00Z", used: 30),
            quotaSnapshot("2026-08-20T09:30:00Z", used: 35),
            quotaSnapshot("2026-08-20T10:00:00Z", used: 32)
        ]
    )
    let result = try quotaTrend([report], from: "2026-08-20T00:00:00Z", through: "2026-08-20T23:00:00Z")

    #expect(result.points.count == 1)
    #expect(result.points[0].cumulativeUsedPercent == nil)
    #expect(result.points[0].usdPerPercent == nil)
    #expect(result.warnings.contains { $0.contains("下降") })
}

@Test("A new period first observed a day after reset is an approximate start, not today's reset")
func dailyQuotaResetWasYesterday() throws {
    let report = try quotaReport(observations: [
        quotaSnapshot("2026-08-19T10:00:00Z", used: 40),
        quotaSnapshot("2026-08-21T09:00:00Z", used: 8, reset: "2026-08-27T12:00:00Z"),
        quotaSnapshot("2026-08-21T12:00:00Z", used: 10, reset: "2026-08-27T12:00:00Z")
    ])
    let points = try quotaTrend([report], from: "2026-08-21T00:00:00Z", through: "2026-08-21T23:00:00Z").points

    #expect(points.count == 1)
    #expect(points[0].isReset == false)
    #expect(points[0].startRemainingPercent == 92)
    #expect(points[0].cumulativeUsedPercent == 2)
    #expect(points[0].isApproximate)
}

@Test("Duplicate root reports use the newest copy for quota and price")
func dailyQuotaDeduplicatesReports() throws {
    let old = try quotaReport(
        id: "same-root", generatedAt: "2026-08-20T12:00:00Z",
        samples: [quotaSample("2026-08-20T09:00:00Z", input: 1_000_000)],
        observations: [quotaSnapshot("2026-08-20T10:00:00Z", used: 20)]
    )
    let latest = try quotaReport(
        id: "same-root", generatedAt: "2026-08-20T20:00:00Z",
        samples: [quotaSample("2026-08-20T09:00:00Z", input: 2_000_000)],
        observations: [
            quotaSnapshot("2026-08-20T10:00:00Z", used: 20),
            quotaSnapshot("2026-08-20T18:00:00Z", used: 30)
        ]
    )
    let result = try quotaTrend([old, latest], from: "2026-08-20T00:00:00Z", through: "2026-08-20T23:00:00Z")

    #expect(result.points.count == 1)
    #expect(result.points[0].cumulativeUsedPercent == 10)
    #expect(result.points[0].usdPerPercent == Decimal(string: "0.2"))
    #expect(result.warnings.contains { $0.contains("重复会话") })
}

@Test("Unpriced usage marks the USD per percent as approximate")
func dailyQuotaPartialPrice() throws {
    let report = try quotaReport(
        samples: [
            quotaSample("2026-08-20T09:00:00Z", input: 1_000_000),
            quotaSample("2026-08-20T09:01:00Z", model: "unpriced", input: 1_000_000)
        ],
        observations: [
            quotaSnapshot("2026-08-19T23:00:00Z", used: 20),
            quotaSnapshot("2026-08-20T10:00:00Z", used: 30)
        ]
    )
    let result = try quotaTrend([report], from: "2026-08-20T00:00:00Z", through: "2026-08-20T23:00:00Z")

    #expect(result.points[0].usdPerPercent == Decimal(string: "0.1"))
    #expect(result.points[0].isApproximate)
    #expect(result.warnings.contains { $0.contains("缺少 API USD") })
}

private func quotaTrend(_ reports: [UsageReport], from start: String, through end: String) throws -> DailyQuotaTrend {
    DailyQuotaTrendAggregator(catalog: try quotaCatalog(), calendar: quotaCalendar()).aggregate(
        reports: reports,
        startDate: try #require(quotaDate(start)),
        endDate: try #require(quotaDate(end))
    )
}

private func quotaCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func quotaDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}

private func quotaCatalog() throws -> PricingCatalog {
    let object: [String: Any] = [
        "schema_version": 1,
        "catalog_id": "daily-quota-tests",
        "observed_at": "2026-08-20",
        "token_unit": 1_000_000,
        "scope": "tests",
        "models": [
            "priced-model": [
                "display_name": "Priced Model",
                "aliases": [],
                "api_usd": [
                    "standard": ["short": [
                        "input": "1", "cached_input": "0.1",
                        "cache_write": "1.25", "output": "2"
                    ]]
                ]
            ]
        ]
    ]
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(PricingCatalog.self, from: JSONSerialization.data(withJSONObject: object))
}

private func quotaReport(
    id: String = UUID().uuidString,
    generatedAt: String = "2026-08-20T22:00:00Z",
    samples: [[String: Any]] = [],
    observations: [[String: Any]]
) throws -> UsageReport {
    let input = samples.reduce(Int64.zero) { $0 + ($1["input"] as? Int64 ?? 0) }
    let usage = quotaUsage(input: input)
    let zero = quotaUsage(input: 0)
    let counts: [String: Any] = [
        "image_inputs": 0, "audio_inputs": 0, "image_generations": 0,
        "web_searches": 0, "mcp_calls": 0, "tool_calls": 0
    ]
    let object: [String: Any] = [
        "report_schema_version": 1,
        "generated_at": generatedAt,
        "root_thread_id": id,
        "rate_limit_observations": observations,
        "current_turn": [
            "available": false, "usage_is_provisional": false,
            "usage": zero, "counts": counts, "root_usage": zero,
            "agents_usage": zero, "segments": [], "cost": [:]
        ],
        "task": [
            "usage": usage, "counts": counts,
            "root_usage": usage, "agents_usage": zero,
            "usage_samples": samples,
            "segments": [], "cost": [:],
            "linked_agent_threads": 0,
            "usage_is_lower_bound": false
        ],
        "threads": [], "completeness": [:], "warnings": [], "pricing_catalog": [:]
    ]
    return try UsageReportDecoder.decode(JSONSerialization.data(withJSONObject: object))
}

private func quotaSnapshot(
    _ at: String,
    used: Double,
    reset: String = "2026-08-24T00:00:00Z"
) -> [String: Any] {
    [
        "observed_at": at, "limit_id": "codex", "bucket": "secondary",
        "used_percent": used, "window_minutes": 10_080, "resets_at": reset
    ]
}

private func quotaSample(
    _ minute: String,
    model: String = "priced-model",
    input: Int64
) -> [String: Any] {
    [
        "minute": minute, "model": model, "effort": "medium", "tier": "default",
        "tier_source": "thread_settings", "long_context": false,
        "usage": quotaUsage(input: input), "request_count": 1,
        "input": input
    ]
}

private func quotaUsage(input: Int64) -> [String: Any] {
    [
        "input_tokens": input, "cached_input_tokens": 0,
        "cache_write_input_tokens": 0, "output_tokens": 0,
        "reasoning_output_tokens": 0, "total_tokens": input
    ]
}
