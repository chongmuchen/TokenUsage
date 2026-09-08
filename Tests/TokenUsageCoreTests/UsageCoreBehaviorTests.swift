import Foundation
import Testing
@testable import TokenUsageCore

@Test("Report v1 decodes snake-case fields and ISO-8601 timestamps")
func reportV1Decoding() throws {
    let report = try UsageReportDecoder.decode(makeSyntheticReportData())

    #expect(report.reportSchemaVersion == 1)
    #expect(report.rootThreadId == "session-root")
    #expect(report.displayName == "Synthetic report")
    #expect(report.selectedTurnId == "turn-main")
    #expect(report.task.usage.totalTokens == 190)
    #expect(report.task.usage.cachedInputTokens == 30)
    #expect(report.task.usage.ordinaryInputTokens == 118)
    #expect(report.threads.count == 4)
    #expect(report.imageGenerations == nil)

    let segment = try #require(report.task.segments.first)
    #expect(segment.model == "synthetic-model")
    #expect(segment.tierSource == "response")
    #expect(segment.firstAt != nil)
    #expect(segment.lastAt != nil)
    #expect(segment.requestCount == 4)
}

@Test("Optional image-generation details decode and follow their turn through the tree")
func optionalImageGenerationDetails() throws {
    let base = try #require(
        JSONSerialization.jsonObject(with: makeSyntheticReportData()) as? [String: Any]
    )
    var object = base
    object["image_generations"] = [[
        "id": "image-call-hash",
        "thread_id": "session-root",
        "turn_id": "turn-main",
        "generated_at": "2026-01-10T12:00:30Z",
        "status": "completed",
        "user_prompt_preview": "用户输入预览",
        "user_prompt_truncated": false,
        "revised_prompt_preview": "生成提示词预览",
        "revised_prompt_truncated": true,
        "requested_size": "1024x1024",
        "requested_quality": "high",
        "actual_width": 1536,
        "actual_height": 1024,
        "output_format": "png",
        "output_bytes": 123_456
    ], [:]]

    let report = try UsageReportDecoder.decode(
        JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
    let detail = try #require(report.imageGenerationDetails.first)
    #expect(report.imageGenerationDetails.count == 2)
    #expect(report.imageGenerationDetails[1].id == nil)
    #expect(detail.userPromptPreview == "用户输入预览")
    #expect(detail.revisedPromptTruncated == true)
    #expect(detail.actualWidth == 1536)

    let session = UsageTreeBuilder(catalog: try PricingCatalog.bundled()).build(
        report: report,
        title: nil
    )
    let mainTurn = try #require(session.children?.first { $0.kind == .mainTurn })
    #expect(session.imageGenerations.count == 2)
    #expect(mainTurn.imageGenerations == [detail])
}

@Test("Unsupported report schema is rejected before full decoding")
func unsupportedSchemaIsRejected() throws {
    do {
        _ = try UsageReportDecoder.decode(makeSyntheticReportData(schemaVersion: 2))
        Issue.record("Schema v2 unexpectedly decoded")
    } catch let error as UsageReportError {
        #expect(error == .unsupportedSchema(2))
    }
}

@Test("Default and quick date ranges end at 23:59 and contain 30, 7, and 1 calendar days")
func datePresetRanges() throws {
    let calendar = utcCalendar()
    let now = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 3, day: 15, hour: 18, minute: 45
    )))
    let endOfToday = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 3, day: 15, hour: 23, minute: 59
    )))

    var filter = UsageFilter(now: now, calendar: calendar)
    #expect(filter.preset == .month)
    #expect(filter.startDate == date(2026, 2, 14, calendar: calendar))
    #expect(filter.endDate == endOfToday)

    filter.apply(.week, now: now, calendar: calendar)
    #expect(filter.startDate == date(2026, 3, 9, calendar: calendar))
    #expect(filter.endDate == endOfToday)

    filter.apply(.today, now: now, calendar: calendar)
    #expect(filter.startDate == date(2026, 3, 15, calendar: calendar))
    #expect(filter.endDate == endOfToday)

    let customStart = date(2026, 1, 2, calendar: calendar)
    let customEnd = date(2026, 1, 4, calendar: calendar)
    filter.startDate = customStart
    filter.endDate = customEnd
    filter.apply(.custom, now: now, calendar: calendar)
    #expect(filter.startDate == customStart)
    #expect(filter.endDate == customEnd)
}

