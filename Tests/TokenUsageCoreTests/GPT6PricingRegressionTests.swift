import Foundation
import Testing
@testable import TokenUsageCore

@Test("GPT-6 Sol and Luna retain exact cache and context pricing across Python and Swift")
func gpt6PricingMatchesParserAtLongContextBoundary() throws {
    let catalog = try PricingCatalog.bundled()
    let estimator = CreditEstimator(catalog: catalog)
    let results = try gpt6ParserPricing()
    #expect(results.count == 12)

    // Each request has 50,000 cached reads, 20,000 cache writes, and 10,000
    // output tokens (including 4,000 reasoning tokens). Expected amounts are
    // independent totals, so charging cache writes or reasoning twice fails.
    let expected: [String: (apiStandard: String, apiFast: String, creditsStandard: String, creditsFast: String)] = [
        "gpt-6-sol:272000": ("0.564", "1.128", "13.85", "34.625"),
        "gpt-6-sol:272001": ("1.078004", "2.156008", "13.85005", "34.625125"),
        "gpt-6-luna:272000": ("0.0282", "0.0564", "0.6925", "1.73125"),
        "gpt-6-luna:272001": ("0.0539002", "0.1078004", "0.6925025", "1.73125625")
    ]

    for result in results {
        let segment = result.segment
        let model = try #require(segment.model)
        let tier = try #require(segment.tier)
        let amounts = try #require(expected["\(model):\(segment.usage.inputTokens)"])
        let context = Comment(rawValue: "\(model), \(tier), input \(segment.usage.inputTokens)")
        let isFast = tier == "fast" || tier == "priority"
        let apiAmount = try #require(Decimal(string: isFast ? amounts.apiFast : amounts.apiStandard))
        let creditAmount = try #require(Decimal(string: isFast ? amounts.creditsFast : amounts.creditsStandard))

        #expect(segment.longContext == (segment.usage.inputTokens == 272_001), context)
        #expect(segment.usage.ordinaryInputTokens == segment.usage.inputTokens - 70_000, context)
        let api = estimator.estimateAPI([segment])
        #expect(api.amount == apiAmount, context)
        #expect(api.basis == .configured, context)
        #expect(api.pricedTokens == segment.usage.totalTokens, context)
        #expect(!api.isPartial, context)
        let credits = estimator.estimate([segment])
        #expect(credits.amount == creditAmount, context)
        #expect(credits.basis == .configured, context)
        #expect(!credits.isPartial, context)

        // Reports serialize money at six decimal places; Swift keeps full
        // Decimal precision until display, especially for Luna's small rates.
        #expect(result.cost.catalogId == catalog.catalogId, context)
        #expect(result.cost.apiUsdConfiguredTierEstimate.flatMap { Decimal(string: $0) } == gpt6ReportAmount(apiAmount), context)
        #expect(result.cost.codexCreditsConfiguredTierEstimate.flatMap { Decimal(string: $0) } == gpt6ReportAmount(creditAmount), context)
        #expect(result.cost.apiUsdStandardEquivalent.flatMap { Decimal(string: $0) } == gpt6ReportAmount(try #require(Decimal(string: amounts.apiStandard))), context)
        #expect(result.cost.codexCreditsStandardEquivalent.flatMap { Decimal(string: $0) } == gpt6ReportAmount(try #require(Decimal(string: amounts.creditsStandard))), context)
        #expect(result.cost.apiConfiguredPricedTokens == segment.usage.totalTokens, context)
        #expect(result.cost.creditConfiguredPricedTokens == segment.usage.totalTokens, context)
    }
}

