import Foundation
import SwiftUI

/// Persistent user preferences that survive app restarts. Backed by
/// UserDefaults so nothing leaves the machine.
@MainActor
final class RecordSettings: ObservableObject {
    static let shared = RecordSettings()

    // MARK: General

    @Published var autoOpenMainWindow: Bool = defaultBool("record.autoOpenMainWindow", default: true) {
        didSet { UserDefaults.standard.set(autoOpenMainWindow, forKey: "record.autoOpenMainWindow") }
    }
    @Published var soundOnStartStop: Bool = defaultBool("record.soundOnStartStop", default: false) {
        didSet { UserDefaults.standard.set(soundOnStartStop, forKey: "record.soundOnStartStop") }
    }
    @Published var notifyOnStop: Bool = defaultBool("record.notifyOnStop", default: false) {
        didSet { UserDefaults.standard.set(notifyOnStop, forKey: "record.notifyOnStop") }
    }
    @Published var retentionDays: Int = defaultInt("record.retentionDays", default: 0) {
        didSet { UserDefaults.standard.set(retentionDays, forKey: "record.retentionDays") }
    }

    // MARK: Kiro assistant

    @Published var kiroExecutableOverride: String = defaultString("record.kiroExecutableOverride", default: "") {
        didSet { UserDefaults.standard.set(kiroExecutableOverride, forKey: "record.kiroExecutableOverride") }
    }
    @Published var kiroTimeoutSeconds: Double = defaultDouble("record.kiroTimeoutSeconds", default: 300) {
        didSet { UserDefaults.standard.set(kiroTimeoutSeconds, forKey: "record.kiroTimeoutSeconds") }
    }
    @Published var autoSummaryOnStop: Bool = defaultBool("record.autoSummaryOnStop", default: true) {
        didSet { UserDefaults.standard.set(autoSummaryOnStop, forKey: "record.autoSummaryOnStop") }
    }
    @Published var autoTitleOnStop: Bool = defaultBool("record.autoTitleOnStop", default: true) {
        didSet { UserDefaults.standard.set(autoTitleOnStop, forKey: "record.autoTitleOnStop") }
    }
    @Published var summaryPromptTemplate: String = defaultString(
        "record.summaryPromptTemplate",
        default: RecordSettings.defaultSummaryPrompt
    ) {
        didSet { UserDefaults.standard.set(summaryPromptTemplate, forKey: "record.summaryPromptTemplate") }
    }

    // MARK: Capture

    @Published var autoPauseOnSilenceSeconds: Double = defaultDouble("record.autoPauseSilence", default: 0) {
        didSet { UserDefaults.standard.set(autoPauseOnSilenceSeconds, forKey: "record.autoPauseSilence") }
    }
    @Published var maxMeetingMinutes: Int = defaultInt("record.maxMeetingMinutes", default: 0) {
        didSet { UserDefaults.standard.set(maxMeetingMinutes, forKey: "record.maxMeetingMinutes") }
    }

    // MARK: Post-meeting hook

    @Published var postStopScriptPath: String = defaultString("record.postStopScriptPath", default: "") {
        didSet { UserDefaults.standard.set(postStopScriptPath, forKey: "record.postStopScriptPath") }
    }

    // MARK: Call auto-detection

    @Published var autoDetectCallApps: Bool = defaultBool("record.autoDetectCallApps", default: false) {
        didSet { UserDefaults.standard.set(autoDetectCallApps, forKey: "record.autoDetectCallApps") }
    }

    // MARK: Defaults

    static let defaultSummaryPrompt = """
    Read the meeting transcript below. Reply with EXACTLY this format, no preamble:

    TITLE: <a short 3-6 word title>
    SUMMARY: <two to three sentences describing what was discussed and any decisions or action items>

    Transcript:
    {TRANSCRIPT}
    """

    // MARK: Helpers

    private static func defaultBool(_ key: String, default: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? `default` : UserDefaults.standard.bool(forKey: key)
    }
    private static func defaultInt(_ key: String, default: Int) -> Int {
        UserDefaults.standard.object(forKey: key) == nil ? `default` : UserDefaults.standard.integer(forKey: key)
    }
    private static func defaultDouble(_ key: String, default: Double) -> Double {
        UserDefaults.standard.object(forKey: key) == nil ? `default` : UserDefaults.standard.double(forKey: key)
    }
    private static func defaultString(_ key: String, default: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? `default`
    }

    private init() {}
}
