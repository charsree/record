import CryptoKit
import Foundation
import Security
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum MeetingDatabaseError: LocalizedError {
    case sqlite(String)
    case invalidCiphertext

    var errorDescription: String? {
        switch self {
        case .sqlite(let message): "Meeting database error: \(message)"
        case .invalidCiphertext: "Stored meeting data could not be decrypted."
        }
    }
}

enum MeetingStatus: String, Codable, Sendable {
    case recording
    case complete
    case interrupted

    var title: String {
        switch self {
        case .recording: "Recording"
        case .complete: "Complete"
        case .interrupted: "Interrupted"
        }
    }
}

/// A saved meeting as listed in History. Transcript text is loaded separately.
struct MeetingRecord: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    let startedAt: Date
    var endedAt: Date?
    var status: MeetingStatus
    var segmentCount: Int
    var summary: String
    var tags: [String]

    var duration: TimeInterval {
        (endedAt ?? .now).timeIntervalSince(startedAt)
    }

    var displayTitle: String {
        title.isEmpty ? Self.defaultTitle(for: startedAt) : title
    }

    static func defaultTitle(for date: Date) -> String {
        "Meeting " + date.formatted(date: .abbreviated, time: .shortened)
    }
}

enum MeetingKey {
    private static let service = "local.record.app"
    private static let account = "meeting-encryption-key"

    /// Location of the on-disk key. Kept next to the SQLite database inside the
    /// user's Application Support directory so it inherits the same POSIX
    /// isolation as the encrypted transcripts themselves.
    private static func keyURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appending(path: "Record")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "meeting-key.bin")
    }

    static func load() throws -> SymmetricKey {
        let url = try keyURL()
        if let data = try? Data(contentsOf: url), data.count == 32 {
            return SymmetricKey(data: data)
        }
        // Migrate a previously stored legacy-keychain key if present so users
        // who ran an older build don't lose access to their transcripts.
        switch try readLegacyKeychainKey() {
        case .found(let data):
            try write(keyData: data, to: url)
            deleteLegacyKeychainKey()
            return SymmetricKey(data: data)
        case .missing:
            let key = SymmetricKey(size: .bits256)
            let bytes = key.withUnsafeBytes { Data($0) }
            try write(keyData: bytes, to: url)
            return key
        }
    }

    private enum LegacyLookup {
        case found(Data)
        case missing
    }

    private static func write(keyData: Data, to url: URL) throws {
        try keyData.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func readLegacyKeychainKey() throws -> LegacyLookup {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return .found(data) }
        if status == errSecItemNotFound { return .missing }
        // errSecUserCanceled, errSecAuthFailed etc. -> abort so we don't wipe
        // the user's existing encrypted transcripts by generating a new key.
        throw MeetingDatabaseError.sqlite(
            "Could not read the legacy encryption key from the login keychain (status \(status)). " +
            "Choose \"Always Allow\" the next time macOS prompts, then relaunch Record."
        )
    }

    private static func deleteLegacyKeychainKey() {
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)
    }
}

