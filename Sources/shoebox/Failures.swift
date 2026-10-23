import ArgumentParser
import ShoeboxCore
import Foundation

struct Failures: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List assets that previously failed to process",
        discussion: """
            List assets recorded as having failed to find locally or download from iCloud.

            By default, backup skips these assets. Pass --retry-failed to attempt them
            again; a successful attempt removes the asset from this list automatically.
            """,
        subcommands: [Clear.self]
    )

    func run() throws {
        let records = try FailureStore().list()
        guard !records.isEmpty else {
            print("No recorded failures.")
            return
        }
        let local = records.filter { $0.category == .local }.count
        let cloud = records.filter { $0.category == .cloud }.count
        print("\(records.count) recorded failures (\(local) local, \(cloud) cloud):\n")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for record in records {
            print("  \(record.uuid)  [\(record.category.rawValue)]  attempts=\(record.attempts)  last=\(formatter.string(from: record.lastFailedAt))")
            if !record.reason.isEmpty {
                print("      \(record.reason)")
            }
        }
    }

    struct Clear: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove assets from the failure list",
            discussion: "Remove specific UUIDs from the failure list, or use --all to clear every record."
        )

        @Argument(help: "UUIDs to remove")
        var uuids: [String] = []

        @Flag(help: "Clear all recorded failures")
        var all = false

        func validate() throws {
            if !all, uuids.isEmpty {
                throw ValidationError("provide UUIDs to clear or use --all")
            }
            if all, !uuids.isEmpty {
                throw ValidationError("--all cannot be combined with explicit UUIDs")
            }
        }

        func run() throws {
            let store = try FailureStore()
            if all {
                print("Cleared \(try store.clearAll()) recorded failures.")
                return
            }
            for uuid in uuids {
                try store.clear(uuid)
            }
            print("Cleared \(uuids.count) UUID(s) from the failure list.")
        }
    }
}
