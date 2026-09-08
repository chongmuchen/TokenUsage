import Foundation

/// One authoritative minute-level usage bucket from a root task report.
/// `minute == nil` is retained for reconciliation and is plotted at the
/// report generation minute as an explicitly approximate fallback.
public struct UsageSample: Codable, Equatable, Hashable, Sendable {
    public let minute: Date?
    /// Optional ownership metadata emitted by newer producers. Keeping it on
    /// the task-level timeline lets detail views slice the exact same samples
    /// as the trend view without duplicating an accounting plane.
    public let threadId: String?
    public let turnId: String?
    public let model: String?
    public let effort: String?
    public let tier: String?
    public let tierSource: String?
    public let taskEpoch: Int64?
    public let longContext: Bool?
    public let usage: TokenUsage
    public let requestCount: Int64?

    public init(
        minute: Date?,
        threadId: String? = nil,
        turnId: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        tier: String? = nil,
        tierSource: String? = nil,
        taskEpoch: Int64? = nil,
        longContext: Bool? = nil,
        usage: TokenUsage,
        requestCount: Int64? = nil
    ) {
        self.minute = minute
        self.threadId = threadId
        self.turnId = turnId
        self.model = model
        self.effort = effort
        self.tier = tier
        self.tierSource = tierSource
        self.taskEpoch = taskEpoch
        self.longContext = longContext
        self.usage = usage
        self.requestCount = requestCount
    }
}

public enum UsageTrendSpeed: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case fast
    case unknown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: "Standard"
        case .fast: "Fast"
        case .unknown: "未知速度"
        }
    }
}

public enum UsageTrendGroupMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case configuration

    public var id: String { rawValue }
}

/// Empty selections mean "all" for that dimension. Values in
/// `selectedModels` are canonical model IDs returned by `dimensions.models`.
public struct UsageTrendFilter: Equatable, Sendable {
    public var startMinute: Date
    public var endMinute: Date
    public var selectedModels: Set<String>
    public var selectedEfforts: Set<String>
    public var selectedSpeeds: Set<UsageTrendSpeed>
    public var groupMode: UsageTrendGroupMode

    public init(
        startMinute: Date,
        endMinute: Date,
        selectedModels: Set<String> = [],
        selectedEfforts: Set<String> = [],
        selectedSpeeds: Set<UsageTrendSpeed> = [],
        groupMode: UsageTrendGroupMode = .all
    ) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.selectedModels = selectedModels
        self.selectedEfforts = selectedEfforts
        self.selectedSpeeds = selectedSpeeds
        self.groupMode = groupMode
    }
}

public struct UsageTrendModelOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct UsageTrendConfiguration: Identifiable, Hashable, Sendable {
    public let modelID: String
    public let modelName: String
    public let effort: String
    public let speed: UsageTrendSpeed

    public init(modelID: String, modelName: String, effort: String, speed: UsageTrendSpeed) {
        self.modelID = modelID
        self.modelName = modelName
        self.effort = effort
        self.speed = speed
    }

    public var id: String {
        [modelID, effort, speed.rawValue].joined(separator: "\u{1F}")
    }

    public var displayName: String {
        "\(modelName) · \(effort) · \(speed.displayName)"
    }
}

public enum UsageTrendSeriesKey: Hashable, Sendable {
    case all
    case configuration(UsageTrendConfiguration)
}

/// Cache-write is a subset of non-cached input and is exposed separately for
/// price tooltips. The total identity is:
/// nonCachedInput + cachedInput + output == total.
public struct UsageTrendTokenBreakdown: Equatable, Sendable {
    public let nonCachedInputTokens: Int64
    public let cachedInputTokens: Int64
    public let cacheWriteInputTokens: Int64
    public let outputTokens: Int64
    public let reasoningOutputTokens: Int64
    public let totalTokens: Int64

    public init(
        nonCachedInputTokens: Int64 = 0,
        cachedInputTokens: Int64 = 0,
        cacheWriteInputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        reasoningOutputTokens: Int64 = 0,
        totalTokens: Int64? = nil
    ) {
        self.nonCachedInputTokens = max(nonCachedInputTokens, 0)
        self.cachedInputTokens = max(cachedInputTokens, 0)
        self.cacheWriteInputTokens = min(
            max(cacheWriteInputTokens, 0),
            max(nonCachedInputTokens, 0)
        )
        self.outputTokens = max(outputTokens, 0)
        self.reasoningOutputTokens = min(max(reasoningOutputTokens, 0), max(outputTokens, 0))
        self.totalTokens = max(
            totalTokens ?? trendSaturatedAdd(
                trendSaturatedAdd(max(nonCachedInputTokens, 0), max(cachedInputTokens, 0)),
                max(outputTokens, 0)
            ),
            0
        )
    }

