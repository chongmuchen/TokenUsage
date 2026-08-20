import SwiftUI
import TokenUsageCore

struct TrendFilterBar: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        HStack(spacing: 10) {
            TrendMultiSelectMenu(
                title: "模型",
                systemImage: "cpu",
                options: viewModel.trendModelOptions.map {
                    TrendFilterOption(id: $0.id, name: $0.displayName)
                },
                selection: $viewModel.selectedTrendModels
            )

            TrendMultiSelectMenu(
                title: "推理强度",
                systemImage: "brain.head.profile",
                options: viewModel.trendEffortOptions.map {
                    TrendFilterOption(id: $0, name: $0)
                },
                selection: $viewModel.selectedTrendEfforts
            )

            TrendMultiSelectMenu(
                title: "速度",
                systemImage: "speedometer",
                options: viewModel.trendSpeedOptions.map {
                    TrendFilterOption(id: $0, name: $0.displayName)
                },
                selection: $viewModel.selectedTrendSpeeds
            )
            .help("速度来自会话记录中的 Standard / Fast 档位；未知档位会单独保留。")

            Divider().frame(height: 24)

            Picker("曲线", selection: $viewModel.trendGroupMode) {
                Text("全部合并").tag(UsageTrendGroupMode.all)
                Text("按配置分线").tag(UsageTrendGroupMode.configuration)
            }
            .pickerStyle(.segmented)
            .frame(width: 235)
            .accessibilityLabel("趋势曲线分组")

            Spacer(minLength: 0)

            if hasSelection {
                Button("清除趋势筛选") {
                    viewModel.selectedTrendModels.removeAll()
                    viewModel.selectedTrendEfforts.removeAll()
                    viewModel.selectedTrendSpeeds.removeAll()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var hasSelection: Bool {
        !viewModel.selectedTrendModels.isEmpty
            || !viewModel.selectedTrendEfforts.isEmpty
            || !viewModel.selectedTrendSpeeds.isEmpty
    }
}

private struct TrendFilterOption<Value: Hashable>: Identifiable {
    let id: Value
    let name: String
}

private struct TrendMultiSelectMenu<Value: Hashable>: View {
    let title: String
    let systemImage: String
    let options: [TrendFilterOption<Value>]
    @Binding var selection: Set<Value>

    var body: some View {
        Menu {
            Button {
                selection.removeAll()
            } label: {
                if selection.isEmpty {
                    Label("全部", systemImage: "checkmark")
                } else {
                    Text("全部")
                }
            }

            Divider()

            ForEach(options) { option in
                Button {
                    if selection.contains(option.id) {
                        selection.remove(option.id)
                    } else {
                        selection.insert(option.id)
                    }
                } label: {
                    if selection.contains(option.id) {
                        Label(option.name, systemImage: "checkmark")
                    } else {
                        Text(option.name)
                    }
                }
            }
        } label: {
            Label(summary, systemImage: systemImage)
                .lineLimit(1)
        }
        .disabled(options.isEmpty)
        .accessibilityLabel(summary)
    }

    private var summary: String {
        guard !selection.isEmpty else { return "\(title)：全部" }
        if selection.count == 1,
           let selected = selection.first,
           let option = options.first(where: { $0.id == selected }) {
            return "\(title)：\(option.name)"
        }
        return "\(title)：\(selection.count) 项"
    }
}
