import Foundation
import GRDB

/// A persistent record of assets that could not be backed up. Backups skip
/// these assets unless asked to retry them. Ported from internal/failures;
/// the schema and the timestamp format are the same, so the Go tool can read
/// the file.
public final class FailureStore: Sendable {
    public enum Category: String, Sendable {
        /// The original file was not found locally.
        case local
        /// The asset could not be downloaded from iCloud.
        case cloud
    }

    public struct Record: Sendable, Equatable {
        public var uuid: String
        public var category: Category
        public var reason: String
        public var attempts: Int
        public var firstFailedAt: Date
        public var lastFailedAt: Date
    }

    private let database: DatabaseQueue

    /// Opens the store, and creates the file and the schema if necessary.
    public init(path: URL = ShoeboxPaths.failures) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        database = try DatabaseQueue(path: path.path(percentEncoded: false), configuration: configuration)
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS failures (
                    uuid            TEXT PRIMARY KEY,
                    category        TEXT NOT NULL,
                    reason          TEXT,
                    attempts        INTEGER NOT NULL DEFAULT 1,
                    first_failed_at TIMESTAMP NOT NULL,
                    last_failed_at  TIMESTAMP NOT NULL
                )
                """)
        }
    }

    public func failedUUIDs() throws -> Set<String> {
        try database.read { db in
            Set(try String.fetchAll(db, sql: "SELECT uuid FROM failures"))
        }
    }

    /// Records a failure. For a known UUID, it increments the attempt count
    /// and updates the category, the reason, and the last failure time.
    public func fail(_ uuid: String, category: Category, reason: String, at date: Date = Date()) throws {
        let now = Self.format(date)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO failures (uuid, category, reason, attempts, first_failed_at, last_failed_at)
                    VALUES (?, ?, ?, 1, ?, ?)
                    ON CONFLICT(uuid) DO UPDATE SET
                        category       = excluded.category,
                        reason         = excluded.reason,
                        attempts       = attempts + 1,
                        last_failed_at = excluded.last_failed_at
                    """,
                arguments: [uuid, category.rawValue, reason, now, now]
            )
        }
    }

    public func clear(_ uuid: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM failures WHERE uuid = ?", arguments: [uuid])
        }
    }

    /// Removes every record and returns the number removed.
    @discardableResult
    public func clearAll() throws -> Int {
        try database.write { db in
            try db.execute(sql: "DELETE FROM failures")
            return db.changesCount
        }
    }

    /// Removes the records of assets that are no longer in the library, and
    /// returns the number removed.
    @discardableResult
    public func prune(keeping libraryUUIDs: Set<String>) throws -> Int {
        let stale = try failedUUIDs().subtracting(libraryUUIDs)
        guard !stale.isEmpty else { return 0 }
        try database.write { db in
            for uuid in stale {
                try db.execute(sql: "DELETE FROM failures WHERE uuid = ?", arguments: [uuid])
            }
        }
        return stale.count
    }

    /// All records, most recent failure first. A category limits the list.
    public func list(category: Category? = nil) throws -> [Record] {
        try database.read { db in
            var sql = "SELECT uuid, category, reason, attempts, first_failed_at, last_failed_at FROM failures"
            var arguments = StatementArguments()
            if let category {
                sql += " WHERE category = ?"
                arguments += [category.rawValue]
            }
            sql += " ORDER BY last_failed_at DESC"
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                Record(
                    uuid: try row.decode(atIndex: 0),
                    category: Category(rawValue: try row.decode(atIndex: 1)) ?? .local,
                    reason: try row.decode(String?.self, atIndex: 2) ?? "",
                    attempts: try row.decode(atIndex: 3),
                    firstFailedAt: Self.parse(try row.decode(atIndex: 4)) ?? .distantPast,
                    lastFailedAt: Self.parse(try row.decode(atIndex: 5)) ?? .distantPast
                )
            }
        }
    }

    // MARK: Timestamps

    // The Go SQLite driver writes `2006-01-02 15:04:05.999999999-07:00`.

    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
        return formatter.string(from: date) + "+00:00"
    }

    static func parse(_ text: String) -> Date? {
        let pattern = /^(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})?$/
        guard let match = text.wholeMatch(of: pattern) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard var date = formatter.date(from: match.1.replacingOccurrences(of: "T", with: " ")) else { return nil }
        if let fraction = match.2 {
            date += Double("0." + fraction) ?? 0
        }
        if let zone = match.3, zone != "Z" {
            let sign: Double = zone.hasPrefix("-") ? -1 : 1
            let hours = Double(zone.dropFirst().prefix(2)) ?? 0
            let minutes = Double(zone.suffix(2)) ?? 0
            date -= sign * (hours * 3600 + minutes * 60)
        }
        return date
    }
}
