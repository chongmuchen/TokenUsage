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
    #expect(state["cache_schema_version"] as? Int == 15)
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

@Test("Forked session excludes inherited cumulative tokens from its first request")
func parserExcludesInheritedForkCounter() throws {
    let state = try runParserEpochRecords([
        epochSessionMeta(forkedFrom: "01a08aae-0d7d-74d2-b827-7a3b3a43ec4b"),
        epochTaskStarted("01a0a5b2-161d-7af3-b678-58af4c2c24d8", at: "2026-09-15T15:31:46Z"),
        [
            "timestamp": "2026-09-15T15:31:47Z",
            "type": "turn_context",
            "payload": ["turn_id": "01a0a5b2-161d-7af3-b678-58af4c2c24d8", "model": "gpt-5.6-sol"]
        ],
        epochTokenCount(
            input: 94_826_970, output: 254_572, at: "2026-09-15T15:31:58Z",
            cachedInput: 92_797_184, reasoningOutput: 73_255,
            lastUsage: [
                "input_tokens": 211_195, "cached_input_tokens": 0,
                "cache_write_input_tokens": 0, "output_tokens": 290,
                "reasoning_output_tokens": 119, "total_tokens": 211_485
            ]
        ),
        epochTokenCount(
            input: 95_038_477, output: 254_668, at: "2026-09-15T15:32:04Z",
            cachedInput: 93_008_256, reasoningOutput: 73_255
        )
    ], includeSummary: true)

    let rawUsage = try #require(state["raw_usage"] as? [String: Any])
    #expect(rawUsage["input_tokens"] as? Int == 422_702)
    #expect(rawUsage["output_tokens"] as? Int == 386)
    #expect(rawUsage["total_tokens"] as? Int == 423_088)
    #expect(state["cache_schema_version"] as? Int == 16)
    let samples = try #require(state["usage_samples"] as? [[String: Any]])
    let firstSample = try #require(samples.first)
    let firstUsage = try #require(firstSample["usage"] as? [String: Any])
    #expect(firstUsage["total_tokens"] as? Int == 211_485)
    #expect(firstSample["long_context"] as? Bool == false)
    let summary = try #require(state["_test_summary"] as? [String: Any])
    let ownedUsage = try #require(summary["usage"] as? [String: Any])
    #expect(ownedUsage["total_tokens"] as? Int == 423_088)
    #expect(summary["exclusive_usage_available"] as? Bool == true)
}

@Test("Forked session with no reliable first request leaves an explicit lower bound")
func parserDoesNotPriceAmbiguousForkCounter() throws {
    let state = try runParserEpochRecords([
        epochSessionMeta(forkedFrom: "01a08aae-0d7d-74d2-b827-7a3b3a43ec4b"),
        epochTaskStarted("01a0a5b2-161d-7af3-b678-58af4c2c24d8", at: "2026-09-15T15:31:46Z"),
        epochTokenCount(
            input: 95_000_000, output: 100_000, at: "2026-09-15T15:31:58Z",
            lastUsage: ["total_tokens": 2_000]
        ),
        epochTokenCount(input: 95_001_000, output: 100_020, at: "2026-09-15T15:32:04Z")
    ], includeSummary: true)

    let rawUsage = try #require(state["raw_usage"] as? [String: Any])
    #expect(rawUsage["total_tokens"] as? Int == 1_020)
    let summary = try #require(state["_test_summary"] as? [String: Any])
    let warnings = try #require(summary["warnings"] as? [String])
    #expect(warnings.contains { $0.contains("first token increment was unavailable") })
}

