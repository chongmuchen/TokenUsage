import Foundation
import Testing
@testable import TokenUsageCore

@Test("Parser prices Astra Ultrafast separately from Fast and leaves unsupported models unpriced")
func parserUltrafastPricingAndHover() throws {
    let results = try ultrafastParserResults()
    #expect(results.count == 7)

    let expected: [String: (credits: String, api: String)] = [
        "gpt-6-astra:standard:short": ("26.250000", "1.100000"),
        "gpt-6-astra:fast:short": ("52.500000", "2.200000"),
        "gpt-6-astra:ultrafast:short": ("157.500000", "6.600000"),
        "gpt-6-astra:standard:long": ("76.250000", "5.950000"),
        "gpt-6-astra:fast:long": ("152.500000", "11.900000"),
        "gpt-6-astra:ultrafast:long": ("457.500000", "35.700000")
    ]
    for result in results {
        let key = "\(result.model):\(result.tier):\(result.context)"
        if let amounts = expected[key] {
            #expect(result.cost.codexCreditsConfiguredTierEstimate == amounts.credits, Comment(rawValue: key))
            #expect(result.cost.apiUsdConfiguredTierEstimate == amounts.api, Comment(rawValue: key))
        } else {
            #expect(key == "gpt-6.1-sol:ultrafast:short")
            #expect(result.cost.codexCreditsStandardEquivalent != nil)
            #expect(result.cost.apiUsdStandardEquivalent != nil)
            #expect(result.cost.codexCreditsConfiguredTierEstimate == nil)
            #expect(result.cost.apiUsdConfiguredTierEstimate == nil)
            #expect(result.cost.creditConfiguredPricedTokens == 0)
            #expect(result.cost.apiConfiguredPricedTokens == 0)
            #expect(result.cost.warnings?.contains { $0.contains("Codex Ultrafast billing multiplier") } == true)
            #expect(result.cost.warnings?.contains { $0.contains("API Ultrafast pricing") } == true)
        }
    }

    let ultra = try #require(results.first { $0.model == "gpt-6-astra" && $0.tier == "ultrafast" && $0.context == "short" })
    #expect(ultra.label.contains("Ultrafast 8×"))
    #expect(ultra.hover.contains("Ultrafast·速×8·订额×8·付费Cr×6"))
    let fast = try #require(results.first { $0.model == "gpt-6-astra" && $0.tier == "fast" && $0.context == "short" })
    #expect(fast.hover.contains("Fast·速×?·订额×2.5·付费Cr×2"))
}

private struct UltrafastParserResult: Decodable {
    let model: String
    let tier: String
    let context: String
    let cost: CostSummary
    let label: String
    let hover: String
}

private func ultrafastParserResults() throws -> [UltrafastParserResult] {
    let script = try #require(TokenUsageResources.url(forResource: "token_usage", withExtension: "py"))
    let code = """
        import json, runpy, sys

        ns = runpy.run_path(sys.argv[1])
        catalog = ns["_load_catalog"]()
        results = []
        cases = [("gpt-6-astra", tier, context)
                 for context in ("short", "long")
                 for tier in ("standard", "fast", "ultrafast")]
        cases.append(("gpt-6.1-sol", "ultrafast", "short"))
        for model, tier, context in cases:
            input_tokens = 300000 if context == "long" else 100000
            segment = {
                "model": model, "tier": tier, "tier_source": "thread_settings",
                "long_context": context == "long",
                "usage": {
                    "input_tokens": input_tokens, "cached_input_tokens": 50000,
                    "cache_write_input_tokens": 20000, "output_tokens": 10000,
                    "reasoning_output_tokens": 4000, "total_tokens": input_tokens + 10000,
                },
            }
            results.append({
                "model": model, "tier": tier, "context": context,
                "cost": ns["_calculate_cost"]([segment], catalog),
                "label": ns["_segment_labels"]([segment], catalog),
                "hover": ns["_hover_short_model_multiplier"]([segment], catalog),
            })
        print(json.dumps(results))
        """
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
    return try UsageReportDecoder.makeJSONDecoder().decode([UltrafastParserResult].self, from: output)
}
