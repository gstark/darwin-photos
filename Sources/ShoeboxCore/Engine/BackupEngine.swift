import Foundation

public struct BackupOptions: Sendable {
    public var startDate: CoreDataDate?
    public var endDate: CoreDataDate?
    public var workers = 4
    public var dryRun = false
    /// Also attempt assets that failed before.
    public var retryFailed = false
    /// Back up only these assets, shared album and Messages assets
    /// included. `export` sets this.
    public var onlyUUIDs: Set<String>?

    public init() {}
}

public enum BackupError: Error, CustomStringConvertible {
    case insufficientSpace(needed: Int64, available: Int64)

    public var description: String {
        switch self {
        case .insufficientSpace(let needed, let available):
            "insufficient disk space: need \(needed) bytes, have \(available) bytes"
        }
    }
}

/// Runs one incremental backup. Ported from cmd/backup.go.
///
/// 1. List the assets in the library. Shared album and Messages assets are
///    not included.
/// 2. Leave out assets that failed before, unless `retryFailed` is set.
/// 3. Leave out assets that the destination already has.
/// 4. Copy the local originals.
/// 5. Download the cloud-only originals to a staging folder, and store them.
public struct BackupEngine: Sendable {
    public let library: PhotosLibrary
    public let destination: any BackupDestination
    public let downloader: any AssetDownloading
    /// Nil disables failure tracking.
    public let failures: FailureStore?

    public init(library: PhotosLibrary, destination: any BackupDestination, downloader: any AssetDownloading, failures: FailureStore?) {
        self.library = library
        self.destination = destination
        self.downloader = downloader
        self.failures = failures
    }

