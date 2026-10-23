import ArgumentParser
import ShoeboxCore
import Foundation

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export photos to a directory by UUID",
        discussion: """
            Copies or downloads the original of each asset to a directory. Files are
            named <UUID>.<ext>. Files that already exist are skipped.

            Local originals are copied. Cloud-only originals download through PhotoKit,
            or through the iCloud web API if PhotoKit cannot see the asset.

            Single export:
              shoebox export E448C88A-... /Volumes/Backup

            From file (one UUID per line):
              shoebox export --from-file uuids.txt /Volumes/Backup

            From stdin:
              shoebox ls --cloud --json | jq -r '.assets[].uuid' | shoebox export - /Volumes/Backup

            Sign in to iCloud with the Shoebox app (Settings > iCloud). The
            app and this tool share the session in the login Keychain.
            """,
        subcommands: [Files.self, ImportCookies.self, ImportSession.self, Status.self, Logout.self],
        defaultSubcommand: Files.self
    )
}

extension Export {
    struct Files: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Export the given UUIDs (the default)"
        )

        @OptionGroup var libraryOptions: LibraryOptions

        @Argument(help: "A UUID and the output directory, or `-` and the output directory, or only the output directory with --from-file")
        var arguments: [String] = []

        @Option(name: [.customShort("f"), .long], help: "File containing UUIDs (one per line)")
        var fromFile: String?

        @Option(name: [.short, .long], help: "Number of parallel workers")
        var workers = 4

        @Option(name: [.short, .long], help: "Number of retry attempts for failed iCloud downloads")
        var retry = 3

        @Flag(help: "Attempt assets previously recorded as failed (skipped by default)")
        var retryFailed = false

        func validate() throws {
            guard workers >= 1 else { throw ValidationError("--workers must be at least 1, got \(workers)") }
            guard retry >= 0 else { throw ValidationError("--retry must not be negative, got \(retry)") }
            if fromFile != nil {
                guard arguments.count == 1 else { throw ValidationError("--from-file requires output directory") }
            } else {
                guard arguments.count == 2 else {
                    throw ValidationError("requires UUID and output directory, or use --from-file/-")
                }
            }
        }

        func run() async throws {
            let uuids: [String]
            let outputDir: String
            if let fromFile {
                uuids = try readUUIDs(contentsOf: fromFile)
                outputDir = arguments[0]
            } else if arguments[0] == "-" {
                uuids = try readUUIDsFromStandardInput()
                outputDir = arguments[1]
            } else {
                uuids = [arguments[0]]
                outputDir = arguments[1]
            }

            let destination = try LocalDestination(directory: URL(filePath: outputDir))
            let failures = try? FailureStore()
            let library = try libraryOptions.open()
            let downloader = await CloudSetup.downloader(library: library, retries: retry)

            var options = BackupOptions()
            options.workers = workers
            options.retryFailed = retryFailed
            options.onlyUUIDs = Set(uuids)
            let engine = BackupEngine(library: library, destination: destination, downloader: downloader, failures: failures)
            let (events, task) = engine.start(options)
            let renderer = BackupRenderer(retryCommand: "export --retry-failed ...", title: "Export")
            let outcome = try await withInterruptHandler(stop: task.cancel) { try await renderer.render(events) }

            let notExported = outcome.plan.notFound.count + outcome.summary.failed + outcome.summary.waitingForSignIn
            if notExported > 0 {
                throw CLIError("\(notExported) of \(Set(uuids).count) requested asset(s) were not exported")
            }
        }
    }
}

// MARK: iCloud session

extension Export {
    struct ImportCookies: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import-cookies",
            abstract: "Import browser cookies for iCloud authentication",
            discussion: """
                Import cookies exported from your browser to authenticate with iCloud.

                Steps:
                  1. Log into icloud.com in your browser.
                  2. Open Photos so that the photo cookies load.
                  3. Export the cookies for "icloud.com" in Netscape cookies.txt format.
                  4. Run: shoebox export import-cookies cookies.txt

                The session goes into the login Keychain.
                """
        )

        @Argument(help: "The cookies.txt file")
        var cookieFile: String

        func run() async throws {
            let text: String
            do {
                text = try String(contentsOf: URL(filePath: cookieFile), encoding: .utf8)
            } catch {
                throw CLIError("failed to read cookie file: \(error.localizedDescription)")
            }
            try await saveValidated(ICloudSession.importCookiesFile(text))
        }
    }

    struct ImportSession: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import-session",
            abstract: "Import the iCloud session that the Go tool saved",
            discussion: "Reads ~/.darwin-photos/session.json, or the given file, and stores the session in the login Keychain."
        )

        @Argument(help: "The session file")
        var path = ShoeboxPaths.goSession.path(percentEncoded: false)

        func run() async throws {
            try await saveValidated(ICloudSession.importGoSession(from: URL(filePath: path)))
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check the saved iCloud session with Apple"
        )

        func run() async throws {
            guard let session = try KeychainSessionStore().load() else {
                throw CLIError("not signed in. Sign in with the Shoebox app (Settings > iCloud), or run 'shoebox export import-cookies'")
            }
            Console.line("Session saved at: \(session.savedAt.formatted(date: .abbreviated, time: .shortened))")
            Console.line("Cookies: \(session.cookies.count)")
            let client = ICloudClient(session: session)
            do {
                try await client.validate()
                let zones = try await client.privateZoneNames()
                Console.line("Private zones: \(zones.joined(separator: ", "))")
            } catch {
                throw CLIError("session validation failed: \(error)")
            }
            try KeychainSessionStore().save(await client.session)
            Console.line("Session is valid. Photos URL: \(await client.session.photosURL ?? "")")
        }
    }

    struct Logout: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Clear the saved iCloud session",
            discussion: "Removes the session from the login Keychain. ~/.darwin-photos/session.json is not changed."
        )

        func run() throws {
            try KeychainSessionStore().delete()
            print("Logged out successfully.")
        }
    }
}

/// Validates new cookies with Apple, as `saveICloudCookies` does, then
/// stores the session.
private func saveValidated(_ session: ICloudSession) async throws {
    Console.line("Discovering Photos URL from iCloud...")
    let client = ICloudClient(session: session)
    do {
        try await client.validate()
    } catch {
        throw CLIError("failed to discover Photos URL: \(error)")
    }
    try KeychainSessionStore().save(await client.session)
    print("iCloud session saved to the login Keychain.")
}
