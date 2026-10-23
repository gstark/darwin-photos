import AWSClientRuntime
import AWSS3
import AWSSDKIdentity
import ShoeboxCore
import Foundation
import SmithyIdentity

/// Connection and upload settings. Each value is optional; nil uses the AWS
/// defaults.
public struct S3Options: Sendable, Equatable {
    public var profile: String?
    public var region: String?
    public var endpoint: String?
    public var forcePathStyle = false
    /// `AES256` or `aws:kms`.
    public var sse: String?
    public var kmsKeyID: String?
    public var storageClass: String?
    /// When set, the client uses this key instead of the AWS profile chain.
    public var accessKey: AccessKey?

    public init() {}
}

public enum S3DestinationError: Error, CustomStringConvertible {
    case invalidOption(String)
    case noRegion
    case bucket(String, Error)
    case list(Error)
    case upload(key: String, Error)

    public var description: String {
        switch self {
        case .invalidOption(let message): message
        case .noRegion: "no S3 region: pass --s3-region, set AWS_REGION, or set a region in the AWS profile"
        case .bucket(let bucket, let error): "validate S3 bucket \"\(bucket)\": \(error)"
        case .list(let error): "list S3 objects: \(error)"
        case .upload(let key, let error): "upload \(key): \(error)"
        }
    }
}

/// An S3 bucket and prefix. Ported from cmd/s3_destination.go.
///
/// Every upload sends `If-None-Match: *`, so an upload never replaces an
/// object. A 412 PreconditionFailed response means that the object exists,
/// and counts as success.
public struct S3Destination: BackupDestination {
    /// Files up to this size go in one PutObject. Larger files use a
    /// multipart upload.
    static let singlePutLimit = 16 * 1024 * 1024
    static let partSize = 8 * 1024 * 1024

    public let bucket: String
    public let prefix: String
    public let options: S3Options
    private let client: S3Client

    public init(uri: String, options: S3Options) throws {
        (bucket, prefix) = try S3Rules.parse(uri)
        try Self.check(options)
        self.options = options

        let resolver: any AWSCredentialIdentityResolver = if let key = options.accessKey {
            StaticAWSCredentialIdentityResolver(AWSCredentialIdentity(accessKey: key.id, secret: key.secret))
        } else if let profile = options.profile {
            ProfileAWSCredentialIdentityResolver(profileName: profile)
        } else {
            DefaultAWSCredentialIdentityResolverChain()
        }
        guard let region = options.region ?? AWSConfigFile.region(profile: options.profile) else {
            throw S3DestinationError.noRegion
        }
        let config = try S3Client.S3ClientConfig(
            awsCredentialIdentityResolver: resolver,
            region: region,
            forcePathStyle: options.forcePathStyle,
            endpoint: options.endpoint
        )
        client = S3Client(config: config)
    }

    /// The Go validation rules and messages.
    static func check(_ options: S3Options) throws {
        if let sse = options.sse, sse != "AES256", sse != "aws:kms" {
            throw S3DestinationError.invalidOption("unsupported --s3-sse value \"\(sse)\" (use AES256 or aws:kms)")
        }
        if options.kmsKeyID != nil, options.sse != "aws:kms" {
            throw S3DestinationError.invalidOption("--s3-kms-key-id requires --s3-sse aws:kms")
        }
        if let endpoint = options.endpoint {
            guard let url = URLComponents(string: endpoint), let scheme = url.scheme, url.host?.isEmpty == false else {
                throw S3DestinationError.invalidOption("invalid --s3-endpoint \"\(endpoint)\"")
            }
            guard scheme == "http" || scheme == "https" else {
                throw S3DestinationError.invalidOption("--s3-endpoint must use http or https")
            }
        }
    }

    public var displayName: String {
        "s3://" + bucket + (prefix.isEmpty ? "" : "/" + prefix)
    }

    /// Checks that the bucket exists and that the credentials work.
    public func validate() async throws {
        do {
            _ = try await client.headBucket(input: HeadBucketInput(bucket: bucket))
        } catch {
            throw S3DestinationError.bucket(bucket, error)
        }
    }

