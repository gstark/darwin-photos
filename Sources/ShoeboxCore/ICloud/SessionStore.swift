import Foundation
import Security

/// Keeps the iCloud session between runs.
public protocol SessionStore: Sendable {
    func load() throws -> ICloudSession?
    func save(_ session: ICloudSession) throws
    func delete() throws
}

public enum KeychainError: Error, CustomStringConvertible {
    case status(OSStatus)

    public var description: String {
        switch self {
        case .status(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain error \(status): \(message)"
        }
    }
}

/// One generic password item in the login keychain.
public struct KeychainItem: Sendable {
    public let service: String
    public let account: String
    public let label: String

    public init(service: String = "com.gstark.shoebox", account: String, label: String) {
        self.service = service
        self.account = account
        self.label = label
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> Data? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.status(status) }
        return data
    }

    public func save(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = label
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError.status(added) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}

/// Stores the session as one generic password item in the login keychain.
/// The Go tool kept the session in `session.json`. The file is no longer
/// written.
public struct KeychainSessionStore: SessionStore {
    private let item: KeychainItem

    public init(service: String = "com.gstark.shoebox", account: String = "icloud-session") {
        item = KeychainItem(service: service, account: account, label: "shoebox iCloud session")
    }

    public func load() throws -> ICloudSession? {
        guard let data = try item.load() else { return nil }
        return try Self.decoder.decode(ICloudSession.self, from: data)
    }

    public func save(_ session: ICloudSession) throws {
        try item.save(Self.encoder.encode(session))
    }

    public func delete() throws {
        try item.delete()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension SessionStore {
    /// Copies the Go tool's `session.json` into the store if the store is
    /// empty. Returns true if it imported the file.
    @discardableResult
    public func importGoSessionIfEmpty(from url: URL = ShoeboxPaths.goSession) throws -> Bool {
        guard try load() == nil, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return false
        }
        try save(ICloudSession.importGoSession(from: url))
        return true
    }
}

extension ShoeboxPaths {
    /// The Go tool's session file. Read once, for the import.
    public static let goSession = URL.homeDirectory.appending(path: ".darwin-photos/session.json")
}
