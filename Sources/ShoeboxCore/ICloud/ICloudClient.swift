import Foundation

/// Sends HTTP requests. `URLSession` is the real transport.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Downloads the body to a new temporary file that the caller owns.
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request, delegate: nil)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (file, response) = try await download(for: request, delegate: nil)
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: file)
            throw URLError(.badServerResponse)
        }
        return (file, http)
    }
}

public enum ICloudError: Error, CustomStringConvertible {
    /// Apple rejected the session. The user must sign in again.
    case sessionInvalid(String)
    case http(step: String, status: Int, body: String)
    case missingDatabaseURL
    case recordNotFound(String)
    case recordError(recordName: String, code: String)
    case noDownloadURL(String)
    case incompleteDownload(got: Int64, expected: Int64)

    public var description: String {
        switch self {
        case .sessionInvalid(let detail): "iCloud session invalid: \(detail)"
        case .http(let step, let status, let body): "\(step) failed (status \(status)): \(body.prefix(300))"
        case .missingDatabaseURL: "no Photos URL found in the setup response"
        case .recordNotFound(let name): "photo not found: \(name)"
        case .recordError(let name, let code): "cloudkit error for \(name): \(code)"
        case .noDownloadURL(let name): "no download URL available for: \(name)"
        case .incompleteDownload(let got, let expected): "incomplete download: got \(got) bytes, expected \(expected)"
        }
    }

    /// Transient errors that can succeed on a retry. Ported from
    /// `isRetryableError`.
    static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case ICloudError.http(_, let status, _): status >= 500
        case ICloudError.incompleteDownload: true
        case let error as URLError:
            [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet,
             .dnsLookupFailed, .cannotFindHost, .secureConnectionFailed, .resourceUnavailable].contains(error.code)
        default: false
        }
    }
}

/// A file in iCloud that a pre-signed URL can download.
public struct RemoteFile: Sendable, Equatable {
    public var recordName: String
    public var filename: String
    public var size: Int64
    public var downloadURL: String
    public var checksum: String
}

