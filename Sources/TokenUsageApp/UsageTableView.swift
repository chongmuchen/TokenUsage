import SwiftUI
import TokenUsageCore

struct UsageTableView: View {
    let rows: [UsageTreeRow]

    @State private var selection = Set<UsageTreeRow.ID>()
    @SceneStorage("usage-table-columns")
    private var columnCustomization = TableColumnCustomization<UsageTreeRow>()

    var body: some View {
        Table(
            rows,
            children: \.children,
            selection: $selection,
            columnCustomization: $columnCustomization
        ) {
            TableColumn("时间") { row in
                TimeCell(date: row.time)
            }
            .width(min: 125, ideal: 145, max: 180)
            .customizationID("time")

            TableColumn("会话 / 对话") { row in
                NameCell(row: row)
            }
            .width(min: 230, ideal: 340, max: .infinity)
            .customizationID("name")

            TableColumn("Token（总 / 自身）") { row in
                TotalAndOwnTokenCell(row: row)
            }
            .width(min: 120, ideal: 138, max: 170)
            .customizationID("total-own")

            TableColumn("输入") { row in
                TokenCell(value: row.subtreeUsage.inputTokens)
            }
            .width(min: 82, ideal: 92, max: 120)
            .customizationID("input")

            TableColumn("缓存（读 / 写）") { row in
                CacheCell(
                    read: row.subtreeUsage.cachedInputTokens,
                    write: row.subtreeUsage.cacheWriteInputTokens
                )
            }
            .width(min: 112, ideal: 128, max: 155)
            .customizationID("cache")

            TableColumn("输出") { row in
                TokenCell(value: row.subtreeUsage.outputTokens)
            }
            .width(min: 82, ideal: 92, max: 120)
            .customizationID("output")

            TableColumn("推理") { row in
                TokenCell(value: row.subtreeUsage.reasoningOutputTokens)
            }
            .width(min: 82, ideal: 92, max: 120)
            .customizationID("reasoning")

            TableColumn("模型 / 档位") { row in
                Text(row.modelSummary)
                    .lineLimit(1)
                    .help(row.modelSummary)
            }
            .width(min: 130, ideal: 190, max: 280)
            .customizationID("model")

            TableColumn("Credits") { row in
                CreditsCell(estimate: row.creditEstimate)
            }
            .width(min: 120, ideal: 140, max: 175)
            .customizationID("credits")

            TableColumn("API USD 等价") { row in
                APIPriceCell(estimate: row.apiPriceEstimate)
            }
            .width(min: 130, ideal: 150, max: 185)
            .customizationID("api-price")
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }
}

private struct TimeCell: View {
    let date: Date?

    var body: some View {
        if let date {
            Text(date, format: .dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
                .monospacedDigit()
                .lineLimit(1)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}

private struct NameCell: View {
    let row: UsageTreeRow

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 15)

            Text(row.name)
                .lineLimit(1)
                .fontWeight(row.kind == .summary ? .semibold : .regular)
                .help(row.name)

            if row.counts.imageGenerations > 0 {
                ImageGenerationBadge(row: row)
            }

            if row.attribution == .timeInferred {
                badge("估算归属", color: .orange)
            } else if row.attribution == .unattributed && row.kind != .residual {
                badge("侧边", color: .secondary)
            }
            if row.isProvisional {
                badge("进行中", color: .blue)
            }
            if row.isLowerBound {
                badge("下界", color: .orange)
            }
            if !row.warnings.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(row.warnings.joined(separator: "\n"))
            }
        }
    }

    @ViewBuilder
    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var icon: String {
        switch row.kind {
        case .session: "bubble.left.and.bubble.right"
        case .summary: "sum"
        case .mainTurn: "text.bubble"
        case .agentThread: "point.3.connected.trianglepath.dotted"
        case .agentTurn: "bubble.left"
        case .sideGroup: "square.stack.3d.up"
        case .residual: "questionmark.diamond"
        }
    }

    private var iconColor: Color {
        switch row.kind {
        case .session: .accentColor
        case .summary: .accentColor
        case .mainTurn: .primary
        case .agentThread, .agentTurn: .purple
        case .sideGroup, .residual: .secondary
        }
    }
}

private struct ImageGenerationBadge: View {
    let row: UsageTreeRow

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "photo")
                Text("图片 \(TokenFormatter.compact(row.counts.imageGenerations))")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.purple)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.purple.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("查看图片生成提示词、尺寸和质量")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ImageGenerationDetailsView(
                reportedCount: row.counts.imageGenerations,
                details: row.imageGenerations
            )
        }
    }
}

