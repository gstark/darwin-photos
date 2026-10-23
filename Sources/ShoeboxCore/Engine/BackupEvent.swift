import Foundation

/// What a backup run will do, after the scan.
public struct BackupPlan: Sendable, Equatable {
    /// Assets in the library that match the filters.
    public var libraryCount = 0
    /// Requested UUIDs that are not in the library. Only `onlyUUIDs` sets this.
    public var notFound: [String] = []
    /// Assets that were skipped because they failed before.
    public var skippedFailed = 0
    /// Assets that are already at the destination.
    public var alreadyBackedUp = 0
    public var localCount = 0
    public var localBytes: Int64 = 0
    public var cloudCount = 0
    public var cloudBytes: Int64 = 0

    public var missingCount: Int { localCount + cloudCount }
    public var missingBytes: Int64 { localBytes + cloudBytes }

    public init() {}
}

/// The two stages of a run. Local copies come first, as in the Go tool.
public enum BackupStage: Sendable, Equatable {
    case copyingLocal
    case downloadingCloud
}

/// Where the stored file came from.
public enum AssetSource: Sendable, Equatable {
    case local
    case photoKit
    case iCloud
}

public struct BackupSummary: Sendable, Equatable {
    public var copied = 0
    public var copiedBytes: Int64 = 0
    public var downloaded = 0
    public var downloadedBytes: Int64 = 0
    public var viaPhotoKit = 0
    public var viaICloud = 0
    public var localFailed = 0
    public var cloudFailed = 0
    /// Cloud-only assets that only the iCloud web API can get, while there is
    /// no valid session. They are not recorded as failures.
    public var waitingForSignIn = 0
    public var dryRun = false

    public var failed: Int { localFailed + cloudFailed }

    public init() {}
}

public enum BackupEvent: Sendable, Equatable {
    case scanningLibrary
    case scanningDestination(libraryCount: Int, skippedFailed: Int)
    case planned(BackupPlan)
    case stageStarted(BackupStage, count: Int, bytes: Int64)
    /// Progress in the current stage.
    case progress(done: Int, total: Int, bytesDone: Int64, bytesTotal: Int64)
    case assetSucceeded(uuid: String, source: AssetSource)
    case assetFailed(uuid: String, reason: String)
    /// The first asset that needs an iCloud sign-in. Sent once per run.
    case signInRequired(reason: String)
    case finished(BackupSummary)
}