/// The iCloud web API: setup discovery, CloudKit record lookup, and
/// downloads. Ported from internal/icloud.
///
/// Spike 1 found these rules:
/// - The client sets the `Cookie` header itself. A session with an
///   `HTTPCookieStorage` did not send the cookies.
/// - A 421 redirect loop means that the session is not valid.
public actor ICloudClient {
    /// The Safari user agent that the spike used.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    public private(set) var session: ICloudSession
    private let transport: any HTTPTransport
    private var privateZones: [Zone]?

    struct Zone: Codable, Equatable {
        let zoneName: String
        let ownerRecordName: String?
    }

    public init(session: ICloudSession, transport: any HTTPTransport = ICloudClient.defaultTransport) {
        self.session = session
        self.transport = transport
    }

    /// No cookie storage, and no cache. The client sets the cookies itself.
    public static let defaultTransport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30 * 60
        return URLSession(configuration: configuration)
    }()

    // MARK: Setup

    /// Calls the setup `validate` endpoint. It finds the CloudKit service URL
    /// and the DSID, and stores them in `session`.
    public func validate() async throws {
        let global = "https://setup.icloud.com/setup/ws/1"
        let china = "https://setup.icloud.com.cn/setup/ws/1"
        // A China endpoint with global cookies can loop on partition
        // redirects, so the global endpoint comes first unless the session is
        // for China.
        let endpoints = session.isChina ? [china, global] : [global, china]

        var lastError: Error = ICloudError.missingDatabaseURL
        for endpoint in endpoints {
            do {
                try await validate(endpoint: endpoint, depth: 0)
                return
            } catch let error as ICloudError {
                if case .sessionInvalid = error { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    private func validate(endpoint: String, depth: Int) async throws {
        guard depth <= 3 else {
            throw ICloudError.sessionInvalid("too many partition redirects")
        }
        let url = try Self.url(endpoint + "/validate", query: [
            "clientBuildNumber": "2546Build34",
            "clientMasteringNumber": "2546Build34",
            "clientId": session.clientID,
            "requestId": UUID().uuidString.lowercased(),
        ])
        let (data, http) = try await transport.data(for: request(url, body: nil))

        if http.statusCode == 421, let partition = http.value(forHTTPHeaderField: "X-Apple-User-Partition"), !partition.isEmpty {
            let domain = endpoint.contains(".cn") ? "icloud.com.cn" : "icloud.com"
            return try await validate(endpoint: "https://p\(partition)-setup.\(domain)/setup/ws/1", depth: depth + 1)
        }
        if [401, 403, 421].contains(http.statusCode) {
            throw ICloudError.sessionInvalid("validate returned status \(http.statusCode)")
        }
        guard http.statusCode < 400 else {
            throw ICloudError.http(step: "validate", status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }

        struct Body: Decodable {
            struct Webservices: Decodable {
                struct Service: Decodable { let url: String? }
                let ckdatabasews: Service?
            }
            struct DsInfo: Decodable { let dsid: String? }
            let webservices: Webservices?
            let dsInfo: DsInfo?
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        guard let photosURL = body.webservices?.ckdatabasews?.url, !photosURL.isEmpty else {
            throw ICloudError.missingDatabaseURL
        }
        session.photosURL = photosURL
        if let dsid = body.dsInfo?.dsid, !dsid.isEmpty {
            session.dsid = dsid
        }
    }

    // MARK: CloudKit

    /// Finds the download URL of the original. With `searchAllZones`, the
    /// lookup tries every private zone after PrimarySync.
    public func remoteFile(for record: CloudRecord) async throws -> RemoteFile {
        do {
            return try await lookup(record.recordName, zone: Zone(zoneName: "PrimarySync", ownerRecordName: nil))
        } catch {
            guard record.searchAllZones, !Self.isSessionInvalid(error) else { throw error }
            for zone in try await listPrivateZones() where zone.zoneName != "PrimarySync" {
                if let file = try? await lookup(record.recordName, zone: zone) {
                    return file
                }
            }
            throw error
        }
    }

    /// The names of the private Photos zones. A successful call proves that
    /// CloudKit accepts the session.
    public func privateZoneNames() async throws -> [String] {
        try await listPrivateZones().map(\.zoneName)
    }

    func listPrivateZones() async throws -> [Zone] {
        if let privateZones { return privateZones }
        let data = try await cloudKit(path: "private/zones/list", step: "cloudkit zones list", body: Data("{}".utf8))
        struct Body: Decodable {
            struct Entry: Decodable {
                let zoneID: Zone
                let deleted: Bool?
            }
            let zones: [Entry]
        }
        let zones = try JSONDecoder().decode(Body.self, from: data).zones.filter { $0.deleted != true }.map(\.zoneID)
        privateZones = zones
        return zones
    }

    private func lookup(_ recordName: String, zone: Zone) async throws -> RemoteFile {
        struct Lookup: Encodable {
            struct Ref: Encodable { let recordName: String }
            let records: [Ref]
            let zoneID: Zone
        }
        let body = try JSONEncoder().encode(Lookup(records: [.init(recordName: recordName)], zoneID: zone))
        let data = try await cloudKit(path: "private/records/lookup", step: "cloudkit lookup", body: body)

        struct Response: Decodable {
            struct Record: Decodable {
                struct Fields: Decodable {
                    struct Original: Decodable {
                        struct Value: Decodable {
                            let downloadURL: String?
                            let size: Int64?
                            let fileChecksum: String?
                        }
                        let value: Value?
                    }
                    struct Encoded: Decodable { let value: String? }
                    let resOriginalRes: Original?
                    let filenameEnc: Encoded?
                }
                let recordName: String?
                let serverErrorCode: String?
                let fields: Fields?
            }
            let records: [Record]?
        }
        guard let record = try JSONDecoder().decode(Response.self, from: data).records?.first else {
            throw ICloudError.recordNotFound(recordName)
        }
        if let code = record.serverErrorCode, !code.isEmpty {
            throw ICloudError.recordError(recordName: recordName, code: code)
        }
        let original = record.fields?.resOriginalRes?.value
        guard let url = original?.downloadURL, !url.isEmpty else {
            throw ICloudError.noDownloadURL(recordName)
        }
        let filename = record.fields?.filenameEnc?.value
            .flatMap { Data(base64Encoded: $0) }
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        return RemoteFile(
            recordName: record.recordName ?? recordName,
            filename: filename,
            size: original?.size ?? 0,
            downloadURL: url,
            checksum: original?.fileChecksum ?? ""
        )
    }

    private func cloudKit(path: String, step: String, body: Data) async throws -> Data {
        guard let photosURL = session.photosURL else { throw ICloudError.missingDatabaseURL }
        var query = [
            "remapEnums": "true",
            "clientBuildNumber": "2546Build17",
            "clientMasteringNumber": "2546Build17",
            "clientId": session.clientID,
        ]
        query["dsid"] = session.dsid
        let url = try Self.url(photosURL + "/database/1/com.apple.photos.cloud/production/" + path, query: query)
        let (data, http) = try await transport.data(for: request(url, body: body))
        if http.statusCode == 401 || (http.statusCode == 421 && String(decoding: data, as: UTF8.self).contains("Invalid global session")) {
            throw ICloudError.sessionInvalid(String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard http.statusCode < 400 else {
            throw ICloudError.http(step: step, status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    // MARK: Download

    /// Downloads the file to `target`. Retries transient errors with a
    /// backoff of 1 s, 2 s, 4 s, and so on.
    public func download(_ file: RemoteFile, to target: URL, retries: Int) async throws {
        guard let url = URL(string: file.downloadURL) else { throw ICloudError.noDownloadURL(file.recordName) }
        // The download URLs are pre-signed. They need no cookies.
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        var attempt = 0
        while true {
            do {
                try await downloadOnce(request, to: target)
                return
            } catch {
                guard attempt < retries, ICloudError.isRetryable(error) else { throw error }
                try await Task.sleep(for: .seconds(1 << attempt))
                attempt += 1
            }
        }
    }

    private func downloadOnce(_ request: URLRequest, to target: URL) async throws {
        let (temp, http) = try await transport.download(for: request)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard http.statusCode < 400 else {
            throw ICloudError.http(step: "download", status: http.statusCode, body: "")
        }
        let size = Int64((try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if http.expectedContentLength > 0, size != http.expectedContentLength {
            throw ICloudError.incompleteDownload(got: size, expected: http.expectedContentLength)
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
    }

    // MARK: Requests

    private func request(_ url: URL, body: Data?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let origin = url.host()?.hasSuffix(".cn") == true ? "https://www.icloud.com.cn" : "https://www.icloud.com"
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let body {
            // CloudKit wants text/plain.
            let type = url.host()?.contains("ckdatabasews") == true ? "text/plain;charset=UTF-8" : "application/json"
            request.setValue(type, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if let cookie = session.cookieHeader(host: url.host() ?? "") {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private static func url(_ base: String, query: [String: String]) throws -> URL {
        guard var components = URLComponents(string: base) else { throw URLError(.badURL) }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    static func isSessionInvalid(_ error: Error) -> Bool {
        if case ICloudError.sessionInvalid = error { return true }
        return false
    }
}
