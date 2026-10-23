import ShoeboxCore
import Foundation

/// Prints backup events in the style of the Go tool.
struct BackupRenderer {
    /// The command that the retry hint shows, for example `backup --retry-failed /Volumes/Backup`.
    let retryCommand: String
    /// "Backup" or "Export", for the last line.
    var title = "Backup"
    var destinationLabel = "output directory"

    struct Outcome {
        var plan = BackupPlan()
        var summary = BackupSummary()
    }

    /// `onEvent` gets each event before it is printed.
    func render(_ events: AsyncThrowingStream<BackupEvent, Error>, onEvent: (BackupEvent) -> Void = { _ in }) async throws -> Outcome {
        let start = Date()
        var outcome = Outcome()
        var bar: ProgressBar?
        var stage: BackupStage?
        var failedItems: [String] = []
        var stageSucceeded = 0
        var stageViaPhotoKit = 0
        var stageViaICloud = 0

        func finishStage(_ summary: BackupSummary?) {
            guard let current = stage, bar != nil else { return }
            Console.line()
            switch current {
            case .copyingLocal:
                Console.line("  Copied: \(stageSucceeded)")
            case .downloadingCloud:
                Console.line("  Downloaded: \(stageSucceeded) (PhotoKit \(stageViaPhotoKit), iCloud \(stageViaICloud))")
                if let waiting = summary?.waitingForSignIn, waiting > 0 {
                    Console.line("  Waiting for iCloud sign-in: \(waiting)")
                }
            }
            if !failedItems.isEmpty {
                Console.line("  Failed: \(failedItems.count)")
                failedItems.forEach { Console.line("    - \($0)") }
            }
            Console.line()
            failedItems = []
            stageSucceeded = 0
            stageViaPhotoKit = 0
            stageViaICloud = 0
            bar = nil
        }

        for try await event in events {
            onEvent(event)
            switch event {
            case .scanningLibrary:
                Console.write("Scanning library...")

            case .scanningDestination(let libraryCount, let skippedFailed):
                Console.line(" \(libraryCount) photos")
                if skippedFailed > 0 {
                    Console.line("Skipping \(skippedFailed) previously failed photo(s) (use --retry-failed to attempt them)")
                }
                Console.write("Scanning \(destinationLabel)...")

            case .planned(let plan):
                outcome.plan = plan
                Console.line(" \(plan.alreadyBackedUp) already backed up")
                if !plan.notFound.isEmpty {
                    Console.line("Warning: \(plan.notFound.count) UUID(s) not found in the library: \(plan.notFound.prefix(5).joined(separator: ", "))\(plan.notFound.count > 5 ? ", ..." : "")")
                }
                Console.line()
                if plan.missingCount == 0 {
                    Console.line("All photos already backed up!")
                } else {
                    Console.line("Missing: \(plan.missingCount) photos")
                    if plan.localCount > 0 {
                        Console.line("  - \(plan.localCount) available locally (\(formatBytes(plan.localBytes)))")
                    }
                    if plan.cloudCount > 0 {
                        Console.line("  - \(plan.cloudCount) cloud-only (\(formatBytes(plan.cloudBytes)))")
                    }
                    Console.line()
                }

            case .stageStarted(let next, let count, let bytes):
                finishStage(nil)
                stage = next
                Console.line(next == .copyingLocal ? "Copying local files..." : "Downloading cloud-only files...")
                bar = ProgressBar(total: count, totalBytes: bytes)

            case .progress(let done, _, let bytesDone, _):
                bar?.draw(done: done, bytesDone: bytesDone)

            case .assetSucceeded(_, let source):
                stageSucceeded += 1
                if source == .photoKit { stageViaPhotoKit += 1 }
                if source == .iCloud { stageViaICloud += 1 }

            case .assetFailed(let uuid, let reason):
                failedItems.append("\(uuid): \(reason)")

            case .signInRequired(let reason):
                Console.line()
                Console.line("iCloud sign-in required (\(reason)). Assets that only the iCloud web API can get are skipped.")
                Console.line("Sign in with the Shoebox app (Settings > iCloud), or: shoebox export import-cookies <cookies.txt>")

            case .finished(let summary):
                outcome.summary = summary
                if summary.dryRun {
                    Console.line("Dry run: no files copied or downloaded.")
                    return outcome
                }
                finishStage(summary)
                if summary.failed > 0 {
                    Console.line("\(summary.failed) item(s) failed and were recorded; review with 'shoebox failures'.")
                    Console.line("Retry with: shoebox \(retryCommand)")
                    Console.line()
                }
                Console.line("\(title) complete! (took \(formatDuration(Date().timeIntervalSince(start))))")
            }
        }
        return outcome
    }
}
