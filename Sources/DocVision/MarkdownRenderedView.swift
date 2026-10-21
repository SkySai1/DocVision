import SwiftUI

struct MarkdownRenderedView: View {
    let markdown: String

    private var blocks: [MarkdownBlock] {
        MarkdownBlockParser.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks.indices, id: \.self) { index in
                renderedBlock(blocks[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func renderedBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inlineMarkdown(text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 8 : 4)
                .textSelection(.enabled)
        case let .paragraph(text):
            Text(inlineMarkdown(text))
                .font(.body)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case let .list(items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .font(.body.monospacedDigit())
                            .frame(width: 28, alignment: .trailing)
                        Text(inlineMarkdown(item.text))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indentation) * 7)
                }
            }
        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.65))
                    .frame(width: 3)
                Text(inlineMarkdown(text))
                    .italic()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 5)
            .padding(.leading, 8)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        case let .code(language, text):
            VStack(alignment: .leading, spacing: 7) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case let .table(headers, rows):
            renderedTable(headers: headers, rows: rows)
        case .divider:
            Divider()
                .padding(.vertical, 4)
        }
    }

    private func renderedTable(headers: [String], rows: [[String]]) -> some View {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        return ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        tableCell(column < headers.count ? headers[column] : "", isHeader: true)
                    }
                }
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { column in
                            let value = column < rows[row].count ? rows[row][column] : ""
                            tableCell(value, isHeader: false)
                        }
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            }
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableCell(_ value: String, isHeader: Bool) -> some View {
        Text(inlineMarkdown(value))
            .font(isHeader ? .body.weight(.semibold) : .body)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHeader ? Color.secondary.opacity(0.1) : Color.clear)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.16))
                    .frame(width: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.16))
                    .frame(height: 1)
            }
            .textSelection(.enabled)
    }

    private func inlineMarkdown(_ source: String) -> AttributedString {
        (try? AttributedString(markdown: source)) ?? AttributedString(source)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 28
        case 2: 24
        case 3: 20
        case 4: 18
        case 5: 16
        default: 14
        }
    }
}
