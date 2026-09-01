import Foundation
import Testing
@testable import TokenUsageCore

@Test("Session and trend use the same mixed per-bucket pricing semantics")
func sessionAndTrendPricingStayConsistent() throws {
    let catalog = try pricingConsistencyCatalog()
    let samples = [
        pricingSample(
            minute: "2026-08-20T10:00:00Z",
            model: "priced-model",
            tier: "priority",
            tierSource: "response",
            input: 1_000_000
        ),
        pricingSample(
            minute: "2026-08-20T10:01:00Z",
            model: "priced-model",
            tier: "priority",
            tierSource: "current_config_fallback",
            input: 1_000_000
        ),
        pricingSample(
            minute: "2026-08-20T10:02:00Z",
            model: "priced-model",
            tier: "future-tier",
            tierSource: "response",
            input: 500_000
        ),
        pricingSample(
            minute: "2026-08-20T10:03:00Z",
            model: "unpriced-model",
            tier: "default",
            tierSource: "response",
            input: 250_000
        )
    ]
    let report = try pricingConsistencyReport(samples: samples)
    let estimator = CreditEstimator(catalog: catalog)

    #expect(
        estimator.modelSummary(for: Array(report.task.segments.prefix(2)))
            .hasSuffix("混合档位")
    )
    #expect(
        estimator.modelSummary(for: [report.task.segments[2]])
            .hasSuffix("Standard")
    )

    let session = UsageTreeBuilder(catalog: catalog).build(report: report, title: "Mixed pricing")

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let trend = UsageTrendAggregator(catalog: catalog, calendar: calendar).aggregate(
        reports: [report],
        filter: UsageTrendFilter(
            startMinute: try pricingDate("2026-08-20T10:00:00Z"),
            endMinute: try pricingDate("2026-08-20T10:03:00Z")
        )
    )
    let trendSummary = try #require(trend.series.first?.summary)

    let sessionCredits = try #require(session.creditEstimate)
    #expect(sessionCredits.amount == Decimal(string: "35"))
    #expect(sessionCredits.amount == trendSummary.credits.amount)
    #expect(sessionCredits.basis == .mixed)
    #expect(trendSummary.credits.basis == .mixed)
    #expect(sessionCredits.pricedTokens == 2_500_000)
    #expect(sessionCredits.pricedTokens == trendSummary.credits.pricedTokens)
    #expect(sessionCredits.totalTokens == 2_750_000)
    #expect(sessionCredits.totalTokens == trendSummary.credits.totalTokens)
    #expect(sessionCredits.isPartial)

    let sessionAPI = try #require(session.apiPriceEstimate)
    #expect(sessionAPI.amount == Decimal(string: "3.5"))
    #expect(sessionAPI.amount == trendSummary.apiUSD.amount)
    #expect(sessionAPI.basis == .mixed)
    #expect(trendSummary.apiUSD.basis == .mixed)
    #expect(sessionAPI.pricedTokens == 2_500_000)
    #expect(sessionAPI.pricedTokens == trendSummary.apiUSD.pricedTokens)
    #expect(sessionAPI.totalTokens == 2_750_000)
    #expect(sessionAPI.totalTokens == trendSummary.apiUSD.totalTokens)
    #expect(sessionAPI.isPartial)
}

@Test("Suppressed session and summary rows retain an explicit suppression reason")
func pricingSuppressionReasonSurvivesTreeAggregation() throws {
    let catalog = try pricingConsistencyCatalog()
    let report = try pricingConsistencyReport(
        samples: [
            pricingSample(
                minute: "2026-08-20T10:00:00Z",
                model: "priced-model",
                tier: "default",
                tierSource: "response",
                input: 1_000_000
            )
        ],
        costSuppressed: true
    )
    let builder = UsageTreeBuilder(catalog: catalog)
    let session = builder.build(report: report, title: "Suppressed")

    #expect(session.creditEstimate == nil)
    #expect(session.apiPriceEstimate == nil)
    #expect(session.warnings.contains { $0.contains("price estimates were suppressed") })

    let summary = try #require(builder.summaryRow(for: [session]))
    #expect(summary.creditEstimate == nil)
    #expect(summary.apiPriceEstimate == nil)
    #expect(summary.warnings.contains { $0.contains("price estimates were suppressed") })
}

