import Foundation

@inline(__always)
private func addingWithoutTrap(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int64.max : result
}

public struct TokenUsage: Codable, Equatable, Hashable, Sendable {
    public let inputTokens: Int64
    public let cachedInputTokens: Int64
    public let cacheWriteInputTokens: Int64
    public let outputTokens: Int64
    public let reasoningOutputTokens: Int64
    public let totalTokens: Int64

    public init(
        inputTokens: Int64 = 0,
        cachedInputTokens: Int64 = 0,
        cacheWriteInputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        reasoningOutputTokens: Int64 = 0,
        totalTokens: Int64? = nil
    ) {
        self.inputTokens = max(inputTokens, 0)
        self.cachedInputTokens = max(cachedInputTokens, 0)
        self.cacheWriteInputTokens = max(cacheWriteInputTokens, 0)
        self.outputTokens = max(outputTokens, 0)
        self.reasoningOutputTokens = max(reasoningOutputTokens, 0)
        self.totalTokens = max(
            totalTokens ?? addingWithoutTrap(max(inputTokens, 0), max(outputTokens, 0)),
            0
        )
    }

    public static let zero = TokenUsage()

    public var ordinaryInputTokens: Int64 {
        guard inputTokens >= cachedInputTokens else { return 0 }
        let afterCacheRead = inputTokens - cachedInputTokens
        guard afterCacheRead >= cacheWriteInputTokens else { return 0 }
        return afterCacheRead - cacheWriteInputTokens
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: addingWithoutTrap(lhs.inputTokens, rhs.inputTokens),
            cachedInputTokens: addingWithoutTrap(lhs.cachedInputTokens, rhs.cachedInputTokens),
            cacheWriteInputTokens: addingWithoutTrap(lhs.cacheWriteInputTokens, rhs.cacheWriteInputTokens),
            outputTokens: addingWithoutTrap(lhs.outputTokens, rhs.outputTokens),
            reasoningOutputTokens: addingWithoutTrap(lhs.reasoningOutputTokens, rhs.reasoningOutputTokens)
        )
    }

    public static func sum<S: Sequence>(_ values: S) -> TokenUsage where S.Element == TokenUsage {
        values.reduce(.zero, +)
    }

    public var isZero: Bool { totalTokens == 0 }

    public func subtracting(_ other: TokenUsage) -> TokenUsage? {
        guard
            inputTokens >= other.inputTokens,
            cachedInputTokens >= other.cachedInputTokens,
            cacheWriteInputTokens >= other.cacheWriteInputTokens,
            outputTokens >= other.outputTokens,
            reasoningOutputTokens >= other.reasoningOutputTokens
        else { return nil }
        return TokenUsage(
            inputTokens: inputTokens - other.inputTokens,
            cachedInputTokens: cachedInputTokens - other.cachedInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens - other.cacheWriteInputTokens,
            outputTokens: outputTokens - other.outputTokens,
            reasoningOutputTokens: reasoningOutputTokens - other.reasoningOutputTokens
        )
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens
        case cachedInputTokens
        case cacheWriteInputTokens
        case outputTokens
        case reasoningOutputTokens
        case totalTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let input = try container.decode(Int64.self, forKey: .inputTokens)
        let cached = try container.decode(Int64.self, forKey: .cachedInputTokens)
        let cacheWrite = try container.decode(Int64.self, forKey: .cacheWriteInputTokens)
        let output = try container.decode(Int64.self, forKey: .outputTokens)
        let reasoning = try container.decode(Int64.self, forKey: .reasoningOutputTokens)
        let total = try container.decode(Int64.self, forKey: .totalTokens)

        guard input >= 0, cached >= 0, cacheWrite >= 0, output >= 0, reasoning >= 0, total >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .totalTokens,
                in: container,
                debugDescription: "Token counts must be nonnegative."
            )
        }
        guard cached <= input, cacheWrite <= input - cached else {
            throw DecodingError.dataCorruptedError(
                forKey: .cachedInputTokens,
                in: container,
                debugDescription: "Cached input counts exceed total input tokens."
            )
        }
        let (computedTotal, overflow) = input.addingReportingOverflow(output)
        guard !overflow, total == computedTotal else {
            throw DecodingError.dataCorruptedError(
                forKey: .totalTokens,
                in: container,
                debugDescription: "Total tokens must equal input plus output without overflow."
            )
        }
        self.init(
            inputTokens: input,
            cachedInputTokens: cached,
            cacheWriteInputTokens: cacheWrite,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: total
        )
    }
}

public struct UsageCounts: Codable, Equatable, Hashable, Sendable {
    public let imageInputs: Int64
    public let audioInputs: Int64
    public let imageGenerations: Int64
    public let webSearches: Int64
    public let mcpCalls: Int64
    public let toolCalls: Int64

    public init(
        imageInputs: Int64 = 0,
        audioInputs: Int64 = 0,
        imageGenerations: Int64 = 0,
        webSearches: Int64 = 0,
        mcpCalls: Int64 = 0,
        toolCalls: Int64 = 0
    ) {
        self.imageInputs = max(imageInputs, 0)
        self.audioInputs = max(audioInputs, 0)
        self.imageGenerations = max(imageGenerations, 0)
        self.webSearches = max(webSearches, 0)
        self.mcpCalls = max(mcpCalls, 0)
        self.toolCalls = max(toolCalls, 0)
    }

