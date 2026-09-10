import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Watches for known video-call apps activating in the foreground and posts
/// a "Start recording?" macOS notification when the toggle in Preferences
/// is on. The user has to accept the prompt — nothing auto-records without
/// their consent. Local-only; nothing leaves the machine.
@MainActor
final class CallDetector: ObservableObject {
    static let shared = CallDetector()

    private var isWatching = false
    private var lastPromptedBundle: String?
    private var lastPromptedAt: Date = .distantPast

    /// Known bundle IDs of call apps we care about.
    private let callBundles: Set<String> = [
        "us.zoom.xos",                       // Zoom
        "com.microsoft.teams",               // Microsoft Teams
        "com.microsoft.teams2",              // Teams 2
        "com.amazon.chime",                  // Amazon Chime
        "com.amazon.Amazon-Chime",           // Amazon Chime alt
        "com.google.meet",                   // Google Meet (native)
        "com.tinyspeck.slackmacgap",         // Slack (huddles)
        "com.hnc.Discord",                   // Discord
        "com.webex.meetingmanager",          // Webex
        "com.cisco.webexmeetingsapp",        // Webex
        "com.readdle.SparkOnMac"             // Spark? no, remove
    ]

    private init() {}

    func start() {
        guard !isWatching else { return }
        isWatching = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        // Ask for notification permission ahead of time.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    func stop() {
        guard isWatching else { return }
        isWatching = false
        NSWorkspace.shared.notificationCenter.removeObserver(self,
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func handleActivation(_ note: Notification) {
        let enabled = UserDefaults.standard.bool(forKey: "record.autoDetectCallApps")
        guard enabled else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundle = app.bundleIdentifier,
              callBundles.contains(bundle) else { return }
        // Debounce: don't reprompt for the same bundle within 5 minutes,
        // and only when we're NOT already recording.
        if bundle == lastPromptedBundle,
           Date.now.timeIntervalSince(lastPromptedAt) < 300 {
            return
        }
        guard !MeetingSession.shared.isRecording else { return }
        lastPromptedBundle = bundle
        lastPromptedAt = .now

        // Post a notification with an action to start recording.
        let content = UNMutableNotificationContent()
        content.title = "Call detected"
        content.body = "Start recording \(app.localizedName ?? "this call") in Record?"
        content.categoryIdentifier = "record.callStart"
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        let startAction = UNNotificationAction(
            identifier: "record.startRecording",
            title: "Start recording",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: "record.callStart",
            actions: [startAction],
            intentIdentifiers: [],
            options: []
        )
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        center.delegate = CallDetectorNotificationDelegate.shared
        center.add(request, withCompletionHandler: nil)
    }
}

/// Handles the user tapping "Start recording" in the notification.
final class CallDetectorNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = CallDetectorNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if response.actionIdentifier == "record.startRecording" {
            await MainActor.run {
                if !MeetingSession.shared.isRecording {
                    Task { await MeetingSession.shared.toggleRecording() }
                }
                RecordWindowActivator.bringMainWindowForward()
            }
        }
    }

    // Show the notification banner even when Record is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
