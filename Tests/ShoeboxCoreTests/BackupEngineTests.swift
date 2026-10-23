import Foundation
import Synchronization
import Testing
@testable import ShoeboxCore

struct BackupEngineTests {
    let fixture: FixtureLibrary
    let library: PhotosLibrary
    let output: URL
    let failures: FailureStore

    init() throws {
        fixture = try FixtureLibrary()
        library = try PhotosLibrary(libraryPath: fixture.path)
        output = FileManager.default.temporaryDirectory.appending(path: "backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        failures = try FailureStore(path: output.deletingLastPathComponent().appending(path: "failures-\(UUID().uuidString).db"))
    }

    private func run(
        _ destination: any BackupDestination,
        downloader: FakeDownloader = FakeDownloader(),
        _ configure: (inout BackupOptions) -> Void = { _ in }
    ) async throws -> [BackupEvent] {
        var options = BackupOptions()
        configure(&options)
        var events: [BackupEvent] = []
        let engine = BackupEngine(library: library, destination: destination, downloader: downloader, failures: failures)
        for try await event in engine.run(options) {
            events.append(event)
        }
        return events
    }

    private func plan(_ events: [BackupEvent]) -> BackupPlan? {
        events.lazy.compactMap { if case .planned(let plan) = $0 { plan } else { nil } }.first
    }

    private func summary(_ events: [BackupEvent]) -> BackupSummary? {
        events.lazy.compactMap { if case .finished(let summary) = $0 { summary } else { nil } }.first
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: output.path(percentEncoded: false)).sorted()
    }

    @Test func copiesLocalOriginalsAndDownloadsCloudAssets() async throws {
        let events = try await run(LocalDestination(directory: output))

        // Shared album, Messages, and trashed assets are not part of a backup.
        let plan = try #require(plan(events))
        #expect(plan.libraryCount == 3)
        #expect(plan.localCount == 1)
        #expect(plan.cloudCount == 2)

        let summary = try #require(summary(events))
        #expect(summary.copied == 1)
        #expect(summary.downloaded == 2)
        #expect(summary.viaPhotoKit == 2)
        #expect(events.contains(.stageStarted(.copyingLocal, count: 1, bytes: plan.localBytes)))
        #expect(events.contains(.stageStarted(.downloadingCloud, count: 2, bytes: plan.cloudBytes)))

        let copy = output.appending(path: "LOCAL-PHOTO.heic")
        #expect(try String(contentsOf: copy, encoding: .utf8) == "local photo bytes")
        // The file time is the asset's modification date.
        let modified = try copy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(modified == Date(timeIntervalSinceReferenceDate: FixtureLibrary.march10 + 60.5))
        #expect(try String(contentsOf: output.appending(path: "CLOUD-VIDEO.mov"), encoding: .utf8) == "cloud CLOUD-VIDEO")
        // No temporary file is left.
        #expect(try files() == ["CLOUD-VIDEO.mov", "LOCAL-PHOTO.heic", "NO-RESOURCE.png"])
    }

    @Test func signInRequiredIsReportedOnceAndNotRecorded() async throws {
        let downloader = FakeDownloader(signInRequired: ["CLOUD-VIDEO", "NO-RESOURCE"])
        let events = try await run(LocalDestination(directory: output), downloader: downloader)
        #expect(events.filter { if case .signInRequired = $0 { true } else { false } }.count == 1)
        #expect(summary(events)?.waitingForSignIn == 2)
        #expect(summary(events)?.failed == 0)
        #expect(try failures.failedUUIDs().isEmpty)
    }

    @Test func cloudFailuresAreRecordedAsCloud() async throws {
        let events = try await run(LocalDestination(directory: output), downloader: FakeDownloader(failing: ["CLOUD-VIDEO"]))
        #expect(summary(events)?.cloudFailed == 1)
        #expect(try failures.list(category: .cloud).map(\.uuid) == ["CLOUD-VIDEO"])
        #expect(try files() == ["LOCAL-PHOTO.heic", "NO-RESOURCE.png"])
    }

    @Test func existingFileWithAnotherExtensionCaseCounts() async throws {
        try Data().write(to: output.appending(path: "CLOUD-VIDEO.MOV"))
        let events = try await run(LocalDestination(directory: output)) { $0.dryRun = true }
        #expect(plan(events)?.alreadyBackedUp == 1)
        #expect(plan(events)?.cloudCount == 1)
    }

    @Test func partialFilesDoNotCount() async throws {
        try Data().write(to: output.appending(path: ".LOCAL-PHOTO.heic.partial"))
        try Data().write(to: output.appending(path: "CLOUD-VIDEO.mov.part-123"))
        let events = try await run(LocalDestination(directory: output)) { $0.dryRun = true }
        #expect(plan(events)?.alreadyBackedUp == 0)
    }

