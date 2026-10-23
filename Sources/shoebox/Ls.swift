import ArgumentParser
import ShoeboxCore
import Foundation

extension ListOptions.Sort: ExpressibleByArgument {}

struct Ls: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List photos in the library",
        discussion: """
            List photos and videos in your iCloud Photos library.

            Shows UUID, filename, type, size, date, and download status (Local/Cloud).
            """
    )

    @OptionGroup var libraryOptions: LibraryOptions

    @Option(name: [.customShort("n"), .long], help: "Limit number of results")
    var limit = 50

    @Option(name: [.customShort("o"), .long], help: "Offset for pagination")
    var offset = 0

    @Flag(help: "Show only locally available photos")
    var local = false

    @Flag(help: "Show only cloud-only photos")
    var cloud = false

    @Flag(help: "Show only photos (no videos)")
    var photos = false

    @Flag(help: "Show only videos")
    var videos = false

    @Option(name: [.short, .long], help: "Sort by: date, name, size")
    var sort = ListOptions.Sort.date

    @Flag(inversion: .prefixedNo, help: "Sort descending (newest first)")
    var desc = true

    @Flag(help: "Include trashed items")
    var trashed = false

    @Flag(help: "Output as JSON")
    var json = false

    @Option(help: "Start date (YYYY-MM-DD), inclusive")
    var start: String?

    @Option(help: "End date (YYYY-MM-DD), inclusive")
    var end: String?

    @Option(help: "Filter by album name (exact match)")
    var album: String?

    func run() throws {
        var options = ListOptions()
        options.limit = limit
        options.offset = offset
        options.localOnly = local
        options.cloudOnly = cloud
        options.photosOnly = photos
        options.videosOnly = videos
        options.includeTrashed = trashed
        options.sort = sort
        options.descending = desc
        options.albumName = album
        if let start {
            options.startDate = try parseDay(start, label: "start")
        }
        if let end {
            options.endDate = try parseDay(end, label: "end")
        }

        let library = try libraryOptions.open()
        let (assets, total) = try library.listAssets(options)
        if json {
            try printJSON(LsOutput(assets: assets.map(LsOutput.Item.init), count: assets.count, total: total))
        } else {
            printPlain(assets, total: total)
        }
    }

    private func printPlain(_ assets: [Asset], total: Int) {
        let rows = assets.map { asset -> [String] in
            var name = asset.originalFilename.isEmpty ? asset.filename : asset.originalFilename
            if name.count > 40 {
                name = String(name.prefix(37)) + "..."
            }
            return [
                asset.isLocallyAvailable ? "L" : "C",
                asset.uuid,
                formatBytes(asset.fileSize),
                asset.dateCreated?.shortDateTime ?? "-",
                asset.typeString,
                name,
            ]
        }
        print(formatTable(rows), terminator: "")
        if assets.count < total {
            printError("# \(assets.count)/\(total) shown")
        }
    }
}

/// The `ls --json` shape of the Go tool.
struct LsOutput: Encodable {
    struct Item: Encodable {
        let uuid: String
        let filename: String
        let original_filename: String?
        let type: String
        let size: Int64
        let date: String?
        let status: String
        let width: Int?
        let height: Int?
        let duration: Double?

        init(_ asset: Asset) {
            uuid = asset.uuid
            filename = asset.filename
            original_filename = asset.originalFilename.isEmpty || asset.originalFilename == asset.filename
                ? nil : asset.originalFilename
            type = asset.typeString
            size = asset.fileSize
            date = asset.dateCreated?.iso8601Seconds
            status = asset.statusString
            width = asset.width > 0 ? asset.width : nil
            height = asset.height > 0 ? asset.height : nil
            duration = asset.duration > 0 ? asset.duration : nil
        }
    }

    let assets: [Item]
    let count: Int
    let total: Int
}
