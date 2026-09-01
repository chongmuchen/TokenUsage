import Foundation

public struct PricingCatalog: Decodable, Sendable {
    public let schemaVersion: Int
    public let catalogId: String
    public let observedAt: String
    public let tokenUnit: Int64
    public let scope: String
    public let models: [String: ModelPricing]

    public init(
        schemaVersion: Int,
        catalogId: String,
        observedAt: String,
        tokenUnit: Int64,
        scope: String,
        models: [String: ModelPricing]
    ) {
        self.schemaVersion = schemaVersion
        self.catalogId = catalogId
        self.observedAt = observedAt
        self.tokenUnit = tokenUnit
        self.scope = scope
        self.models = models
    }

    public static func bundled() throws -> PricingCatalog {
        guard let url = TokenUsageResources.url(forResource: "pricing_catalog", withExtension: "json") else {
            throw PricingCatalogError.missingResource
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PricingCatalog.self, from: data)
    }

    public func entry(for model: String?) -> (key: String, value: ModelPricing)? {
        guard let model else { return nil }
        if let exact = models[model] { return (model, exact) }
        return models.first { $0.value.aliases.contains(model) }
    }
}

public struct ModelPricing: Decodable, Sendable {
    public let displayName: String
    public let aliases: [String]
    public let codexCredits: CodexCreditRates?
    public let apiUsd: APIPriceCatalog?
}

public struct CodexCreditRates: Decodable, Sendable {
    public let input: String?
    public let cachedInput: String?
    public let output: String?
    public let fast: FastCreditRates?
}

public struct FastCreditRates: Decodable, Sendable {
    public let support: String?
    public let speedMultiplierNominal: String?
    public let billingMultiplier: String?
}

public struct APIPriceCatalog: Decodable, Sendable {
    public let standard: APIRateGroups?
    public let fast: APIRateGroups?
    public let longContextThresholdInputTokensExclusive: Int64?
    public let longContextRule: APILongContextRule?
}

public struct APIRateGroups: Decodable, Sendable {
    public let short: APITokenRates?
    public let long: APITokenRates?
}

public struct APITokenRates: Decodable, Sendable {
    public let input: String?
    public let cachedInput: String?
    public let cacheWrite: String?
    public let output: String?
}

public struct APILongContextRule: Decodable, Sendable {
    public let thresholdInputTokensExclusive: Int64?
    public let inputMultiplier: String?
    public let outputMultiplier: String?
}

public enum PricingCatalogError: LocalizedError {
    case missingResource

    public var errorDescription: String? {
        "应用资源中缺少 pricing_catalog.json。"
    }
}

public enum CreditEstimateBasis: String, Sendable, Hashable {
    case configured = "配置价"
    case standard = "Std价"
    case mixed = "混合口径"
}

public struct CreditEstimate: Equatable, Sendable {
    public let amount: Decimal?
    public let basis: CreditEstimateBasis
    public let pricedTokens: Int64
    public let totalTokens: Int64

    public var isPartial: Bool { pricedTokens < totalTokens }
}

public enum APIPriceEstimateBasis: String, Sendable, Hashable {
    case configured = "配置档 API 价"
    case standard = "Standard API 价"
    case mixed = "混合口径 API 价"
}

public struct APIPriceEstimate: Equatable, Sendable {
    public let amount: Decimal?
    public let basis: APIPriceEstimateBasis
    public let pricedTokens: Int64
    public let totalTokens: Int64

    public var isPartial: Bool { pricedTokens < totalTokens }
}

public struct CreditEstimator: Sendable {
    private let catalog: PricingCatalog
    private let standardTiers: Set<String> = ["default", "standard"]
    private let fastTiers: Set<String> = ["fast", "priority"]

    public init(catalog: PricingCatalog) {
        self.catalog = catalog
    }