private func pricingConsistencyCatalog() throws -> PricingCatalog {
    let object: [String: Any] = [
        "schema_version": 1,
        "catalog_id": "pricing-consistency-test",
        "observed_at": "2026-08-20",
        "token_unit": 1_000_000,
        "scope": "tests",
        "models": [
            "priced-model": [
                "display_name": "Priced Model",
                "aliases": [],
                "codex_credits": [
                    "input": "10",
                    "cached_input": "1",
                    "output": "20",
                    "fast": [
                        "support": "documented",
                        "speed_multiplier_nominal": "1.5",
                        "billing_multiplier": "2"
                    ]
                ],
                "api_usd": [
                    "standard": [
                        "short": [
                            "input": "1",
                            "cached_input": "0.1",
                            "cache_write": "1.25",
                            "output": "2"
                        ]
                    ],
                    "fast": [
                        "short": [
                            "input": "2",
                            "cached_input": "0.2",
                            "cache_write": "2.5",
                            "output": "4"
                        ]
                    ]
                ]
            ]
        ]
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(PricingCatalog.self, from: data)
}

private func pricingConsistencyReport(
    samples: [[String: Any]],
    costSuppressed: Bool = false
) throws -> UsageReport {
    let totalInput = samples.reduce(Int64.zero) { partial, sample in
        let usage = sample["usage"] as? [String: Any]
        return partial + (usage?["input_tokens"] as? Int64 ?? 0)
    }
    let totalUsage = pricingUsage(input: totalInput)
    let zeroUsage = pricingUsage(input: 0)
    let counts: [String: Any] = [
        "image_inputs": 0,
        "audio_inputs": 0,
        "image_generations": 0,
        "web_searches": 0,
        "mcp_calls": 0,
        "tool_calls": 0
    ]
    let segments = samples.map { sample -> [String: Any] in
        var segment = sample
        let minute = segment.removeValue(forKey: "minute")
        segment["first_at"] = minute
        segment["last_at"] = minute
        return segment
    }
    let taskCost: [String: Any] = costSuppressed
        ? ["cost_suppressed": true]
        : [
            "codex_credits_standard_equivalent": "999",
            "api_usd_standard_equivalent": "999"
        ]
    let object: [String: Any] = [
        "report_schema_version": 1,
        "generated_at": "2026-08-20T12:00:00Z",
        "root_thread_id": "pricing-consistency",
        "display_name": "Mixed pricing",
        "selected_turn_id": NSNull(),
        "current_turn": [
            "available": false,
            "usage_is_provisional": false,
            "usage": zeroUsage,
            "counts": counts,
            "root_usage": zeroUsage,
            "agents_usage": zeroUsage,
            "segments": [],
            "cost": [:]
        ],
        "task": [
            "usage": totalUsage,
            "counts": counts,
            "root_usage": totalUsage,
            "agents_usage": zeroUsage,
            "segments": segments,
            "usage_samples": samples,
            // These deliberately disagree with the current catalog. The reader
            // must use its per-bucket result and reserve embedded totals for
            // legacy reports that have no locally priceable usage.
            "cost": taskCost,
            "linked_agent_threads": 0,
            "usage_is_lower_bound": false
        ],
        "threads": [],
        "completeness": [:],
        "warnings": [],
        "pricing_catalog": [:]
    ]
    return try UsageReportDecoder.decode(JSONSerialization.data(withJSONObject: object))
}

private func pricingSample(
    minute: String,
    model: String,
    tier: String,
    tierSource: String,
    input: Int64
) -> [String: Any] {
    [
        "minute": minute,
        "model": model,
        "effort": "medium",
        "tier": tier,
        "tier_source": tierSource,
        "task_epoch": 1,
        "long_context": false,
        "usage": pricingUsage(input: input),
        "request_count": 1
    ]
}

private func pricingUsage(input: Int64) -> [String: Any] {
    [
        "input_tokens": input,
        "cached_input_tokens": 0,
        "cache_write_input_tokens": 0,
        "output_tokens": 0,
        "reasoning_output_tokens": 0,
        "total_tokens": input
    ]
}

private func pricingDate(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return try #require(formatter.date(from: value))
}
