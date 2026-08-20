import Foundation
import Testing
@testable import TokenUsageCore

@Test("Malformed token counts fail decoding instead of trapping")
func malformedTokenCountsFailSoft() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let overflow = Data(
        """
        {"input_tokens":9223372036854775807,"cached_input_tokens":0,"cache_write_input_tokens":0,
         "output_tokens":1,"reasoning_output_tokens":0,"total_tokens":9223372036854775807}
        """.utf8
    )
    #expect(throws: DecodingError.self) {
        try decoder.decode(TokenUsage.self, from: overflow)
    }

    let negative = Data(
        """
        {"image_inputs":-1,"audio_inputs":0,"image_generations":0,
         "web_searches":0,"mcp_calls":0,"tool_calls":0}
        """.utf8
    )
    #expect(throws: DecodingError.self) {
        try decoder.decode(UsageCounts.self, from: negative)
    }
}

@Test("Programmatic aggregation saturates rather than overflowing")
func aggregationDoesNotTrap() {
    let usage = TokenUsage(inputTokens: Int64.max, totalTokens: Int64.max)
        + TokenUsage(inputTokens: 1, totalTokens: 1)
    #expect(usage.inputTokens == Int64.max)
    #expect(usage.totalTokens == Int64.max)

    let counts = UsageCounts(toolCalls: Int64.max) + UsageCounts(toolCalls: 1)
    #expect(counts.toolCalls == Int64.max)

    let inconsistent = TokenUsage(
        inputTokens: 0,
        cachedInputTokens: Int64.max,
        cacheWriteInputTokens: Int64.max
    )
    #expect(inconsistent.ordinaryInputTokens == 0)
}

@Test("Explicit agent turn link wins over conflicting parent metadata")
func explicitAgentLinkWins() throws {
    let reportJSON = Data(
        """
        {
          "report_schema_version": 1,
          "generated_at": "2026-08-17T00:00:00Z",
          "root_thread_id": "root",
          "current_turn": {
            "available": false, "usage_is_provisional": false,
            "usage": \(zeroUsageJSON), "counts": \(zeroCountsJSON),
            "root_usage": \(zeroUsageJSON), "agents_usage": \(oneTokenUsageJSON),
            "segments": [], "cost": {}
          },
          "task": {
            "usage": \(oneTokenUsageJSON), "counts": \(zeroCountsJSON),
            "root_usage": \(zeroUsageJSON), "agents_usage": \(oneTokenUsageJSON),
            "segments": [], "cost": {}, "linked_agent_threads": 1,
            "usage_is_lower_bound": false
          },
          "threads": [
            {
              "thread_id": "root", "usage": \(zeroUsageJSON), "counts": \(zeroCountsJSON),
              "owned_turn_ids": ["turn-1"], "active_turn_count": 0, "segments": [],
              "warnings": [], "parse_errors": 0, "unclassified_compaction_total": 0,
              "turns": [{
                "turn_id": "turn-1", "usage": \(zeroUsageJSON), "segments": [],
                "counts": \(zeroCountsJSON), "agent_thread_ids": ["child"], "aborted": false
              }]
            },
            {
              "thread_id": "child", "parent_thread_id": "different-parent",
              "thread_source": "subagent", "usage": \(oneTokenUsageJSON),
              "counts": \(zeroCountsJSON), "owned_turn_ids": [], "turns": [],
              "active_turn_count": 0, "segments": [], "warnings": [],
              "parse_errors": 0, "unclassified_compaction_total": 0
            }
          ],
          "completeness": {}, "warnings": [], "pricing_catalog": {}
        }
        """.utf8
    )
    let report = try UsageReportDecoder.decode(reportJSON)
    let catalog = PricingCatalog(
        schemaVersion: 1,
        catalogId: "test",
        observedAt: "2026-08-17",
        tokenUnit: 1,
        scope: "test",
        models: [:]
    )
    let session = UsageTreeBuilder(catalog: catalog).build(report: report, title: nil)
    let mainTurn = try #require(session.children?.first { $0.kind == .mainTurn })
    let child = try #require(mainTurn.children?.first { $0.kind == .agentThread })

    #expect(child.attribution == .direct)
    #expect(child.name.hasPrefix("子对话"))
    #expect(session.warnings.contains { $0.contains("parent_thread_id 冲突") })
}

private let zeroUsageJSON =
    #"{"input_tokens":0,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":0}"#

private let oneTokenUsageJSON =
    #"{"input_tokens":1,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":1}"#

private let zeroCountsJSON =
    #"{"image_inputs":0,"audio_inputs":0,"image_generations":0,"web_searches":0,"mcp_calls":0,"tool_calls":0}"#