    public static let zero = UsageCounts()

    public var isZero: Bool {
        imageInputs == 0
            && audioInputs == 0
            && imageGenerations == 0
            && webSearches == 0
            && mcpCalls == 0
            && toolCalls == 0
    }

    public static func + (lhs: UsageCounts, rhs: UsageCounts) -> UsageCounts {
        UsageCounts(
            imageInputs: addingWithoutTrap(lhs.imageInputs, rhs.imageInputs),
            audioInputs: addingWithoutTrap(lhs.audioInputs, rhs.audioInputs),
            imageGenerations: addingWithoutTrap(lhs.imageGenerations, rhs.imageGenerations),
            webSearches: addingWithoutTrap(lhs.webSearches, rhs.webSearches),
            mcpCalls: addingWithoutTrap(lhs.mcpCalls, rhs.mcpCalls),
            toolCalls: addingWithoutTrap(lhs.toolCalls, rhs.toolCalls)
        )
    }

    public static func sum<S: Sequence>(_ values: S) -> UsageCounts where S.Element == UsageCounts {
        values.reduce(.zero, +)
    }

    public func subtracting(_ other: UsageCounts) -> UsageCounts? {
        guard
            imageInputs >= other.imageInputs,
            audioInputs >= other.audioInputs,
            imageGenerations >= other.imageGenerations,
            webSearches >= other.webSearches,
            mcpCalls >= other.mcpCalls,
            toolCalls >= other.toolCalls
        else { return nil }
        return UsageCounts(
            imageInputs: imageInputs - other.imageInputs,
            audioInputs: audioInputs - other.audioInputs,
            imageGenerations: imageGenerations - other.imageGenerations,
            webSearches: webSearches - other.webSearches,
            mcpCalls: mcpCalls - other.mcpCalls,
            toolCalls: toolCalls - other.toolCalls
        )
    }

    private enum CodingKeys: String, CodingKey {
        case imageInputs
        case audioInputs
        case imageGenerations
        case webSearches
        case mcpCalls
        case toolCalls
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let values = (
            imageInputs: try container.decode(Int64.self, forKey: .imageInputs),
            audioInputs: try container.decode(Int64.self, forKey: .audioInputs),
            imageGenerations: try container.decode(Int64.self, forKey: .imageGenerations),
            webSearches: try container.decode(Int64.self, forKey: .webSearches),
            mcpCalls: try container.decode(Int64.self, forKey: .mcpCalls),
            toolCalls: try container.decode(Int64.self, forKey: .toolCalls)
        )
        guard
            values.imageInputs >= 0,
            values.audioInputs >= 0,
            values.imageGenerations >= 0,
            values.webSearches >= 0,
            values.mcpCalls >= 0,
            values.toolCalls >= 0
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .toolCalls,
                in: container,
                debugDescription: "Usage counts must be nonnegative."
            )
        }
        self.init(
            imageInputs: values.imageInputs,
            audioInputs: values.audioInputs,
            imageGenerations: values.imageGenerations,
            webSearches: values.webSearches,
            mcpCalls: values.mcpCalls,
            toolCalls: values.toolCalls
        )
    }
}

public struct UsageSegment: Codable, Equatable, Hashable, Sendable {
    public let model: String?
    public let effort: String?
    public let tier: String?
    public let tierSource: String?
    public let taskEpoch: Int64?
    public let longContext: Bool?
    public let usage: TokenUsage
    public let firstAt: Date?
    public let lastAt: Date?
    public let requestCount: Int64?
}

public struct CostSummary: Codable, Equatable, Sendable {
    public let catalogId: String?
    public let catalogObservedAt: String?
    public let codexCreditsStandardEquivalent: String?
    public let codexCreditsConfiguredTierEstimate: String?
    public let apiUsdStandardEquivalent: String?
    public let apiUsdConfiguredTierEstimate: String?
    public let codexCreditsStandardPricedSubtotal: String?
    public let codexCreditsConfiguredTierPricedSubtotal: String?
    public let apiUsdStandardPricedSubtotal: String?
    public let apiUsdConfiguredTierPricedSubtotal: String?
    public let creditStandardPricedTokens: Int64?
    public let creditConfiguredPricedTokens: Int64?
    public let apiStandardPricedTokens: Int64?
    public let apiConfiguredPricedTokens: Int64?
    public let creditConfiguredUnpricedTokens: Int64?
    public let apiConfiguredUnpricedTokens: Int64?
    public let effectiveTierConfirmed: Bool?
    public let creditUnpricedTokens: Int64?
    public let apiUnpricedTokens: Int64?
    public let costSuppressed: Bool?
    public let warnings: [String]?

    public var preferredCreditsText: String? {
        if costSuppressed == true { return nil }
        return codexCreditsConfiguredTierEstimate
            ?? codexCreditsStandardEquivalent
            ?? codexCreditsConfiguredTierPricedSubtotal
            ?? codexCreditsStandardPricedSubtotal
    }

