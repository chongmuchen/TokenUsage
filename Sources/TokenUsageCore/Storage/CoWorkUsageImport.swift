import Foundation

/// A privacy-safe CoWork App Server usage record converted into the same
/// accounting plane as native Codex reports.
public struct ImportedCoWorkUsageReport: Sendable {
    public let recordID: UUID
    public let title: String
    public let report: UsageReport

    public init(recordID: UUID, title: String, report: UsageReport) {
        self.recordID = recordID
        self.title = title
        self.report = report
    }
}

public struct CoWorkUsageImportLoadResult: Sendable {
    public let reports: [ImportedCoWorkUsageReport]
    public let issues: [ReportLoadIssue]
    public let directoryExists: Bool

    public init(
        reports: [ImportedCoWorkUsageReport],
        issues: [ReportLoadIssue],
        directoryExists: Bool
    ) {
        self.reports = reports
        self.issues = issues
        self.directoryExists = directoryExists
    }
}

public enum CoWorkUsageImportError: LocalizedError {
    case invalidDirectory(String)
    case invalidFile(String)
    case unsupportedSchema(Int)
    case invalidProducer(String)
    case malformedRecord(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory(let reason):
            "CoWork 用量目录不可用：\(reason)"
        case .invalidFile(let reason):
            "CoWork 用量文件无效：\(reason)"
        case .unsupportedSchema(let version):
            "不支持 CoWork 用量格式 v\(version)。"
        case .invalidProducer(let producer):
            "未知 CoWork 用量来源：\(producer)"
        case .malformedRecord(let reason):
            "CoWork 用量记录无法对账：\(reason)"
        }
    }
}

