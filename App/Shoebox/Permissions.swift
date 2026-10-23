import AppKit
import ShoeboxCore
import Photos

/// The two permissions that a backup needs.
struct Permissions: Equatable {
    /// Full Disk Access. Without it, the app cannot read Photos.sqlite.
    var fullDiskAccess: Bool
    var photos: PHAuthorizationStatus

    var photosGranted: Bool { photos == .authorized }
    var complete: Bool { fullDiskAccess && photosGranted }

    static func current() -> Permissions {
        let database = PhotosLibrary.defaultPath + "/database/Photos.sqlite"
        let handle = FileHandle(forReadingAtPath: database)
        try? handle?.close()
        return Permissions(fullDiskAccess: handle != nil, photos: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    static func openPhotosSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
    }
}
