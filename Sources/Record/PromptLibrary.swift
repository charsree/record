import Foundation
import SwiftUI

/// A saved Ask prompt the user can reapply.
struct PromptTemplate: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var body: String
}

/// UserDefaults-backed prompt store. Local-only; nothing leaves the machine.
@MainActor
final class PromptLibrary: ObservableObject {
    static let shared = PromptLibrary()

    @Published private(set) var prompts: [PromptTemplate] = []

    private let key = "record.promptLibrary.v1"
    private let defaults = UserDefaults.standard

    init() {
        load()
        if prompts.isEmpty {
            prompts = Self.builtInDefaults
            persist()
        }
    }

    static let builtInDefaults: [PromptTemplate] = [
        .init(name: "Summarize meeting", body: "Give me a one-paragraph summary of this meeting, then a bulleted list of the key decisions and the top three risks."),
        .init(name: "Action items", body: "Extract every action item mentioned in the meeting as a bulleted list. For each item include: the owner (if named), what needs to happen, and a due date if mentioned. Skip anything speculative."),
        .init(name: "Draft status update", body: "Write a concise status-update email from this meeting: what was decided, what's blocked, what's next, who owns each next step. Keep it under 200 words."),
        .init(name: "Draft follow-up email", body: "Draft a follow-up email to the attendees summarizing the discussion, decisions, and any action items with owners and dates. Keep it professional and under 250 words."),
        .init(name: "Explain jargon", body: "List every acronym, product code name, and technical term used in the meeting, with a one-sentence plain-English explanation for each.")
    ]

    func add(name: String, body: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedBody.isEmpty else { return }
        prompts.append(PromptTemplate(name: trimmedName, body: trimmedBody))
        persist()
    }

    /// Appends a template as-is (used by the manager UI when creating a
    /// blank draft the user will fill in before saving).
    func append(_ template: PromptTemplate) {
        prompts.append(template)
        persist()
    }

    func remove(_ id: PromptTemplate.ID) {
        prompts.removeAll { $0.id == id }
        persist()
    }

    func update(_ template: PromptTemplate) {
        guard let index = prompts.firstIndex(where: { $0.id == template.id }) else { return }
        prompts[index] = template
        persist()
    }

    func restoreDefaults() {
        prompts = Self.builtInDefaults
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(prompts) else { return }
        defaults.set(data, forKey: key)
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([PromptTemplate].self, from: data) else {
            return
        }
        prompts = decoded
    }
}
