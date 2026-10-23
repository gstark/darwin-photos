import ShoeboxCore
import Foundation
import Testing
@testable import shoebox

struct OutputTests {
    @Test(arguments: [
        (0, "0B"),
        (1023, "1023B"),
        (1024, "1.0KB"),
        (1536, "1.5KB"),
        (5 * 1024 * 1024, "5.0MB"),
        (3 * 1024 * 1024 * 1024 + 512 * 1024 * 1024, "3.5GB"),
    ] as [(Int64, String)])
    func formatBytesMatchesGo(bytes: Int64, expected: String) {
        #expect(formatBytes(bytes) == expected)
    }

    @Test func formatTablePadsAllColumnsButTheLast() {
        let table = formatTable([["L", "ABC", "long name"], ["C", "A", "x"]])
        #expect(table == "L  ABC  long name\nC  A    x\n")
    }

    private func sampleAsset() -> Asset {
        Asset(
            pk: 1, uuid: "U1", filename: "U1.heic", directory: "", originalFilename: "U1.heic",
            uniformTypeID: "public.heic", kind: .photo, width: 0, height: 10,
            dateCreated: CoreDataDate(timestamp: 86_400.5), dateModified: nil,
            latitude: 0, longitude: 0, duration: 0, favorite: false, hidden: false, trashed: false,
            cloudLocalState: 0, localAvailability: .local, fileSize: 42
        )
    }

    private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @Test func lsItemOmitsEmptyFieldsLikeGo() throws {
        let object = try jsonObject(LsOutput.Item(sampleAsset()))
        #expect(Set(object.keys) == ["uuid", "filename", "type", "size", "date", "status", "height"])
        #expect(object["date"] as? String == "2001-01-02T00:00:00Z")
    }

    @Test func catOutputOmitsEmptyCameraAndAlbums() throws {
        var asset = sampleAsset()
        asset.dateCreated = nil
        let object = try jsonObject(CatOutput(asset: asset, exif: ExtendedAttributes(), albums: [], path: "/p"))
        #expect(object["camera"] == nil)
        #expect(object["albums"] == nil)
        #expect(object["location"] == nil)
        #expect(object["dateCreated"] as? String == "0001-01-01T00:00:00Z")
    }
}

struct CommandTests {
    @Test func everyGoCommandExists() {
        let names = Shoebox.configuration.subcommands.map { $0._commandName }
        #expect(Set(names).isSuperset(of: ["ls", "cat", "stats", "albums", "backup", "export", "sync", "failures", "version"]))
    }
}
