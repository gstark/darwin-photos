import Foundation
import Testing
@testable import ShoeboxCore

struct ScheduleRulesTests {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    /// 2026-10-14 (a Wednesday) at the given time, New York time.
    func at(_ time: String, dayOffset: Int = 0) -> Date {
        let parts = time.split(separator: ":").map { Int($0)! }
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14 + dayOffset, hour: parts[0], minute: parts[1]))!
        return day
    }

    func rules(_ frequency: Schedule.Frequency, _ start: String = "01:00", _ end: String = "06:00") -> ScheduleRules {
        var schedule = Schedule()
        schedule.frequency = frequency
        schedule.windowStart = start
        schedule.windowEnd = end
        return ScheduleRules(schedule, calendar: calendar)
    }

    @Test func offIsNeverDue() {
        #expect(!rules(.off).isDue(lastSuccess: nil, now: at("02:00")))
        #expect(rules(.off).nextRun(lastSuccess: nil, now: at("02:00")) == nil)
        // A missing frequency means off.
        #expect(ScheduleRules(Schedule(), calendar: calendar).frequency == .off)
    }

    @Test func theFirstBackupWaitsForTheWindow() {
        let daily = rules(.daily)
        #expect(!daily.isDue(lastSuccess: nil, now: at("00:30")))
        #expect(daily.isDue(lastSuccess: nil, now: at("01:00")))
        #expect(!daily.isDue(lastSuccess: nil, now: at("06:00")))
        #expect(daily.nextRun(lastSuccess: nil, now: at("12:00")) == at("01:00", dayOffset: 1))
    }

    @Test func dailyRunsOncePerWindowAndCatchesUpAfterSleep() {
        let daily = rules(.daily)
        // Backed up last night in the window.
        #expect(!daily.isDue(lastSuccess: at("01:10"), now: at("03:00")))
        #expect(!daily.isDue(lastSuccess: at("01:10"), now: at("23:00")))
        #expect(daily.nextRun(lastSuccess: at("01:10"), now: at("03:00")) == at("01:00", dayOffset: 1))
        // A backup in the evening does not count for the next night.
        #expect(daily.isDue(lastSuccess: at("20:00", dayOffset: -1), now: at("01:30")))
        // Asleep through the window: due when the Mac wakes at 08:00.
        #expect(daily.isDue(lastSuccess: at("01:10", dayOffset: -1), now: at("08:00")))
    }

    @Test func weeklyWaitsSixDaysBeforeTheWindow() {
        let weekly = rules(.weekly)
        #expect(!weekly.isDue(lastSuccess: at("01:10"), now: at("02:00", dayOffset: 5)))
        #expect(!weekly.isDue(lastSuccess: at("01:10"), now: at("02:00", dayOffset: 6)))
        #expect(weekly.isDue(lastSuccess: at("01:10"), now: at("02:00", dayOffset: 7)))
        #expect(weekly.nextRun(lastSuccess: at("01:10"), now: at("02:00", dayOffset: 2)) == at("01:00", dayOffset: 7))
    }

    @Test func aWindowCanCrossMidnight() {
        let daily = rules(.daily, "22:00", "02:00")
        #expect(daily.isInWindow(at("23:30")))
        #expect(daily.isInWindow(at("01:30")))
        #expect(!daily.isInWindow(at("02:00")))
        #expect(!daily.isInWindow(at("21:59")))
        // Backed up at 23:30 yesterday: the window that started at 22:00
        // yesterday is done, so nothing is due until 22:00 today.
        #expect(!daily.isDue(lastSuccess: at("23:30", dayOffset: -1), now: at("01:00")))
        #expect(daily.nextRun(lastSuccess: at("23:30", dayOffset: -1), now: at("01:00")) == at("22:00"))
    }

    @Test func equalStartAndEndMeansTheWholeDay() {
        let daily = rules(.daily, "03:00", "03:00")
        #expect(daily.isInWindow(at("02:59")))
        #expect(daily.isInWindow(at("03:00")))
    }

    @Test func badTimesUseTheDefaultWindow() {
        let daily = rules(.daily, "25:00", "x")
        #expect(daily.windowStart == Schedule.defaultWindowStart)
        #expect(daily.windowEnd == Schedule.defaultWindowEnd)
        #expect(TimeOfDay("7:05")?.description == "07:05")
    }
}