    /// The object names directly under the prefix. Deeper keys do not count.
    public func existingNames() async throws -> Set<String> {
        let listPrefix = prefix.isEmpty ? "" : prefix + "/"
        var names = Set<String>()
        do {
            for try await page in client.listObjectsV2Paginated(input: ListObjectsV2Input(bucket: bucket, prefix: listPrefix)) {
                for key in (page.contents ?? []).compactMap(\.key) {
                    let name = String(key.dropFirst(listPrefix.count))
                    if !name.isEmpty, !name.contains("/") {
                        names.insert(name)
                    }
                }
            }
        } catch {
            throw S3DestinationError.list(error)
        }
        return names
    }

    public func availableCapacity() throws -> Int64? { nil }

    public func store(file: URL, name: String, asset: Asset) async throws {
        let key = S3Rules.objectKey(prefix: prefix, name: name)
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if size <= Self.singlePutLimit {
                _ = try await client.putObject(input: PutObjectInput(
                    body: .data(try Data(contentsOf: file)),
                    bucket: bucket,
                    contentType: S3Rules.contentType(forFilename: name),
                    ifNoneMatch: "*",
                    key: key,
                    metadata: S3Rules.metadata(for: asset),
                    serverSideEncryption: options.sse.flatMap(S3ClientTypes.ServerSideEncryption.init(rawValue:)),
                    ssekmsKeyId: options.kmsKeyID,
                    storageClass: options.storageClass.flatMap(S3ClientTypes.StorageClass.init(rawValue:))
                ))
            } else {
                try await multipartUpload(file: file, key: key, name: name, asset: asset)
            }
        } catch where Self.isPreconditionFailed(error) {
            // The object exists. The pre-scan can miss a concurrent upload.
            return
        } catch {
            throw S3DestinationError.upload(key: key, error)
        }
    }

    private func multipartUpload(file: URL, key: String, name: String, asset: Asset) async throws {
        let create = try await client.createMultipartUpload(input: CreateMultipartUploadInput(
            bucket: bucket,
            contentType: S3Rules.contentType(forFilename: name),
            key: key,
            metadata: S3Rules.metadata(for: asset),
            serverSideEncryption: options.sse.flatMap(S3ClientTypes.ServerSideEncryption.init(rawValue:)),
            ssekmsKeyId: options.kmsKeyID,
            storageClass: options.storageClass.flatMap(S3ClientTypes.StorageClass.init(rawValue:))
        ))
        guard let uploadID = create.uploadId else {
            throw S3DestinationError.upload(key: key, URLError(.badServerResponse))
        }
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var parts: [S3ClientTypes.CompletedPart] = []
            var number = 1
            while let data = try handle.read(upToCount: Self.partSize), !data.isEmpty {
                try Task.checkCancellation()
                let part = try await client.uploadPart(input: UploadPartInput(
                    body: .data(data), bucket: bucket, key: key, partNumber: number, uploadId: uploadID
                ))
                parts.append(S3ClientTypes.CompletedPart(eTag: part.eTag, partNumber: number))
                number += 1
            }
            _ = try await client.completeMultipartUpload(input: CompleteMultipartUploadInput(
                bucket: bucket,
                ifNoneMatch: "*",
                key: key,
                multipartUpload: S3ClientTypes.CompletedMultipartUpload(parts: parts),
                uploadId: uploadID
            ))
        } catch {
            _ = try? await client.abortMultipartUpload(input: AbortMultipartUploadInput(bucket: bucket, key: key, uploadId: uploadID))
            throw error
        }
    }

    /// Spike 3 found that the SDK reports the 412 as a service error with
    /// the code `PreconditionFailed`.
    static func isPreconditionFailed(_ error: Error) -> Bool {
        if let serviceError = error as? any AWSServiceError, serviceError.errorCode == "PreconditionFailed" {
            return true
        }
        return String(describing: error).contains("PreconditionFailed")
    }
}

/// Reads the region of a profile from `~/.aws/config`, because the S3
/// client needs a region before it can resolve one itself.
enum AWSConfigFile {
    static func region(profile: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let name = profile ?? environment["AWS_PROFILE"] ?? "default"
        let path = environment["AWS_CONFIG_FILE"] ?? URL.homeDirectory.appending(path: ".aws/config").path(percentEncoded: false)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return region(in: text, profile: name)
    }

    static func region(in text: String, profile: String) -> String? {
        let wanted = profile == "default" ? ["default", "profile default"] : ["profile \(profile)"]
        var inSection = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: .whitespaces)
                inSection = wanted.contains(section)
                continue
            }
            guard inSection, let equals = line.firstIndex(of: "=") else { continue }
            if line[..<equals].trimmingCharacters(in: .whitespaces) == "region" {
                return line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
