import SwiftUI

private struct MarkdownBlock: Identifiable {
    enum Kind { case heading(Int), paragraph, bullet, quote, code, rule }
    let id: Int
    let kind: Kind
    let text: String
}

struct MarkdownPreview: View {
    let source: String

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
        for raw in lines {
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
                        Text(block.text).font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(15)
                            .background(DeskStyle.background, in: RoundedRectangle(cornerRadius: 8))
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
        if let value = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(value)
        }
        return Text(source)
    }
}
