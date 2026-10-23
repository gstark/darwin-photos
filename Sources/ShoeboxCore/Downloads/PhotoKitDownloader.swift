import Foundation
import Photos

public enum PhotoKitError: Error, CustomStringConvertible {
    case notAuthorized(PHAuthorizationStatus)
    /// PhotoKit does not return the asset. Hidden assets and photos saved
    /// from Messages are examples.
    case notFound(String)
    case noOriginal(String)

    public var description: String {
        switch self {
        case .notAuthorized(let status): "Photos access is not granted (status \(status.rawValue))"
        case .notFound(let uuid): "PhotoKit does not return asset \(uuid)"
        case .noOriginal(let uuid): "PhotoKit has no original resource for \(uuid)"
        }
    }
}

/// Downloads originals through PhotoKit. PhotoKit gets cloud-only originals
/// from iCloud without a web sign-in.
public struct PhotoKitDownloader: Sendable {
    /// Requests Photos access if the user has not answered yet. Only full
    /// access works: limited access does not return the whole library.
    public static func authorize() async throws -> PhotoKitDownloader {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized else { throw PhotoKitError.notAuthorized(status) }
        return PhotoKitDownloader()
    }

    private init() {}

    /// Writes the original resource of the asset to `target`. `target` must
    /// not exist.
    public func download(uuid: String, kind: AssetKind, to target: URL) async throws {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: ["\(uuid)/L0/001"], options: options).firstObject else {
            throw PhotoKitError.notFound(uuid)
        }
        let wanted: PHAssetResourceType = kind == .video ? .video : .photo
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == wanted }) else {
            throw PhotoKitError.noOriginal(uuid)
        }
        let request = PHAssetResourceRequestOptions()
        request.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: target, options: request)
    }
}
