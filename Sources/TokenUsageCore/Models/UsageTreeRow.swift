import Foundation

public enum UsageRowKind: String, Sendable {
    case session
    case summary
    case mainTurn
    case agentThread
    case agentTurn
    case sideGroup
    case residual
}

public enum AttributionKind: String, Sendable {
    case direct
    case timeInferred
    case unattributed
}

public enum UsageTokenScope: String, CaseIterable, Identifiable, Sendable {
    case sessionTotal
    case selectedRange

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sessionTotal: "会话总 Token"
        case .selectedRange: "时段内 Token"
        }
    }
}

public struct UsageTreeRow: Identifiable, Sendable {
    public let id: String
    public let kind: UsageRowKind
    public let time: Date?
    public let endTime: Date?
    public let name: String
    public let projectName: String?
    public let projectPath: String?
    public let ownUsage: TokenUsage
    public let subtreeUsage: TokenUsage
    public let counts: UsageCounts
    public let imageGenerations: [ImageGenerationDetail]
    public let segments: [UsageSegment]
    /// Segments owned by this row only. `segments` remains the subtree pricing
    /// plane for backwards compatibility.
    public let ownSegments: [UsageSegment]
    /// Optional exact minute samples. `nil` identifies a legacy report/row and
    /// triggers the timestamped-segment compatibility path when range slicing.
    public let ownUsageSamples: [UsageSample]?
    public let subtreeUsageSamples: [UsageSample]?
    public let usageSampleFallbackTime: Date?
    public let modelSummary: String
    public let creditEstimate: CreditEstimate?
    public let apiPriceEstimate: APIPriceEstimate?
    public let apiUSDText: String?
    public let attribution: AttributionKind
    public let isProvisional: Bool
    public let isLowerBound: Bool
    /// Approximation state for the subtree figures shown in the primary Token
    /// and breakdown columns.
    public let isUsageApproximate: Bool
    /// Approximation state for the secondary "自身" figure. A legacy report
    /// can still have an exact task-level minute plane while lacking the IDs
    /// needed to slice its root/turn ownership exactly.
    public let isOwnUsageApproximate: Bool
    public let pricingSuppressed: Bool
    public let warnings: [String]
    public let children: [UsageTreeRow]?

    public init(
        id: String,
        kind: UsageRowKind,
        time: Date?,
        endTime: Date? = nil,
        name: String,
        projectName: String? = nil,
        projectPath: String? = nil,
        ownUsage: TokenUsage,
        subtreeUsage: TokenUsage,
        counts: UsageCounts,
        imageGenerations: [ImageGenerationDetail] = [],
        segments: [UsageSegment],
        ownSegments: [UsageSegment]? = nil,
        ownUsageSamples: [UsageSample]? = nil,
        subtreeUsageSamples: [UsageSample]? = nil,
        usageSampleFallbackTime: Date? = nil,
        modelSummary: String,
        creditEstimate: CreditEstimate?,
        apiPriceEstimate: APIPriceEstimate? = nil,
        apiUSDText: String? = nil,
        attribution: AttributionKind,
        isProvisional: Bool = false,
        isLowerBound: Bool = false,
        isUsageApproximate: Bool = false,
        isOwnUsageApproximate: Bool? = nil,
        pricingSuppressed: Bool = false,
        warnings: [String] = [],
        children: [UsageTreeRow]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.time = time
        self.endTime = endTime
        self.name = name
        self.projectName = projectName
        self.projectPath = projectPath
        self.ownUsage = ownUsage
        self.subtreeUsage = subtreeUsage
        self.counts = counts
        self.imageGenerations = imageGenerations
        self.segments = segments
        self.ownSegments = ownSegments ?? segments
        self.ownUsageSamples = ownUsageSamples
        self.subtreeUsageSamples = subtreeUsageSamples
        self.usageSampleFallbackTime = usageSampleFallbackTime
        self.modelSummary = modelSummary
        self.creditEstimate = creditEstimate
        self.apiPriceEstimate = apiPriceEstimate
        self.apiUSDText = apiUSDText
        self.attribution = attribution
        self.isProvisional = isProvisional
        self.isLowerBound = isLowerBound
        self.isUsageApproximate = isUsageApproximate
        self.isOwnUsageApproximate = isOwnUsageApproximate ?? isUsageApproximate
        self.pricingSuppressed = pricingSuppressed
        self.warnings = warnings
        self.children = children?.isEmpty == true ? nil : children
    }
}

public enum DatePreset: String, CaseIterable, Identifiable, Sendable {
    case today = "今天"
    case week = "最近一周"
    case month = "最近一月"
    case limitPeriod = "本周期（额度周期）"
    case custom = "自定义"

    public var id: String { rawValue }
}