private struct ImageGenerationDetailsView: View {
    let reportedCount: Int64
    let details: [ImageGenerationDetail]

    private var visibleDetails: [ImageGenerationDetail] {
        Array(details.prefix(50))
    }

    private var missingCount: Int64 {
        max(reportedCount - Int64(details.count), 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("图片生成详情", systemImage: "photo.on.rectangle.angled")
                    .font(.headline)
                Spacer()
                Text("共 \(reportedCount) 次")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(visibleDetails.enumerated()), id: \.offset) { index, detail in
                        ImageGenerationDetailCard(index: index + 1, detail: detail)
                    }

                    if missingCount > 0 {
                        MissingImageGenerationCard(count: missingCount)
                    }

                    if details.count > visibleDetails.count {
                        Text("另有 \(details.count - visibleDetails.count) 条详情未展开显示。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 520)
        }
        .padding(16)
        .frame(width: 470)
    }
}

private struct ImageGenerationDetailCard: View {
    let index: Int
    let detail: ImageGenerationDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("图片 \(index)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let status = detail.status?.nonEmpty {
                    Text(localizedStatus(status))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(statusColor(status))
                }
            }

            PromptPreview(
                title: "用户输入",
                value: detail.userPromptPreview,
                isTruncated: detail.userPromptTruncated == true
            )
            PromptPreview(
                title: "生成提示词",
                value: detail.revisedPromptPreview,
                isTruncated: detail.revisedPromptTruncated == true
            )

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                metadataRow("请求尺寸", requestSizeText)
                metadataRow("输出尺寸", outputSizeText)
                metadataRow("质量", qualityText)
                metadataRow("格式 / 大小", formatAndBytesText)
                if let generatedAt = detail.generatedAt {
                    GridRow {
                        metadataLabel("生成时间")
                        Text(generatedAt, format: .dateTime.year().month().day().hour().minute().second())
                            .monospacedDigit()
                    }
                }
            }
            .font(.caption)
        }
        .padding(11)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .textSelection(.enabled)
    }

    private var requestSizeText: String {
        detail.requestedSize?.nonEmpty ?? "—"
    }

    private var outputSizeText: String {
        if let width = detail.actualWidth, let height = detail.actualHeight,
           width > 0, height > 0 {
            let pixels = "\(width) × \(height) px"
            if let reported = detail.reportedSize?.nonEmpty,
               reported != "\(width)x\(height)" {
                return "\(pixels)（服务端 \(reported)）"
            }
            return pixels
        }
        return detail.reportedSize?.nonEmpty ?? "—"
    }

    private var qualityText: String {
        switch (detail.requestedQuality?.nonEmpty, detail.reportedQuality?.nonEmpty) {
        case let (requested?, reported?) where requested != reported:
            return "\(reported)（请求 \(requested)）"
        case (_, let reported?):
            return reported
        case (let requested?, nil):
            return requested
        default:
            return "—"
        }
    }

    private var formatAndBytesText: String {
        let format = detail.outputFormat?.nonEmpty?.uppercased()
        let bytes = detail.outputBytes.flatMap { value in
            value >= 0 ? ByteCountFormatter.string(fromByteCount: value, countStyle: .file) : nil
        }
        return [format, bytes].compactMap { $0 }.isEmpty
            ? "—"
            : [format, bytes].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            metadataLabel(label)
            Text(value)
        }
    }

    private func metadataLabel(_ value: String) -> some View {
        Text(value)
            .foregroundStyle(.secondary)
            .frame(width: 72, alignment: .leading)
    }

    private func localizedStatus(_ status: String) -> String {
        switch status.lowercased() {
        case "completed", "succeeded", "success": "成功"
        case "failed", "error": "失败"
        case "interrupted", "cancelled", "canceled": "已中断"
        default: status
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "completed", "succeeded", "success": .green
        case "failed", "error": .red
        default: .secondary
        }
    }
}

