import Foundation
import Testing
@testable import TokenUsageCore

@Test("Trend uses only task samples and includes the complete selected minute")
func trendMinuteBoundaryAndSingleAccountingPlane() throws {
    let first = trendSample(
        "2026-08-20T10:00:00Z",
        model: "gpt-5.6-sol",
        effort: "medium",
        tier: "default",
        usage: trendUsage(input: 100, cached: 20, cacheWrite: 10, output: 10, reasoning: 2)
    )
    let second = trendSample(
        "2026-08-20T10:01:00Z",
        model: "gpt-5.6-sol",
        effort: "medium",
        tier: "default",
        usage: trendUsage(input: 50, cached: 10, output: 5, reasoning: 1)
    )
    let report = try trendReport(samples: [first, second])
    let instant = try trendDate("2026-08-20T10:00:48Z")
    let result = try trendAggregator().aggregate(
        reports: [report],
        filter: UsageTrendFilter(startMinute: instant, endMinute: instant)
    )

    let series = try #require(result.series.first)
    #expect(result.series.count == 1)
    #expect(series.summary.tokens.totalTokens == 110)
    #expect(series.summary.tokens.nonCachedInputTokens == 80)
    #expect(series.summary.tokens.cachedInputTokens == 20)
    #expect(series.summary.tokens.cacheWriteInputTokens == 10)
    #expect(series.summary.tokens.outputTokens == 10)
    #expect(series.summary.tokens.reasoningOutputTokens == 2)
    #expect(series.summary.isApproximate == false)
}

@Test("Trend returns an empty series list when no sample matches the filters")
func trendEmptySelectionHasNoSyntheticZeroCurve() throws {
    let report = try trendReport(samples: [
        trendSample(
            "2026-08-20T10:00:00Z",
            model: "gpt-5.6-sol",
            effort: "medium",
            tier: "default",
            usage: trendUsage(input: 10)
        )
    ])
    let minute = try trendDate("2026-08-20T10:00:00Z")
    let result = try trendAggregator().aggregate(
        reports: [report],
        filter: UsageTrendFilter(
            startMinute: minute,
            endMinute: minute,
            selectedModels: ["gpt-5.6-terra"],
            groupMode: .all
        )
    )

    #expect(result.series.isEmpty)
}

@Test("Trend buckets in the supplied calendar and fills missing days")
func trendLocalMidnightAndZeroDays() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let report = try trendReport(samples: [
        trendSample(
            "2026-03-01T15:59:00Z",
            model: "gpt-5.6-sol",
            effort: "high",
            tier: "default",
            usage: trendUsage(input: 10)
        ),
        trendSample(
            "2026-03-01T16:01:00Z",
            model: "gpt-5.6-sol",
            effort: "high",
            tier: "default",
            usage: trendUsage(input: 20)
        )
    ])
    let start = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 3, day: 1, hour: 0, minute: 0
    )))
    let end = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 3, day: 3, hour: 23, minute: 59
    )))
    let result = UsageTrendAggregator(catalog: try PricingCatalog.bundled(), calendar: calendar)
        .aggregate(
            reports: [report],
            filter: UsageTrendFilter(startMinute: start, endMinute: end)
        )

    let points = try #require(result.series.first?.points)
    #expect(points.count == 3)
    #expect(points.map(\.aggregate.tokens.totalTokens) == [10, 20, 0])
    #expect(result.series.first?.summary.tokens.totalTokens == 30)
}

