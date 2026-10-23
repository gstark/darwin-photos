import Foundation

/// An exclusive lock on ~/.shoebox/run.lock. The app and the CLI take
/// it before a backup, so two backups never run at the same time. The
/// operating system releases the lock when the process ends.
public final class RunLock: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case busy
        case cannotOpen(String, Int32)

        public var description: String {
            switch self {
            case .busy: "another backup is already running"
            case .cannotOpen(let path, let code): "cannot open \(path): \(String(cString: strerror(code)))"
            }
        }
    }

    private let descriptor: Int32

    /// Takes the lock, or throws `Failure.busy` at once if another process holds it.
    public init(path: URL = ShoeboxPaths.runLock) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let filePath = path.path(percentEncoded: false)
        let fd = open(filePath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.cannotOpen(filePath, errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw Failure.busy
        }
        descriptor = fd
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