public struct UsageFilter: Equatable, Sendable {
    public var startDate: Date
    public var endDate: Date
    public var minimumTokensText: String
    public var maximumTokensText: String
    public var preset: DatePreset
    public var tokenScope: UsageTokenScope

    public init(now: Date = Date(), calendar: Calendar = .current) {
        let startOfToday = calendar.startOfDay(for: now)
        self.startDate = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
        self.endDate = Self.endMinuteOfDay(containing: now, calendar: calendar)
        self.minimumTokensText = ""
        self.maximumTokensText = ""
        self.preset = .month
        self.tokenScope = .sessionTotal
    }

    public var minimumTokens: Int64? {
        Self.parseTokenBound(minimumTokensText)
    }

    public var maximumTokens: Int64? {
        Self.parseTokenBound(maximumTokensText)
    }

    /// Accepts exact values as well as compact forms such as 100k and 1.5M.
    /// Grouping separators and spaces are ignored.
    public static func parseTokenBound(_ text: String) -> Int64? {
        var normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty else { return nil }

        let multiplier: Double
        switch normalized.last {
        case "k":
            multiplier = 1_000
            normalized.removeLast()
        case "m":
            multiplier = 1_000_000
            normalized.removeLast()
        case "b":
            multiplier = 1_000_000_000
            normalized.removeLast()
        default:
            multiplier = 1
        }
        guard let base = Double(normalized), base >= 0 else { return nil }
        let value = base * multiplier
        guard value.isFinite, value <= Double(Int64.max) else { return nil }
        return Int64(value.rounded())
    }

    public mutating func apply(_ preset: DatePreset, now: Date = Date(), calendar: Calendar = .current) {
        // The quota period is supplied by the server-backed weekly projection;
        // a static calendar preset cannot derive it safely.
        guard preset != .limitPeriod else { return }
        self.preset = preset
        guard preset != .custom else { return }
        let startOfToday = calendar.startOfDay(for: now)
        endDate = Self.endMinuteOfDay(containing: now, calendar: calendar)
        switch preset {
        case .today:
            startDate = startOfToday
        case .week:
            startDate = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        case .month:
            startDate = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
        case .limitPeriod:
            break
        case .custom:
            break
        }
    }

    /// Applies a server quota window expressed as a half-open range. Usage is
    /// recorded in minute buckets, so both boundaries are floored and the UI's
    /// inclusive end picker is set to the minute immediately before reset.
    @discardableResult
    public mutating func applyLimitPeriod(
        start: Date,
        endExclusive: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let lower = Self.startOfMinute(start, calendar: calendar)
        let upper = Self.startOfMinute(endExclusive, calendar: calendar)
        guard
            lower < upper,
            let inclusiveEnd = calendar.date(byAdding: .minute, value: -1, to: upper)
        else { return false }

        startDate = lower
        endDate = inclusiveEnd
        preset = .limitPeriod
        return true
    }

    /// Keep the quota reset time in the picker, but stop daily charts at the
    /// current moment instead of filling future days with zeroes.
    public func chartEndDate(now: Date = Date()) -> Date {
        preset == .limitPeriod ? min(endDate, now) : endDate
    }

    public func overlapsDateRange(_ row: UsageTreeRow, calendar: Calendar = .current) -> Bool {
        guard row.kind == .session, let start = row.time else { return false }
        let (lower, upper) = minuteRange(calendar: calendar)
        let end = max(row.endTime ?? start, start)
        return start < upper && end >= lower
    }

    public func includesTokenBounds(_ row: UsageTreeRow) -> Bool {
        if let minimumTokens, row.subtreeUsage.totalTokens < minimumTokens { return false }
        if let maximumTokens, row.subtreeUsage.totalTokens > maximumTokens { return false }
        return true
    }

    public func includes(_ row: UsageTreeRow, calendar: Calendar = .current) -> Bool {
        overlapsDateRange(row, calendar: calendar) && includesTokenBounds(row)
    }

    /// Returns a half-open range that includes every timestamp in the selected
    /// start and end minutes. Date pickers expose minute precision, while the
    /// reports themselves retain seconds and milliseconds.
    public func minuteRange(calendar: Calendar = .current) -> (lower: Date, upperExclusive: Date) {
        let lower = Self.startOfMinute(min(startDate, endDate), calendar: calendar)
        let finalMinute = Self.startOfMinute(max(startDate, endDate), calendar: calendar)
        let upper = calendar.date(byAdding: .minute, value: 1, to: finalMinute) ?? finalMinute
        return (lower, upper)
    }

    private static func startOfMinute(_ date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return calendar.date(from: components) ?? date
    }

    private static func endMinuteOfDay(containing date: Date, calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        guard
            let startOfNextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay),
            let endMinute = calendar.date(byAdding: .minute, value: -1, to: startOfNextDay)
        else {
            return startOfMinute(date, calendar: calendar)
        }
        return endMinute
    }
}