    public func estimate(
        _ segments: [UsageSegment],
        expectedTotalTokens: Int64? = nil
    ) -> CreditEstimate {
        var estimatedAmount = Decimal.zero
        var hasAmount = false
        var bases = Set<CreditEstimateBasis>()
        var pricedTokens: Int64 = 0
        let segmentTokens = segments.reduce(Int64.zero) {
            addingWithoutOverflow($0, $1.usage.totalTokens)
        }
        let totalTokens = expectedTotalTokens ?? segmentTokens
        let unit = Decimal(catalog.tokenUnit)
        guard segmentTokens <= totalTokens else {
            return CreditEstimate(amount: nil, basis: .standard, pricedTokens: 0, totalTokens: totalTokens)
        }

        for segment in segments {
            guard
                let entry = catalog.entry(for: segment.model)?.value,
                let rates = entry.codexCredits,
                let inputRate = decimal(rates.input),
                let cachedRate = decimal(rates.cachedInput),
                let outputRate = decimal(rates.output)
            else { continue }

            let usage = segment.usage
            guard usage.cachedInputTokens <= usage.inputTokens else { continue }
            let ordinary = max(usage.inputTokens - usage.cachedInputTokens, 0)
            let base = (
                Decimal(ordinary) * inputRate
                + Decimal(usage.cachedInputTokens) * cachedRate
                + Decimal(usage.outputTokens) * outputRate
            ) / unit

            let selected: (amount: Decimal, basis: CreditEstimateBasis)
            switch pricingTier(for: segment) {
            case .standard:
                selected = (base, .configured)
            case .fast:
                guard let multiplier = decimal(rates.fast?.billingMultiplier) else { continue }
                selected = (base * multiplier, .configured)
            case .fallbackStandard:
                selected = (base, .standard)
            }

            estimatedAmount += selected.amount
            bases.insert(selected.basis)
            pricedTokens = addingWithoutOverflow(pricedTokens, usage.totalTokens)
            hasAmount = true
        }

        return CreditEstimate(
            amount: hasAmount ? estimatedAmount : nil,
            basis: creditBasis(for: bases),
            pricedTokens: pricedTokens,
            totalTokens: totalTokens
        )
    }

    public func estimateAPI(
        _ segments: [UsageSegment],
        expectedTotalTokens: Int64? = nil
    ) -> APIPriceEstimate {
        var estimatedAmount = Decimal.zero
        var hasAmount = false
        var bases = Set<APIPriceEstimateBasis>()
        var pricedTokens: Int64 = 0
        let segmentTokens = segments.reduce(Int64.zero) {
            addingWithoutOverflow($0, $1.usage.totalTokens)
        }
        let totalTokens = expectedTotalTokens ?? segmentTokens
        let unit = Decimal(catalog.tokenUnit)
        guard segmentTokens <= totalTokens else {
            return APIPriceEstimate(amount: nil, basis: .standard, pricedTokens: 0, totalTokens: totalTokens)
        }

        for segment in segments {
            guard
                let api = catalog.entry(for: segment.model)?.value.apiUsd,
                let standard = amount(for: segment, api: api, groups: api.standard, unit: unit)
            else { continue }

            let selected: (amount: Decimal, basis: APIPriceEstimateBasis)
            switch pricingTier(for: segment) {
            case .standard:
                selected = (standard, .configured)
            case .fast:
                guard let fast = amount(for: segment, api: api, groups: api.fast, unit: unit) else {
                    continue
                }
                selected = (fast, .configured)
            case .fallbackStandard:
                selected = (standard, .standard)
            }

            estimatedAmount += selected.amount
            bases.insert(selected.basis)
            pricedTokens = addingWithoutOverflow(pricedTokens, segment.usage.totalTokens)
            hasAmount = true
        }

        return APIPriceEstimate(
            amount: hasAmount ? estimatedAmount : nil,
            basis: apiBasis(for: bases),
            pricedTokens: pricedTokens,
            totalTokens: totalTokens
        )
    }

    public func modelSummary(for segments: [UsageSegment]) -> String {
        let keys = Set(segments.compactMap(\.model))
        guard !keys.isEmpty else { return "—" }
        if keys.count > 1 { return "混合 \(keys.count) 种" }

        let model = keys.first!
        let entry = catalog.entry(for: model)?.value
        var pieces = [entry?.displayName ?? model]

        let efforts = Set(segments.compactMap(\.effort))
        if efforts.count == 1, let effort = efforts.first { pieces.append(effort) }

        let effectiveTiers = Set(segments.map { pricingTier(for: $0) })
        if effectiveTiers == [.fast] {
            if let speed = entry?.codexCredits?.fast?.speedMultiplierNominal {
                pieces.append("Fast \(speed)×")
            } else {
                pieces.append("Fast")
            }
        } else if effectiveTiers.contains(.fast) {
            pieces.append("混合档位")
        } else if !effectiveTiers.isEmpty {
            // Missing, unknown, and current-config fallback tiers all use the
            // Standard estimate. Do not label a session as Fast merely because
            // the fallback config happened to contain "priority".
            pieces.append("Standard")
        }
        return pieces.joined(separator: " · ")
    }