/// Reads only the deliberately content-free exchange directory. It never
/// opens CoWork's SwiftData database, auth files, prompts, images or traces.
public actor CoWorkUsageImportRepository {
    public static let maximumExchangeBytes: Int64 = 8 * 1024 * 1024
    public static let maximumExchangeFiles = 50_000
    public static let producer = "com.marscmchen.CoWork"

    private let catalog: PricingCatalog?

    public init(catalog: PricingCatalog? = nil) {
        self.catalog = catalog ?? (try? PricingCatalog.bundled())
    }

    public static func importsDirectory(for codexRoot: URL) -> URL {
        codexRoot.standardizedFileURL
            .appendingPathComponent("token-usage", isDirectory: true)
            .appendingPathComponent("imports", isDirectory: true)
            .appendingPathComponent("cowork", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    public func load(from codexRoot: URL) throws -> CoWorkUsageImportLoadResult {
        guard let directory = try validatedImportsDirectory(for: codexRoot) else {
            return CoWorkUsageImportLoadResult(reports: [], issues: [], directoryExists: false)
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .nameKey
        ]
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }
        guard files.count <= Self.maximumExchangeFiles else {
            throw CoWorkUsageImportError.invalidDirectory("文件数超过安全上限")
        }

        var winners: [UUID: ImportedCoWorkUsageReport] = [:]
        var issues: [ReportLoadIssue] = []
        for file in files {
            do {
                let imported = try decode(file, inside: directory)
                if let existing = winners[imported.recordID] {
                    if imported.report.generatedAt > existing.report.generatedAt {
                        winners[imported.recordID] = imported
                    }
                    issues.append(ReportLoadIssue(
                        fileName: file.lastPathComponent,
                        message: "重复 record_id；仅采用 generated_at 最新的记录"
                    ))
                } else {
                    winners[imported.recordID] = imported
                }
            } catch {
                issues.append(ReportLoadIssue(
                    fileName: file.lastPathComponent,
                    message: error.localizedDescription
                ))
            }
        }
        let reports = winners.values.sorted { $0.report.generatedAt > $1.report.generatedAt }
        return CoWorkUsageImportLoadResult(
            reports: reports,
            issues: issues,
            directoryExists: true
        )
    }

    private func validatedImportsDirectory(for codexRoot: URL) throws -> URL? {
        let root = codexRoot.standardizedFileURL.resolvingSymlinksInPath()
        var current = root
        for component in ["token-usage", "imports", "cowork", "v1"] {
            current.appendPathComponent(component, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory) else {
                return nil
            }
            let values = try current.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            guard isDirectory.boolValue,
                  values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw CoWorkUsageImportError.invalidDirectory(
                    "拒绝非目录或符号链接路径组件：\(component)"
                )
            }
        }

        let standardized = current.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath()
        let rootPath = root.path(percentEncoded: false)
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let resolvedPath = resolved.path(percentEncoded: false)
        guard resolvedPath.hasPrefix(rootPrefix),
              resolvedPath == standardized.path(percentEncoded: false) else {
            throw CoWorkUsageImportError.invalidDirectory("解析后的目录越出 Codex Home")
        }
        return standardized
    }

    private func decode(
        _ file: URL,
        inside directory: URL
    ) throws -> ImportedCoWorkUsageReport {
        let standardizedFile = file.standardizedFileURL
        guard standardizedFile.deletingLastPathComponent() == directory.standardizedFileURL else {
            throw CoWorkUsageImportError.invalidFile("文件越出 CoWork 用量目录")
        }
        let values = try file.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CoWorkUsageImportError.invalidFile("不是普通文件或是符号链接")
        }
        guard Int64(values.fileSize ?? 0) <= Self.maximumExchangeBytes else {
            throw CoWorkUsageImportError.invalidFile("超过 8 MiB 安全上限")
        }
        guard let fileRecordID = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
            throw CoWorkUsageImportError.invalidFile("文件名必须是 record UUID")
        }

        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
        let exchange = try Self.decoder.decode(CoWorkUsageExchange.self, from: data)
        guard exchange.schemaVersion == 1 else {
            throw CoWorkUsageImportError.unsupportedSchema(exchange.schemaVersion)
        }
        guard exchange.producer == Self.producer else {
            throw CoWorkUsageImportError.invalidProducer(exchange.producer)
        }
        guard exchange.recordId == fileRecordID else {
            throw CoWorkUsageImportError.invalidFile("文件名与 record_id 不一致")
        }
        try validate(exchange)
        return try makeImportedReport(exchange)
    }

    private func validate(_ exchange: CoWorkUsageExchange) throws {
        guard exchange.usage.isValid,
              exchange.samples.allSatisfy({ $0.usage.isValid }) else {
            throw CoWorkUsageImportError.malformedRecord("Token 字段为负、子集关系错误或 total 不等于 input + output")
        }
        guard !exchange.session.id.isEmpty, exchange.session.id.count <= 256 else {
            throw CoWorkUsageImportError.malformedRecord("session.id 缺失或过长")
        }
        try validateText(exchange.session.id, label: "session.id", maximum: 256, allowEmpty: false)
        try validateText(exchange.session.title, label: "session.title", maximum: 512)
        try validateText(exchange.session.status, label: "session.status", maximum: 64, allowEmpty: false)
        guard exchange.samples.count <= 100_000 else {
            throw CoWorkUsageImportError.malformedRecord("samples 数量超过安全上限")
        }
        guard Set(exchange.samples.map(\.id)).count == exchange.samples.count else {
            throw CoWorkUsageImportError.malformedRecord("sample id 重复")
        }
        let sum = try exactSum(exchange.samples.map(\.usage))
        guard sum == exchange.usage else {
            throw CoWorkUsageImportError.malformedRecord("samples 之和不等于累计 usage")
        }
        guard exchange.counts.imageGenerations >= 0 else {
            throw CoWorkUsageImportError.malformedRecord("image_generations 不能为负数")
        }
        guard exchange.warnings.count <= 1_024,
              exchange.completeness.count <= 128 else {
            throw CoWorkUsageImportError.malformedRecord("warnings 或 completeness 数量超过安全上限")
        }
        for (key, value) in exchange.completeness {
            try validateText(key, label: "completeness key", maximum: 128, allowEmpty: false)
            try validateText(value, label: "completeness value", maximum: 256)
        }
        for warning in exchange.warnings {
            try validateText(warning, label: "warning", maximum: 2_048)
        }
        if let billing = exchange.billing {
            guard billing.estimatedUsageCreditsMicros >= 0,
                  billing.estimatedUsageUsdMicros.map({ $0 >= 0 }) ?? true,
                  billing.groups.count <= 10_000,
                  billing.groups.allSatisfy(\.isValid) else {
                throw CoWorkUsageImportError.malformedRecord("billing 字段为负、过多或不完整")
            }
        }
        for sample in exchange.samples {
            try validateText(sample.id, label: "sample.id", maximum: 256, allowEmpty: false)
            try validateText(sample.model, label: "model", maximum: 128)
            try validateText(sample.effort, label: "effort", maximum: 64)
            try validateText(sample.tier, label: "tier", maximum: 64)
            try validateText(sample.tierSource, label: "tier_source", maximum: 64)
            if let requestCount = sample.requestCount, requestCount < 0 {
                throw CoWorkUsageImportError.malformedRecord("request_count 不能为负数")
            }
        }
    }

    private func makeImportedReport(
        _ exchange: CoWorkUsageExchange
    ) throws -> ImportedCoWorkUsageReport {
        let rootID = "cowork:\(exchange.recordId.uuidString.lowercased())"
        let turnID = "cowork-turn:\(exchange.recordId.uuidString.lowercased())"
        let title = sanitizedTitle(exchange.session.title)
        let usage = exchange.usage.tokenUsage
        let counts = UsageCounts(imageGenerations: exchange.counts.imageGenerations)
        let samples = exchange.samples.map {
            UsageSample(
                minute: $0.occurredAt,
                model: normalized($0.model),
                effort: normalized($0.effort),
                tier: normalized($0.tier),
                tierSource: normalized($0.tierSource),
                taskEpoch: 0,
                longContext: resolvedLongContext(for: $0),
                usage: $0.usage.tokenUsage,
                requestCount: $0.requestCount
            )
        }
        let segments = makeSegments(from: samples)
        let finalStatuses = Set(["completed", "succeeded"])
        let lifecycleIsFinal = exchange.session.endedAt != nil
            && finalStatuses.contains(exchange.session.status.lowercased())
        let usageIsObserved = exchange.completeness["usage"] == "observed"
        let costIsSuppressed = exchange.completeness["cost_suppressed"] == "true"
            || exchange.completeness["cost"] == "suppressed"
            || !usageIsObserved
        let isFinal = lifecycleIsFinal && usageIsObserved
        let duration = durationMilliseconds(
            from: exchange.session.startedAt,
            to: exchange.session.endedAt
        )
        var importedWarnings = exchange.warnings.map(sanitizedWarning)
        let usableBilling: CoWorkExchangeBilling?
        if let billing = exchange.billing,
           billing.estimatedUsageCreditsMicros == 0,
           usage.totalTokens > 0 {
            usableBilling = nil
            importedWarnings.append(
                "非零 Token 对应的后端 Credits 暂为 0；按尚未结算处理，不显示为零成本。"
            )
        } else {
            usableBilling = exchange.billing
        }
        if usableBilling != nil {
            importedWarnings.append(
                "会话 Credits 优先采用 App Server 后端估值；每日趋势中的价格仍按 TokenUsage 公开价目录估算。"
            )
        }
        if !usageIsObserved {
            importedWarnings.append("累计 Token 曾出现异常；当前用量仅为已观测下界，价格已抑制。")
        }
        let warnings = uniqueWarnings(
            importedWarnings
                + ["CoWork App Server 用量只覆盖 Codex 控制回合；图片生成模型 Token 和图片费用未计入。"]
        )
        let cost = makeCost(
            segments: segments,
            totalTokens: usage.totalTokens,
            billing: usableBilling,
            suppressed: costIsSuppressed
        )
        let current = CurrentTurnSummary(
            available: !usage.isZero,
            usageIsProvisional: !isFinal,
            usage: usage,
            counts: counts,
            rootUsage: usage,
            agentsUsage: .zero,
            segments: segments,
            cost: cost,
            durationMs: duration,
            ttftMs: nil
        )
        let task = TaskSummary(
            usage: usage,
            counts: counts,
            rootUsage: usage,
            agentsUsage: .zero,
            segments: segments,
            usageSamples: samples,
            cost: cost,
            linkedAgentThreads: 0,
            usageIsLowerBound: !isFinal
        )
        let turn = TurnSummary(
            turnId: turnID,
            startedAt: exchange.session.startedAt,
            completedAt: exchange.session.endedAt,
            durationMs: duration,
            ttftMs: nil,
            model: singleValue(samples.compactMap(\.model)),
            effort: singleValue(samples.compactMap(\.effort)),
            tier: singleValue(samples.compactMap(\.tier)),
            tierSource: singleValue(samples.compactMap(\.tierSource)),
            usage: usage,
            segments: segments,
            counts: counts,
            agentThreadIds: [],
            aborted: !isFinal && exchange.session.endedAt != nil,
            firstUsageAt: exchange.samples.map(\.occurredAt).min(),
            lastUsageAt: exchange.samples.map(\.occurredAt).max()
        )
        let thread = ThreadSummary(
            threadId: rootID,
            parentThreadId: nil,
            forkedFromId: nil,
            threadSource: "cowork-app-server",
            agentPath: nil,
            cliVersion: nil,
            boundaryMethod: "app-server-total-delta",
            exclusiveUsageAvailable: true,
            usage: usage,
            rawCumulativeUsage: usage,
            inheritedPrefixUsage: .zero,
            inheritedPrefixCounts: .zero,
            counts: counts,
            ownedTurnIds: [turnID],
            turns: [turn],
            activeTurnCount: exchange.session.endedAt == nil ? 1 : 0,
            segments: segments,
            warnings: warnings,
            parseErrors: 0,
            unclassifiedCompactionTotal: 0
        )
        let catalogReference = PricingCatalogReference(
            catalogId: catalog?.catalogId,
            observedAt: catalog?.observedAt,
            scope: catalog?.scope
        )
        let report = UsageReport(
            reportSchemaVersion: 1,
            generatedAt: exchange.generatedAt,
            rootThreadId: rootID,
            selectedTurnId: turnID,
            currentTurn: current,
            task: task,
            threads: [thread],
            completeness: Completeness(
                textTokenBreakdown: "app-server-total-observed",
                imageTokenBreakdown: "unavailable",
                effectiveServiceTier: "thread-start-response-not-provider-confirmed",
                subscriptionDollars: "unavailable",
                subagentAttribution: "not-applicable",
                allAgentPerTurn: "not-applicable",
                snapshotConsistency: isFinal ? "final" : "provisional",
                usageSummary: isFinal ? "observed" : "lower-bound"
            ),
            warnings: warnings,
            pricingCatalog: catalogReference
        )
        return ImportedCoWorkUsageReport(
            recordID: exchange.recordId,
            title: title,
            report: report
        )
    }

    private func makeSegments(from samples: [UsageSample]) -> [UsageSegment] {
        struct Key: Hashable {
            let model: String?
            let effort: String?
            let tier: String?
            let tierSource: String?
            let longContext: Bool?
        }
        struct Value {
            var usage = TokenUsage.zero
            var firstAt: Date?
            var lastAt: Date?
            var requestCount: Int64?
        }

        var values: [Key: Value] = [:]
        for sample in samples {
            let key = Key(
                model: sample.model,
                effort: sample.effort,
                tier: sample.tier,
                tierSource: sample.tierSource,
                longContext: sample.longContext
            )
            var value = values[key] ?? Value()
            value.usage = value.usage + sample.usage
            value.firstAt = minDate(value.firstAt, sample.minute)
            value.lastAt = maxDate(value.lastAt, sample.minute)
            if let count = sample.requestCount {
                let prior = value.requestCount ?? 0
                let (next, overflow) = prior.addingReportingOverflow(count)
                value.requestCount = overflow ? nil : next
            }
            values[key] = value
        }
        return values.map { key, value in
            UsageSegment(
                model: key.model,
                effort: key.effort,
                tier: key.tier,
                tierSource: key.tierSource,
                taskEpoch: 0,
                longContext: key.longContext,
                usage: value.usage,
                firstAt: value.firstAt,
                lastAt: value.lastAt,
                requestCount: value.requestCount
            )
        }.sorted {
            ($0.firstAt ?? .distantPast, $0.model ?? "", $0.effort ?? "", $0.tier ?? "")
                < ($1.firstAt ?? .distantPast, $1.model ?? "", $1.effort ?? "", $1.tier ?? "")
        }
    }

    private func makeCost(
        segments: [UsageSegment],
        totalTokens: Int64,
        billing: CoWorkExchangeBilling?,
        suppressed: Bool
    ) -> CostSummary {
        if suppressed {
            return suppressedCost(
                totalTokens: totalTokens,
                warnings: ["累计 Token 无法完整对账，价格已抑制。"]
            )
        }
        guard let catalog else {
            return emptyCost(totalTokens: totalTokens, warnings: ["价格目录不可用。"])
        }
        let estimator = CreditEstimator(catalog: catalog)
        let credits = estimator.estimate(segments, expectedTotalTokens: totalTokens)
        let api = estimator.estimateAPI(segments, expectedTotalTokens: totalTokens)
        let creditText = credits.amount.map(decimalString)
        let apiText = api.amount.map(decimalString)
        let creditComplete = credits.pricedTokens == credits.totalTokens
        let apiComplete = api.pricedTokens == api.totalTokens
        let backendCreditText = billing.map {
            decimalString(Decimal($0.estimatedUsageCreditsMicros) / Decimal(1_000_000))
        }
        let configuredCreditText = backendCreditText
            ?? (credits.basis == .configured && creditComplete ? creditText : nil)

        return CostSummary(
            catalogId: catalog.catalogId,
            catalogObservedAt: catalog.observedAt,
            codexCreditsStandardEquivalent: credits.basis == .standard && creditComplete ? creditText : nil,
            codexCreditsConfiguredTierEstimate: configuredCreditText,
            apiUsdStandardEquivalent: api.basis == .standard && apiComplete ? apiText : nil,
            apiUsdConfiguredTierEstimate: api.basis == .configured && apiComplete ? apiText : nil,
            codexCreditsStandardPricedSubtotal: credits.basis == .standard && !creditComplete ? creditText : nil,
            codexCreditsConfiguredTierPricedSubtotal: backendCreditText == nil
                && credits.basis == .configured && !creditComplete ? creditText : nil,
            apiUsdStandardPricedSubtotal: api.basis == .standard && !apiComplete ? apiText : nil,
            apiUsdConfiguredTierPricedSubtotal: api.basis == .configured && !apiComplete ? apiText : nil,
            creditStandardPricedTokens: credits.basis == .standard ? credits.pricedTokens : nil,
            creditConfiguredPricedTokens: backendCreditText == nil
                ? (credits.basis == .configured ? credits.pricedTokens : nil)
                : totalTokens,
            apiStandardPricedTokens: api.basis == .standard ? api.pricedTokens : nil,
            apiConfiguredPricedTokens: api.basis == .configured ? api.pricedTokens : nil,
            creditConfiguredUnpricedTokens: backendCreditText == nil
                ? (credits.basis == .configured ? max(totalTokens - credits.pricedTokens, 0) : totalTokens)
                : 0,
            apiConfiguredUnpricedTokens: api.basis == .configured
                ? max(totalTokens - api.pricedTokens, 0)
                : totalTokens,
            effectiveTierConfirmed: false,
            creditUnpricedTokens: max(totalTokens - credits.pricedTokens, 0),
            apiUnpricedTokens: max(totalTokens - api.pricedTokens, 0),
            costSuppressed: false,
            warnings: [
                backendCreditText == nil
                    ? "CoWork 档位来自 thread/start 响应，并非模型供应端最终计费确认。"
                    : "Credits 来自 App Server thread billing 后端估值；档位字段仍不是模型供应端响应确认。"
            ]
        )
    }

    private func suppressedCost(totalTokens: Int64, warnings: [String]) -> CostSummary {
        CostSummary(
            catalogId: catalog?.catalogId,
            catalogObservedAt: catalog?.observedAt,
            codexCreditsStandardEquivalent: nil,
            codexCreditsConfiguredTierEstimate: nil,
            apiUsdStandardEquivalent: nil,
            apiUsdConfiguredTierEstimate: nil,
            codexCreditsStandardPricedSubtotal: nil,
            codexCreditsConfiguredTierPricedSubtotal: nil,
            apiUsdStandardPricedSubtotal: nil,
            apiUsdConfiguredTierPricedSubtotal: nil,
            creditStandardPricedTokens: 0,
            creditConfiguredPricedTokens: 0,
            apiStandardPricedTokens: 0,
            apiConfiguredPricedTokens: 0,
            creditConfiguredUnpricedTokens: totalTokens,
            apiConfiguredUnpricedTokens: totalTokens,
            effectiveTierConfirmed: false,
            creditUnpricedTokens: totalTokens,
            apiUnpricedTokens: totalTokens,
            costSuppressed: true,
            warnings: warnings
        )
    }

    private func emptyCost(totalTokens: Int64, warnings: [String]) -> CostSummary {
        CostSummary(
            catalogId: nil,
            catalogObservedAt: nil,
            codexCreditsStandardEquivalent: nil,
            codexCreditsConfiguredTierEstimate: nil,
            apiUsdStandardEquivalent: nil,
            apiUsdConfiguredTierEstimate: nil,
            codexCreditsStandardPricedSubtotal: nil,
            codexCreditsConfiguredTierPricedSubtotal: nil,
            apiUsdStandardPricedSubtotal: nil,
            apiUsdConfiguredTierPricedSubtotal: nil,
            creditStandardPricedTokens: 0,
            creditConfiguredPricedTokens: 0,
            apiStandardPricedTokens: 0,
            apiConfiguredPricedTokens: 0,
            creditConfiguredUnpricedTokens: totalTokens,
            apiConfiguredUnpricedTokens: totalTokens,
            effectiveTierConfirmed: false,
            creditUnpricedTokens: totalTokens,
            apiUnpricedTokens: totalTokens,
            costSuppressed: false,
            warnings: warnings
        )
    }

    private func exactSum(_ vectors: [CoWorkUsageVector]) throws -> CoWorkUsageVector {
        var result = CoWorkUsageVector.zero
        for vector in vectors {
            guard let next = result.adding(vector) else {
                throw CoWorkUsageImportError.malformedRecord("Token 加总溢出")
            }
            result = next
        }
        return result
    }

    private func validateText(
        _ text: String?,
        label: String,
        maximum: Int,
        allowEmpty: Bool = true
    ) throws {
        guard let text else { return }
        if (!allowEmpty && text.isEmpty) || text.count > maximum || text.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) {
            throw CoWorkUsageImportError.malformedRecord("\(label) 含非法字符或过长")
        }
    }

    private func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Missing per-request metadata can still prove a request was short when
    /// the entire observed delta is no larger than the model's threshold. A
    /// larger aggregate remains unknown; it may contain several short calls.
    private func resolvedLongContext(for sample: CoWorkExchangeSample) -> Bool? {
        if let value = sample.longContext { return value }
        guard let api = catalog?.entry(for: normalized(sample.model))?.value.apiUsd else {
            return nil
        }
        let hasDistinctLongPrice = api.standard?.long != nil
            || api.fast?.long != nil
            || api.longContextRule != nil
            || api.longContextThresholdInputTokensExclusive != nil
        guard hasDistinctLongPrice else { return false }
        let threshold = api.longContextThresholdInputTokensExclusive
            ?? api.longContextRule?.thresholdInputTokensExclusive
        guard let threshold, sample.usage.inputTokens <= threshold else { return nil }
        return false
    }

    private func sanitizedTitle(_ text: String) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String((collapsed.isEmpty ? "CoWork" : collapsed).prefix(80))
    }

    private func sanitizedWarning(_ text: String) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(512))
    }

    private func uniqueWarnings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(64).map { $0 }
    }

    private func singleValue(_ values: [String]) -> String? {
        let unique = Set(values)
        return unique.count == 1 ? unique.first : nil
    }

    private func minDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (left?, right?): min(left, right)
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): nil
        }
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (left?, right?): max(left, right)
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): nil
        }
    }

    private func durationMilliseconds(from start: Date, to end: Date?) -> Int64? {
        guard let end, end >= start else { return nil }
        let milliseconds = (end.timeIntervalSince(start) * 1_000).rounded()
        guard milliseconds <= Double(Int64.max) else { return Int64.max }
        return Int64(milliseconds)
    }

    private func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let value = fractional.date(from: text) { return value }
            let ordinary = ISO8601DateFormatter()
            ordinary.formatOptions = [.withInternetDateTime]
            if let value = ordinary.date(from: text) { return value }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 timestamp: \(text)"
            )
        }
        return decoder
    }()
}

