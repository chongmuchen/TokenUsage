import Foundation
import Testing
@testable import TokenUsageCore

@Test("CoWork total deltas import once with cache-write, configuration, prices, and minute samples")
func coworkExchangeImportsWithoutDoubleCounting() async throws {
    let fixture = try CoWorkImportFixture()
    defer { fixture.remove() }

    let recordID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let json = coworkExchangeJSON(recordID: recordID).replacingOccurrences(
        of: "\"billing\":null",
        with: """
        \"billing\":{
          \"estimated_usage_credits_micros\":1250000,
          \"estimated_usage_usd_micros\":null,
          \"groups\":[{
            \"model\":\"gpt-5.6-sol\",\"effort\":\"high\",\"speed\":\"standard\",
            \"estimated_usage_credits_micros\":1250000,
            \"net_new_input_tokens\":185,\"cached_input_tokens\":50,
            \"input_tokens\":250,\"output_tokens\":25,\"total_tokens\":275
          }]
        }
        """
    )
    try fixture.write(recordID: recordID, json: json)
    let result = try await CoWorkUsageImportRepository().load(from: fixture.root)
    let imported = try #require(result.reports.first)
    let report = imported.report

    #expect(result.directoryExists)
    #expect(result.reports.count == 1)
    #expect(result.issues.isEmpty)
    #expect(imported.title == "CoWork")
    #expect(report.rootThreadId == "cowork:\(recordID.uuidString.lowercased())")
    #expect(report.task.usage.inputTokens == 250)
    #expect(report.task.usage.cachedInputTokens == 50)
    #expect(report.task.usage.cacheWriteInputTokens == 15)
    #expect(report.task.usage.outputTokens == 25)
    #expect(report.task.usage.reasoningOutputTokens == 5)
    #expect(report.task.usage.totalTokens == 275)
    #expect(report.task.usageSamples?.count == 2)
    #expect(report.task.usageIsLowerBound == false)
    #expect(report.task.counts.imageGenerations == 1)
    #expect(report.task.cost.preferredCreditsText != nil)
    #expect(report.task.cost.preferredCreditsText == "1.25")
    #expect(report.task.cost.preferredAPIUSDText != nil)

    let firstMinute = try #require(report.task.usageSamples?.first?.minute)
    let trend = try UsageTrendAggregator(catalog: PricingCatalog.bundled()).aggregate(
        reports: [report],
        filter: UsageTrendFilter(startMinute: firstMinute, endMinute: firstMinute)
    )
    let series = try #require(trend.series.first)
    #expect(series.summary.tokens.totalTokens == 110)
    #expect(series.summary.tokens.cacheWriteInputTokens == 10)

    let tree = try UsageTreeBuilder(catalog: PricingCatalog.bundled())
        .build(report: report, title: imported.title)
    #expect(tree.name == "CoWork")
    #expect(tree.children?.count == 1)
    #expect(tree.creditEstimate?.amount != nil)
    #expect(tree.apiPriceEstimate?.amount != nil)
}

@Test("CoWork running records stay lower bounds")
func coworkRunningExchangeIsProvisional() async throws {
    let fixture = try CoWorkImportFixture()
    defer { fixture.remove() }
    let recordID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    let json = coworkExchangeJSON(recordID: recordID)
        .replacingOccurrences(of: "\"ended_at\":\"2026-08-20T10:02:00Z\",", with: "\"ended_at\":null,")
        .replacingOccurrences(of: "\"status\":\"completed\"", with: "\"status\":\"running\"")
    try fixture.write(recordID: recordID, json: json)

    let result = try await CoWorkUsageImportRepository().load(from: fixture.root)
    let report = try #require(result.reports.first?.report)
    #expect(report.task.usageIsLowerBound)
    #expect(report.currentTurn.usageIsProvisional)
    #expect(report.threads.first?.activeTurnCount == 1)
}

