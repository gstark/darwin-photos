import Foundation

/// Paths under ~/.shoebox. The Go tool uses ~/.darwin-photos.
public enum ShoeboxPaths {
    public static let directory = URL.homeDirectory.appending(path: ".shoebox")
    public static let config = directory.appending(path: "config.json")
    public static let failures = directory.appending(path: "failures.db")
    public static let runLock = directory.appending(path: "run.lock")
}

/// The contents of ~/.shoebox/config.json. All keys are optional.
/// The keys are the same as in the Go tool config file.
public struct Settings: Codable, Sendable, Equatable {
    public struct S3: Codable, Sendable, Equatable {
        public var profile: String?
        public var region: String?
        public var endpoint: String?
        public var forcePathStyle: Bool?
        public var sse: String?
        public var kmsKeyID: String?
        public var storageClass: String?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case profile, region, endpoint, sse
            case forcePathStyle = "force_path_style"
            case kmsKeyID = "kms_key_id"
            case storageClass = "storage_class"
        }

        public init() {}
    }

    public var workers: Int?
    public var destination: String?
    public var s3: S3?
    public var retryFailed: Bool?
    /// Only the app reads this. The CLI and the Go tool ignore it.
    public var schedule: Schedule?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case workers, destination, s3, schedule
        case retryFailed = "retry_failed"
    }

    public init() {}

    /// Reads the settings file. A missing file gives empty settings.
    public static func load(from url: URL = ShoeboxPaths.config) throws -> Settings {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return Settings()
        }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            throw SettingsError.invalid(url.path(percentEncoded: false), error)
        }
    }

    /// Writes the settings. Keys that this type does not know, for example
    /// keys of a newer version, stay in the file. A nil value removes its key.
    public func save(to url: URL = ShoeboxPaths.config) throws {
        var root: [String: Any] = [:]
        do {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SettingsError.notAnObject(url.path(percentEncoded: false))
            }
            root = object
        } catch CocoaError.fileReadNoSuchFile {
            // A new file.
        }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] ?? [:]
        // Objects merge key by key, so their unknown keys stay too.
        let objects: [CodingKeys: [String]] = [
            .s3: S3.CodingKeys.allCases.map(\.stringValue),
            .schedule: Schedule.CodingKeys.allCases.map(\.stringValue),
        ]
        for key in CodingKeys.allCases {
            let name = key.stringValue
            guard let knownKeys = objects[key] else {
                root[name] = encoded[name]
                continue
            }
            var object = root[name] as? [String: Any] ?? [:]
            let encodedObject = encoded[name] as? [String: Any] ?? [:]
            for knownKey in knownKeys {
                object[knownKey] = encodedObject[knownKey]
            }
            root[name] = object.isEmpty ? nil : object
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }
}

public enum SettingsError: Error, CustomStringConvertible {
    case invalid(String, Error)
    case notAnObject(String)

    public var description: String {
        switch self {
        case .invalid(let path, let error): "parse config \(path): \(error)"
        case .notAnObject(let path): "config \(path) is not a JSON object"
        }
    }
}