@Test("Missing first counter in a copied fork prefix does not taint owned usage")
func parserKeepsForkPrefixWarningOutOfOwnedTurn() throws {
    let state = try runParserEpochRecords([
        epochSessionMeta(forkedFrom: "01a08aae-0d7d-74d2-b827-7a3b3a43ec4b"),
        epochTaskStarted("01a08aae-f051-7b09-bbac-c388b7c7f127", at: "2026-09-10T09:00:00Z"),
        epochTokenCount(input: 95_000_000, output: 100_000, at: "2026-09-10T09:00:01Z"),
        epochTaskComplete("01a08aae-f051-7b09-bbac-c388b7c7f127", at: "2026-09-10T09:00:02Z"),
        epochTaskStarted("01a0a5b2-161d-7af3-b678-58af4c2c24d8", at: "2026-09-15T15:31:46Z"),
        epochTokenCount(input: 95_001_000, output: 100_020, at: "2026-09-15T15:31:58Z")
    ], includeSummary: true)

    let summary = try #require(state["_test_summary"] as? [String: Any])
    let ownedUsage = try #require(summary["usage"] as? [String: Any])
    #expect(ownedUsage["total_tokens"] as? Int == 1_020)
    let warnings = try #require(summary["warnings"] as? [String])
    #expect(!warnings.contains { $0.contains("first token increment was unavailable") })
}

@Test("Parser captures both rate-limit buckets even when token usage does not change")
func parserCapturesRateLimitsBeforeZeroDeltaReturn() throws {
    let limits = epochRateLimits(primaryUsed: 7.5, secondaryUsed: 28)
    let state = try runParserEpochRecords([
        epochTokenCount(input: 0, output: 0, at: "2026-09-07T10:00:00Z", rateLimits: limits),
        epochTokenCount(input: 0, output: 0, at: "2026-09-07T10:01:00Z", rateLimits: limits)
    ])

    let snapshots = try #require(state["rate_limit_snapshots"] as? [[String: Any]])
    #expect(snapshots.count == 2)
    let primary = try #require(snapshots.first { $0["bucket"] as? String == "primary" })
    let secondary = try #require(snapshots.first { $0["bucket"] as? String == "secondary" })

    #expect(primary["observed_at"] as? String == "2026-09-07T10:01:00Z")
    #expect(primary["limit_id"] as? String == "codex-test")
    #expect(primary["limit_name"] as? String == "Codex Test")
    #expect(primary["used_percent"] as? Double == 7.5)
    #expect(primary["window_minutes"] as? Int == 300)
    #expect(primary["resets_at"] as? String == "2026-09-07T12:00:00Z")
    #expect(primary["plan_type"] as? String == "plus")

    #expect(secondary["observed_at"] as? String == "2026-09-07T10:01:00Z")
    #expect(secondary["used_percent"] as? Int == 28)
    #expect(secondary["window_minutes"] as? Int == 10_080)
    #expect(secondary["resets_at"] as? String == "2026-09-14T12:00:00Z")

    let observations = try #require(state["rate_limit_observations"] as? [[String: Any]])
    #expect(observations.count == 4)
    #expect(observations.filter { $0["bucket"] as? String == "secondary" }
        .compactMap { $0["observed_at"] as? String }
        == ["2026-09-07T10:00:00Z", "2026-09-07T10:01:00Z"])
}