    @Test func onlyUUIDsIncludesSharedAndMessagesAssetsAndReportsMissing() async throws {
        let events = try await run(LocalDestination(directory: output)) {
            $0.onlyUUIDs = ["SHARED-PHOTO", "MESSAGES-PHOTO", "CLOUD-VIDEO", "NOT-THERE"]
        }
        #expect(plan(events)?.libraryCount == 3)
        #expect(plan(events)?.notFound == ["NOT-THERE"])
        #expect(try files() == ["CLOUD-VIDEO.mov", "MESSAGES-PHOTO.heic", "SHARED-PHOTO.jpg"])
    }

    @Test func secondRunCopiesNothing() async throws {
        let destination = try LocalDestination(directory: output)
        _ = try await run(destination)
        let events = try await run(destination)
        #expect(plan(events)?.alreadyBackedUp == 3)
        #expect(plan(events)?.missingCount == 0)
    }

    @Test func dryRunCopiesNothing() async throws {
        let events = try await run(LocalDestination(directory: output)) { $0.dryRun = true }
        #expect(plan(events)?.localCount == 1)
        #expect(summary(events)?.dryRun == true)
        #expect(try files().isEmpty)
    }

    @Test func failuresAreRecordedThenSkipped() async throws {
        let events = try await run(FailingDestination())
        #expect(summary(events)?.localFailed == 1)
        #expect(summary(events)?.cloudFailed == 2)
        #expect(try failures.list(category: .local).map(\.uuid) == ["LOCAL-PHOTO"])

        let second = try await run(LocalDestination(directory: output))
        #expect(plan(second)?.skippedFailed == 3)
        #expect(plan(second)?.missingCount == 0)

        // A retry that succeeds clears the record.
        let retry = try await run(LocalDestination(directory: output)) { $0.retryFailed = true }
        #expect(summary(retry)?.copied == 1)
        #expect(summary(retry)?.downloaded == 2)
        #expect(try failures.failedUUIDs().isEmpty)
    }

    @Test func staleFailuresArePruned() async throws {
        try failures.fail("DELETED-LONG-AGO", category: .cloud, reason: "")
        _ = try await run(LocalDestination(directory: output)) { $0.dryRun = true }
        #expect(try failures.failedUUIDs().isEmpty)
    }

    @Test func cancelRemovesTheStagingFolder() async throws {
        let downloader = FakeDownloader(delay: .seconds(30))
        let engine = BackupEngine(library: library, destination: try LocalDestination(directory: output), downloader: downloader, failures: failures)
        let (events, task) = engine.start(BackupOptions())
        await #expect(throws: CancellationError.self) {
            for try await event in events {
                if case .stageStarted(.downloadingCloud, _, _) = event {
                    try await Task.sleep(for: .milliseconds(100))
                    task.cancel()
                }
            }
        }
        let staging = try #require(downloader.targets.first?.deletingLastPathComponent())
        #expect(!FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)))
    }

    @Test func backupFilenameFallsBackToJPG() throws {
        var asset = try library.asset(uuid: "LOCAL-PHOTO")
        #expect(asset.backupFilename == "LOCAL-PHOTO.heic")
        asset.filename = "NOEXT"
        #expect(asset.backupFilename == "LOCAL-PHOTO.jpg")
    }
}

/// Writes `cloud <UUID>` for each asset, unless the UUID is in a set.
final class FakeDownloader: AssetDownloading {
    struct Unavailable: Error {}

    let signInRequired: Set<String>
    let failing: Set<String>
    let delay: Duration?
    private let log = Mutex<[URL]>([])

    init(signInRequired: Set<String> = [], failing: Set<String> = [], delay: Duration? = nil) {
        self.signInRequired = signInRequired
        self.failing = failing
        self.delay = delay
    }

    var targets: [URL] { log.withLock { $0 } }

    func download(_ asset: Asset, to target: URL) async throws -> DownloadSource {
        log.withLock { $0.append(target) }
        if let delay { try await Task.sleep(for: delay) }
        if signInRequired.contains(asset.uuid) { throw CloudDownloadError.signInRequired("not signed in") }
        if failing.contains(asset.uuid) { throw Unavailable() }
        try Data("cloud \(asset.uuid)".utf8).write(to: target)
        return .photoKit
    }
}

/// A destination that rejects every file.
private struct FailingDestination: BackupDestination {
    struct Rejected: Error {}

    var displayName: String { "failing" }
    func existingNames() async throws -> Set<String> { [] }
    func availableCapacity() throws -> Int64? { nil }
    func store(file: URL, name: String, asset: Asset) async throws { throw Rejected() }
}
