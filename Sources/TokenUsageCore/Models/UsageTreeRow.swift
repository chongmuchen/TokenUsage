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

public struct UsageTreeRow: Identifiable, Sendable {
    public let id: String
    public let kind: UsageRowKind
    public let time: Date?
    public let name: String
    public let ownUsage: TokenUsage
    public let subtreeUsage: TokenUsage
    public let counts: UsageCounts
    public let imageGenerations: [ImageGenerationDetail]
    public let segments: [UsageSegment]
    public let modelSummary: String
    public let creditEstimate: CreditEstimate?
    public let apiPriceEstimate: APIPriceEstimate?
    public let apiUSDText: String?
    public let attribution: AttributionKind
    public let isProvisional: Bool
    public let isLowerBound: Bool
    public let warnings: [String]
    public let children: [UsageTreeRow]?

    public init(
        id: String,
        kind: UsageRowKind,
        time: Date?,
        name: String,
        ownUsage: TokenUsage,
        subtreeUsage: TokenUsage,
        counts: UsageCounts,
        imageGenerations: [ImageGenerationDetail] = [],
        segments: [UsageSegment],
        modelSummary: String,
        creditEstimate: CreditEstimate?,
        apiPriceEstimate: APIPriceEstimate? = nil,
        apiUSDText: String? = nil,
        attribution: AttributionKind,
        isProvisional: Bool = false,
        isLowerBound: Bool = false,
        warnings: [String] = [],
        children: [UsageTreeRow]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.time = time
        self.name = name
        self.ownUsage = ownUsage
        self.subtreeUsage = subtreeUsage
        self.counts = counts
        self.imageGenerations = imageGenerations
        self.segments = segments
        self.modelSummary = modelSummary
        self.creditEstimate = creditEstimate
        self.apiPriceEstimate = apiPriceEstimate
        self.apiUSDText = apiUSDText
        self.attribution = attribution
        self.isProvisional = isProvisional
        self.isLowerBound = isLowerBound
        self.warnings = warnings
        self.children = children?.isEmpty == true ? nil : children
    }
}

public enum DatePreset: String, CaseIterable, Identifiable, Sendable {
    case today = "今天"
    case week = "最近一周"
    case month = "最近一月"
    case custom = "自定义"

    public var id: String { rawValue }
}

public struct UsageFilter: Equatable, Sendable {
    public var startDate: Date
    public var endDate: Date
    public var minimumTokensText: String
    public var maximumTokensText: String
    public var preset: DatePreset

    public init(now: Date = Date(), calendar: Calendar = .current) {
        let end = Self.startOfMinute(now, calendar: calendar)
        let startOfToday = calendar.startOfDay(for: end)
        self.startDate = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
        self.endDate = end
        self.minimumTokensText = ""
        self.maximumTokensText = ""
        self.preset = .month
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
        self.preset = preset
        guard preset != .custom else { return }
        let end = Self.startOfMinute(now, calendar: calendar)
        let startOfToday = calendar.startOfDay(for: end)
        endDate = end
        switch preset {
        case .today:
            startDate = startOfToday
        case .week:
            startDate = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        case .month:
            startDate = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
        case .custom:
            break
        }
    }

    public func includes(_ row: UsageTreeRow, calendar: Calendar = .current) -> Bool {
        guard row.kind == .session, let time = row.time else { return false }
        let (lower, upper) = minuteRange(calendar: calendar)
        guard time >= lower && time < upper else { return false }
        if let minimumTokens, row.subtreeUsage.totalTokens < minimumTokens { return false }
        if let maximumTokens, row.subtreeUsage.totalTokens > maximumTokens { return false }
        return true
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
}
