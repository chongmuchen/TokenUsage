import SwiftUI
import TokenUsageCore

struct UsageTableView: View {
    let rows: [UsageTreeRow]

    @State private var selection = Set<UsageTreeRow.ID>()
    @State private var sortOrder: [UsageRowSortComparator] = []
    @SceneStorage("usage-table-columns")
    private var columnCustomization = TableColumnCustomization<UsageTreeRow>()

    private var sortedRows: [UsageTreeRow] {
        guard !sortOrder.isEmpty else { return rows }
        let summaryRows = rows.filter { $0.kind == .summary }
        return rows
            .filter { $0.kind != .summary }
            .sorted(using: sortOrder)
            + summaryRows
    }

    var body: some View {
        Table(
            sortedRows,
            children: \.children,
            selection: $selection,
            sortOrder: $sortOrder,
            columnCustomization: $columnCustomization
        ) {
            TableColumn("时间") { row in
                TimeCell(row: row)
            }
            .width(min: 170, ideal: 190, max: 220)
            .customizationID("time")

            TableColumn("会话 / 对话") { row in
                NameCell(row: row)
            }
            .width(min: 230, ideal: 340, max: .infinity)
            .customizationID("name")

            TableColumn("项目") { row in
                if let projectName = row.projectName {
                    Text(projectName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.projectPath ?? projectName)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 90, ideal: 125, max: 200)
            .customizationID("project")

            TableColumn(
                "Token（含子级 / 自身）",
                sortUsing: UsageRowSortComparator(field: .totalTokens)
            ) { row in
                TotalAndOwnTokenCell(row: row)
            }
            .width(min: 135, ideal: 150, max: 185)
            .customizationID("total-own")

            TableColumn("输入") { row in
                TokenCell(
                    value: row.subtreeUsage.inputTokens,
                    isApproximate: row.isUsageApproximate
                )
            }
            .width(min: 82, ideal: 92, max: 120)
            .customizationID("input")

            TableColumn("缓存（读 / 写）") { row in
                CacheCell(
                    read: row.subtreeUsage.cachedInputTokens,
                    write: row.subtreeUsage.cacheWriteInputTokens,
                    isApproximate: row.isUsageApproximate
                )
            }
            .width(min: 112, ideal: 128, max: 155)
            .customizationID("cache")

            TableColumn("输出 / 推理") { row in
                OutputCell(
                    output: row.subtreeUsage.outputTokens,
                    reasoning: row.subtreeUsage.reasoningOutputTokens,
                    isApproximate: row.isUsageApproximate
                )
            }
            .width(min: 118, ideal: 140, max: 175)
            .customizationID("output-reasoning")

            TableColumn("模型 / 档位") { row in
                Text(row.modelSummary)
                    .lineLimit(1)
                    .help(row.modelSummary)
            }
            .width(min: 130, ideal: 190, max: 280)
            .customizationID("model")

            TableColumn(
                "Credits / API USD 等价",
                sortUsing: UsageRowSortComparator(field: .apiUSD)
            ) { row in
                CombinedPriceCell(row: row)
            }
            .width(min: 150, ideal: 190, max: 250)
            .customizationID("credits-api-price")
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }
}

private struct UsageRowSortComparator: SortComparator {
    enum Field {
        case totalTokens
        case apiUSD
    }

    let field: Field
    var order: SortOrder = .forward

    func compare(_ lhs: UsageTreeRow, _ rhs: UsageTreeRow) -> ComparisonResult {
        switch field {
        case .totalTokens:
            let result = compareValues(lhs.subtreeUsage.totalTokens, rhs.subtreeUsage.totalTokens)
            return result == .orderedSame
                ? stableFallback(lhs, rhs)
                : applyingOrder(to: result)
        case .apiUSD:
            return compareAPIPrice(lhs, rhs)
        }
    }

    private func compareAPIPrice(_ lhs: UsageTreeRow, _ rhs: UsageTreeRow) -> ComparisonResult {
        switch (lhs.apiPriceEstimate?.amount, rhs.apiPriceEstimate?.amount) {
        case let (left?, right?):
            let result = compareValues(left, right)
            return result == .orderedSame
                ? stableFallback(lhs, rhs)
                : applyingOrder(to: result)
        case (nil, nil):
            return stableFallback(lhs, rhs)
        case (nil, _?):
            return .orderedDescending
        case (_?, nil):
            return .orderedAscending
        }
    }

    private func compareValues<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    /// Equal values retain a deterministic, useful order across refreshes.
    private func stableFallback(_ lhs: UsageTreeRow, _ rhs: UsageTreeRow) -> ComparisonResult {
        let leftTime = lhs.time ?? .distantPast
        let rightTime = rhs.time ?? .distantPast
        if leftTime > rightTime { return .orderedAscending }
        if leftTime < rightTime { return .orderedDescending }
        return compareValues(lhs.id, rhs.id)
    }

    private func applyingOrder(to result: ComparisonResult) -> ComparisonResult {
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

private struct TimeCell: View {
    let row: UsageTreeRow

    var body: some View {
        if showsRange {
            VStack(alignment: .leading, spacing: 1) {
                timestampLine(label: "开始", date: row.time)
                timestampLine(label: "结束", date: row.endTime)
            }
        } else if let date = row.time {
            timestamp(date)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    private var showsRange: Bool {
        row.kind == .session || row.endTime != nil
    }

    private func timestampLine(label: String, date: Date?) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            if let date {
                timestamp(date)
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func timestamp(_ date: Date) -> some View {
        Text(date, format: .dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
            .monospacedDigit()
            .lineLimit(1)
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
    var isApproximate = false

    var body: some View {
        Text(qualifiedToken(value, isLowerBound: isLowerBound, isApproximate: isApproximate))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(tokenHelp(value, isLowerBound: isLowerBound, isApproximate: isApproximate))
    }
}

private struct TotalAndOwnTokenCell: View {
    let row: UsageTreeRow

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(qualifiedToken(
                row.subtreeUsage.totalTokens,
                isLowerBound: row.isLowerBound,
                isApproximate: row.isUsageApproximate
            ))
                .monospacedDigit()
                .fontWeight(row.kind == .summary ? .semibold : .regular)
            if row.kind != .summary {
                Text("自身 " + qualifiedToken(
                    row.ownUsage.totalTokens,
                    isLowerBound: false,
                    isApproximate: row.isOwnUsageApproximate
                ))
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
            return tokenHelp(
                row.subtreeUsage.totalTokens,
                isLowerBound: row.isLowerBound,
                isApproximate: row.isUsageApproximate,
                label: "当前筛选会话合计"
            )
        }
        let base = "含子级 \(TokenFormatter.exact(row.subtreeUsage.totalTokens))；"
            + "自身 \(TokenFormatter.exact(row.ownUsage.totalTokens)) tokens"
        var result = base + usageQualifierHelp(
            isLowerBound: row.isLowerBound,
            isApproximate: row.isUsageApproximate
        )
        if row.isOwnUsageApproximate && !row.isUsageApproximate {
            result += "\n≈ 仅自身用量缺少完整的分钟归属，已近似计算"
        }
        return result
    }
}

private struct CacheCell: View {
    let read: Int64
    let write: Int64
    var isLowerBound = false
    var isApproximate = false

    var body: some View {
        Text(
            "\(qualifiedToken(read, isLowerBound: isLowerBound, isApproximate: isApproximate)) / "
                + qualifiedToken(write, isLowerBound: isLowerBound, isApproximate: isApproximate)
        )
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(
                "缓存读 \(TokenFormatter.exact(read))；缓存写 \(TokenFormatter.exact(write))"
                    + usageQualifierHelp(
                        isLowerBound: isLowerBound,
                        isApproximate: isApproximate
                    )
            )
    }
}

private struct OutputCell: View {
    let output: Int64
    let reasoning: Int64
    var isApproximate = false

    var body: some View {
        Text(
            "\(qualifiedToken(output, isLowerBound: false, isApproximate: isApproximate)) / "
                + qualifiedToken(reasoning, isLowerBound: false, isApproximate: isApproximate)
        )
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(
                "输出 \(TokenFormatter.exact(output))；推理 \(TokenFormatter.exact(reasoning))"
                    + "（推理是输出的子集，两者不相加）"
                    + usageQualifierHelp(isLowerBound: false, isApproximate: isApproximate)
            )
    }
}

private func qualifiedToken(
    _ value: Int64,
    isLowerBound: Bool,
    isApproximate: Bool
) -> String {
    let approximation = isApproximate ? "≈" : ""
    let separator = isApproximate && isLowerBound ? " " : ""
    let lowerBound = isLowerBound ? "≥" : ""
    return approximation + separator + lowerBound + TokenFormatter.compact(value)
}

private func tokenHelp(
    _ value: Int64,
    isLowerBound: Bool,
    isApproximate: Bool,
    label: String? = nil
) -> String {
    let prefix = label.map { $0 + " " } ?? ""
    let lowerBound = isLowerBound ? "至少 " : ""
    return prefix + lowerBound + TokenFormatter.exact(value) + " tokens"
        + usageQualifierHelp(isLowerBound: isLowerBound, isApproximate: isApproximate)
}

private func usageQualifierHelp(isLowerBound: Bool, isApproximate: Bool) -> String {
    var notes: [String] = []
    if isLowerBound {
        notes.append("≥ 表示当前记录只能确认此下界")
    }
    if isApproximate {
        notes.append("≈ 表示该值缺少完整的分钟归属，已按观测时间近似计算")
    }
    return notes.isEmpty ? "" : "\n" + notes.joined(separator: "\n")
}

private struct CreditsCell: View {
    let estimate: CreditEstimate?
    let warnings: [String]

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
                .help(unavailablePriceHelp(warnings: warnings, currency: "Credits"))
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

private struct CombinedPriceCell: View {
    let row: UsageTreeRow

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            CreditsCell(estimate: row.creditEstimate, warnings: row.warnings)
            APIPriceCell(estimate: row.apiPriceEstimate, warnings: row.warnings)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct APIPriceCell: View {
    let estimate: APIPriceEstimate?
    let warnings: [String]

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
                .help(unavailablePriceHelp(warnings: warnings, currency: "API USD"))
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

private func unavailablePriceHelp(warnings: [String], currency: String) -> String {
    let suppressed = warnings.contains { warning in
        let normalized = warning.lowercased()
        return normalized.contains("price estimates were suppressed")
            || normalized.contains("token counter invariants failed")
    }
    if suppressed {
        return "Token 计数校验未通过，应用已主动隐藏 \(currency) 估算；这不是缺少公开价目。重新同步该日期范围可用新版解析器重建报告。"
    }
    return "该行没有足够的公开价目来估算 \(currency)；可能是模型未知或公开价目未覆盖。"
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
