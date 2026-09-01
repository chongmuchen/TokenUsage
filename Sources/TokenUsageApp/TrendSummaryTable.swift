import SwiftUI
import TokenUsageCore

struct TrendSummaryTable: View {
    let result: UsageTrendResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("每条曲线汇总").font(.headline)
                    Text("汇总范围：\(rangeText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("价格为公开价估算")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal) {
                Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 7) {
                    GridRow {
                        header("曲线", alignment: .leading)
                        header("总 Token")
                        header("非缓存输入")
                        header("缓存读 / 写")
                        header("输出 / 推理")
                        header("Credits")
                        header("API USD 等价")
                        header("覆盖率（Cr / API）")
                    }

                    Divider().gridCellColumns(8)

                    ForEach(Array(result.series.enumerated()), id: \.element.id) { index, series in
                        GridRow {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(TrendSeriesPalette.color(at: index))
                                    .frame(width: 7, height: 7)
                                Text(series.name)
                                    .lineLimit(2)
                                if series.summary.isApproximate {
                                    Text("近似")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            token(series.summary.tokens.totalTokens)
                            token(series.summary.tokens.nonCachedInputTokens)
                            pair(
                                series.summary.tokens.cachedInputTokens,
                                series.summary.tokens.cacheWriteInputTokens
                            )
                            pair(
                                series.summary.tokens.outputTokens,
                                series.summary.tokens.reasoningOutputTokens
                            )
                            price(series.summary.credits, currency: .credits)
                            price(series.summary.apiUSD, currency: .apiUSD)
                            coverageCell(
                                credits: series.summary.credits,
                                apiUSD: series.summary.apiUSD
                            )
                        }
                        .help(summaryHelp(series))
                    }
                }
                .font(.callout)
                .frame(minWidth: 1160)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
        }
    }

    private var rangeText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(formatter.string(from: result.startMinute)) – \(formatter.string(from: result.endMinute))"
    }

    private func header(_ text: String, alignment: Alignment = .trailing) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func token(_ value: Int64) -> some View {
        Text(TokenFormatter.compact(value))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func pair(_ first: Int64, _ second: Int64) -> some View {
        Text("\(TokenFormatter.compact(first)) / \(TokenFormatter.compact(second))")
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func price(
        _ summary: UsageTrendPriceSummary,
        currency: SummaryCurrency
    ) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            if let amount = summary.amount {
                Text(pricePrefix(summary) + currency.format(amount))
                    .monospacedDigit()
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func pricePrefix(_ summary: UsageTrendPriceSummary) -> String {
        switch (summary.basis, summary.isPartial) {
        case (.mixed, true): "混合·部分≈"
        case (.mixed, false): "混合≈"
        case (_, true): "部分≈"
        case (_, false): "≈"
        }
    }

    private func coverage(_ summary: UsageTrendPriceSummary) -> String {
        guard summary.totalTokens > 0 else { return "100.00%" }
        let percent = Double(summary.pricedTokens) / Double(summary.totalTokens) * 100
        return String(format: "%.2f%%", percent)
    }

    private func coverageCell(
        credits: UsageTrendPriceSummary,
        apiUSD: UsageTrendPriceSummary
    ) -> some View {
        HStack(spacing: 3) {
            Text("\(coverage(credits)) / \(coverage(apiUSD))")
                .monospacedDigit()
            if credits.isSuppressed || apiUSD.isSuppressed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .help(coverageHelp(credits: credits, apiUSD: apiUSD))
    }

    private func coverageHelp(
        credits: UsageTrendPriceSummary,
        apiUSD: UsageTrendPriceSummary
    ) -> String {
        [
            coverageHelpLine("Credits", summary: credits),
            coverageHelpLine("API", summary: apiUSD),
            "计数校验抑价表示为了避免用不可靠的 token 差值算钱而主动隐藏价格；价目未覆盖表示缺少对应模型的公开价格。"
        ].joined(separator: "\n")
    }

    private func coverageHelpLine(
        _ label: String,
        summary: UsageTrendPriceSummary
    ) -> String {
        let catalogUnpriced = max(summary.unpricedTokens - summary.suppressedTokens, 0)
        return "\(label)：已定价 \(TokenFormatter.exact(summary.pricedTokens)) / "
            + "\(TokenFormatter.exact(summary.totalTokens))；计数校验抑价 "
            + "\(TokenFormatter.exact(summary.suppressedTokens))；价目未覆盖 "
            + "\(TokenFormatter.exact(catalogUnpriced)) tokens"
    }

    private func summaryHelp(_ series: UsageTrendSeries) -> String {
        let tokens = series.summary.tokens
        return [
            series.name,
            "总 Token \(TokenFormatter.exact(tokens.totalTokens))",
            "非缓存输入 \(TokenFormatter.exact(tokens.nonCachedInputTokens))",
            "缓存读 \(TokenFormatter.exact(tokens.cachedInputTokens))；缓存写 \(TokenFormatter.exact(tokens.cacheWriteInputTokens))",
            "输出 \(TokenFormatter.exact(tokens.outputTokens))；推理 \(TokenFormatter.exact(tokens.reasoningOutputTokens))"
        ].joined(separator: "\n")
    }

}

enum TrendSeriesPalette {
    private static let colors: [Color] = [
        .blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown,
        .cyan, .mint, .red, .yellow
    ]

    static func color(at index: Int) -> Color {
        colors[index % colors.count]
    }
}

private enum SummaryCurrency {
    case credits
    case apiUSD

    func format(_ amount: Decimal) -> String {
        let number = amount as NSDecimalNumber
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let text = formatter.string(from: number) ?? number.stringValue
        return self == .credits ? "\(text) cr" : "$\(text)"
    }
}
