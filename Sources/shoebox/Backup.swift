import ArgumentParser
import ShoeboxCore
import ShoeboxS3
import Foundation

struct Backup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Incrementally back up all photos to a directory",
        discussion: """
            Copies every photo that the destination does not have yet. Files are
            named <UUID>.<ext>, so a second run copies only new photos.

            Defaults come from ~/.shoebox/config.json ("destination",
            "workers", "retry_failed"). Command-line values take precedence.

            Local originals are copied. Cloud-only originals download through
            PhotoKit. Assets that PhotoKit cannot see download through the
            iCloud web API, which needs a saved iCloud session.

            The destination can be an S3 URI. S3 settings come from the --s3-* flags,
            then from "s3" in the config file. Uploads never replace an object.

            Examples:
              shoebox backup /Volumes/Backup/Photos
              shoebox backup s3://my-bucket/photos-backup
              shoebox backup --start 2024-01-01 /Volumes/Backup/Photos
            """
    )

    @OptionGroup var libraryOptions: LibraryOptions

    @Argument(help: "The backup folder. Defaults to \"destination\" in the config file.")
    var destination: String?

    @Option(name: [.short, .long], help: "Number of parallel workers for copies and downloads (default: 4, or \"workers\" in the config file)")
    var workers: Int?

    @Option(name: [.short, .long], help: "Number of retry attempts for failed iCloud downloads")
    var retry = 3

    @Option(help: "Start date (YYYY-MM-DD), inclusive")
    var start: String?

    @Option(help: "End date (YYYY-MM-DD), inclusive")
    var end: String?

    @Flag(help: "Scan and report what would be backed up, without copying")
    var dryRun = false

    @Flag(help: "Attempt assets previously recorded as failed (skipped by default)")
    var retryFailed = false

    @Option(name: .customLong("s3-endpoint"), help: "Custom S3-compatible endpoint URL")
    var s3Endpoint: String?

    @Option(name: .customLong("s3-region"), help: "S3 region (overrides AWS config when set)")
    var s3Region: String?

    @Option(name: .customLong("s3-profile"), help: "AWS shared-config profile (overrides AWS_PROFILE when set)")
    var s3Profile: String?

    @Flag(name: .customLong("s3-force-path-style"), help: "Use path-style S3 addressing")
    var s3ForcePathStyle = false

    @Option(name: .customLong("s3-sse"), help: "S3 server-side encryption mode (AES256 or aws:kms)")
    var s3SSE: String?

    @Option(name: .customLong("s3-kms-key-id"), help: "S3 KMS key ID for SSE-KMS")
    var s3KMSKeyID: String?

    @Option(name: .customLong("s3-storage-class"), help: "S3 storage class for uploaded objects")
    var s3StorageClass: String?

    func run() async throws {
        let settings = try Settings.load()
        var options = BackupOptions()
        options.workers = workers ?? settings.workers ?? 4
        options.dryRun = dryRun
        options.retryFailed = retryFailed || settings.retryFailed == true
        if let start {
            options.startDate = try parseDay(start, label: "start")
        }
        if let end {
            options.endDate = try parseDay(end, label: "end")
        }
        guard options.workers >= 1 else {
            throw ValidationError("--workers must be at least 1, got \(options.workers)")
        }
        guard retry >= 0 else {
            throw ValidationError("--retry must not be negative, got \(retry)")
        }

        guard let target = destination ?? settings.destination else {
            throw CLIError("no output destination: pass one as an argument or set \"destination\" in \(ShoeboxPaths.config.path(percentEncoded: false))")
        }
        let destination = try await openDestination(target, s3: s3Options(settings.s3 ?? Settings.S3()))

        let lock: RunLock
        do {
            lock = try RunLock()
        } catch RunLock.Failure.busy {
            throw CLIError("another backup is already running")
        }

        let failures: FailureStore?
        do {
            failures = try FailureStore()
        } catch {
            Console.line("Warning: could not open failure store, skip-tracking disabled: \(error)")
            failures = nil
        }

        let library = try libraryOptions.open()
        let downloader = await CloudSetup.downloader(library: library, retries: retry, interactive: !dryRun)
        let engine = BackupEngine(library: library, destination: destination, downloader: downloader, failures: failures)
        let renderer = BackupRenderer(
            retryCommand: "backup --retry-failed \(target)",
            destinationLabel: destination is S3Destination ? "S3 destination" : "output directory"
        )
        let startedAt = Date()
        let history = RunHistory()
        let log = dryRun ? nil : history.startLog(startedAt: startedAt, trigger: .cli, destination: target)
        let (events, task) = engine.start(options)
        let outcome: BackupRenderer.Outcome
        do {
            outcome = try await withInterruptHandler(stop: task.cancel) {
                try await renderer.render(events) { log?.write($0) }
            }
        } catch {
            if !dryRun {
                let result: RunRecord.Outcome = error is CancellationError || (error as? ExitCode) == ExitCode(130) ? .cancelled : .failed(String(describing: error))
                log?.finish(result)
                try? history.append(RunRecord(startedAt: startedAt, trigger: .cli, outcome: result, destination: target))
            }
            throw error
        }
        if !dryRun {
            log?.finish(.succeeded)
            // The app's scheduler counts this run.
            try? history.append(RunRecord(startedAt: startedAt, trigger: .cli, summary: outcome.summary, destination: target))
        }
        withExtendedLifetime(lock) {}
        // As in the Go tool, a failed S3 backup exits with an error.
        if destination is S3Destination, outcome.summary.failed > 0 {
            throw CLIError("\(outcome.summary.failed) backups failed")
        }
    }

    /// Flags first, then the config file. Ported from `applyBackupConfig`.
    private func s3Options(_ config: Settings.S3) -> S3Options {
        var options = S3Options(config: config)
        options.profile = s3Profile ?? options.profile
        options.region = s3Region ?? options.region
        options.endpoint = s3Endpoint ?? options.endpoint
        options.forcePathStyle = s3ForcePathStyle || options.forcePathStyle
        options.sse = s3SSE ?? options.sse
        options.kmsKeyID = s3KMSKeyID ?? options.kmsKeyID
        options.storageClass = s3StorageClass ?? options.storageClass
        return options
    }
}

/// Parses `YYYY-MM-DD` as midnight UTC, as the Go tool does.
func parseDay(_ value: String, label: String) throws -> CoreDataDate {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let date = formatter.date(from: value) else {
        throw ValidationError("invalid \(label) date \"\(value)\": use YYYY-MM-DD format")
    }
    return CoreDataDate(date)
}