struct RunHistoryTests {
    let url = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID().uuidString)/history.json")

    @Test func keepsTheNewestRecordsAndFindsTheLastSuccess() throws {
        let history = RunHistory(url: url)
        #expect(history.records().isEmpty)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try history.append(RunRecord(startedAt: start, finishedAt: start, trigger: .scheduled, outcome: .succeeded))
        try history.append(RunRecord(startedAt: start + 60, finishedAt: start + 60, trigger: .cli, outcome: .failed("no network")))
        #expect(history.lastSuccess?.trigger == .scheduled)
        #expect(history.last?.outcome == .failed("no network"))

        for index in 0..<RunHistory.limit {
            try history.append(RunRecord(startedAt: start + Double(index), finishedAt: start, trigger: .manual, outcome: .cancelled))
        }
        #expect(history.records().count == RunHistory.limit)
        #expect(history.lastSuccess == nil)
    }

    @Test func keepsTheLogsOfTheRecordsOnly() throws {
        let history = RunHistory(url: url)
        let first = Date(timeIntervalSince1970: 1_800_000_000.25)
        history.startLog(startedAt: first, trigger: .manual, destination: "/Volumes/Backup")?.finish(.cancelled)
        try history.append(RunRecord(startedAt: first, trigger: .manual, outcome: .cancelled))

        // The record keeps whole seconds. The log name must match it.
        let record = try #require(history.records().first)
        let log = try #require(history.log(for: record))
        #expect(log.contains("Backup started (manual)"))
        #expect(log.contains("Destination: /Volumes/Backup"))
        #expect(log.contains("Backup cancelled"))

        for index in 1...RunHistory.limit {
            let start = first + Double(index)
            _ = history.startLog(startedAt: start, trigger: .scheduled, destination: nil)
            try history.append(RunRecord(startedAt: start, trigger: .scheduled, outcome: .cancelled))
        }
        #expect(history.log(for: record) == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: history.logs.path(percentEncoded: false))
        #expect(files.count == RunHistory.limit)
    }

    @Test func readsRecordsWithoutTheNewFields() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"""
            [{"failed": 0, "finishedAt": "2026-10-17T05:00:19Z", "outcome": {"succeeded": {}},
              "startedAt": "2026-10-17T05:00:07Z", "stored": 1, "trigger": "scheduled", "waitingForSignIn": 0}]
            """#.utf8).write(to: url)
        let record = try #require(RunHistory(url: url).last)
        #expect(record.stored == 1)
        #expect(record.bytesStored == nil)
        #expect(record.duration == 12)
    }
}

struct RunLogTests {
    @Test func logsThePlanAndFailuresButNotEachPhoto() {
        var plan = BackupPlan()
        plan.alreadyBackedUp = 10
        plan.localCount = 2
        plan.cloudCount = 1
        #expect(RunLog.lines(for: .planned(plan)).count == 2)
        #expect(RunLog.lines(for: .assetSucceeded(uuid: "A", source: .local)).isEmpty)
        #expect(RunLog.lines(for: .progress(done: 1, total: 2, bytesDone: 1, bytesTotal: 2)).isEmpty)
        #expect(RunLog.lines(for: .assetFailed(uuid: "B", reason: "gone")) == ["Failed B: gone"])
    }
}

struct ScheduleSettingsTests {
    @Test func saveKeepsUnknownScheduleKeys() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "schedule-\(UUID().uuidString)/config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schedule": {"frequency": "daily", "future": 1}}"#.utf8).write(to: url)

        var settings = try Settings.load(from: url)
        #expect(settings.schedule?.frequency == .daily)
        settings.schedule?.wifiNetworks = ["Home"]
        try settings.save(to: url)

        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let schedule = try #require(json["schedule"] as? [String: Any])
        #expect(schedule["future"] as? Int == 1)
        #expect(schedule["wifi_networks"] as? [String] == ["Home"])
    }
}

struct WaitReasonTests {
    let home = SystemState(onPowerAdapter: true, network: .wifi(wifiName: "Home", expensive: false))

    @Test func theDefaultsWaitForPowerAndACheapNetwork() {
        let schedule = Schedule()
        #expect(schedule.waitReasons(home, destinationIsS3: true).isEmpty)
        var state = home
        state.onPowerAdapter = false
        state.network = .wifi(wifiName: "Phone", expensive: true)
        #expect(schedule.waitReasons(state, destinationIsS3: true) == [.onBattery, .expensiveNetwork])

        var relaxed = Schedule()
        relaxed.requirePower = false
        relaxed.skipExpensiveNetwork = false
        #expect(relaxed.waitReasons(state, destinationIsS3: true).isEmpty)
    }

    @Test func s3NeedsANetworkAndAFolderNeedsItsDrive() {
        let offline = SystemState(onPowerAdapter: true, network: .offline, destinationFolderExists: false)
        #expect(Schedule().waitReasons(offline, destinationIsS3: true) == [.offline])
        #expect(Schedule().waitReasons(offline, destinationIsS3: false) == [.destinationNotConnected])
    }

    @Test func onlyAllowedWiFiNetworks() {
        var schedule = Schedule()
        schedule.wifiNetworks = ["Home", "Home-5G"]
        #expect(schedule.waitReasons(home, destinationIsS3: true).isEmpty)

        var state = home
        state.network = .wifi(wifiName: "Coffee Shop", expensive: false)
        #expect(schedule.waitReasons(state, destinationIsS3: true) == [.otherWiFi("Coffee Shop")])
        state.network = .wifi(wifiName: nil, expensive: false)
        #expect(schedule.waitReasons(state, destinationIsS3: true) == [.unknownWiFi])
        state.network = .other(expensive: false)
        #expect(schedule.waitReasons(state, destinationIsS3: true) == [.notOnAllowedNetwork])
        // A wired connection passes.
        state.network = .wired(expensive: false)
        #expect(schedule.waitReasons(state, destinationIsS3: true).isEmpty)
    }
}