@Test("Trend normalizes model aliases and Standard/Fast filters before grouping")
func trendConfigurationFilteringAndGrouping() throws {
    let report = try trendReport(samples: [
        trendSample(
            "2026-08-20T10:00:00Z",
            model: "gpt-5.6",
            effort: "ultra",
            tier: "default",
            usage: trendUsage(input: 10)
        ),
        trendSample(
            "2026-08-20T10:01:00Z",
            model: "gpt-5.6-sol",
            effort: "ultra",
            tier: "priority",
            usage: trendUsage(input: 20)
        ),
        trendSample(
            "2026-08-20T10:02:00Z",
            model: "gpt-5.6-terra",
            effort: "low",
            tier: nil,
            usage: trendUsage(input: 30)
        )
    ])
    let start = try trendDate("2026-08-20T10:00:00Z")
    let end = try trendDate("2026-08-20T10:02:00Z")
    let aggregator = try trendAggregator()

    let split = aggregator.aggregate(
        reports: [report],
        filter: UsageTrendFilter(
            startMinute: start,
            endMinute: end,
            groupMode: .configuration
        )
    )
    #expect(split.series.count == 3)
    #expect(split.dimensions.models.map(\.id).contains("gpt-5.6-sol"))
    #expect(Set(split.dimensions.speeds) == [.standard, .fast, .unknown])

    let fastSol = aggregator.aggregate(
        reports: [report],
        filter: UsageTrendFilter(
            startMinute: start,
            endMinute: end,
            selectedModels: ["gpt-5.6-sol"],
            selectedEfforts: ["ultra"],
            selectedSpeeds: [.fast],
            groupMode: .configuration
        )
    )
    #expect(fastSol.series.count == 1)
    #expect(fastSol.series.first?.summary.tokens.totalTokens == 20)
}

@Test("Trend prices each minute with cache-aware configured rates")
func trendPriceAndCoverage() throws {
    let usage = trendUsage(
        input: 1_000_000,
        cached: 200_000,
        cacheWrite: 100_000,
        output: 100_000,
        reasoning: 40_000
    )
    let report = try trendReport(samples: [
        trendSample(
            "2026-08-20T10:00:00Z",
            model: "gpt-5.6-sol",
            effort: "medium",
            tier: "default",
            usage: usage
        )
    ])
    let minute = try trendDate("2026-08-20T10:00:00Z")
    let result = try trendAggregator().aggregate(
        reports: [report],
        filter: UsageTrendFilter(startMinute: minute, endMinute: minute)
    )
    let summary = try #require(result.series.first?.summary)

    #expect(summary.credits.amount == Decimal(string: "177.5"))
    #expect(summary.credits.basis == .configured)
    #expect(summary.credits.pricedTokens == 1_100_000)
    #expect(summary.apiUSD.amount == Decimal(string: "7.225"))
    #expect(summary.apiUSD.basis == .configured)
    #expect(summary.apiUSD.isPartial == false)
}

@Test("Trend keeps safe price subtotals while exposing suppressed coverage")
func trendSuppressedPriceCoverage() throws {
    let minuteText = "2026-08-20T10:00:00Z"
    let priced = try trendReport(
        samples: [
            trendSample(
                minuteText,
                model: "gpt-5.6-sol",
                effort: "medium",
                tier: "default",
                usage: trendUsage(input: 100)
            )
        ],
        id: "priced"
    )
    let suppressed = try trendReport(
        samples: [
            trendSample(
                minuteText,
                model: "gpt-5.6-sol",
                effort: "medium",
                tier: "default",
                usage: trendUsage(input: 200)
            )
        ],
        id: "suppressed",
        costSuppressed: true
    )
    let minute = try trendDate(minuteText)
    let result = try trendAggregator().aggregate(
        reports: [priced, suppressed],
        filter: UsageTrendFilter(startMinute: minute, endMinute: minute)
    )
    let credits = try #require(result.series.first?.summary.credits)

    #expect(credits.amount != nil)
    #expect(credits.pricedTokens == 100)
    #expect(credits.totalTokens == 300)
    #expect(credits.suppressedTokens == 200)
    #expect(credits.isPartial)
    #expect(credits.isSuppressed)
}

@Test("Legacy segments fall back to last usage time and stay visibly approximate")
func trendLegacyFallback() throws {
    let segment = trendSegment(
        "2026-08-20T10:03:00Z",
        model: "gpt-5.6-sol",
        effort: "medium",
        tier: "default",
        usage: trendUsage(input: 40, output: 2)
    )
    let report = try trendReport(samples: nil, segments: [segment])
    let minute = try trendDate("2026-08-20T10:03:00Z")
    let result = try trendAggregator().aggregate(
        reports: [report],
        filter: UsageTrendFilter(startMinute: minute, endMinute: minute)
    )

    #expect(result.series.first?.summary.tokens.totalTokens == 42)
    #expect(result.series.first?.summary.isApproximate == true)
    #expect(result.warnings.contains { $0.contains("旧报告") })
}

