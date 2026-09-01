import Foundation
import Testing
@testable import TokenUsageCore

@Test("Parser rebases a decreasing first token sample at a new task epoch")
func parserRebasesCounterAtNewTaskEpoch() throws {
    let state = try runParserEpochRecords([
        epochTaskStarted("turn-1", at: "2026-09-01T10:00:00Z"),
        epochTokenCount(input: 100, output: 10, at: "2026-09-01T10:00:01Z"),
        epochTokenCount(input: 150, output: 20, at: "2026-09-01T10:00:02Z"),
        epochTaskComplete("turn-1", at: "2026-09-01T10:00:03Z"),
        epochTaskStarted("turn-2", at: "2026-09-01T10:01:00Z"),
        epochTokenCount(input: 40, output: 5, at: "2026-09-01T10:01:01Z"),
        epochTokenCount(input: 60, output: 8, at: "2026-09-01T10:01:02Z")
    ])

    let rawUsage = try #require(state["raw_usage"] as? [String: Any])
    #expect(rawUsage["input_tokens"] as? Int == 210)
    #expect(rawUsage["output_tokens"] as? Int == 28)
    #expect(rawUsage["total_tokens"] as? Int == 238)
    #expect(state["cache_schema_version"] as? Int == 11)
    #expect(state["last_total_usage_task_epoch"] as? Int == 2)

    let turns = try #require(state["turns"] as? [String: [String: Any]])
    let firstUsage = try #require(turns["turn-1"]?["usage"] as? [String: Any])
    let secondUsage = try #require(turns["turn-2"]?["usage"] as? [String: Any])
    #expect(firstUsage["total_tokens"] as? Int == 170)
    #expect(secondUsage["total_tokens"] as? Int == 68)

    let warnings = try #require(state["warnings"] as? [String])
    #expect(!warnings.contains { $0.contains("token counters decreased") })
}

@Test("Parser does not rebase a decreasing token sample within one task epoch")
func parserStillRejectsCounterDecreaseWithinTaskEpoch() throws {
    let state = try runParserEpochRecords([
        epochTaskStarted("turn-1", at: "2026-09-01T10:00:00Z"),
        epochTokenCount(input: 100, output: 10, at: "2026-09-01T10:00:01Z"),
        epochTokenCount(input: 80, output: 8, at: "2026-09-01T10:00:02Z"),
        epochTokenCount(input: 120, output: 12, at: "2026-09-01T10:00:03Z")
    ])

    let rawUsage = try #require(state["raw_usage"] as? [String: Any])
    #expect(rawUsage["input_tokens"] as? Int == 120)
    #expect(rawUsage["output_tokens"] as? Int == 12)
    #expect(rawUsage["total_tokens"] as? Int == 132)

    let warnings = try #require(state["warnings"] as? [String])
    #expect(warnings.contains {
        $0 == "token counters decreased; usage is a lower bound and price estimates were suppressed"
    })
}

@Test("Parser keeps using a cumulative baseline when counters continue across tasks")
func parserDoesNotDoubleCountMonotonicCrossTaskCounters() throws {
    let state = try runParserEpochRecords([
        epochTaskStarted("turn-1", at: "2026-09-01T10:00:00Z"),
        epochTokenCount(input: 100, output: 10, at: "2026-09-01T10:00:01Z"),
        epochTaskComplete("turn-1", at: "2026-09-01T10:00:02Z"),
        epochTaskStarted("turn-2", at: "2026-09-01T10:01:00Z"),
        epochTokenCount(input: 150, output: 20, at: "2026-09-01T10:01:01Z")
    ])

    let rawUsage = try #require(state["raw_usage"] as? [String: Any])
    #expect(rawUsage["input_tokens"] as? Int == 150)
    #expect(rawUsage["output_tokens"] as? Int == 20)
    #expect(rawUsage["total_tokens"] as? Int == 170)
}

private func runParserEpochRecords(_ records: [[String: Any]]) throws -> [String: Any] {
    let script = try #require(
        TokenUsageResources.url(forResource: "token_usage", withExtension: "py")
    )
    let recordsData = try JSONSerialization.data(withJSONObject: records)
    let recordsJSON = String(decoding: recordsData, as: UTF8.self)
    let code = """
        import json, runpy, sys
        from pathlib import Path
        from types import SimpleNamespace

        ns = runpy.run_path(sys.argv[1])
        state = ns["_new_parser_state"](
            Path("/tmp/rollout-parser-epoch-test.jsonl"),
            SimpleNamespace(st_dev=1, st_ino=1),
        )
        for record in json.loads(sys.argv[2]):
            state["record_sequence"] += 1
            ns["_process_record"](state, record)
        print(json.dumps(state))
        """

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", code, script.path, recordsJSON]
    var environment = ProcessInfo.processInfo.environment
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    process.environment = environment
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
    #expect(
        process.terminationStatus == 0,
        Comment(rawValue: String(decoding: errorOutput, as: UTF8.self))
    )
    return try #require(
        try JSONSerialization.jsonObject(with: output) as? [String: Any]
    )
}

private func epochTaskStarted(_ turnID: String, at timestamp: String) -> [String: Any] {
    [
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": ["type": "task_started", "turn_id": turnID]
    ]
}

private func epochTaskComplete(_ turnID: String, at timestamp: String) -> [String: Any] {
    [
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": ["type": "task_complete", "turn_id": turnID]
    ]
}

private func epochTokenCount(input: Int, output: Int, at timestamp: String) -> [String: Any] {
    [
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": [
            "type": "token_count",
            "info": [
                "total_token_usage": [
                    "input_tokens": input,
                    "cached_input_tokens": 0,
                    "cache_write_input_tokens": 0,
                    "output_tokens": output,
                    "reasoning_output_tokens": 0,
                    "total_tokens": input + output
                ]
            ]
        ]
    ]
}
