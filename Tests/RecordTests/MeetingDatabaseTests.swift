import CryptoKit
import Foundation
import Testing
@testable import Record

struct MeetingDatabaseTests {
    private func makeDatabase() throws -> (MeetingDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "record-tests-\(UUID().uuidString).sqlite")
        return (try MeetingDatabase(url: url, key: SymmetricKey(size: .bits256)), url)
    }

    @Test
    func roundTripsEncryptedSegments() async throws {
        let (database, _) = try makeDatabase()
        let meetingID = try await database.startMeeting(title: "Sync")
        let segment = TranscriptSegment(source: .visual, text: "Phase 2 starts Oct 14", isFinal: true)

        try await database.append(segment, meetingID: meetingID)

        let saved = try await database.segments(for: meetingID)
        #expect(saved == [segment])
    }

    @Test
    func listsMeetingsWithSegmentCountsAndStatus() async throws {
        let (database, _) = try makeDatabase()
        let firstID = try await database.startMeeting(title: "One")
        try await database.append(
            TranscriptSegment(source: .microphone, text: "hello", isFinal: true),
            meetingID: firstID
        )
        try await database.finishMeeting(firstID)
        _ = try await database.startMeeting(title: "Two") // leave open → interrupted

        try await database.recoverInterruptedMeetings()
        let all = try await database.meetings()

        #expect(all.count == 2)
        let first = try #require(all.first(where: { $0.title == "One" }))
        let second = try #require(all.first(where: { $0.title == "Two" }))
        #expect(first.status == .complete)
        #expect(first.segmentCount == 1)
        #expect(second.status == .interrupted)
        #expect(second.segmentCount == 0)
    }

    @Test
    func deleteEmptyMeetingsRemovesRecordsWithNoTranscript() async throws {
        let (database, _) = try makeDatabase()
        let keptID = try await database.startMeeting(title: "Kept")
        try await database.append(
            TranscriptSegment(source: .microphone, text: "hi", isFinal: true),
            meetingID: keptID
        )
        try await database.finishMeeting(keptID)
        let discardedID = try await database.startMeeting(title: "Discarded")
        try await database.finishMeeting(discardedID)

        try await database.deleteEmptyMeetings()
        let remaining = try await database.meetings()

        #expect(remaining.map(\.id) == [keptID])
    }

    @Test
    func renameMeetingUpdatesTitle() async throws {
        let (database, _) = try makeDatabase()
        let id = try await database.startMeeting(title: "Old")
        try await database.renameMeeting(id, title: "New name")

        let meetings = try await database.meetings()
        #expect(meetings.first(where: { $0.id == id })?.title == "New name")
    }

    @Test
    func replacingASegmentUpdatesInsteadOfInserting() async throws {
        let (database, _) = try makeDatabase()
        let id = try await database.startMeeting()
        let segmentID = UUID()
        try await database.append(
            TranscriptSegment(id: segmentID, source: .microphone, text: "draft", isFinal: false),
            meetingID: id
        )
        try await database.append(
            TranscriptSegment(id: segmentID, source: .microphone, text: "final", isFinal: true),
            meetingID: id
        )

        let stored = try await database.segments(for: id)
        #expect(stored.count == 1)
        #expect(stored.first?.text == "final")
        #expect(stored.first?.isFinal == true)
    }
}
