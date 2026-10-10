import SwiftUI

/// Lightweight block-level Markdown renderer: headings, paragraphs, lists, quotes, code fences, tables, rules.
/// Inline styling (bold, italics, code, links) uses Foundation's AttributedString Markdown parser.
enum MDBlock: Hashable {
    case heading(Int, String)
    case paragraph(String)
    case bullet(String, marker: String, indent: Int)
    case quote(String)
    case code(String)
    case table([[String]])
    case rule
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var para: [String] = []
        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: " "))); para.removeAll() }
        }
        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flush()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
                i += 1
                continue
            }
            if line.isEmpty { flush(); i += 1; continue }
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                if level <= 6, line.dropFirst(level).first == " " {
                    flush()
                    blocks.append(.heading(level, String(line.dropFirst(level + 1))))
                    i += 1; continue
                }
            }
            if line == "---" || line == "***" { flush(); blocks.append(.rule); i += 1; continue }
            if line.hasPrefix("|") {
                flush()
                var rows: [[String]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let r = lines[i].trimmingCharacters(in: .whitespaces)
                    let cells = r.split(separator: "|", omittingEmptySubsequences: false)
                        .dropFirst().dropLast()
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    let isDivider = cells.allSatisfy { $0.allSatisfy { "-: ".contains($0) } && !$0.isEmpty }
                    if !isDivider { rows.append(cells) }
                    i += 1
                }
                blocks.append(.table(rows)); continue
            }
            if line.hasPrefix(">") {
                flush(); blocks.append(.quote(String(line.drop(while: { $0 == ">" || $0 == " " })))); i += 1; continue
            }
            let indent = raw.prefix(while: { $0 == " " }).count / 2
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush(); blocks.append(.bullet(String(line.dropFirst(2)), marker: "•", indent: indent)); i += 1; continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.bullet(String(line[line.index(dot, offsetBy: 2)...]), marker: String(line[...dot]), indent: indent))
                i += 1; continue
            }
            para.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Table with fixed column widths (each column sized to its longest cell, capped), scrolling sideways when wide.
struct MarkdownTable: View {
    let rows: [[String]]
    var body: some View {
        let cols = rows.map(\.count).max() ?? 0
        let widths: [CGFloat] = (0..<cols).map { c in
            let longest = rows.map { c < $0.count ? $0[c].count : 0 }.max() ?? 0
            return min(300, max(90, CGFloat(longest) * 6.6 + 24))
        }
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0..<cols, id: \.self) { c in
                            Text(MarkdownParser.inline(c < row.count ? row[c] : ""))
                                .font(.system(size: 12.5, weight: r == 0 ? .semibold : .regular))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .frame(width: widths[c], alignment: .topLeading)
                                .frame(maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .background(r == 0 ? PB.surface : Color.clear)
                    .overlay(alignment: .bottom) { Rectangle().fill(PB.line).frame(height: 1) }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PB.line))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct MarkdownView: View {
    let blocks: [MDBlock]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { idx, block in
                view(for: block).id(idx)
            }
        }
        .textSelection(.enabled)
        .tint(PB.cobalt)
    }

    @ViewBuilder
    private func view(for block: MDBlock) -> some View {
        switch block {
        case let .heading(level, text):
            VStack(alignment: .leading, spacing: 8) {
                if level == 2 { Divider().overlay(PB.line).padding(.top, 16) }
                Text(MarkdownParser.inline(text))
                    .font(.system(size: level == 1 ? 30 : level == 2 ? 21 : 16, weight: .bold))
                    .kerning(level <= 2 ? -0.5 : 0)
                    .foregroundStyle(PB.ink)
            }
            .padding(.top, level <= 2 ? 6 : 4)
        case let .paragraph(text):
            Text(MarkdownParser.inline(text)).font(.system(size: 14)).lineSpacing(4).foregroundStyle(PB.ink)
        case let .bullet(text, marker, indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).font(.system(size: 14, weight: .semibold)).foregroundStyle(PB.ink2)
                Text(MarkdownParser.inline(text)).font(.system(size: 14)).lineSpacing(3)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case let .quote(text):
            HStack(spacing: 12) {
                Rectangle().fill(PB.cobalt).frame(width: 3)
                Text(MarkdownParser.inline(text)).font(.system(size: 14)).foregroundStyle(PB.ink2)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .code(code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(PB.ink)
                    .padding(16)
            }
            .background(RoundedRectangle(cornerRadius: PB.rMD).fill(PB.surface))
            .overlay(RoundedRectangle(cornerRadius: PB.rMD).strokeBorder(PB.line))
        case let .table(rows):
            MarkdownTable(rows: rows)
        case .rule:
            Divider().overlay(PB.line)
        }
    }
}
