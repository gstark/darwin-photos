import Foundation

public enum LocalDestinationError: Error, CustomStringConvertible {
    case notFound(String)
    case notADirectory(String)

    public var description: String {
        switch self {
        case .notFound(let path): "output directory does not exist: \(path)"
        case .notADirectory(let path): "output path is not a directory: \(path)"
        }
    }
}

/// A backup folder on a local or external disk. All files are in the top
/// level of the folder.
public struct LocalDestination: BackupDestination {
    public let directory: URL

    public init(directory: URL) throws {
        let path = directory.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw LocalDestinationError.notFound(path)
        }
        guard isDirectory.boolValue else { throw LocalDestinationError.notADirectory(path) }
        self.directory = directory
    }

    public var displayName: String { directory.path(percentEncoded: false) }

    public func existingNames() async throws -> Set<String> {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        return Set(entries.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map(\.lastPathComponent))
    }

    public func availableCapacity() throws -> Int64? {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values.volumeAvailableCapacity.map(Int64.init)
    }

    /// Copies to a hidden temporary file, flushes it to the disk, sets the
    /// modification time, and then renames it. An interrupted copy therefore
    /// never leaves a partial file under the backup name.
    public func store(file: URL, name: String, asset: Asset) async throws {
        let target = directory.appending(path: name)
        let temp = directory.appending(path: ".\(name).partial")
        try? FileManager.default.removeItem(at: temp)
        do {
            try FileManager.default.copyItem(at: file, to: temp)
            try Self.flush(temp)
            if let date = asset.backupModificationDate {
                // Best effort, as in the Go tool: a valid copy must not fail
                // because of the time stamp.
                try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: temp.path(percentEncoded: false))
            }
            if rename(temp.path(percentEncoded: false), target.path(percentEncoded: false)) != 0 {
                throw CocoaError.error(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path(percentEncoded: false)])
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Writes the file to permanent storage, as Go's File.Sync does on macOS.
    private static func flush(_ url: URL) throws {
        let fd = open(url.path(percentEncoded: false), O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
