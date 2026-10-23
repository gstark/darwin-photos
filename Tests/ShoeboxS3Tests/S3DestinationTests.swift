import AWSS3
import ShoeboxCore
import Foundation
import Testing
@testable import ShoeboxS3

struct S3RulesTests {
    @Test func parsesTheURI() throws {
        #expect(try S3Rules.parse("s3://bucket/backup/") == ("bucket", "backup"))
        #expect(try S3Rules.parse("s3://bucket") == ("bucket", ""))
        #expect(try S3Rules.parse("s3://bucket/a%20b/c/") == ("bucket", "a b/c"))
        #expect(throws: S3Rules.LocationError.self) { try S3Rules.parse("https://bucket/x") }
        #expect(throws: S3Rules.LocationError.self) { try S3Rules.parse("s3:///x") }
        #expect(throws: S3Rules.LocationError.self) { try S3Rules.parse("s3://bucket/x?y=1") }
        #expect(S3Rules.objectKey(prefix: "backup", name: "U.heic") == "backup/U.heic")
        #expect(S3Rules.objectKey(prefix: "", name: "U.heic") == "U.heic")
    }

    @Test func contentTypes() {
        #expect(S3Rules.contentType(forFilename: "U.HEIC") == "image/heic")
        #expect(S3Rules.contentType(forFilename: "U.jpeg") == "image/jpeg")
        #expect(S3Rules.contentType(forFilename: "U.mov") == "video/quicktime")
        #expect(S3Rules.contentType(forFilename: "U.webp") == "image/webp")
        #expect(S3Rules.contentType(forFilename: "U.unknown-ext") == "application/octet-stream")
    }

    @Test func metadata() {
        let asset = Asset(
            pk: 1, uuid: "U", filename: "U.heic", directory: "U", originalFilename: "IMG_0001.HEIC",
            uniformTypeID: "public.heic", kind: .photo, width: 1, height: 1,
            dateCreated: CoreDataDate(timestamp: 731_764_800.75), dateModified: nil,
            latitude: 0, longitude: 0, duration: 0, favorite: false, hidden: false, trashed: false,
            cloudLocalState: 0, localAvailability: .local, fileSize: 1
        )
        #expect(S3Rules.metadata(for: asset) == [
            "darwin-photos-uuid": "U",
            "date-created": "2024-03-10T12:00:00Z",
            "original-filename": "IMG_0001.HEIC",
        ])
    }

    @Test func optionChecks() {
        var options = S3Options()
        options.sse = "aes"
        #expect(throws: S3DestinationError.self) { try S3Destination.check(options) }
        options.sse = "AES256"
        options.kmsKeyID = "key"
        #expect(throws: S3DestinationError.self) { try S3Destination.check(options) }
        options = S3Options()
        options.endpoint = "ftp://host"
        #expect(throws: S3DestinationError.self) { try S3Destination.check(options) }
        options.endpoint = "http://127.0.0.1:9000"
        #expect(throws: Never.self) { try S3Destination.check(options) }
    }

    @Test func optionsFromTheConfigFile() {
        var config = Settings.S3()
        config.profile = "gstark"
        config.region = "us-east-1"
        config.forcePathStyle = true
        config.storageClass = "STANDARD_IA"

        let fromFile = S3Options(config: config, environment: [:])
        #expect(fromFile.profile == "gstark")
        #expect(fromFile.region == "us-east-1")
        #expect(fromFile.forcePathStyle)
        #expect(fromFile.storageClass == "STANDARD_IA")

        // The environment wins. With AWS_PROFILE set, the SDK reads it itself.
        let fromEnvironment = S3Options(config: config, environment: ["AWS_PROFILE": "other", "AWS_DEFAULT_REGION": "eu-west-1"])
        #expect(fromEnvironment.profile == nil)
        #expect(fromEnvironment.region == "eu-west-1")
    }

    @Test func profileRegionFromTheConfigFile() {
        let text = """
            [default]
            region = us-west-2
            [profile gstark]
            output = json
            region = us-east-2
            """
        #expect(AWSConfigFile.region(in: text, profile: "gstark") == "us-east-2")
        #expect(AWSConfigFile.region(in: text, profile: "default") == "us-west-2")
        #expect(AWSConfigFile.region(in: text, profile: "other") == nil)
    }
}

/// Runs against a local S3 server. `scripts/s3-local-test.sh` starts MinIO
/// and sets the environment.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SHOEBOX_S3_TEST_ENDPOINT"] != nil))
struct S3DestinationIntegrationTests {
    let endpoint = ProcessInfo.processInfo.environment["SHOEBOX_S3_TEST_ENDPOINT"] ?? ""
    let bucket = "shoebox-test-\(UUID().uuidString.lowercased().prefix(8))"