private struct CoWorkUsageExchange: Decodable {
    let schemaVersion: Int
    let producer: String
    let generatedAt: Date
    let recordId: UUID
    let session: CoWorkExchangeSession
    let usage: CoWorkUsageVector
    let samples: [CoWorkExchangeSample]
    let counts: CoWorkExchangeCounts
    let billing: CoWorkExchangeBilling?
    let completeness: [String: String]
    let warnings: [String]
}

private struct CoWorkExchangeSession: Decodable {
    let id: String
    let title: String
    let startedAt: Date
    let endedAt: Date?
    let status: String
}

private struct CoWorkExchangeSample: Decodable {
    let id: String
    let occurredAt: Date
    let model: String?
    let effort: String?
    let tier: String?
    let tierSource: String
    let longContext: Bool?
    let requestCount: Int64?
    let usage: CoWorkUsageVector
}

private struct CoWorkExchangeCounts: Decodable {
    let imageGenerations: Int64
}

private struct CoWorkExchangeBilling: Decodable {
    let estimatedUsageCreditsMicros: Int64
    let estimatedUsageUsdMicros: Int64?
    let groups: [CoWorkExchangeBillingGroup]
}

private struct CoWorkExchangeBillingGroup: Decodable {
    let model: String?
    let effort: String?
    let speed: String?
    let estimatedUsageCreditsMicros: Int64
    let netNewInputTokens: Int64?
    let cachedInputTokens: Int64?
    let inputTokens: Int64?
    let outputTokens: Int64?
    let totalTokens: Int64?

