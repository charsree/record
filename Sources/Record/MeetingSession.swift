import AppKit
import AVFoundation
import CoreMedia
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
final class MeetingSession: ObservableObject {
    static let shared = MeetingSession()

    // Live meeting state
    @Published private(set) var transcript: [TranscriptSegment] = []
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published var micMuted: Bool = false
    @Published private(set) var isBusy = false
    @Published private(set) var visualContextEnabled = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var chatTurns: [ChatTurn] = []
    @Published private(set) var pendingAttachments: [ChatAttachment] = []
    @Published private(set) var isAsking = false
    @Published private(set) var savedChats: [ChatArchiveEntry] = []
    @Published private(set) var activeChatID: UUID = UUID()
    @Published private(set) var importProgress: AudioFileTranscriber.Progress?
    private var activeChatCreatedAt: Date = .now
    private var chatArchive: ChatArchive?
    @Published private(set) var microphonePermissionText = "Not requested"
    @Published private(set) var screenPermissionText = "Not requested"
    @Published private(set) var transcriptionEngineText = "Local whisper not loaded"
    @Published private(set) var captureModeText = "Mic + system audio"
    @Published var selectedCaptureTarget: CaptureTarget = .primaryDisplay
    @Published private(set) var availableDisplays: [CaptureDisplay] = CaptureDisplay.current()
    @Published private(set) var availableWindows: [CaptureWindow] = []
    @Published private(set) var currentMeetingTitle: String = ""
    @Published private(set) var latestCapturePreview: Data?
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var micLevel: Float = 0     // 0…1, RMS-ish
    @Published private(set) var systemAudioLevel: Float = 0
    @Published var translationEnabled: Bool = TranslationDefaults.load() {
        didSet {
            TranslationDefaults.save(translationEnabled)
            micTranscriber.translate = translationEnabled
            systemTranscriber.translate = translationEnabled
        }
    }
    @Published var kiroEnabled: Bool = KiroEnabledDefaults.load() {
        didSet {
            KiroEnabledDefaults.save(kiroEnabled)
            if !kiroEnabled { Task { await resetChat() } }
        }
    }
    /// True iff a `kiro-cli` binary is discoverable on this machine.
    /// Refreshed on launch and whenever the user updates the executable
    /// override in Preferences. The UI hides chat + auto-summary
    /// controls when this is false so users who haven't installed Kiro
    /// don't see broken features.
    @Published private(set) var kiroAvailable: Bool = false

    /// Re-scan for `kiro-cli`. Call after the user edits the
    /// "Kiro executable override" field in Preferences → Kiro.
    func refreshKiroAvailability() {
        let available = kiro.isAvailable()
        kiroAvailable = available
        if !available {
            kiroEnabled = false
        }
    }

    // History state
    @Published private(set) var history: [MeetingRecord] = []
    @Published private(set) var selectedHistoryMeeting: MeetingRecord?
    @Published private(set) var selectedHistoryTranscript: [TranscriptSegment] = []
    @Published private(set) var historyStatusMessage: String?
    @Published var historyTagFilter: String? = nil {
        didSet { objectWillChange.send() }
    }
    @Published var historyDateFilter: DateFilter = .all {
        didSet { objectWillChange.send() }
    }

    enum DateFilter: Hashable {
        case all
        case today
        case thisWeek
        case thisMonth
        case last30Days

        var label: String {
            switch self {
            case .all: "All time"
            case .today: "Today"
            case .thisWeek: "This week"
            case .thisMonth: "This month"
            case .last30Days: "Last 30 days"
            }
        }

        func matches(_ date: Date) -> Bool {
            let cal = Calendar.current
            switch self {
            case .all: return true
            case .today: return cal.isDateInToday(date)
            case .thisWeek:
                return cal.isDate(date, equalTo: .now, toGranularity: .weekOfYear)
            case .thisMonth:
                return cal.isDate(date, equalTo: .now, toGranularity: .month)
            case .last30Days:
                return date.timeIntervalSince(Date.now.addingTimeInterval(-30 * 86_400)) >= 0
            }
        }
    }

    /// Meetings currently visible in the sidebar after applying the filter.
    var filteredHistory: [MeetingRecord] {
        var out = history
        if let tag = historyTagFilter {
            out = out.filter { m in
                m.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
            }
        }
        if historyDateFilter != .all {
            out = out.filter { historyDateFilter.matches($0.startedAt) }
        }
        return out
    }

