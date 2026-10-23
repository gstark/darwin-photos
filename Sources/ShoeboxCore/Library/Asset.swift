import Foundation

public enum AssetKind: Int, Sendable {
    case photo = 0
    case video = 1
}

/// Download state of the original resource. Photos.sqlite stores it in
/// ZINTERNALRESOURCE.ZLOCALAVAILABILITY.
public enum LocalAvailability: Int, Sendable {
    case unknown = 0
    case cloud = -1
    case local = 1
}

/// A photo or video in the library.
public struct Asset: Sendable, Equatable {
    public var pk: Int64
    public var uuid: String
    /// The file name inside the library (ZFILENAME). Backups use its extension.
    public var filename: String
    /// The originals subdirectory. Empty means the first character of the UUID.
    public var directory: String
    public var originalFilename: String
    public var uniformTypeID: String
    public var kind: AssetKind
    public var width: Int
    public var height: Int
    public var dateCreated: CoreDataDate?
    public var dateModified: CoreDataDate?
    public var latitude: Double
    public var longitude: Double
    /// Video length in seconds.
    public var duration: Double
    public var favorite: Bool
    public var hidden: Bool
    public var trashed: Bool
    public var cloudLocalState: Int
    public var localAvailability: LocalAvailability
    public var fileSize: Int64

    public init(
        pk: Int64, uuid: String, filename: String, directory: String, originalFilename: String,
        uniformTypeID: String, kind: AssetKind, width: Int, height: Int,
        dateCreated: CoreDataDate?, dateModified: CoreDataDate?,
        latitude: Double, longitude: Double, duration: Double,
        favorite: Bool, hidden: Bool, trashed: Bool, cloudLocalState: Int,
        localAvailability: LocalAvailability, fileSize: Int64
    ) {
        self.pk = pk
        self.uuid = uuid
        self.filename = filename
        self.directory = directory
        self.originalFilename = originalFilename
        self.uniformTypeID = uniformTypeID
        self.kind = kind
        self.width = width
        self.height = height
        self.dateCreated = dateCreated
        self.dateModified = dateModified
        self.latitude = latitude
        self.longitude = longitude
        self.duration = duration
        self.favorite = favorite
        self.hidden = hidden
        self.trashed = trashed
        self.cloudLocalState = cloudLocalState
        self.localAvailability = localAvailability
        self.fileSize = fileSize
    }

    public var isLocallyAvailable: Bool { localAvailability == .local }

    public var typeString: String { kind == .video ? "Video" : "Photo" }

    public var statusString: String { isLocallyAvailable ? "Local" : "Cloud" }

    /// The path of the original file in the library.
    public func localPath(libraryPath: String) -> String {
        let dir = directory.isEmpty ? String(uuid.prefix(1)) : directory
        return URL(filePath: libraryPath)
            .appending(path: "originals")
            .appending(path: dir)
            .appending(path: filename)
            .path(percentEncoded: false)
    }
}

/// EXIF and camera metadata.
public struct ExtendedAttributes: Sendable, Equatable {
    public var cameraMake: String
    public var cameraModel: String
    public var lensModel: String
    public var iso: Int
    public var aperture: Double
    public var shutterSpeed: Double
    public var focalLength: Double

    public init(
        cameraMake: String = "", cameraModel: String = "", lensModel: String = "",
        iso: Int = 0, aperture: Double = 0, shutterSpeed: Double = 0, focalLength: Double = 0
    ) {
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.iso = iso
        self.aperture = aperture
        self.shutterSpeed = shutterSpeed
        self.focalLength = focalLength
    }
}

/// A Photos record in iCloud.
public struct CloudRecord: Sendable, Equatable {
    public var recordName: String
    /// True when the record name is a resource fingerprint. Such a record can
    /// be in any private zone, for example a SharedSync zone.
    public var searchAllZones: Bool

    public init(recordName: String, searchAllZones: Bool) {
        self.recordName = recordName
        self.searchAllZones = searchAllZones
    }
}

public struct Album: Sendable, Equatable {
    public var pk: Int64
    public var uuid: String
    public var title: String
}
