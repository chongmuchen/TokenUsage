import CSQLite
import Darwin
import Foundation

public struct HistoricalSyncProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    public let generated: Int
    public let failed: Int

    public init(completed: Int, total: Int, generated: Int, failed: Int) {
        self.completed = completed
        self.total = total
        self.generated = generated
        self.failed = failed
    }
}

public struct HistoricalSyncResult: Equatable, Sendable {
    public let discovered: Int
    public let generated: Int
    public let skipped: Int
    public let failed: Int

    public init(discovered: Int, generated: Int, skipped: Int, failed: Int) {
        self.discovered = discovered
        self.generated = generated
        self.skipped = skipped
        self.failed = failed
    }
}

public enum HistoricalSyncError: LocalizedError {
    case noStateDatabase
    case databaseUnavailable
    case queryUnavailable
    case queryFailed(String)
    case missingParser
    case missingPython

    public var errorDescription: String? {
        switch self {
        case .noStateDatabase:
            "Codex 数据目录中没有 state_*.sqlite。"
        case .databaseUnavailable:
            "无法以只读方式打开 Codex 状态数据库。"
        case .queryUnavailable:
            "当前 Codex 状态数据库格式不受支持。"
        case .queryFailed(let reason):
            "读取 Codex 状态数据库失败：\(reason)"
        case .missingParser:
            "应用资源中缺少本地 token 解析器。"
        case .missingPython:
            "本机没有 /usr/bin/python3，无法回填历史报告。"
        }
    }
}

