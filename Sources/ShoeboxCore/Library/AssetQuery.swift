import Foundation
import GRDB

/// Options for `PhotosLibrary.listAssets`.
public struct ListOptions: Sendable {
    public enum Sort: String, Sendable, CaseIterable {
        case date, name, size
    }

    public var limit = 0
    public var offset = 0
    public var localOnly = false
    public var cloudOnly = false
    public var photosOnly = false
    public var videosOnly = false
    public var includeTrashed = false
    public var sort = Sort.date
    public var descending = false
    /// Include assets created on or after this date.
    public var startDate: CoreDataDate?
    /// Include assets created on or before the end of this day.
    public var endDate: CoreDataDate?
    /// Exact, case-sensitive album title.
    public var albumName: String?
    /// Leave out iCloud shared album assets. Backups set this.
    public var excludeSharedAlbumAssets = false
    /// Leave out assets saved from Messages (`ZSAVEDASSETTYPE = 12`). Their
    /// originals are only in the Shared with You library, and that library
    /// has no local files. Backups set this.
    public var excludeMessagesAssets = false

    public init() {}
}

/// SQL for asset queries, ported from internal/db/assets.go.
enum AssetSQL {
    /// Original resources of the asset. The original of a photo is type 0.
    /// The original of a video is type 1; its type 0 rows are small stills.
    /// The largest original with a fingerprint is the current original.
    static let latestOriginalPredicate = """
        r.ZASSET = a.Z_PK AND r.ZRESOURCETYPE = (CASE WHEN a.ZKIND = 1 THEN 1 ELSE 0 END) \
        AND r.ZFINGERPRINT IS NOT NULL AND r.ZFINGERPRINT != ''
        """

    static let latestOriginalLocalAvailability =
        "(SELECT r.ZLOCALAVAILABILITY FROM ZINTERNALRESOURCE r WHERE \(latestOriginalPredicate) ORDER BY r.ZDATALENGTH DESC LIMIT 1)"

    static let latestOriginalDataLength =
        "(SELECT r.ZDATALENGTH FROM ZINTERNALRESOURCE r WHERE \(latestOriginalPredicate) ORDER BY r.ZDATALENGTH DESC LIMIT 1)"

    static let projection = """
         a.Z_PK, a.ZUUID, a.ZFILENAME, a.ZDIRECTORY, a.ZWIDTH, a.ZHEIGHT, a.ZKIND,
         a.ZUNIFORMTYPEIDENTIFIER, a.ZFAVORITE, a.ZHIDDEN, a.ZTRASHEDSTATE, a.ZCLOUDLOCALSTATE,
         CAST(a.ZDATECREATED AS REAL), CAST(a.ZMODIFICATIONDATE AS REAL),
         a.ZLATITUDE, a.ZLONGITUDE, a.ZDURATION,
         aa.ZORIGINALFILENAME, aa.ZORIGINALFILESIZE,
         \(latestOriginalLocalAvailability) AS local_avail,
         \(latestOriginalDataLength) AS data_length

        """

    static let baseFrom = """
        FROM ZASSET a
        LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON a.ZADDITIONALATTRIBUTES = aa.Z_PK

        """

    /// Builds the joins and the WHERE clause. The list query and the count
    /// query use the same filters.
    struct Filter {
        let options: ListOptions
        /// The N in the Z_<N>ASSETS album relation table.
        let albumRelation: Int?

        var joins: String {
            guard options.albumName != nil, let n = albumRelation else { return "" }
            return """
                JOIN Z_\(n)ASSETS rel ON a.Z_PK = rel.Z_3ASSETS
                JOIN ZGENERICALBUM alb ON rel.Z_\(n)ALBUMS = alb.Z_PK

                """
        }

        var whereClause: (sql: String, arguments: StatementArguments) {
            var clauses: [String] = []
            var arguments = StatementArguments()

            if let album = options.albumName {
                clauses += ["alb.ZTITLE = ?", "alb.ZKIND = 2"]
                arguments += [album]
            }
            if !options.includeTrashed {
                clauses.append("(a.ZTRASHEDSTATE = 0 OR a.ZTRASHEDSTATE IS NULL)")
            }
            if options.excludeSharedAlbumAssets {
                clauses.append("a.ZCOLLECTIONSHARE IS NULL")
            }
            if options.excludeMessagesAssets {
                clauses.append("a.ZSAVEDASSETTYPE IS NOT 12")
            }
            if options.localOnly {
                clauses.append("\(latestOriginalLocalAvailability) = 1")
            } else if options.cloudOnly {
                clauses.append("\(latestOriginalLocalAvailability) = -1")
            }
            if options.photosOnly {
                clauses.append("a.ZKIND = 0")
            } else if options.videosOnly {
                clauses.append("a.ZKIND = 1")
            }
            if let start = options.startDate {
                clauses.append("a.ZDATECREATED >= ?")
                arguments += [start.timestamp]
            }
            if let end = options.endDate {
                clauses.append("a.ZDATECREATED <= ?")
                arguments += [end.timestamp + 86_400 - 1]
            }

            if clauses.isEmpty {
                return ("WHERE 1=1", arguments)
            }
            return ("WHERE " + clauses.joined(separator: " AND "), arguments)
        }

        var orderBy: String {
            let column = switch options.sort {
            case .date: "a.ZDATECREATED"
            case .name: "COALESCE(aa.ZORIGINALFILENAME, a.ZFILENAME)"
            case .size: "data_length"
            }
            return " ORDER BY \(column) \(options.descending ? "DESC" : "ASC")"
        }
    }
}