@Test("Minute range includes the complete selected end minute")
func minuteRangeIsInclusive() throws {
    let calendar = utcCalendar()
    let start = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 3, day: 15, hour: 10, minute: 12, second: 48
    )))
    let end = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 3, day: 15, hour: 11, minute: 34, second: 9
    )))
    var filter = UsageFilter(now: end, calendar: calendar)
    filter.startDate = start
    filter.endDate = end

    let range = filter.minuteRange(calendar: calendar)
    let expectedLower = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 3, day: 15, hour: 10, minute: 12
    )))
    let expectedUpper = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 3, day: 15, hour: 11, minute: 35
    )))
    #expect(range.lower == expectedLower)
    #expect(range.upperExclusive == expectedUpper)
}

@Test("Token bounds are normalized, inclusive, and use session subtree usage")
func tokenBounds() {
    let calendar = utcCalendar()
    let day = date(2026, 3, 15, calendar: calendar)
    let row = UsageTreeRow(
        id: "session:synthetic",
        kind: .session,
        time: day,
        name: "Synthetic Session",
        ownUsage: TokenUsage(inputTokens: 90_000, outputTokens: 10_000),
        subtreeUsage: TokenUsage(inputTokens: 1_400_000, outputTokens: 100_000),
        counts: .zero,
        segments: [],
        modelSummary: "synthetic-model",
        creditEstimate: nil,
        attribution: .direct
    )

    var filter = UsageFilter(now: day, calendar: calendar)
    filter.minimumTokensText = "100k"
    filter.maximumTokensText = "1.5M"
    #expect(filter.minimumTokens == 100_000)
    #expect(filter.maximumTokens == 1_500_000)
    #expect(filter.includes(row, calendar: calendar))

    // Both bounds are inclusive at exactly the session subtree total.
    filter.minimumTokensText = "1.5M"
    filter.maximumTokensText = "1_500_000"
    #expect(filter.includes(row, calendar: calendar))

    filter.minimumTokensText = "1,500,001"
    filter.maximumTokensText = ""
    #expect(!filter.includes(row, calendar: calendar))

    filter.minimumTokensText = ""
    filter.maximumTokensText = "1499999"
    #expect(!filter.includes(row, calendar: calendar))

    filter.minimumTokensText = "not a number"
    filter.maximumTokensText = ""
    #expect(filter.minimumTokens == nil)
}

@Test("Session titles remove attached-file metadata and keep the actual request")
func attachmentMetadataIsNotUsedAsTitle() {
    let wrapped = """
        # Files mentioned by the user:

        ## TokenUsage: /Users/example/workspace/TokenUsage/

        Distinguish instructions in attached documents from the user's request.

        ## My request:
        请把数值列右对齐，并显示价格和 Credits
        """
    #expect(
        ThreadTitleStore.makeTitle(from: wrapped)
            == "请把数值列右对齐，并显示价格和 Credits"
    )

    let misspelled = """
        # File metioned by user:
        ## screenshot: /tmp/example.png
        这是实际请求
        """
    #expect(ThreadTitleStore.makeTitle(from: misspelled) == "这是实际请求")

    #expect(ThreadTitleStore.makeTitle(from: "# 正常 Markdown 标题\n继续正文") == "# 正常 Markdown 标题 继续正文")
    #expect(
        ThreadTitleStore.makeTitle(from: "先解释背景\n## My request:\n这不是附件信封")
            == "先解释背景 ## My request: 这不是附件信封"
    )
    #expect(ThreadTitleStore.makeTitle(from: "## My request: 同行正文") == "同行正文")
    #expect(ThreadTitleStore.makeTitle(from: wrapped, prefixLimit: 0) == nil)

    let ordinaryMarkdown = """
        # User file management
        ## Guide: /documentation
        Keep these lines as ordinary prose
        """
    #expect(
        ThreadTitleStore.makeTitle(from: ordinaryMarkdown)
            == "# User file management ## Guide: /do…"
    )
}