    /// Related meetings for the selected history entry — meetings that share
    /// tags or top keywords with it. Runs on the archive index (no DB decrypt).
    var relatedMeetings: [MeetingRecord] {
        guard let target = selectedHistoryMeeting else { return [] }
        let targetTags = Set(target.tags.map { $0.lowercased() })
        let targetKeywords = Set(Self.topKeywords(from: target.summary + " " + target.title, limit: 20))
        // Score every other meeting by shared tags (weight 3) + shared summary keywords (1).
        let scored = history
            .filter { $0.id != target.id }
            .map { meeting -> (MeetingRecord, Int) in
                var score = 0
                let otherTags = Set(meeting.tags.map { $0.lowercased() })
                score += targetTags.intersection(otherTags).count * 3
                let otherKeywords = Set(Self.topKeywords(from: meeting.summary + " " + meeting.title, limit: 20))
                score += targetKeywords.intersection(otherKeywords).count
                return (meeting, score)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
        return scored.map(\.0)
    }

    private static func topKeywords(from text: String, limit: Int) -> [String] {
        let stopwords: Set<String> = [
            "the", "and", "for", "with", "this", "that", "have", "from",
            "your", "were", "was", "are", "you", "any", "what", "when",
            "who", "how", "why", "which", "does", "did", "meeting", "meetings",
            "then", "have", "will", "some", "about"
        ]
        let words = text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 && !stopwords.contains($0) }
        // Frequency-rank.
        var counts: [String: Int] = [:]
        for word in words { counts[word, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    /// All distinct tags across every meeting, sorted alphabetically.
    var allTags: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for meeting in history {
            for tag in meeting.tags where !seen.contains(tag.lowercased()) {
                seen.insert(tag.lowercased())
                out.append(tag)
            }
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    @Published var globalSearchQuery: String = ""
    @Published private(set) var globalSearchResults: [MeetingSearchHit] = []
    @Published private(set) var globalSearchInProgress: Bool = false
    private var searchTask: Task<Void, Never>?

    let store = TranscriptStore()
    private let microphone = AudioCaptureService()
    private let micTranscriber = LocalSpeechTranscriber()
    private let systemTranscriber = LocalSpeechTranscriber()
    private let systemCapture = SystemCaptureService()
    private let visualContext = VisualContextService()
    private let kiro = KiroACPClient()
    private let audioRecorder = MeetingAudioRecorder()
    private var database: MeetingDatabase?
    private var meetingID: UUID?
    private var systemAudioAvailable = false
    private var conversation: KiroConversation?
    private var currentAskTask: Task<Void, Never>?
    /// Segment IDs already sent to the current Kiro conversation as evidence.
    /// Used to include any transcript that arrived mid-chat (Snap & OCR, new
    /// utterances) as fresh context on the next follow-up.
    private var evidenceSentIDs: Set<UUID> = []
    /// Elapsed-active-time accounting so the header timer excludes paused
    /// intervals. `activeSegmentStart` is nil while paused.
    private var activeSegmentStart: Date?
    private var accumulatedActiveTime: TimeInterval = 0
    /// When we last heard audio above the silence threshold. Used for the
    /// auto-pause-on-silence setting.
    private var lastAudioActivityAt: Date?
    /// Ticks every second while recording. Enforces auto-pause and max-length.
    private var recordingWatchdog: Task<Void, Never>?

    /// Total active-recording time, correctly skipping paused intervals.
    var activeElapsed: TimeInterval {
        accumulatedActiveTime + (activeSegmentStart.map { Date.now.timeIntervalSince($0) } ?? 0)
    }
    /// Which context the conversation currently belongs to: the live meeting
    /// or a specific history meeting. Switching context ends the ACP session.
    private var conversationContext: ConversationContext?
    /// Which saved chat's turns are currently loaded. If Kiro's ACP process
    /// dies or we switch chats, we spawn a fresh process, but the prior turns
    /// stay in the UI. On the next send we include those turns as memory
    /// context so Kiro doesn't "forget" the conversation.
    private var conversationChatID: UUID?

    private enum ConversationContext: Equatable {
        case live
        case history(UUID)
        case allMeetings
    }

    var statusText: String {
        if !isRecording { return "Idle" }
        if isPaused { return "Paused" }
        if visualContextEnabled { return "Listening + screen" }
        return systemAudioAvailable ? "Listening" : "Listening (mic only)"
    }

    var lastTranscriptText: String {
        transcript.last?.text ?? ""
    }

    init() {
        // Detect kiro-cli up front so the UI can hide AI features when
        // the user hasn't installed it. This is a cheap filesystem probe
        // (no subprocess launch) that we redo whenever the user tweaks
        // the executable-override in Preferences.
        self.kiroAvailable = kiro.isAvailable()
        if !self.kiroAvailable {
            self.kiroEnabled = false
        }

        microphone.onPacket = { [weak self] packet in
            guard let self else { return }
            if self.micMuted { return }
            self.micTranscriber.append(packet)
            self.audioRecorder.writeMic(packet)
            self.updateMicLevel(from: packet.monoSamples)
        }
        micTranscriber.onLive = { [weak self] text in
            Task { await self?.updateLive(source: .microphone, text: text) }
        }
        micTranscriber.onFinal = { [weak self] text in
            Task { await self?.finalize(source: .microphone, text: text) }
        }
        micTranscriber.onError = { [weak self] error in self?.errorMessage = error }
        micTranscriber.translate = translationEnabled

        systemTranscriber.onLive = { [weak self] text in
            Task { await self?.updateLive(source: .systemAudio, text: text) }
        }
        systemTranscriber.onFinal = { [weak self] text in
            Task { await self?.finalize(source: .systemAudio, text: text) }
        }
        systemTranscriber.onError = { [weak self] error in self?.errorMessage = error }
        systemTranscriber.translate = translationEnabled

        systemCapture.onAudioPacket = { [weak self] packet in
            guard let self else { return }
            self.systemTranscriber.append(packet)
            self.audioRecorder.writeSystem(packet)
            self.updateSystemLevel(from: packet)
        }
        systemCapture.onScreenFrame = { [weak self] image in self?.visualContext.inspect(image) }
        systemCapture.onError = { [weak self] error in self?.errorMessage = error }

        visualContext.onText = { [weak self] text in
            Task { await self?.append(TranscriptSegment(source: .visual, text: text, isFinal: true)) }
        }
        visualContext.onFrameUpdated = { [weak self] jpeg in
            Task { @MainActor in self?.latestCapturePreview = jpeg }
        }

        Task { await bootstrap() }
    }

    // MARK: Lifecycle

    private func bootstrap() async {
        do {
            let database = try MeetingDatabase.production()
            try await database.recoverInterruptedMeetings()
            try await database.deleteEmptyMeetings()
            // Enforce retention policy from Preferences.
            let retentionDays = UserDefaults.standard.integer(forKey: "record.retentionDays")
            if retentionDays > 0 {
                try? await database.deleteMeetingsOlderThan(days: retentionDays)
            }
            self.database = database
            await refreshHistory()
        } catch {
            self.errorMessage = error.localizedDescription
        }
        // Load persisted chats.
        do {
            let archive = try ChatArchive.production()
            chatArchive = archive
            savedChats = await archive.load()
        } catch {
            errorMessage = "Could not load chat history: \(error.localizedDescription)"
        }
    }

    /// Save the current chat to the archive (upsert). No-op if the chat is
    /// still empty.
    private func persistCurrentChat() async {
        guard let archive = chatArchive, !chatTurns.isEmpty else { return }
        let entry = ChatArchiveEntry(
            id: activeChatID,
            title: currentChatTitle,
            turns: chatTurns,
            createdAt: activeChatCreatedAt,
            updatedAt: .now
        )
        do {
            let updated = try await archive.upsert(entry)
            savedChats = updated
        } catch {
            // Silent — not worth surfacing.
        }
    }

    private var currentChatTitle: String {
        savedChats.first(where: { $0.id == activeChatID })?.title ?? ""
    }

    func selectChat(_ id: UUID) async {
        guard let entry = savedChats.first(where: { $0.id == id }) else { return }
        // End the current Kiro session so it doesn't leak context.
        await conversation?.end()
        conversation = nil
        conversationContext = nil
        activeChatID = entry.id
        activeChatCreatedAt = entry.createdAt
        chatTurns = entry.turns
        // We can't be sure which turns Kiro has "seen" now that we're on a
        // fresh ACP session, so start fresh evidence tracking.
        evidenceSentIDs = []
    }

    func startNewChat() async {
        await persistCurrentChat()
        await conversation?.end()
        conversation = nil
        conversationContext = nil
        chatTurns = []
        pendingAttachments = []
        evidenceSentIDs = []
        activeChatID = UUID()
        activeChatCreatedAt = .now
    }

    func renameChat(_ id: UUID, to title: String) async {
        guard let archive = chatArchive else { return }
        do {
            savedChats = try await archive.rename(id, title: title)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteChat(_ id: UUID) async {
        guard let archive = chatArchive else { return }
        do {
            savedChats = try await archive.delete(id)
        } catch {
            errorMessage = error.localizedDescription
        }
        if activeChatID == id {
            chatTurns = []
            activeChatID = UUID()
            activeChatCreatedAt = .now
            pendingAttachments = []
            evidenceSentIDs = []
            await conversation?.end()
            conversation = nil
            conversationContext = nil
        }
    }

    func toggleRecording() async {
        if isRecording {
            await stop()
        } else {
            await start()
        }
    }

    /// Suspends audio capture without ending the meeting. The DB row stays
    /// in `recording` state; the elapsed timer freezes; the transcript so
    /// far is preserved. Resume with `resumeRecording()`.
    func togglePause() async {
        guard isRecording else { return }
        if isPaused {
            await resumeRecording()
        } else {
            await pauseRecording()
        }
    }

    /// Toggles star/highlight on a live transcript segment and persists.
    func toggleStar(segmentID: UUID) async {
        guard let updated = await store.toggleStar(segmentID) else { return }
        transcript = await store.all()
        if let database, let meetingID {
            try? await database.append(updated, meetingID: meetingID)
        }
    }

    /// Toggles star on a history segment (already-loaded selectedHistoryTranscript).
    func toggleStarInSelectedHistory(segmentID: UUID) async {
        guard let index = selectedHistoryTranscript.firstIndex(where: { $0.id == segmentID }) else { return }
        selectedHistoryTranscript[index].starred.toggle()
        let updated = selectedHistoryTranscript[index]
        if let database, let meeting = selectedHistoryMeeting {
            try? await database.append(updated, meetingID: meeting.id)
        }
    }

    /// Edits the text of a live-transcript segment and persists.
    func editSegment(id: UUID, newText: String) async {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Update the store in-place.
        var updated = await store.all()
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        updated[index].text = trimmed
        await store.replaceAll(with: updated)
        transcript = updated
        if let database, let meetingID {
            try? await database.append(updated[index], meetingID: meetingID)
        }
    }

    /// Edits the text of a segment in the selected history meeting.
    func editHistorySegment(id: UUID, newText: String) async {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = selectedHistoryTranscript.firstIndex(where: { $0.id == id }) else { return }
        selectedHistoryTranscript[index].text = trimmed
        if let database, let meeting = selectedHistoryMeeting {
            try? await database.append(selectedHistoryTranscript[index], meetingID: meeting.id)
        }
    }

    private func pauseRecording() async {
        guard isRecording, !isPaused else { return }
        isBusy = true
        defer { isBusy = false }
        microphone.stop()
        await systemCapture.stop()
        await micTranscriber.stop()
        await systemTranscriber.stop()
        // Freeze the elapsed timer.
        if let started = activeSegmentStart {
            accumulatedActiveTime += Date.now.timeIntervalSince(started)
            activeSegmentStart = nil
        }
        micLevel = 0
        systemAudioLevel = 0
        isPaused = true
    }

    private func resumeRecording() async {
        guard isRecording, isPaused else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await micTranscriber.start()
            try microphone.start()
            if systemAudioAvailable {
                try await systemTranscriber.start()
                try await systemCapture.start(
                    includeVisualFrames: visualContextEnabled,
                    displayID: selectedCaptureTarget.displayID,
                    windowID: selectedCaptureTarget.windowID
                )
            }
            activeSegmentStart = .now
            isPaused = false
        } catch {
            errorMessage = "Could not resume: \(error.localizedDescription)"
        }
    }

    func runSmokeTest() async -> String {
        await start()
        guard isRecording else {
            return "SMOKE_FAILED: \(errorMessage ?? "capture did not start")"
        }
        try? await Task.sleep(for: .seconds(2))
        await stop()
        return "SMOKE_PASSED: microphone, system audio, local whisper, and screen capture started"
    }

    func handleAppWillTerminate() {
        // Called from AppDelegate. Best-effort synchronous close so we don't
        // leave a meeting stuck in the `recording` status.
        microphone.stop()
        if let database, let meetingID {
            Task.detached { try? await database.finishMeeting(meetingID) }
        }
    }

    func refreshCaptureWindows() async {
        do {
            availableWindows = try await SystemCaptureService.windows()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Switch which display or window is being captured, on the fly. Restarts
    /// the ScreenCaptureKit stream if a meeting is currently recording.
    func changeCaptureTarget(_ target: CaptureTarget) async {
        selectedCaptureTarget = target
        guard isRecording else { return }
        await systemCapture.stop()
        do {
            try await systemCapture.start(
                includeVisualFrames: visualContextEnabled,
                displayID: target.displayID,
                windowID: target.windowID
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var currentSourceLabel: String {
        switch selectedCaptureTarget {
        case .primaryDisplay:
            return "Primary display"
        case .display(let id):
            return availableDisplays.first(where: { $0.id == id })?.title ?? "Display \(id)"
        case .window(let id):
            return availableWindows.first(where: { $0.id == id })?.title ?? "Window \(id)"
        }
    }

    /// Inserts a "Chapter" marker into the transcript at the current time.
    /// Also persists to the current meeting if one is recording.
    func insertChapter(title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Break the paragraph thread so the next speech utterance starts
        // a new row instead of being merged with the one before the
        // chapter marker.
        lastFinalizeAt.removeAll()
        await append(TranscriptSegment(source: .chapter, text: trimmed, isFinal: true))
    }

    /// Inserts a manual "Note" segment at the current time. The user types
    /// this from a small popover — useful for capturing a decision or
    /// context that wasn't spoken aloud.
    func insertNote(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastFinalizeAt.removeAll()
        await append(TranscriptSegment(source: .note, text: trimmed, isFinal: true))
    }

    /// Grabs a fresh, native-resolution screenshot of the currently selected
    /// source, runs accurate Vision OCR against it, appends the recognized
    /// text as a Screen segment, and returns the recognized string. Works
    /// whether or not a meeting is recording.
    func snapAndOCR() async -> String? {
        errorMessage = nil
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "record-snap-\(UUID().uuidString).png")
        // Get Record's window out of the way so the crosshair overlays a clean screen.
        let previousMainWindow = NSApp.keyWindow
        previousMainWindow?.orderOut(nil)
        defer {
            if let previousMainWindow {
                previousMainWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive; -x silent (no shutter); -o no drop-shadow when a window is picked.
        process.arguments = ["-i", "-x", "-o", tempURL.path]
        do {
            try process.run()
        } catch {
            errorMessage = "Could not launch screencapture: \(error.localizedDescription)"
            return nil
        }
        await Task.detached { process.waitUntilExit() }.value

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tempURL.path),
              let image = NSImage(contentsOf: tempURL),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            // User pressed Esc, or nothing to read — silent.
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let text = await VisualContextService.recognizeText(from: cg)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = "No text detected in the selection."
            return nil
        }
        // Log the grab in the transcript so it's searchable/exportable,
        // AND queue it as a pending attachment so the next Ask carries it
        // to Kiro even if it lands mid-conversation (evidence is only sent
        // on the first turn of a chat).
        await append(TranscriptSegment(source: .visual, text: text, isFinal: true))
        let stamp = Date.now.formatted(date: .omitted, time: .shortened)
        addPastedText(text, label: "Grabbed screen text \(stamp).txt")
        // Also drop it onto the pasteboard, macpowertools-style.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return text
    }

    func toggleVisualContext() async {
        guard isRecording else { return }
        let enableVisuals = !visualContextEnabled
        if enableVisuals, !systemCapture.requestPermission() {
            screenPermissionText = "Denied"
            errorMessage = "Screen Recording permission is required for visual context."
            return
        }

        await systemCapture.stop()
        do {
            try await systemCapture.start(
                includeVisualFrames: enableVisuals,
                displayID: selectedCaptureTarget.displayID,
                windowID: selectedCaptureTarget.windowID
            )
            visualContextEnabled = enableVisuals
            systemAudioAvailable = true
            captureModeText = enableVisuals ? "Mic + system audio + screen" : "Mic + system audio"
        } catch {
            visualContextEnabled = false
            errorMessage = error.localizedDescription
            try? await systemCapture.start(
                includeVisualFrames: false,
                displayID: selectedCaptureTarget.displayID,
                windowID: selectedCaptureTarget.windowID
            )
        }
    }

    // MARK: Ask

    func ask(_ question: String) async {
        await sendChatMessage(
            question: question,
            context: .live,
            evidenceProvider: { await self.store.evidence(for: question) },
            visualImage: visualContextEnabled ? visualContext.latestFrameJPEG : nil,
            emptyEvidenceMessage: "There's no meeting evidence yet."
        )
    }

    func askHistoryQuestion(_ question: String) async {
        guard let selectedHistoryMeeting else { return }
        let context = ConversationContext.history(selectedHistoryMeeting.id)
        let scratch = TranscriptStore()
        await scratch.replaceAll(with: selectedHistoryTranscript)
        await sendChatMessage(
            question: question,
            context: context,
            evidenceProvider: { await scratch.evidence(for: question) },
            visualImage: nil,
            emptyEvidenceMessage: "No matching evidence in \(selectedHistoryMeeting.displayTitle)."
        )
    }

    /// Ask across every saved meeting — evidence is drawn from the whole
    /// archive using the same MeetingSearch we already built.
    func askAcrossAllMeetings(_ question: String) async {
        let context = ConversationContext.allMeetings
        let database = self.database
        let meetings = self.history
        await sendChatMessage(
            question: question,
            context: context,
            evidenceProvider: {
                await Self.buildArchiveEvidence(
                    question: question,
                    meetings: meetings,
                    database: database
                )
            },
            visualImage: nil,
            emptyEvidenceMessage: "No meetings are saved yet."
        )
    }

    /// Builds a two-layer evidence bundle for archive-wide questions:
    /// (1) a synthetic meeting index — one pseudo-segment per meeting with
    /// its title / date / duration / summary / tags — so Kiro can always
    /// answer meta questions ("what meetings did I have?", "summarize the
    /// last N", "when did we talk about X"); and (2) any actual transcript
    /// segments that match keywords from the question.
    private static func buildArchiveEvidence(
        question: String,
        meetings: [MeetingRecord],
        database: MeetingDatabase?
    ) async -> [TranscriptSegment] {
        var evidence: [TranscriptSegment] = []

        // 1. Meeting index — cap to newest 50 so the prompt doesn't blow up.
        for meeting in meetings.prefix(50) {
            let dateStr = meeting.startedAt.formatted(date: .abbreviated, time: .shortened)
            let durationMinutes = Int(meeting.duration / 60)
            let tags = meeting.tags.isEmpty ? "none" : meeting.tags.joined(separator: ", ")
            let summary = meeting.summary.isEmpty ? "(not summarized)" : meeting.summary
            let text = """
            Meeting "\(meeting.displayTitle)" on \(dateStr) · \(durationMinutes) min · \
            \(meeting.segmentCount) transcript segments · tags: \(tags).
            Summary: \(summary)
            """
            evidence.append(TranscriptSegment(
                source: .note,
                timestamp: meeting.startedAt,
                text: text,
                isFinal: true
            ))
        }

        // 2. Keyword-matched segments from actual transcripts.
        guard let database else { return evidence }
        let terms = extractKeywords(from: question)
        var seenSegmentIDs = Set<UUID>()
        for term in terms {
            let hits = await MeetingSearch.run(query: term, database: database)
            for hit in hits.prefix(8) where !seenSegmentIDs.contains(hit.segment.id) {
                seenSegmentIDs.insert(hit.segment.id)
                // Prepend the meeting title to each snippet so Kiro can cite it.
                let annotated = TranscriptSegment(
                    id: hit.segment.id,
                    source: hit.segment.source,
                    timestamp: hit.segment.timestamp,
                    text: "[From “\(hit.meeting.displayTitle)”] \(hit.segment.text)",
                    isFinal: true,
                    starred: hit.segment.starred
                )
                evidence.append(annotated)
            }
        }
        return evidence
    }

    /// Naive keyword extraction: lower-cased tokens of ≥4 chars, minus a
    /// tiny stop-list. Good enough to find "action items", "rollout",
    /// "Priya" without pretending to be a search engine.
    private static func extractKeywords(from question: String) -> [String] {
        let stopwords: Set<String> = [
            "the", "and", "for", "with", "this", "that", "have", "from",
            "your", "were", "was", "are", "you", "any", "what", "when",
            "who", "how", "why", "which", "does", "did", "meeting", "meetings",
            "please", "me", "my", "our", "us", "about", "list", "show"
        ]
        return question
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 && !stopwords.contains($0) }
    }

    /// Wipes the chat thread and terminates the underlying kiro-cli process
    /// so the next question starts a fresh conversation with no memory.
    /// Persists the current chat first so nothing is lost.
    func resetChat() async {
        await persistCurrentChat()
        currentAskTask?.cancel()
        currentAskTask = nil
        await conversation?.end()
        conversation = nil
        conversationContext = nil
        chatTurns = []
        pendingAttachments = []
        evidenceSentIDs = []
        activeChatID = UUID()
        activeChatCreatedAt = .now
    }

    // MARK: Attachments

    func addAttachments(from urls: [URL]) {
        Task { await self.importAttachments(urls: urls) }
    }

    private func importAttachments(urls: [URL]) async {
        var newAttachments: [ChatAttachment] = []
        var errors: [String] = []
        // Run extraction off the main actor so a slow .docx (unzip) or a big
        // PDF doesn't freeze the UI.
        for url in urls {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ChatAttachment, Error> in
                do {
                    let attachment = try AttachmentImporter.makeAttachment(from: url)
                    return .success(attachment)
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let attachment):
                newAttachments.append(attachment)
            case .failure(let error):
                errors.append(error.localizedDescription)
            }
        }
        pendingAttachments.append(contentsOf: newAttachments)
        if !errors.isEmpty {
            errorMessage = errors.joined(separator: "\n")
        }
    }

    /// Adds a pasted string as an in-memory attachment. Useful when the user
    /// wants to give Kiro context that isn't stored in a file (a Slack thread,
    /// a code snippet, a copied wiki paragraph).
    func addPastedText(_ text: String, label: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let filename = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Pasted \(Date.now.formatted(date: .omitted, time: .shortened)).txt"
        let attachment = ChatAttachment(
            filename: filename,
            byteSize: trimmed.utf8.count,
            payload: .text(trimmed)
        )
        pendingAttachments.append(attachment)
    }

    func removeAttachment(_ id: ChatAttachment.ID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// Cancels any in-flight ask without wiping the thread. Also nukes the
    /// kiro-cli process so a stuck subprocess doesn't hold up the next try.
    func cancelAsk() async {
        currentAskTask?.cancel()
        currentAskTask = nil
        await conversation?.end()
        conversation = nil
        conversationContext = nil
        if let index = chatTurns.lastIndex(where: { $0.isLoading }) {
            chatTurns[index].isLoading = false
            chatTurns[index].errorMessage = "Cancelled."
        }
        isAsking = false
    }

    private func sendChatMessage(
        question: String,
        context: ConversationContext,
        evidenceProvider: () async -> [TranscriptSegment],
        visualImage: Data?,
        emptyEvidenceMessage: String
    ) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil

        let turnIndex = chatTurns.count
        chatTurns.append(ChatTurn(
            question: trimmed,
            answer: "",
            isLoading: true,
            errorMessage: nil,
            timestamp: .now
        ))
        isAsking = true
        defer { isAsking = false }

        let evidence = await evidenceProvider()

        // Snapshot attachments now, before we do anything that might clear them.
        let attachments = pendingAttachments
        let textAttachments = attachments.compactMap { attachment -> String? in
            if case .text = attachment.payload { return attachment.promptRepresentation }
            return nil
        }
        let extraImages = attachments.compactMap(\.jpegPayload)
        pendingAttachments = []  // consumed by this send
        if !attachments.isEmpty {
            chatTurns[turnIndex].attachmentNames = attachments.map(\.filename)
        }

        // Only bail when we truly have nothing to send.
        guard !evidence.isEmpty || !attachments.isEmpty || kiroEnabled else {
            chatTurns[turnIndex].answer = emptyEvidenceMessage
            chatTurns[turnIndex].isLoading = false
            return
        }

        // Local-only mode: skip kiro-cli, return the matching evidence as-is.
        if !kiroEnabled {
            let localBody: String
            if !evidence.isEmpty {
                localBody = Self.localEvidenceAnswer(for: trimmed, evidence: evidence)
            } else {
                localBody = "Kiro is off. Attached files: \(attachments.map(\.filename).joined(separator: ", "))."
            }
            chatTurns[turnIndex].answer = localBody
            chatTurns[turnIndex].isLoading = false
            return
        }

        // If Kiro's ACP session is tied to a different chat/context than
        // ours, terminate it and start a fresh one. IMPORTANT: we keep the
        // UI's `chatTurns` intact — resuming a saved chat should not erase
        // earlier messages just because Kiro's process was gone.
        let sessionMismatch = (conversationContext != context) || (conversationChatID != activeChatID)
        if sessionMismatch {
            await conversation?.end()
            conversation = kiro.startConversation()
            conversationContext = context
            conversationChatID = activeChatID
            evidenceSentIDs = []
        }
        if conversation == nil {
            conversation = kiro.startConversation()
        }

        // First message on THIS Kiro session — either brand-new chat, or
        // resumed one where the process was killed. Include prior turns as
        // memory so Kiro doesn't "forget" the conversation.
        let priorTurns = Array(chatTurns.dropLast()) // exclude the just-appended pending turn
        let isFirstOnThisSession = sessionMismatch || priorTurns.isEmpty
        var prompt: String
        if isFirstOnThisSession {
            let promptMode: KiroPrompt.Mode = (context == .allMeetings) ? .archive : .singleMeeting
            prompt = KiroPrompt.opening(
                question: trimmed,
                evidence: evidence,
                hasAttachments: !attachments.isEmpty,
                priorTurns: priorTurns.isEmpty ? nil : priorTurns,
                mode: promptMode
            )
            evidenceSentIDs = Set(evidence.map(\.id))
        } else {
            // Same Kiro session — its memory already has everything before.
            let newEvidence = evidence.filter { !evidenceSentIDs.contains($0.id) }
            if newEvidence.isEmpty {
                prompt = trimmed
            } else {
                let block = newEvidence.map {
                    "[\($0.timestamp.formatted(date: .omitted, time: .standard))] \($0.source.title): \($0.text)"
                }.joined(separator: "\n")
                prompt = """
                \(trimmed)

                (New transcript entries since my last message — please consider these as additional context)
                \(block)
                """
                evidenceSentIDs.formUnion(newEvidence.map(\.id))
            }
        }
        if !textAttachments.isEmpty {
            prompt += "\n\nAttached documents (use these as context; they belong to this question):\n\n"
            prompt += textAttachments.joined(separator: "\n\n")
        }

        guard let conversation else {
            let latest = chatTurns.count - 1
            chatTurns[latest].isLoading = false
            chatTurns[latest].errorMessage = "kiro-cli is not available. Turn off Kiro in preferences to use local-only search, or set RECORD_KIRO_CLI to its absolute path."
            errorMessage = chatTurns[latest].errorMessage
            return
        }

        do {
            let answer = try await conversation.send(
                prompt: prompt,
                visualImage: visualImage,
                extraImages: extraImages
            )
            let latest = chatTurns.count - 1
            chatTurns[latest].answer = answer
            chatTurns[latest].isLoading = false
            await persistCurrentChat()
        } catch {
            let latest = chatTurns.count - 1
            chatTurns[latest].isLoading = false
            chatTurns[latest].errorMessage = error.localizedDescription
            await persistCurrentChat()
            await conversation.end()
            self.conversation = nil
            self.conversationContext = nil
        }
    }

    /// Local, LLM-free answer: renders the top evidence snippets as bullets.
    private static func localEvidenceAnswer(for question: String, evidence: [TranscriptSegment]) -> String {
        let bullets = evidence.prefix(8).map { segment in
            let time = segment.timestamp.formatted(date: .omitted, time: .shortened)
            return "- **[\(time)] \(segment.source.title)**: \(segment.text)"
        }.joined(separator: "\n")
        return """
        Kiro is off, so here are the matching transcript segments for **\(question)**:

        \(bullets)
        """
    }

    // MARK: Start / stop

    private func start() async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        smokeLog("checking microphone permission")
        let micAllowed = await microphone.requestPermission()
        microphonePermissionText = micAllowed ? "Allowed" : "Denied"
        smokeLog("microphone permission: \(micAllowed)")
        guard micAllowed else {
            errorMessage = "Microphone permission is required."
            return
        }

        smokeLog("checking screen recording permission")
        let screenAllowed = systemCapture.requestPermission()
        screenPermissionText = screenAllowed ? "Allowed" : "Denied"
        systemAudioAvailable = screenAllowed
        smokeLog("screen recording permission: \(screenAllowed)")
        if !screenAllowed {
            errorMessage = "Screen Recording permission is off — recording microphone only. Grant it in System Settings › Privacy & Security › Screen Recording to also capture what others say."
        }

        do {
            smokeLog("opening encrypted meeting store")
            if database == nil {
                database = try MeetingDatabase.production()
            }
            // Preserve any chapter/note segments the user added before hitting
            // Start — those should belong to the new meeting.
            let preExisting = await store.all()
            await store.reset()
            for segment in preExisting {
                await store.append(segment)
            }
            transcript = await store.all()
            // NOTE: intentionally NOT resetting the Kiro chat here — the
            // user might already be mid-conversation. Live-meeting evidence
            // flows into the same chat via the "new transcript since last
            // send" mechanism.
            let title = MeetingRecord.defaultTitle(for: .now)
            currentMeetingTitle = title
            meetingID = try await database?.startMeeting(title: title)
            if let meetingID {
                try? audioRecorder.start(meetingID: meetingID)
            }
            // Persist the pre-existing segments into the newly-created meeting.
            if let database, let meetingID {
                for segment in preExisting {
                    try? await database.append(segment, meetingID: meetingID)
                }
            }
            smokeLog("loading local whisper model")
            try await micTranscriber.start()
            transcriptionEngineText = "Local whisper loaded"
            smokeLog("starting microphone engine")
            try microphone.start()
            if screenAllowed {
                try await systemTranscriber.start()
                smokeLog("starting system audio capture")
                try await systemCapture.start(
                    includeVisualFrames: visualContextEnabled,
                    displayID: selectedCaptureTarget.displayID,
                    windowID: selectedCaptureTarget.windowID
                )
                captureModeText = visualContextEnabled ? "Mic + system audio + screen" : "Mic + system audio"
            } else {
                captureModeText = "Mic only"
            }
            isRecording = true
            recordingStartedAt = .now
            activeSegmentStart = .now
            accumulatedActiveTime = 0
            isPaused = false
            lastAudioActivityAt = .now
            lastFinalizeAt.removeAll()
            startRecordingWatchdog()
            playStartStopSoundIfEnabled()
            smokeLog("capture started")
        } catch {
            microphone.stop()
            await micTranscriber.stop()
            await systemTranscriber.stop()
            transcriptionEngineText = "Local whisper unavailable"
            if let database, let meetingID {
                try? await database.abandonMeeting(meetingID)
            }
            meetingID = nil
            errorMessage = error.localizedDescription
            smokeLog("capture failed: \(error.localizedDescription)")
        }
    }

    private func smokeLog(_ message: String) {
        guard ProcessInfo.processInfo.arguments.contains("--smoke-start") else { return }
        FileHandle.standardError.write(Data("SMOKE_STEP: \(message)\n".utf8))
    }

    private func stop() async {
        isBusy = true
        microphone.stop()
        await systemCapture.stop()
        await micTranscriber.stop()
        await systemTranscriber.stop()
        audioRecorder.stop()
        let finishedMeetingID = meetingID
        let finishedTranscript = await store.all()
        if let database, let meetingID {
            try? await database.finishMeeting(meetingID)
        }
        meetingID = nil
        isRecording = false
        isPaused = false
        visualContextEnabled = false
        captureModeText = "Mic + system audio"
        recordingStartedAt = nil
        activeSegmentStart = nil
        accumulatedActiveTime = 0
        micLevel = 0
        systemAudioLevel = 0
        latestCapturePreview = nil
        stopRecordingWatchdog()
        playStartStopSoundIfEnabled()
        postStopNotificationIfEnabled()
        await refreshHistory()
        isBusy = false

        // Kick off summary/title generation in the background so we don't
        // block the UI. Uses a separate Kiro conversation from any chat
        // the user has open, so their chat context isn't polluted.
        if let finishedMeetingID {
            Task { await self.autoAnnotate(meetingID: finishedMeetingID, segments: finishedTranscript) }
            Task.detached { await Self.runPostMeetingHook(
                meetingID: finishedMeetingID,
                segments: finishedTranscript,
                title: self.currentMeetingTitle
            ) }
        }
    }

    /// Runs the user-configured post-meeting shell script (from Preferences)
    /// with a plain-text transcript file as $1. Best-effort; failures are
    /// silent. Runs off the main actor so slow scripts don't stall the UI.
    private nonisolated static func runPostMeetingHook(
        meetingID: UUID,
        segments: [TranscriptSegment],
        title: String
    ) async {
        let scriptPath = UserDefaults.standard.string(forKey: "record.postStopScriptPath")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !scriptPath.isEmpty,
              FileManager.default.isExecutableFile(atPath: scriptPath) else { return }
        // Write the transcript to a temp file.
        let displayTitle = title.isEmpty ? "Meeting \(meetingID.uuidString.prefix(8))" : title
        let text = TranscriptExporter.render(
            segments,
            title: displayTitle,
            startedAt: segments.first?.timestamp ?? .now,
            summary: "",
            tags: [],
            as: .txt
        )
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "record-hook-\(meetingID.uuidString).txt")
        do {
            try Data(text.utf8).write(to: tempURL, options: .atomic)
        } catch {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: scriptPath)
        process.arguments = [tempURL.path]
        do { try process.run() } catch { return }
        // We fire-and-forget. The script is responsible for cleaning up the temp file.
    }

    /// Imports a `.wav`/`.mp3`/`.m4a`/… audio file, transcribes it locally,
    /// and saves the result as a new meeting in History.
    func importAudioFile(_ url: URL) async {
        guard let database else { return }
        errorMessage = nil
        importProgress = AudioFileTranscriber.Progress(
            completedSeconds: 0, totalSeconds: 0, stage: .reading
        )
        do {
            _ = try await AudioFileTranscriber.transcribe(
                url: url,
                database: database,
                translate: translationEnabled,
                progress: { [weak self] progress in
                    Task { @MainActor in self?.importProgress = progress }
                }
            )
            await refreshHistory()
            importProgress = nil
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
            importProgress = nil
        }
    }
    func regenerateSummaryAndTitle(for meeting: MeetingRecord) async {
        guard let database else { return }
        do {
            let segments = try await database.segments(for: meeting.id)
            await autoAnnotate(meetingID: meeting.id, segments: segments)
        } catch {
            historyStatusMessage = "Could not regenerate: \(error.localizedDescription)"
        }
    }

    /// Asks Kiro for a short title + a 2–3 sentence summary of the meeting,
    /// then saves both back to the database. Runs on a throwaway Kiro
    /// conversation so it doesn't touch the user's live chat.
    private func autoAnnotate(meetingID: UUID, segments: [TranscriptSegment]) async {
        // Nothing to do without Kiro — recording + transcription work
        // without it, but summaries require the subprocess.
        guard kiroAvailable, kiroEnabled else { return }
        let wantTitle = UserDefaults.standard.object(forKey: "record.autoTitleOnStop") == nil
            ? true : UserDefaults.standard.bool(forKey: "record.autoTitleOnStop")
        let wantSummary = UserDefaults.standard.object(forKey: "record.autoSummaryOnStop") == nil
            ? true : UserDefaults.standard.bool(forKey: "record.autoSummaryOnStop")
        guard wantTitle || wantSummary else { return }

        let finalSegments = segments.filter { $0.isFinal }
        // Any transcript with real content is worth annotating — even a
        // one-sentence meeting is fine. Only skip if the transcript is
        // essentially empty (nothing for Kiro to summarize).
        let totalCharacters = finalSegments.reduce(0) { $0 + $1.text.count }
        guard !finalSegments.isEmpty, totalCharacters >= 20 else { return }
        guard let conversation = kiro.startConversation() else { return }
        defer { Task { await conversation.end() } }

        let transcript = finalSegments.map {
            "[\($0.timestamp.formatted(date: .omitted, time: .standard))] \($0.source.title): \($0.text)"
        }.joined(separator: "\n")

        let template = UserDefaults.standard.string(forKey: "record.summaryPromptTemplate")
            ?? RecordSettings.defaultSummaryPrompt
        let prompt = template.replacingOccurrences(of: "{TRANSCRIPT}", with: transcript)

        do {
            self.isBusy = true
            defer { self.isBusy = false }
            let answer = try await conversation.send(prompt: prompt)
            let (title, summary) = Self.parseAnnotation(from: answer)
            if wantTitle, !title.isEmpty {
                try? await database?.renameMeeting(meetingID, title: title)
            }
            if wantSummary, !summary.isEmpty {
                try? await database?.setSummary(meetingID, summary: summary)
            }
            await refreshHistory()
            if selectedHistoryMeeting?.id == meetingID,
               let updated = history.first(where: { $0.id == meetingID }) {
                selectedHistoryMeeting = updated
            }
        } catch {
            errorMessage = "Auto-summary failed: \(error.localizedDescription)"
        }
    }

    private static func parseAnnotation(from answer: String) -> (title: String, summary: String) {
        var title = ""
        var summary = ""
        var reading: String? = nil
        for rawLine in answer.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let range = trimmed.range(of: "TITLE:", options: .caseInsensitive) {
                let value = trimmed[range.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                title = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                reading = "title"
            } else if let range = trimmed.range(of: "SUMMARY:", options: .caseInsensitive) {
                let value = trimmed[range.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                summary = value
                reading = "summary"
            } else if reading == "summary", !trimmed.isEmpty {
                summary += (summary.isEmpty ? "" : " ") + trimmed
            }
        }
        return (title, summary)
    }

    // MARK: Transcript plumbing

    private func updateLive(source: TranscriptSource, text: String) async {
        _ = await store.replaceLive(source: source, text: text)
        transcript = await store.all()
    }

    /// Maximum silence gap (seconds) between two finalized utterances
    /// that still counts as "the same paragraph". Tuned to match how
    /// Apple Voice Memos groups continuous speech into paragraphs —
    /// short pauses (breath, filler word) stay on the same row; longer
    /// pauses start a new one. Explicit chapter/note inserts always
    /// break the paragraph too.
    private static let paragraphGapSeconds: TimeInterval = 2.5
    /// If a paragraph grows past this many characters, force a break on
    /// the next finalize so no row becomes an unreadable wall of text.
    private static let paragraphMaxCharacters = 700
    private var lastFinalizeAt: [TranscriptSource: Date] = [:]

    private func finalize(source: TranscriptSource, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            _ = await store.finalizeLive(source: source, text: trimmed)
            transcript = await store.all()
            return
        }

        let now = Date()
        let previousFinalizeAt = lastFinalizeAt[source]
        lastFinalizeAt[source] = now

        // Should this utterance fold into the previous paragraph?
        // Yes when: (1) we just finalized recently, and (2) that
        // paragraph isn't already at the size cap. Otherwise it starts a
        // new paragraph. Matches Apple Voice Memos' behavior where a
        // continuous burst of speech reads as one flowing paragraph.
        let canMerge: Bool
        if let previous = previousFinalizeAt,
           now.timeIntervalSince(previous) < Self.paragraphGapSeconds,
           let last = await store.lastFinal(for: source),
           last.text.count < Self.paragraphMaxCharacters {
            canMerge = true
        } else {
            canMerge = false
        }

        if canMerge,
           let merged = await store.appendToLastFinal(source: source, additionalText: trimmed) {
            transcript = await store.all()
            if let database, let meetingID {
                try? await database.append(merged, meetingID: meetingID)
            }
            return
        }

        let finalized = await store.finalizeLive(source: source, text: trimmed)
        transcript = await store.all()
        if let finalized, let database, let meetingID {
            try? await database.append(finalized, meetingID: meetingID)
        }
    }

    private func append(_ segment: TranscriptSegment) async {
        await store.append(segment)
        transcript = await store.all()
        if let database, let meetingID {
            try? await database.append(segment, meetingID: meetingID)
        }
    }

    // MARK: History

    func refreshHistory() async {
        guard let database else { return }
        do {
            history = try await database.meetings()
            historyStatusMessage = nil
        } catch {
            historyStatusMessage = error.localizedDescription
        }
    }

    /// Debounced cross-meeting search. Cancels a previous in-flight query.
    func runGlobalSearch() {
        searchTask?.cancel()
        let query = globalSearchQuery
        guard let database else {
            globalSearchResults = []
            return
        }
        globalSearchInProgress = true
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            if Task.isCancelled { return }
            let hits = await MeetingSearch.run(query: query, database: database)
            if Task.isCancelled { return }
            self?.globalSearchResults = hits
            self?.globalSearchInProgress = false
        }
    }

    func clearGlobalSearch() {
        searchTask?.cancel()
        searchTask = nil
        globalSearchQuery = ""
        globalSearchResults = []
        globalSearchInProgress = false
    }

    func selectHistoryMeeting(_ meeting: MeetingRecord?) async {
        selectedHistoryMeeting = meeting
        // Don't nuke the chat — the user may want to keep talking to Kiro
        // while browsing meetings. If they ask a question specifically about
        // a history meeting, sendChatMessage will already terminate the
        // Kiro ACP session and start a new one with the right evidence.
        guard let meeting, let database else {
            selectedHistoryTranscript = []
            return
        }
        do {
            selectedHistoryTranscript = try await database.segments(for: meeting.id)
            historyStatusMessage = nil
        } catch {
            selectedHistoryTranscript = []
            historyStatusMessage = "Could not decrypt \(meeting.displayTitle): \(error.localizedDescription)"
        }
    }

    func renameSelectedMeeting(_ newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let meeting = selectedHistoryMeeting, let database, !trimmed.isEmpty else { return }
        do {
            try await database.renameMeeting(meeting.id, title: trimmed)
            var updated = meeting
            updated.title = trimmed
            selectedHistoryMeeting = updated
            await refreshHistory()
        } catch {
            historyStatusMessage = error.localizedDescription
        }
    }

    func addTagToSelected(_ tag: String) async {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var meeting = selectedHistoryMeeting, let database, !trimmed.isEmpty else { return }
        guard !meeting.tags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        meeting.tags.append(trimmed)
        do {
            try await database.setTags(meeting.id, tags: meeting.tags)
            selectedHistoryMeeting = meeting
            await refreshHistory()
        } catch {
            historyStatusMessage = error.localizedDescription
        }
    }

    func removeTagFromSelected(_ tag: String) async {
        guard var meeting = selectedHistoryMeeting, let database else { return }
        meeting.tags.removeAll { $0 == tag }
        do {
            try await database.setTags(meeting.id, tags: meeting.tags)
            selectedHistoryMeeting = meeting
            await refreshHistory()
        } catch {
            historyStatusMessage = error.localizedDescription
        }
    }

    func deleteSelectedMeeting() async {
        guard let meeting = selectedHistoryMeeting, let database else { return }
        do {
            try await database.deleteMeeting(meeting.id)
            MeetingAudioRecorder.deleteAudio(for: meeting.id)
            selectedHistoryMeeting = nil
            selectedHistoryTranscript = []
            await refreshHistory()
        } catch {
            historyStatusMessage = error.localizedDescription
        }
    }

    /// Returns the full transcript text of the currently selected history
    /// meeting, ready to save to disk from a SwiftUI file exporter.
    func selectedMeetingExportText() -> String? {
        guard let meeting = selectedHistoryMeeting else { return nil }
        return TranscriptFormatter.plainText(
            selectedHistoryTranscript,
            title: meeting.displayTitle,
            startedAt: meeting.startedAt
        )
    }

    func liveExportText() -> String {
        TranscriptFormatter.plainText(
            transcript,
            title: currentMeetingTitle.isEmpty ? "Live meeting" : currentMeetingTitle,
            startedAt: recordingStartedAt ?? .now
        )
    }

    /// Copies text to the pasteboard so callers don't need to import AppKit.
    func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Audio-level meters

    private func updateMicLevel(from samples: [Float]) {
        let level = Self.rmsLevel(samples)
        Task { @MainActor in
            self.micLevel = level
            if level > 0.05 { self.lastAudioActivityAt = .now }
        }
    }

    private func updateSystemLevel(from packet: SystemAudioPacket) {
        let mono = LocalAudioMath.monoSamples(
            fromInterleavedFloatData: packet.data,
            channelCount: Int(packet.channelCount)
        )
        let level = Self.rmsLevel(mono)
        Task { @MainActor in
            self.systemAudioLevel = level
            if level > 0.05 { self.lastAudioActivityAt = .now }
        }
    }

    private static func rmsLevel(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let energy = samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(samples.count)
        let rms = sqrt(energy)
        // Compand into a 0…1 visual range that reacts to normal speech (~0.02–0.15 RMS).
        let normalized = min(1, rms * 6)
        return normalized
    }

    // MARK: - Recording watchdog (auto-pause on silence, max length safety cap)

    private func startRecordingWatchdog() {
        recordingWatchdog?.cancel()
        recordingWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isRecording else { continue }
                self.watchdogTick()
            }
        }
    }

    private func stopRecordingWatchdog() {
        recordingWatchdog?.cancel()
        recordingWatchdog = nil
    }

    private func watchdogTick() {
        let defaults = UserDefaults.standard
        // Auto-pause on silence.
        let silenceSeconds = defaults.double(forKey: "record.autoPauseSilence")
        if silenceSeconds > 0, !isPaused,
           let lastActivity = lastAudioActivityAt,
           Date.now.timeIntervalSince(lastActivity) >= silenceSeconds {
            Task { await self.pauseRecording() }
            lastAudioActivityAt = nil // don't re-trigger until audio resumes
        } else if isPaused, silenceSeconds > 0,
                  let lastActivity = lastAudioActivityAt,
                  Date.now.timeIntervalSince(lastActivity) < 2 {
            // Audio came back — auto-resume.
            Task { await self.resumeRecording() }
        }
        // Max meeting length safety cap.
        let maxMinutes = defaults.integer(forKey: "record.maxMeetingMinutes")
        if maxMinutes > 0, activeElapsed >= Double(maxMinutes) * 60 {
            Task { await self.stop() }
        }
    }

    // MARK: - Notification + sound helpers

    private func playStartStopSoundIfEnabled() {
        let key = "record.soundOnStartStop"
        let enabled = UserDefaults.standard.object(forKey: key) == nil
            ? false : UserDefaults.standard.bool(forKey: key)
        guard enabled else { return }
        NSSound(named: "Pop")?.play()
    }

    private func postStopNotificationIfEnabled() {
        let enabled = UserDefaults.standard.bool(forKey: "record.notifyOnStop")
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Meeting ended"
        content.body = currentMeetingTitle.isEmpty ? "Your meeting is saved." : currentMeetingTitle
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }
}

struct CaptureDisplay: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let title: String

    static func current() -> [CaptureDisplay] {
        NSScreen.screens.enumerated().compactMap { offset, screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return CaptureDisplay(id: id.uint32Value, title: "Display \(offset + 1)")
        }
    }
}

enum CaptureTarget: Hashable {
    case primaryDisplay
    case display(CGDirectDisplayID)
    case window(CGWindowID)

    var displayID: CGDirectDisplayID? {
        switch self {
        case .primaryDisplay: nil
        case .display(let id): id
        case .window: nil
        }
    }

    var windowID: CGWindowID? {
        if case .window(let id) = self { return id }
        return nil
    }
}


enum KiroEnabledDefaults {
    private static let key = "record.kiroEnabled"

    static func load() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil { return true }
        return defaults.bool(forKey: key)
    }

    static func save(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
    }
}


enum TranslationDefaults {
    private static let key = "record.translationEnabled"
    static func load() -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func save(_ enabled: Bool) { UserDefaults.standard.set(enabled, forKey: key) }
}