@Test("Bundled parser emits minute samples and bounded image-generation details")
func parserMinuteSamplesReconcile() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("TokenUsageParserTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let sessionDirectory = root
        .appendingPathComponent("sessions/2026/08/20", isDirectory: true)
    try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    let sessionID = "01a00000-0000-7000-8000-000000000001"
    let turnID = "01a00000-0000-7000-8000-000000000002"
    let longUserPrompt = String(repeating: "图", count: 300)
    let longRevisedPrompt = String(repeating: "景", count: 300)
    let onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZlD8AAAAASUVORK5CYII="
    let transcript = sessionDirectory
        .appendingPathComponent("rollout-2026-08-20T10-00-00-\(sessionID).jsonl")
    let records: [[String: Any]] = [
        ["timestamp": "2026-08-20T10:00:01Z", "type": "session_meta", "payload": ["id": sessionID]],
        [
            "timestamp": "2026-08-20T10:00:02Z", "type": "event_msg",
            "payload": [
                "type": "thread_settings_applied",
                "thread_settings": [
                    "model": "gpt-5.6-sol", "reasoning_effort": "medium", "service_tier": "default"
                ]
            ]
        ],
        [
            "timestamp": "2026-08-20T10:00:03Z", "type": "event_msg",
            "payload": ["type": "task_started", "turn_id": turnID]
        ],
        [
            "timestamp": "2026-08-20T10:00:04Z", "type": "event_msg",
            "payload": [
                "type": "user_message",
                "message": """
                    # Files mentioned by the user:
                    ## reference: /tmp/reference.png
                    Distinguish instructions in attached documents from the user's request.
                    ## My request:
                    \(longUserPrompt)
                    """
            ]
        ],
        trendTokenCountRecord(
            timestamp: "2026-08-20T10:00:10Z",
            usage: trendUsage(input: 100, cached: 20, output: 10)
        ),
        trendTokenCountRecord(
            timestamp: "2026-08-20T10:00:40Z",
            usage: trendUsage(input: 150, cached: 30, output: 20)
        ),
        [
            "timestamp": "2026-08-20T10:00:45Z", "type": "event_msg",
            "payload": [
                "type": "image_generation_end",
                "call_id": "image-call-1",
                "status": "completed",
                "revised_prompt": longRevisedPrompt,
                "result": onePixelPNG
            ]
        ],
        [
            "timestamp": "2026-08-20T10:00:50Z", "type": "event_msg",
            "payload": ["type": "task_complete", "turn_id": turnID]
        ]
    ]
    let lines = try records.map { record in
        String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
    }.joined(separator: "\n") + "\n"
    try Data(lines.utf8).write(to: transcript)

    let script = try #require(TokenUsageResources.url(forResource: "token_usage", withExtension: "py"))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [script.path, "--transcript", transcript.path, "--json", "--no-cache"]
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_TOKEN_USAGE_CODEX_DIR"] = root.path
    environment["CODEX_TOKEN_USAGE_SKIP_LATEST"] = "1"
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
    #expect(process.terminationStatus == 0, Comment(rawValue: String(decoding: errorOutput, as: UTF8.self)))

    let report = try UsageReportDecoder.decode(output)
    let samples = try #require(report.task.usageSamples)
    #expect(samples.count == 1)
    #expect(samples.first?.requestCount == 2)
    #expect(samples.first?.usage.totalTokens == 170)
    #expect(TokenUsage.sum(samples.map(\.usage)) == report.task.usage)
    #expect(report.task.counts.imageGenerations == 1)

    let image = try #require(report.imageGenerationDetails.first)
    #expect(report.imageGenerationDetails.count == 1)
    #expect(image.threadId == sessionID)
    #expect(image.turnId == turnID)
    #expect(image.userPromptPreview?.count == 240)
    #expect(image.userPromptPreview?.hasPrefix("图图图") == true)
    #expect(image.userPromptTruncated == true)
    #expect(image.revisedPromptPreview?.count == 240)
    #expect(image.revisedPromptTruncated == true)
    #expect(image.actualWidth == 1)
    #expect(image.actualHeight == 1)
    #expect(image.outputFormat == "png")
    #expect(image.outputBytes == Int64(Data(base64Encoded: onePixelPNG)?.count ?? 0))

    let raw = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
    let threads = try #require(raw["threads"] as? [[String: Any]])
    #expect(threads.allSatisfy { $0["usage_samples"] == nil })
    #expect(threads.flatMap { $0["turns"] as? [[String: Any]] ?? [] }.allSatisfy {
        $0["usage_samples"] == nil
    })
}

