import Foundation

/// The text log of one backup run. Each line starts with the local time.
/// `RunHistory.startLog` opens it, and `RunHistory.append` deletes it with
/// its record.
public final class RunLog: Sendable {
    public let url: URL
    private let handle: FileHandle

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path(percentEncoded: false)])
        }
        self.url = url
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle.close()
    }

    public func write(_ message: String, at date: Date = Date()) {
        let time = date.formatted(Date.ISO8601FormatStyle(dateTimeSeparator: .space, timeZone: .current))
        try? handle.write(contentsOf: Data("\(time)  \(message)\n".utf8))
    }

    public func write(_ event: BackupEvent) {
        let now = Date()
        for line in Self.lines(for: event) {
            write(line, at: now)
        }
    }

    public func finish(_ outcome: RunRecord.Outcome) {
        switch outcome {
        case .succeeded: write("Backup finished")
        case .cancelled: write("Backup cancelled")
        case .failed(let reason): write("Backup failed: \(reason)")
        }
    }

    /// Progress and each stored photo give no lines. A run of 50,000 photos
    /// would otherwise give an unreadable log.
    static func lines(for event: BackupEvent) -> [String] {
        switch event {
        case .scanningLibrary:
            return ["Scanning the Photos library"]
        case .scanningDestination(let libraryCount, let skippedFailed):
            var lines = ["Library: \(libraryCount.formatted()) photos"]
            if skippedFailed > 0 {
                lines.append("Skipping \(skippedFailed.formatted()) photos that failed before")
            }
            lines.append("Scanning the destination")
            return lines
        case .planned(let plan):
            var lines = ["Already backed up: \(plan.alreadyBackedUp.formatted()) photos"]
            if !plan.notFound.isEmpty {
                lines.append("Not in the library: \(plan.notFound.joined(separator: ", "))")
            }
            if plan.missingCount == 0 {
                lines.append("All photos are backed up")
            } else {
                lines.append("To back up: \(plan.localCount.formatted()) local (\(bytes(plan.localBytes))), \(plan.cloudCount.formatted()) cloud-only (\(bytes(plan.cloudBytes)))")
            }
            return lines
        case .stageStarted(let stage, let count, let size):
            let action = stage == .copyingLocal ? "Copying \(count.formatted()) local photos" : "Downloading \(count.formatted()) cloud-only photos"
            return ["\(action) (\(bytes(size)))"]
        case .progress, .assetSucceeded:
            return []
        case .assetFailed(let uuid, let reason):
            return ["Failed \(uuid): \(reason)"]
        case .signInRequired(let reason):
            return ["iCloud sign-in required (\(reason)). Photos that only the iCloud web API can get wait for a sign-in."]
        case .finished(let summary):
            if summary.dryRun { return ["Dry run: nothing copied or downloaded"] }
            var lines = [
                "Copied: \(summary.copied.formatted()) (\(bytes(summary.copiedBytes)))",
                "Downloaded: \(summary.downloaded.formatted()) (\(bytes(summary.downloadedBytes))), PhotoKit \(summary.viaPhotoKit.formatted()), iCloud \(summary.viaICloud.formatted())",
            ]
            if summary.failed > 0 {
                lines.append("Failed: \(summary.localFailed.formatted()) local, \(summary.cloudFailed.formatted()) cloud")
            }
            if summary.waitingForSignIn > 0 {
                lines.append("Waiting for iCloud sign-in: \(summary.waitingForSignIn.formatted())")
            }
            return lines
        }
    }

    private static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }
}
