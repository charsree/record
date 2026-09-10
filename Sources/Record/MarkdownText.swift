import AppKit
import Foundation
import SwiftUI

/// A compact block-level markdown renderer. Handles headings, ordered and
/// unordered lists, blockquotes, fenced code blocks, horizontal rules, and
/// paragraphs. Inline markdown (`**bold**`, `*italic*`, `` `code` ``,
/// `[label](url)`) is rendered via `AttributedString(markdown:)`.
///
/// Deliberately small — meant for AI answers, transcripts, and short notes,
/// NOT arbitrary markdown documents.
struct MarkdownText: View {
    let raw: String
    var textColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownParser.blocks(from: raw).enumerated()), id: \.offset) { _, block in
                block.view(textColor: textColor)
            }
        }
    }
}

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulleted([String])
    case numbered([String])
    case blockquote([String])
    case code(String)
    case rule
}

extension MarkdownBlock {
    @ViewBuilder
    func view(textColor: Color) -> some View {
        switch self {
        case .heading(let level, let text):
            Text(inline(text))
                .font(headingFont(for: level))
                .foregroundStyle(textColor)
                .padding(.top, level == 1 ? 6 : 4)
        case .paragraph(let text):
            Text(inline(text))
                .foregroundStyle(textColor)
                .textSelection(.enabled)
        case .bulleted(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(item))
                            .foregroundStyle(textColor)
                            .textSelection(.enabled)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(inline(item))
                            .foregroundStyle(textColor)
                            .textSelection(.enabled)
                    }
                }
            }
        case .blockquote(let lines):
            HStack(spacing: 8) {
                Rectangle().fill(.secondary.opacity(0.5)).frame(width: 3)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(inline(line))
                            .italic()
                            .foregroundStyle(textColor.opacity(0.85))
                            .textSelection(.enabled)
                    }
                }
            }
        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        default: .headline
        }
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return attributed
        }
        return AttributedString(text)
    }
}

enum MarkdownParser {
    static func blocks(from raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                var codeLines: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 } // consume closing fence
                blocks.append(.code(codeLines.joined(separator: "\n")))
                continue
            }

            if trimmed == "---" || trimmed == "***" {
                blocks.append(.rule)
                index += 1
                continue
            }

            if let level = headingLevel(in: trimmed) {
                let content = trimmed.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: content))
                index += 1
                continue
            }

            if trimmed.hasPrefix("> ") {
                var quoted: [String] = []
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("> ") {
                    let stripped = lines[index]
                        .trimmingCharacters(in: .whitespaces)
                        .dropFirst(2)
                    quoted.append(String(stripped))
                    index += 1
                }
                blocks.append(.blockquote(quoted))
                continue
            }

            if bulletContent(trimmed) != nil {
                var items: [String] = []
                while index < lines.count,
                      let item = bulletContent(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.bulleted(items))
                continue
            }

            if numberedContent(trimmed) != nil {
                var items: [String] = []
                while index < lines.count,
                      let item = numberedContent(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.numbered(items))
                continue
            }

            // Paragraph — collect until blank line or the next special block.
            var paragraph: [String] = [trimmed]
            index += 1
            while index < lines.count {
                let nextTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty { break }
                if nextTrimmed.hasPrefix("#") || nextTrimmed.hasPrefix("```") ||
                    nextTrimmed.hasPrefix("> ") ||
                    bulletContent(nextTrimmed) != nil ||
                    numberedContent(nextTrimmed) != nil ||
                    nextTrimmed == "---" || nextTrimmed == "***" {
                    break
                }
                paragraph.append(nextTrimmed)
                index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
        }

        return blocks
    }

    private static func headingLevel(in text: String) -> Int? {
        guard text.hasPrefix("#") else { return nil }
        var level = 0
        for character in text {
            if character == "#" { level += 1 } else { break }
        }
        guard level <= 6 else { return nil }
        // Must have a space after the hashes (or the whole line is hashes).
        let dropped = text.dropFirst(level)
        guard dropped.first == " " || dropped.isEmpty else { return nil }
        return level
    }

    private static func bulletContent(_ trimmed: String) -> String? {
        for prefix in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
            }
        }
        return nil
    }

    private static func numberedContent(_ trimmed: String) -> String? {
        var scanner = trimmed[...]
        var digits = ""
        while let first = scanner.first, first.isNumber, digits.count < 3 {
            digits.append(first)
            scanner = scanner.dropFirst()
        }
        guard !digits.isEmpty, scanner.first == ".", scanner.dropFirst().first == " " else {
            return nil
        }
        return String(scanner.dropFirst(2))
    }
}
