import Foundation
import Synchronization
import Testing
@testable import ShoeboxCore

/// Answers requests from a handler and keeps a log of them.
final class FakeTransport: HTTPTransport {
    typealias Reply = (status: Int, headers: [String: String], body: Data)

    private let handler: @Sendable (URLRequest) -> Reply
    private let log = Mutex<[URLRequest]>([])

    init(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        self.handler = handler
    }

    var requests: [URLRequest] { log.withLock { $0 } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        log.withLock { $0.append(request) }
        let reply = handler(request)
        return (reply.body, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!)
    }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        let file = FileManager.default.temporaryDirectory.appending(path: "fake-download-\(UUID().uuidString)")
        try data.write(to: file)
        return (file, response)
    }
}

private func json(_ text: String) -> Data { Data(text.utf8) }

struct ICloudClientTests {
    let session = ICloudSession(
        cookies: [
            .init(name: "X-APPLE-WEBAUTH-TOKEN", value: "\"token\"", domain: ".icloud.com"),
            .init(name: "OTHER", value: "x", domain: "idmsa.apple.com"),
        ],
        clientID: "client-1"
    )

    @Test func validateFollowsThePartitionRedirect() async throws {
        let transport = FakeTransport { request in
            if request.url?.host() == "setup.icloud.com" {
                return (421, ["X-Apple-User-Partition": "42"], Data())
            }
            return (200, [:], json(#"{"webservices":{"ckdatabasews":{"url":"https://p42-ckdatabasews.icloud.com:443"}},"dsInfo":{"dsid":"123"}}"#))
        }
        let client = ICloudClient(session: session, transport: transport)
        try await client.validate()

        #expect(await client.session.photosURL == "https://p42-ckdatabasews.icloud.com:443")
        #expect(await client.session.dsid == "123")
        let hosts = transport.requests.map { $0.url?.host() }
        #expect(hosts == ["setup.icloud.com", "p42-setup.icloud.com"])
        // Only cookies for the host, without quotes.
        #expect(transport.requests[0].value(forHTTPHeaderField: "Cookie") == "X-APPLE-WEBAUTH-TOKEN=token")
        #expect(transport.requests[0].url?.query()?.contains("clientId=client-1") == true)
    }

    @Test func aPartitionLoopMeansTheSessionIsInvalid() async throws {
        let transport = FakeTransport { _ in (421, ["X-Apple-User-Partition": "42"], Data()) }
        let client = ICloudClient(session: session, transport: transport)
        await #expect {
            try await client.validate()
        } throws: { ICloudClient.isSessionInvalid($0) }
    }

    @Test func lookupDecodesTheOriginal() async throws {
        var signedIn = session
        signedIn.photosURL = "https://p42-ckdatabasews.icloud.com:443"
        signedIn.dsid = "123"
        let transport = FakeTransport { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(body.contains(#""zoneName":"PrimarySync""#))
            return (200, [:], json("""
                {"records":[{"recordName":"MASTER","fields":{
                  "resOriginalRes":{"value":{"downloadURL":"https://cvws.icloud-content.com/B/x/${f}?o=1","size":2048,"fileChecksum":"abc"}},
                  "filenameEnc":{"value":"\(Data("IMG_0001.HEIC".utf8).base64EncodedString())"}}}]}
                """))
        }
        let client = ICloudClient(session: signedIn, transport: transport)
        let file = try await client.remoteFile(for: CloudRecord(recordName: "MASTER", searchAllZones: false))
        #expect(file.filename == "IMG_0001.HEIC")
        #expect(file.size == 2048)
        #expect(file.downloadURL.hasSuffix("${f}?o=1"))
        let request = try #require(transport.requests.first)
        #expect(request.url?.path() == "/database/1/com.apple.photos.cloud/production/private/records/lookup")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/plain;charset=UTF-8")
        #expect(request.url?.query()?.contains("dsid=123") == true)
    }

    @Test func lookupSearchesOtherZonesForFingerprintRecords() async throws {
        var signedIn = session
        signedIn.photosURL = "https://p42-ckdatabasews.icloud.com:443"
        let transport = FakeTransport { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if request.url?.path().hasSuffix("zones/list") == true {
                return (200, [:], json(#"{"zones":[{"zoneID":{"zoneName":"PrimarySync"}},{"zoneID":{"zoneName":"SharedSync-1","ownerRecordName":"_owner"}},{"zoneID":{"zoneName":"Gone"},"deleted":true}]}"#))
            }
            if body.contains("SharedSync-1") {
                return (200, [:], json(#"{"records":[{"recordName":"FP","fields":{"resOriginalRes":{"value":{"downloadURL":"https://example.com/f","size":1}}}}]}"#))
            }
            return (200, [:], json(#"{"records":[{"recordName":"FP","serverErrorCode":"NOT_FOUND"}]}"#))
        }
        let client = ICloudClient(session: signedIn, transport: transport)
        let file = try await client.remoteFile(for: CloudRecord(recordName: "FP", searchAllZones: true))
        #expect(file.downloadURL == "https://example.com/f")

        // A master record is only looked up in PrimarySync.
        await #expect(throws: ICloudError.self) {
            try await client.remoteFile(for: CloudRecord(recordName: "FP", searchAllZones: false))
        }
    }

    @Test func invalidGlobalSessionIsReported() async throws {
        var signedIn = session
        signedIn.photosURL = "https://p42-ckdatabasews.icloud.com:443"
        let transport = FakeTransport { _ in (421, [:], json(#"{"reason":"Invalid global session"}"#)) }
        let client = ICloudClient(session: signedIn, transport: transport)
        await #expect {
            try await client.remoteFile(for: CloudRecord(recordName: "FP", searchAllZones: true))
        } throws: { ICloudClient.isSessionInvalid($0) }
    }

    @Test func downloadChecksTheLengthAndSendsNoCookies() async throws {
        let transport = FakeTransport { _ in (200, ["Content-Length": "10"], Data("short".utf8)) }
        let client = ICloudClient(session: session, transport: transport)
        let target = FileManager.default.temporaryDirectory.appending(path: "download-\(UUID().uuidString)")
        let file = RemoteFile(recordName: "R", filename: "", size: 10, downloadURL: "https://cvws.icloud-content.com/B/x/${f}?o=1", checksum: "")
        await #expect {
            try await client.download(file, to: target, retries: 0)
        } throws: { if case ICloudError.incompleteDownload = $0 { true } else { false } }
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(!FileManager.default.fileExists(atPath: target.path(percentEncoded: false)))
    }

    @Test func downloadRetriesServerErrors() async throws {
        let calls = Mutex(0)
        let transport = FakeTransport { _ in
            let call = calls.withLock { $0 += 1; return $0 }
            return call == 1 ? (503, [:], Data()) : (200, [:], Data("photo".utf8))
        }
        let client = ICloudClient(session: session, transport: transport)
        let target = FileManager.default.temporaryDirectory.appending(path: "download-\(UUID().uuidString)")
        let file = RemoteFile(recordName: "R", filename: "", size: 5, downloadURL: "https://example.com/f", checksum: "")
        try await client.download(file, to: target, retries: 1)
        #expect(try String(contentsOf: target, encoding: .utf8) == "photo")
    }
}

struct ICloudSessionTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "session-\(UUID().uuidString)")

    @Test func importsTheGoSessionFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "session.json")
        try json("""
            {"dsid":"123","client_id":"abc","photos_url":"https://p1-ckdatabasews.icloud.com:443",
             "cookies":[{"Name":"X-APPLE-WEBAUTH-TOKEN","Value":"t","Path":"","Domain":"","Expires":"0001-01-01T00:00:00Z"},
                        {"Name":"X-APPLE-WEBAUTH-USER","Value":"u","Path":"","Domain":""}],
             "saved_at":"2026-06-26T13:49:07.799668-04:00"}
            """).write(to: url)
        let session = try ICloudSession.importGoSession(from: url)
        #expect(session.dsid == "123")
        #expect(session.clientID == "abc")
        #expect(session.photosURL == "https://p1-ckdatabasews.icloud.com:443")
        #expect(session.cookies.allSatisfy { $0.domain == nil })
        // Cookies without a domain go to every host.
        #expect(session.cookieHeader(host: "p1-ckdatabasews.icloud.com") == "X-APPLE-WEBAUTH-TOKEN=t; X-APPLE-WEBAUTH-USER=u")
    }

    @Test func importsACookiesFile() throws {
        let text = """
            # Netscape HTTP Cookie File
            .icloud.com\tTRUE\t/\tTRUE\t0\tX-APPLE-WEBAUTH-TOKEN\t"v=2:t=abc"
            #HttpOnly_.icloud.com\tTRUE\t/\tTRUE\t0\tX-APPLE-WEBAUTH-USER\tu
            .example.com\tTRUE\t/\tTRUE\t0\tOTHER\tx
            """
        let session = try ICloudSession.importCookiesFile(text)
        #expect(session.cookies.map(\.name) == ["X-APPLE-WEBAUTH-TOKEN", "X-APPLE-WEBAUTH-USER"])
        #expect(session.cookies[0].value == "v=2:t=abc")
        #expect(session.cookieHeader(host: "setup.icloud.com") == "X-APPLE-WEBAUTH-TOKEN=v=2:t=abc; X-APPLE-WEBAUTH-USER=u")
        #expect(session.cookieHeader(host: "example.com") == nil)
    }

    @Test func aCookiesFileNeedsTheAuthToken() {
        #expect(throws: ICloudSessionImportError.self) {
            try ICloudSession.importCookiesFile(".icloud.com\tTRUE\t/\tTRUE\t0\tOTHER\tx")
        }
    }
}

struct CloudDownloaderTests {
    /// A store with no session.
    struct EmptyStore: SessionStore {
        func load() throws -> ICloudSession? { nil }
        func save(_ session: ICloudSession) throws {}
        func delete() throws {}
    }

    @Test func withoutPhotoKitOrSessionTheAssetWaitsForSignIn() async throws {
        let fixture = try FixtureLibrary()
        let library = try PhotosLibrary(libraryPath: fixture.path)
        let downloader = CloudDownloader(library: library, photoKit: nil, iCloud: ICloudAccess(store: EmptyStore()))
        let target = FileManager.default.temporaryDirectory.appending(path: "cloud-\(UUID().uuidString)")

        await #expect {
            try await downloader.download(try library.asset(uuid: "CLOUD-VIDEO"), to: target)
        } throws: { if case CloudDownloadError.signInRequired = $0 { true } else { false } }
        // No record name at all is a normal failure.
        await #expect {
            try await downloader.download(try library.asset(uuid: "NO-RESOURCE"), to: target)
        } throws: { if case CloudDownloadError.noCloudRecord = $0 { true } else { false } }
    }
}
