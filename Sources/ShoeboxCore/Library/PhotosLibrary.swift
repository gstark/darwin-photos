import Foundation
import GRDB

public enum PhotosLibraryError: Error, CustomStringConvertible {
    case databaseNotFound(String)
    case assetNotFound(String)
    case albumTableNotFound
    case accessDenied(String)

    public var description: String {
        switch self {
        case .databaseNotFound(let path): "Photos database not found at \(path)"
        case .accessDenied(let path): "cannot read \(path). Grant Full Disk Access to this app or terminal"
        case .assetNotFound(let id): "asset not found: \(id)"
        case .albumTableNotFound: "album relationship table not found in database"
        }
    }
}

/// Aggregate statistics for the library. Trashed assets are not counted.
public struct LibraryStats: Sendable, Equatable {
    public var totalCount = 0
    /// All resources: originals and derivatives.
    public var totalSize: Int64 = 0
    /// Original resources only: type 0 for photos, type 1 for videos.
    public var originalSize: Int64 = 0
    /// Large JPEG previews of cloud-only photos. They are not in iCloud.
    public var localCacheSize: Int64 = 0
    public var localCount = 0
    public var localSize: Int64 = 0
    public var cloudCount = 0
    public var cloudSize: Int64 = 0
    public var photoCount = 0
    public var photoSize: Int64 = 0
    public var videoCount = 0
    public var videoSize: Int64 = 0

    public var derivativeSize: Int64 { totalSize - originalSize }
    /// The estimate of what counts toward the iCloud quota.
    public var iCloudStorage: Int64 { totalSize - localCacheSize }
    public var cloudDerivatives: Int64 { iCloudStorage - originalSize }
}

/// Read-only access to Photos.sqlite. Ported from internal/db.
public final class PhotosLibrary: Sendable {
    public static let defaultPath = URL.homeDirectory
        .appending(path: "Pictures/Photos Library.photoslibrary")
        .path(percentEncoded: false)

    public let libraryPath: String
    private let database: DatabaseQueue
    /// Set only when the database had to be copied.
    private let tempDirectory: URL?

    /// Opens the database read-only and immutable, in place. If that fails,
    /// copies the database to a temporary directory and opens the copy.
    public init(libraryPath: String = PhotosLibrary.defaultPath) throws {
        self.libraryPath = libraryPath
        let source = URL(filePath: libraryPath).appending(path: "database/Photos.sqlite")
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
            throw PhotosLibraryError.databaseNotFound(source.path(percentEncoded: false))
        }

        var configuration = Configuration()
        configuration.readonly = true

        if let queue = try? DatabaseQueue(path: source.absoluteString + "?mode=ro&immutable=1", configuration: configuration),
           (try? queue.read({ try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlite_master") })) != nil {
            database = queue
            tempDirectory = nil
            return
        }

        let temp = FileManager.default.temporaryDirectory.appending(path: "shoebox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        do {
            let copy = temp.appending(path: "Photos.sqlite")
            try FileManager.default.copyItem(at: source, to: copy)
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.copyItem(
                    at: URL(filePath: source.path(percentEncoded: false) + suffix),
                    to: URL(filePath: copy.path(percentEncoded: false) + suffix)
                )
            }
            database = try DatabaseQueue(path: copy.path(percentEncoded: false), configuration: configuration)
            tempDirectory = temp
        } catch {
            try? FileManager.default.removeItem(at: temp)
            // Without Full Disk Access, macOS returns EPERM for files in the library.
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            if underlying?.domain == NSPOSIXErrorDomain, [EPERM, EACCES].contains(Int32(underlying?.code ?? 0)) {
                throw PhotosLibraryError.accessDenied(source.path(percentEncoded: false))
            }
            throw error
        }
    }

    deinit {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    // MARK: Assets

    /// Returns one page of assets and the total count that matches the filters.
    public func listAssets(_ options: ListOptions) throws -> (assets: [Asset], total: Int) {
        try database.read { db in
            var relation: Int?
            if options.albumName != nil {
                guard let n = try Self.albumRelationNumber(db) else { throw PhotosLibraryError.albumTableNotFound }
                relation = n
            }
            let filter = AssetSQL.Filter(options: options, albumRelation: relation)
            let (whereSQL, arguments) = filter.whereClause

            var sql = "SELECT" + AssetSQL.projection + AssetSQL.baseFrom + filter.joins + whereSQL + filter.orderBy
            var pageArguments = arguments
            if options.limit > 0 {
                sql += " LIMIT ?"
                pageArguments += [options.limit]
            }
            if options.offset > 0 {
                // SQLite needs a LIMIT before OFFSET. -1 means no limit.
                if options.limit <= 0 { sql += " LIMIT -1" }
                sql += " OFFSET ?"
                pageArguments += [options.offset]
            }

            let assets = try Row.fetchAll(db, sql: sql, arguments: pageArguments).map(Self.asset(from:))
            let countSQL = "SELECT COUNT(*) " + AssetSQL.baseFrom + filter.joins + whereSQL
            let total = try Int.fetchOne(db, sql: countSQL, arguments: arguments) ?? 0
            return (assets, total)
        }
    }

    public func asset(uuid: String) throws -> Asset {
        try database.read { db in
            let sql = "SELECT" + AssetSQL.projection + AssetSQL.baseFrom + "WHERE a.ZUUID = ? LIMIT 1"
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [uuid]) else {
                throw PhotosLibraryError.assetNotFound(uuid)
            }
            return try Self.asset(from: row)
        }
    }

