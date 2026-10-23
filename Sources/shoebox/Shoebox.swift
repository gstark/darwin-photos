import ArgumentParser
import ShoeboxCore

@main
struct Shoebox: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shoebox",
        abstract: "CLI tool for exploring your iCloud Photos library",
        discussion: """
            shoebox reads your local iCloud Photos database to list photos,
            show detailed metadata, and download cloud-only photos.
            """,
        version: cliVersion,
        subcommands: [Ls.self, Cat.self, Stats.self, Albums.self, Backup.self, Export.self, Sync.self, Failures.self, Version.self]
    )
}

struct LibraryOptions: ParsableArguments {
    @Option(name: [.short, .long], help: "Path to Photos library")
    var library = PhotosLibrary.defaultPath

    func open() throws -> PhotosLibrary {
        do {
            return try PhotosLibrary(libraryPath: library)
        } catch {
            throw CLIError("failed to open Photos database: \(error)")
        }
    }
}

/// A runtime error. ArgumentParser prints it without the usage text.
struct CLIError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
