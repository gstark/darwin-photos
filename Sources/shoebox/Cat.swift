import ArgumentParser
import ShoeboxCore
import Foundation

struct Cat: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show detailed information about a photo",
        discussion: "Display detailed metadata for a specific photo or video, by its full UUID."
    )

    @OptionGroup var libraryOptions: LibraryOptions

    @Argument(help: "The asset UUID")
    var uuid: String

    @Flag(help: "Output as JSON")
    var json = false

    func run() throws {
        let library = try libraryOptions.open()
        let asset: Asset
        do {
            asset = try library.asset(uuid: uuid)
        } catch PhotosLibraryError.assetNotFound {
            throw CLIError("asset not found: \(uuid)")
        }
        let exif = try library.extendedAttributes(assetPK: asset.pk)
        let albums = try library.albums(assetPK: asset.pk).map(\.title)
        let path = asset.localPath(libraryPath: library.libraryPath)

        if json {
            try printJSON(CatOutput(asset: asset, exif: exif, albums: albums, path: path), sortedKeys: true)
        } else {
            printPlain(asset, exif: exif, albums: albums, path: path)
        }
    }

    private func printPlain(_ asset: Asset, exif: ExtendedAttributes?, albums: [String], path: String) {
        print("uuid:      \(asset.uuid)")
        print("file:      \(asset.originalFilename)")
        if asset.filename != asset.originalFilename {
            print("current:   \(asset.filename)")
        }
        print("type:      \(asset.typeString) (\(asset.uniformTypeID))")
        print("size:      \(formatBytes(asset.fileSize)) (\(asset.fileSize) bytes)")
        if asset.width > 0, asset.height > 0 {
            print("dims:      \(asset.width)x\(asset.height)")
        }
        if let date = asset.dateCreated {
            print("date:      \(date.dateTime)")
        }
        if asset.duration > 0 {
            print(String(format: "duration:  %.1fs", asset.duration))
        }
        print("status:    \(asset.statusString)")
        print("path:      \(path)")
        if asset.latitude != 0 || asset.longitude != 0 {
            print(String(format: "location:  %.6f,%.6f", asset.latitude, asset.longitude))
        }

        if let exif {
            let camera = [exif.cameraMake, exif.cameraModel].filter { !$0.isEmpty }.joined(separator: " ")
            if !camera.isEmpty {
                print("camera:    \(camera)")
            }
            if !exif.lensModel.isEmpty {
                print("lens:      \(exif.lensModel)")
            }
            if exif.iso > 0 {
                print("iso:       \(exif.iso)")
            }
            if exif.aperture > 0 {
                print(String(format: "aperture:  f/%.1f", exif.aperture))
            }
            if exif.shutterSpeed > 0 {
                if exif.shutterSpeed < 1 {
                    print(String(format: "shutter:   1/%.0f", 1 / exif.shutterSpeed))
                } else {
                    print(String(format: "shutter:   %.1fs", exif.shutterSpeed))
                }
            }
            if exif.focalLength > 0 {
                print(String(format: "focal:     %.1fmm", exif.focalLength))
            }
        }

        if !albums.isEmpty {
            print("albums:    \(albums.joined(separator: ", "))")
        }

        let flags = [(asset.favorite, "favorite"), (asset.hidden, "hidden"), (asset.trashed, "trashed")]
            .filter(\.0).map(\.1)
        if !flags.isEmpty {
            print("flags:     \(flags.joined(separator: ", "))")
        }
    }
}

/// The `cat --json` shape of the Go tool. Go encodes it from a map, so the
/// keys are sorted.
struct CatOutput: Encodable {
    struct Dimensions: Encodable {
        let width: Int
        let height: Int
    }

    struct Location: Encodable {
        let latitude: Double
        let longitude: Double
    }

    struct Camera: Encodable {
        let make: String?
        let model: String?
        let lens: String?
        let iso: Int?
        let aperture: Double?
        let shutterSpeed: Double?
        let focalLength: Double?

        /// Returns nil when no field has a value, because Go omits an empty camera.
        init?(_ exif: ExtendedAttributes) {
            make = exif.cameraMake.isEmpty ? nil : exif.cameraMake
            model = exif.cameraModel.isEmpty ? nil : exif.cameraModel
            lens = exif.lensModel.isEmpty ? nil : exif.lensModel
            iso = exif.iso > 0 ? exif.iso : nil
            aperture = exif.aperture > 0 ? exif.aperture : nil
            shutterSpeed = exif.shutterSpeed > 0 ? exif.shutterSpeed : nil
            focalLength = exif.focalLength > 0 ? exif.focalLength : nil
            if make == nil, model == nil, lens == nil, iso == nil, aperture == nil, shutterSpeed == nil, focalLength == nil {
                return nil
            }
        }
    }

    let uuid: String
    let filename: String
    let originalFilename: String
    let type: String
    let uniformTypeId: String
    let dimensions: Dimensions
    let fileSize: Int64
    let dateCreated: String
    let favorite: Bool
    let hidden: Bool
    let trashed: Bool
    let status: String
    let localPath: String
    let location: Location?
    let duration: Double?
    let camera: Camera?
    let albums: [String]?

    init(asset: Asset, exif: ExtendedAttributes?, albums: [String], path: String) {
        uuid = asset.uuid
        filename = asset.filename
        originalFilename = asset.originalFilename
        type = asset.typeString
        uniformTypeId = asset.uniformTypeID
        dimensions = Dimensions(width: asset.width, height: asset.height)
        fileSize = asset.fileSize
        // Go prints its zero time for a missing date.
        dateCreated = asset.dateCreated?.rfc3339Nano ?? "0001-01-01T00:00:00Z"
        favorite = asset.favorite
        hidden = asset.hidden
        trashed = asset.trashed
        status = asset.statusString
        localPath = path
        location = asset.latitude != 0 || asset.longitude != 0
            ? Location(latitude: asset.latitude, longitude: asset.longitude) : nil
        duration = asset.duration > 0 ? asset.duration : nil
        camera = exif.flatMap(Camera.init)
        self.albums = albums.isEmpty ? nil : albums
    }
}