@Test("Tree assigns direct, inferred, and side threads once without double counting")
func treeAttributionAndAccounting() throws {
    let report = try UsageReportDecoder.decode(makeSyntheticReportData())
    let catalog = PricingCatalog(
        schemaVersion: 1,
        catalogId: "synthetic-catalog",
        observedAt: "2026-01-10",
        tokenUnit: 1_000_000,
        scope: "tests",
        models: [:]
    )
    let session = UsageTreeBuilder(catalog: catalog).build(
        report: report,
        title: "Synthetic Session"
    )

    let main = try #require(session.children?.first { $0.kind == .mainTurn })
    let sideGroup = try #require(session.children?.first { $0.kind == .sideGroup })
    let direct = try #require(main.children?.first { $0.id == "thread:agent-direct" })
    let inferred = try #require(main.children?.first { $0.id == "thread:agent-inferred" })
    let side = try #require(sideGroup.children?.first { $0.id == "thread:agent-side" })

    #expect(direct.attribution == .direct)
    #expect(inferred.attribution == .timeInferred)
    #expect(side.attribution == .unattributed)

    #expect(session.ownUsage.totalTokens == 120)
    #expect(session.subtreeUsage.totalTokens == 190)
    #expect(main.ownUsage.totalTokens == 120)
    #expect(main.subtreeUsage.totalTokens == 180)
    #expect(sideGroup.ownUsage.totalTokens == 0)
    #expect(sideGroup.subtreeUsage.totalTokens == 10)
    #expect(main.subtreeUsage.totalTokens + sideGroup.subtreeUsage.totalTokens == session.subtreeUsage.totalTokens)

    let attachedAgentTotal = (main.children ?? []).reduce(Int64.zero) {
        $0 + $1.subtreeUsage.totalTokens
    }
    #expect(main.ownUsage.totalTokens + attachedAgentTotal == main.subtreeUsage.totalTokens)

    // The agent turn is a breakdown of the thread's own usage, not extra usage.
    let directTurn = try #require(direct.children?.first { $0.kind == .agentTurn })
    #expect(direct.ownUsage.totalTokens == 40)
    #expect(directTurn.ownUsage.totalTokens == 40)
    #expect(direct.subtreeUsage.totalTokens == 40)

    let ids = flatten(session).map(\.id)
    #expect(ids.filter { $0 == "thread:agent-direct" }.count == 1)
    #expect(ids.filter { $0 == "thread:agent-inferred" }.count == 1)
    #expect(ids.filter { $0 == "thread:agent-side" }.count == 1)
}

