import Foundation

/// Where backups go: a local folder now, S3 in Phase 4.
public protocol BackupDestination: Sendable {
    /// A description for messages, such as the folder path or the S3 URL.
    var displayName: String { get }

    /// The names of the files that are already backed up.
    func existingNames() async throws -> Set<String>

    /// Free space in bytes, or nil if the destination has no limit.
    func availableCapacity() throws -> Int64?

    /// Stores a copy of `file` under `name`. The source file is not changed.
    func store(file: URL, name: String, asset: Asset) async throws
}

extension Asset {
    /// The backup file name: `<UUID>.<ext of ZFILENAME>`, or `<UUID>.jpg` if
    /// the file name has no extension. Existing backups depend on this name.
    public var backupFilename: String {
        let ext = (filename as NSString).pathExtension
        return uuid + "." + (ext.isEmpty ? "jpg" : ext)
    }

    /// The time to set on a backup file: the modification date, or the
    /// creation date if there is no modification date.
    public var backupModificationDate: Date? {
        (dateModified ?? dateCreated)?.date
    }
}
