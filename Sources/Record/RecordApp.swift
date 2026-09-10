import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct RecordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = MeetingSession.shared

    var body: some Scene {
        WindowGroup("Record", id: RecordWindows.main) {
            MainWindow(session: session)
                .frame(minWidth: 780, minHeight: 540)
        }
        .defaultSize(width: 1_120, height: 740)

        Settings {
            PreferencesWindow()
        }

        Window("Record Mini", id: RecordWindows.mini) {
            MiniWindow(session: session)
                .frame(minWidth: 320, idealWidth: 360, minHeight: 92, idealHeight: 120)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.bottomTrailing)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(session.isRecording ? "Stop meeting" : "Start meeting") {
                    Task { await session.toggleRecording() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                Button(session.isPaused ? "Resume meeting" : "Pause meeting") {
                    Task { await session.togglePause() }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!session.isRecording)
                Divider()
                MiniWindowMenuItem()
                Button("Import Audio File…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.allowedContentTypes = [.audio]
                    panel.prompt = "Import"
                    if panel.runModal() == .OK, let url = panel.url {
                        Task { await MeetingSession.shared.importAudioFile(url) }
                    }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Open Kiro log…") {
                    NSWorkspace.shared.open(KiroWorkspace.stderrLogURL())
                }
            }
        }

        MenuBarExtra {
            MenuBarView(session: session)
        } label: {
            Image(systemName: session.isRecording ? "record.circle.fill" : "record.circle")
                .symbolRenderingMode(.hierarchical)
        }
    }
}

enum RecordWindows {
    static let main = "record.main"
    static let mini = "record.mini"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var globalHotkey: GlobalHotkey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Regular app (dock icon, cmd+tab) so users can actually find the window.
        NSApp.setActivationPolicy(.regular)
        if ProcessInfo.processInfo.arguments.contains("--smoke-start") {
            Task { @MainActor in
                let result = await MeetingSession.shared.runSmokeTest()
                print(result)
                NSApp.terminate(nil)
            }
        }

        // ⌘⌥R starts/stops a meeting from anywhere in macOS.
        // While a meeting is running it toggles pause/resume, so you can
        // step away from a conversation without ending the whole meeting.
        globalHotkey = GlobalHotkey {
            Task { @MainActor in
                RecordWindowActivator.bringMainWindowForward()
                let session = MeetingSession.shared
                if session.isRecording {
                    await session.togglePause()
                } else {
                    await session.toggleRecording()
                }
            }
        }

        // Watch for known call apps activating in the foreground.
        CallDetector.shared.start()

        // Fire off any recording schedules the user has set up.
        Scheduler.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            RecordWindowActivator.bringMainWindowForward()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MeetingSession.shared.handleAppWillTerminate()
    }
}

enum RecordWindowActivator {
    @MainActor
    static func bringMainWindowForward() {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: { $0.title == "Record" || $0.identifier?.rawValue.contains("record.main") == true }) {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        // Fall back to SwiftUI's openWindow via URL scheme-style shortcut.
        NSApp.sendAction(#selector(NSApplication.newWindowForTab(_:)), to: nil, from: nil)
    }
}

// MARK: - Menu bar

private struct MenuBarView: View {
    @ObservedObject var session: MeetingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(session.isRecording ? .red : .secondary)
                    .frame(width: 8, height: 8)
                Text(session.statusText).font(.headline)
            }
            if !session.lastTranscriptText.isEmpty {
                Text(session.lastTranscriptText)
                    .lineLimit(2)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            if session.isRecording {
                Button(session.isPaused ? "Resume" : "Pause") {
                    Task { await session.togglePause() }
                }
                Button("Stop meeting") {
                    Task { await session.toggleRecording() }
                }
            } else {
                Button("Start meeting") {
                    Task { await session.toggleRecording() }
                }
            }
            Button("Open Record") {
                RecordWindowActivator.bringMainWindowForward()
            }
            MiniWindowMenuItem()
            Divider()
            Button("Quit Record") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(8)
        .frame(width: 260)
    }
}

// MARK: - Main window

private enum SidebarSelection: Hashable {
    case live
    case askAll
    case meeting(UUID)
    case chat(UUID)
}

private struct MainWindow: View {
    @ObservedObject var session: MeetingSession
    @State private var selection: SidebarSelection? = .live
    /// Force the sidebar to stay visible even on narrow windows.
    /// Without this, `NavigationSplitView` on macOS auto-collapses the
    /// sidebar on smaller screens (e.g. 13-inch MacBook Air), making it
    /// look like the app is missing half its UI.
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @StateObject private var lock = AppLock.shared

    var body: some View {
        Group {
            if lock.isLocked {
                LockScreen(lock: lock)
            } else {
                content
            }
        }
        .onAppear { AppLock.shared.poke() }
    }