@Test("Forked transcripts exclude inherited usage samples before the owned boundary")
func parserForkSampleOwnership() throws {
    let script = try #require(TokenUsageResources.url(forResource: "token_usage", withExtension: "py"))
    let code = """
        import json, runpy, sys
        ns = runpy.run_path(sys.argv[1])
        state = {
            "forked_from_id": "parent",
            "usage_samples": [
                {"task_epoch": 1, "usage": {"total_tokens": 10}},
                {"task_epoch": 2, "usage": {"total_tokens": 20}},
                {"task_epoch": 3, "usage": {"total_tokens": 30}},
            ],
        }
        owned = ns["_owned_usage_samples"](state, {"task_epoch": 2})
        print(json.dumps([item["task_epoch"] for item in owned]))
        """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", code, script.path]
    var environment = ProcessInfo.processInfo.environment
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    process.environment = environment
    let stdout = Pipe()
    process.standardOutput = stdout
    try process.run()
    process.waitUntilExit()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    #expect(process.terminationStatus == 0)
    let epochs = try JSONSerialization.jsonObject(with: output) as? [Int]
    #expect(epochs == [2, 3])
}

@Test("Transcript resolution never follows a copied Home's stale absolute rollout path")
func parserTranscriptResolutionStaysInsideSelectedHome() throws {
    let fileManager = FileManager.default
    let container = fileManager.temporaryDirectory
        .appendingPathComponent("TokenUsageResolutionTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: container) }
    let currentHome = container.appendingPathComponent("current", isDirectory: true)
    let oldHome = container.appendingPathComponent("old", isDirectory: true)
    let relativeDirectory = "sessions/2026/08/20"
    let currentDirectory = currentHome.appendingPathComponent(relativeDirectory, isDirectory: true)
    let oldDirectory = oldHome.appendingPathComponent(relativeDirectory, isDirectory: true)
    try fileManager.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
    let threadID = "01a00000-0000-7000-8000-000000000099"
    let fileName = "rollout-2026-08-20T10-00-00-\(threadID).jsonl"
    let currentTranscript = currentDirectory.appendingPathComponent(fileName)
    let oldTranscript = oldDirectory.appendingPathComponent(fileName)
    try Data("current\n".utf8).write(to: currentTranscript)
    try Data("old\n".utf8).write(to: oldTranscript)

    let script = try #require(TokenUsageResources.url(forResource: "token_usage", withExtension: "py"))
    let code = """
        import runpy, sys
        from pathlib import Path
        ns = runpy.run_path(sys.argv[1])
        result = ns["_resolve_transcript"](
            {"rollout_path": sys.argv[2]}, sys.argv[3], Path(sys.argv[4])
        )
        print(result or "")
        """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
        "-c", code, script.path, oldTranscript.path, threadID, currentHome.path
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    process.environment = environment
    let stdout = Pipe()
    process.standardOutput = stdout
    try process.run()
    process.waitUntilExit()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let resolved = String(decoding: output, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    #expect(process.terminationStatus == 0)
    #expect(fileManager.contentsEqual(atPath: resolved, andPath: currentTranscript.path))
    #expect(!fileManager.contentsEqual(atPath: resolved, andPath: oldTranscript.path))
}

private func trendAggregator() throws -> UsageTrendAggregator {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return UsageTrendAggregator(catalog: try PricingCatalog.bundled(), calendar: calendar)
}

private func trendDate(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return try #require(formatter.date(from: value))
}

private func trendUsage(
    input: Int64 = 0,
    cached: Int64 = 0,
    cacheWrite: Int64 = 0,
    output: Int64 = 0,
    reasoning: Int64 = 0
) -> [String: Any] {
    [
        "input_tokens": input,
        "cached_input_tokens": cached,
        "cache_write_input_tokens": cacheWrite,
        "output_tokens": output,
        "reasoning_output_tokens": reasoning,
        "total_tokens": input + output
    ]
}

private func trendSample(
    _ minute: String,
    model: String?,
    effort: String?,
    tier: String?,
    usage: [String: Any]
) -> [String: Any] {
    var result: [String: Any] = [
        "minute": minute,
        "task_epoch": 1,
        "long_context": false,
        "usage": usage,
        "request_count": 1,
        "tier_source": "thread_settings"
    ]
    if let model { result["model"] = model }
    if let effort { result["effort"] = effort }
    if let tier { result["tier"] = tier }
    return result
}

private func trendSegment(
    _ lastAt: String,
    model: String?,
    effort: String?,
    tier: String?,
    usage: [String: Any]
) -> [String: Any] {
    var result = trendSample(lastAt, model: model, effort: effort, tier: tier, usage: usage)
    result.removeValue(forKey: "minute")
    result["first_at"] = lastAt
    result["last_at"] = lastAt
    return result
}

private func trendReport(
    samples: [[String: Any]]?,
    segments: [[String: Any]] = [],
    id: String = UUID().uuidString,
    generatedAt: String = "2026-08-20T12:00:00Z",
    costSuppressed: Bool = false
) throws -> UsageReport {
    let sampleUsage = samples?.compactMap { $0["usage"] as? [String: Any] } ?? []
    let segmentUsage = segments.compactMap { $0["usage"] as? [String: Any] }
    let usage = trendSumUsage(sampleUsage.isEmpty ? segmentUsage : sampleUsage)
    let zero = trendUsage()
    let zeroCounts: [String: Any] = [
        "image_inputs": 0, "audio_inputs": 0, "image_generations": 0,
        "web_searches": 0, "mcp_calls": 0, "tool_calls": 0
    ]
    var task: [String: Any] = [
        "usage": usage,
        "counts": zeroCounts,
        "root_usage": usage,
        "agents_usage": zero,
        "segments": segments,
        "cost": ["cost_suppressed": costSuppressed],
        "linked_agent_threads": 0,
        "usage_is_lower_bound": false
    ]
    if let samples { task["usage_samples"] = samples }
    let root: [String: Any] = [
        "report_schema_version": 1,
        "generated_at": generatedAt,
        "root_thread_id": id,
        "selected_turn_id": NSNull(),
        "current_turn": [
            "available": false,
            "usage_is_provisional": false,
            "usage": usage,
            "counts": zeroCounts,
            "root_usage": usage,
            "agents_usage": zero,
            "segments": segments,
            "cost": ["cost_suppressed": costSuppressed],
            "duration_ms": NSNull(),
            "ttft_ms": NSNull()
        ],
        "task": task,
        "threads": [],
        "completeness": [:],
        "warnings": [],
        "pricing_catalog": [:]
    ]
    return try UsageReportDecoder.decode(JSONSerialization.data(withJSONObject: root))
}

private func trendSumUsage(_ usages: [[String: Any]]) -> [String: Any] {
    var input: Int64 = 0
    var cached: Int64 = 0
    var cacheWrite: Int64 = 0
    var output: Int64 = 0
    var reasoning: Int64 = 0
    for usage in usages {
        input += usage["input_tokens"] as? Int64 ?? 0
        cached += usage["cached_input_tokens"] as? Int64 ?? 0
        cacheWrite += usage["cache_write_input_tokens"] as? Int64 ?? 0
        output += usage["output_tokens"] as? Int64 ?? 0
        reasoning += usage["reasoning_output_tokens"] as? Int64 ?? 0
    }
    return trendUsage(
        input: input,
        cached: cached,
        cacheWrite: cacheWrite,
        output: output,
        reasoning: reasoning
    )
}

private func trendTokenCountRecord(
    timestamp: String,
    usage: [String: Any]
) -> [String: Any] {
    [
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": [
            "type": "token_count",
            "info": ["total_token_usage": usage]
        ]
    ]
}
