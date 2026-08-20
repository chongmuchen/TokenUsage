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
        var standardAmount = Decimal.zero
        var configuredAmount = Decimal.zero
        var standardTokens: Int64 = 0
        var configuredTokens: Int64 = 0
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

            standardAmount += base
            standardTokens = addingWithoutOverflow(standardTokens, usage.totalTokens)

            guard segment.tierSource != "current_config_fallback", let tier = segment.tier else {
                continue
            }
            if standardTiers.contains(tier) {
                configuredAmount += base
                configuredTokens = addingWithoutOverflow(configuredTokens, usage.totalTokens)
            } else if fastTiers.contains(tier), let multiplier = decimal(rates.fast?.billingMultiplier) {
                configuredAmount += base * multiplier
                configuredTokens = addingWithoutOverflow(configuredTokens, usage.totalTokens)
            }
        }

        if totalTokens > 0, configuredTokens == totalTokens {
            return CreditEstimate(
                amount: configuredAmount,
                basis: .configured,
                pricedTokens: configuredTokens,
                totalTokens: totalTokens
            )
        }
        return CreditEstimate(
            amount: standardTokens > 0 ? standardAmount : nil,
            basis: .standard,
            pricedTokens: standardTokens,
            totalTokens: totalTokens
        )
    }

    public func estimateAPI(
        _ segments: [UsageSegment],
        expectedTotalTokens: Int64? = nil
    ) -> APIPriceEstimate {
        var standardAmount = Decimal.zero
        var configuredAmount = Decimal.zero
        var standardTokens: Int64 = 0
        var configuredTokens: Int64 = 0
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

            standardAmount += standard
            standardTokens = addingWithoutOverflow(standardTokens, segment.usage.totalTokens)

            guard segment.tierSource != "current_config_fallback", let tier = segment.tier else {
                continue
            }
            if standardTiers.contains(tier) {
                configuredAmount += standard
                configuredTokens = addingWithoutOverflow(configuredTokens, segment.usage.totalTokens)
            } else if
                fastTiers.contains(tier),
                let fast = amount(for: segment, api: api, groups: api.fast, unit: unit)
            {
                configuredAmount += fast
                configuredTokens = addingWithoutOverflow(configuredTokens, segment.usage.totalTokens)
            }
        }

        if totalTokens > 0, configuredTokens == totalTokens {
            return APIPriceEstimate(
                amount: configuredAmount,
                basis: .configured,
                pricedTokens: configuredTokens,
                totalTokens: totalTokens
            )
        }
        return APIPriceEstimate(
            amount: standardTokens > 0 ? standardAmount : nil,
            basis: .standard,
            pricedTokens: standardTokens,
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

        let tiers = Set(segments.compactMap(\.tier))
        if tiers.count == 1, let tier = tiers.first {
            if fastTiers.contains(tier) {
                if let speed = entry?.codexCredits?.fast?.speedMultiplierNominal {
                    pieces.append("Fast \(speed)×")
                } else {
                    pieces.append("Fast")
                }
            } else if standardTiers.contains(tier) {
                pieces.append("Standard")
            } else {
                pieces.append(tier)
            }
        } else if tiers.count > 1 {
            pieces.append("混合档位")
        }
        return pieces.joined(separator: " · ")
    }

    private func decimal(_ text: String?) -> Decimal? {
        guard let text else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
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
}
