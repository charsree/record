import Foundation

/// Recurring recording schedule. Local-only, stored in UserDefaults.
struct ScheduledMeeting: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// 1 = Sunday, 2 = Monday, … 7 = Saturday (matches `Calendar.component(.weekday:)`).
    var weekdays: Set<Int>
    /// Hour of day in 24h.
    var hour: Int
    /// Minute of hour.
    var minute: Int
    /// How long to record before auto-stopping. 0 = don't auto-stop.
    var durationMinutes: Int
    /// Turn the schedule off without deleting.
    var enabled: Bool = true

    static let weekdayLabels: [Int: String] = [
        1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"
    ]

    var timeLabel: String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    var weekdayLabel: String {
        let ordered = weekdays.sorted()
        if ordered == [2, 3, 4, 5, 6] { return "Weekdays" }
        if ordered == [1, 7] { return "Weekends" }
        if ordered == [1, 2, 3, 4, 5, 6, 7] { return "Every day" }
        return ordered.compactMap { Self.weekdayLabels[$0] }.joined(separator: " ")
    }
}

@MainActor
final class SchedulerStore: ObservableObject {
    static let shared = SchedulerStore()

    @Published var schedules: [ScheduledMeeting] = load() {
        didSet { persist() }
    }

    private init() {}

    private static let key = "record.schedules.v1"

    static func load() -> [ScheduledMeeting] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ScheduledMeeting].self, from: data)
        else { return [] }
        return decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(schedules) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    func add(_ schedule: ScheduledMeeting) {
        schedules.append(schedule)
    }

    func remove(_ id: ScheduledMeeting.ID) {
        schedules.removeAll { $0.id == id }
    }

    func replace(_ schedule: ScheduledMeeting) {
        guard let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        schedules[index] = schedule
    }
}

/// Ticks once a minute and starts a recording when a schedule matches.
@MainActor
final class Scheduler {
    static let shared = Scheduler()

    private var timer: Timer?
    private var lastFiredMinuteKey: Set<String> = []

    private init() {}

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Date.now
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: now)
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let minuteKey = "\(weekday)-\(hour)-\(minute)"

        for schedule in SchedulerStore.shared.schedules where schedule.enabled {
            guard schedule.weekdays.contains(weekday),
                  schedule.hour == hour,
                  schedule.minute == minute else { continue }
            let key = "\(schedule.id.uuidString)-\(minuteKey)"
            if lastFiredMinuteKey.contains(key) { continue }
            lastFiredMinuteKey.insert(key)
            let session = MeetingSession.shared
            guard !session.isRecording else { continue }
            Task {
                await session.toggleRecording()
                if schedule.durationMinutes > 0 {
                    try? await Task.sleep(for: .seconds(schedule.durationMinutes * 60))
                    if session.isRecording {
                        await session.toggleRecording()
                    }
                }
            }
        }
        // Prune ancient keys.
        if lastFiredMinuteKey.count > 200 {
            lastFiredMinuteKey.removeAll()
        }
    }
}