@Test("Parser preserves daily and reset boundaries while compacting intermediate quota polls")
func parserCompactsRateLimitObservations() throws {
    func limit(_ used: Int, reset: Int) -> [String: Any] {
        [
            "limit_id": "codex",
            "secondary": [
                "used_percent": used,
                "window_minutes": 10_080,
                "resets_at": reset
            ]
        ]
    }
    let firstReset = 1_789_387_200
    // A manual early reset on Sep 8 creates a weekly window ending Sep 15.
    let nextReset = 1_789_437_600
    let state = try runParserEpochRecords([
        epochTokenCount(input: 0, output: 0, at: "2026-09-07T13:00:00Z", rateLimits: limit(10, reset: firstReset)),
        epochTokenCount(input: 0, output: 0, at: "2026-09-07T14:00:00Z", rateLimits: limit(20, reset: firstReset + 28)),
        epochTokenCount(input: 0, output: 0, at: "2026-09-07T15:00:00Z", rateLimits: limit(30, reset: firstReset + 42)),
        epochTokenCount(input: 0, output: 0, at: "2026-09-08T01:00:00Z", rateLimits: limit(35, reset: firstReset)),
        epochTokenCount(input: 0, output: 0, at: "2026-09-08T02:00:00Z", rateLimits: limit(38, reset: firstReset)),
        epochTokenCount(input: 0, output: 0, at: "2026-09-08T03:00:00Z", rateLimits: limit(2, reset: nextReset)),
        epochTokenCount(input: 0, output: 0, at: "2026-09-08T04:00:00Z", rateLimits: limit(4, reset: nextReset)),
        epochTokenCount(input: 0, output: 0, at: "2026-09-08T05:00:00Z", rateLimits: limit(5, reset: nextReset))
    ])

    let observations = try #require(state["rate_limit_observations"] as? [[String: Any]])
    #expect(observations.count == 6)
    #expect(observations.compactMap { $0["used_percent"] as? Int } == [10, 30, 35, 38, 2, 5])
    #expect(observations.compactMap { $0["observed_at"] as? String } == [
        "2026-09-07T13:00:00Z", "2026-09-07T15:00:00Z",
        "2026-09-08T01:00:00Z", "2026-09-08T02:00:00Z",
        "2026-09-08T03:00:00Z", "2026-09-08T05:00:00Z"
    ])
    let snapshots = try #require(state["rate_limit_snapshots"] as? [[String: Any]])
    #expect(snapshots.count == 4) // Exact reset timestamps retain their previous meaning.
}

@Test("Merged root and agent observations keep both sides of a reset")
func parserMergesRateLimitObservationsAcrossThreads() throws {
    func observation(_ at: String, used: Int, reset: String) -> [String: Any] {
        [
            "observed_at": at,
            "limit_id": "codex",
            "bucket": "secondary",
            "used_percent": used,
            "window_minutes": 10_080,
            "resets_at": reset
        ]
    }
    let oldReset = "2026-09-14T12:00:00Z"
    let newReset = "2026-09-15T02:00:00Z"
    let merged = try mergeRateLimitObservations([
        observation("2026-09-08T11:00:00Z", used: 12, reset: oldReset),
        observation("2026-09-08T10:30:00Z", used: 11, reset: oldReset),
        observation("2026-09-08T10:00:00Z", used: 10, reset: oldReset),
        observation("2026-09-08T11:30:00Z", used: 2, reset: newReset),
        observation("2026-09-08T12:00:00Z", used: 4, reset: newReset),
        observation("2026-09-08T11:00:00Z", used: 12, reset: oldReset)
    ])
    #expect(merged.compactMap { $0["used_percent"] as? Int } == [10, 12, 2, 4])
}

@Test("Rate-limit merge keeps the latest observation for each exact reset and preserves jitter")
func parserMergesRateLimitSnapshotsAcrossThreads() throws {
    let shared: [String: Any] = [
        "limit_id": "codex-test",
        "bucket": "secondary",
        "used_percent": 28,
        "window_minutes": 10_080,
        "resets_at": "2026-09-14T12:00:00Z",
        "plan_type": "plus"
    ]
    var rootEarlier = shared
    rootEarlier["observed_at"] = "2026-09-07T10:00:00Z"
    var agentLater = shared
    agentLater["observed_at"] = "2026-09-07T10:02:00Z"
    var changed = shared
    changed["observed_at"] = "2026-09-07T10:03:00Z"
    changed["used_percent"] = 29
    var changedDuplicate = changed
    changedDuplicate["observed_at"] = "2026-09-07T10:04:00Z"
    changedDuplicate["resets_at"] = "2026-09-14T12:00:28Z"
    var nextPeriod = changedDuplicate
    nextPeriod["observed_at"] = "2026-09-14T10:00:00Z"
    nextPeriod["resets_at"] = "2026-09-21T12:00:00Z"
    nextPeriod["used_percent"] = 3

    let snapshots = try mergeRateLimitSnapshots([
        nextPeriod, changedDuplicate, rootEarlier, changed, agentLater
    ])
    #expect(snapshots.count == 3)
    #expect(snapshots[0]["observed_at"] as? String == "2026-09-07T10:03:00Z")
    #expect(snapshots[0]["used_percent"] as? Int == 29)
    #expect(snapshots[0]["resets_at"] as? String == "2026-09-14T12:00:00Z")
    #expect(snapshots[1]["observed_at"] as? String == "2026-09-07T10:04:00Z")
    #expect(snapshots[1]["resets_at"] as? String == "2026-09-14T12:00:28Z")
    #expect(snapshots[2]["observed_at"] as? String == "2026-09-14T10:00:00Z")
    #expect(snapshots[2]["used_percent"] as? Int == 3)
}

