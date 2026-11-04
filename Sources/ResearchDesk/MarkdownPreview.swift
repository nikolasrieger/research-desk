import SwiftUI

private struct MarkdownBlock: Identifiable {
    enum Kind { case heading(Int), paragraph, bullet, quote, code, rule, table([[String]]) }
    let id: Int
    let kind: Kind
    let text: String
}

struct MarkdownPreview: View {
    let source: String
    var rendersTables = false
    var linksFilePaths = false

    private var blocks: [MarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var result: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inCode = false
        func append(_ kind: MarkdownBlock.Kind, _ text: String) {
            result.append(MarkdownBlock(id: result.count, kind: kind, text: text))
        }
        func flushParagraph() {
            if !paragraph.isEmpty {
                append(.paragraph, paragraph.joined(separator: " "))
                paragraph.removeAll()
            }
        }
        var position = 0
        while position < lines.count {
            let raw = lines[position]
            if rendersTables, !inCode, let table = MarkdownTableParser.parse(lines, at: position) {
                flushParagraph()
                append(.table(table.rows), "")
                position += table.consumed
                continue
            }
            if rendersTables, !inCode, MarkdownTableParser.isTerminalBorder(raw) {
                flushParagraph()
                var terminal: [String] = []
                while position < lines.count, MarkdownTableParser.isTerminalRow(lines[position]) {
                    terminal.append(lines[position]); position += 1
                }
                append(.code, terminal.joined(separator: "\n"))
                continue
            }
            position += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flushParagraph()
                if inCode { append(.code, code.joined(separator: "\n")); code.removeAll() }
                inCode.toggle()
                continue
            }
            if inCode { code.append(raw); continue }
            if line.isEmpty { flushParagraph(); continue }
            let hashes = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") {
                flushParagraph()
                append(.heading(hashes), String(line.dropFirst(hashes + 1)))
            } else if line == "---" || line == "***" {
                flushParagraph()
                append(.rule, "")
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                append(.bullet, String(line.dropFirst(2)))
            } else if line.hasPrefix("> ") {
                flushParagraph()
                append(.quote, String(line.dropFirst(2)))
            } else if let dot = line.firstIndex(of: "."),
                      line.startIndex != dot,
                      line[..<dot].allSatisfy(\.isNumber),
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flushParagraph()
                append(.bullet, String(line[line.index(dot, offsetBy: 2)...]))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        if !code.isEmpty { append(.code, code.joined(separator: "\n")) }
        return result
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(blocks) { block in
                    switch block.kind {
                    case .heading(let level):
                        inline(block.text)
                            .font(.system(size: level == 1 ? 27 : level == 2 ? 22 : 17, weight: .semibold))
                            .padding(.top, level == 1 ? 10 : 4)
                    case .paragraph:
                        inline(block.text).font(.system(size: 14)).lineSpacing(5)
                    case .bullet:
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("•").foregroundStyle(DeskStyle.accent)
                            inline(block.text).font(.system(size: 14)).lineSpacing(4)
                        }
                    case .quote:
                        HStack(alignment: .top, spacing: 12) {
                            RoundedRectangle(cornerRadius: 2).fill(DeskStyle.accent.opacity(0.45)).frame(width: 3)
                            inline(block.text).font(.system(size: 14)).foregroundStyle(DeskStyle.muted)
                        }.padding(.vertical, 3)
                    case .code:
                        if rendersTables {
                            ScrollView(.horizontal) {
                                Text(block.text).font(.system(size: 12, design: .monospaced))
                                    .fixedSize(horizontal: true, vertical: false).padding(15)
                            }.background(DeskStyle.background, in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            Text(block.text).font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(15)
                                .background(DeskStyle.background, in: RoundedRectangle(cornerRadius: 8))
                        }
                    case .table(let rows):
                        ScrollView(.horizontal) {
                            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                                    GridRow {
                                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                            inline(cell).font(.system(size: 12, weight: rowIndex == 0 ? .semibold : .regular))
                                                .frame(minWidth: 80, maxWidth: 280, alignment: .leading).padding(10)
                                                .background(rowIndex == 0 ? DeskStyle.raised : DeskStyle.surface)
                                                .overlay(Rectangle().stroke(DeskStyle.edge, lineWidth: 0.5))
                                        }
                                    }
                                }
                            }.fixedSize(horizontal: true, vertical: false)
                        }
                    case .rule:
                        Rectangle().fill(DeskStyle.edge).frame(height: 1).padding(.vertical, 4)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(32)
            .textSelection(.enabled)
        }
    }

    private func inline(_ source: String) -> Text {
        if let value = try? AttributedString(markdown: linksFilePaths ? AgentFileLink.linkCodePaths(source) : source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(value)
        }
        return Text(source)
    }
}

/// Pipe tables keep cell boundaries; terminal box-drawing tables retain monospace alignment.
enum MarkdownTableParser {
    static func cells(_ line: String) -> [String] {
        var source = line.trimmingCharacters(in: .whitespaces)
        if source.hasPrefix("|") { source.removeFirst() }
        if source.hasSuffix("|"), !source.hasSuffix("\\|") { source.removeLast() }
        var result: [String] = [], cell = ""
        var escaped = false, inCode = false
        for character in source {
            if escaped { cell.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "`" { inCode.toggle(); cell.append(character); continue }
            if character == "|", !inCode { result.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(character) }
        }
        if escaped { cell.append("\\") }
        result.append(cell.trimmingCharacters(in: .whitespaces))
        return result
    }
    static func parse(_ lines: [String], at index: Int) -> (rows: [[String]], consumed: Int)? {
        guard index + 1 < lines.count, lines[index].contains("|") else { return nil }
        let header = cells(lines[index]), separators = cells(lines[index + 1])
        guard header.count >= 2, separators.count == header.count,
              separators.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) else { return nil }
        var rows = [header], cursor = index + 2
        while cursor < lines.count, lines[cursor].contains("|"), !lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty {
            let row = cells(lines[cursor])
            guard row.count == header.count else { break }
            rows.append(row); cursor += 1
        }
        return (rows, cursor - index)
    }
    static func isTerminalBorder(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return ["┌", "╔", "╭", "┏", "┍"].contains(where: { trimmed.hasPrefix($0) }) ||
            (trimmed.hasPrefix("+") && trimmed.contains("---") && trimmed.hasSuffix("+"))
    }
    static func isTerminalRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && ["│", "┃", "║", "┌", "┐", "└", "┘", "├", "┤", "┼", "╭", "╰", "╔", "╚", "╠", "┏", "┗", "┣", "┍", "+", "|"].contains(where: { trimmed.hasPrefix($0) })
    }
}
