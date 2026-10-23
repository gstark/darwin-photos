import AppKit

/// Asks the model to check for a due backup: each hour, after the Mac wakes,
/// and soon after launch. The model decides if a backup is due.
@MainActor
final class Scheduler {
    private let activity = NSBackgroundActivityScheduler(identifier: "com.gstark.shoebox.schedule")
    private var observers: [Task<Void, Never>] = []

    func start(check: @escaping @MainActor () -> Void) {
        activity.repeats = true
        activity.interval = 60 * 60
        activity.tolerance = 5 * 60
        activity.qualityOfService = .utility
        activity.schedule { completion in
            // The check only starts a backup, so the activity ends at once.
            Task { @MainActor in check() }
            completion(.finished)
        }

        observers.append(Task {
            // Give the network time to connect after launch.
            try? await Task.sleep(for: .seconds(30))
            check()
        })
        observers.append(Task {
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                try? await Task.sleep(for: .seconds(60))
                check()
            }
        })
    }
}
