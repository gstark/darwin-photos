import AppKit
import ShoeboxCore
import Foundation
import Observation
import Photos

/// The state that the menu shows. All changes happen on the main actor.
@MainActor
@Observable
final class AppModel {
    /// Progress of the run in progress.
    struct Progress: Equatable {
        /// Set when the library scan is done.
        var libraryCount: Int?
        var plan: BackupPlan?
        var stage: BackupStage?
        var stageStartedAt = Date()
        var done = 0
        var total = 0
        var bytesDone: Int64 = 0
        var bytesTotal: Int64 = 0
        /// The average speed of the current stage.
        var bytesPerSecond: Double?
        var stored = 0
        var failed = 0

        var fraction: Double? {
            guard stage != nil else { return nil }
            if bytesTotal > 0 { return Double(bytesDone) / Double(bytesTotal) }
            return total > 0 ? Double(done) / Double(total) : nil
        }

        var secondsLeft: Double? {
            guard let bytesPerSecond, bytesPerSecond > 0, bytesTotal > bytesDone else { return nil }
            return Double(bytesTotal - bytesDone) / bytesPerSecond
        }
    }

    private(set) var isRunning = false
    private(set) var progress = Progress()
    /// The last run of the app or the CLI.
    private(set) var lastRun: RunRecord?
    /// When the next scheduled backup is due. Nil when the schedule is off.
    private(set) var nextRun: Date?
    /// Why a due scheduled backup waits. Empty when nothing waits.
    private(set) var waitReasons: [WaitReason] = []
    private(set) var schedule = Schedule()
    let monitor = SystemMonitor()
    let notifier = Notifier()
    /// Increases when something asks for the login window. The menu bar
    /// label opens it, because the label view always exists.
    private(set) var loginWindowRequests = 0
    private let history = RunHistory()
    private let scheduler = Scheduler()
    private(set) var failureCount: Int?
    private(set) var permissions = Permissions.current()
    let account = ICloudAccount()
    /// The current frame of the running icon.
    private(set) var activityFrame = 0
    private var task: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?

    init() {
        lastRun = history.last
        reloadSchedule()
        scheduler.start { [weak self] in self?.runIfDue() }
        // A network change or a connected drive can end a wait.
        monitor.start { [weak self] in self?.runIfDue() }
        notifier.start { [weak self] in self?.loginWindowRequests += 1 }
        refreshFailureCount()
        // The user grants permissions in System Settings, then comes back.
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                self?.refreshPermissions()
            }
        }
    }

    var needsAttention: Bool {
        if !permissions.complete { return true }
        if case .failed = lastRun?.outcome { return true }
        return lastRun?.waitingForSignIn ?? 0 > 0
    }

    /// Reads the schedule from config.json again, for example after a save
    /// in Settings.
    func reloadSchedule() {
        schedule = (try? Settings.load())?.schedule ?? Schedule()
        updateNextRun()
    }

    /// Starts a scheduled backup if one is due and the conditions allow it.
    func runIfDue() {
        reloadSchedule()
        lastRun = history.last
        guard !isRunning, permissions.complete else { return }
        guard ScheduleRules(schedule).isDue(lastSuccess: history.lastSuccess?.startedAt, now: Date()) else {
            waitReasons = []
            return
        }
        let destination = (try? Settings.load())?.destination
        let isS3 = destination?.hasPrefix("s3://") ?? false
        let state = monitor.state(destinationFolder: isS3 ? nil : destination)
        waitReasons = schedule.waitReasons(state, destinationIsS3: isS3)
        if waitReasons.isEmpty {
            start(.scheduled)
        }
    }

    func backUpNow() {
        start(.manual)
    }

    private func updateNextRun() {
        nextRun = ScheduleRules(schedule).nextRun(lastSuccess: history.lastSuccess?.startedAt, now: Date())
    }

    private func start(_ trigger: RunRecord.Trigger) {
        guard !isRunning else { return }
        isRunning = true
        waitReasons = []
        progress = Progress()
        activityTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: ActivityIcon.interval)
                activityFrame = (activityFrame + 1) % ActivityIcon.frameCount
            }
        }
        // Idle sleep would stop the backup. The display can still sleep.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "Backing up photos"
        )
        task = Task {
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let startedAt = Date()
            let destination = (try? Settings.load())?.destination
            let log = history.startLog(startedAt: startedAt, trigger: trigger, destination: destination)
            let run: RunRecord
            do {
                let summary = try await BackupRunner.run { event in
                    log?.write(event)
                    self.apply(event)
                }
                run = RunRecord(startedAt: startedAt, trigger: trigger, summary: summary, destination: destination)
            } catch is CancellationError {
                run = RunRecord(startedAt: startedAt, trigger: trigger, outcome: .cancelled, destination: destination)
            } catch {
                run = RunRecord(startedAt: startedAt, trigger: trigger, outcome: .failed(String(describing: error)), destination: destination)
            }
            log?.finish(run.outcome)
            try? history.append(run)
            lastRun = run
            await notifier.notify(run)
            updateNextRun()
            isRunning = false
            task = nil
            activityTask?.cancel()
            activityTask = nil
            activityFrame = 0
            refreshFailureCount()
            account.reload()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func refreshPermissions() {
        permissions = Permissions.current()
    }

    func requestPhotosAccess() async {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refreshPermissions()
    }

    func refreshFailureCount() {
        failureCount = try? FailureStore().failedUUIDs().count
    }

    private func apply(_ event: BackupEvent) {
        switch event {
        case .scanningDestination(let libraryCount, _):
            progress.libraryCount = libraryCount
        case .planned(let plan):
            progress.plan = plan
        case .stageStarted(let stage, let count, let bytes):
            progress.stage = stage
            progress.stageStartedAt = Date()
            progress.done = 0
            progress.total = count
            progress.bytesDone = 0
            progress.bytesTotal = bytes
            progress.bytesPerSecond = nil
        case .progress(let done, let total, let bytesDone, let bytesTotal):
            progress.done = done
            progress.total = total
            progress.bytesDone = bytesDone
            progress.bytesTotal = bytesTotal
            let elapsed = Date().timeIntervalSince(progress.stageStartedAt)
            progress.bytesPerSecond = elapsed > 1 ? Double(bytesDone) / elapsed : nil
        case .assetSucceeded:
            progress.stored += 1
        case .assetFailed:
            progress.failed += 1
        default:
            break
        }
    }

}