private func runParserEpochRecords(
    _ records: [[String: Any]], includeSummary: Bool = false
) throws -> [String: Any] {
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
        if sys.argv[3] == "1":
            state["_test_summary"] = ns["_thread_summary"](state["thread_id"], state, {}, None, None)
        print(json.dumps(state))
        """

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", code, script.path, recordsJSON, includeSummary ? "1" : "0"]
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

private func mergeRateLimitSnapshots(_ snapshots: [[String: Any]]) throws -> [[String: Any]] {
    try mergeRateLimitValues(snapshots, function: "_merge_rate_limit_snapshots")
}

private func mergeRateLimitObservations(_ observations: [[String: Any]]) throws -> [[String: Any]] {
    try mergeRateLimitValues(observations, function: "_merge_rate_limit_observations")
}

private func mergeRateLimitValues(
    _ values: [[String: Any]],
    function: String
) throws -> [[String: Any]] {
    let script = try #require(
        TokenUsageResources.url(forResource: "token_usage", withExtension: "py")
    )
    let snapshotsData = try JSONSerialization.data(withJSONObject: values)
    let snapshotsJSON = String(decoding: snapshotsData, as: UTF8.self)
    let code = """
        import json, runpy, sys
        ns = runpy.run_path(sys.argv[1])
        print(json.dumps(ns[sys.argv[3]](json.loads(sys.argv[2]))))
        """

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", code, script.path, snapshotsJSON, function]
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
        try JSONSerialization.jsonObject(with: output) as? [[String: Any]]
    )
}

private func epochTaskStarted(_ turnID: String, at timestamp: String) -> [String: Any] {
    [
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": ["type": "task_started", "turn_id": turnID]
    ]
}

private func epochSessionMeta(forkedFrom parentID: String) -> [String: Any] {
    [
        "timestamp": "2026-09-15T15:30:46Z",
        "type": "session_meta",
        "payload": [
            "id": "01a0a5b1-2bb9-79d2-bfd9-a14a74b137a2",
            "forked_from_id": parentID
        ]
    ]
}

private func epochTaskComplete(_ turnID: String, at timestamp: String) -> [String: Any] {
    [
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": ["type": "task_complete", "turn_id": turnID]
    ]
}

private func epochTokenCount(
    input: Int,
    output: Int,
    at timestamp: String,
    rateLimits: [String: Any]? = nil,
    cachedInput: Int = 0,
    reasoningOutput: Int = 0,
    lastUsage: [String: Int]? = nil
) -> [String: Any] {
    var info: [String: Any] = [
        "total_token_usage": [
            "input_tokens": input,
            "cached_input_tokens": cachedInput,
            "cache_write_input_tokens": 0,
            "output_tokens": output,
            "reasoning_output_tokens": reasoningOutput,
            "total_tokens": input + output
        ]
    ]
    if let lastUsage {
        info["last_token_usage"] = lastUsage
    }
    var payload: [String: Any] = [
        "type": "token_count",
        "info": info
    ]
    if let rateLimits {
        payload["rate_limits"] = rateLimits
    }
    return [
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": payload
    ]
}

private func epochRateLimits(primaryUsed: Double, secondaryUsed: Int) -> [String: Any] {
    [
        "limit_id": "codex-test",
        "limit_name": "Codex Test",
        "plan_type": "plus",
        "primary": [
            "used_percent": primaryUsed,
            "window_minutes": 300,
            "resets_at": 1_788_782_400
        ],
        "secondary": [
            "used_percent": secondaryUsed,
            "window_minutes": 10_080,
            "resets_at": 1_789_387_200
        ]
    ]
}
