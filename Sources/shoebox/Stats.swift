import ArgumentParser
import ShoeboxCore

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show library statistics",
        discussion: "Show total count and size of photos and videos in your iCloud Photos library."
    )

    @OptionGroup var libraryOptions: LibraryOptions

    @Flag(help: "Output as JSON")
    var json = false

    func run() throws {
        let stats = try libraryOptions.open().stats()
        if json {
            try printJSON(StatsOutput(stats))
        } else {
            printPlain(stats)
        }
    }

    private func printPlain(_ stats: LibraryStats) {
        func line(_ label: String, _ bytes: Int64, indent: Bool = false) {
            let padded = indent
                ? "  " + label.padding(toLength: 43, withPad: " ", startingAt: 0)
                : label.padding(toLength: 45, withPad: " ", startingAt: 0)
            let size = formatBytes(bytes)
            print(padded + " " + String(repeating: " ", count: max(0, 10 - size.count)) + size)
        }
        func counted(_ label: String, _ count: Int, _ bytes: Int64) -> String {
            let size = formatBytes(bytes)
            return label + String(repeating: " ", count: max(0, 6 - String(count).count)) + "\(count) items  "
                + String(repeating: " ", count: max(0, 10 - size.count)) + size
        }

        line("iCloud Storage (counts toward quota):", stats.iCloudStorage)
        line("Originals:", stats.originalSize, indent: true)
        line("Cloud derivatives:", stats.cloudDerivatives, indent: true)
        print()
        line("Local Cache Only (not in iCloud):", stats.localCacheSize)
        line("JPEG previews for cloud photos", stats.localCacheSize, indent: true)
        print()
        line("Total on this Mac:", stats.totalSize)
        print()
        print("By type:")
        print(counted("  Photos: ", stats.photoCount, stats.photoSize))
        print(counted("  Videos: ", stats.videoCount, stats.videoSize))
        print()
        print("By availability:")
        print(counted("  Downloaded:  ", stats.localCount, stats.localSize))
        print(counted("  Cloud-only:  ", stats.cloudCount, stats.cloudSize))
    }
}

/// The `stats --json` shape of the Go tool.
struct StatsOutput: Encodable {
    let total_count: Int
    let total_size: Int64
    let icloud_storage: Int64
    let original_size: Int64
    let cloud_derivatives: Int64
    let local_cache_size: Int64
    let derivative_size: Int64
    let local_count: Int
    let local_size: Int64
    let cloud_count: Int
    let cloud_size: Int64
    let photo_count: Int
    let photo_size: Int64
    let video_count: Int
    let video_size: Int64

    init(_ stats: LibraryStats) {
        total_count = stats.totalCount
        total_size = stats.totalSize
        icloud_storage = stats.iCloudStorage
        original_size = stats.originalSize
        cloud_derivatives = stats.cloudDerivatives
        local_cache_size = stats.localCacheSize
        derivative_size = stats.derivativeSize
        local_count = stats.localCount
        local_size = stats.localSize
        cloud_count = stats.cloudCount
        cloud_size = stats.cloudSize
        photo_count = stats.photoCount
        photo_size = stats.photoSize
        video_count = stats.videoCount
        video_size = stats.videoSize
    }
}