    private func makeDestination(prefix: String = "backup") async throws -> (S3Destination, S3Client) {
        var options = S3Options()
        options.endpoint = endpoint
        options.region = "us-east-1"
        options.forcePathStyle = true
        let config = try await S3Client.S3ClientConfig(region: "us-east-1", forcePathStyle: true, endpoint: endpoint)
        let client = S3Client(config: config)
        _ = try await client.createBucket(input: CreateBucketInput(bucket: bucket))
        return (try S3Destination(uri: "s3://\(bucket)/\(prefix)/", options: options), client)
    }

    private func asset(_ uuid: String) -> Asset {
        Asset(
            pk: 1, uuid: uuid, filename: "\(uuid).mov", directory: "A", originalFilename: "IMG_0001.MOV",
            uniformTypeID: "com.apple.quicktime-movie", kind: .video, width: 1, height: 1,
            dateCreated: CoreDataDate(timestamp: 731_764_800), dateModified: CoreDataDate(timestamp: 731_764_860),
            latitude: 0, longitude: 0, duration: 0, favorite: false, hidden: false, trashed: false,
            cloudLocalState: 0, localAvailability: .local, fileSize: 1
        )
    }

    private func file(bytes: Int, fill: UInt8) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "s3-test-\(UUID().uuidString)")
        try Data(repeating: fill, count: bytes).write(to: url)
        return url
    }

    @Test func uploadsWithMetadataAndNeverReplaces() async throws {
        let (destination, client) = try await makeDestination()
        try await destination.validate()

        try await destination.store(file: try file(bytes: 1000, fill: 1), name: "A.mov", asset: asset("A"))
        let head = try await client.headObject(input: HeadObjectInput(bucket: bucket, key: "backup/A.mov"))
        #expect(head.contentType == "video/quicktime")
        #expect(head.contentLength == 1000)
        #expect(head.metadata?["darwin-photos-uuid"] == "A")
        #expect(head.metadata?["date-created"] == "2024-03-10T12:00:00Z")
        #expect(head.metadata?["date-modified"] == "2024-03-10T12:01:00Z")
        #expect(head.metadata?["original-filename"] == "IMG_0001.MOV")

        // A second upload to the same key gets 412 and counts as success.
        try await destination.store(file: try file(bytes: 5, fill: 2), name: "A.mov", asset: asset("A"))
        let again = try await client.headObject(input: HeadObjectInput(bucket: bucket, key: "backup/A.mov"))
        #expect(again.contentLength == 1000)
    }

    @Test func aStaticAccessKeyReplacesTheProfileChain() async throws {
        _ = try await makeDestination()
        let environment = ProcessInfo.processInfo.environment
        var options = S3Options()
        options.endpoint = endpoint
        options.region = "us-east-1"
        options.forcePathStyle = true
        options.profile = "no-such-profile"
        options.accessKey = AccessKey(id: try #require(environment["AWS_ACCESS_KEY_ID"]), secret: try #require(environment["AWS_SECRET_ACCESS_KEY"]))
        try await S3Destination(uri: "s3://\(bucket)/backup/", options: options).validate()

        options.accessKey?.secret = "wrong"
        await #expect(throws: S3DestinationError.self) {
            try await S3Destination(uri: "s3://\(bucket)/backup/", options: options).validate()
        }
    }

    @Test func largeFilesUseMultipartUpload() async throws {
        let (destination, client) = try await makeDestination()
        let size = S3Destination.singlePutLimit + 3 * 1024 * 1024
        try await destination.store(file: try file(bytes: size, fill: 3), name: "B.mov", asset: asset("B"))
        let head = try await client.headObject(input: HeadObjectInput(bucket: bucket, key: "backup/B.mov"))
        #expect(head.contentLength == size)
        #expect(head.metadata?["darwin-photos-uuid"] == "B")
        #expect(head.eTag?.contains("-") == true)

        // The conditional complete also protects multipart uploads.
        try await destination.store(file: try file(bytes: size, fill: 4), name: "B.mov", asset: asset("B"))
    }

    @Test func existingNamesIgnoresOtherPrefixesAndDeeperKeys() async throws {
        let (destination, client) = try await makeDestination()
        for key in ["backup/A.heic", "backup/B.mov", "backup/sub/C.heic", "other/D.heic", "backupX/E.heic"] {
            _ = try await client.putObject(input: PutObjectInput(body: .data(Data("x".utf8)), bucket: bucket, key: key))
        }
        #expect(try await destination.existingNames() == ["A.heic", "B.mov"])
    }
}
