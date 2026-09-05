import Testing
@testable import TokenUsageCore

private struct ExpectedRates {
    let input: String?
    let cachedInput: String?
    let cacheWrite: String?
    let output: String?
}

@Test("Bundled pricing catalog identifies the current public snapshot")
func pricingCatalogCurrentSnapshotMetadata() throws {
    let catalog = try PricingCatalog.bundled()

    #expect(catalog.catalogId == "openai-public-2026-09-05")
    #expect(catalog.observedAt == "2026-09-05")
    #expect(catalog.tokenUnit == 1_000_000)
    #expect(catalog.models.count == 7)
    #expect(catalog.entry(for: "gpt-5.6")?.key == "gpt-5.6-sol")
}

@Test("Bundled pricing catalog matches current ChatGPT and Codex credit rates")
func pricingCatalogCurrentCreditRates() throws {
    let catalog = try PricingCatalog.bundled()

    try expectCredits(
        catalog, model: "gpt-6-astra",
        input: "250", cachedInput: "25", output: "1250",
        fastSupport: "documented", fastMultiplier: "2.5", speedMultiplier: nil
    )
    try expectCredits(
        catalog, model: "gpt-5.6-sol",
        input: "100", cachedInput: "10", output: "500",
        fastSupport: "documented", fastMultiplier: "2.5"
    )
    try expectCredits(
        catalog, model: "gpt-5.6-terra",
        input: "50", cachedInput: "5", output: "300",
        fastSupport: "documented", fastMultiplier: "2.5"
    )
    try expectCredits(
        catalog, model: "gpt-5.6-luna",
        input: "5", cachedInput: "0.5", output: "30",
        fastSupport: "documented", fastMultiplier: "2.5"
    )
    try expectCredits(
        catalog, model: "gpt-5.5",
        input: "125", cachedInput: "12.5", output: "750",
        fastSupport: "documented_for_chatgpt_codex", fastMultiplier: "2.5"
    )
    try expectCredits(
        catalog, model: "gpt-5.4",
        input: "62.5", cachedInput: "6.25", output: "375",
        fastSupport: "documented_for_chatgpt_codex", fastMultiplier: "2.0"
    )
    try expectCredits(
        catalog, model: "gpt-5.4-mini",
        input: "18.75", cachedInput: "1.875", output: "113",
        fastSupport: "not_listed", fastMultiplier: nil, speedMultiplier: nil
    )
}

@Test("Bundled pricing catalog matches current Standard and Fast API rates")
func pricingCatalogCurrentTieredAPIRates() throws {
    let catalog = try PricingCatalog.bundled()

    try expectTieredAPI(
        catalog, model: "gpt-6-astra",
        standardShort: .init(input: "10.00", cachedInput: "1.00", cacheWrite: "12.50", output: "50.00"),
        standardLong: .init(input: "20.00", cachedInput: "2.00", cacheWrite: "25.00", output: "75.00"),
        fastShort: .init(input: "20.00", cachedInput: "2.00", cacheWrite: "25.00", output: "100.00"),
        fastLong: .init(input: "40.00", cachedInput: "4.00", cacheWrite: "50.00", output: "150.00")
    )
    try expectTieredAPI(
        catalog, model: "gpt-5.6-sol",
        standardShort: .init(input: "4.00", cachedInput: "0.40", cacheWrite: "5.00", output: "20.00"),
        standardLong: .init(input: "8.00", cachedInput: "0.80", cacheWrite: "10.00", output: "30.00"),
        fastShort: .init(input: "8.00", cachedInput: "0.80", cacheWrite: "10.00", output: "40.00"),
        fastLong: .init(input: "16.00", cachedInput: "1.60", cacheWrite: "20.00", output: "60.00")
    )
    try expectTieredAPI(
        catalog, model: "gpt-5.6-terra",
        standardShort: .init(input: "2.00", cachedInput: "0.20", cacheWrite: "2.50", output: "12.00"),
        standardLong: .init(input: "4.00", cachedInput: "0.40", cacheWrite: "5.00", output: "18.00"),
        fastShort: .init(input: "4.00", cachedInput: "0.40", cacheWrite: "5.00", output: "24.00"),
        fastLong: .init(input: "8.00", cachedInput: "0.80", cacheWrite: "10.00", output: "36.00")
    )
    try expectTieredAPI(
        catalog, model: "gpt-5.6-luna",
        standardShort: .init(input: "0.20", cachedInput: "0.02", cacheWrite: "0.25", output: "1.20"),
        standardLong: .init(input: "0.40", cachedInput: "0.04", cacheWrite: "0.50", output: "1.80"),
        fastShort: .init(input: "0.40", cachedInput: "0.04", cacheWrite: "0.50", output: "2.40"),
        fastLong: .init(input: "0.80", cachedInput: "0.08", cacheWrite: "1.00", output: "3.60")
    )
}

