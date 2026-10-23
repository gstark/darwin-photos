import ShoeboxCore
import Foundation

extension S3Options {
    /// The `s3` values from the config file. `AWS_PROFILE` and `AWS_REGION`
    /// (or `AWS_DEFAULT_REGION`) win over the file, as in the Go tool.
    public init(config: Settings.S3, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init()
        let envProfile = environment["AWS_PROFILE"].flatMap { $0.isEmpty ? nil : $0 }
        profile = envProfile == nil ? config.profile : nil
        let envRegion = (environment["AWS_REGION"] ?? environment["AWS_DEFAULT_REGION"]).flatMap { $0.isEmpty ? nil : $0 }
        region = envRegion ?? config.region
        endpoint = config.endpoint
        forcePathStyle = config.forcePathStyle == true
        sse = config.sse
        kmsKeyID = config.kmsKeyID
        storageClass = config.storageClass
    }
}

/// Opens a local folder or an `s3://` URI. An S3 destination is validated
/// before it is returned.
public func openDestination(_ target: String, s3: S3Options) async throws -> any BackupDestination {
    guard target.hasPrefix("s3://") else {
        return try LocalDestination(directory: URL(filePath: target))
    }
    let destination = try S3Destination(uri: target, options: s3)
    try await destination.validate()
    return destination
}