    public init(usage: TokenUsage) {
        self.init(
            nonCachedInputTokens: max(usage.inputTokens - usage.cachedInputTokens, 0),
            cachedInputTokens: usage.cachedInputTokens,
            cacheWriteInputTokens: usage.cacheWriteInputTokens,
            outputTokens: usage.outputTokens,
            reasoningOutputTokens: usage.reasoningOutputTokens,
            totalTokens: usage.totalTokens
        )
    }

    public static let zero = UsageTrendTokenBreakdown()

    public var ordinaryInputTokens: Int64 {
        max(nonCachedInputTokens - cacheWriteInputTokens, 0)
    }

    public static func + (
        lhs: UsageTrendTokenBreakdown,
        rhs: UsageTrendTokenBreakdown
    ) -> UsageTrendTokenBreakdown {
        UsageTrendTokenBreakdown(
            nonCachedInputTokens: trendSaturatedAdd(lhs.nonCachedInputTokens, rhs.nonCachedInputTokens),
            cachedInputTokens: trendSaturatedAdd(lhs.cachedInputTokens, rhs.cachedInputTokens),
            cacheWriteInputTokens: trendSaturatedAdd(lhs.cacheWriteInputTokens, rhs.cacheWriteInputTokens),
            outputTokens: trendSaturatedAdd(lhs.outputTokens, rhs.outputTokens),
            reasoningOutputTokens: trendSaturatedAdd(lhs.reasoningOutputTokens, rhs.reasoningOutputTokens),
            totalTokens: trendSaturatedAdd(lhs.totalTokens, rhs.totalTokens)
        )
    }
}

public enum UsageTrendPriceBasis: String, Sendable {
    case configured
    case standard
    case mixed
    case unavailable
}

public struct UsageTrendPriceSummary: Equatable, Sendable {
    public let amount: Decimal?
    public let basis: UsageTrendPriceBasis
    public let pricedTokens: Int64
    public let totalTokens: Int64
    public let suppressedTokens: Int64

    public init(
        amount: Decimal?,
        basis: UsageTrendPriceBasis,
        pricedTokens: Int64,
        totalTokens: Int64,
        suppressedTokens: Int64
    ) {
        self.amount = amount
        self.basis = basis
        self.pricedTokens = max(pricedTokens, 0)
        self.totalTokens = max(totalTokens, 0)
        self.suppressedTokens = max(suppressedTokens, 0)
    }

    public var unpricedTokens: Int64 { max(totalTokens - pricedTokens, 0) }
    public var isPartial: Bool { pricedTokens < totalTokens }
    public var isSuppressed: Bool { suppressedTokens > 0 }
}

public struct UsageTrendAggregate: Equatable, Sendable {
    public let tokens: UsageTrendTokenBreakdown
    public let credits: UsageTrendPriceSummary
    public let apiUSD: UsageTrendPriceSummary
    public let isApproximate: Bool

    public init(
        tokens: UsageTrendTokenBreakdown,
        credits: UsageTrendPriceSummary,
        apiUSD: UsageTrendPriceSummary,
        isApproximate: Bool
    ) {
        self.tokens = tokens
        self.credits = credits
        self.apiUSD = apiUSD
        self.isApproximate = isApproximate
    }
}

public struct UsageTrendPoint: Identifiable, Equatable, Sendable {
    public let day: Date
    public let aggregate: UsageTrendAggregate

    public init(day: Date, aggregate: UsageTrendAggregate) {
        self.day = day
        self.aggregate = aggregate
    }

    public var id: Date { day }
}

public struct UsageTrendSeries: Identifiable, Sendable {
    public let id: UsageTrendSeriesKey
    public let name: String
    public let points: [UsageTrendPoint]
    public let summary: UsageTrendAggregate

    public init(
        id: UsageTrendSeriesKey,
        name: String,
        points: [UsageTrendPoint],
        summary: UsageTrendAggregate
    ) {
        self.id = id
        self.name = name
        self.points = points
        self.summary = summary
    }
}

public struct UsageTrendDimensions: Sendable {
    public let models: [UsageTrendModelOption]
    public let efforts: [String]
    public let speeds: [UsageTrendSpeed]

    public init(
        models: [UsageTrendModelOption],
        efforts: [String],
        speeds: [UsageTrendSpeed]
    ) {
        self.models = models
        self.efforts = efforts
        self.speeds = speeds
    }
}

public struct UsageTrendResult: Sendable {
    public let startMinute: Date
    public let endMinute: Date
    public let days: [Date]
    public let dimensions: UsageTrendDimensions
    public let series: [UsageTrendSeries]
    public let warnings: [String]

    public init(
        startMinute: Date,
        endMinute: Date,
        days: [Date],
        dimensions: UsageTrendDimensions,
        series: [UsageTrendSeries],
        warnings: [String]
    ) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.days = days
        self.dimensions = dimensions
        self.series = series
        self.warnings = warnings
    }

    public var isApproximate: Bool {
        series.contains { $0.summary.isApproximate }
    }
}

@inline(__always)
private func trendSaturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int64.max : value
}
