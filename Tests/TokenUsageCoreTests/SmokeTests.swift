import Testing
@testable import TokenUsageCore

@Test("Token total equals input plus output")
func tokenTotalInvariant() {
    let usage = TokenUsage(inputTokens: 10, outputTokens: 4)
    #expect(usage.totalTokens == 14)
}
