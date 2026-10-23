import Foundation

/// An AWS access key for the backup IAM user. The app uses it for its
/// backups, so a scheduled run does not need the AWS profile, which can
/// wait for a locked password manager.
public struct AccessKey: Codable, Sendable, Equatable {
    public var id: String
    public var secret: String

    public init(id: String, secret: String) {
        self.id = id
        self.secret = secret
    }
}

/// Keeps the access key in the login keychain. `scripts/create-backup-iam-user.sh`
/// writes the same item.
public struct AccessKeyStore: Sendable {
    private let item = KeychainItem(account: "aws-access-key", label: "shoebox AWS access key")

    public init() {}

    public func load() throws -> AccessKey? {
        guard let data = try item.load() else { return nil }
        return try JSONDecoder().decode(AccessKey.self, from: data)
    }

    public func save(_ key: AccessKey) throws {
        try item.save(JSONEncoder().encode(key))
    }

    public func delete() throws {
        try item.delete()
    }
}