    /// Returns nil when the asset has no EXIF record.
    public func extendedAttributes(assetPK: Int64) throws -> ExtendedAttributes? {
        try database.read { db in
            let sql = """
                SELECT e.ZCAMERAMAKE, e.ZCAMERAMODEL, e.ZLENSMODEL, e.ZISO, e.ZAPERTURE, e.ZSHUTTERSPEED, e.ZFOCALLENGTH
                FROM ZASSET a
                JOIN ZEXTENDEDATTRIBUTES e ON a.ZEXTENDEDATTRIBUTES = e.Z_PK
                WHERE a.Z_PK = ?
                """
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [assetPK]) else { return nil }
            return ExtendedAttributes(
                cameraMake: try row.decode(String?.self, atIndex: 0) ?? "",
                cameraModel: try row.decode(String?.self, atIndex: 1) ?? "",
                lensModel: try row.decode(String?.self, atIndex: 2) ?? "",
                iso: try row.decode(Int?.self, atIndex: 3) ?? 0,
                aperture: try row.decode(Double?.self, atIndex: 4) ?? 0,
                shutterSpeed: try row.decode(Double?.self, atIndex: 5) ?? 0,
                focalLength: try row.decode(Double?.self, atIndex: 6) ?? 0
            )
        }
    }

    /// The UUID of every asset in the library, trashed assets included.
    public func allAssetUUIDs() throws -> Set<String> {
        try database.read { db in
            Set(try String.fetchAll(db, sql: "SELECT ZUUID FROM ZASSET WHERE ZUUID IS NOT NULL"))
        }
    }

    /// The CloudKit record that holds the original of the asset, or nil if
    /// the library has no record name for it. Ported from
    /// `GetCloudDownloadRecords`: the cloud master GUID comes first. Without
    /// a master, the fingerprint of the original resource is the record name.
    public func cloudRecord(uuid: String) throws -> CloudRecord? {
        try database.read { db in
            let sql = """
                SELECT cm.ZCLOUDMASTERGUID,
                    (SELECT r.ZFINGERPRINT FROM ZINTERNALRESOURCE r
                     WHERE \(AssetSQL.latestOriginalPredicate)
                     ORDER BY r.ZDATALENGTH DESC LIMIT 1)
                FROM ZASSET a
                LEFT JOIN ZCLOUDMASTER cm ON a.ZMASTER = cm.Z_PK
                WHERE a.ZUUID = ?
                LIMIT 1
                """
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [uuid]) else { return nil }
            if let master = try row.decode(String?.self, atIndex: 0), !master.isEmpty {
                return CloudRecord(recordName: master, searchAllZones: false)
            }
            if let fingerprint = try row.decode(String?.self, atIndex: 1), !fingerprint.isEmpty {
                return CloudRecord(recordName: fingerprint, searchAllZones: true)
            }
            return nil
        }
    }

    // MARK: Albums

    /// User albums that contain the asset.
    public func albums(assetPK: Int64) throws -> [Album] {
        try database.read { db in
            guard let n = try Self.albumRelationNumber(db) else { return [] }
            let sql = """
                SELECT alb.Z_PK, alb.ZUUID, alb.ZTITLE
                FROM ZGENERICALBUM alb
                JOIN Z_\(n)ASSETS rel ON alb.Z_PK = rel.Z_\(n)ALBUMS
                WHERE rel.Z_3ASSETS = ?
                  AND alb.ZKIND = 2
                  AND alb.ZTITLE IS NOT NULL
                """
            return try Row.fetchAll(db, sql: sql, arguments: [assetPK]).map(Self.album(from:))
        }
    }

    /// All user albums, sorted by title.
    public func albums() throws -> [Album] {
        try database.read { db in
            let sql = """
                SELECT Z_PK, ZUUID, ZTITLE
                FROM ZGENERICALBUM
                WHERE ZKIND = 2 AND ZTITLE IS NOT NULL
                ORDER BY ZTITLE
                """
            return try Row.fetchAll(db, sql: sql).map(Self.album(from:))
        }
    }

    // MARK: Stats

    public func stats() throws -> LibraryStats {
        try database.read { db in
            let sql = """
                SELECT
                    COALESCE((SELECT r.ZLOCALAVAILABILITY FROM ZINTERNALRESOURCE r
                     WHERE \(AssetSQL.latestOriginalPredicate)
                     ORDER BY r.ZDATALENGTH DESC LIMIT 1), 0) AS local_avail,
                    a.ZKIND,
                    COUNT(*) AS cnt,
                    COALESCE(SUM(COALESCE(
                        (SELECT SUM(r.ZDATALENGTH) FROM ZINTERNALRESOURCE r
                         WHERE r.ZASSET = a.Z_PK AND r.ZFINGERPRINT IS NOT NULL AND r.ZFINGERPRINT != ''),
                        aa.ZORIGINALFILESIZE, 0)), 0) AS total_size,
                    COALESCE(SUM(COALESCE(
                        (SELECT SUM(r.ZDATALENGTH) FROM ZINTERNALRESOURCE r
                         WHERE \(AssetSQL.latestOriginalPredicate)),
                        aa.ZORIGINALFILESIZE, 0)), 0) AS original_size
                FROM ZASSET a
                LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON a.ZADDITIONALATTRIBUTES = aa.Z_PK
                WHERE (a.ZTRASHEDSTATE = 0 OR a.ZTRASHEDSTATE IS NULL)
                GROUP BY local_avail, a.ZKIND
                """
            var stats = LibraryStats()
            for row in try Row.fetchAll(db, sql: sql) {
                let localAvailability = try row.decode(Int?.self, atIndex: 0) ?? 0
                let kind = try row.decode(Int?.self, atIndex: 1) ?? 0
                let count = try row.decode(Int.self, atIndex: 2)
                let size = try row.decode(Int64.self, atIndex: 3)
                let originalSize = try row.decode(Int64.self, atIndex: 4)

                stats.totalCount += count
                stats.totalSize += size
                stats.originalSize += originalSize
                if localAvailability == LocalAvailability.local.rawValue {
                    stats.localCount += count
                    stats.localSize += size
                } else {
                    stats.cloudCount += count
                    stats.cloudSize += size
                }
                if kind == AssetKind.photo.rawValue {
                    stats.photoCount += count
                    stats.photoSize += size
                } else {
                    stats.videoCount += count
                    stats.videoSize += size
                }
            }

            // Type 3 resources of 3 MB or more are high-resolution previews of
            // cloud-only photos. They exist only on this Mac.
            let cacheSQL = """
                SELECT COALESCE(SUM(ZDATALENGTH), 0)
                FROM ZINTERNALRESOURCE
                WHERE ZRESOURCETYPE = 3
                  AND ZLOCALAVAILABILITY = -1
                  AND ZDATALENGTH >= 3145728
                  AND ZFINGERPRINT IS NOT NULL AND ZFINGERPRINT != ''
                """
            stats.localCacheSize = try Int64.fetchOne(db, sql: cacheSQL) ?? 0
            return stats
        }
    }

    // MARK: Row mapping

    /// The album relation table is Z_<N>ASSETS. N changes between macOS
    /// versions. Returns nil if the table does not exist.
    private static func albumRelationNumber(_ db: Database) throws -> Int? {
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name GLOB 'Z_[0-9]*ASSETS' LIMIT 1"
        guard let name = try String.fetchOne(db, sql: sql) else { return nil }
        return Int(name.dropFirst(2).dropLast(6))
    }

    /// Maps a row of `AssetSQL.projection`. GRDB throws, and does not
    /// crash, when a value does not convert.
    private static func asset(from row: Row) throws -> Asset {
        func value<T: DatabaseValueConvertible>(_ index: Int) throws -> T? {
            try row.decode(T?.self, atIndex: index)
        }
        let dataLength: Int64 = try value(20) ?? 0
        let originalFileSize: Int64 = try value(18) ?? 0
        let created: Double? = try value(12)
        let modified: Double? = try value(13)
        let favorite: Int? = try value(8)
        let hidden: Int? = try value(9)
        let trashed: Int? = try value(10)
        return Asset(
            pk: try row.decode(atIndex: 0),
            uuid: try value(1) ?? "",
            filename: try value(2) ?? "",
            directory: try value(3) ?? "",
            originalFilename: try value(17) ?? "",
            uniformTypeID: try value(7) ?? "",
            kind: AssetKind(rawValue: try value(6) ?? 0) ?? .photo,
            width: try value(4) ?? 0,
            height: try value(5) ?? 0,
            dateCreated: created.flatMap(CoreDataDate.init(timestamp:)),
            dateModified: modified.flatMap(CoreDataDate.init(timestamp:)),
            latitude: try value(14) ?? 0,
            longitude: try value(15) ?? 0,
            duration: try value(16) ?? 0,
            favorite: favorite == 1,
            hidden: hidden == 1,
            trashed: trashed.map { $0 != 0 } ?? false,
            cloudLocalState: try value(11) ?? 0,
            localAvailability: LocalAvailability(rawValue: try value(19) ?? 0) ?? .unknown,
            fileSize: dataLength != 0 ? dataLength : originalFileSize
        )
    }

    private static func album(from row: Row) throws -> Album {
        Album(
            pk: try row.decode(atIndex: 0),
            uuid: try row.decode(String?.self, atIndex: 1) ?? "",
            title: try row.decode(String?.self, atIndex: 2) ?? ""
        )
    }
}
