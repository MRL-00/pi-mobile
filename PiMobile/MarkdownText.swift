import SwiftUI

/// Block-based markdown renderer. Apple's `AttributedString` `.full` parser collapses
/// whitespace around bold/headings (words glue together); splitting into blocks and only
/// using inline markdown inside each block keeps spacing readable.
struct MarkdownText: View {
    let markdown: String
    var baseSize: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .tint(Theme.accent)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(.system(size: headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .foregroundStyle(Theme.text)
                .padding(.top, level <= 2 ? 6 : 2)
                .padding(.bottom, 2)

        case .paragraph(let text):
            inlineText(text)
                .font(.system(size: baseSize))
                .foregroundStyle(Color(red: 0.86, green: 0.86, blue: 0.89))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.system(size: baseSize, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                        inlineText(item)
                            .font(.system(size: baseSize))
                            .foregroundStyle(Color(red: 0.86, green: 0.86, blue: 0.89))
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 2)

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).")
                            .font(.system(size: baseSize, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(minWidth: 20, alignment: .trailing)
                        inlineText(item)
                            .font(.system(size: baseSize))
                            .foregroundStyle(Color(red: 0.86, green: 0.86, blue: 0.89))
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .code(let text):
            Text(text)
                .font(.system(size: baseSize - 1, design: .monospaced))
                .foregroundStyle(Color(red: 0.78, green: 0.84, blue: 0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.textMuted)
                    .frame(width: 3)
                inlineText(text)
                    .font(.system(size: baseSize))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .rule:
            Divider().overlay(Theme.separator).padding(.vertical, 4)

        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)
        }
    }

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        let columns = max(headers.count, rows.map(\.count).max() ?? 0)
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        tableCell(c < headers.count ? headers[c] : "", header: true)
                    }
                }
                .background(Color.white.opacity(0.07))

                ForEach(Array(rows.enumerated()), id: \.offset) { ri, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            tableCell(c < row.count ? row[c] : "", header: false)
                        }
                    }
                    .background(ri % 2 == 0 ? Color.clear : Color.white.opacity(0.03))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }

    private func tableCell(_ text: String, header: Bool) -> some View {
        inlineText(text)
            .font(.system(size: baseSize - 1, weight: header ? .semibold : .regular))
            .foregroundStyle(header ? Theme.text : Color(red: 0.86, green: 0.86, blue: 0.89))
            .multilineTextAlignment(.leading)
            .lineLimit(8)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minWidth: 72, maxWidth: 200, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return baseSize + 7
        case 2: return baseSize + 5
        case 3: return baseSize + 3
        default: return baseSize + 1
        }
    }

    private func inlineText(_ text: String) -> Text {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        if let parsed = try? AttributedString(markdown: text, options: options) {
            return Text(parsed)
        }
        return Text(text)
    }

    // MARK: - Parsing

    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullets([String])
        case numbered([String])
        case code(String)
        case quote(String)
        case rule
        case table(headers: [String], rows: [[String]])
    }

    private static func parse(_ markdown: String) -> [Block] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll()
            guard !text.isEmpty else { return }
            blocks.append(.paragraph(text))
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                i += 1
                var code: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // closing fence
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            if let heading = headingMatch(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.0, text: heading.1))
                i += 1
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("> ") {
                        quote.append(String(t.dropFirst(2)))
                    } else if t == ">" {
                        quote.append("")
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            if isBullet(trimmed) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, isBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripBullet(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                    // Continuation lines indented under the bullet
                    while i < lines.count {
                        let raw = lines[i]
                        let t = raw.trimmingCharacters(in: .whitespaces)
                        if t.isEmpty || isBullet(t) || isNumbered(t) || headingMatch(t) != nil || t.hasPrefix("```") || t.hasPrefix(">") {
                            break
                        }
                        if raw.hasPrefix("  ") || raw.hasPrefix("\t") {
                            items[items.count - 1] += " " + t
                            i += 1
                        } else {
                            break
                        }
                    }
                }
                blocks.append(.bullets(items))
                continue
            }

            if isNumbered(trimmed) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, isNumbered(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripNumbered(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.numbered(items))
                continue
            }

            // GFM tables — including soft-wrapped cells from narrow model output.
            if looksLikeTableRow(trimmed) {
                var idx = i
                if let table = tryParseTable(lines, start: &idx) {
                    flushParagraph()
                    blocks.append(table)
                    i = idx
                    continue
                }
            }

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: - Tables

    private static func tryParseTable(_ lines: [String], start i: inout Int) -> Block? {
        var idx = i
        guard let headerLine = readTableRow(lines, at: &idx) else { return nil }
        let headers = parseCells(headerLine)
        guard headers.count >= 2 else { return nil }

        guard let sepLine = readTableRow(lines, at: &idx), isTableSeparator(sepLine) else { return nil }

        var rows: [[String]] = []
        while idx < lines.count {
            let saved = idx
            guard let rowLine = readTableRow(lines, at: &idx) else { break }
            let trimmed = rowLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || isTableSeparator(trimmed) || !looksLikeTableRow(trimmed) {
                idx = saved
                break
            }
            var cells = parseCells(rowLine)
            while cells.count < headers.count { cells.append("") }
            if cells.count > headers.count { cells = Array(cells.prefix(headers.count)) }
            rows.append(cells)
        }

        i = idx
        return .table(headers: headers, rows: rows)
    }

    /// Reads one logical table row, joining soft-wrapped continuations like:
    /// `| … | High | timeout +` / `deny default |`
    private static func readTableRow(_ lines: [String], at idx: inout Int) -> String? {
        guard idx < lines.count else { return nil }
        var row = lines[idx].trimmingCharacters(in: .whitespaces)
        if row.isEmpty { return nil }
        idx += 1

        while idx < lines.count {
            let nextTrim = lines[idx].trimmingCharacters(in: .whitespaces)
            if nextTrim.isEmpty { break }
            if nextTrim.hasPrefix("|") || isTableSeparator(nextTrim) { break }
            if headingMatch(nextTrim) != nil || nextTrim.hasPrefix("```")
                || isBullet(nextTrim) || isNumbered(nextTrim) || nextTrim.hasPrefix(">") {
                break
            }
            // Incomplete row (model wrapped mid-cell) — join until we see a closing `|`.
            if row.hasSuffix("|") { break }
            row += " " + nextTrim
            idx += 1
        }
        return row
    }

    private static func looksLikeTableRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|") else { return false }
        return t.hasPrefix("|") || t.hasSuffix("|") || parseCells(t).count >= 2
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = parseCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty else { return false }
            return c.unicodeScalars.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
        }
    }

    /// Split on `|` but keep `\|` and pipes inside `` `inline code` ``.
    private static func parseCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }

        var cells: [String] = []
        var current = ""
        var inCode = false
        var i = t.startIndex
        while i < t.endIndex {
            let ch = t[i]
            if ch == "`" {
                inCode.toggle()
                current.append(ch)
                i = t.index(after: i)
                continue
            }
            if ch == "\\", !inCode {
                let next = t.index(after: i)
                if next < t.endIndex, t[next] == "|" {
                    current.append("|")
                    i = t.index(after: next)
                    continue
                }
            }
            if ch == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                i = t.index(after: i)
                continue
            }
            current.append(ch)
            i = t.index(after: i)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func headingMatch(_ line: String) -> (Int, String)? {
        guard let regex = try? NSRegularExpression(pattern: #"^(#{1,6})\s+(.+)$"#) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let levelRange = Range(match.range(at: 1), in: line),
              let textRange = Range(match.range(at: 2), in: line) else { return nil }
        return (line[levelRange].count, String(line[textRange]))
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    private static func stripBullet(_ line: String) -> String {
        String(line.dropFirst(2))
    }

    private static func isNumbered(_ line: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"^\d+\.\s+"#) else { return false }
        return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func stripNumbered(_ line: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"^\d+\.\s+"#) else { return line }
        return regex.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
    }
}
