import Foundation
import Testing
@testable import TokenUsageCore

@Test("Directory monitor observes repeated atomic report writes")
func directoryMonitorObservesRepeatedAtomicWrites() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("TokenUsage-Monitor-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? fileManager.removeItem(at: directory) }

    let changes = DispatchSemaphore(value: 0)
    let monitor = ReportDirectoryMonitor()
    defer { monitor.stop() }
    try monitor.start(directory: directory) {
        changes.signal()
    }

    let report = directory.appendingPathComponent("report.json")
    try Data("{\"version\":1}".utf8).write(to: report, options: .atomic)
    #expect(changes.wait(timeout: .now() + 2) == .success)

    // Drain any additional notifications attributable to the first write and
    // require a quiet interval longer than the monitor's debounce window. The
    // next assertion therefore cannot consume a stale semaphore signal.
    while changes.wait(timeout: .now() + .milliseconds(300)) == .success {}

    try Data("{\"version\":2}".utf8).write(to: report, options: .atomic)
    #expect(changes.wait(timeout: .now() + 2) == .success)
}