@Test("Credits and API prices use separate public rate tables", arguments: ["gpt-5.6-sol", "gpt-6-astra"])
func creditsAndAPIPricesAreBothEstimated(model: String) throws {
    let catalog = try PricingCatalog.bundled()
    let estimator = CreditEstimator(catalog: catalog)
    let priceMultiplier = model == "gpt-6-astra" ? Decimal(string: "2.5")! : Decimal(1)
    let usage = TokenUsage(
        inputTokens: 1_000_000,
        cachedInputTokens: 200_000,
        cacheWriteInputTokens: 100_000,
        outputTokens: 100_000,
        reasoningOutputTokens: 40_000
    )
    let standard = UsageSegment(
        model: model,
        effort: "medium",
        tier: "default",
        tierSource: "thread_settings",
        taskEpoch: 1,
        longContext: false,
        usage: usage,
        firstAt: nil,
        lastAt: nil,
        requestCount: 1
    )
    let credits = estimator.estimate([standard])
    let api = estimator.estimateAPI([standard])
    #expect(credits.amount == Decimal(132) * priceMultiplier)
    // The segment records per-request long-context status. Its aggregate may
    // exceed 272k because it contains many short requests and must stay short.
    #expect(api.amount == Decimal(string: "5.38")! * priceMultiplier)
    #expect(api.basis == .configured)

    let fast = UsageSegment(
        model: model,
        effort: "medium",
        tier: "priority",
        tierSource: "thread_settings",
        taskEpoch: 1,
        longContext: false,
        usage: usage,
        firstAt: nil,
        lastAt: nil,
        requestCount: 1
    )
    #expect(estimator.estimate([fast]).amount == Decimal(330) * priceMultiplier)
    #expect(estimator.estimateAPI([fast]).amount == Decimal(string: "10.76")! * priceMultiplier)
    if model == "gpt-6-astra" {
        #expect(estimator.modelSummary(for: [fast]) == "GPT-6 Astra · medium · Fast")
    }

    let long = UsageSegment(
        model: model,
        effort: "medium",
        tier: "default",
        tierSource: "thread_settings",
        taskEpoch: 1,
        longContext: true,
        usage: usage,
        firstAt: nil,
        lastAt: nil,
        requestCount: 1
    )
    #expect(estimator.estimateAPI([long]).amount == Decimal(string: "9.76")! * priceMultiplier)

    let unknownContext = UsageSegment(
        model: model,
        effort: "medium",
        tier: "default",
        tierSource: "thread_settings",
        taskEpoch: 1,
        longContext: nil,
        usage: usage,
        firstAt: nil,
        lastAt: nil,
        requestCount: 1
    )
    #expect(estimator.estimateAPI([unknownContext]).amount == nil)
}

@Test("Standard reports without embedded public prices use the reader catalog")
func standardReportPricingFallsBackToReaderCatalog() throws {
    let data = try makeSyntheticReportData()
    let text = try #require(String(data: data, encoding: .utf8))
        .replacingOccurrences(of: "synthetic-model", with: "gpt-5.6-sol")
    let report = try UsageReportDecoder.decode(Data(text.utf8))
    let session = UsageTreeBuilder(catalog: try PricingCatalog.bundled()).build(
        report: report,
        title: report.displayName
    )

    #expect(session.name == "Synthetic report")
    #expect(session.creditEstimate?.amount != nil)
    #expect(session.apiPriceEstimate?.amount != nil)
}

@Test("Suppressed costs stay hidden and partial session prices prefer broader coverage")
func sessionPriceSafetyRules() throws {
    let catalog = try PricingCatalog.bundled()
    let builder = UsageTreeBuilder(catalog: catalog)

    let suppressed = try UsageReportDecoder.decode(
        makeSyntheticReportData(taskCost: [
            "cost_suppressed": true,
            "codex_credits_standard_equivalent": "999",
            "api_usd_standard_equivalent": "999"
        ])
    )
    let suppressedRows = flatten(builder.build(report: suppressed, title: "Synthetic"))
    #expect(suppressedRows.allSatisfy { $0.creditEstimate == nil })
    #expect(suppressedRows.allSatisfy { $0.apiPriceEstimate == nil })

    let partial = try UsageReportDecoder.decode(
        makeSyntheticReportData(taskCost: [
            "codex_credits_configured_tier_priced_subtotal": "1.25",
            "codex_credits_standard_priced_subtotal": "2.50",
            "credit_configured_priced_tokens": 10,
            "credit_standard_priced_tokens": 180,
            "api_usd_configured_tier_priced_subtotal": "0.10",
            "api_usd_standard_priced_subtotal": "0.20",
            "api_configured_priced_tokens": 10,
            "api_standard_priced_tokens": 180
        ])
    )
    let session = builder.build(report: partial, title: "Synthetic")
    #expect(session.creditEstimate?.basis == .standard)
    #expect(session.creditEstimate?.amount == Decimal(string: "2.50"))
    #expect(session.apiPriceEstimate?.basis == .standard)
    #expect(session.apiPriceEstimate?.amount == Decimal(string: "0.20"))
}

