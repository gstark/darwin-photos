import Foundation
import GRDB

/// A small Photos library with only the tables and columns that
/// PhotosLibrary reads. It contains no personal data.
struct FixtureLibrary {
    let path: String

    /// Seconds since 2001-01-01 for 2024-03-10 12:00:00 UTC.
    static let march10 = 731_764_800.0

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "shoebox-tests-\(UUID().uuidString)/Fixture.photoslibrary")
        try FileManager.default.createDirectory(at: root.appending(path: "database"), withIntermediateDirectories: true)
        path = root.path(percentEncoded: false)

        // The original file of the local photo.
        let originals = root.appending(path: "originals/L")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try Data("local photo bytes".utf8).write(to: originals.appending(path: "LOCAL-PHOTO.heic"))

        let queue = try DatabaseQueue(path: root.appending(path: "database/Photos.sqlite").path(percentEncoded: false))
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE ZASSET (
                    Z_PK INTEGER PRIMARY KEY, ZUUID VARCHAR, ZFILENAME VARCHAR, ZDIRECTORY VARCHAR,
                    ZWIDTH INTEGER, ZHEIGHT INTEGER, ZKIND INTEGER, ZUNIFORMTYPEIDENTIFIER VARCHAR,
                    ZFAVORITE INTEGER, ZHIDDEN INTEGER, ZTRASHEDSTATE INTEGER, ZCLOUDLOCALSTATE INTEGER,
                    ZDATECREATED TIMESTAMP, ZMODIFICATIONDATE TIMESTAMP, ZLATITUDE FLOAT, ZLONGITUDE FLOAT,
                    ZDURATION FLOAT, ZADDITIONALATTRIBUTES INTEGER, ZEXTENDEDATTRIBUTES INTEGER,
                    ZCOLLECTIONSHARE INTEGER, ZMASTER INTEGER, ZSAVEDASSETTYPE INTEGER
                );
                CREATE TABLE ZCLOUDMASTER (Z_PK INTEGER PRIMARY KEY, ZCLOUDMASTERGUID VARCHAR);
                CREATE TABLE ZADDITIONALASSETATTRIBUTES (Z_PK INTEGER PRIMARY KEY, ZORIGINALFILENAME VARCHAR, ZORIGINALFILESIZE INTEGER);
                CREATE TABLE ZINTERNALRESOURCE (
                    Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZRESOURCETYPE INTEGER, ZFINGERPRINT VARCHAR,
                    ZDATALENGTH INTEGER, ZLOCALAVAILABILITY INTEGER
                );
                CREATE TABLE ZEXTENDEDATTRIBUTES (
                    Z_PK INTEGER PRIMARY KEY, ZCAMERAMAKE VARCHAR, ZCAMERAMODEL VARCHAR, ZLENSMODEL VARCHAR,
                    ZISO INTEGER, ZAPERTURE FLOAT, ZSHUTTERSPEED FLOAT, ZFOCALLENGTH FLOAT
                );
                CREATE TABLE ZGENERICALBUM (Z_PK INTEGER PRIMARY KEY, ZUUID VARCHAR, ZTITLE VARCHAR, ZKIND INTEGER);
                CREATE TABLE Z_30ASSETS (Z_30ALBUMS INTEGER, Z_3ASSETS INTEGER);
                """)

            let day = 86_400.0
            // pk, uuid, filename, kind, created, trashed, shared, hidden, duration
            let assets: [(Int, String, String, Int, Double, Int, Int?, Int, Double)] = [
                (1, "LOCAL-PHOTO", "LOCAL-PHOTO.heic", 0, Self.march10 + 0.5, 0, nil, 0, 0),
                (2, "CLOUD-VIDEO", "CLOUD-VIDEO.mov", 1, Self.march10 + day, 0, nil, 0, 12.5),
                (3, "TRASHED-PHOTO", "TRASHED-PHOTO.jpg", 0, Self.march10 + 2 * day, 1, nil, 0, 0),
                (4, "SHARED-PHOTO", "SHARED-PHOTO.jpg", 0, Self.march10 + 3 * day, 0, 7, 0, 0),
                (5, "NO-RESOURCE", "NO-RESOURCE.png", 0, Self.march10 - day, 0, nil, 1, 0),
                // Saved from Messages. Its original is in the Shared with You library.
                (6, "MESSAGES-PHOTO", "MESSAGES-PHOTO.heic", 0, Self.march10 + 4 * day, 0, nil, 0, 0),
            ]
            for (pk, uuid, filename, kind, created, trashed, shared, hidden, duration) in assets {
                try db.execute(
                    sql: """
                        INSERT INTO ZASSET VALUES (?, ?, ?, ?, 4032, 3024, ?, 'public.heic', ?, ?, ?, 0, ?, ?, 45.5, -122.5, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [pk, uuid, filename, String(uuid.prefix(1)), kind, pk == 1 ? 1 : 0, hidden, trashed,
                                created, created + 60, duration, pk, pk == 1 ? 1 : nil, shared, pk <= 2 ? 100 + pk : nil, pk == 6 ? 12 : 3]
                )
                try db.execute(
                    sql: "INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES (?, ?, ?)",
                    arguments: [pk, "IMG_000\(pk).\(filename.split(separator: ".").last!.uppercased())", 1_000 * pk]
                )
            }

            // pk, asset, type, fingerprint, length, availability
            let resources: [(Int, Int, Int, String?, Int, Int)] = [
                (1, 1, 0, "fp-old", 1_000_000, 1),
                (2, 1, 0, "fp-new", 2_000_000, 1),
                (3, 1, 3, "fp-preview", 4_000_000, -1),
                // The video original is type 1. Its type 0 row is a local still.
                (4, 2, 1, "fp-video", 50_000_000, -1),
                (8, 2, 1, "fp-video-medium", 10_000_000, -1),
                (9, 2, 0, "fp-video-still", 300_000, 1),
                (5, 3, 0, "fp-trashed", 3_000_000, 1),
                (6, 4, 0, "fp-shared", 500_000, 1),
                (7, 1, 0, nil, 9_000_000, 1),
            ]
            for (pk, asset, type, fingerprint, length, availability) in resources {
                try db.execute(
                    sql: "INSERT INTO ZINTERNALRESOURCE VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [pk, asset, type, fingerprint, length, availability]
                )
            }

            // The video has a cloud master. The other assets use the fingerprint.
            try db.execute(sql: "INSERT INTO ZCLOUDMASTER VALUES (101, NULL), (102, 'MASTER-VIDEO')")
            try db.execute(sql: "INSERT INTO ZEXTENDEDATTRIBUTES VALUES (1, 'Apple', 'iPhone 15 Pro', 'Main Camera', 100, 1.78, 0.008, 6.86)")
            try db.execute(sql: """
                INSERT INTO ZGENERICALBUM VALUES (10, 'ALBUM-TRIP', 'Trip', 2), (11, 'ALBUM-SMART', 'Smart', 1), (12, 'ALBUM-ART', 'Art', 2);
                INSERT INTO Z_30ASSETS VALUES (10, 1), (10, 2), (11, 1);
                """)
        }
    }
}