/// Runs the bundled, model-free parser for user tasks whose report is missing
/// or no longer safe to reuse. It never invokes Codex or an OpenAI endpoint.
public actor HistoricalReportGenerator {
    private let parserTimeout: TimeInterval
    private let currentCatalogID: String?

    public init(parserTimeout: TimeInterval = 45, currentCatalogID: String? = nil) {
        self.parserTimeout = min(max(parserTimeout, 0.1), 300)
        self.currentCatalogID = currentCatalogID ?? (try? PricingCatalog.bundled())?.catalogId
    }

    public func generateMissingReports(
        codexRoot: URL,
        startDate: Date,
        endDateExclusive: Date,
        progress: @escaping @Sendable (HistoricalSyncProgress) -> Void
    ) async throws -> HistoricalSyncResult {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw HistoricalSyncError.missingPython
        }
        guard let script = TokenUsageResources.url(forResource: "token_usage", withExtension: "py") else {
            throw HistoricalSyncError.missingParser
        }

        let sessionIDs = try userSessionIDs(
            codexRoot: codexRoot,
            startDate: startDate,
            endDateExclusive: endDateExclusive
        )
        let reportsDirectory = CodexPaths.reportsDirectory(for: codexRoot)
        var generated = 0
        var skipped = 0
        var failed = 0

        for (index, sessionID) in sessionIDs.enumerated() {
            try Task.checkCancellation()
            let reportURL = reportsDirectory.appendingPathComponent(sessionID).appendingPathExtension("json")
            if reusableExistingReport(at: reportURL, expectedRootID: sessionID) {
                skipped += 1
            } else if try await runParser(script: script, codexRoot: codexRoot, sessionID: sessionID) {
                generated += 1
            } else {
                failed += 1
            }
            progress(
                HistoricalSyncProgress(
                    completed: index + 1,
                    total: sessionIDs.count,
                    generated: generated,
                    failed: failed
                )
            )
        }

        return HistoricalSyncResult(
            discovered: sessionIDs.count,
            generated: generated,
            skipped: skipped,
            failed: failed
        )
    }

    private func userSessionIDs(
        codexRoot: URL,
        startDate: Date,
        endDateExclusive: Date
    ) throws -> [String] {
        let databaseURL = try newestStateDatabase(in: codexRoot)
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            if database != nil { sqlite3_close_v2(database) }
            throw HistoricalSyncError.databaseUnavailable
        }
        defer { sqlite3_close_v2(database) }
        sqlite3_busy_timeout(database, 200)

        let sql = """
            SELECT id
            FROM threads
            WHERE thread_source = 'user'
              AND created_at < ?
              AND updated_at >= ?
            ORDER BY updated_at DESC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HistoricalSyncError.queryUnavailable
        }
        defer { sqlite3_finalize(statement) }

        guard
            sqlite3_bind_double(statement, 1, endDateExclusive.timeIntervalSince1970) == SQLITE_OK,
            sqlite3_bind_double(statement, 2, startDate.timeIntervalSince1970) == SQLITE_OK
        else {
            throw HistoricalSyncError.queryFailed(databaseError(database))
        }
        var result: [String] = []
        while true {
            let stepResult = sqlite3_step(statement)
            switch stepResult {
            case SQLITE_ROW:
                guard let text = sqlite3_column_text(statement, 0) else { continue }
                result.append(String(cString: text))
            case SQLITE_DONE:
                return result
            default:
                throw HistoricalSyncError.queryFailed(databaseError(database))
            }
        }
    }

    private func newestStateDatabase(in codexRoot: URL) throws -> URL {
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: codexRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let databases = candidates.filter {
            $0.pathExtension == "sqlite"
                && $0.deletingPathExtension().lastPathComponent.range(
                    of: #"^state_[0-9]+$"#,
                    options: .regularExpression
                ) != nil
        }
        guard let newest = databases.max(by: { databaseSortKey($0) < databaseSortKey($1) }) else {
            throw HistoricalSyncError.noStateDatabase
        }
        return newest
    }

    private func databaseSortKey(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let version = Int(stem.split(separator: "_").last ?? "") ?? -1
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        return String(format: "%020d-%020.0f", version, modified)
    }

    private func reusableExistingReport(at url: URL, expectedRootID: String) -> Bool {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard
            let values = try? url.resourceValues(forKeys: keys),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileSize = values.fileSize,
            fileSize > 0,
            Int64(fileSize) <= ReportRepository.maximumReportBytes,
            let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
            let report = try? UsageReportDecoder.decode(data)
        else { return false }
        return !Self.needsRefresh(
            report: report,
            expectedRootID: expectedRootID,
            currentCatalogID: currentCatalogID
        )
    }

    /// A report is rebuilt when a newer parser can add minute samples or
    /// rate-limit observations, turn an observed lower bound or a suppressed
    /// estimate into a complete result, or when bundled public prices changed.
    /// Kept internal so the policy can be regression tested without touching a
    /// user's Codex Home.
    static func needsRefresh(
        report: UsageReport,
        expectedRootID: String,
        currentCatalogID: String?
    ) -> Bool {
        guard report.rootThreadId == expectedRootID else { return true }
        guard report.task.usageSamples != nil else { return true }
        guard report.rateLimitSnapshots != nil else { return true }
        guard report.rateLimitObservations != nil else { return true }
        guard !report.task.usageIsLowerBound else { return true }
        guard report.task.cost.costSuppressed != true else { return true }

        guard let currentCatalogID else { return false }
        return report.pricingCatalog.catalogId != currentCatalogID
            || report.task.cost.catalogId != currentCatalogID
    }

    private func runParser(script: URL, codexRoot: URL, sessionID: String) async throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "--session", sessionID, "--compact"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_TOKEN_USAGE_CODEX_DIR"] = codexRoot.path
        environment["CODEX_TOKEN_USAGE_SKIP_LATEST"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }

        let deadline = Date().addingTimeInterval(parserTimeout)
        while process.isRunning {
            if Task.isCancelled {
                stop(process)
                throw CancellationError()
            }
            if Date() >= deadline {
                stop(process)
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                stop(process)
                throw error
            }
        }
        return process.terminationReason == .exit && process.terminationStatus == 0
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let graceDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private func databaseError(_ database: OpaquePointer) -> String {
        guard let message = sqlite3_errmsg(database) else { return "SQLite error" }
        return String(cString: message)
    }
}
