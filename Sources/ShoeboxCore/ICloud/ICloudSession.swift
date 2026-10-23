import Foundation

/// The saved iCloud web sign-in: the cookies and the values that setup
/// discovery found. Ported from internal/icloud/session.go.
public struct ICloudSession: Codable, Sendable, Equatable {
    public struct Cookie: Codable, Sendable, Equatable {
        public var name: String
        public var value: String
        /// Nil sends the cookie to every iCloud host. The Go session file
        /// has no domains.
        public var domain: String?

        public init(name: String, value: String, domain: String? = nil) {
            self.name = name
            self.value = value
            self.domain = domain
        }
    }

    public static let authCookieName = "X-APPLE-WEBAUTH-TOKEN"

    public var cookies: [Cookie]
    public var dsid: String?
    /// Sent as `clientId`. It stays the same for the life of the session.
    public var clientID: String
    /// The CloudKit database service, for example `https://p123-ckdatabasews.icloud.com:443`.
    public var photosURL: String?
    public var savedAt: Date

    public init(cookies: [Cookie], dsid: String? = nil, clientID: String = UUID().uuidString.lowercased(), photosURL: String? = nil, savedAt: Date = Date()) {
        self.cookies = cookies
        self.dsid = dsid
        self.clientID = clientID
        self.photosURL = photosURL
        self.savedAt = savedAt
    }

    public var hasAuthCookie: Bool {
        cookies.contains { $0.name == Self.authCookieName && !$0.value.isEmpty }
    }

    /// True when the cookies or the service URL are for icloud.com.cn.
    var isChina: Bool {
        photosURL?.contains(".icloud.com.cn") == true || cookies.contains { $0.domain?.contains(".icloud.com.cn") == true }
    }

    /// The `Cookie` header for a host. The first cookie with a name wins.
    func cookieHeader(host: String) -> String? {
        var seen = Set<String>()
        let pairs = cookies.filter { cookie in
            guard Self.matches(cookie.domain, host: host), seen.insert(cookie.name).inserted else { return false }
            return true
        }
        .map { "\($0.name)=\(Self.clean($0.value))" }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    private static func matches(_ domain: String?, host: String) -> Bool {
        guard let domain = domain?.lowercased(), !domain.isEmpty else { return true }
        let base = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == base || host.hasSuffix("." + base)
    }

    /// Browser exports can quote cookie values. Go's cookie jar drops the
    /// quotes, so the Go tool always sent the values without them.
    static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "")
    }
}

public enum ICloudSessionImportError: Error, CustomStringConvertible {
    case noCookies
    case noAuthCookie

    public var description: String {
        switch self {
        case .noCookies: "no iCloud cookies found"
        case .noAuthCookie: "\(ICloudSession.authCookieName) not found"
        }
    }
}

extension ICloudSession {
    /// Reads `~/.darwin-photos/session.json` from the Go tool.
    public static func importGoSession(from url: URL) throws -> ICloudSession {
        struct GoCookie: Decodable {
            let Name: String
            let Value: String
            let Domain: String?
        }
        struct GoSession: Decodable {
            let dsid: String?
            let client_id: String?
            let photos_url: String?
            let cookies: [GoCookie]?
        }
        let go = try JSONDecoder().decode(GoSession.self, from: Data(contentsOf: url))
        let cookies = (go.cookies ?? []).map {
            Cookie(name: $0.Name, value: $0.Value, domain: ($0.Domain?.isEmpty ?? true) ? nil : $0.Domain)
        }
        let session = ICloudSession(
            cookies: cookies,
            dsid: go.dsid.flatMap { $0.isEmpty ? nil : $0 },
            clientID: go.client_id.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString.lowercased(),
            photosURL: go.photos_url.flatMap { $0.isEmpty ? nil : $0 }
        )
        try session.validateCookies()
        return session
    }

    /// Reads a Netscape `cookies.txt` export. Only icloud and apple cookies
    /// are kept, as in `runImportCookies`.
    public static func importCookiesFile(_ text: String) throws -> ICloudSession {
        var cookies: [Cookie] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // `#HttpOnly_` lines are real cookies in the Netscape format.
            let entry = trimmed.hasPrefix("#HttpOnly_") ? String(trimmed.dropFirst("#HttpOnly_".count)) : trimmed
            guard !entry.isEmpty, !entry.hasPrefix("#") else { continue }
            let parts = entry.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 7 else { continue }
            let domain = parts[0]
            guard domain.contains("icloud") || domain.contains("apple") else { continue }
            cookies.append(Cookie(name: parts[5], value: clean(parts[6]), domain: domain))
        }
        let session = ICloudSession(cookies: cookies)
        try session.validateCookies()
        return session
    }

    func validateCookies() throws {
        guard !cookies.isEmpty else { throw ICloudSessionImportError.noCookies }
        guard hasAuthCookie else { throw ICloudSessionImportError.noAuthCookie }
    }
}