    var isValid: Bool {
        guard estimatedUsageCreditsMicros >= 0 else { return false }
        return [
            netNewInputTokens,
            cachedInputTokens,
            inputTokens,
            outputTokens,
            totalTokens
        ].compactMap { $0 }.allSatisfy { $0 >= 0 }
    }
}

private struct CoWorkUsageVector: Decodable, Equatable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let cacheWriteInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64

    static let zero = CoWorkUsageVector(
        inputTokens: 0,
        cachedInputTokens: 0,
        cacheWriteInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 0
    )

    var isValid: Bool {
        guard inputTokens >= 0,
              cachedInputTokens >= 0,
              cacheWriteInputTokens >= 0,
              outputTokens >= 0,
              reasoningOutputTokens >= 0,
              totalTokens >= 0,
              cachedInputTokens <= inputTokens,
              cacheWriteInputTokens <= inputTokens - cachedInputTokens,
              reasoningOutputTokens <= outputTokens else {
            return false
        }
        let (computed, overflow) = inputTokens.addingReportingOverflow(outputTokens)
        return !overflow && computed == totalTokens
    }

    var tokenUsage: TokenUsage {
        TokenUsage(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            totalTokens: totalTokens
        )
    }

    func adding(_ other: CoWorkUsageVector) -> CoWorkUsageVector? {
        func add(_ lhs: Int64, _ rhs: Int64) -> Int64? {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? nil : value
        }
        guard
            let input = add(inputTokens, other.inputTokens),
            let cached = add(cachedInputTokens, other.cachedInputTokens),
            let cacheWrite = add(cacheWriteInputTokens, other.cacheWriteInputTokens),
            let output = add(outputTokens, other.outputTokens),
            let reasoning = add(reasoningOutputTokens, other.reasoningOutputTokens),
            let total = add(totalTokens, other.totalTokens)
        else { return nil }
        return CoWorkUsageVector(
            inputTokens: input,
            cachedInputTokens: cached,
            cacheWriteInputTokens: cacheWrite,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: total
        )
    }
}
