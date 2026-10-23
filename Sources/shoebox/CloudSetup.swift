import ShoeboxCore
import Foundation

/// Builds the cloud downloader for `backup`, `export`, and `sync`.
enum CloudSetup {
    /// With `interactive` false, nothing asks for Photos access and the Go
    /// session is not imported. Dry runs use this.
    static func downloader(library: PhotosLibrary, retries: Int, interactive: Bool = true) async -> CloudDownloader {
        let store = KeychainSessionStore()
        guard interactive else {
            return CloudDownloader(library: library, photoKit: nil, iCloud: ICloudAccess(store: store), retries: retries)
        }
        let photoKit = await photoKit()
        do {
            if try store.importGoSessionIfEmpty() {
                Console.line("Imported the iCloud session from \(ShoeboxPaths.goSession.path(percentEncoded: false)) into the Keychain.")
            }
        } catch {
            Console.line("Warning: could not import the Go iCloud session: \(error)")
        }
        return CloudDownloader(library: library, photoKit: photoKit, iCloud: ICloudAccess(store: store), retries: retries)
    }

    static func photoKit() async -> PhotoKitDownloader? {
        do {
            return try await PhotoKitDownloader.authorize()
        } catch {
            Console.line("Warning: \(error). Cloud-only photos download through the iCloud web API only.")
            return nil
        }
    }
}