@Test("Bundled pricing catalog preserves documented legacy model API limits")
func pricingCatalogLegacyModelAPIRatesAndLimits() throws {
    let catalog = try PricingCatalog.bundled()

    try expectLegacyAPI(
        catalog, model: "gpt-5.5",
        short: .init(input: "5.00", cachedInput: "0.50", cacheWrite: nil, output: "30.00"),
        longContext: true
    )
    try expectLegacyAPI(
        catalog, model: "gpt-5.4",
        short: .init(input: "2.50", cachedInput: "0.25", cacheWrite: nil, output: "15.00"),
        longContext: true
    )
    try expectLegacyAPI(
        catalog, model: "gpt-5.4-mini",
        short: .init(input: "0.75", cachedInput: "0.075", cacheWrite: nil, output: "4.50"),
        longContext: false
    )
}

private func expectCredits(
    _ catalog: PricingCatalog,
    model: String,
    input: String,
    cachedInput: String,
    output: String,
    fastSupport: String,
    fastMultiplier: String?,
    speedMultiplier: String? = "1.5"
) throws {
    let rates = try #require(catalog.models[model]?.codexCredits)
    #expect(rates.input == input)
    #expect(rates.cachedInput == cachedInput)
    #expect(rates.output == output)
    #expect(rates.fast?.support == fastSupport)
    #expect(rates.fast?.speedMultiplierNominal == speedMultiplier)
    #expect(rates.fast?.billingMultiplier == fastMultiplier)
}

private func expectTieredAPI(
    _ catalog: PricingCatalog,
    model: String,
    standardShort: ExpectedRates,
    standardLong: ExpectedRates,
    fastShort: ExpectedRates,
    fastLong: ExpectedRates
) throws {
    let api = try #require(catalog.models[model]?.apiUsd)
    #expect(api.longContextThresholdInputTokensExclusive == 272_000)
    #expect(api.longContextRule == nil)
    try expectRates(api.standard?.short, standardShort)
    try expectRates(api.standard?.long, standardLong)
    try expectRates(api.fast?.short, fastShort)
    try expectRates(api.fast?.long, fastLong)
}

private func expectLegacyAPI(
    _ catalog: PricingCatalog,
    model: String,
    short: ExpectedRates,
    longContext: Bool
) throws {
    let api = try #require(catalog.models[model]?.apiUsd)
    try expectRates(api.standard?.short, short)
    #expect(api.standard?.long == nil)
    #expect(api.fast == nil)
    #expect(api.longContextThresholdInputTokensExclusive == nil)
    if longContext {
        #expect(api.longContextRule?.thresholdInputTokensExclusive == 272_000)
        #expect(api.longContextRule?.inputMultiplier == "2.0")
        #expect(api.longContextRule?.outputMultiplier == "1.5")
    } else {
        #expect(api.longContextRule == nil)
    }
}

private func expectRates(_ actual: APITokenRates?, _ expected: ExpectedRates) throws {
    let actual = try #require(actual)
    #expect(actual.input == expected.input)
    #expect(actual.cachedInput == expected.cachedInput)
    #expect(actual.cacheWrite == expected.cacheWrite)
    #expect(actual.output == expected.output)
}
