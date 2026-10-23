import Foundation
import GRDB
import Testing
@testable import ShoeboxCore

struct FailureStoreTests {
    let path = FileManager.default.temporaryDirectory.appending(path: "failures-\(UUID().uuidString)/failures.db")

    @Test func failCountsAttemptsAndClearRemoves() throws {
        let store = try FailureStore(path: path)
        try store.fail("A", category: .local, reason: "first")
        try store.fail("A", category: .cloud, reason: "second")
        try store.fail("B", category: .cloud, reason: "other")

        let a = try #require(try store.list().first { $0.uuid == "A" })
        #expect(a.attempts == 2)
        #expect(a.category == .cloud)
        #expect(a.reason == "second")
        #expect(try store.list(category: .cloud).count == 2)

        try store.clear("A")
        #expect(try store.failedUUIDs() == ["B"])
        #expect(try store.clearAll() == 1)
    }

    @Test func pruneRemovesAssetsThatAreGone() throws {
        let store = try FailureStore(path: path)
        try store.fail("KEEP", category: .cloud, reason: "")
        try store.fail("GONE", category: .cloud, reason: "")
        #expect(try store.prune(keeping: ["KEEP", "OTHER"]) == 1)
        #expect(try store.failedUUIDs() == ["KEEP"])
    }

    @Test func readsRowsWrittenByTheGoTool() throws {
        let store = try FailureStore(path: path)
        let queue = try DatabaseQueue(path: path.path(percentEncoded: false))
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO failures VALUES
                ('GO', 'cloud', 'no supported CloudKit download record', 2,
                 '2026-06-26 13:49:07.799668+00:00', '2026-06-26 14:47:55.028724+00:00')
                """)
        }
        let record = try #require(try store.list().first)
        #expect(record.attempts == 2)
        #expect(abs(record.lastFailedAt.timeIntervalSince1970 - 1_782_485_275.028724) < 0.001)
    }

    @Test func timestampFormatMatchesTheGoDriver() throws {
        let date = Date(timeIntervalSince1970: 1_782_485_275.5)
        let text = FailureStore.format(date)
        #expect(text == "2026-06-26 14:47:55.500000+00:00")
        #expect(FailureStore.parse(text) == date)
        #expect(FailureStore.parse("2026-06-26 16:47:55+02:00") == Date(timeIntervalSince1970: 1_782_485_275))
    }
}

struct SettingsTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "settings-\(UUID().uuidString)")

    @Test func missingFileGivesEmptySettings() throws {
        #expect(try Settings.load(from: directory.appending(path: "config.json")) == Settings())
    }

    @Test func readsTheGoConfigFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "config.json")
        try Data("""
            {"workers": 6, "destination": "s3://bucket/backup/",
             "s3": {"profile": "gstark", "region": "us-east-1", "force_path_style": true},
             "retry_failed": true, "unknown": 1}
            """.utf8).write(to: url)
        let settings = try Settings.load(from: url)
        #expect(settings.workers == 6)
        #expect(settings.destination == "s3://bucket/backup/")
        #expect(settings.s3?.profile == "gstark")
        #expect(settings.s3?.forcePathStyle == true)
        #expect(settings.retryFailed == true)
    }

    @Test func saveKeepsUnknownKeysAndRemovesClearedOnes() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "config.json")
        try Data("""
            {"workers": 6, "destination": "/Volumes/Old", "retry_failed": true,
             "s3": {"profile": "gstark", "future_s3_key": "x"},
             "schedule": {"frequency": "daily"}}
            """.utf8).write(to: url)

        var settings = try Settings.load(from: url)
        settings.workers = 8
        settings.destination = "s3://bucket/backup/"
        settings.retryFailed = nil
        settings.s3?.profile = nil
        settings.s3?.region = "us-east-1"
        try settings.save(to: url)

        #expect(try Settings.load(from: url) == settings)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["retry_failed"] == nil)
        #expect((json["schedule"] as? [String: String]) == ["frequency": "daily"])
        #expect((json["s3"] as? [String: String]) == ["region": "us-east-1", "future_s3_key": "x"])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func saveDoesNotReplaceAnUnreadableFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "config.json")
        try Data(#"{"schedule": {"frequency": "daily"}}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false)) }

        #expect(throws: (any Error).self) { try Settings().save(to: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("schedule"))
    }

    @Test func saveCreatesTheFile() throws {
        let url = directory.appending(path: "new/config.json")
        var settings = Settings()
        settings.workers = 2
        try settings.save(to: url)
        #expect(try Settings.load(from: url) == settings)
    }
}

struct RunLockTests {
    @Test func secondLockIsBusyUntilTheFirstIsReleased() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "lock-\(UUID().uuidString)/run.lock")
        var first: RunLock? = try RunLock(path: path)
        #expect(throws: RunLock.Failure.self) { try RunLock(path: path) }
        withExtendedLifetime(first) {}
        first = nil
        #expect(throws: Never.self) { try RunLock(path: path) }
    }
}
