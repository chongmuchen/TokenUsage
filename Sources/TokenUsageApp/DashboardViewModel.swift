import AppKit
import Combine
import Foundation
import TokenUsageCore

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var sessions: [UsageTreeRow] = []
    @Published private(set) var reports: [UsageReport] = []
    @Published private(set) var loadIssues: [ReportLoadIssue] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedRoot: URL
    @Published private(set) var homes: [CodexHome]
    @Published private(set) var duplicateSessionCount = 0
    @Published private(set) var isSyncingHistory = false
    @Published private(set) var historyProgress: HistoricalSyncProgress?
    @Published private(set) var historyMessage: String?
    @Published var filter = UsageFilter()
    @Published var trendGroupMode: UsageTrendGroupMode = .all
    @Published var selectedTrendModels: Set<String> = []
    @Published var selectedTrendEfforts: Set<String> = []
    @Published var selectedTrendSpeeds: Set<UsageTrendSpeed> = []

    private let repository = ReportRepository()
    private let titleStore = ThreadTitleStore()
    private let historyGenerator = HistoricalReportGenerator()
    private let bookmarkStore: SecurityScopedBookmarkStore
    private let builder: UsageTreeBuilder
    private let trendAggregator: UsageTrendAggregator
    private var monitors: [UUID: ReportDirectoryMonitor] = [:]
    private var securityScopedURLs: [UUID: URL] = [:]
    private var loadGeneration = 0

    init() {
        let bookmarkStore = SecurityScopedBookmarkStore()
        let homes = bookmarkStore.loadHomes()
        let catalog = (try? PricingCatalog.bundled()) ?? PricingCatalog(
            schemaVersion: 1,
            catalogId: "unavailable",
            observedAt: "—",
            tokenUnit: 1_000_000,
            scope: "",
            models: [:]
        )
        self.bookmarkStore = bookmarkStore
        self.builder = UsageTreeBuilder(catalog: catalog)
        self.trendAggregator = UsageTrendAggregator(catalog: catalog)
        self.homes = homes
        self.selectedRoot = homes.first(where: \.isActive)?.rootURL
            ?? homes.first(where: \.isAvailable)?.rootURL
            ?? CodexPaths.defaultRoot
        beginSecurityScopedAccess()
        reload(startMonitor: true)
    }

    deinit {
        monitors.values.forEach { $0.stop() }
        securityScopedURLs.values.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    var filteredSessions: [UsageTreeRow] {
        sessions.filter { filter.includes($0) }
    }

    var filteredRowsWithSummary: [UsageTreeRow] {
        let filtered = filteredSessions
        guard let summary = builder.summaryRow(for: filtered) else { return filtered }
        return filtered + [summary]
    }

    var filteredTokenTotal: Int64 {
        filteredSessions.reduce(0) { $0 + $1.subtreeUsage.totalTokens }
    }

    var trendResult: UsageTrendResult {
        trendAggregator.aggregate(
            reports: reports,
            filter: UsageTrendFilter(
                startMinute: filter.startDate,
                endMinute: filter.endDate,
                selectedModels: selectedTrendModels,
                selectedEfforts: selectedTrendEfforts,
                selectedSpeeds: selectedTrendSpeeds,
                groupMode: trendGroupMode
            )
        )
    }

    var trendModelOptions: [UsageTrendModelOption] { unfilteredTrendDimensions.models }
    var trendEffortOptions: [String] { unfilteredTrendDimensions.efforts }
    var trendSpeedOptions: [UsageTrendSpeed] { unfilteredTrendDimensions.speeds }

    private var unfilteredTrendDimensions: UsageTrendDimensions {
        trendAggregator.aggregate(
            reports: reports,
            filter: UsageTrendFilter(
                startMinute: filter.startDate,
                endMinute: filter.endDate,
                groupMode: .all
            )
        ).dimensions
    }

    var statusText: String {
        if isLoading { return "正在读取报告…" }
        if let errorMessage { return errorMessage }
        if !loadIssues.isEmpty { return "已保留可用报告；\(loadIssues.count) 个文件或目录读取失败" }
        if duplicateSessionCount > 0 {
            return "显示 \(filteredSessions.count) / \(sessions.count) 个会话；已合并 \(duplicateSessionCount) 个跨目录重复会话"
        }
        return "显示 \(filteredSessions.count) / \(sessions.count) 个会话"
    }

    /// A compact description suitable for a toolbar or settings summary.
    var codexHomePathSummary: String {
        if homes.count == 1 { return homes[0].pathSummary }
        return "\(homes.count) 个 Codex Home · " + homes.map(\.pathSummary).joined(separator: " · ")
    }

    func applyPreset(_ preset: DatePreset) {
        filter.apply(preset)
    }

    func markDateRangeCustom() {
        if filter.preset != .custom { filter.preset = .custom }
    }

    /// Backwards-compatible toolbar action. Selecting a directory now adds it
    /// instead of replacing the existing Codex Home.
    func chooseCodexDirectory() {
        let panel = NSOpenPanel()
        panel.title = "添加 Codex Home"
        panel.message = "请选择一个 Codex Home 根目录（例如 ~/.codex）。"
        panel.prompt = "添加"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = selectedRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            _ = try addCodexHome(url)
        } catch {
            errorMessage = "无法添加目录：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func addCodexHome(_ url: URL, name: String? = nil) throws -> CodexHome {
        let home = try bookmarkStore.makeHome(url: url, existingHomes: homes, name: name)
        stopMonitors()
        stopSecurityScopedAccess()
        homes.append(home)
        bookmarkStore.saveHomes(homes)
        updateSelectedRoot()
        beginSecurityScopedAccess()
        reload(startMonitor: true)
        return home
    }

    @discardableResult
    func removeCodexHome(id: UUID) -> Bool {
        guard let index = homes.firstIndex(where: { $0.id == id }) else { return false }
        guard !homes[index].isDefault else {
            errorMessage = CodexHomeError.cannotRemoveDefault.localizedDescription
            return false
        }
        stopMonitors()
        stopSecurityScopedAccess()
        homes.remove(at: index)
        bookmarkStore.saveHomes(homes)
        updateSelectedRoot()
        beginSecurityScopedAccess()
        reload(startMonitor: true)
        return true
    }

    func setCodexHomeEnabled(id: UUID, enabled: Bool) {
        guard let index = homes.firstIndex(where: { $0.id == id }) else { return }
        let home = homes[index]
        guard home.isEnabled != enabled else { return }
        stopMonitors()
        stopSecurityScopedAccess()
        homes[index] = CodexHome(
            id: home.id,
            name: home.name,
            rootURL: home.rootURL,
            isDefault: home.isDefault,
            isEnabled: enabled,
            authorizationError: home.authorizationError,
            bookmarkData: home.bookmarkData
        )
        bookmarkStore.saveHomes(homes)
        updateSelectedRoot()
        beginSecurityScopedAccess()
        reload(startMonitor: true)
    }

    func reload(startMonitor: Bool = false) {
        loadGeneration += 1
        let generation = loadGeneration
        let homes = self.homes
        isLoading = true
        errorMessage = nil

        Task {
            var winners: [String: (home: CodexHome, report: UsageReport)] = [:]
            var issues: [ReportLoadIssue] = []
            var successfulHomes = 0
            var duplicates = 0

            for home in homes {
                guard home.isEnabled else { continue }
                guard home.isAvailable else {
                    issues.append(
                        homeIssue(
                            home,
                            suffix: "authorization",
                            message: home.authorizationError ?? "目录授权不可用"
                        )
                    )
                    continue
                }
                do {
                    let result = try await repository.load(from: home.rootURL)
                    successfulHomes += 1
                    issues.append(contentsOf: result.issues.map { namespacedIssue($0, home: home) })
                    for report in result.reports {
                        if let existing = winners[report.rootThreadId] {
                            duplicates += 1
                            if report.generatedAt > existing.report.generatedAt {
                                winners[report.rootThreadId] = (home, report)
                            }
                        } else {
                            winners[report.rootThreadId] = (home, report)
                        }
                    }
                } catch {
                    issues.append(homeIssue(home, suffix: "reports", message: error.localizedDescription))
                }
            }

            var titlesByHome: [UUID: [String: String]] = [:]
            let grouped = Dictionary(grouping: winners.values, by: { $0.home.id })
            for (homeID, candidates) in grouped {
                guard let home = candidates.first?.home else { continue }
                titlesByHome[homeID] = await titleStore.titles(
                    for: Set(candidates.map { $0.report.rootThreadId }),
                    codexRoot: home.rootURL
                )
            }

            let rows = winners.values.map { candidate in
                let title = titlesByHome[candidate.home.id]?[candidate.report.rootThreadId]
                return namespace(
                    builder.build(report: candidate.report, title: title),
                    homeID: candidate.home.id
                )
            }.sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }

            guard generation == loadGeneration else { return }
            reports = winners.values.map(\.report).sorted { $0.generatedAt > $1.generatedAt }
            sessions = rows
            loadIssues = issues
            duplicateSessionCount = duplicates
            isLoading = false
            lastUpdated = Date()
            if successfulHomes == 0 {
                errorMessage = homes.contains(where: \.isEnabled)
                    ? "没有可读取的 Codex Home；请检查目录授权或先同步报告。"
                    : "没有启用的 Codex Home。"
            } else {
                errorMessage = nil
            }
            if startMonitor { installMonitors() }
        }
    }

    func syncVisibleDateRange() {
        guard !isSyncingHistory else { return }
        let range = filter.minuteRange()
        let lower = range.lower
        let upper = range.upperExclusive
        let homes = self.homes.filter(\.isActive)
        isSyncingHistory = true
        historyProgress = nil
        historyMessage = nil
        stopMonitors()

        Task {
            var generated = 0
            var skipped = 0
            var failed = 0
            var unavailable = 0

            for home in homes {
                do {
                    let result = try await historyGenerator.generateMissingReports(
                        codexRoot: home.rootURL,
                        startDate: lower,
                        endDateExclusive: upper
                    ) { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.historyProgress = progress
                        }
                    }
                    generated += result.generated
                    skipped += result.skipped
                    failed += result.failed
                } catch {
                    unavailable += 1
                }
            }
            isSyncingHistory = false
            historyMessage = "历史同步完成：\(homes.count) 个目录，新增 \(generated)，已有 \(skipped)，失败 \(failed)"
            if unavailable > 0 { historyMessage? += "；\(unavailable) 个目录不可用" }
            reload(startMonitor: true)
        }
    }

    private func installMonitors() {
        stopMonitors()
        for home in homes where home.isActive {
            guard let directory = monitorDirectory(for: home) else {
                appendIssueIfNeeded(homeIssue(home, suffix: "monitor", message: "目录不存在，无法监控"))
                continue
            }
            let monitor = ReportDirectoryMonitor()
            do {
                try monitor.start(directory: directory) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard self?.homes.contains(where: { $0.id == home.id }) == true else { return }
                        // Re-arm after every event as rename/delete/revoke closes
                        // the underlying directory descriptor on some filesystems.
                        self?.reload(startMonitor: true)
                    }
                }
                monitors[home.id] = monitor
            } catch {
                appendIssueIfNeeded(homeIssue(home, suffix: "monitor", message: error.localizedDescription))
            }
        }
    }

    private func monitorDirectory(for home: CodexHome) -> URL? {
        let reports = CodexPaths.reportsDirectory(for: home.rootURL)
        let candidates = [reports, reports.deletingLastPathComponent(), home.rootURL]
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private func stopMonitors() {
        monitors.values.forEach { $0.stop() }
        monitors.removeAll()
    }

    private func beginSecurityScopedAccess() {
        stopSecurityScopedAccess()
        for home in homes where home.isActive {
            if home.rootURL.startAccessingSecurityScopedResource() {
                securityScopedURLs[home.id] = home.rootURL
            }
        }
    }

    private func stopSecurityScopedAccess() {
        securityScopedURLs.values.forEach { $0.stopAccessingSecurityScopedResource() }
        securityScopedURLs.removeAll()
    }

    private func updateSelectedRoot() {
        selectedRoot = homes.first(where: \.isActive)?.rootURL
            ?? homes.first(where: \.isAvailable)?.rootURL
            ?? CodexPaths.defaultRoot
    }

    private func namespacedIssue(_ issue: ReportLoadIssue, home: CodexHome) -> ReportLoadIssue {
        ReportLoadIssue(
            fileName: "\(home.id.uuidString)/\(issue.fileName)",
            message: "\(home.name)：\(issue.message)"
        )
    }

    private func homeIssue(_ home: CodexHome, suffix: String, message: String) -> ReportLoadIssue {
        ReportLoadIssue(
            fileName: "\(home.id.uuidString)/<\(suffix)>",
            message: "\(home.name)：\(message)"
        )
    }

    private func appendIssueIfNeeded(_ issue: ReportLoadIssue) {
        guard !loadIssues.contains(where: { $0.id == issue.id }) else { return }
        loadIssues.append(issue)
    }

    private func namespace(_ row: UsageTreeRow, homeID: UUID) -> UsageTreeRow {
        UsageTreeRow(
            id: "home:\(homeID.uuidString):\(row.id)",
            kind: row.kind,
            time: row.time,
            name: row.name,
            ownUsage: row.ownUsage,
            subtreeUsage: row.subtreeUsage,
            counts: row.counts,
            segments: row.segments,
            modelSummary: row.modelSummary,
            creditEstimate: row.creditEstimate,
            apiPriceEstimate: row.apiPriceEstimate,
            apiUSDText: row.apiUSDText,
            attribution: row.attribution,
            isProvisional: row.isProvisional,
            isLowerBound: row.isLowerBound,
            warnings: row.warnings,
            children: row.children?.map { namespace($0, homeID: homeID) }
        )
    }
}