@Test("CoWork malformed or symlinked exchange files fail soft")
func coworkExchangeRejectsMismatchedAccountingAndSymlinks() async throws {
    let fixture = try CoWorkImportFixture()
    defer { fixture.remove() }
    let recordID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
    let malformed = coworkExchangeJSON(recordID: recordID)
        .replacingOccurrences(of: "\"total_tokens\":275", with: "\"total_tokens\":276")
    try fixture.write(recordID: recordID, json: malformed)

    let other = fixture.directory.appendingPathComponent("source.json")
    try Data(coworkExchangeJSON(recordID: recordID).utf8).write(to: other)
    let linkID = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
    let link = fixture.directory.appendingPathComponent(linkID.uuidString.lowercased() + ".json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)

    let result = try await CoWorkUsageImportRepository().load(from: fixture.root)
    #expect(result.reports.isEmpty)
    #expect(result.issues.count >= 2)
}

@Test("CoWork counter anomalies remain lower bounds and suppress prices")
func coworkExchangeSuppressesCostAfterCounterAnomaly() async throws {
    let fixture = try CoWorkImportFixture()
    defer { fixture.remove() }
    let recordID = UUID(uuidString: "12121212-3434-5656-7878-909090909090")!
    let json = coworkExchangeJSON(recordID: recordID)
        .replacingOccurrences(
            of: "\"completeness\":{\"usage\":\"observed\",\"cache_write\":\"observed\"}",
            with: "\"completeness\":{\"usage\":\"lower_bound\",\"cache_write\":\"lower_bound\",\"cost_suppressed\":\"true\"}"
        )
    try fixture.write(recordID: recordID, json: json)

    let result = try await CoWorkUsageImportRepository().load(from: fixture.root)
    let report = try #require(result.reports.first?.report)
    #expect(report.task.usageIsLowerBound)
    #expect(report.currentTurn.usageIsProvisional)
    #expect(report.task.cost.costSuppressed == true)
    #expect(report.task.cost.preferredCreditsText == nil)
    #expect(report.task.cost.preferredAPIUSDText == nil)
}

@Test("CoWork nonzero usage never accepts an unsettled zero-credit response")
func coworkExchangeIgnoresUnsettledZeroBilling() async throws {
    let fixture = try CoWorkImportFixture()
    defer { fixture.remove() }
    let recordID = UUID(uuidString: "abababab-cdcd-efef-1212-343434343434")!
    let json = coworkExchangeJSON(recordID: recordID).replacingOccurrences(
        of: "\"billing\":null",
        with: "\"billing\":{\"estimated_usage_credits_micros\":0,\"estimated_usage_usd_micros\":0,\"groups\":[]}"
    )
    try fixture.write(recordID: recordID, json: json)

    let result = try await CoWorkUsageImportRepository().load(from: fixture.root)
    let report = try #require(result.reports.first?.report)
    #expect(report.task.cost.preferredCreditsText != nil)
    #expect(report.task.cost.preferredCreditsText != "0")
    #expect(report.warnings.contains { $0.contains("尚未结算") })
}

@Test("CoWork importer rejects every intermediate directory symlink")
func coworkExchangeRejectsIntermediateDirectorySymlink() async throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("TokenUsage-CoWork-Symlink-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent("home", isDirectory: true)
    let outside = base.appendingPathComponent("outside", isDirectory: true)
    let externalImports = outside
        .appendingPathComponent("imports/cowork/v1", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: externalImports, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("token-usage", isDirectory: true),
        withDestinationURL: outside
    )
    let recordID = UUID(uuidString: "10101010-2020-3030-4040-505050505050")!
    try Data(coworkExchangeJSON(recordID: recordID).utf8).write(
        to: externalImports.appendingPathComponent(recordID.uuidString.lowercased() + ".json")
    )

    do {
        _ = try await CoWorkUsageImportRepository().load(from: root)
        Issue.record("expected the importer to reject an intermediate directory symlink")
    } catch {
        #expect(error is CoWorkUsageImportError)
    }
}

private struct CoWorkImportFixture {
    let root: URL
    let directory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenUsage-CoWork-\(UUID().uuidString)", isDirectory: true)
        directory = CoWorkUsageImportRepository.importsDirectory(for: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(recordID: UUID, json: String) throws {
        let file = directory.appendingPathComponent(recordID.uuidString.lowercased() + ".json")
        try Data(json.utf8).write(to: file, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func coworkExchangeJSON(recordID: UUID) -> String {
    """
    {
      "schema_version":1,
      "producer":"com.marscmchen.CoWork",
      "generated_at":"2026-08-20T10:02:00Z",
      "record_id":"\(recordID.uuidString.lowercased())",
      "session":{
        "id":"thread-fixture","title":"CoWork",
        "started_at":"2026-08-20T10:00:00Z",
        "ended_at":"2026-08-20T10:02:00Z",
        "status":"completed"
      },
      "usage":{
        "input_tokens":250,"cached_input_tokens":50,"cache_write_input_tokens":15,
        "output_tokens":25,"reasoning_output_tokens":5,"total_tokens":275
      },
      "samples":[
        {
          "id":"sample-1","occurred_at":"2026-08-20T10:00:30Z",
          "model":"gpt-5.6-sol","effort":"high","tier":"default",
          "tier_source":"thread_start_response","long_context":false,"request_count":1,
          "usage":{
            "input_tokens":100,"cached_input_tokens":20,"cache_write_input_tokens":10,
            "output_tokens":10,"reasoning_output_tokens":2,"total_tokens":110
          }
        },
        {
          "id":"sample-2","occurred_at":"2026-08-20T10:01:30Z",
          "model":"gpt-5.6-sol","effort":"high","tier":"default",
          "tier_source":"thread_start_response","long_context":false,"request_count":1,
          "usage":{
            "input_tokens":150,"cached_input_tokens":30,"cache_write_input_tokens":5,
            "output_tokens":15,"reasoning_output_tokens":3,"total_tokens":165
          }
        }
      ],
      "counts":{"image_generations":1},
      "billing":null,
      "completeness":{"usage":"observed","cache_write":"observed"},
      "warnings":[]
    }
    """
}
