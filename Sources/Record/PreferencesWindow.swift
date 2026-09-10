import AppKit
import SwiftUI

/// Preferences window / sheet. First tab is the Whisper model catalog with
/// installed status, download buttons, and progress. More tabs can be added
/// as we ship more settings.
struct PreferencesWindow: View {
    @StateObject private var models = WhisperModelManager.shared
    @StateObject private var settings = RecordSettings.shared
    @StateObject private var lock = AppLock.shared
    @StateObject private var scheduler = SchedulerStore.shared

    var body: some View {
        TabView {
            GeneralPane(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelsPane(models: models)
                .tabItem { Label("Transcription", systemImage: "waveform") }
            KiroPane(settings: settings)
                .tabItem { Label("Kiro", systemImage: "sparkles") }
            CapturePane(settings: settings)
                .tabItem { Label("Capture", systemImage: "record.circle") }
            SchedulesPane(store: scheduler)
                .tabItem { Label("Schedules", systemImage: "calendar") }
            SecurityPane(lock: lock)
                .tabItem { Label("Security", systemImage: "lock") }
        }
        .frame(minWidth: 680, minHeight: 500)
        .padding()
    }
}

private struct SchedulesPane: View {
    @ObservedObject var store: SchedulerStore
    @State private var editing: ScheduledMeeting?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scheduled recordings")
                .font(.title2.bold())
            Text("Record automatically starts a meeting when a schedule fires. Both prompt-less and safety-capped by the duration below.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach(store.schedules) { schedule in
                    HStack {
                        Toggle("", isOn: binding(for: schedule.id, keyPath: \.enabled))
                            .labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(schedule.name.isEmpty ? "Untitled" : schedule.name)
                                .font(.body.weight(.medium))
                            Text("\(schedule.weekdayLabel) at \(schedule.timeLabel) · \(schedule.durationMinutes > 0 ? "\(schedule.durationMinutes)m" : "manual stop")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editing = schedule }
                        Button(role: .destructive) {
                            store.remove(schedule.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset)

            HStack {
                Button {
                    editing = ScheduledMeeting(
                        name: "New schedule",
                        weekdays: [2, 3, 4, 5, 6],
                        hour: 10,
                        minute: 0,
                        durationMinutes: 30
                    )
                } label: {
                    Label("Add schedule", systemImage: "plus")
                }
                Spacer()
            }
        }
        .sheet(item: $editing) { schedule in
            ScheduleEditor(schedule: schedule) { updated in
                if store.schedules.contains(where: { $0.id == updated.id }) {
                    store.replace(updated)
                } else {
                    store.add(updated)
                }
            }
        }
    }

    private func binding(for id: ScheduledMeeting.ID, keyPath: WritableKeyPath<ScheduledMeeting, Bool>) -> Binding<Bool> {
        Binding(
            get: {
                store.schedules.first(where: { $0.id == id })?[keyPath: keyPath] ?? false
            },
            set: { newValue in
                guard var schedule = store.schedules.first(where: { $0.id == id }) else { return }
                schedule[keyPath: keyPath] = newValue
                store.replace(schedule)
            }
        )
    }
}

private struct ScheduleEditor: View {
    @State var schedule: ScheduledMeeting
    let onSave: (ScheduledMeeting) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Name") {
                TextField("e.g. Team standup", text: $schedule.name)
            }
            Section("Days") {
                HStack(spacing: 6) {
                    ForEach(1...7, id: \.self) { day in
                        let selected = schedule.weekdays.contains(day)
                        Button(ScheduledMeeting.weekdayLabels[day] ?? "?") {
                            if selected {
                                schedule.weekdays.remove(day)
                            } else {
                                schedule.weekdays.insert(day)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(selected ? .accentColor : .secondary)
                    }
                }
            }
            Section("Time") {
                DatePicker(
                    "Start at",
                    selection: Binding(
                        get: {
                            var c = DateComponents()
                            c.hour = schedule.hour; c.minute = schedule.minute
                            return Calendar.current.date(from: c) ?? .now
                        },
                        set: { date in
                            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                            schedule.hour = c.hour ?? 0
                            schedule.minute = c.minute ?? 0
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
            }
            Section("Duration") {
                Stepper(
                    schedule.durationMinutes == 0 ? "Stop manually" : "Auto-stop after \(schedule.durationMinutes) min",
                    value: $schedule.durationMinutes,
                    in: 0...240,
                    step: 15
                )
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 480, minHeight: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(schedule)
                    dismiss()
                }
                .disabled(schedule.weekdays.isEmpty)
            }
        }
    }
}

private struct GeneralPane: View {
    @ObservedObject var settings: RecordSettings

    var body: some View {
        Form {
            Section {
                Toggle("Open the main window at launch", isOn: $settings.autoOpenMainWindow)
                Toggle("Play a sound when a meeting starts or stops", isOn: $settings.soundOnStartStop)
                Toggle("Post a macOS notification when a meeting ends", isOn: $settings.notifyOnStop)
            }
            Section("Retention") {
                Stepper(
                    "Delete meetings older than \(settings.retentionDays > 0 ? "\(settings.retentionDays) days" : "never")",
                    value: $settings.retentionDays,
                    in: 0...365,
                    step: 7
                )
                Text("Set to 0 to keep everything forever. Retention runs when Record launches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct KiroPane: View {
    @ObservedObject var settings: RecordSettings

    var body: some View {
        Form {
            Section("Executable") {
                TextField("kiro-cli path (blank = auto-detect)", text: $settings.kiroExecutableOverride)
                Text("Same as the RECORD_KIRO_CLI env var. Leave empty to use ~/.local/bin/kiro-cli, /opt/homebrew/bin/kiro-cli, or /Applications/Kiro CLI.app/Contents/MacOS/kiro-cli.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Timeout") {
                HStack {
                    Slider(value: $settings.kiroTimeoutSeconds, in: 30...900, step: 15)
                    Text("\(Int(settings.kiroTimeoutSeconds))s")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            Section("Automatic annotations") {
                Toggle("Generate a short title after every meeting", isOn: $settings.autoTitleOnStop)
                Toggle("Generate a summary after every meeting", isOn: $settings.autoSummaryOnStop)
            }
            Section("Summary prompt template") {
                Text("Use {TRANSCRIPT} where you want the meeting transcript to be inserted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $settings.summaryPromptTemplate)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
                    )
                HStack {
                    Spacer()
                    Button("Restore default") {
                        settings.summaryPromptTemplate = RecordSettings.defaultSummaryPrompt
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CapturePane: View {
    @ObservedObject var settings: RecordSettings

    var body: some View {
        Form {
            Section("Silence detection") {
                Stepper(
                    settings.autoPauseOnSilenceSeconds == 0
                        ? "Auto-pause disabled"
                        : "Auto-pause after \(Int(settings.autoPauseOnSilenceSeconds)) s of silence",
                    value: $settings.autoPauseOnSilenceSeconds,
                    in: 0...120,
                    step: 5
                )
                Text("When on, Record automatically pauses when there's no audio for the given duration and resumes when audio returns.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Safety cap") {
                Stepper(
                    settings.maxMeetingMinutes == 0
                        ? "No max meeting length"
                        : "Stop meetings after \(settings.maxMeetingMinutes) minutes",
                    value: $settings.maxMeetingMinutes,
                    in: 0...480,
                    step: 15
                )
            }
            Section("Auto-detect calls") {
                Toggle("Prompt me to record when a call app comes forward", isOn: $settings.autoDetectCallApps)
                Text("Watches for Zoom, Chime, Teams, Meet, Slack Huddles, Webex, and Discord. Only prompts — never auto-starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Post-meeting hook") {
                HStack {
                    TextField("Path to shell script (blank to disable)", text: $settings.postStopScriptPath)
                    Button("Pick…") { pickScript() }
                }
                Text("The script is invoked after Stop with the transcript file path as $1. Great for auto-posting summaries or piping into your own tools. Runs off the main thread; failures are silent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func pickScript() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose script"
        if panel.runModal() == .OK, let url = panel.url {
            settings.postStopScriptPath = url.path
        }
    }
}

private struct SecurityPane: View {
    @ObservedObject var lock: AppLock
    @State private var draft: String = ""
    @State private var confirm: String = ""
    @State private var errorMessage: String?
    @State private var autoLockMinutes: Int

    init(lock: AppLock) {
        self.lock = lock
        self._autoLockMinutes = State(initialValue: lock.autoLockMinutes)
    }

    var body: some View {
        Form {
            Section("Passphrase") {
                if lock.isConfigured {
                    Text("Passphrase is set. Enter a new one to change it, or clear the fields and hit Remove to disable.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Add a passphrase to gate the app on launch. Meeting transcripts stay AES-encrypted on disk regardless.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                SecureField("New passphrase", text: $draft)
                SecureField("Confirm", text: $confirm)
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Save") { save() }
                        .disabled(draft.isEmpty)
                    if lock.isConfigured {
                        Button("Remove passphrase", role: .destructive) {
                            lock.setPassphrase("")
                            draft = ""; confirm = ""
                        }
                    }
                    Spacer()
                    Button("Lock now") { lock.lockNow() }
                        .disabled(!lock.isConfigured)
                }
            }
            Section("Auto-lock") {
                Stepper(
                    autoLockMinutes == 0
                        ? "Never auto-lock"
                        : "Lock after \(autoLockMinutes) min idle",
                    value: $autoLockMinutes,
                    in: 0...240,
                    step: 5
                )
                .onChange(of: autoLockMinutes) { _, newValue in
                    lock.autoLockMinutes = newValue
                }
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        guard draft == confirm else {
            errorMessage = "The two entries don't match."
            return
        }
        lock.setPassphrase(draft)
        draft = ""; confirm = ""; errorMessage = nil
    }
}

private struct ModelsPane: View {
    @ObservedObject var models: WhisperModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Whisper transcription model")
                .font(.title2.bold())
            Text("The larger multilingual models handle accents and non-native speakers better than the small English-only models. Downloads land in Application Support and don't leave your machine.")
                .foregroundStyle(.secondary)
                .font(.callout)

            List(WhisperModelCatalog.all) { model in
                ModelRow(model: model, manager: models)
            }
            .listStyle(.inset)

            if let download = models.download {
                DownloadProgress(state: download, manager: models)
            }
        }
        .onAppear { models.probeSizes() }
    }
}

private struct ModelRow: View {
    let model: WhisperModel
    @ObservedObject var manager: WhisperModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(model.displayName).font(.headline)
                        if manager.selectedID == model.id {
                            Text("Selected")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.blue.opacity(0.15), in: Capsule())
                                .foregroundStyle(.blue)
                        }
                        if model.isMultilingual {
                            Text("Multilingual")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.purple.opacity(0.15), in: Capsule())
                                .foregroundStyle(.purple)
                        }
                    }
                    Text(model.description).font(.callout).foregroundStyle(.secondary)
                    Text(sizeLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                actionButton
            }
        }
        .padding(.vertical, 4)
    }

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: manager.size(of: model), countStyle: .file)
    }

    @ViewBuilder
    private var actionButton: some View {
        let installed = manager.installed.contains(model.id)
        let downloadingThis = manager.download?.modelID == model.id
        if downloadingThis {
            Button("Cancel", role: .destructive) { manager.cancelDownload() }
        } else if installed {
            HStack(spacing: 6) {
                Button(manager.selectedID == model.id ? "Selected" : "Use this model") {
                    manager.selectedID = model.id
                }
                .disabled(manager.selectedID == model.id)
                if model.id != "base.en" { // never let the user nuke the bundled fallback
                    Button {
                        manager.deleteModel(model)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Remove the downloaded copy of this model")
                }
            }
        } else {
            Button {
                manager.downloadModel(model)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .disabled(manager.download != nil)
        }
    }
}

private struct DownloadProgress: View {
    let state: WhisperModelManager.DownloadState
    @ObservedObject var manager: WhisperModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Downloading \(state.modelID)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(ByteCountFormatter.string(fromByteCount: state.receivedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: state.totalBytes, countStyle: .file))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: state.fraction)
            if let error = state.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