    public var preferredAPIUSDText: String? {
        if costSuppressed == true { return nil }
        return apiUsdConfiguredTierEstimate
            ?? apiUsdStandardEquivalent
            ?? apiUsdConfiguredTierPricedSubtotal
            ?? apiUsdStandardPricedSubtotal
    }
}

public struct CurrentTurnSummary: Codable, Equatable, Sendable {
    public let available: Bool
    public let usageIsProvisional: Bool
    public let usage: TokenUsage
    public let counts: UsageCounts
    public let rootUsage: TokenUsage
    public let agentsUsage: TokenUsage
    public let segments: [UsageSegment]
    public let cost: CostSummary
    public let durationMs: Int64?
    public let ttftMs: Int64?
}

public struct TaskSummary: Codable, Equatable, Sendable {
    public let usage: TokenUsage
    public let counts: UsageCounts
    public let rootUsage: TokenUsage
    public let agentsUsage: TokenUsage
    public let segments: [UsageSegment]
    /// Minute-resolution accounting emitted by newer v1 producers. `nil`
    /// means a legacy report; an empty array is a valid exact zero-usage plane.
    public let usageSamples: [UsageSample]?
    public let cost: CostSummary
    public let linkedAgentThreads: Int64
    public let usageIsLowerBound: Bool
}

public struct TurnSummary: Codable, Equatable, Identifiable, Sendable {
    public let turnId: String
    public let startedAt: Date?
    public let completedAt: Date?
    public let durationMs: Int64?
    public let ttftMs: Int64?
    public let model: String?
    public let effort: String?
    public let tier: String?
    public let tierSource: String?
    public let usage: TokenUsage
    public let segments: [UsageSegment]
    public let counts: UsageCounts
    public let agentThreadIds: [String]
    public let aborted: Bool
    public let firstUsageAt: Date?
    public let lastUsageAt: Date?

    public var id: String { turnId }
    public var effectiveStart: Date? { startedAt ?? firstUsageAt }
    public var effectiveEnd: Date? { completedAt ?? lastUsageAt ?? effectiveStart }
}

public struct ThreadSummary: Codable, Equatable, Identifiable, Sendable {
    public let threadId: String
    public let parentThreadId: String?
    public let forkedFromId: String?
    public let threadSource: String?
    public let agentPath: String?
    public let cliVersion: String?
    public let boundaryMethod: String?
    public let exclusiveUsageAvailable: Bool?
    public let usage: TokenUsage
    public let rawCumulativeUsage: TokenUsage?
    public let inheritedPrefixUsage: TokenUsage?
    public let inheritedPrefixCounts: UsageCounts?
    public let counts: UsageCounts
    public let ownedTurnIds: [String]
    public let turns: [TurnSummary]
    public let activeTurnCount: Int64
    public let segments: [UsageSegment]
    public let warnings: [String]
    public let parseErrors: Int64
    public let unclassifiedCompactionTotal: Int64

    public var id: String { threadId }
}

public struct Completeness: Codable, Equatable, Sendable {
    public let textTokenBreakdown: String?
    public let imageTokenBreakdown: String?
    public let effectiveServiceTier: String?
    public let subscriptionDollars: String?
    public let subagentAttribution: String?
    public let allAgentPerTurn: String?
    public let snapshotConsistency: String?
    public let usageSummary: String?
}

public struct PricingCatalogReference: Codable, Equatable, Sendable {
    public let catalogId: String?
    public let observedAt: String?
    public let scope: String?
}

public struct UsageReport: Codable, Equatable, Identifiable, Sendable {
    public let reportSchemaVersion: Int
    public let generatedAt: Date
    public let rootThreadId: String
    public let selectedTurnId: String?
    public let currentTurn: CurrentTurnSummary
    public let task: TaskSummary
    public let threads: [ThreadSummary]
    public let completeness: Completeness
    public let warnings: [String]
    public let pricingCatalog: PricingCatalogReference

    public var id: String { rootThreadId }
}

public enum UsageReportDecoder {
    public static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }

            let ordinary = ISO8601DateFormatter()
            ordinary.formatOptions = [.withInternetDateTime]
            if let date = ordinary.date(from: text) { return date }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 timestamp: \(text)"
            )
        }
        return decoder
    }

    public static func decode(_ data: Data) throws -> UsageReport {
        let decoder = makeJSONDecoder()
        let probe = try decoder.decode(VersionProbe.self, from: data)
        guard probe.reportSchemaVersion == 1 else {
            throw UsageReportError.unsupportedSchema(probe.reportSchemaVersion)
        }
        return try decoder.decode(UsageReport.self, from: data)
    }

    private struct VersionProbe: Decodable {
        let reportSchemaVersion: Int
    }
}

public enum UsageReportError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case invalidFile(String)
    case missingReportsDirectory

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "报告格式 v\(version) 暂不支持，请升级读取器。"
        case .invalidFile(let reason):
            return "报告文件无效：\(reason)"
        case .missingReportsDirectory:
            return "没有找到 token-usage/reports 目录。"
        }
    }
}