    private func decimal(_ text: String?) -> Decimal? {
        guard let text else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Chooses the price for one observed accounting bucket. A tier is only
    /// authoritative when it came from the transcript itself. Config-file
    /// fallbacks and unknown tier values deliberately use Standard so a mixed
    /// task can retain safe partial coverage without repricing known Fast use.
    private func pricingTier(for segment: UsageSegment) -> PricingTier {
        let source = normalized(segment.tierSource)
        guard source != "current_config_fallback", let tier = normalized(segment.tier) else {
            return .fallbackStandard
        }
        if standardTiers.contains(tier) { return .standard }
        if fastTiers.contains(tier) { return .fast }
        return .fallbackStandard
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }

    private func creditBasis(for bases: Set<CreditEstimateBasis>) -> CreditEstimateBasis {
        if bases.count > 1 || bases.contains(.mixed) { return .mixed }
        return bases.first ?? .standard
    }

    private func apiBasis(for bases: Set<APIPriceEstimateBasis>) -> APIPriceEstimateBasis {
        if bases.count > 1 || bases.contains(.mixed) { return .mixed }
        return bases.first ?? .standard
    }

    private func amount(
        for segment: UsageSegment,
        api: APIPriceCatalog,
        groups: APIRateGroups?,
        unit: Decimal
    ) -> Decimal? {
        guard let groups else { return nil }
        let usage = segment.usage
        let hasDistinctLongPrice = groups.long != nil
            || api.longContextRule != nil
            || api.longContextThresholdInputTokensExclusive != nil
        let isLong: Bool
        if let recordedLongContext = segment.longContext {
            // A segment may aggregate many individually short requests. Never
            // reclassify it from the aggregate input token count.
            isLong = recordedLongContext
        } else if hasDistinctLongPrice {
            // The per-request flag is required to choose a safe price.
            return nil
        } else {
            isLong = false
        }

        let rates: APITokenRates?
        let inputMultiplier: Decimal
        let outputMultiplier: Decimal
        if isLong, let explicitLong = groups.long {
            rates = explicitLong
            inputMultiplier = 1
            outputMultiplier = 1
        } else {
            rates = groups.short
            if isLong, let rule = api.longContextRule {
                inputMultiplier = decimal(rule.inputMultiplier) ?? 1
                outputMultiplier = decimal(rule.outputMultiplier) ?? 1
            } else {
                inputMultiplier = 1
                outputMultiplier = 1
            }
        }
        guard let rates else { return nil }

        let ordinary = usage.ordinaryInputTokens
        guard let ordinaryCost = componentCost(ordinary, rate: rates.input, multiplier: inputMultiplier) else {
            return nil
        }
        guard let cachedCost = componentCost(
            usage.cachedInputTokens,
            rate: rates.cachedInput,
            multiplier: inputMultiplier
        ) else { return nil }
        guard let cacheWriteCost = componentCost(
            usage.cacheWriteInputTokens,
            rate: rates.cacheWrite,
            multiplier: inputMultiplier
        ) else { return nil }
        guard let outputCost = componentCost(
            usage.outputTokens,
            rate: rates.output,
            multiplier: outputMultiplier
        ) else { return nil }
        return (ordinaryCost + cachedCost + cacheWriteCost + outputCost) / unit
    }

    private func componentCost(_ tokens: Int64, rate: String?, multiplier: Decimal) -> Decimal? {
        guard tokens > 0 else { return 0 }
        guard let value = decimal(rate) else { return nil }
        return Decimal(tokens) * value * multiplier
    }

    private func addingWithoutOverflow(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : result
    }

    private enum PricingTier: Hashable {
        case standard
        case fast
        case fallbackStandard
    }
}