private struct PromptPreview: View {
    let title: String
    let value: String?
    let isTruncated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title + (isTruncated ? "（已截断）" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value?.nonEmpty ?? "—")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MissingImageGenerationCard: View {
    let count: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("未记录详情 · \(count) 次")
                .font(.subheadline.weight(.semibold))
            PromptPreview(title: "用户输入", value: nil, isTruncated: false)
            PromptPreview(title: "生成提示词", value: nil, isTruncated: false)
            Text("尺寸 —   质量 —   格式 / 大小 —")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(11)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct TokenCell: View {
    let value: Int64
    var isLowerBound = false

    var body: some View {
        Text((isLowerBound ? "≥" : "") + TokenFormatter.compact(value))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help((isLowerBound ? "至少 " : "") + TokenFormatter.exact(value) + " tokens")
    }
}

private struct TotalAndOwnTokenCell: View {
    let row: UsageTreeRow

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text((row.isLowerBound ? "≥" : "") + TokenFormatter.compact(row.subtreeUsage.totalTokens))
                .monospacedDigit()
                .fontWeight(row.kind == .summary ? .semibold : .regular)
            if row.kind != .summary {
                Text("自身 " + TokenFormatter.compact(row.ownUsage.totalTokens))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .help(helpText)
    }

    private var helpText: String {
        if row.kind == .summary {
            return "当前筛选会话合计 \(TokenFormatter.exact(row.subtreeUsage.totalTokens)) tokens"
        }
        return "含子级 \(TokenFormatter.exact(row.subtreeUsage.totalTokens))；"
            + "自身 \(TokenFormatter.exact(row.ownUsage.totalTokens)) tokens"
    }
}

private struct CacheCell: View {
    let read: Int64
    let write: Int64

    var body: some View {
        Text("\(TokenFormatter.compact(read)) / \(TokenFormatter.compact(write))")
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help("缓存读 \(TokenFormatter.exact(read))；缓存写 \(TokenFormatter.exact(write))")
    }
}

private struct CreditsCell: View {
    let estimate: CreditEstimate?

    var body: some View {
        if let estimate, let amount = estimate.amount {
            HStack(spacing: 3) {
                Text(qualifier(estimate))
                    .foregroundStyle(.secondary)
                Text(DecimalFormatter.string(amount))
                    .monospacedDigit()
                Text("cr")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .help(helpText(estimate))
        } else {
            Text("—")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help("没有足够的公开价目来估算")
        }
    }

    private func helpText(_ estimate: CreditEstimate) -> String {
        var lines = [
            "\(estimate.basis.rawValue)估算；不是订阅实际扣款",
            "配置档位来自本地会话记录，不代表服务端最终执行档位"
        ]
        if estimate.isPartial {
            lines.append("仅覆盖 \(TokenFormatter.exact(estimate.pricedTokens)) / \(TokenFormatter.exact(estimate.totalTokens)) tokens")
        }
        return lines.joined(separator: "\n")
    }

    private func qualifier(_ estimate: CreditEstimate) -> String {
        switch (estimate.basis == .mixed, estimate.isPartial) {
        case (true, true): "混合·部分≈"
        case (true, false): "混合≈"
        case (false, true): "部分≈"
        case (false, false): "≈"
        }
    }
}

private struct APIPriceCell: View {
    let estimate: APIPriceEstimate?

    var body: some View {
        if let estimate, let amount = estimate.amount {
            HStack(spacing: 2) {
                Text(qualifier(estimate))
                    .foregroundStyle(.secondary)
                Text("$" + DecimalFormatter.string(amount))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .help(helpText(estimate))
        } else {
            Text("—")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help("没有足够的公开 API 价目来估算")
        }
    }

    private func helpText(_ estimate: APIPriceEstimate) -> String {
        var lines = [
            "\(estimate.basis.rawValue)等价估算；不是订阅实际扣款",
            "按默认公共 API token 价估算；不含区域加价、工具调用和图片生成等额外费用",
            "配置档位来自本地会话记录，服务端实际档位可能不同"
        ]
        if estimate.isPartial {
            lines.append(
                "仅覆盖 \(TokenFormatter.exact(estimate.pricedTokens)) / "
                    + "\(TokenFormatter.exact(estimate.totalTokens)) tokens"
            )
        }
        return lines.joined(separator: "\n")
    }

    private func qualifier(_ estimate: APIPriceEstimate) -> String {
        switch (estimate.basis == .mixed, estimate.isPartial) {
        case (true, true): "混合·部分≈"
        case (true, false): "混合≈"
        case (false, true): "部分≈"
        case (false, false): "≈"
        }
    }
}

enum TokenFormatter {
    private static let exactFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static func exact(_ value: Int64) -> String {
        exactFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func compact(_ value: Int64) -> String {
        let magnitude = abs(Double(value))
        let divisor: Double
        let suffix: String
        switch magnitude {
        case 1_000_000_000...:
            divisor = 1_000_000_000
            suffix = "B"
        case 1_000_000...:
            divisor = 1_000_000
            suffix = "M"
        case 1_000...:
            divisor = 1_000
            suffix = "k"
        default:
            return String(format: "%.2f", Double(value))
        }
        let scaled = Double(value) / divisor
        return String(format: "%.2f%@", scaled, suffix)
    }
}

private enum DecimalFormatter {
    static func string(_ value: Decimal) -> String {
        let number = value as NSDecimalNumber
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: number) ?? number.stringValue
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
