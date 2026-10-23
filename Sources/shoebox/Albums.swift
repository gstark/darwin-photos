import ArgumentParser
import ShoeboxCore

struct Albums: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List albums in the library",
        discussion: "List all user-created albums in your iCloud Photos library."
    )

    @OptionGroup var libraryOptions: LibraryOptions

    @Flag(help: "Output as JSON")
    var json = false

    func run() throws {
        let albums = try libraryOptions.open().albums()
        if json {
            try printJSON(AlbumsOutput(albums: albums.map { .init(uuid: $0.uuid, title: $0.title) }, total: albums.count))
        } else if albums.isEmpty {
            print("No albums found")
        } else {
            albums.forEach { print($0.title) }
        }
    }
}

/// The `albums --json` shape of the Go tool.
struct AlbumsOutput: Encodable {
    struct Item: Encodable {
        let uuid: String
        let title: String
    }

    let albums: [Item]
    let total: Int
}
