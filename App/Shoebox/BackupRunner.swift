import ShoeboxCore
import ShoeboxS3
import Foundation

enum BackupRunnerError: Error, CustomStringConvertible {
    case noDestination
    case busy
    case noSummary

    var description: String {
        switch self {
        case .noDestination: "No destination is set. Set \"destination\" in \(ShoeboxPaths.config.path(percentEncoded: false))."
        case .busy: "Another backup is already running."
        case .noSummary: "The backup stopped without a summary."
        }
    }
}

/// Runs one backup with the settings from config.json, as
/// `shoebox backup` does without flags.
enum BackupRunner {
    static func run(onEvent: @escaping @MainActor (BackupEvent) -> Void) async throws -> BackupSummary {
        let settings = try Settings.load()
        guard let target = settings.destination else { throw BackupRunnerError.noDestination }
        var s3 = S3Options(config: settings.s3 ?? Settings.S3())
        // The backup IAM user's key, when it is set. The AWS profile can wait
        // for a locked password manager, which stops a scheduled run.
        s3.accessKey = try AccessKeyStore().load()
        let destination = try await openDestination(target, s3: s3)

        let lock: RunLock
        do {
            lock = try RunLock()
        } catch RunLock.Failure.busy {
            throw BackupRunnerError.busy
        }
        defer { withExtendedLifetime(lock) {} }

        let library = try PhotosLibrary()
        let store = KeychainSessionStore()
        _ = try? store.importGoSessionIfEmpty()
        let photoKit = try? await PhotoKitDownloader.authorize()
        let downloader = CloudDownloader(library: library, photoKit: photoKit, iCloud: ICloudAccess(store: store), retries: 3)
        let engine = BackupEngine(library: library, destination: destination, downloader: downloader, failures: try? FailureStore())

        var options = BackupOptions()
        options.workers = settings.workers ?? 4
        options.retryFailed = settings.retryFailed == true

        let (events, task) = engine.start(options)
        return try await withTaskCancellationHandler {
            var summary: BackupSummary?
            for try await event in events {
                await onEvent(event)
                if case .finished(let finished) = event {
                    summary = finished
                }
            }
            guard let summary else { throw BackupRunnerError.noSummary }
            return summary
        } onCancel: {
            task.cancel()
        }
    }
}