    @ViewBuilder
    private var content: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            Sidebar(session: session, selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch selection {
                case .live, .none, .chat:
                    LivePane(session: session)
                case .askAll:
                    AskAllPane(session: session)
                case .meeting(let id):
                    if let meeting = session.history.first(where: { $0.id == id }) {
                        HistoryPane(session: session, meeting: meeting)
                    } else {
                        ContentUnavailableView(
                            "Meeting removed",
                            systemImage: "trash",
                            description: Text("This meeting is no longer available.")
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selection, initial: false) { _, newValue in
            switch newValue {
            case .meeting(let id):
                if let meeting = session.history.first(where: { $0.id == id }) {
                    Task { await session.selectHistoryMeeting(meeting) }
                }
            case .chat(let id):
                Task { await session.selectChat(id) }
            default:
                Task { await session.selectHistoryMeeting(nil) }
            }
        }
        .task { await session.refreshHistory() }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var session: MeetingSession
    @Binding var selection: SidebarSelection?

    @State private var renamingChat: ChatArchiveEntry?
    @State private var renameDraft: String = ""
    @State private var deletingChat: ChatArchiveEntry?
    @State private var confirmingDeleteAllChats = false

    private var filterEmptyText: String {
        if session.history.isEmpty { return "No saved meetings yet" }
        if session.historyTagFilter != nil, session.historyDateFilter != .all {
            return "No meetings match those filters"
        }
        if session.historyTagFilter != nil { return "No meetings with that tag" }
        if session.historyDateFilter != .all { return "No meetings in that time range" }
        return "No saved meetings yet"
    }

    var body: some View {
        List(selection: $selection) {
            Section("Search") {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search all meetings", text: $session.globalSearchQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { session.runGlobalSearch() }
                    if !session.globalSearchQuery.isEmpty {
                        Button {
                            session.clearGlobalSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if session.globalSearchInProgress {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Searching…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(session.globalSearchResults) { hit in
                    Button {
                        selection = .meeting(hit.meeting.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.meeting.displayTitle)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text(hit.snippet)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                if !session.globalSearchQuery.isEmpty
                    && !session.globalSearchInProgress
                    && session.globalSearchResults.isEmpty {
                    Text("No matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Live") {
                HStack(spacing: 8) {
                    Image(systemName: session.isRecording ? "record.circle.fill" : "record.circle")
                        .foregroundStyle(session.isRecording ? .red : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Live meeting")
                        Text(session.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(SidebarSelection.live)

                HStack(spacing: 8) {
                    Image(systemName: "books.vertical")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ask across all meetings")
                        Text("\(session.history.count) meeting\(session.history.count == 1 ? "" : "s") to search")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(SidebarSelection.askAll)

                if let progress = session.importProgress {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Importing audio…").font(.caption)
                            if progress.totalSeconds > 0 {
                                Text("\(Int(progress.completedSeconds))s / \(Int(progress.totalSeconds))s")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                HStack {
                    Text("History").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        ForEach([
                            MeetingSession.DateFilter.all,
                            .today, .thisWeek, .thisMonth, .last30Days
                        ], id: \.self) { filter in
                            Button {
                                session.historyDateFilter = filter
                            } label: {
                                HStack {
                                    Text(filter.label)
                                    if session.historyDateFilter == filter {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Filter by date")
                }
                if !session.allTags.isEmpty {
                    TagFilterRow(
                        allTags: session.allTags,
                        active: session.historyTagFilter,
                        onSelect: { tag in session.historyTagFilter = tag }
                    )
                }
                if session.filteredHistory.isEmpty {
                    Text(filterEmptyText).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(session.filteredHistory) { meeting in
                    HistorySidebarRow(meeting: meeting)
                        .tag(SidebarSelection.meeting(meeting.id))
                        .contextMenu {
                            Button("Open", systemImage: "eye") {
                                selection = .meeting(meeting.id)
                            }
                            Button(role: .destructive) {
                                Task {
                                    if selection == .meeting(meeting.id) { selection = .live }
                                    await session.selectHistoryMeeting(meeting)
                                    await session.deleteSelectedMeeting()
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            Section {
                HStack {
                    Text("Chats").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button {
                            Task { await session.startNewChat() }
                        } label: {
                            Label("New chat", systemImage: "square.and.pencil")
                        }
                        if !session.savedChats.isEmpty {
                            Divider()
                            Button(role: .destructive) {
                                confirmingDeleteAllChats = true
                            } label: {
                                Label("Delete all chats", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Chat actions")
                }
                if session.savedChats.isEmpty {
                    Text("No saved chats yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(session.savedChats) { chat in
                    ChatSidebarRow(chat: chat, isActive: chat.id == session.activeChatID)
                        .tag(SidebarSelection.chat(chat.id))
                        .contextMenu {
                            Button("Open") {
                                Task { await session.selectChat(chat.id) }
                            }
                            Button("Rename…") {
                                renamingChat = chat
                            }
                            Button(role: .destructive) {
                                deletingChat = chat
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deletingChat = chat
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                renamingChat = chat
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .alert("Rename chat", isPresented: Binding(
            get: { renamingChat != nil },
            set: { if !$0 { renamingChat = nil } }
        ), presenting: renamingChat) { chat in
            TextField("Chat title", text: $renameDraft)
            Button("Rename") {
                Task { await session.renameChat(chat.id, to: renameDraft) }
                renamingChat = nil
            }
            Button("Cancel", role: .cancel) { renamingChat = nil }
        }
        .onChange(of: renamingChat) { _, chat in
            renameDraft = chat?.displayTitle ?? ""
        }
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(
                get: { deletingChat != nil },
                set: { if !$0 { deletingChat = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletingChat
        ) { chat in
            Button("Delete “\(chat.displayTitle)”", role: .destructive) {
                let id = chat.id
                Task { await session.deleteChat(id) }
                deletingChat = nil
            }
            Button("Cancel", role: .cancel) { deletingChat = nil }
        } message: { chat in
            Text("This chat has \(chat.turns.count) message\(chat.turns.count == 1 ? "" : "s"). Deleting can't be undone.")
        }
        .confirmationDialog(
            "Delete all chats?",
            isPresented: $confirmingDeleteAllChats,
            titleVisibility: .visible
        ) {
            Button("Delete \(session.savedChats.count) chat\(session.savedChats.count == 1 ? "" : "s")", role: .destructive) {
                Task {
                    for chat in session.savedChats {
                        await session.deleteChat(chat.id)
                    }
                }
                confirmingDeleteAllChats = false
            }
            Button("Cancel", role: .cancel) { confirmingDeleteAllChats = false }
        } message: {
            Text("Every saved chat will be permanently removed. This can't be undone.")
        }
        .onChange(of: session.globalSearchQuery, initial: false) { _, newValue in
            if newValue.count >= 2 { session.runGlobalSearch() }
            else if newValue.isEmpty { session.clearGlobalSearch() }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await session.refreshHistory() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh history")
            }
        }
        .navigationTitle("Record")
    }
}

private struct HistorySidebarRow: View {
    let meeting: MeetingRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.displayTitle)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.startedAt, format: .dateTime.month().day().hour().minute())
                Text("·")
                Text("\(meeting.segmentCount) segments")
                if meeting.status == .interrupted {
                    Text("·")
                    Text("interrupted").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct ChatSidebarRow: View {
    let chat: ChatArchiveEntry
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.displayTitle)
                    .lineLimit(1)
                    .font(.callout)
                HStack(spacing: 4) {
                    Text("\(chat.turns.count)")
                        .monospacedDigit()
                    Text("·")
                    Text(chat.updatedAt, format: .dateTime.month().day().hour().minute())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Live pane

private struct LivePane: View {
    @ObservedObject var session: MeetingSession
    @State private var question = ""
    @State private var pickingSource = false
    @State private var chapterDraft = ""
    @State private var noteDraft = ""
    @State private var chapterSheet = false
    @State private var noteSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LiveHeader(session: session)
                LiveControls(session: session, pickingSource: $pickingSource)
                if let message = session.errorMessage {
                    CalloutView(message: message)
                }
                AskPanel(
                    question: $question,
                    turns: session.chatTurns,
                    isAsking: session.isAsking,
                    placeholder: "Ask about this meeting…",
                    onSubmit: { text in Task { await session.ask(text) } },
                    onReset: { Task { await session.startNewChat() } },
                    attachments: session.pendingAttachments,
                    onAddAttachments: { urls in session.addAttachments(from: urls) },
                    onAddPastedText: { text, label in session.addPastedText(text, label: label) },
                    onRemoveAttachment: { id in session.removeAttachment(id) },
                    onCancel: { Task { await session.cancelAsk() } },
                    kiroAvailable: session.kiroAvailable
                )
                TranscriptListView(
                    segments: session.transcript,
                    emptyText: "The transcript appears here as people speak.",
                    onToggleStar: { id in Task { await session.toggleStar(segmentID: id) } },
                    onEdit: { id, text in Task { await session.editSegment(id: id, newText: text) } },
                    meetingTitle: session.currentMeetingTitle.isEmpty ? "Live meeting" : session.currentMeetingTitle,
                    meetingStartedAt: session.recordingStartedAt ?? .now,
                    enableDownload: true
                )
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $pickingSource) {
            SourcePickerSheet(session: session)
        }
        .sheet(isPresented: $chapterSheet) {
            InsertTextSheet(
                title: "Insert chapter marker",
                placeholder: "e.g. Discussing rollout",
                submitLabel: "Insert",
                initialText: $chapterDraft
            ) { text in
                Task { await session.insertChapter(title: text) }
            }
        }
        .sheet(isPresented: $noteSheet) {
            InsertTextSheet(
                title: "Add note",
                placeholder: "Type a note at this timestamp",
                submitLabel: "Add note",
                initialText: $noteDraft,
                allowMultiline: true
            ) { text in
                Task { await session.insertNote(text: text) }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.liveExportText(), forType: .string)
                } label: {
                    Label("Copy transcript", systemImage: "doc.on.doc")
                }
                .disabled(session.transcript.isEmpty)

                Button {
                    chapterDraft = ""
                    chapterSheet = true
                } label: {
                    Label("Chapter", systemImage: "bookmark")
                }
                .keyboardShortcut("m", modifiers: [.command])
                .help("Insert a chapter marker (⌘M)")

                Button {
                    noteDraft = ""
                    noteSheet = true
                } label: {
                    Label("Note", systemImage: "note.text")
                }
                .keyboardShortcut("n", modifiers: [.command])
                .help("Add a manual note at this timestamp (⌘N)")

                if session.isRecording {
                    Button {
                        session.micMuted.toggle()
                    } label: {
                        Label(
                            session.micMuted ? "Mic off" : "Mic on",
                            systemImage: session.micMuted ? "mic.slash.fill" : "mic.fill"
                        )
                    }
                    .tint(session.micMuted ? .red : .accentColor)
                    .help("Mute mic (⌘⌥.)")
                    .keyboardShortcut(".", modifiers: [.command, .option])

                    Button {
                        Task { await session.togglePause() }
                    } label: {
                        Label(
                            session.isPaused ? "Resume" : "Pause",
                            systemImage: session.isPaused ? "play.circle.fill" : "pause.circle.fill"
                        )
                    }
                    .disabled(session.isBusy)
                    .tint(session.isPaused ? .accentColor : .orange)

                    Button(role: .destructive) {
                        Task { await session.toggleRecording() }
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                    .disabled(session.isBusy)
                    .tint(.red)
                } else {
                    Button {
                        Task { await session.toggleRecording() }
                    } label: {
                        Label("Start", systemImage: "record.circle")
                    }
                    .disabled(session.isBusy)
                    .tint(.accentColor)
                }
            }
        }
    }
}

private struct LiveHeader: View {
    @ObservedObject var session: MeetingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                RecordingIndicator(active: session.isRecording, paused: session.isPaused)
                Text(session.currentMeetingTitle.isEmpty ? "Live meeting" : session.currentMeetingTitle)
                    .font(.largeTitle.bold())
                if session.isRecording {
                    ActiveElapsedLabel(session: session)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(session.isPaused ? .orange : .secondary)
                }
            }
            HStack(spacing: 12) {
                Text(session.captureModeText + " · " + session.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if session.isRecording {
                    LevelMeter(label: "Mic", level: session.micLevel, color: .blue)
                        .frame(width: 90)
                    if session.captureModeText.contains("system audio") {
                        LevelMeter(label: "Sys", level: session.systemAudioLevel, color: .purple)
                            .frame(width: 90)
                    }
                }
            }
        }
    }
}

private struct RecordingIndicator: View {
    let active: Bool
    var paused: Bool = false
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(paused ? .orange : (active ? .red : .secondary))
            .frame(width: 12, height: 12)
            .scaleEffect(pulse && active && !paused ? 1.25 : 1)
            .opacity(pulse && active && !paused ? 0.6 : 1)
            .animation(active && !paused ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                       value: pulse)
            .onAppear { pulse = true }
    }
}

private struct ActiveElapsedLabel: View {
    @ObservedObject var session: MeetingSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Text(formatted(elapsed: session.activeElapsed) + (session.isPaused ? " · paused" : ""))
        }
    }

    private func formatted(elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

private struct ElapsedTimeLabel: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(formatted(elapsed: context.date.timeIntervalSince(startedAt)))
        }
    }

    private func formatted(elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

private struct LevelMeter: View {
    let label: String
    let level: Float
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.2))
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(2, proxy.size.width * CGFloat(level)))
                        .animation(.easeOut(duration: 0.1), value: level)
                }
            }
            .frame(height: 6)
        }
    }
}

private struct LiveControls: View {
    @ObservedObject var session: MeetingSession
    @Binding var pickingSource: Bool

    var body: some View {
        GroupBox("Capture") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Toggle("Include screen (OCR + Kiro attachments)", isOn: Binding(
                        get: { session.visualContextEnabled },
                        set: { _ in Task { await session.toggleVisualContext() } }
                    ))
                    .disabled(!session.isRecording)

                    Toggle("Translate to English", isOn: $session.translationEnabled)
                        .help("Whisper translates any input language to English on the fly")

                    Spacer()

                    Button {
                        Task { _ = await session.snapAndOCR() }
                    } label: {
                        Label("Grab text…", systemImage: "text.viewfinder")
                    }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .help("Drag a region or pick a window to OCR — text goes to the transcript and clipboard")

                    Button {
                        pickingSource = true
                    } label: {
                        Label(session.currentSourceLabel, systemImage: "rectangle.on.rectangle")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help("Change what's being captured")
                }

                if session.visualContextEnabled, let preview = session.latestCapturePreview,
                   let image = NSImage(data: preview) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
                            )
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Live capture", systemImage: "eye.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                            Text("Source: \(session.currentSourceLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Updated every second while screen capture is on. Record's own windows are always excluded.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                HStack(spacing: 12) {
                    Label(session.microphonePermissionText, systemImage: "mic")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Label(session.screenPermissionText, systemImage: "rectangle.on.rectangle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Label(session.transcriptionEngineText, systemImage: "waveform")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Spacer()
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - History pane

private struct HistoryPane: View {
    @ObservedObject var session: MeetingSession
    let meeting: MeetingRecord

    @State private var titleDraft = ""
    @State private var question = ""
    @State private var exportError: String?
    @State private var confirmingDelete = false
    @StateObject private var player = MeetingAudioPlayer()
    @State private var peaks: [Float] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HistoryHeader(
                    meeting: meeting,
                    titleDraft: $titleDraft,
                    onCommit: { newTitle in Task { await session.renameSelectedMeeting(newTitle) } },
                    onAddTag: { tag in Task { await session.addTagToSelected(tag) } },
                    onRemoveTag: { tag in Task { await session.removeTagFromSelected(tag) } }
                )

                if let message = session.historyStatusMessage {
                    CalloutView(message: message)
                }

                AskPanel(
                    question: $question,
                    turns: session.chatTurns,
                    isAsking: session.isAsking,
                    placeholder: "Ask this meeting…",
                    onSubmit: { text in Task { await session.askHistoryQuestion(text) } },
                    onReset: { Task { await session.startNewChat() } },
                    attachments: session.pendingAttachments,
                    onAddAttachments: { urls in session.addAttachments(from: urls) },
                    onAddPastedText: { text, label in session.addPastedText(text, label: label) },
                    onRemoveAttachment: { id in session.removeAttachment(id) },
                    onCancel: { Task { await session.cancelAsk() } },
                    kiroAvailable: session.kiroAvailable
                )

                if MeetingAudioRecorder.hasAudio(for: meeting.id) {
                    AudioPlayerBar(player: player, peaks: peaks, meetingID: meeting.id, onSeek: { fraction in
                        player.seek(to: fraction * player.duration)
                    })
                }

                TranscriptListView(
                    segments: session.selectedHistoryTranscript,
                    emptyText: "This meeting has no transcript segments.",
                    onToggleStar: { id in Task { await session.toggleStarInSelectedHistory(segmentID: id) } },
                    onEdit: { id, text in Task { await session.editHistorySegment(id: id, newText: text) } },
                    onSegmentTap: { segment in
                        guard MeetingAudioRecorder.hasAudio(for: meeting.id) else { return }
                        let offset = segment.timestamp.timeIntervalSince(meeting.startedAt)
                        player.seek(to: max(0, offset))
                        if !player.isPlaying { player.play() }
                    },
                    meetingTitle: meeting.displayTitle,
                    meetingStartedAt: meeting.startedAt,
                    meetingSummary: meeting.summary,
                    meetingTags: meeting.tags,
                    enableDownload: true
                )

                if !session.relatedMeetings.isEmpty {
                    RelatedMeetingsFooter(meetings: session.relatedMeetings) { meeting in
                        Task { await session.selectHistoryMeeting(meeting) }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if let text = session.selectedMeetingExportText() {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                } label: {
                    Label("Copy transcript", systemImage: "doc.on.doc")
                }
                .disabled(session.selectedHistoryTranscript.isEmpty)

                Menu {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Button(format.displayName) { runExport(as: format) }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(session.selectedHistoryTranscript.isEmpty)

                Menu {
                    Button("Summarize this meeting") {
                        Task { await session.askHistoryQuestion("Give me a one-paragraph summary of this meeting, then a bulleted list of the key decisions and top three risks.") }
                    }
                    Button("Extract action items") {
                        Task { await session.askHistoryQuestion("Extract every action item mentioned in the meeting as a bulleted list. Include owner and due date when named. Skip anything speculative.") }
                    }
                    Button("Draft a follow-up email") {
                        Task { await session.askHistoryQuestion("Draft a follow-up email to the attendees summarizing the discussion, decisions, and any action items with owners and dates. Keep it professional and under 250 words.") }
                    }
                    Button("Explain jargon") {
                        Task { await session.askHistoryQuestion("List every acronym, product code name, and technical term used in the meeting, with a one-sentence plain-English explanation for each.") }
                    }
                } label: {
                    Label("Quick actions", systemImage: "wand.and.stars")
                }
                .disabled(session.selectedHistoryTranscript.isEmpty)

                Button {
                    Task { await session.regenerateSummaryAndTitle(for: meeting) }
                } label: {
                    Label("Regenerate summary", systemImage: "sparkles")
                }
                .disabled(session.selectedHistoryTranscript.isEmpty)
                .help("Ask Kiro to rewrite the auto-generated title and summary")

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible,
            presenting: meeting
        ) { meeting in
            Button("Delete “\(meeting.displayTitle)”", role: .destructive) {
                Task { await session.deleteSelectedMeeting() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The transcript is encrypted on disk and will be permanently removed. This cannot be undone.")
        }
        .alert("Could not export", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .onAppear { titleDraft = meeting.displayTitle; loadAudio() }
        .onDisappear { player.unload() }
        .onChange(of: meeting.id, initial: false) { _, _ in
            titleDraft = meeting.displayTitle
            loadAudio()
        }
    }

    private func loadAudio() {
        peaks = []
        player.unload()
        let urls = MeetingAudioRecorder.tracks(for: meeting.id)
        guard !urls.isEmpty else { return }
        player.load(urls: urls)
        Task {
            let generated = await WaveformGenerator.combinedPeaks(urls: urls)
            await MainActor.run { self.peaks = generated }
        }
    }

    private func runExport(as format: ExportFormat) {
        let text = TranscriptExporter.render(
            session.selectedHistoryTranscript,
            title: meeting.displayTitle,
            startedAt: meeting.startedAt,
            summary: meeting.summary,
            tags: meeting.tags,
            as: format
        )
        let panel = NSSavePanel()
        panel.title = "Export transcript"
        panel.nameFieldStringValue = sanitizedFilename(meeting.displayTitle) + "." + format.fileExtension
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        // Default to ~/Downloads/Record which most users can write to.
        let downloads = try? FileManager.default.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        if let downloads {
            panel.directoryURL = downloads
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            try Data(text.utf8).write(to: target, options: .atomic)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func sanitizedFilename(_ raw: String) -> String {
        let stripped = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? "meeting" : stripped
    }
}

private struct HistoryHeader: View {
    let meeting: MeetingRecord
    @Binding var titleDraft: String
    let onCommit: (String) -> Void
    var onAddTag: ((String) -> Void)? = nil
    var onRemoveTag: ((String) -> Void)? = nil

    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Meeting title", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.largeTitle.bold())
                .onSubmit { onCommit(titleDraft) }
            HStack(spacing: 10) {
                Text(meeting.startedAt, format: .dateTime.weekday(.wide).month().day().hour().minute())
                Text("·")
                Text(durationText(meeting.duration))
                Text("·")
                Text("\(meeting.segmentCount) segments")
                if meeting.status == .interrupted {
                    Text("·")
                    Text("interrupted").foregroundStyle(.orange)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if !meeting.summary.isEmpty {
                Text(meeting.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }

            HStack(spacing: 6) {
                ForEach(meeting.tags, id: \.self) { tag in
                    TagChip(tag: tag) { onRemoveTag?(tag) }
                }
                TextField("Add tag", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit {
                        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onAddTag?(trimmed)
                        newTag = ""
                    }
            }
            .padding(.top, 2)
        }
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secondsRemaining = seconds % 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, secondsRemaining) }
        return "\(secondsRemaining)s"
    }
}

private struct TagChip: View {
    let tag: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "tag")
                .font(.caption2)
            Text(tag).font(.caption)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.blue.opacity(0.12), in: Capsule())
        .foregroundStyle(.blue)
    }
}

// MARK: - Shared views

private struct AskPanel: View {
    @Binding var question: String
    let turns: [ChatTurn]
    let isAsking: Bool
    let placeholder: String
    let onSubmit: (String) -> Void
    let onReset: () -> Void
    var attachments: [ChatAttachment] = []
    var onAddAttachments: (([URL]) -> Void)? = nil
    var onAddPastedText: ((String, String?) -> Void)? = nil
    var onRemoveAttachment: ((ChatAttachment.ID) -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    /// When false, Kiro CLI wasn't found on the machine — we render an
    /// install-hint banner and disable the composer.
    var kiroAvailable: Bool = true

    @State private var presentPasteSheet = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Ask Kiro", systemImage: "bubble.left.and.bubble.right")
                        .font(.headline)
                    Spacer()
                    if !turns.isEmpty {
                        Text("\(turns.count) message\(turns.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            onReset()
                        } label: {
                            Label("New chat", systemImage: "arrow.counterclockwise")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Start a fresh conversation (drops previous context)")
                    }
                }

                if !kiroAvailable {
                    KiroUnavailableBanner()
                }

                if !turns.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(turns) { turn in
                                    ChatTurnView(turn: turn, onCopy: onCopy).id(turn.id)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(maxHeight: 320)
                        .onChange(of: turns.last?.id, initial: false) { _, newValue in
                            guard let newValue else { return }
                            withAnimation { proxy.scrollTo(newValue, anchor: .bottom) }
                        }
                        .onChange(of: turns.last?.answer, initial: false) { _, _ in
                            if let last = turns.last?.id {
                                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    if onAddAttachments != nil {
                        Menu {
                            Button {
                                presentAttachmentPicker()
                            } label: {
                                Label("Attach file…", systemImage: "doc")
                            }
                            Button {
                                presentPasteSheet = true
                            } label: {
                                Label("Paste text as attachment…", systemImage: "text.append")
                            }
                            if canPasteFromClipboard() {
                                Button {
                                    pasteFromClipboard()
                                } label: {
                                    Label("Attach clipboard text", systemImage: "doc.on.clipboard")
                                }
                                .keyboardShortcut("v", modifiers: [.command, .shift])
                            }
                        } label: {
                            Image(systemName: "paperclip")
                        }
                        .buttonStyle(.borderless)
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Attach a document, paste text, or attach clipboard contents (⌘⇧V)")
                    }
                    PromptLibraryMenu { template in
                        question = template.body
                    }
                    TextField(turns.isEmpty ? placeholder : "Follow up…", text: $question)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!kiroAvailable)
                        .onSubmit { submit() }
                    if isAsking {
                        Button("Cancel", role: .destructive) { onCancel?() }
                            .keyboardShortcut(.escape, modifiers: [])
                    } else {
                        Button(turns.isEmpty ? "Ask" : "Send") { submit() }
                            .keyboardShortcut(.return, modifiers: [.command])
                            .disabled(!kiroAvailable || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if !attachments.isEmpty {
                    AttachmentChipsRow(attachments: attachments, onRemove: onRemoveAttachment)
                }
            }
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $presentPasteSheet) {
            PasteTextSheet { text, label in
                onAddPastedText?(text, label)
            }
        }
    }

    private func submit() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        question = ""
    }

    private func presentAttachmentPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = AttachmentImporter.acceptedContentTypes
        panel.prompt = "Attach"
        panel.title = "Attach files to the Kiro conversation"
        if panel.runModal() == .OK {
            onAddAttachments?(panel.urls)
        }
    }

    private func canPasteFromClipboard() -> Bool {
        NSPasteboard.general.string(forType: .string)?.isEmpty == false
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty else { return }
        onAddPastedText?(text, nil)
    }
}

/// Non-blocking banner shown in place of the chat when kiro-cli isn't
/// available. Explains the local-first tradeoff and links to install.
private struct KiroUnavailableBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Kiro CLI isn't installed")
                    .font(.subheadline.weight(.semibold))
                Text("Recording, transcription, search, and export all work without Kiro. Install the CLI to enable chat, auto-summaries, and auto-titles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Install Kiro CLI", destination: URL(string: "https://kiro.dev/download")!)
                    .font(.caption.weight(.medium))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.tertiary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PasteTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAttach: (String, String?) -> Void

    @State private var text = ""
    @State private var label = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Paste text as attachment")
                    .font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Attach") {
                    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    onAttach(text, trimmedLabel.isEmpty ? nil : trimmedLabel)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextField("Label (optional)", text: $label)
                .textFieldStyle(.roundedBorder)
            Text("Content")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
                )
        }
        .padding()
        .frame(minWidth: 560, minHeight: 380)
    }
}

private struct AttachmentChipsRow: View {
    let attachments: [ChatAttachment]
    let onRemove: ((ChatAttachment.ID) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachment.isImage ? "photo" : "doc.text")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(attachment.filename)
                                .lineLimit(1)
                                .font(.caption.weight(.medium))
                            Text(attachment.displayDetail)
                                .lineLimit(1)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            onRemove?(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.secondary.opacity(0.12), in: Capsule())
                }
            }
        }
    }
}

private struct ChatTurnView: View {
    let turn: ChatTurn
    let onCopy: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(turn.question)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !turn.attachmentNames.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "paperclip")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(turn.attachmentNames.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 6) {
                    if turn.isLoading, turn.answer.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Kiro is thinking…").foregroundStyle(.secondary)
                        }
                    } else if let errorMessage = turn.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    } else {
                        MarkdownText(raw: turn.answer)
                        if !turn.answer.isEmpty {
                            HStack {
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(turn.answer, forType: .string)
                                    onCopy?()
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().opacity(0.3)
        }
    }
}

private struct TranscriptListView: View {
    let segments: [TranscriptSegment]
    let emptyText: String
    var onCopyAll: (() -> Void)? = nil
    var onToggleStar: ((UUID) -> Void)? = nil
    var onEdit: ((UUID, String) -> Void)? = nil
    var onSegmentTap: ((TranscriptSegment) -> Void)? = nil
    /// Optional download hook — when provided the header shows an Export
    /// menu that saves the transcript in the picked format via NSSavePanel.
    var meetingTitle: String? = nil
    var meetingStartedAt: Date? = nil
    var meetingSummary: String = ""
    var meetingTags: [String] = []
    var enableDownload: Bool = false

    @State private var searchText = ""
    @State private var autoScroll = true
    @State private var starredOnly = false

    private var filtered: [TranscriptSegment] {
        var out = segments
        if starredOnly { out = out.filter { $0.starred } }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return out }
        return out.filter {
            $0.text.range(of: query, options: .caseInsensitive) != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Transcript").font(.title2.bold())
                Spacer()
                if segments.count > 6 {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search transcript", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                    }
                }
                Toggle(isOn: $autoScroll) {
                    Label("Auto-scroll", systemImage: "pin")
                        .labelStyle(.iconOnly)
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Follow newest segment (pin to bottom)")
                Toggle(isOn: $starredOnly) {
                    Label("Starred only", systemImage: starredOnly ? "star.fill" : "star")
                        .labelStyle(.iconOnly)
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Only show starred segments")
                Button {
                    NSPasteboard.general.clearContents()
                    let joined = segments
                        .filter { $0.isFinal }
                        .map { "[\($0.timestamp.formatted(date: .omitted, time: .standard))] \($0.source.title): \($0.text)" }
                        .joined(separator: "\n")
                    NSPasteboard.general.setString(joined, forType: .string)
                    onCopyAll?()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy full transcript to clipboard")
                .disabled(segments.isEmpty)
                if enableDownload {
                    Menu {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Button(format.displayName) { downloadTranscript(as: format) }
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Download transcript as a file")
                    .disabled(segments.isEmpty)
                }
                Text("\(filtered.count)/\(segments.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if segments.isEmpty {
                ContentUnavailableView(
                    "No transcript yet",
                    systemImage: "waveform",
                    description: Text(emptyText)
                )
                .frame(maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView(
                    "No matches",
                    systemImage: "magnifyingglass",
                    description: Text("No segment contains “\(searchText)”.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(filtered) { segment in
                                TranscriptRow(
                                    segment: segment,
                                    highlight: searchText,
                                    onToggleStar: onToggleStar.map { callback in { callback(segment.id) } },
                                    onEdit: onEdit.map { callback in { newText in callback(segment.id, newText) } },
                                    onTap: onSegmentTap.map { callback in { callback(segment) } }
                                ).id(segment.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: filtered.last?.id, initial: false) { _, newValue in
                        guard autoScroll, let newValue else { return }
                        withAnimation { proxy.scrollTo(newValue, anchor: .bottom) }
                    }
                }
            }
        }
    }
    private func downloadTranscript(as format: ExportFormat) {
        let title = meetingTitle ?? "Live transcript"
        let started = meetingStartedAt ?? .now
        let text = TranscriptExporter.render(
            segments,
            title: title,
            startedAt: started,
            summary: meetingSummary,
            tags: meetingTags,
            as: format
        )
        let panel = NSSavePanel()
        panel.title = "Download transcript"
        panel.nameFieldStringValue = TranscriptListView.sanitize(title) + "." + format.fileExtension
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let downloads = try? FileManager.default.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            panel.directoryURL = downloads
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let target = panel.url else { return }
        try? Data(text.utf8).write(to: target, options: .atomic)
    }

    private static func sanitize(_ raw: String) -> String {
        let stripped = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? "transcript" : stripped
    }
}

private struct CalloutView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .textSelection(.enabled)
    }
}

// MARK: - Export document

struct TranscriptExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText, .json,
        UTType(filenameExtension: "md") ?? .plainText,
        UTType(filenameExtension: "srt") ?? .plainText,
        UTType(filenameExtension: "vtt") ?? .plainText
    ]
    var text: String
    var suggestedFilename: String
    var format: ExportFormat

    init(text: String, suggestedFilename: String, format: ExportFormat) {
        self.text = text
        self.suggestedFilename = suggestedFilename
        self.format = format
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        self.text = String(data: data, encoding: .utf8) ?? ""
        self.suggestedFilename = configuration.file.filename ?? "meeting.txt"
        self.format = .txt
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Kept for backward compatibility with the earlier fileExporter usage. New
/// code should use `TranscriptExportDocument` instead.
struct TranscriptTextDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    var text: String
    var suggestedFilename: String

    init(text: String, suggestedFilename: String) {
        self.text = text
        self.suggestedFilename = suggestedFilename
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        self.text = String(data: data, encoding: .utf8) ?? ""
        self.suggestedFilename = configuration.file.filename ?? "meeting.txt"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}


private struct InsertTextSheet: View {
    let title: String
    let placeholder: String
    let submitLabel: String
    @Binding var initialText: String
    var allowMultiline: Bool = false
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            if allowMultiline {
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
                    )
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(submitLabel) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 460)
        .onAppear { text = initialText }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        initialText = ""
        dismiss()
    }
}


private struct AskAllPane: View {
    @ObservedObject var session: MeetingSession
    @State private var question = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Image(systemName: "books.vertical.fill")
                            .foregroundStyle(Color.accentColor)
                        Text("Ask across all meetings")
                            .font(.largeTitle.bold())
                    }
                    Text("Kiro's answer draws evidence from your entire meeting archive (\(session.history.count) meetings). Everything stays on-device.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let message = session.errorMessage {
                    CalloutView(message: message)
                }
                AskPanel(
                    question: $question,
                    turns: session.chatTurns,
                    isAsking: session.isAsking,
                    placeholder: "e.g. What did I promise the team last month?",
                    onSubmit: { text in Task { await session.askAcrossAllMeetings(text) } },
                    onReset: { Task { await session.startNewChat() } },
                    attachments: session.pendingAttachments,
                    onAddAttachments: { urls in session.addAttachments(from: urls) },
                    onAddPastedText: { text, label in session.addPastedText(text, label: label) },
                    onRemoveAttachment: { id in session.removeAttachment(id) },
                    onCancel: { Task { await session.cancelAsk() } },
                    kiroAvailable: session.kiroAvailable
                )
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}


private struct TagFilterRow: View {
    let allTags: [String]
    let active: String?
    let onSelect: (String?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Chip(label: "All", active: active == nil) { onSelect(nil) }
                ForEach(allTags, id: \.self) { tag in
                    Chip(
                        label: tag,
                        active: active?.caseInsensitiveCompare(tag) == .orderedSame
                    ) {
                        onSelect(active?.caseInsensitiveCompare(tag) == .orderedSame ? nil : tag)
                    }
                }
            }
        }
    }

    private struct Chip: View {
        let label: String
        let active: Bool
        let onTap: () -> Void

        var body: some View {
            Button(action: onTap) {
                Text(label)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(active ? Color.accentColor : Color.secondary.opacity(0.15),
                                in: Capsule())
                    .foregroundStyle(active ? .white : .primary)
            }
            .buttonStyle(.plain)
        }
    }
}


private struct TranscriptRow: View {
    let segment: TranscriptSegment
    var highlight: String = ""
    var onToggleStar: (() -> Void)? = nil
    var onEdit: ((String) -> Void)? = nil
    var onTap: (() -> Void)? = nil

    @State private var editing = false
    @State private var editDraft = ""

    var body: some View {
        content
            .onTapGesture(count: 2) { onTap?() }
            .sheet(isPresented: $editing) {
                EditSegmentSheet(text: $editDraft) { newText in
                    onEdit?(newText)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        // Chapter markers render as prominent section headers, not chat rows.
        if segment.source == .chapter {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "bookmark.fill").foregroundStyle(.teal)
                    Text(segment.text)
                        .font(.headline)
                    Text(segment.timestamp, format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Divider()
            }
            .padding(.vertical, 4)
            .contextMenu { copyMenu }
        } else if segment.source == .note {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "note.text")
                    .foregroundStyle(.indigo)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(segment.timestamp, format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(attributed(text: segment.text, highlight: highlight))
                        .textSelection(.enabled)
                        .italic()
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .contextMenu { copyMenu }
        } else {
            defaultRow
        }
    }

    private var defaultRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(segment.source.color)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(segment.source.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(segment.source.color)
                    Text(segment.timestamp, format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if !segment.isFinal {
                        Text("live")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    if segment.starred {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                Text(attributed(text: segment.text, highlight: highlight))
                    .textSelection(.enabled)
                    .foregroundStyle(segment.isFinal ? .primary : .secondary)
            }
        }
        .contextMenu { copyMenu }
    }

    @ViewBuilder
    private var copyMenu: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(segment.text, forType: .string)
        } label: {
            Label("Copy text", systemImage: "doc.on.doc")
        }
        Button {
            let time = segment.timestamp.formatted(date: .omitted, time: .standard)
            let payload = "[\(time)] \(segment.source.title): \(segment.text)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(payload, forType: .string)
        } label: {
            Label("Copy with timestamp", systemImage: "clock")
        }
        Button {
            let time = segment.timestamp.formatted(date: .omitted, time: .shortened)
            let payload = "> \"\(segment.text)\" — \(segment.source.title), \(time)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(payload, forType: .string)
        } label: {
            Label("Copy as quote", systemImage: "quote.opening")
        }
        Divider()
        Button {
            onToggleStar?()
        } label: {
            Label(segment.starred ? "Unstar" : "Star", systemImage: segment.starred ? "star.slash" : "star.fill")
        }
        if onEdit != nil {
            Button {
                editDraft = segment.text
                editing = true
            } label: {
                Label("Edit…", systemImage: "pencil")
            }
        }
        if onTap != nil {
            Button {
                onTap?()
            } label: {
                Label("Play from here", systemImage: "play.circle")
            }
        }
    }

    private func attributed(text: String, highlight: String) -> AttributedString {
        var attributed = AttributedString(text)
        let query = highlight.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return attributed }
        var searchRange = attributed.startIndex..<attributed.endIndex
        while let match = attributed[searchRange].range(of: query, options: .caseInsensitive) {
            attributed[match].backgroundColor = .yellow.opacity(0.35)
            attributed[match].foregroundColor = .primary
            searchRange = match.upperBound..<attributed.endIndex
        }
        return attributed
    }
}


private struct MiniWindowMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Mini Window") {
            openWindow(id: RecordWindows.mini)
        }
        .keyboardShortcut("m", modifiers: [.command, .option])
    }
}


private struct EditSegmentSheet: View {
    @Binding var text: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit transcript segment").font(.title2.bold())
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
                )
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 300)
    }
}


private struct RelatedMeetingsFooter: View {
    let meetings: [MeetingRecord]
    let onOpen: (MeetingRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Related meetings", systemImage: "link").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(meetings) { meeting in
                        Button {
                            onOpen(meeting)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(meeting.displayTitle)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                Text(meeting.startedAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !meeting.tags.isEmpty {
                                    Text(meeting.tags.prefix(3).joined(separator: ", "))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(8)
                            .frame(width: 220, alignment: .leading)
                            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}


private struct AudioPlayerBar: View {
    @ObservedObject var player: MeetingAudioPlayer
    let peaks: [Float]
    let meetingID: UUID
    let onSeek: (Double) -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderedProminent)
                Text(format(player.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                trackToggles
                Text(format(player.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            WaveformView(
                peaks: peaks,
                progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                onSeek: onSeek
            )
        }
        .padding(10)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var trackToggles: some View {
        let mic = MeetingAudioRecorder.micURL(for: meetingID)
        let sys = MeetingAudioRecorder.systemURL(for: meetingID)
        let fm = FileManager.default
        if fm.isReadableFile(atPath: mic.path), fm.isReadableFile(atPath: sys.path) {
            HStack(spacing: 4) {
                Button {
                    player.toggleMute(url: mic)
                } label: {
                    Label("You", systemImage: player.mutedTracks.contains(mic) ? "person.slash" : "person")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(player.mutedTracks.contains(mic) ? "Unmute your voice" : "Mute your voice")
                Button {
                    player.toggleMute(url: sys)
                } label: {
                    Label("Others", systemImage: player.mutedTracks.contains(sys) ? "speaker.slash" : "speaker.wave.2")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(player.mutedTracks.contains(sys) ? "Unmute call audio" : "Mute call audio")
            }
        }
    }

    private func format(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        let m = s / 60
        let sec = s % 60
        return String(format: "%d:%02d", m, sec)
    }
}