    /// Starts the backup. Cancel the consuming task to stop it.
    public func run(_ options: BackupOptions) -> AsyncThrowingStream<BackupEvent, Error> {
        let (events, task) = start(options)
        return AsyncThrowingStream { continuation in
            let forward = Task {
                do {
                    for try await event in events { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                forward.cancel()
            }
        }
    }

    /// Starts the backup. Cancel `task` to stop it. The stream then ends with
    /// a `CancellationError` after the engine has removed its temporary files.
    public func start(_ options: BackupOptions) -> (events: AsyncThrowingStream<BackupEvent, Error>, task: Task<Void, Never>) {
        let (events, continuation) = AsyncThrowingStream.makeStream(of: BackupEvent.self)
        let task = Task {
            do {
                try await perform(options) { continuation.yield($0) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return (events, task)
    }

    private enum Outcome: Sendable {
        case stored(AssetSource)
        case failed(Error)
        case signInRequired(String)
    }

    private func perform(_ options: BackupOptions, emit: @escaping @Sendable (BackupEvent) -> Void) async throws {
        emit(.scanningLibrary)
        var listOptions = ListOptions()
        listOptions.startDate = options.startDate
        listOptions.endDate = options.endDate
        listOptions.excludeSharedAlbumAssets = options.onlyUUIDs == nil
        listOptions.excludeMessagesAssets = options.onlyUUIDs == nil
        var assets = try library.listAssets(listOptions).assets
        var plan = BackupPlan()
        if let only = options.onlyUUIDs {
            assets = assets.filter { only.contains($0.uuid) }
            plan.notFound = only.subtracting(assets.map(\.uuid)).sorted()
        }

        if let failures {
            _ = try? failures.prune(keeping: library.allAssetUUIDs())
        }
        let skip = options.retryFailed ? [] : (try? failures?.failedUUIDs()) ?? []
        let candidates = assets.filter { !skip.contains($0.uuid) }

        plan.libraryCount = assets.count
        plan.skippedFailed = assets.count - candidates.count
        emit(.scanningDestination(libraryCount: plan.libraryCount, skippedFailed: plan.skippedFailed))
        // Match on the UUID, not the full name. The Go `export` named files
        // with the extension from iCloud, which can differ in case.
        let existing = Set(try await destination.existingNames().map { ($0 as NSString).deletingPathExtension })

        var local: [Asset] = []
        var cloud: [Asset] = []
        for asset in candidates {
            if existing.contains(asset.uuid) {
                plan.alreadyBackedUp += 1
                continue
            }
            // Photos.sqlite can say "local" when the file is gone. Such an
            // asset is treated as cloud-only.
            if asset.isLocallyAvailable, FileManager.default.fileExists(atPath: asset.localPath(libraryPath: library.libraryPath)) {
                local.append(asset)
                plan.localCount += 1
                plan.localBytes += asset.fileSize
            } else {
                cloud.append(asset)
                plan.cloudCount += 1
                plan.cloudBytes += asset.fileSize
            }
        }
        emit(.planned(plan))

        var summary = BackupSummary()
        summary.dryRun = options.dryRun
        guard !options.dryRun, plan.missingCount > 0 else {
            emit(.finished(summary))
            return
        }

        if let available = try? destination.availableCapacity(), available < plan.missingBytes {
            throw BackupError.insufficientSpace(needed: plan.missingBytes, available: available)
        }

        let destination = destination
        let libraryPath = library.libraryPath
        if !local.isEmpty {
            emit(.stageStarted(.copyingLocal, count: local.count, bytes: plan.localBytes))
            try await runStage(local, bytes: plan.localBytes, workers: options.workers, emit: emit) { asset in
                let source = URL(filePath: asset.localPath(libraryPath: libraryPath))
                try await destination.store(file: source, name: asset.backupFilename, asset: asset)
                return .local
            } record: { asset, outcome in
                switch outcome {
                case .stored:
                    summary.copied += 1
                    summary.copiedBytes += asset.fileSize
                    try? failures?.clear(asset.uuid)
                case .failed(let error):
                    summary.localFailed += 1
                    try? failures?.fail(asset.uuid, category: .local, reason: Self.describe(error))
                case .signInRequired:
                    break
                }
            }
        }

        guard !cloud.isEmpty else {
            emit(.finished(summary))
            return
        }
        let staging = FileManager.default.temporaryDirectory.appending(path: "shoebox-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let downloader = downloader
        var signInReported = false
        emit(.stageStarted(.downloadingCloud, count: cloud.count, bytes: plan.cloudBytes))
        try await runStage(cloud, bytes: plan.cloudBytes, workers: options.workers, emit: emit) { asset in
            let staged = staging.appending(path: asset.backupFilename)
            defer { try? FileManager.default.removeItem(at: staged) }
            let source = try await downloader.download(asset, to: staged)
            try await destination.store(file: staged, name: asset.backupFilename, asset: asset)
            return source == .photoKit ? .photoKit : .iCloud
        } record: { asset, outcome in
            switch outcome {
            case .stored(let source):
                summary.downloaded += 1
                summary.downloadedBytes += asset.fileSize
                if source == .photoKit { summary.viaPhotoKit += 1 } else { summary.viaICloud += 1 }
                try? failures?.clear(asset.uuid)
            case .failed(let error):
                summary.cloudFailed += 1
                try? failures?.fail(asset.uuid, category: .cloud, reason: Self.describe(error))
            case .signInRequired(let reason):
                summary.waitingForSignIn += 1
                if !signInReported {
                    signInReported = true
                    emit(.signInRequired(reason: reason))
                }
            }
        }
        emit(.finished(summary))
    }

    /// Runs `work` for each asset with at most `workers` at a time. `record`
    /// runs on this task, so it can change local state.
    private func runStage(
        _ assets: [Asset],
        bytes: Int64,
        workers: Int,
        emit: @escaping @Sendable (BackupEvent) -> Void,
        work: @escaping @Sendable (Asset) async throws -> AssetSource,
        record: (Asset, Outcome) -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: (Asset, Outcome).self) { group in
            var pending = assets.makeIterator()
            func addNext() {
                guard let asset = pending.next() else { return }
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        return (asset, .stored(try await work(asset)))
                    } catch CloudDownloadError.signInRequired(let reason) {
                        return (asset, .signInRequired(reason))
                    } catch {
                        try Task.checkCancellation()
                        return (asset, .failed(error))
                    }
                }
            }
            for _ in 0..<max(1, workers) {
                addNext()
            }

            var done = 0
            var bytesDone: Int64 = 0
            while let (asset, outcome) = try await group.next() {
                done += 1
                record(asset, outcome)
                switch outcome {
                case .stored(let source):
                    bytesDone += asset.fileSize
                    emit(.assetSucceeded(uuid: asset.uuid, source: source))
                case .failed(let error):
                    emit(.assetFailed(uuid: asset.uuid, reason: Self.describe(error)))
                case .signInRequired:
                    break
                }
                emit(.progress(done: done, total: assets.count, bytesDone: bytesDone, bytesTotal: bytes))
                addNext()
            }
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