actor MeetingDatabase {
    private var handle: OpaquePointer?
    private let key: SymmetricKey

    init(url: URL, key: SymmetricKey) throws {
        self.key = key
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              handle != nil else {
            throw MeetingDatabaseError.sqlite("Could not open \(url.lastPathComponent)")
        }
        try Self.execute(handle, "PRAGMA journal_mode=WAL;")
        try Self.execute(handle, "PRAGMA secure_delete=ON;")
        try Self.execute(handle, "PRAGMA foreign_keys=ON;")
        try Self.execute(handle, """
            CREATE TABLE IF NOT EXISTS meetings (
                id TEXT PRIMARY KEY NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL,
                status TEXT NOT NULL
            );
        """)
        try Self.execute(handle, """
            CREATE TABLE IF NOT EXISTS segments (
                id TEXT PRIMARY KEY NOT NULL,
                meeting_id TEXT NOT NULL,
                source TEXT NOT NULL,
                recorded_at REAL NOT NULL,
                ciphertext BLOB NOT NULL,
                FOREIGN KEY(meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
            );
        """)
        try Self.execute(handle, "CREATE INDEX IF NOT EXISTS segments_meeting_time ON segments(meeting_id, recorded_at);")
        try Self.migrate(handle)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    deinit {
        // Sqlite handle cleanup on process exit is fine; skip actor-isolated
        // access here to stay compatible with Swift 6's nonisolated deinit.
    }

    static func productionURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport.appending(path: "Record/meetings.sqlite")
    }

    static func production() throws -> MeetingDatabase {
        try MeetingDatabase(url: productionURL(), key: MeetingKey.load())
    }

    // MARK: Meetings

    func startMeeting(title: String = "") throws -> UUID {
        let id = UUID()
        try execute(
            "INSERT INTO meetings (id, started_at, status, title) VALUES (?, ?, 'recording', ?);",
            values: [id.uuidString, Date.now.timeIntervalSince1970, title]
        )
        return id
    }

    func finishMeeting(_ id: UUID) throws {
        try execute(
            "UPDATE meetings SET ended_at = ?, status = 'complete' WHERE id = ?;",
            values: [Date.now.timeIntervalSince1970, id.uuidString]
        )
    }

    /// Marks a meeting that never produced audio as failed so it does not
    /// linger in the `recording` state.
    func abandonMeeting(_ id: UUID) throws {
        try execute(
            "UPDATE meetings SET ended_at = ?, status = 'interrupted' WHERE id = ?;",
            values: [Date.now.timeIntervalSince1970, id.uuidString]
        )
    }

    func recoverInterruptedMeetings() throws {
        try execute(
            "UPDATE meetings SET ended_at = ?, status = 'interrupted' WHERE status = 'recording';",
            values: [Date.now.timeIntervalSince1970]
        )
    }

    func renameMeeting(_ id: UUID, title: String) throws {
        try execute(
            "UPDATE meetings SET title = ? WHERE id = ?;",
            values: [title.trimmingCharacters(in: .whitespacesAndNewlines), id.uuidString]
        )
    }

    func setSummary(_ id: UUID, summary: String) throws {
        try execute(
            "UPDATE meetings SET summary = ? WHERE id = ?;",
            values: [summary, id.uuidString]
        )
    }

    func setTags(_ id: UUID, tags: [String]) throws {
        let joined = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: ",", with: " ") }
            .joined(separator: ",")
        try execute(
            "UPDATE meetings SET tags = ? WHERE id = ?;",
            values: [joined, id.uuidString]
        )
    }

    func deleteMeeting(_ id: UUID) throws {
        try execute("DELETE FROM segments WHERE meeting_id = ?;", values: [id.uuidString])
        try execute("DELETE FROM meetings WHERE id = ?;", values: [id.uuidString])
    }

    /// Removes meetings that ended without saving any transcript text.
    func deleteEmptyMeetings() throws {
        try execute("""
            DELETE FROM meetings
            WHERE status != 'recording'
              AND NOT EXISTS (SELECT 1 FROM segments WHERE segments.meeting_id = meetings.id);
        """)
    }

    /// Deletes meetings whose most-recent activity is older than `days` days.
    /// Uses `ended_at` when available, otherwise `started_at`. Segments
    /// cascade via the foreign key.
    func deleteMeetingsOlderThan(days: Int) throws {
        guard days > 0 else { return }
        let threshold = Date.now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        try execute("""
            DELETE FROM meetings
            WHERE COALESCE(ended_at, started_at) < ?;
        """, values: [threshold])
    }

    func meetings() throws -> [MeetingRecord] {
        guard let handle else { throw MeetingDatabaseError.sqlite("Database is closed.") }
        var statement: OpaquePointer?
        let sql = """
            SELECT m.id, m.title, m.started_at, m.ended_at, m.status, m.summary, m.tags,
                   (SELECT COUNT(*) FROM segments s WHERE s.meeting_id = m.id)
            FROM meetings m
            ORDER BY m.started_at DESC;
        """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }
        var result: [MeetingRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: idText)) else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let endedAt = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            let statusText = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
            let status = MeetingStatus(rawValue: statusText) ?? .interrupted
            let summary = sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? ""
            let tagsRaw = sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? ""
            let tags = tagsRaw.split(separator: ",").map { String($0) }
            let count = Int(sqlite3_column_int64(statement, 7))
            result.append(MeetingRecord(
                id: id,
                title: title,
                startedAt: startedAt,
                endedAt: endedAt,
                status: status,
                segmentCount: count,
                summary: summary,
                tags: tags
            ))
        }
        return result
    }

    // MARK: Segments

    func append(_ segment: TranscriptSegment, meetingID: UUID) throws {
        let payload = try JSONEncoder().encode(segment)
        let sealed = try AES.GCM.seal(payload, using: key).combined
        guard let sealed else { throw MeetingDatabaseError.invalidCiphertext }
        try execute(
            "INSERT OR REPLACE INTO segments (id, meeting_id, source, recorded_at, ciphertext) VALUES (?, ?, ?, ?, ?);",
            values: [
                segment.id.uuidString,
                meetingID.uuidString,
                segment.source.rawValue,
                segment.timestamp.timeIntervalSince1970,
                sealed
            ]
        )
    }

    func segments(for meetingID: UUID) throws -> [TranscriptSegment] {
        guard let handle else { throw MeetingDatabaseError.sqlite("Database is closed.") }
        var statement: OpaquePointer?
        let sql = "SELECT ciphertext FROM segments WHERE meeting_id = ? ORDER BY recorded_at ASC;"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, meetingID.uuidString, -1, sqliteTransient)
        var result: [TranscriptSegment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 0))
            let sealed = try AES.GCM.SealedBox(combined: Data(bytes: bytes, count: count))
            let decoded = try AES.GCM.open(sealed, using: key)
            result.append(try JSONDecoder().decode(TranscriptSegment.self, from: decoded))
        }
        return result
    }

    // MARK: SQL helpers

    private func execute(_ sql: String, values: [Any] = []) throws {
        guard let handle else { throw MeetingDatabaseError.sqlite("Database is closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let value as String:
                sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case let value as Double:
                sqlite3_bind_double(statement, index, value)
            case let value as Data:
                _ = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), sqliteTransient)
                }
            default:
                throw MeetingDatabaseError.sqlite("Unsupported SQL value.")
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func lastError() -> MeetingDatabaseError {
        MeetingDatabaseError.sqlite(String(cString: sqlite3_errmsg(handle)))
    }

    private nonisolated static func execute(_ handle: OpaquePointer?, _ sql: String) throws {
        var message: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(message)
            throw MeetingDatabaseError.sqlite(detail)
        }
    }

    /// Adds columns introduced after the first release. Older databases lack `title`.
    private nonisolated static func migrate(_ handle: OpaquePointer?) throws {
        if !columnExists(handle, table: "meetings", column: "title") {
            try execute(handle, "ALTER TABLE meetings ADD COLUMN title TEXT NOT NULL DEFAULT '';")
        }
        if !columnExists(handle, table: "meetings", column: "summary") {
            try execute(handle, "ALTER TABLE meetings ADD COLUMN summary TEXT NOT NULL DEFAULT '';")
        }
        if !columnExists(handle, table: "meetings", column: "tags") {
            // Comma-separated (no commas in tag values). Kept simple to avoid a join table.
            try execute(handle, "ALTER TABLE meetings ADD COLUMN tags TEXT NOT NULL DEFAULT '';")
        }
    }

    private nonisolated static func columnExists(_ handle: OpaquePointer?, table: String, column: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column {
                return true
            }
        }
        return false
    }
}
