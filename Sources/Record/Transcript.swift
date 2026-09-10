import Foundation
import SwiftUI

enum TranscriptSource: String, Codable, Sendable, CaseIterable {
    case microphone
    case systemAudio
    case visual
    case chapter
    case note

    var title: String {
        switch self {
        case .microphone: "You"
        case .systemAudio: "Others"
        case .visual: "Screen"
        case .chapter: "Chapter"
        case .note: "Note"
        }
    }

    var color: Color {
        switch self {
        case .microphone: .blue
        case .systemAudio: .purple
        case .visual: .green
        case .chapter: .teal
        case .note: .indigo
        }
    }
}

struct TranscriptSegment: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let source: TranscriptSource
    let timestamp: Date
    var text: String
    var isFinal: Bool
    var starred: Bool

    init(
        id: UUID = UUID(),
        source: TranscriptSource,
        timestamp: Date = .now,
        text: String,
        isFinal: Bool,
        starred: Bool = false
    ) {
        self.id = id
        self.source = source
        self.timestamp = timestamp
        self.text = text
        self.isFinal = isFinal
        self.starred = starred
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, timestamp, text, isFinal, starred
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.source = try container.decode(TranscriptSource.self, forKey: .source)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.text = try container.decode(String.self, forKey: .text)
        self.isFinal = try container.decode(Bool.self, forKey: .isFinal)
        self.starred = try container.decodeIfPresent(Bool.self, forKey: .starred) ?? false
    }
}

actor TranscriptStore {
    private var segments: [TranscriptSegment] = []

    func replaceAll(with newSegments: [TranscriptSegment]) {
        segments = newSegments
    }

    /// Flips the `starred` flag on the segment with the given id and returns
    /// the updated segment (nil if not found).
    @discardableResult
    func toggleStar(_ id: UUID) -> TranscriptSegment? {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return nil }
        segments[index].starred.toggle()
        return segments[index]
    }

    func append(_ segment: TranscriptSegment) {
        segments.append(segment)
    }

    /// Overwrite or append the current live segment for a source. Returns the
    /// segment as it now stands, so the caller can render it.
    @discardableResult
    func replaceLive(source: TranscriptSource, text: String) -> TranscriptSegment {
        if let index = segments.lastIndex(where: { $0.source == source && !$0.isFinal }) {
            segments[index].text = text
            return segments[index]
        }
        let segment = TranscriptSegment(source: source, text: text, isFinal: false)
        segments.append(segment)
        return segment
    }

    /// Turn any live segment for `source` into a finalized one with the given
    /// text (or create a new final segment if none was live). Returns the
    /// finalized segment for persistence.
    func finalizeLive(source: TranscriptSource, text: String) -> TranscriptSegment? {
        guard !text.isEmpty else {
            // Drop the pending live bubble so the UI doesn't show stale text.
            if let index = segments.lastIndex(where: { $0.source == source && !$0.isFinal }) {
                segments.remove(at: index)
            }
            return nil
        }
        if let index = segments.lastIndex(where: { $0.source == source && !$0.isFinal }) {
            segments[index].text = text
            segments[index].isFinal = true
            return segments[index]
        }
        let segment = TranscriptSegment(source: source, text: text, isFinal: true)
        segments.append(segment)
        return segment
    }

    func all() -> [TranscriptSegment] {
        segments
    }

    func evidence(for question: String, limit: Int = 12) -> [TranscriptSegment] {
        let terms = Set(
            question
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count > 2 }
        )
        let scored = segments
            .filter { $0.isFinal }
            .map { segment -> (TranscriptSegment, Int) in
                let score = segment.text.lowercased().split { !$0.isLetter && !$0.isNumber }
                    .map(String.init)
                    .reduce(0) { $0 + (terms.contains($1) ? 1 : 0) }
                return (segment, score)
            }
        return scored
            .sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.timestamp > rhs.0.timestamp : lhs.1 > rhs.1
            }
            .prefix(limit)
            .map(\.0)
    }

    func reset() {
        segments.removeAll()
    }
}

enum TranscriptFormatter {
    static func plainText(_ segments: [TranscriptSegment], title: String, startedAt: Date) -> String {
        let header = """
        \(title)
        Started \(startedAt.formatted(date: .abbreviated, time: .standard))

        """
        let body = segments
            .filter { $0.isFinal }
            .map { segment in
                let time = segment.timestamp.formatted(date: .omitted, time: .standard)
                return "[\(time)] \(segment.source.title): \(segment.text)"
            }
            .joined(separator: "\n")
        return header + "\n" + body + "\n"
    }
}
