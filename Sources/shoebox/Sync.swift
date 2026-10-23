import ArgumentParser
import ShoeboxCore
import Foundation

struct Sync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sync cloud photos to the Photos library",
        discussion: """
            Downloads cloud-only photos from iCloud into the Photos library through PhotoKit.
            No iCloud sign-in is needed.

            Single sync:
              shoebox sync E448C88A-...

            From file (one UUID per line):
              shoebox sync --from-file uuids.txt

            From stdin:
              shoebox ls --cloud --json | jq -r '.assets[].uuid' | shoebox sync -
            """
    )

    @OptionGroup var libraryOptions: LibraryOptions

    @Argument(help: "A UUID, or `-` to read UUIDs from stdin")
    var uuid: String?

    @Option(name: [.customShort("f"), .long], help: "File containing UUIDs (one per line)")
    var fromFile: String?

    @Option(name: [.short, .long], help: "Number of parallel workers")
    var workers = 4

    @Flag(help: "Attempt assets previously recorded as failed (skipped by default)")
    var retryFailed = false

    func validate() throws {
        guard workers >= 1 else { throw ValidationError("--workers must be at least 1, got \(workers)") }
        if fromFile != nil, uuid != nil {
            throw ValidationError("--from-file cannot be combined with UUID argument")
        }
        if fromFile == nil, uuid == nil {
            throw ValidationError("requires a UUID, --from-file, or -")
        }
    }

    func run() async throws {
        let requested: [String] = if let fromFile {
            try readUUIDs(contentsOf: fromFile)
        } else if uuid == "-" {
            try readUUIDsFromStandardInput()
        } else {
            [uuid!]
        }

        guard let photoKit = await CloudSetup.photoKit() else {
            throw CLIError("sync needs Photos access")
        }
        let failures = try? FailureStore()
        let skip = retryFailed ? [] : (try? failures?.failedUUIDs()) ?? []
        let uuids = requested.filter { !skip.contains($0) }
        if uuids.count < requested.count {
            Console.line("Skipping \(requested.count - uuids.count) previously failed photo(s) (use --retry-failed to attempt them)")
        }

        let library = try libraryOptions.open()
        var assets: [Asset] = []
        var notFound = 0
        var alreadyLocal = 0
        for uuid in uuids {
            guard let asset = try? library.asset(uuid: uuid) else {
                notFound += 1
                try? failures?.fail(uuid, category: .local, reason: "not found in Photos library")
                continue
            }
            if asset.isLocallyAvailable {
                alreadyLocal += 1
                try? failures?.clear(uuid)
            } else {
                assets.append(asset)
            }
        }
        if notFound > 0 { Console.line("Warning: \(notFound) UUIDs not found") }
        if alreadyLocal > 0 { Console.line("Skipping \(alreadyLocal) already local photos") }
        guard !assets.isEmpty else {
            Console.line("No cloud-only photos to sync")
            return
        }
        Console.line("Syncing \(assets.count) photos")
        Console.line("Using \(workers) workers\n")

        // PhotoKit writes into the library cache as it downloads. The copy in
        // the temporary folder is not needed.
        let staging = FileManager.default.temporaryDirectory.appending(path: "shoebox-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let start = Date()
        let bar = ProgressBar(total: assets.count, totalBytes: 0)
        var failedItems: [String] = []
        try await withThrowingTaskGroup(of: (Asset, Error?).self) { group in
            var pending = assets.makeIterator()
            func addNext() {
                guard let asset = pending.next() else { return }
                group.addTask {
                    let target = staging.appending(path: asset.backupFilename)
                    defer { try? FileManager.default.removeItem(at: target) }
                    do {
                        try await photoKit.download(uuid: asset.uuid, kind: asset.kind, to: target)
                        return (asset, nil)
                    } catch {
                        return (asset, error)
                    }
                }
            }
            for _ in 0..<workers { addNext() }
            var done = 0
            while let (asset, error) = try await group.next() {
                done += 1
                bar.draw(done: done, bytesDone: 0)
                if let error {
                    failedItems.append("\(asset.originalFilename.isEmpty ? asset.filename : asset.originalFilename): \(error)")
                    try? failures?.fail(asset.uuid, category: .cloud, reason: "sync failed: \(error)")
                } else {
                    try? failures?.clear(asset.uuid)
                }
                addNext()
            }
        }

        Console.line()
        Console.line("\nCompleted in \(formatDuration(Date().timeIntervalSince(start)))")
        Console.line("  Succeeded: \(assets.count - failedItems.count)")
        if !failedItems.isEmpty {
            Console.line("  Failed:    \(failedItems.count)")
            failedItems.forEach { Console.line("    - \($0)") }
            throw CLIError("\(failedItems.count) syncs failed")
        }
    }
}

/// Reads UUIDs, one per line. Empty lines and lines that start with `#` are
/// ignored. Ported from `parseUUIDs`.
func parseUUIDs(_ text: String) throws -> [String] {
    let uuids = text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    guard !uuids.isEmpty else { throw CLIError("no UUIDs found in input") }
    return uuids
}

func readUUIDs(contentsOf path: String) throws -> [String] {
    do {
        return try parseUUIDs(String(contentsOf: URL(filePath: path), encoding: .utf8))
    } catch let error as CLIError {
        throw error
    } catch {
        throw CLIError("failed to open file: \(error.localizedDescription)")
    }
}

func readUUIDsFromStandardInput() throws -> [String] {
    try parseUUIDs(String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self))
}