@Test("Historical sync rebuilds lower-bound, suppressed, legacy, no-limit, and stale-price reports")
func historicalSyncRefreshPolicy() throws {
    let current = try historicalPolicyReport()
    #expect(!HistoricalReportGenerator.needsRefresh(
        report: current,
        expectedRootID: "session-root",
        currentCatalogID: "current-catalog"
    ))
    #expect(HistoricalReportGenerator.needsRefresh(
        report: try historicalPolicyReport(hasUsageSamples: false),
        expectedRootID: "session-root",
        currentCatalogID: "current-catalog"
    ))
    #expect(HistoricalReportGenerator.needsRefresh(
        report: try historicalPolicyReport(hasRateLimitSnapshots: false),
        expectedRootID: "session-root",
        currentCatalogID: "current-catalog"
    ))
    #expect(HistoricalReportGenerator.needsRefresh(
        report: try historicalPolicyReport(isLowerBound: true),
        expectedRootID: "session-root",
        currentCatalogID: "current-catalog"
    ))
    #expect(HistoricalReportGenerator.needsRefresh(
        report: try historicalPolicyReport(costSuppressed: true),
        expectedRootID: "session-root",
        currentCatalogID: "current-catalog"
    ))
    #expect(HistoricalReportGenerator.needsRefresh(
        report: try historicalPolicyReport(reportCatalogID: "old-catalog"),
        expectedRootID: "session-root",
        currentCatalogID: "current-catalog"
    ))
    #expect(HistoricalReportGenerator.needsRefresh(
        report: try historicalPolicyReport(costCatalogID: "old-catalog"),
        expectedRootID: "session-root",
        currentCatalogID: "current-catalog"
    ))
    #expect(HistoricalReportGenerator.needsRefresh(
        report: current,
        expectedRootID: "another-session",
        currentCatalogID: "current-catalog"
    ))
}

@Test("Filtered summary counts only sessions and preserves displayed price coverage")
func filteredSummaryRow() throws {
    let builder = UsageTreeBuilder(catalog: try PricingCatalog.bundled())
    let firstUsage = TokenUsage(inputTokens: 100, outputTokens: 20)
    let secondUsage = TokenUsage(inputTokens: 70, outputTokens: 10)
    let first = UsageTreeRow(
        id: "session:first",
        kind: .session,
        time: Date(timeIntervalSince1970: 1),
        name: "First",
        ownUsage: firstUsage,
        subtreeUsage: firstUsage,
        counts: UsageCounts(imageInputs: 1),
        segments: [],
        modelSummary: "model-a",
        creditEstimate: CreditEstimate(
            amount: Decimal(string: "1.25"),
            basis: .configured,
            pricedTokens: 120,
            totalTokens: 120
        ),
        apiPriceEstimate: APIPriceEstimate(
            amount: Decimal(string: "0.10"),
            basis: .configured,
            pricedTokens: 120,
            totalTokens: 120
        ),
        attribution: .direct
    )
    let second = UsageTreeRow(
        id: "session:second",
        kind: .session,
        time: Date(timeIntervalSince1970: 2),
        name: "Second",
        ownUsage: secondUsage,
        subtreeUsage: secondUsage,
        counts: UsageCounts(imageInputs: 2),
        segments: [],
        modelSummary: "model-b",
        creditEstimate: CreditEstimate(
            amount: Decimal(string: "2.50"),
            basis: .standard,
            pricedTokens: 40,
            totalTokens: 80
        ),
        apiPriceEstimate: nil,
        attribution: .direct
    )
    let child = UsageTreeRow(
        id: "turn:child",
        kind: .agentTurn,
        time: Date(timeIntervalSince1970: 3),
        name: "Child that must not be counted",
        ownUsage: TokenUsage(inputTokens: 9_000, outputTokens: 1_000),
        subtreeUsage: TokenUsage(inputTokens: 9_000, outputTokens: 1_000),
        counts: UsageCounts(imageInputs: 99),
        segments: [],
        modelSummary: "model-child",
        creditEstimate: CreditEstimate(
            amount: Decimal(string: "999"),
            basis: .configured,
            pricedTokens: 10_000,
            totalTokens: 10_000
        ),
        attribution: .direct
    )

    let summary = try #require(builder.summaryRow(for: [first, child, second]))
    #expect(summary.kind == .summary)
    #expect(summary.children == nil)
    #expect(summary.subtreeUsage.totalTokens == 200)
    #expect(summary.counts.imageInputs == 3)
    #expect(summary.creditEstimate?.amount == Decimal(string: "3.75"))
    #expect(summary.creditEstimate?.basis == .mixed)
    #expect(summary.creditEstimate?.pricedTokens == 160)
    #expect(summary.creditEstimate?.isPartial == true)
    #expect(summary.apiPriceEstimate?.amount == Decimal(string: "0.10"))
    #expect(summary.apiPriceEstimate?.basis == .configured)
    #expect(summary.apiPriceEstimate?.pricedTokens == 120)
    #expect(summary.apiPriceEstimate?.isPartial == true)
    #expect(!UsageFilter().includes(summary))
    #expect(builder.summaryRow(for: [child]) == nil)
}

