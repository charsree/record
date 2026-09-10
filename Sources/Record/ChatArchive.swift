import CryptoKit
import Foundation

/// A saved Kiro chat — persisted so restarts don't lose your conversation.
struct ChatArchiveEntry: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var turns: [ChatTurn]
    var createdAt: Date
    var updatedAt: Date

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let firstQuestion = turns.first?.question, !firstQuestion.isEmpty {
            let trimmed = firstQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(trimmed.prefix(60))
        }
        return "Chat " + createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    // Hashable — turns aren't naturally Hashable so we key by id + updatedAt.
    static func == (lhs: ChatArchiveEntry, rhs: ChatArchiveEntry) -> Bool {
        lhs.id == rhs.id && lhs.updatedAt == rhs.updatedAt && lhs.title == rhs.title
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(updatedAt)
    }
}

/// AES-GCM encrypted, on-disk store for Kiro chats. Local-only, uses the
/// same encryption key as the transcript database.
actor ChatArchive {
    private let url: URL
    private let key: SymmetricKey
    private var entries: [ChatArchiveEntry] = []
    private var loaded = false

    init(url: URL, key: SymmetricKey) {
        self.url = url
        self.key = key
    }

    static func production() throws -> ChatArchive {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let file = applicationSupport.appending(path: "Record/chats.enc")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return ChatArchive(url: file, key: try MeetingKey.load())
    }

    func load() -> [ChatArchiveEntry] {
        if !loaded {
            entries = readFromDisk()
            loaded = true
        }
        return entries
    }

    /// Insert or update a chat entry. Returns the up-to-date list.
    @discardableResult
    func upsert(_ entry: ChatArchiveEntry) throws -> [ChatArchiveEntry] {
        if !loaded { _ = load() }
        var updated = entry
        updated.updatedAt = .now
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = updated
        } else {
            entries.insert(updated, at: 0)
        }
        // Keep newest first.
        entries.sort { $0.updatedAt > $1.updatedAt }
        try writeToDisk(entries)
        return entries
    }

    func delete(_ id: UUID) throws -> [ChatArchiveEntry] {
        if !loaded { _ = load() }
        entries.removeAll { $0.id == id }
        try writeToDisk(entries)
        return entries
    }

    func rename(_ id: UUID, title: String) throws -> [ChatArchiveEntry] {
        if !loaded { _ = load() }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return entries }
        entries[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[index].updatedAt = .now
        try writeToDisk(entries)
        return entries
    }

    private func readFromDisk() -> [ChatArchiveEntry] {
        guard let ciphertext = try? Data(contentsOf: url), !ciphertext.isEmpty else {
            return []
        }
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            let plaintext = try AES.GCM.open(box, using: key)
            return try JSONDecoder().decode([ChatArchiveEntry].self, from: plaintext)
        } catch {
            return []
        }
    }

    private func writeToDisk(_ payload: [ChatArchiveEntry]) throws {
        let data = try JSONEncoder().encode(payload)
        guard let sealed = try AES.GCM.seal(data, using: key).combined else {
            throw MeetingDatabaseError.invalidCiphertext
        }
        try sealed.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
