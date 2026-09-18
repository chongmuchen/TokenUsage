import AppKit
import Combine
import Foundation
import TokenUsageCore

private struct LoadedUsageCandidate: Sendable {
    let home: CodexHome
    let report: UsageReport
}

private struct HomeUsageReportGroup: Sendable {
    let home: CodexHome
    let reports: [UsageReport]
}

private struct ReportFileFingerprint: Equatable {
    let name: String
    let resourceIdentifier: String?
    let modifiedAt: Date?
    let byteCount: Int
}

private struct ReportDirectoryFingerprint: Equatable {
    let path: String
    let files: [ReportFileFingerprint]?
}

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
    @Published private(set) var weeklyLimitOverview: WeeklyLimitOverview?
    @Published private(set) var dailyQuotaTrend: DailyQuotaTrend?
    @Published private(set) var dailyQuotaHomeName: String?

    private let repository = ReportRepository()
    private let titleStore = ThreadTitleStore()
    private let historyGenerator = HistoricalReportGenerator()
    private let bookmarkStore: SecurityScopedBookmarkStore
    private let builder: UsageTreeBuilder
    private let trendAggregator: UsageTrendAggregator
    private let weeklyLimitEstimator: WeeklyLimitEstimator
    private let dailyQuotaAggregator: DailyQuotaTrendAggregator
    private var monitors: [String: ReportDirectoryMonitor] = [:]
    private var securityScopedURLs: [UUID: URL] = [:]
    private var loadGeneration = 0
    private var lastLoadedReportFingerprint: [ReportDirectoryFingerprint]?
    private var fallbackRefreshTask: Task<Void, Never>?
    private var weeklyLimitOverviewTask: Task<Void, Never>?

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
        self.weeklyLimitEstimator = WeeklyLimitEstimator(catalog: catalog)
        self.dailyQuotaAggregator = DailyQuotaTrendAggregator(catalog: catalog)
        self.homes = homes
        self.selectedRoot = homes.first(where: \.isActive)?.rootURL
            ?? homes.first(where: \.isAvailable)?.rootURL
            ?? CodexPaths.defaultRoot
        beginSecurityScopedAccess()
        reload(startMonitor: true)
        startFallbackRefresh()
    }

    deinit {
        fallbackRefreshTask?.cancel()
        weeklyLimitOverviewTask?.cancel()
        monitors.values.forEach { $0.stop() }
        securityScopedURLs.values.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    var filteredSessions: [UsageTreeRow] {
        let overlapping = sessions.filter { filter.overlapsDateRange($0) }
        switch filter.tokenScope {
        case .sessionTotal:
            return overlapping.filter { filter.includesTokenBounds($0) }
        case .selectedRange:
            let range = filter.minuteRange()
            return overlapping
                .compactMap {
                    builder.slicedRow(
                        $0,
                        lower: range.lower,
                        upperExclusive: range.upperExclusive
                    )
                }
                .filter { filter.includesTokenBounds($0) }
        }
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

    /// Quota figures stay on the same Codex Home as the weekly-limit card.
    /// The complete trend is cached after a report load, so changing a chart
    /// filter only selects its daily points instead of reparsing all reports.
    var visibleDailyQuotaPoints: [DailyQuotaPoint] {
        guard let dailyQuotaTrend else { return [] }
        let calendar = Calendar.current
        let lower = calendar.startOfDay(for: min(filter.startDate, filter.endDate))
        let upper = calendar.startOfDay(for: max(filter.startDate, filter.endDate))
        return dailyQuotaTrend.points.filter { $0.day >= lower && $0.day <= upper }
    }

    var visibleDailyQuotaHomeName: String? {
        (homes + automaticCodexHomes(excluding: homes)).filter(\.isActive).count > 1
            ? dailyQuotaHomeName
            : nil
    }

    var latestUsageObservedAt: Date? {
        reports.compactMap { report in
            report.task.usageSamples?.compactMap(\.minute).max()
                ?? report.threads
                    .flatMap(\.turns)
                    .compactMap { $0.lastUsageAt ?? $0.completedAt ?? $0.startedAt }
                    .max()
                ?? report.generatedAt
        }.max()
    }

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

    /// The exact active window backing the current weekly-limit card. Reusing
    /// this projection keeps the shortcut on the same Home/account selection
    /// as the figures shown in the dashboard.
    var currentLimitPeriod: DateInterval? {
        guard let projection = weeklyLimitOverview?.current else { return nil }
        let now = Date()
        guard projection.periodStart <= now, projection.periodEnd > now else { return nil }
        return DateInterval(start: projection.periodStart, end: projection.periodEnd)
    }

    var hasActiveLimitPeriod: Bool { currentLimitPeriod != nil }

    /// A compact description suitable for a toolbar or settings summary.
    var codexHomePathSummary: String {
        if homes.count == 1 { return homes[0].pathSummary }
        return "\(homes.count) 个 Codex Home · " + homes.map(\.pathSummary).joined(separator: " · ")
    }

    func applyPreset(_ preset: DatePreset) {
        if preset == .limitPeriod {
            guard let period = currentLimitPeriod else {
                if filter.preset == .limitPeriod { filter.preset = .custom }
                return
            }
            _ = filter.applyLimitPeriod(start: period.start, endExclusive: period.end)
            return
        }
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
        let registeredHomes = self.homes
        let automaticHomes = automaticCodexHomes(excluding: registeredHomes)
        let allSources = registeredHomes + automaticHomes
        let automaticIDs = Set(automaticHomes.map(\.id))
        // Subscribe before the first directory enumeration. If a report is
        // atomically written while an initial/retry load is in flight, the
        // monitor schedules a newer generation instead of leaving the UI on
        // the snapshot taken just before that write.
        let monitorIssues = startMonitor ? installMonitors() : []
        let loadFingerprint = reportFingerprint(for: allSources)
        isLoading = true
        errorMessage = nil

        Task {
            var winners: [String: LoadedUsageCandidate] = [:]
            var issues = monitorIssues
            var successfulHomes = 0
            var duplicates = 0

            func consider(_ candidate: LoadedUsageCandidate) {
                if let existing = winners[candidate.report.rootThreadId] {
                    duplicates += 1
                    if candidate.report.generatedAt > existing.report.generatedAt {
                        winners[candidate.report.rootThreadId] = candidate
                    }
                } else {
                    winners[candidate.report.rootThreadId] = candidate
                }
            }

            for home in allSources {
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
                var loadedSource = false
                var ordinaryLoadError: Error?

                do {
                    let result = try await repository.load(from: home.rootURL)
                    loadedSource = true
                    issues.append(contentsOf: result.issues.map { namespacedIssue($0, home: home) })
                    for report in result.reports {
                        consider(LoadedUsageCandidate(home: home, report: report))
                    }
                } catch {
                    ordinaryLoadError = error
                }

                if loadedSource {
                    successfulHomes += 1
                } else if let ordinaryLoadError, !automaticIDs.contains(home.id) {
                    issues.append(homeIssue(
                        home,
                        suffix: "reports",
                        message: ordinaryLoadError.localizedDescription
                    ))
                }
            }

            var metadataByHome: [UUID: [String: ThreadDisplayMetadata]] = [:]
            let grouped = Dictionary(grouping: winners.values, by: { $0.home.id })
            for (homeID, candidates) in grouped {
                guard let home = candidates.first?.home else { continue }
                metadataByHome[homeID] = await titleStore.metadata(
                    for: Set(candidates.map { $0.report.rootThreadId }),
                    codexRoot: home.rootURL
                )
            }

            let rows = winners.values.map { candidate in
                let metadata = metadataByHome[candidate.home.id]?[candidate.report.rootThreadId]
                let title = candidate.report.displayName
                    ?? metadata?.title
                return namespace(
                    builder.build(
                        report: candidate.report,
                        title: title,
                        projectName: metadata?.projectName,
                        projectPath: metadata?.projectPath
                    ),
                    homeID: candidate.home.id
                )
            }.sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }

            guard generation == loadGeneration else { return }
            let loadedReports = winners.values.map(\.report).sorted { $0.generatedAt > $1.generatedAt }
            let weeklyReportGroups = grouped.values.compactMap { candidates -> HomeUsageReportGroup? in
                guard let home = candidates.first?.home else { return nil }
                return HomeUsageReportGroup(
                    home: home,
                    reports: candidates.map(\.report).sorted { $0.generatedAt > $1.generatedAt }
                )
            }
            reports = loadedReports
            sessions = rows
            loadIssues = issues
            duplicateSessionCount = duplicates
            lastLoadedReportFingerprint = loadFingerprint
            isLoading = false
            lastUpdated = Date()
            if successfulHomes == 0 {
                errorMessage = registeredHomes.contains(where: \.isEnabled)
                    ? "没有可读取的 Codex Home；请检查目录授权或先同步报告。"
                    : "没有启用的 Codex Home。"
            } else {
                errorMessage = nil
            }
            updateWeeklyLimitOverview(reportGroups: weeklyReportGroups, generation: generation)
        }
    }

    /// Weekly-limit aggregation intentionally runs once per completed report
    /// load, outside the main actor. Each Codex Home is estimated separately
    /// so one account's quota percentage is never paired with another Home's
    /// Token/API-USD usage. Chart filters never affect these estimates.
    private func updateWeeklyLimitOverview(
        reportGroups: [HomeUsageReportGroup],
        generation: Int
    ) {
        weeklyLimitOverviewTask?.cancel()
        let estimator = weeklyLimitEstimator
        let quotaAggregator = dailyQuotaAggregator
        weeklyLimitOverviewTask = Task.detached(priority: .utility) { [weak self] in
            let now = Date()
            var overviews: [(group: HomeUsageReportGroup, overview: WeeklyLimitOverview)] = []
            for group in reportGroups {
                guard !Task.isCancelled else { return }
                let candidate = estimator.overview(
                    reports: group.reports,
                    now: now,
                    historyLimit: WeeklyLimitEstimator.maximumHistoryPeriods
                )
                if candidate.current != nil || !candidate.history.isEmpty {
                    overviews.append((group, candidate))
                }
            }
            guard !Task.isCancelled else { return }
            let selected = overviews.max { lhs, rhs in
                let lhs = lhs.overview
                let rhs = rhs.overview
                let lhsHasCurrent = lhs.current != nil
                let rhsHasCurrent = rhs.current != nil
                if lhsHasCurrent != rhsHasCurrent {
                    return !lhsHasCurrent && rhsHasCurrent
                }
                let lhsDate = lhs.current?.observationCutoff
                    ?? lhs.history.first?.observationCutoff
                    ?? .distantPast
                let rhsDate = rhs.current?.observationCutoff
                    ?? rhs.history.first?.observationCutoff
                    ?? .distantPast
                return lhsDate < rhsDate
            }
            let overview = selected?.overview
                ?? WeeklyLimitOverview(current: nil, history: [], computedAt: now)
            let quotaTrend: DailyQuotaTrend?
            if let selected {
                let reports = selected.group.reports
                var firstReportTime: Date?
                var lastReportTime: Date?
                func include(_ date: Date?) {
                    guard let date else { return }
                    firstReportTime = min(firstReportTime ?? date, date)
                    lastReportTime = max(lastReportTime ?? date, date)
                }
                for report in reports {
                    for observation in report.rateLimitSnapshots ?? [] {
                        include(observation.observedAt)
                    }
                    for observation in report.rateLimitObservations ?? [] {
                        include(observation.observedAt)
                    }
                    for sample in report.task.usageSamples ?? [] {
                        include(sample.minute)
                    }
                    for thread in report.threads {
                        for turn in thread.turns {
                            include(turn.effectiveStart)
                        }
                    }
                }
                let firstDate = firstReportTime ?? now
                let lastDate = max(lastReportTime ?? now, now)
                // Include the day before the first report as a baseline when
                // one exists. The aggregator decides whether it is observed.
                let startDate = Calendar.current.date(byAdding: .day, value: -1, to: firstDate)
                    ?? firstDate
                quotaTrend = quotaAggregator.aggregate(
                    reports: reports,
                    startDate: startDate,
                    endDate: lastDate,
                    limitID: overview.current?.snapshot.limitId
                        ?? overview.history.first?.snapshot.limitId
                )
            } else {
                quotaTrend = nil
            }
            await MainActor.run { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                self.weeklyLimitOverview = overview
                self.dailyQuotaTrend = quotaTrend
                self.dailyQuotaHomeName = selected?.group.home.name
                if self.filter.preset == .limitPeriod {
                    self.applyPreset(.limitPeriod)
                }
                self.weeklyLimitOverviewTask = nil
            }
        }
    }

    /// Reconciles the UI with disk without rereading every report on every
    /// timer tick. A changed metadata fingerprint means a vnode event was
    /// missed (for example during process startup), so the retry also repairs
    /// the directory subscription before loading.
    func refreshIfReportsChanged() {
        guard !isLoading else { return }
        let sources = homes + automaticCodexHomes(excluding: homes)
        let currentFingerprint = reportFingerprint(for: sources)
        guard let lastLoadedReportFingerprint else {
            reload(startMonitor: true)
            return
        }
        guard currentFingerprint != lastLoadedReportFingerprint else { return }
        reload(startMonitor: true)
    }

    private func startFallbackRefresh() {
        fallbackRefreshTask?.cancel()
        fallbackRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                guard let self else { return }
                self.refreshIfReportsChanged()
            }
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
            historyMessage = "历史同步完成：\(homes.count) 个目录，新建或重建 \(generated)，已是最新 \(skipped)，失败 \(failed)"
            if unavailable > 0 { historyMessage? += "；\(unavailable) 个目录不可用" }
            reload(startMonitor: true)
        }
    }

    @discardableResult
    private func installMonitors() -> [ReportLoadIssue] {
        stopMonitors()
        let sources = homes.filter(\.isActive) + automaticCodexHomes(excluding: homes)
        var monitoredPaths = Set<String>()
        var issues: [ReportLoadIssue] = []

        func install(key: String, directory: URL, home: CodexHome) {
            let path = directory.standardizedFileURL.path(percentEncoded: false)
            guard monitoredPaths.insert(path).inserted else { return }
            let monitor = ReportDirectoryMonitor()
            do {
                try monitor.start(directory: directory) { [weak self] in
                    Task { @MainActor [weak self] in
                        // Ordinary report writes do not invalidate the open
                        // directory descriptor. Keeping the existing monitor
                        // closes the gap previously created by tearing it down
                        // and recreating it for every file event.
                        self?.reload()
                    }
                }
                monitors[key] = monitor
            } catch {
                issues.append(homeIssue(home, suffix: "monitor", message: error.localizedDescription))
            }
        }

        for home in sources where home.isActive {
            guard let directory = monitorDirectory(for: home) else {
                issues.append(homeIssue(home, suffix: "monitor", message: "目录不存在，无法监控"))
                continue
            }
            install(key: "reports:\(home.id.uuidString)", directory: directory, home: home)
        }
        return issues
    }

    private func reportFingerprint(for sources: [CodexHome]) -> [ReportDirectoryFingerprint] {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .fileSizeKey,
            .isRegularFileKey
        ]
        var paths = Set<String>()
        var fingerprints: [ReportDirectoryFingerprint] = []

        for home in sources where home.isActive {
            let directory = CodexPaths.reportsDirectory(for: home.rootURL).standardizedFileURL
            let path = directory.path(percentEncoded: false)
            guard paths.insert(path).inserted else { continue }

            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else {
                fingerprints.append(ReportDirectoryFingerprint(path: path, files: nil))
                continue
            }

            let files = urls.compactMap { url -> ReportFileFingerprint? in
                guard url.pathExtension.lowercased() == "json",
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true else { return nil }
                return ReportFileFingerprint(
                    name: url.lastPathComponent,
                    resourceIdentifier: values.fileResourceIdentifier.map { String(reflecting: $0) },
                    modifiedAt: values.contentModificationDate,
                    byteCount: values.fileSize ?? 0
                )
            }.sorted { $0.name < $1.name }
            fingerprints.append(ReportDirectoryFingerprint(path: path, files: files))
        }

        return fingerprints.sorted { $0.path < $1.path }
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

    /// Product-owned Codex Homes may be offered as convenience inputs, but all
    /// of them are loaded through the same token-usage/reports repository.
    private func automaticCodexHomes(excluding registered: [CodexHome]) -> [CodexHome] {
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [(UUID, URL)] = [
            (
                UUID(uuidString: "00000000-0000-0000-0000-00000000c001")!,
                userHome
                    .appendingPathComponent("Library/Containers/com.marscmchen.CoWork.mac/Data/Library/Application Support/CoWork", isDirectory: true)
                    .appendingPathComponent("CodexImageProvider", isDirectory: true)
            ),
            (
                UUID(uuidString: "00000000-0000-0000-0000-00000000c002")!,
                userHome
                    .appendingPathComponent("Library/Application Support/CoWork", isDirectory: true)
                    .appendingPathComponent("CodexImageProvider", isDirectory: true)
            )
        ]
        let registeredPaths = Set(registered.map { codexHomePathKey($0.rootURL) })
        var seenPaths = registeredPaths
        return candidates.compactMap { id, candidate in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            let root = canonicalCodexRoot(candidate)
            let key = codexHomePathKey(root)
            guard seenPaths.insert(key).inserted else { return nil }
            return CodexHome(
                id: id,
                name: "CoWork Codex Home",
                rootURL: root,
                isDefault: false,
                isEnabled: true,
                authorizationError: nil,
                bookmarkData: nil
            )
        }
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
            endTime: row.endTime,
            name: row.name,
            projectName: row.projectName,
            projectPath: row.projectPath,
            ownUsage: row.ownUsage,
            subtreeUsage: row.subtreeUsage,
            counts: row.counts,
            imageGenerations: row.imageGenerations,
            segments: row.segments,
            ownSegments: row.ownSegments,
            ownUsageSamples: row.ownUsageSamples,
            subtreeUsageSamples: row.subtreeUsageSamples,
            usageSampleFallbackTime: row.usageSampleFallbackTime,
            modelSummary: row.modelSummary,
            creditEstimate: row.creditEstimate,
            apiPriceEstimate: row.apiPriceEstimate,
            apiUSDText: row.apiUSDText,
            attribution: row.attribution,
            isProvisional: row.isProvisional,
            isLowerBound: row.isLowerBound,
            isUsageApproximate: row.isUsageApproximate,
            isOwnUsageApproximate: row.isOwnUsageApproximate,
            pricingSuppressed: row.pricingSuppressed,
            warnings: row.warnings,
            children: row.children?.map { namespace($0, homeID: homeID) }
        )
    }
}
