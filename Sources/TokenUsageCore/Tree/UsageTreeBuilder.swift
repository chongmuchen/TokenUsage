import Foundation

public struct UsageTreeBuilder: Sendable {
    private let estimator: CreditEstimator

    public init(catalog: PricingCatalog) {
        self.estimator = CreditEstimator(catalog: catalog)
    }

    public func build(reports: [UsageReport], titles: [String: String]) -> [UsageTreeRow] {
        reports
            .map { build(report: $0, title: titles[$0.rootThreadId] ?? $0.displayName) }
            .sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }
    }

    /// Builds one non-expandable footer row from the already-filtered top-level
    /// sessions. Only each session's displayed subtree total is included, so
    /// expanded child rows are never counted a second time.
    public func summaryRow(for sessions: [UsageTreeRow]) -> UsageTreeRow? {
        let topLevel = sessions.filter { $0.kind == .session }
        guard !topLevel.isEmpty else { return nil }

        let totalUsage = TokenUsage.sum(topLevel.map(\.subtreeUsage))
        let ownUsage = TokenUsage.sum(topLevel.map(\.ownUsage))
        let counts = UsageCounts.sum(topLevel.map(\.counts))
        let imageGenerations = topLevel.flatMap(\.imageGenerations)
        let allSegments = topLevel.flatMap(\.segments)
        let credit = aggregateCredits(topLevel, totalTokens: totalUsage.totalTokens)
        let apiPrice = aggregateAPIPrices(topLevel, totalTokens: totalUsage.totalTokens)
        var warnings: [String] = []
        if credit?.basis == .mixed { warnings.append("Credits 汇总包含配置价和 Standard 价两种估算口径。") }
        if apiPrice?.basis == .mixed { warnings.append("API USD 汇总包含配置档和 Standard 两种估算口径。") }
        if topLevel.contains(where: { containsPricingSuppressionReason($0.warnings) }) {
            warnings.append("部分会话的 Token 计数校验未通过；price estimates were suppressed（价格估算已隐藏）。")
        }

        return UsageTreeRow(
            id: "summary:filtered",
            kind: .summary,
            time: nil,
            name: "当前筛选汇总 · \(topLevel.count) 个会话",
            ownUsage: ownUsage,
            subtreeUsage: totalUsage,
            counts: counts,
            imageGenerations: imageGenerations,
            segments: allSegments,
            modelSummary: estimator.modelSummary(for: allSegments),
            creditEstimate: credit,
            apiPriceEstimate: apiPrice,
            attribution: .direct,
            isProvisional: topLevel.contains(where: \.isProvisional),
            isLowerBound: topLevel.contains(where: \.isLowerBound),
            isUsageApproximate: topLevel.contains(where: \.isUsageApproximate),
            isOwnUsageApproximate: topLevel.contains(where: \.isOwnUsageApproximate),
            pricingSuppressed: topLevel.allSatisfy(\.pricingSuppressed),
            warnings: warnings
        )
    }

    /// Projects a full-session row tree onto the same half-open minute range
    /// used by `UsageTrendAggregator`. Exact samples are preferred; legacy
    /// rows fall back to their segment observation times and are marked as
    /// approximate. Rows with no selected Token are omitted.
    public func slicedRow(
        _ row: UsageTreeRow,
        lower: Date,
        upperExclusive: Date
    ) -> UsageTreeRow? {
        guard lower < upperExclusive else { return nil }

        let own = slicePlane(
            samples: row.ownUsageSamples,
            segments: row.ownSegments,
            fallbackUsage: row.ownUsage,
            fallbackTime: row.usageSampleFallbackTime ?? row.endTime ?? row.time,
            lower: lower,
            upperExclusive: upperExclusive
        )
        let subtree = slicePlane(
            samples: row.subtreeUsageSamples,
            segments: row.segments,
            fallbackUsage: row.subtreeUsage,
            fallbackTime: row.usageSampleFallbackTime ?? row.endTime ?? row.time,
            lower: lower,
            upperExclusive: upperExclusive
        )
        guard !subtree.usage.isZero else { return nil }

        let children = row.children?.compactMap {
            slicedRow($0, lower: lower, upperExclusive: upperExclusive)
        }
        let approximate = own.approximate || subtree.approximate
        var warnings = row.warnings
        if approximate {
            let warning = "该行缺少完整的分钟归属数据；时段内 Token 已按用量观测时间近似计算。"
            if !warnings.contains(warning) { warnings.append(warning) }
        }
        if
            subtree.samples != nil,
            children?.contains(where: { $0.isUsageApproximate || $0.isOwnUsageApproximate }) == true
        {
            let warning = "该行总量来自精确分钟样本；部分展开项为旧数据近似，明细之和可能不与总量完全一致。"
            if !warnings.contains(warning) { warnings.append(warning) }
        }
        let credit = row.pricingSuppressed
            ? nil
            : estimator.estimate(subtree.segments, expectedTotalTokens: subtree.usage.totalTokens)
        let apiPrice = row.pricingSuppressed
            ? nil
            : estimator.estimateAPI(subtree.segments, expectedTotalTokens: subtree.usage.totalTokens)

        return UsageTreeRow(
            id: row.id,
            kind: row.kind,
            time: row.time,
            endTime: row.endTime,
            name: row.name,
            projectName: row.projectName,
            projectPath: row.projectPath,
            ownUsage: own.usage,
            subtreeUsage: subtree.usage,
            counts: row.counts,
            imageGenerations: row.imageGenerations,
            segments: subtree.segments,
            ownSegments: own.segments,
            ownUsageSamples: own.samples,
            subtreeUsageSamples: subtree.samples,
            usageSampleFallbackTime: row.usageSampleFallbackTime,
            modelSummary: estimator.modelSummary(for: subtree.segments),
            creditEstimate: credit,
            apiPriceEstimate: apiPrice,
            apiUSDText: nil,
            attribution: row.attribution,
            isProvisional: row.isProvisional,
            isLowerBound: row.isLowerBound,
            isUsageApproximate: subtree.approximate,
            isOwnUsageApproximate: own.approximate,
            pricingSuppressed: row.pricingSuppressed,
            warnings: warnings,
            children: children
        )
    }

    public func build(
        report: UsageReport,
        title: String?,
        projectName: String? = nil,
        projectPath: String? = nil
    ) -> UsageTreeRow {
        let threadByID = Dictionary(report.threads.map { ($0.threadId, $0) }, uniquingKeysWith: { first, _ in first })
        let root = threadByID[report.rootThreadId]
        let pricingSuppressed = report.task.cost.costSuppressed == true
        let reportImageGenerations = report.imageGenerationDetails
        var attributionWarnings: [String] = []
        var ownerCandidates: [String: Set<Owner>] = [:]
        var parentMetadataConflicts = Set<String>()

        for thread in report.threads {
            for turn in thread.turns {
                for childID in turn.agentThreadIds {
                    guard
                        childID != report.rootThreadId,
                        childID != thread.threadId,
                        let child = threadByID[childID]
                    else { continue }
                    if
                        let metadataParentID = child.parentThreadId,
                        metadataParentID != thread.threadId,
                        parentMetadataConflicts.insert(childID).inserted
                    {
                        attributionWarnings.append(
                            "子对话 \(shortID(childID)) 的显式轮次引用与 parent_thread_id 冲突，已采用显式引用。"
                        )
                    }
                    ownerCandidates[childID, default: []].insert(
                        Owner(parentThreadID: thread.threadId, parentTurnID: turn.turnId, attribution: .direct)
                    )
                }
            }
        }

        var ownerByChild: [String: Owner] = [:]
        var explicitConflicts = Set<String>()
        for (childID, candidates) in ownerCandidates {
            if candidates.count == 1, let owner = candidates.first {
                ownerByChild[childID] = owner
            } else {
                explicitConflicts.insert(childID)
                attributionWarnings.append("子对话 \(shortID(childID)) 被多个轮次引用，已放入侧边对话。")
            }
        }

        for child in report.threads where child.threadId != report.rootThreadId {
            guard ownerByChild[child.threadId] == nil, !explicitConflicts.contains(child.threadId) else { continue }
            guard let parentID = child.parentThreadId, let parent = threadByID[parentID] else { continue }
            guard let childInterval = interval(for: child) else { continue }
            let overlaps = orderedTurns(parent).filter { turn in
                guard let parentInterval = interval(for: turn) else { return false }
                return intervalsOverlap(parentInterval, childInterval)
            }
            if overlaps.count == 1, let turn = overlaps.first {
                ownerByChild[child.threadId] = Owner(
                    parentThreadID: parentID,
                    parentTurnID: turn.turnId,
                    attribution: .timeInferred
                )
            }
        }

        let taskSamples = report.task.usageSamples

        func reconciledSamples(_ samples: [UsageSample], expected: TokenUsage) -> [UsageSample]? {
            TokenUsage.sum(samples.map(\.usage)) == expected ? samples : nil
        }

        func ownSamples(threadID: String, expected: TokenUsage) -> [UsageSample]? {
            guard let taskSamples else { return nil }
            return reconciledSamples(
                taskSamples.filter { $0.threadId == threadID },
                expected: expected
            )
        }

        func ownSamples(threadID: String, turnID: String, expected: TokenUsage) -> [UsageSample]? {
            guard let taskSamples else { return nil }
            return reconciledSamples(
                taskSamples.filter { $0.threadId == threadID && $0.turnId == turnID },
                expected: expected
            )
        }

        func descendantThreadIDs(startingWith roots: [String]) -> Set<String> {
            var result = Set<String>()
            var pending = roots
            while let current = pending.popLast() {
                guard result.insert(current).inserted else { continue }
                pending.append(contentsOf: ownerByChild.compactMap { childID, owner in
                    owner.parentThreadID == current ? childID : nil
                })
            }
            return result
        }

        func subtreeSamples(
            threadID: String,
            turnID: String? = nil,
            descendantRoots: [String],
            expected: TokenUsage
        ) -> [UsageSample]? {
            guard let taskSamples else { return nil }
            let descendants = descendantThreadIDs(startingWith: descendantRoots)
            let selected = taskSamples.filter { sample in
                if let ownerThreadID = sample.threadId, descendants.contains(ownerThreadID) {
                    return true
                }
                guard sample.threadId == threadID else { return false }
                return turnID == nil || sample.turnId == turnID
            }
            return reconciledSamples(selected, expected: expected)
        }

        func residualSamples(thread: ThreadSummary, expected: TokenUsage) -> [UsageSample]? {
            guard let taskSamples else { return nil }
            let knownTurnIDs = Set(thread.turns.map(\.turnId))
            return reconciledSamples(
                taskSamples.filter { sample in
                    guard sample.threadId == thread.threadId else { return false }
                    guard let turnID = sample.turnId else { return true }
                    return !knownTurnIDs.contains(turnID)
                },
                expected: expected
            )
        }

        var renderedThreadIDs = Set<String>()

        func detailBelongsToThread(_ detail: ImageGenerationDetail, threadID: String) -> Bool {
            if let detailThreadID = detail.threadId {
                return detailThreadID == threadID
            }
            guard let turnID = detail.turnId, let thread = threadByID[threadID] else { return false }
            return thread.turns.contains { $0.turnId == turnID }
        }

        func imageGenerations(threadID: String, turnID: String) -> [ImageGenerationDetail] {
            reportImageGenerations.filter {
                $0.turnId == turnID && detailBelongsToThread($0, threadID: threadID)
            }
        }

        func unmatchedImageGenerations(thread: ThreadSummary) -> [ImageGenerationDetail] {
            let knownTurnIDs = Set(thread.turns.map(\.turnId))
            return reportImageGenerations.filter { detail in
                guard detailBelongsToThread(detail, threadID: thread.threadId) else { return false }
                guard let turnID = detail.turnId else { return true }
                return !knownTurnIDs.contains(turnID)
            }
        }

        func ownThreadImageGenerations(threadID: String) -> [ImageGenerationDetail] {
            reportImageGenerations.filter { detailBelongsToThread($0, threadID: threadID) }
        }

        func childThreadIDs(parentThreadID: String, parentTurnID: String) -> [String] {
            ownerByChild
                .filter { $0.value.parentThreadID == parentThreadID && $0.value.parentTurnID == parentTurnID }
                .map(\.key)
                .sorted { lhs, rhs in
                    let left = threadByID[lhs].flatMap(interval(for:))?.start ?? .distantPast
                    let right = threadByID[rhs].flatMap(interval(for:))?.start ?? .distantPast
                    return left == right ? lhs < rhs : left < right
                }
        }

        func buildTurnRow(
            thread: ThreadSummary,
            turn: TurnSummary,
            ordinal: Int,
            main: Bool,
            path: Set<String>
        ) -> UsageTreeRow {
            let childRows = childThreadIDs(parentThreadID: thread.threadId, parentTurnID: turn.turnId)
                .compactMap { buildThreadRow(threadID: $0, path: path) }
            let childUsage = TokenUsage.sum(childRows.map(\.subtreeUsage))
            let childCounts = UsageCounts.sum(childRows.map(\.counts))
            let childImageGenerations = childRows.flatMap(\.imageGenerations)
            let subtreeSegments = turn.segments + childRows.flatMap(\.segments)
            let childThreadRoots = childThreadIDs(
                parentThreadID: thread.threadId,
                parentTurnID: turn.turnId
            )
            let subtreeUsage = turn.usage + childUsage
            let rowAttribution: AttributionKind = main ? .direct : .direct
            return makeRow(
                id: "turn:\(thread.threadId):\(turn.turnId)",
                kind: main ? .mainTurn : .agentTurn,
                time: turn.effectiveStart,
                endTime: turn.effectiveEnd,
                name: main ? "主对话 \(ordinal + 1)" : "代理轮次 \(ordinal + 1)",
                ownUsage: turn.usage,
                subtreeUsage: subtreeUsage,
                counts: turn.counts + childCounts,
                imageGenerations: imageGenerations(
                    threadID: thread.threadId,
                    turnID: turn.turnId
                ) + childImageGenerations,
                segments: subtreeSegments,
                ownSegments: turn.segments,
                ownUsageSamples: ownSamples(
                    threadID: thread.threadId,
                    turnID: turn.turnId,
                    expected: turn.usage
                ),
                subtreeUsageSamples: subtreeSamples(
                    threadID: thread.threadId,
                    turnID: turn.turnId,
                    descendantRoots: childThreadRoots,
                    expected: subtreeUsage
                ),
                usageSampleFallbackTime: report.generatedAt,
                attribution: rowAttribution,
                pricingSuppressed: pricingSuppressed,
                isProvisional: turn.completedAt == nil && !turn.aborted,
                warnings: turn.aborted ? ["该轮已中止"] : [],
                children: childRows
            )
        }

        func buildThreadRow(threadID: String, path: Set<String>) -> UsageTreeRow? {
            guard let thread = threadByID[threadID], threadID != report.rootThreadId else { return nil }
            guard !path.contains(threadID) else {
                attributionWarnings.append("检测到子对话循环 \(shortID(threadID))，循环边已忽略。")
                return nil
            }
            guard renderedThreadIDs.insert(threadID).inserted else { return nil }

            var nextPath = path
            nextPath.insert(threadID)
            let turns = orderedTurns(thread)
            var turnRows = turns.enumerated().map { index, turn in
                buildTurnRow(thread: thread, turn: turn, ordinal: index, main: false, path: nextPath)
            }

            let turnUsage = TokenUsage.sum(turns.map(\.usage))
            let turnCounts = UsageCounts.sum(turns.map(\.counts))
            var localWarnings = thread.warnings
            let residualUsage = thread.usage.subtracting(turnUsage)
            let residualCounts = thread.counts.subtracting(turnCounts)
            if let residualUsage, let residualCounts, !residualUsage.isZero || !residualCounts.isZero {
                turnRows.append(
                    makeRow(
                        id: "residual:\(threadID)",
                        kind: .residual,
                        time: interval(for: thread)?.end,
                        endTime: interval(for: thread)?.end,
                        name: "线程内未归属用量",
                        ownUsage: residualUsage,
                        subtreeUsage: residualUsage,
                        counts: residualCounts,
                        imageGenerations: unmatchedImageGenerations(thread: thread),
                        segments: [],
                        ownSegments: [],
                        ownUsageSamples: residualSamples(thread: thread, expected: residualUsage),
                        subtreeUsageSamples: residualSamples(thread: thread, expected: residualUsage),
                        usageSampleFallbackTime: report.generatedAt,
                        attribution: .unattributed,
                        pricingSuppressed: pricingSuppressed,
                        warnings: ["该用量无法归到具体代理轮次"]
                    )
                )
            } else if residualUsage == nil || residualCounts == nil {
                localWarnings.append("线程与轮次用量无法对账")
            }

            let descendantRows = turnRows.flatMap { $0.children ?? [] }
            let descendantUsage = TokenUsage.sum(descendantRows.map(\.subtreeUsage))
            let descendantCounts = UsageCounts.sum(descendantRows.map(\.counts))
            let descendantImageGenerations = descendantRows.flatMap(\.imageGenerations)
            let descendantSegments = descendantRows.flatMap(\.segments)
            let directChildThreadIDs = ownerByChild.compactMap { childID, owner in
                owner.parentThreadID == threadID ? childID : nil
            }
            let subtreeUsage = thread.usage + descendantUsage
            let owner = ownerByChild[threadID]
            let attribution = owner?.attribution ?? .unattributed
            let labelPrefix = attribution == .unattributed ? "侧边对话" : "子对话"

            return makeRow(
                id: "thread:\(threadID)",
                kind: .agentThread,
                time: interval(for: thread)?.start,
                endTime: interval(for: thread)?.end,
                name: "\(labelPrefix) · \(threadLabel(thread))",
                ownUsage: thread.usage,
                subtreeUsage: subtreeUsage,
                counts: thread.counts + descendantCounts,
                imageGenerations: ownThreadImageGenerations(threadID: threadID)
                    + descendantImageGenerations,
                segments: thread.segments + descendantSegments,
                ownSegments: thread.segments,
                ownUsageSamples: ownSamples(threadID: threadID, expected: thread.usage),
                subtreeUsageSamples: subtreeSamples(
                    threadID: threadID,
                    descendantRoots: directChildThreadIDs,
                    expected: subtreeUsage
                ),
                usageSampleFallbackTime: report.generatedAt,
                attribution: attribution,
                pricingSuppressed: pricingSuppressed,
                isProvisional: thread.activeTurnCount > 0,
                isLowerBound: thread.exclusiveUsageAvailable == false,
                warnings: localWarnings,
                children: turnRows
            )
        }

        var rootTurnRows: [UsageTreeRow] = []
        if let root {
            rootTurnRows = orderedTurns(root).enumerated().map { index, turn in
                buildTurnRow(thread: root, turn: turn, ordinal: index, main: true, path: [root.threadId])
            }

            let rootTurnUsage = TokenUsage.sum(root.turns.map(\.usage))
            let rootTurnCounts = UsageCounts.sum(root.turns.map(\.counts))
            let residualUsage = root.usage.subtracting(rootTurnUsage)
            let residualCounts = root.counts.subtracting(rootTurnCounts)
            if let residualUsage, let residualCounts, !residualUsage.isZero || !residualCounts.isZero {
                rootTurnRows.append(
                    makeRow(
                        id: "residual:\(root.threadId)",
                        kind: .residual,
                        time: interval(for: root)?.end,
                        endTime: interval(for: root)?.end,
                        name: "主线程未归属用量",
                        ownUsage: residualUsage,
                        subtreeUsage: residualUsage,
                        counts: residualCounts,
                        imageGenerations: unmatchedImageGenerations(thread: root),
                        segments: [],
                        ownSegments: [],
                        ownUsageSamples: residualSamples(thread: root, expected: residualUsage),
                        subtreeUsageSamples: residualSamples(thread: root, expected: residualUsage),
                        usageSampleFallbackTime: report.generatedAt,
                        attribution: .unattributed,
                        pricingSuppressed: pricingSuppressed,
                        warnings: ["该用量无法归到具体主对话"]
                    )
                )
            } else if residualUsage == nil || residualCounts == nil {
                attributionWarnings.append("主线程与轮次用量无法对账")
            }
        }

        var sideRows: [UsageTreeRow] = []
        var remaining = Set(threadByID.keys.filter { $0 != report.rootThreadId && !renderedThreadIDs.contains($0) })
        while let nextID = sideRoot(in: remaining, ownerByChild: ownerByChild) {
            if let row = buildThreadRow(threadID: nextID, path: []) {
                sideRows.append(row)
            } else {
                renderedThreadIDs.insert(nextID)
            }
            remaining = Set(remaining.filter { !renderedThreadIDs.contains($0) })
        }
        if !sideRows.isEmpty {
            let sideUsage = TokenUsage.sum(sideRows.map(\.subtreeUsage))
            let sideCounts = UsageCounts.sum(sideRows.map(\.counts))
            let sideImageGenerations = sideRows.flatMap(\.imageGenerations)
            let sideSegments = sideRows.flatMap(\.segments)
            let sideSamples: [UsageSample]? = sideRows.allSatisfy { $0.subtreeUsageSamples != nil }
                ? reconciledSamples(
                    sideRows.flatMap { $0.subtreeUsageSamples ?? [] },
                    expected: sideUsage
                )
                : nil
            rootTurnRows.append(
                makeRow(
                    id: "side-group:\(report.rootThreadId)",
                    kind: .sideGroup,
                    time: sideRows.compactMap(\.time).min(),
                    endTime: sideRows.compactMap(\.endTime).max(),
                    name: "侧边 / 无法唯一归属的对话",
                    ownUsage: .zero,
                    subtreeUsage: sideUsage,
                    counts: sideCounts,
                    imageGenerations: sideImageGenerations,
                    segments: sideSegments,
                    ownSegments: [],
                    ownUsageSamples: taskSamples == nil ? nil : [],
                    subtreeUsageSamples: sideSamples,
                    usageSampleFallbackTime: report.generatedAt,
                    attribution: .unattributed,
                    pricingSuppressed: pricingSuppressed,
                    warnings: ["这些对话没有唯一的主轮次归属"],
                    children: sideRows
                )
            )
        }

        var sessionWarnings = report.warnings + attributionWarnings + (report.task.cost.warnings ?? [])
        if pricingSuppressed, !containsPricingSuppressionReason(sessionWarnings) {
            // `cost_suppressed` is authoritative even if an older producer did
            // not include its human-readable reason. Keep a canonical marker
            // so unavailable-price tooltips can distinguish validation
            // suppression from a catalog coverage gap.
            sessionWarnings.append("token counter invariants failed; price estimates were suppressed")
        }
        let threadTotal = TokenUsage.sum(report.threads.map(\.usage))
        if threadTotal != report.task.usage {
            sessionWarnings.append("任务汇总与线程独占用量之和不一致；表格以任务汇总为准。")
        }
        let threadIntervals = report.threads.compactMap(interval(for:))
        let sampleTimes = report.task.usageSamples?.compactMap(\.minute) ?? []
        let segmentStarts = report.task.segments.compactMap { $0.firstAt ?? $0.lastAt }
        let segmentEnds = report.task.segments.compactMap { $0.lastAt ?? $0.firstAt }
        let sessionStart: Date
        let sessionEnd: Date
        let observedStarts = threadIntervals.map(\.start) + sampleTimes + segmentStarts
        let observedEnds = threadIntervals.map(\.end) + sampleTimes + segmentEnds
        if let start = observedStarts.min(), let end = observedEnds.max() {
            sessionStart = start
            sessionEnd = max(start, end)
        } else {
            sessionStart = report.generatedAt
            sessionEnd = report.generatedAt
        }
        let pricingSegments = sessionPricingSegments(for: report.task)
        let estimatedCredit = estimator.estimate(
            pricingSegments,
            expectedTotalTokens: report.task.usage.totalTokens
        )
        let estimatedAPIPrice = estimator.estimateAPI(
            pricingSegments,
            expectedTotalTokens: report.task.usage.totalTokens
        )
        let sessionCredit = pricingSuppressed
            ? nil
            : estimateWithLegacyFallback(
                estimatedCredit,
                fallback: sessionCreditEstimate(
                    report.task.cost,
                    totalTokens: report.task.usage.totalTokens
                )
            )
        let sessionAPIPrice = pricingSuppressed
            ? nil
            : estimateWithLegacyFallback(
                estimatedAPIPrice,
                fallback: sessionAPIPriceEstimate(
                    report.task.cost,
                    totalTokens: report.task.usage.totalTokens
                )
            )

        return UsageTreeRow(
            id: "session:\(report.rootThreadId)",
            kind: .session,
            time: sessionStart,
            endTime: sessionEnd,
            name: title?.nonEmpty
                ?? report.displayName?.nonEmpty
                ?? "会话 \(shortID(report.rootThreadId))",
            projectName: projectName,
            projectPath: projectPath,
            ownUsage: report.task.rootUsage,
            subtreeUsage: report.task.usage,
            counts: report.task.counts,
            imageGenerations: reportImageGenerations,
            segments: report.task.segments,
            ownSegments: root?.segments ?? [],
            ownUsageSamples: ownSamples(
                threadID: report.rootThreadId,
                expected: report.task.rootUsage
            ),
            subtreeUsageSamples: report.task.usageSamples,
            usageSampleFallbackTime: report.generatedAt,
            modelSummary: estimator.modelSummary(for: report.task.segments),
            creditEstimate: sessionCredit,
            apiPriceEstimate: sessionAPIPrice,
            apiUSDText: report.task.cost.preferredAPIUSDText,
            attribution: .direct,
            isLowerBound: report.task.usageIsLowerBound,
            pricingSuppressed: pricingSuppressed,
            warnings: sessionWarnings,
            children: rootTurnRows
        )
    }

    private func makeRow(
        id: String,
        kind: UsageRowKind,
        time: Date?,
        endTime: Date? = nil,
        name: String,
        ownUsage: TokenUsage,
        subtreeUsage: TokenUsage,
        counts: UsageCounts,
        imageGenerations: [ImageGenerationDetail] = [],
        segments: [UsageSegment],
        ownSegments: [UsageSegment]? = nil,
        ownUsageSamples: [UsageSample]? = nil,
        subtreeUsageSamples: [UsageSample]? = nil,
        usageSampleFallbackTime: Date? = nil,
        attribution: AttributionKind,
        pricingSuppressed: Bool,
        isProvisional: Bool = false,
        isLowerBound: Bool = false,
        warnings: [String] = [],
        children: [UsageTreeRow] = []
    ) -> UsageTreeRow {
        UsageTreeRow(
            id: id,
            kind: kind,
            time: time,
            endTime: endTime,
            name: name,
            ownUsage: ownUsage,
            subtreeUsage: subtreeUsage,
            counts: counts,
            imageGenerations: imageGenerations,
            segments: segments,
            ownSegments: ownSegments,
            ownUsageSamples: ownUsageSamples,
            subtreeUsageSamples: subtreeUsageSamples,
            usageSampleFallbackTime: usageSampleFallbackTime,
            modelSummary: estimator.modelSummary(for: segments),
            creditEstimate: pricingSuppressed
                ? nil
                : estimator.estimate(segments, expectedTotalTokens: subtreeUsage.totalTokens),
            apiPriceEstimate: pricingSuppressed
                ? nil
                : estimator.estimateAPI(segments, expectedTotalTokens: subtreeUsage.totalTokens),
            attribution: attribution,
            isProvisional: isProvisional,
            isLowerBound: isLowerBound,
            pricingSuppressed: pricingSuppressed,
            warnings: warnings,
            children: children
        )
    }

    private func orderedTurns(_ thread: ThreadSummary) -> [TurnSummary] {
        let byID = Dictionary(thread.turns.map { ($0.turnId, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var result: [TurnSummary] = []
        for turnID in thread.ownedTurnIds {
            if let turn = byID[turnID], seen.insert(turnID).inserted { result.append(turn) }
        }
        let extras = thread.turns
            .filter { !seen.contains($0.turnId) }
            .sorted { ($0.effectiveStart ?? .distantPast) < ($1.effectiveStart ?? .distantPast) }
        result.append(contentsOf: extras)
        return result
    }

    private func interval(for turn: TurnSummary) -> DateInterval? {
        guard let start = turn.effectiveStart else { return nil }
        let end = max(turn.effectiveEnd ?? start, start)
        return DateInterval(start: start, end: end)
    }

    private func interval(for thread: ThreadSummary) -> DateInterval? {
        let intervals = thread.turns.compactMap(interval(for:))
        guard let start = intervals.map(\.start).min(), let end = intervals.map(\.end).max() else { return nil }
        return DateInterval(start: start, end: max(start, end))
    }

    private func intervalsOverlap(_ lhs: DateInterval, _ rhs: DateInterval) -> Bool {
        lhs.start <= rhs.end.addingTimeInterval(2) && rhs.start <= lhs.end.addingTimeInterval(2)
    }

    private func sideRoot(in remaining: Set<String>, ownerByChild: [String: Owner]) -> String? {
        let roots = remaining.filter { id in
            guard let owner = ownerByChild[id] else { return true }
            return !remaining.contains(owner.parentThreadID)
        }
        return roots.sorted().first ?? remaining.sorted().first
    }

    private func threadLabel(_ thread: ThreadSummary) -> String {
        if let agentPath = thread.agentPath?.nonEmpty {
            return URL(fileURLWithPath: agentPath).lastPathComponent.nonEmpty ?? agentPath
        }
        if let source = thread.threadSource?.nonEmpty { return source }
        return shortID(thread.threadId)
    }

    private func shortID(_ value: String) -> String {
        String(value.prefix(8))
    }

    private func containsPricingSuppressionReason(_ warnings: [String]) -> Bool {
        warnings.contains { warning in
            let normalized = warning.lowercased()
            return normalized.contains("price estimates were suppressed")
                || normalized.contains("token counter invariants failed")
        }
    }

    /// New reports expose the same minute accounting plane used by the trend
    /// view. Pricing the session from those buckets makes tier selection and
    /// partial coverage additive and directly comparable across both views.
    private func sessionPricingSegments(for task: TaskSummary) -> [UsageSegment] {
        guard let samples = task.usageSamples else { return task.segments }
        return samples.map { sample in
            UsageSegment(
                model: sample.model,
                effort: sample.effort,
                tier: sample.tier,
                tierSource: sample.tierSource,
                taskEpoch: sample.taskEpoch,
                longContext: sample.longContext,
                usage: sample.usage,
                firstAt: sample.minute,
                lastAt: sample.minute,
                requestCount: sample.requestCount
            )
        }
    }

    private func slicePlane(
        samples: [UsageSample]?,
        segments: [UsageSegment],
        fallbackUsage: TokenUsage,
        fallbackTime: Date?,
        lower: Date,
        upperExclusive: Date
    ) -> SlicedUsagePlane {
        if let samples {
            let selected = samples.filter { sample in
                guard let at = sample.minute ?? fallbackTime else { return false }
                return at >= lower && at < upperExclusive
            }
            return SlicedUsagePlane(
                usage: TokenUsage.sum(selected.map(\.usage)),
                segments: selected.map(segment(for:)),
                samples: selected,
                approximate: samples.contains { $0.minute == nil }
            )
        }

        if !segments.isEmpty {
            let selected = segments.filter { segment in
                guard let at = segment.lastAt ?? segment.firstAt ?? fallbackTime else { return false }
                return at >= lower && at < upperExclusive
            }
            return SlicedUsagePlane(
                usage: TokenUsage.sum(selected.map(\.usage)),
                segments: selected,
                samples: nil,
                approximate: true
            )
        }

        guard
            !fallbackUsage.isZero,
            let fallbackTime,
            fallbackTime >= lower,
            fallbackTime < upperExclusive
        else {
            return SlicedUsagePlane(usage: .zero, segments: [], samples: nil, approximate: true)
        }
        return SlicedUsagePlane(
            usage: fallbackUsage,
            segments: [
                UsageSegment(
                    model: nil,
                    effort: nil,
                    tier: nil,
                    tierSource: nil,
                    taskEpoch: nil,
                    longContext: nil,
                    usage: fallbackUsage,
                    firstAt: fallbackTime,
                    lastAt: fallbackTime,
                    requestCount: nil
                )
            ],
            samples: nil,
            approximate: true
        )
    }

    private func segment(for sample: UsageSample) -> UsageSegment {
        UsageSegment(
            model: sample.model,
            effort: sample.effort,
            tier: sample.tier,
            tierSource: sample.tierSource,
            taskEpoch: sample.taskEpoch,
            longContext: sample.longContext,
            usage: sample.usage,
            firstAt: sample.minute,
            lastAt: sample.minute,
            requestCount: sample.requestCount
        )
    }

    /// Embedded report prices remain a compatibility fallback for legacy
    /// reports whose model cannot be priced by the reader's catalog. As soon as
    /// any current-catalog subtotal is available, keep that internally
    /// consistent partial result instead of replacing it with an older basis.
    private func estimateWithLegacyFallback(
        _ estimate: CreditEstimate,
        fallback: @autoclosure () -> CreditEstimate?
    ) -> CreditEstimate? {
        estimate.amount == nil ? fallback() : estimate
    }

    private func estimateWithLegacyFallback(
        _ estimate: APIPriceEstimate,
        fallback: @autoclosure () -> APIPriceEstimate?
    ) -> APIPriceEstimate? {
        estimate.amount == nil ? fallback() : estimate
    }

    private func sessionCreditEstimate(_ cost: CostSummary, totalTokens: Int64) -> CreditEstimate? {
        let configured = decimal(cost.codexCreditsConfiguredTierEstimate)
        let standard = decimal(cost.codexCreditsStandardEquivalent)
        let configuredSubtotal = decimal(cost.codexCreditsConfiguredTierPricedSubtotal)
        let standardSubtotal = decimal(cost.codexCreditsStandardPricedSubtotal)
        if let configured {
            return CreditEstimate(amount: configured, basis: .configured, pricedTokens: totalTokens, totalTokens: totalTokens)
        }
        if let standard {
            return CreditEstimate(amount: standard, basis: .standard, pricedTokens: totalTokens, totalTokens: totalTokens)
        }
        let configuredPricedTokens = cost.creditConfiguredPricedTokens ?? 0
        let standardPricedTokens = cost.creditStandardPricedTokens ?? 0
        if
            let configuredSubtotal,
            standardSubtotal == nil || configuredPricedTokens >= standardPricedTokens
        {
            return CreditEstimate(
                amount: configuredSubtotal,
                basis: .configured,
                pricedTokens: configuredPricedTokens,
                totalTokens: totalTokens
            )
        }
        if let standardSubtotal {
            return CreditEstimate(
                amount: standardSubtotal,
                basis: .standard,
                pricedTokens: standardPricedTokens,
                totalTokens: totalTokens
            )
        }
        if let configuredSubtotal {
            return CreditEstimate(
                amount: configuredSubtotal,
                basis: .configured,
                pricedTokens: configuredPricedTokens,
                totalTokens: totalTokens
            )
        }
        return nil
    }

    private func sessionAPIPriceEstimate(_ cost: CostSummary, totalTokens: Int64) -> APIPriceEstimate? {
        let configured = decimal(cost.apiUsdConfiguredTierEstimate)
        let standard = decimal(cost.apiUsdStandardEquivalent)
        let configuredSubtotal = decimal(cost.apiUsdConfiguredTierPricedSubtotal)
        let standardSubtotal = decimal(cost.apiUsdStandardPricedSubtotal)
        if let configured {
            return APIPriceEstimate(
                amount: configured,
                basis: .configured,
                pricedTokens: totalTokens,
                totalTokens: totalTokens
            )
        }
        if let standard {
            return APIPriceEstimate(
                amount: standard,
                basis: .standard,
                pricedTokens: totalTokens,
                totalTokens: totalTokens
            )
        }
        let configuredPricedTokens = cost.apiConfiguredPricedTokens ?? 0
        let standardPricedTokens = cost.apiStandardPricedTokens ?? 0
        if
            let configuredSubtotal,
            standardSubtotal == nil || configuredPricedTokens >= standardPricedTokens
        {
            return APIPriceEstimate(
                amount: configuredSubtotal,
                basis: .configured,
                pricedTokens: configuredPricedTokens,
                totalTokens: totalTokens
            )
        }
        if let standardSubtotal {
            return APIPriceEstimate(
                amount: standardSubtotal,
                basis: .standard,
                pricedTokens: standardPricedTokens,
                totalTokens: totalTokens
            )
        }
        if let configuredSubtotal {
            return APIPriceEstimate(
                amount: configuredSubtotal,
                basis: .configured,
                pricedTokens: configuredPricedTokens,
                totalTokens: totalTokens
            )
        }
        return nil
    }

    private func decimal(_ value: String?) -> Decimal? {
        guard let value else { return nil }
        return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func aggregateCredits(
        _ sessions: [UsageTreeRow],
        totalTokens: Int64
    ) -> CreditEstimate? {
        var amount = Decimal.zero
        var pricedTokens: Int64 = 0
        var bases = Set<CreditEstimateBasis>()
        var foundAmount = false

        for session in sessions {
            guard let estimate = session.creditEstimate, let value = estimate.amount else { continue }
            foundAmount = true
            amount += value
            bases.insert(estimate.basis)
            let rowPriced = min(max(estimate.pricedTokens, 0), session.subtreeUsage.totalTokens)
            pricedTokens = saturatedAdd(pricedTokens, rowPriced)
        }
        guard foundAmount else { return nil }
        let basis = bases.count == 1 ? bases.first! : .mixed
        return CreditEstimate(
            amount: amount,
            basis: basis,
            pricedTokens: min(pricedTokens, totalTokens),
            totalTokens: totalTokens
        )
    }

    private func aggregateAPIPrices(
        _ sessions: [UsageTreeRow],
        totalTokens: Int64
    ) -> APIPriceEstimate? {
        var amount = Decimal.zero
        var pricedTokens: Int64 = 0
        var bases = Set<APIPriceEstimateBasis>()
        var foundAmount = false

        for session in sessions {
            guard let estimate = session.apiPriceEstimate, let value = estimate.amount else { continue }
            foundAmount = true
            amount += value
            bases.insert(estimate.basis)
            let rowPriced = min(max(estimate.pricedTokens, 0), session.subtreeUsage.totalTokens)
            pricedTokens = saturatedAdd(pricedTokens, rowPriced)
        }
        guard foundAmount else { return nil }
        let basis = bases.count == 1 ? bases.first! : .mixed
        return APIPriceEstimate(
            amount: amount,
            basis: basis,
            pricedTokens: min(pricedTokens, totalTokens),
            totalTokens: totalTokens
        )
    }

    private func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }
}

private struct Owner: Hashable {
    let parentThreadID: String
    let parentTurnID: String
    let attribution: AttributionKind
}

private struct SlicedUsagePlane {
    let usage: TokenUsage
    let segments: [UsageSegment]
    let samples: [UsageSample]?
    let approximate: Bool
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
