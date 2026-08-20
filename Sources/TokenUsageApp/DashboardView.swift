import SwiftUI
import TokenUsageCore

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var displayMode: DashboardDisplayMode = .trend

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            FilterBar(viewModel: viewModel, showsTokenRange: displayMode == .sessions)
            Divider()

            if displayMode == .trend {
                TrendFilterBar(viewModel: viewModel)
                Divider()
            }

            if viewModel.isLoading && viewModel.sessions.isEmpty {
                loadingState
            } else if let error = viewModel.errorMessage, viewModel.reports.isEmpty {
                errorState(error)
            } else {
                switch displayMode {
                case .trend:
                    TrendDashboardView(result: viewModel.trendResult)
                case .sessions:
                    if viewModel.filteredSessions.isEmpty {
                        emptyState
                    } else {
                        UsageTableView(rows: viewModel.filteredRowsWithSummary)
                    }
                }
            }

            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex Token Usage")
                    .font(.title2.weight(.semibold))
                Text(viewModel.codexHomePathSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(viewModel.codexHomePathSummary)
            }

            Spacer()

            Picker("视图", selection: $displayMode) {
                Label("趋势", systemImage: "chart.xyaxis.line").tag(DashboardDisplayMode.trend)
                Label("会话明细", systemImage: "list.bullet.rectangle").tag(DashboardDisplayMode.sessions)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            codexHomeMenu

            Button {
                viewModel.syncVisibleDateRange()
            } label: {
                Label("同步当前日期范围", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
            }
            .disabled(viewModel.isSyncingHistory)
            .help("为当前起止日期内尚无报告的会话生成本地报告；不调用模型")

            Button {
                viewModel.reload()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(viewModel.isLoading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var codexHomeMenu: some View {
        Menu {
            Section("Codex Home") {
                ForEach(viewModel.homes) { home in
                    Menu {
                        Button {
                            viewModel.setCodexHomeEnabled(id: home.id, enabled: !home.isEnabled)
                        } label: {
                            Label(home.isEnabled ? "停用" : "启用", systemImage: home.isEnabled ? "pause.circle" : "play.circle")
                        }

                        Text(home.pathSummary)

                        if let authorizationError = home.authorizationError {
                            Text("授权错误：\(authorizationError)")
                        }

                        if !home.isDefault {
                            Divider()
                            Button("移除", role: .destructive) {
                                _ = viewModel.removeCodexHome(id: home.id)
                            }
                        }
                    } label: {
                        Label(
                            home.name,
                            systemImage: home.isEnabled ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            }

            Divider()

            Button {
                viewModel.chooseCodexDirectory()
            } label: {
                Label("添加 Codex Home…", systemImage: "folder.badge.plus")
            }
        } label: {
            let activeCount = viewModel.homes.filter(\.isActive).count
            Label("\(activeCount)/\(viewModel.homes.count) 个目录", systemImage: "externaldrive.connected.to.line.below")
        }
        .fixedSize()
        .help(viewModel.codexHomePathSummary)
    }

    private var loadingState: some View {
        ContentUnavailableView {
            Label("正在读取 Codex 用量", systemImage: "chart.bar.doc.horizontal")
        } description: {
            Text("首次解析较大的历史报告可能需要一点时间。")
        } actions: {
            ProgressView().controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("无法读取用量报告", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("选择 Codex 数据目录") {
                viewModel.chooseCodexDirectory()
            }
            Button("重试") {
                viewModel.reload(startMonitor: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("没有符合条件的会话", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("调整日期或 Token 总数范围，也可以刷新报告。")
        } actions: {
            Button("最近一个月") {
                viewModel.applyPreset(.month)
                viewModel.filter.minimumTokensText = ""
                viewModel.filter.maximumTokensText = ""
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if viewModel.isLoading {
                ProgressView().controlSize(.mini)
            }
            Text(viewModel.statusText)
            if let progress = viewModel.historyProgress, viewModel.isSyncingHistory {
                Text("·")
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    .frame(width: 90)
                Text("同步 \(progress.completed)/\(progress.total)")
            } else if let historyMessage = viewModel.historyMessage {
                Text("· \(historyMessage)")
                    .lineLimit(1)
                    .help(historyMessage)
            }
            Spacer()
            if displayMode == .sessions {
                Text("筛选总计 \(TokenFormatter.exact(viewModel.filteredTokenTotal)) tokens")
                    .monospacedDigit()
            } else {
                Text("\(viewModel.trendResult.series.count) 条曲线 · \(viewModel.trendResult.days.count) 天")
            }
            if let updated = viewModel.lastUpdated {
                Text("·")
                Text("更新于 \(updated, format: .dateTime.hour().minute().second())")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 30)
    }
}

private enum DashboardDisplayMode: String, CaseIterable, Identifiable {
    case trend
    case sessions

    var id: String { rawValue }
}
