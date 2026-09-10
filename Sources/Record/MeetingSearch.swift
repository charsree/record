import Foundation

/// One transcript-level hit for a cross-meeting search.
struct MeetingSearchHit: Identifiable {
    let id = UUID()
    let meeting: MeetingRecord
    let segment: TranscriptSegment
    let snippet: String  // pre-formatted text with the query context
}

extension MeetingSearchHit: Hashable {
    static func == (lhs: MeetingSearchHit, rhs: MeetingSearchHit) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum MeetingSearch {
    /// Decrypts every meeting's transcript and filters segments containing
    /// `query` (case-insensitive substring). Returns hits newest-first.
    /// The `throttle` value slows the search if there are many meetings so
    /// the UI stays responsive.
    static func run(query rawQuery: String, database: MeetingDatabase) async -> [MeetingSearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        var results: [MeetingSearchHit] = []
        do {
            let meetings = try await database.meetings()
            for meeting in meetings {
                await Task.yield()
                let segments = (try? await database.segments(for: meeting.id)) ?? []
                for segment in segments where segment.isFinal {
                    if segment.text.range(of: query, options: .caseInsensitive) != nil {
                        results.append(MeetingSearchHit(
                            meeting: meeting,
                            segment: segment,
                            snippet: makeSnippet(text: segment.text, query: query)
                        ))
                    }
                }
            }
        } catch {
            return []
        }
        return results
    }

    /// Produces a ~120-char snippet of `text` centered around the first
    /// occurrence of `query`, so search results show relevant context.
    private static func makeSnippet(text: String, query: String) -> String {
        guard let range = text.range(of: query, options: .caseInsensitive) else { return text }
        let start = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[start..<end])
        if start > text.startIndex { snippet = "…" + snippet }
        if end < text.endIndex { snippet += "…" }
        return snippet
    }
}
