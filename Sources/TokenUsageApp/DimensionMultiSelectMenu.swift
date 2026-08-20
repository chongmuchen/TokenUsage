import SwiftUI

/// A compact OR-within-one-dimension selector. An empty selection means all
/// values, which keeps newly discovered model/tier values visible by default.
struct DimensionMultiSelectMenu: View {
    let title: String
    let options: [String]
    @Binding var selection: Set<String>

    var body: some View {
        Menu {
            Button {
                selection.removeAll()
            } label: {
                Label("全部", systemImage: selection.isEmpty ? "checkmark" : "")
            }

            Divider()

            ForEach(options, id: \.self) { option in
                Button {
                    if selection.contains(option) {
                        selection.remove(option)
                    } else {
                        selection.insert(option)
                    }
                } label: {
                    Label(option, systemImage: selection.contains(option) ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .foregroundStyle(.secondary)
                Text(selectionSummary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(options.isEmpty)
        .help(helpText)
        .accessibilityLabel(title)
        .accessibilityValue(selectionSummary)
    }

    private var selectionSummary: String {
        if options.isEmpty { return "无数据" }
        if selection.isEmpty { return "全部" }
        if selection.count == 1 { return selection.first ?? "全部" }
        return "已选 \(selection.count) 项"
    }

    private var helpText: String {
        guard !selection.isEmpty else { return "\(title)：全部" }
        return "\(title)：" + selection.sorted().joined(separator: "、")
    }
}