@Test("Catalog updates replay previously unknown GPT-6 model caches and retain current caches")
func gpt6CatalogChangeRebuildsLongContextCache() throws {
    let code = """
        import copy, json, os, runpy, sys, tempfile
        from pathlib import Path

        ns = runpy.run_path(sys.argv[1])
        current = ns["_load_catalog"]()
        previous = copy.deepcopy(current)
        previous["catalog_id"] = "openai-public-2026-09-05"
        for model in ("gpt-6-sol", "gpt-6-luna"):
            del previous["models"][model]
        globals_ = ns["parse_transcript"].__globals__
        original_process_record = globals_["_process_record"]
        processed = 0

        def count_record(state, record):
            global processed
            processed += 1
            original_process_record(state, record)

        globals_["_process_record"] = count_record
        results = []
        with tempfile.TemporaryDirectory(prefix="token-usage-pricing-test-") as directory:
            root = Path(directory).resolve()
            os.environ["CODEX_TOKEN_USAGE_CODEX_DIR"] = str(root)
            os.environ["CODEX_TOKEN_USAGE_STATE_DIR"] = str(root / "token-usage")
            sessions = root / "sessions"
            sessions.mkdir()
            for model in ("gpt-6-sol", "gpt-6-luna"):
                transcript = sessions / ("rollout-" + model + ".jsonl")
                usage = {
                    "input_tokens": 300000, "cached_input_tokens": 50000,
                    "cache_write_input_tokens": 20000, "output_tokens": 10000,
                    "reasoning_output_tokens": 4000, "total_tokens": 310000,
                }
                records = [
                    {"type": "session_meta", "payload": {"id": "synthetic-" + model}},
                    {"type": "event_msg", "payload": {
                        "type": "thread_settings_applied",
                        "thread_settings": {"model": model, "service_tier": "standard"},
                    }},
                    {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "turn-1"}},
                    {"type": "event_msg", "payload": {"type": "token_count", "info": {
                        "total_token_usage": usage, "last_token_usage": usage,
                    }}},
                ]
                for record in records:
                    record["timestamp"] = "2026-09-23T10:00:00Z"
                transcript.write_text("".join(json.dumps(record) + "\\n" for record in records))

                globals_["_load_catalog"] = lambda: previous
                old = ns["parse_transcript"](transcript)
                old_segments = old["turns"]["turn-1"]["segments"]
                assert len(old_segments) == 1 and old_segments[0]["long_context"] is False
                assert ns["_calculate_cost"](old_segments, previous)["api_usd_standard_equivalent"] is None

                globals_["_load_catalog"] = lambda: current
                processed = 0
                updated = ns["parse_transcript"](transcript)
                assert processed == len(records), "catalog change must replay each request"
                assert updated["pricing_catalog_id"] == current["catalog_id"]
                segments = updated["turns"]["turn-1"]["segments"]
                assert len(segments) == 1 and segments[0]["long_context"] is True
                assert updated["usage_samples"][0]["long_context"] is True

                processed = 0
                reused = ns["parse_transcript"](transcript)
                assert processed == 0 and reused == updated, "unchanged catalog should reuse its cache"

                cache = ns["_cache_path"](transcript)
                legacy = json.loads(cache.read_text())
                del legacy["pricing_catalog_id"]
                cache.write_text(json.dumps(legacy))
                processed = 0
                ns["parse_transcript"](transcript)
                assert processed == len(records), "cache without a catalog id must replay"
                results.append({"segment": segments[0], "cost": ns["_calculate_cost"](segments, current)})
        print(json.dumps(results))
        """
    let results = try UsageReportDecoder.makeJSONDecoder().decode(
        [GPT6ParserPrice].self,
        from: gpt6RunParserCode(code)
    )
    #expect(results.count == 2)
    #expect(results.first { $0.segment.model == "gpt-6-sol" }?.cost.apiUsdStandardEquivalent == "1.190000")
    #expect(results.first { $0.segment.model == "gpt-6-luna" }?.cost.apiUsdStandardEquivalent == "0.059500")
}

private struct GPT6ParserPrice: Decodable {
    let segment: UsageSegment
    let cost: CostSummary
}

private func gpt6ParserPricing() throws -> [GPT6ParserPrice] {
    let code = """
        import json, runpy, sys

        ns = runpy.run_path(sys.argv[1])
        catalog = ns["_load_catalog"]()
        results = []
        for model in ("gpt-6-sol", "gpt-6-luna"):
            for tier in ("standard", "fast", "priority"):
                for input_tokens in (272000, 272001):
                    usage = {
                        "input_tokens": input_tokens,
                        "cached_input_tokens": 50000,
                        "cache_write_input_tokens": 20000,
                        "output_tokens": 10000,
                        "reasoning_output_tokens": 4000,
                        "total_tokens": input_tokens + 10000,
                    }
                    metadata = {
                        "model": model, "tier": tier,
                        "tier_source": "thread_settings", "task_epoch": 1,
                    }
                    segments = []
                    ns["_add_segment"](segments, metadata, usage, "2026-09-23T10:00:00Z")
                    results.append({
                        "segment": segments[0],
                        "cost": ns["_calculate_cost"](segments, catalog),
                    })
        print(json.dumps(results))
        """
    return try UsageReportDecoder.makeJSONDecoder().decode([GPT6ParserPrice].self, from: gpt6RunParserCode(code))
}

private func gpt6RunParserCode(_ code: String) throws -> Data {
    let script = try #require(TokenUsageResources.url(forResource: "token_usage", withExtension: "py"))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", code, script.path]
    var environment = ProcessInfo.processInfo.environment
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    process.environment = environment
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
    #expect(process.terminationStatus == 0, Comment(rawValue: String(decoding: errorOutput, as: UTF8.self)))
    return output
}

private func gpt6ReportAmount(_ amount: Decimal) -> Decimal {
    var amount = amount
    var rounded = Decimal.zero
    NSDecimalRound(&rounded, &amount, 6, .bankers)
    return rounded
}
