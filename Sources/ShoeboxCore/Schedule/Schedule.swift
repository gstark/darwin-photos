import Foundation

/// The `schedule` object in config.json. Only the app reads it.
public struct Schedule: Codable, Sendable, Equatable {
    public enum Frequency: String, Codable, Sendable, CaseIterable {
        case off, daily, weekly
    }

    public var frequency: Frequency?
    /// `HH:mm`, local time.
    public var windowStart: String?
    public var windowEnd: String?
    /// Check for a due backup when the destination drive connects.
    public var onMount: Bool?
    /// Scheduled backups wait for the power adapter.
    public var requirePower: Bool?
    /// Scheduled backups wait while the network is expensive or constrained,
    /// for example a personal hotspot.
    public var skipExpensiveNetwork: Bool?
    /// Scheduled backups run only on these Wi-Fi networks. Empty or missing
    /// allows every network.
    public var wifiNetworks: [String]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case frequency
        case windowStart = "window_start"
        case windowEnd = "window_end"
        case onMount = "on_mount"
        case requirePower = "require_power"
        case skipExpensiveNetwork = "skip_expensive_network"
        case wifiNetworks = "wifi_networks"
    }

    public init() {}

    public static let defaultWindowStart = TimeOfDay(hour: 1, minute: 0)
    public static let defaultWindowEnd = TimeOfDay(hour: 6, minute: 0)
}

/// A time on the clock, without a date.
public struct TimeOfDay: Sendable, Equatable, Comparable, CustomStringConvertible {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// Parses `HH:mm`.
    public init?(_ text: String) {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute)
        else { return nil }
        self.init(hour: hour, minute: minute)
    }

    var minutes: Int { hour * 60 + minute }

    public var description: String { String(format: "%02d:%02d", hour, minute) }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool { lhs.minutes < rhs.minutes }
}

/// Decides when a scheduled backup is due.
///
/// - The window gives the earliest time of day for a backup. A window can
///   cross midnight, for example 22:00 to 06:00.
/// - A daily backup is due when no backup succeeded since the start of the
///   most recent window. A weekly backup is due when no backup succeeded in
///   the 6 days before that.
/// - So a Mac that sleeps through the window backs up soon after it wakes.
/// - The first backup, with no earlier success, waits for the window.
public struct ScheduleRules: Sendable {
    public let frequency: Schedule.Frequency
    public let windowStart: TimeOfDay
    public let windowEnd: TimeOfDay
    public let calendar: Calendar

    public init(_ schedule: Schedule, calendar: Calendar = .current) {
        frequency = schedule.frequency ?? .off
        windowStart = schedule.windowStart.flatMap(TimeOfDay.init) ?? Schedule.defaultWindowStart
        windowEnd = schedule.windowEnd.flatMap(TimeOfDay.init) ?? Schedule.defaultWindowEnd
        self.calendar = calendar
    }

    public func isDue(lastSuccess: Date?, now: Date) -> Bool {
        guard frequency != .off else { return false }
        guard let lastSuccess else { return isInWindow(now) }
        return lastSuccess < threshold(for: mostRecentWindowStart(atOrBefore: now))
    }

    /// When the next scheduled backup becomes due. `now` if it is due now.
    public func nextRun(lastSuccess: Date?, now: Date) -> Date? {
        guard frequency != .off else { return nil }
        if isDue(lastSuccess: lastSuccess, now: now) { return now }
        guard let lastSuccess else { return nextWindowStart(after: now) }
        // The first window start whose threshold is after the last success.
        let reference = calendar.date(byAdding: .day, value: periodDays - 1, to: lastSuccess)!
        return nextWindowStart(after: reference)
    }

    public func isInWindow(_ date: Date) -> Bool {
        let start = mostRecentWindowStart(atOrBefore: date)
        return date < start.addingTimeInterval(TimeInterval(windowMinutes * 60))
    }

    private var periodDays: Int { frequency == .weekly ? 7 : 1 }

    /// A start time equal to the end time means the whole day.
    private var windowMinutes: Int {
        let length = (windowEnd.minutes - windowStart.minutes + 24 * 60) % (24 * 60)
        return length == 0 ? 24 * 60 : length
    }

    private func threshold(for windowStart: Date) -> Date {
        calendar.date(byAdding: .day, value: -(periodDays - 1), to: windowStart)!
    }

    private func windowStart(onDayOf date: Date) -> Date {
        calendar.date(bySettingHour: windowStart.hour, minute: windowStart.minute, second: 0, of: date)!
    }

    private func mostRecentWindowStart(atOrBefore date: Date) -> Date {
        let today = windowStart(onDayOf: date)
        if today <= date { return today }
        return windowStart(onDayOf: calendar.date(byAdding: .day, value: -1, to: date)!)
    }

    private func nextWindowStart(after date: Date) -> Date {
        let today = windowStart(onDayOf: date)
        if today > date { return today }
        return windowStart(onDayOf: calendar.date(byAdding: .day, value: 1, to: date)!)
    }
}
