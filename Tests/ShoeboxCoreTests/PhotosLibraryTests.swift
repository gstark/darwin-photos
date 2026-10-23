import ShoeboxCore
import Testing

struct PhotosLibraryTests {
    let fixture: FixtureLibrary
    let library: PhotosLibrary

    init() throws {
        fixture = try FixtureLibrary()
        library = try PhotosLibrary(libraryPath: fixture.path)
    }

    private func uuids(_ configure: (inout ListOptions) -> Void = { _ in }) throws -> [String] {
        var options = ListOptions()
        configure(&options)
        return try library.listAssets(options).assets.map(\.uuid)
    }

    @Test func missingDatabaseThrows() {
        #expect(throws: PhotosLibraryError.self) {
            try PhotosLibrary(libraryPath: "/nonexistent/Library.photoslibrary")
        }
    }

    @Test func listExcludesTrashedByDefaultAndSortsByDateAscending() throws {
        #expect(try uuids() == ["NO-RESOURCE", "LOCAL-PHOTO", "CLOUD-VIDEO", "SHARED-PHOTO", "MESSAGES-PHOTO"])
        #expect(try uuids { $0.includeTrashed = true }.contains("TRASHED-PHOTO"))
    }

    @Test func listFilters() throws {
        #expect(try uuids { $0.localOnly = true } == ["LOCAL-PHOTO", "SHARED-PHOTO"])
        #expect(try uuids { $0.cloudOnly = true } == ["CLOUD-VIDEO"])
        #expect(try uuids { $0.videosOnly = true } == ["CLOUD-VIDEO"])
        #expect(try uuids { $0.photosOnly = true } == ["NO-RESOURCE", "LOCAL-PHOTO", "SHARED-PHOTO", "MESSAGES-PHOTO"])
        #expect(try uuids { $0.excludeSharedAlbumAssets = true } == ["NO-RESOURCE", "LOCAL-PHOTO", "CLOUD-VIDEO", "MESSAGES-PHOTO"])
        #expect(try uuids { $0.excludeMessagesAssets = true } == ["NO-RESOURCE", "LOCAL-PHOTO", "CLOUD-VIDEO", "SHARED-PHOTO"])
        #expect(try uuids { $0.albumName = "Trip" } == ["LOCAL-PHOTO", "CLOUD-VIDEO"])
        #expect(try uuids { $0.albumName = "Smart" }.isEmpty)
    }

    @Test func cloudRecordPrefersTheMasterThenTheOriginalFingerprint() throws {
        #expect(try library.cloudRecord(uuid: "CLOUD-VIDEO") == CloudRecord(recordName: "MASTER-VIDEO", searchAllZones: false))
        // The master has no GUID, so the largest original fingerprint is used.
        #expect(try library.cloudRecord(uuid: "LOCAL-PHOTO") == CloudRecord(recordName: "fp-new", searchAllZones: true))
        #expect(try library.cloudRecord(uuid: "NO-RESOURCE") == nil)
        #expect(try library.cloudRecord(uuid: "MISSING") == nil)
    }

    @Test func listDateRangeIncludesTheWholeEndDay() throws {
        let march10 = CoreDataDate(timestamp: FixtureLibrary.march10 - 12 * 3600)!
        let march11 = CoreDataDate(timestamp: FixtureLibrary.march10 + 12 * 3600)!
        #expect(try uuids { $0.startDate = march10; $0.endDate = march10 } == ["LOCAL-PHOTO"])
        #expect(try uuids { $0.startDate = march11 } == ["CLOUD-VIDEO", "SHARED-PHOTO", "MESSAGES-PHOTO"])
    }

    @Test func listSortAndPagination() throws {
        var options = ListOptions()
        options.sort = .size
        options.descending = true
        options.limit = 2
        options.offset = 1
        let (assets, total) = try library.listAssets(options)
        #expect(assets.map(\.uuid) == ["LOCAL-PHOTO", "SHARED-PHOTO"])
        #expect(total == 5)

        options.limit = 0
        #expect(try library.listAssets(options).assets.count == 4)
    }

    @Test func assetMapping() throws {
        let asset = try library.asset(uuid: "LOCAL-PHOTO")
        #expect(asset.pk == 1)
        #expect(asset.filename == "LOCAL-PHOTO.heic")
        #expect(asset.originalFilename == "IMG_0001.HEIC")
        #expect(asset.kind == .photo)
        #expect(asset.favorite)
        #expect(!asset.hidden)
        #expect(asset.localAvailability == .local)
        // The largest original with a fingerprint wins.
        #expect(asset.fileSize == 2_000_000)
        #expect(asset.dateCreated?.rfc3339Nano == "2024-03-10T12:00:00.5Z")
        #expect(asset.dateModified?.iso8601Seconds == "2024-03-10T12:01:00Z")
        #expect(asset.localPath(libraryPath: fixture.path) == fixture.path + "/originals/L/LOCAL-PHOTO.heic")
    }

    @Test func assetWithoutResourceUsesOriginalFileSize() throws {
        let asset = try library.asset(uuid: "NO-RESOURCE")
        #expect(asset.fileSize == 5_000)
        #expect(asset.localAvailability == .unknown)
        #expect(asset.statusString == "Cloud")
        #expect(asset.hidden)
    }

    @Test func videoOriginalIsTheLargestTypeOneResource() throws {
        let video = try library.asset(uuid: "CLOUD-VIDEO")
        #expect(video.fileSize == 50_000_000)
        #expect(video.localAvailability == .cloud)
    }

    @Test func unknownAssetThrows() {
        #expect(throws: PhotosLibraryError.self) {
            try library.asset(uuid: "MISSING")
        }
    }

    @Test func extendedAttributesAndAlbums() throws {
        let exif = try #require(try library.extendedAttributes(assetPK: 1))
        #expect(exif.cameraModel == "iPhone 15 Pro")
        #expect(exif.iso == 100)
        #expect(try library.extendedAttributes(assetPK: 2) == nil)

        #expect(try library.albums(assetPK: 1).map(\.title) == ["Trip"])
        #expect(try library.albums().map(\.title) == ["Art", "Trip"])
    }

    @Test func stats() throws {
        let stats = try library.stats()
        #expect(stats.totalCount == 5)
        #expect(stats.photoCount == 4)
        #expect(stats.videoCount == 1)
        #expect(stats.localCount == 2)
        #expect(stats.cloudCount == 3)
        // Asset 1: 1 + 2 + 4 MB (the resource without a fingerprint is not
        // counted). Asset 2: 50 + 10 MB of video and a 0.3 MB still. Asset 4:
        // 0.5 MB. Assets 5 and 6: no resources, so their original file sizes.
        #expect(stats.totalSize == 7_000_000 + 60_300_000 + 500_000 + 5_000 + 6_000)
        #expect(stats.originalSize == 3_000_000 + 60_000_000 + 500_000 + 5_000 + 6_000)
        #expect(stats.localCacheSize == 4_000_000)
    }
}
