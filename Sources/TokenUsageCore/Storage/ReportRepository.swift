import Darwin
import Foundation

public struct ReportLoadIssue: Identifiable, Equatable, Sendable {
    public let id: String
    public let fileName: String
    public let message: String

    public init(fileName: String, message: String) {
        self.id = fileName
        self.fileName = fileName
        self.message = message
    }
}

public struct ReportLoadResult: Sendable {
    public let reports: [UsageReport]
    public let issues: [ReportLoadIssue]
}

public enum CodexPaths {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public static func reportsDirectory(for selectedURL: URL) -> URL {
        let standardized = selectedURL.standardizedFileURL
        if standardized.lastPathComponent == "reports" {
            return standardized
        }
        if standardized.lastPathComponent == "token-usage" {
            return standardized.appendingPathComponent("reports", isDirectory: true)
        }
        return standardized
            .appendingPathComponent("token-usage", isDirectory: true)
            .appendingPathComponent("reports", isDirectory: true)
    }

    public static func codexRoot(for selectedURL: URL) -> URL {
        let standardized = selectedURL.standardizedFileURL
        if standardized.lastPathComponent == "reports" {
            return standardized.deletingLastPathComponent().deletingLastPathComponent()
        }
        if standardized.lastPathComponent == "token-usage" {
            return standardized.deletingLastPathComponent()
        }
        return standardized
    }
}

public actor ReportRepository {
    public static let maximumReportBytes: Int64 = 64 * 1024 * 1024

    public init() {}

    public func load(from selectedURL: URL) throws -> ReportLoadResult {
        let reportsURL = CodexPaths.reportsDirectory(for: selectedURL)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: reportsURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw UsageReportError.missingReportsDirectory
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .nameKey
        ]
        let files = try FileManager.default.contentsOfDirectory(
            at: reportsURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        var reports: [UsageReport] = []
        var issues: [ReportLoadIssue] = []
        for file in files where file.pathExtension.lowercased() == "json" && file.lastPathComponent != "latest.json" {
            do {
                let values = try file.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw UsageReportError.invalidFile("不是普通文件或是符号链接")
                }
                guard Int64(values.fileSize ?? 0) <= Self.maximumReportBytes else {
                    throw UsageReportError.invalidFile("超过 64 MiB 安全上限")
                }
                let data = try Data(contentsOf: file, options: [.mappedIfSafe])
                let report = try UsageReportDecoder.decode(data)
                guard file.deletingPathExtension().lastPathComponent == report.rootThreadId else {
                    throw UsageReportError.invalidFile("文件名与 root_thread_id 不一致")
                }
                reports.append(report)
            } catch {
                issues.append(ReportLoadIssue(fileName: file.lastPathComponent, message: error.localizedDescription))
            }
        }
        reports.sort { $0.generatedAt > $1.generatedAt }
        return ReportLoadResult(reports: reports, issues: issues)
    }
}

public final class ReportDirectoryMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TokenUsage.ReportDirectoryMonitor")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queueValue: UInt8 = 1
    private var source: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?

    public init() {
        queue.setSpecific(key: queueKey, value: queueValue)
    }

    deinit {
        stop()
    }

    public func start(directory: URL, onChange: @escaping @Sendable () -> Void) throws {
        try syncOnQueue {
            stopOnQueue()

            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .attrib, .revoke],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.debounceWorkItem?.cancel()
                let item = DispatchWorkItem(block: onChange)
                self.debounceWorkItem = item
                self.queue.asyncAfter(deadline: .now() + .milliseconds(180), execute: item)
            }
            source.setCancelHandler {
                close(descriptor)
            }
            self.source = source
            source.resume()
        }
    }

    public func stop() {
        syncOnQueue {
            stopOnQueue()
        }
    }

    private func stopOnQueue() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        source?.cancel()
        source = nil
    }

    private func syncOnQueue<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == queueValue {
            return try operation()
        }
        return try queue.sync(execute: operation)
    }
}
