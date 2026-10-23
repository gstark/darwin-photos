import Foundation

/// One finished backup run.
public struct RunRecord: Codable, Sendable, Equatable {
    public enum Outcome: Codable, Sendable, Equatable {
        case succeeded
        case cancelled
        case failed(String)
    }

    public enum Trigger: String, Codable, Sendable {
        /// Back Up Now in the app.
        case manual
        case scheduled
        /// `shoebox backup`.
        case cli
    }

    public var startedAt: Date
    public var finishedAt: Date
    public var trigger: Trigger
    public var outcome: Outcome
    /// Photos copied or downloaded to the destination.
    public var stored = 0
    public var failed = 0
    public var waitingForSignIn = 0
    // Records from before the History window do not have these.
    public var copied: Int?
    public var downloaded: Int?
    public var bytesStored: Int64?
    /// The folder or S3 URI.
    public var destination: String?

    public init(startedAt: Date, finishedAt: Date = Date(), trigger: Trigger, outcome: Outcome, destination: String? = nil) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.trigger = trigger
        self.outcome = outcome
        self.destination = destination
    }

    public init(startedAt: Date, finishedAt: Date = Date(), trigger: Trigger, summary: BackupSummary, destination: String? = nil) {
        self.init(startedAt: startedAt, finishedAt: finishedAt, trigger: trigger, outcome: .succeeded, destination: destination)
        stored = summary.copied + summary.downloaded
        failed = summary.failed
        waitingForSignIn = summary.waitingForSignIn
        copied = summary.copied
        downloaded = summary.downloaded
        bytesStored = summary.copiedBytes + summary.downloadedBytes
    }

    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

/// The recent runs of the app and the CLI, in ~/.shoebox/history.json,
/// and their logs in the logs folder next to it. The scheduler reads the last success
/// from it, so a backup with the CLI also counts.
public struct RunHistory: Sendable {
    public static let limit = 100

    public let url: URL
    public let logs: URL

    public init(url: URL = ShoeboxPaths.history) {
        self.url = url
        logs = url.deletingLastPathComponent().appending(path: "logs")
    }

    /// Opens the log of a run that starts now. Nil when the file cannot be
    /// made. The run continues without a log.
    public func startLog(startedAt: Date, trigger: RunRecord.Trigger, destination: String?) -> RunLog? {
        let log = try? RunLog(url: logURL(startedAt: startedAt))
        log?.write("Backup started (\(trigger.rawValue))", at: startedAt)
        if let destination {
            log?.write("Destination: \(destination)", at: startedAt)
        }
        return log
    }

    /// The text of the run's log. Nil when the run has no log.
    public func log(for record: RunRecord) -> String? {
        try? String(contentsOf: logURL(startedAt: record.startedAt), encoding: .utf8)
    }

    /// history.json keeps whole seconds, so the name does too.
    func logURL(startedAt: Date) -> URL {
        let name = startedAt.formatted(Date.ISO8601FormatStyle(timeSeparator: .omitted))
        return logs.appending(path: "\(name).log")
    }

    /// Oldest first. A missing or unreadable file gives an empty history.
    public func records() -> [RunRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.decoder.decode([RunRecord].self, from: data)) ?? []
    }

    public var last: RunRecord? { records().last }

    public var lastSuccess: RunRecord? {
        records().last { $0.outcome == .succeeded }
    }

    /// Adds a record and keeps the newest `limit` records.
    public func append(_ record: RunRecord) throws {
        let records = Array((records() + [record]).suffix(Self.limit))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.encoder.encode(records).write(to: url, options: .atomic)
        pruneLogs(keeping: records)
    }

    /// Deletes the logs of runs that are no longer in the history.
    private func pruneLogs(keeping records: [RunRecord]) {
        let kept = Set(records.map { logURL(startedAt: $0.startedAt).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "log" && !kept.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension ShoeboxPaths {
    public static let history = directory.appending(path: "history.json")
}
