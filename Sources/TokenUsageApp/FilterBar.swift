import SwiftUI
import TokenUsageCore

struct FilterBar: View {
    @ObservedObject var viewModel: DashboardViewModel
    var showsTokenRange = true

    private let presets: [DatePreset] = [.today, .week, .month]

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                ForEach(presets) { preset in
                    Button(preset.rawValue) {
                        viewModel.applyPreset(preset)
                    }
                    .buttonStyle(PresetButtonStyle(isSelected: viewModel.filter.preset == preset))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("快捷日期范围")

            Divider().frame(height: 24)

            DatePicker(
                "开始",
                selection: dateBinding(\.startDate),
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .fixedSize()

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)

            DatePicker(
                "结束",
                selection: dateBinding(\.endDate),
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .fixedSize()

            if showsTokenRange {
                Picker("Token 口径", selection: $viewModel.filter.tokenScope) {
                    Text("会话总量").tag(UsageTokenScope.sessionTotal)
                    Text("时段用量").tag(UsageTokenScope.selectedRange)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("会话 Token 口径")
                .help("会话总量显示完整会话用量；时段用量按 token_count 的观测分钟统计筛选时间段内的用量。")

                Divider().frame(height: 24)

                HStack(spacing: 6) {
                    Text(tokenRangeLabel)
                        .foregroundStyle(.secondary)
                    TextField("最少，如 100k", text: $viewModel.filter.minimumTokensText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 105)
                        .accessibilityLabel("最少 Token")
                    Text("–").foregroundStyle(.tertiary)
                    TextField("最多，如 10M", text: $viewModel.filter.maximumTokensText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 105)
                        .accessibilityLabel("最多 Token")
                }
            }

            Spacer(minLength: 0)

            if showsTokenRange
                && (!viewModel.filter.minimumTokensText.isEmpty || !viewModel.filter.maximumTokensText.isEmpty) {
                Button("清除 Token 范围") {
                    viewModel.filter.minimumTokensText = ""
                    viewModel.filter.maximumTokensText = ""
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func dateBinding(_ keyPath: WritableKeyPath<UsageFilter, Date>) -> Binding<Date> {
        Binding(
            get: { viewModel.filter[keyPath: keyPath] },
            set: { value in
                viewModel.filter[keyPath: keyPath] = value
                viewModel.markDateRangeCustom()
            }
        )
    }

    private var tokenRangeLabel: String {
        switch viewModel.filter.tokenScope {
        case .sessionTotal:
            "会话总量范围"
        case .selectedRange:
            "时段用量范围"
        }
    }
}

private struct PresetButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}