private func makeSyntheticReportData(
    schemaVersion: Int = 1,
    taskCost: [String: Any] = [:]
) throws -> Data {
    let rootUsage = usage(input: 100, cached: 20, cacheWrite: 5, output: 20, reasoning: 5)
    let directUsage = usage(input: 30, cached: 10, output: 10, reasoning: 2)
    let inferredUsage = usage(input: 15, output: 5, reasoning: 1)
    let sideUsage = usage(input: 8, output: 2)
    let taskUsage = usage(input: 153, cached: 30, cacheWrite: 5, output: 37, reasoning: 8)
    let agentUsage = usage(input: 53, cached: 10, output: 17, reasoning: 3)

    let rootTurn = turn(
        id: "turn-main",
        usage: rootUsage,
        start: "2026-01-10T12:00:00Z",
        end: "2026-01-10T12:01:00Z",
        agentThreadIDs: ["agent-direct"]
    )
    let directTurn = turn(
        id: "turn-direct",
        usage: directUsage,
        start: "2026-01-10T12:00:10.500Z",
        end: "2026-01-10T12:00:20Z"
    )
    let inferredTurn = turn(
        id: "turn-inferred",
        usage: inferredUsage,
        start: "2026-01-10T12:00:30Z",
        end: "2026-01-10T12:00:40Z"
    )
    let sideTurn = turn(
        id: "turn-side",
        usage: sideUsage,
        start: "2026-01-10T13:00:00Z",
        end: "2026-01-10T13:00:10Z"
    )

    let segment: [String: Any] = [
        "model": "synthetic-model",
        "effort": "medium",
        "tier": "fast",
        "tier_source": "response",
        "task_epoch": 1,
        "long_context": false,
        "usage": taskUsage,
        "first_at": "2026-01-10T12:00:00Z",
        "last_at": "2026-01-10T13:00:10.125Z",
        "request_count": 4
    ]

    let object: [String: Any] = [
        "report_schema_version": schemaVersion,
        "generated_at": "2026-01-10T14:00:00.250Z",
        "root_thread_id": "session-root",
        "display_name": "Synthetic report",
        "selected_turn_id": "turn-main",
        "current_turn": [
            "available": false,
            "usage_is_provisional": false,
            "usage": zeroUsage(),
            "counts": zeroCounts(),
            "root_usage": zeroUsage(),
            "agents_usage": zeroUsage(),
            "segments": [],
            "cost": [:]
        ],
        "task": [
            "usage": taskUsage,
            "counts": zeroCounts(),
            "root_usage": rootUsage,
            "agents_usage": agentUsage,
            "segments": [segment],
            "cost": taskCost,
            "linked_agent_threads": 3,
            "usage_is_lower_bound": false
        ],
        "threads": [
            thread(id: "session-root", usage: rootUsage, turns: [rootTurn], source: "synthetic-root"),
            thread(id: "agent-direct", parentID: "session-root", usage: directUsage, turns: [directTurn], source: "synthetic-direct"),
            thread(id: "agent-inferred", parentID: "session-root", usage: inferredUsage, turns: [inferredTurn], source: "synthetic-inferred"),
            thread(id: "agent-side", usage: sideUsage, turns: [sideTurn], source: "synthetic-side")
        ],
        "completeness": [:],
        "warnings": [],
        "pricing_catalog": [
            "catalog_id": "synthetic-catalog",
            "observed_at": "2026-01-10",
            "scope": "tests"
        ]
    ]
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func historicalPolicyReport(
    hasUsageSamples: Bool = true,
    hasRateLimitSnapshots: Bool = true,
    isLowerBound: Bool = false,
    costSuppressed: Bool = false,
    reportCatalogID: String = "current-catalog",
    costCatalogID: String = "current-catalog"
) throws -> UsageReport {
    var object = try #require(
        JSONSerialization.jsonObject(with: makeSyntheticReportData()) as? [String: Any]
    )
    var task = try #require(object["task"] as? [String: Any])
    if hasUsageSamples {
        task["usage_samples"] = []
    } else {
        task.removeValue(forKey: "usage_samples")
    }
    if hasRateLimitSnapshots {
        object["rate_limit_snapshots"] = []
    } else {
        object.removeValue(forKey: "rate_limit_snapshots")
    }
    task["usage_is_lower_bound"] = isLowerBound
    task["cost"] = [
        "catalog_id": costCatalogID,
        "cost_suppressed": costSuppressed
    ]
    object["task"] = task
    object["pricing_catalog"] = [
        "catalog_id": reportCatalogID,
        "observed_at": "2026-09-01",
        "scope": "tests"
    ]
    return try UsageReportDecoder.decode(
        JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}

private func usage(
    input: Int64,
    cached: Int64 = 0,
    cacheWrite: Int64 = 0,
    output: Int64,
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

private func zeroUsage() -> [String: Any] {
    usage(input: 0, output: 0)
}

private func zeroCounts() -> [String: Any] {
    [
        "image_inputs": 0,
        "audio_inputs": 0,
        "image_generations": 0,
        "web_searches": 0,
        "mcp_calls": 0,
        "tool_calls": 0
    ]
}

private func turn(
    id: String,
    usage: [String: Any],
    start: String,
    end: String,
    agentThreadIDs: [String] = []
) -> [String: Any] {
    [
        "turn_id": id,
        "started_at": start,
        "completed_at": end,
        "usage": usage,
        "segments": [],
        "counts": zeroCounts(),
        "agent_thread_ids": agentThreadIDs,
        "aborted": false
    ]
}

private func thread(
    id: String,
    parentID: String? = nil,
    usage: [String: Any],
    turns: [[String: Any]],
    source: String
) -> [String: Any] {
    var value: [String: Any] = [
        "thread_id": id,
        "thread_source": source,
        "exclusive_usage_available": true,
        "usage": usage,
        "counts": zeroCounts(),
        "owned_turn_ids": turns.compactMap { $0["turn_id"] as? String },
        "turns": turns,
        "active_turn_count": 0,
        "segments": [],
        "warnings": [],
        "parse_errors": 0,
        "unclassified_compaction_total": 0
    ]
    if let parentID { value["parent_thread_id"] = parentID }
    return value
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

private func flatten(_ row: UsageTreeRow) -> [UsageTreeRow] {
    [row] + (row.children ?? []).flatMap(flatten)
}
