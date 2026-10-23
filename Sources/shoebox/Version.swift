import ArgumentParser
import Foundation

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the version information"
    )

    func run() {
        print("shoebox \(cliVersion)")
    }
}

/// From the Info.plist that the linker embeds in the binary. The app uses
/// the same version.
let cliVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
