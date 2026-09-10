import Foundation
import UniformTypeIdentifiers

/// Which format an export should be written in.
enum ExportFormat: String, CaseIterable {
    case txt
    case markdown
    case json
    case srt
    case vtt

    var displayName: String {
        switch self {
        case .txt: "Plain text (.txt)"
        case .markdown: "Markdown (.md)"
        case .json: "JSON (.json)"
        case .srt: "SubRip subtitles (.srt)"
        case .vtt: "WebVTT captions (.vtt)"
        }
    }

    var fileExtension: String {
        switch self {
        case .txt: "txt"
        case .markdown: "md"
        case .json: "json"
        case .srt: "srt"
        case .vtt: "vtt"
        }
    }

    var contentType: UTType {
        switch self {
        case .txt: return .plainText
        case .markdown:
            return UTType(filenameExtension: "md") ?? .plainText
        case .json: return .json
        case .srt:
            return UTType(filenameExtension: "srt") ?? .plainText
        case .vtt:
            return UTType(filenameExtension: "vtt") ?? .plainText
        }
    }
}

enum TranscriptExporter {
    static func render(
        _ segments: [TranscriptSegment],
        title: String,
        startedAt: Date,
        summary: String,
        tags: [String],
        as format: ExportFormat
    ) -> String {
        let finalSegments = segments.filter { $0.isFinal }
        switch format {
        case .txt:
            return renderPlainText(finalSegments, title: title, startedAt: startedAt)
        case .markdown:
            return renderMarkdown(finalSegments, title: title, startedAt: startedAt, summary: summary, tags: tags)
        case .json:
            return renderJSON(finalSegments, title: title, startedAt: startedAt, summary: summary, tags: tags)
        case .srt:
            return renderSRT(finalSegments, referenceStart: startedAt)
        case .vtt:
            return renderVTT(finalSegments, referenceStart: startedAt)
        }
    }

    // MARK: - Plain text (existing behavior, kept for compatibility)

    private static func renderPlainText(_ segments: [TranscriptSegment], title: String, startedAt: Date) -> String {
        let header = """
        \(title)
        Started \(startedAt.formatted(date: .abbreviated, time: .standard))

        """
        let body = segments
            .map { segment in
                let time = segment.timestamp.formatted(date: .omitted, time: .standard)
                return "[\(time)] \(segment.source.title): \(segment.text)"
            }
            .joined(separator: "\n")
        return header + "\n" + body + "\n"
    }

    // MARK: - Markdown

    private static func renderMarkdown(
        _ segments: [TranscriptSegment],
        title: String,
        startedAt: Date,
        summary: String,
        tags: [String]
    ) -> String {
        var out = "# \(title)\n\n"
        out += "_Started \(startedAt.formatted(date: .complete, time: .shortened))_\n\n"
        if !tags.isEmpty {
            let taggedTags = tags.map { "`#\($0)`" }.joined(separator: " ")
            out += "**Tags:** \(taggedTags)\n\n"
        }
        if !summary.isEmpty {
            out += "## Summary\n\n\(summary)\n\n"
        }
        out += "## Transcript\n\n"

        // Group by chapter — segments with source .chapter start a new section.
        var currentChapter: String? = nil
        for segment in segments {
            let time = segment.timestamp.formatted(date: .omitted, time: .standard)
            switch segment.source {
            case .chapter:
                currentChapter = segment.text
                out += "\n### \(segment.text)\n\n"
            case .note:
                out += "> **Note (\(time)):** \(segment.text)\n\n"
            case .visual:
                out += "**Screen (\(time)):**\n\n```\n\(segment.text)\n```\n\n"
            case .microphone, .systemAudio:
                let speaker = segment.source.title
                out += "- **[\(time)] \(speaker):** \(segment.text)\n"
            }
            _ = currentChapter
        }
        return out
    }

    // MARK: - JSON

    private static func renderJSON(
        _ segments: [TranscriptSegment],
        title: String,
        startedAt: Date,
        summary: String,
        tags: [String]
    ) -> String {
        struct Payload: Encodable {
            let title: String
            let startedAt: Date
            let summary: String
            let tags: [String]
            let segments: [TranscriptSegment]
        }
        let payload = Payload(
            title: title,
            startedAt: startedAt,
            summary: summary,
            tags: tags,
            segments: segments
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(payload),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "{}"
    }

    // MARK: - SRT

    private static func renderSRT(_ segments: [TranscriptSegment], referenceStart: Date) -> String {
        var out = ""
        var index = 1
        for (offset, segment) in segments.enumerated() {
            let start = segment.timestamp.timeIntervalSince(referenceStart)
            let end: TimeInterval
            if offset + 1 < segments.count {
                let nextStart = segments[offset + 1].timestamp.timeIntervalSince(referenceStart)
                end = max(start + 1.0, nextStart - 0.05)
            } else {
                end = start + max(2.5, estimatedDuration(text: segment.text))
            }
            let text = segment.source == .chapter
                ? "▶ \(segment.text)"
                : segment.text
            out += "\(index)\n"
            out += "\(srtTimestamp(start)) --> \(srtTimestamp(end))\n"
            out += text + "\n\n"
            index += 1
        }
        return out
    }

    private static func srtTimestamp(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let h = Int(clamped) / 3600
        let m = (Int(clamped) % 3600) / 60
        let s = Int(clamped) % 60
        let ms = Int((clamped - floor(clamped)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    // MARK: - WebVTT

    private static func renderVTT(_ segments: [TranscriptSegment], referenceStart: Date) -> String {
        var out = "WEBVTT\n\n"
        for (offset, segment) in segments.enumerated() {
            let start = segment.timestamp.timeIntervalSince(referenceStart)
            let end: TimeInterval
            if offset + 1 < segments.count {
                let nextStart = segments[offset + 1].timestamp.timeIntervalSince(referenceStart)
                end = max(start + 1.0, nextStart - 0.05)
            } else {
                end = start + max(2.5, estimatedDuration(text: segment.text))
            }
            out += "\(vttTimestamp(start)) --> \(vttTimestamp(end))\n"
            let speaker = segment.source == .chapter ? "Chapter" : segment.source.title
            out += "<v \(speaker)>\(segment.text)\n\n"
        }
        return out
    }

    private static func vttTimestamp(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let h = Int(clamped) / 3600
        let m = (Int(clamped) % 3600) / 60
        let s = Int(clamped) % 60
        let ms = Int((clamped - floor(clamped)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    private static func estimatedDuration(text: String) -> TimeInterval {
        // Roughly 160 words per minute in normal speech.
        let words = Double(text.split(whereSeparator: \.isWhitespace).count)
        return max(2.5, words / (160.0 / 60.0))
    }
}
