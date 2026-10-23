import Foundation

/// Gets the original of an asset that is not on this Mac.
public protocol AssetDownloading: Sendable {
    /// Writes the original to `target`, which must not exist.
    func download(_ asset: Asset, to target: URL) async throws -> DownloadSource
}

public enum DownloadSource: Sendable, Equatable {
    case photoKit
    case iCloud
}

public enum CloudDownloadError: Error, CustomStringConvertible {
    /// Only the iCloud web API can get the asset, and there is no valid
    /// session. The engine does not record this as a failure, so the next
    /// run after a sign-in tries again.
    case signInRequired(String)
    case noCloudRecord

    public var description: String {
        switch self {
        case .signInRequired(let reason): "iCloud sign-in required: \(reason)"
        case .noCloudRecord: "no supported CloudKit download record"
        }
    }
}

/// Routes each cloud-only asset:
///
/// 1. PhotoKit, if Photos access is granted and PhotoKit returns the asset.
/// 2. The iCloud web API, for assets that PhotoKit cannot see or fails on.
///
/// See "Download routing" in docs/swift-port-plan.md.
public struct CloudDownloader: AssetDownloading {
    public let library: PhotosLibrary
    /// Nil when Photos access is not granted.
    public let photoKit: PhotoKitDownloader?
    public let iCloud: ICloudAccess
    /// Retries for a failed iCloud download.
    public let retries: Int

    public init(library: PhotosLibrary, photoKit: PhotoKitDownloader?, iCloud: ICloudAccess, retries: Int = 3) {
        self.library = library
        self.photoKit = photoKit
        self.iCloud = iCloud
        self.retries = retries
    }

    public func download(_ asset: Asset, to target: URL) async throws -> DownloadSource {
        var photoKitError: Error?
        if let photoKit {
            do {
                try await photoKit.download(uuid: asset.uuid, kind: asset.kind, to: target)
                return .photoKit
            } catch PhotoKitError.notFound {
                // Only the iCloud web API can get it.
            } catch {
                photoKitError = error
                try? FileManager.default.removeItem(at: target)
            }
        }

        guard let record = try library.cloudRecord(uuid: asset.uuid) else {
            throw photoKitError ?? CloudDownloadError.noCloudRecord
        }
        let client: ICloudClient
        do {
            client = try await iCloud.client()
        } catch let error as CloudDownloadError {
            // PhotoKit saw the asset and failed: that error is the real one.
            throw photoKitError ?? error
        }
        do {
            let file = try await client.remoteFile(for: record)
            try await client.download(file, to: target, retries: retries)
            return .iCloud
        } catch let error where ICloudClient.isSessionInvalid(error) {
            await iCloud.invalidate()
            throw photoKitError ?? CloudDownloadError.signInRequired("the iCloud session expired")
        }
    }
}

/// Opens the iCloud session once per run, when the first asset needs it.
public actor ICloudAccess {
    private enum State {
        case unopened
        case opening(Task<ICloudClient, Error>)
        case ready(ICloudClient)
        case unavailable(Error)
    }

    private let store: any SessionStore
    private var state = State.unopened

    public init(store: any SessionStore) {
        self.store = store
    }

    /// Returns a validated client. Throws `CloudDownloadError.signInRequired`
    /// if there is no session or Apple rejects it.
    public func client() async throws -> ICloudClient {
        switch state {
        case .ready(let client):
            return client
        case .unavailable(let error):
            throw error
        case .opening(let task):
            return try await task.value
        case .unopened:
            let store = store
            let task = Task { try await Self.open(store) }
            state = .opening(task)
            do {
                let client = try await task.value
                state = .ready(client)
                return client
            } catch {
                state = .unavailable(error)
                throw error
            }
        }
    }

    /// Marks the session as expired for the rest of the run.
    public func invalidate() {
        state = .unavailable(CloudDownloadError.signInRequired("the iCloud session expired"))
    }

    private static func open(_ store: any SessionStore) async throws -> ICloudClient {
        guard let session = try store.load() else {
            throw CloudDownloadError.signInRequired("not signed in")
        }
        let client = ICloudClient(session: session)
        do {
            try await client.validate()
        } catch let error where ICloudClient.isSessionInvalid(error) {
            throw CloudDownloadError.signInRequired("the iCloud session expired")
        }
        // Keep the service URL and DSID that validate found.
        try? store.save(await client.session)
        return client
    }
}
