import ShoeboxCore
import Foundation
import Observation

/// The iCloud session in the Keychain. Only assets that PhotoKit cannot see,
/// such as hidden photos, need it.
@MainActor
@Observable
final class ICloudAccount {
    enum State: Equatable {
        case signedOut
        case unchecked
        case checking
        case valid
        case invalid(String)
    }

    private(set) var state = State.signedOut
    private(set) var session: ICloudSession?
    private let store = KeychainSessionStore()

    init() {
        reload()
    }

    var isSignedIn: Bool { session != nil }

    func reload() {
        do {
            session = try store.load()
            state = session == nil ? .signedOut : .unchecked
        } catch {
            session = nil
            state = .invalid(String(describing: error))
        }
    }

    /// Asks Apple if the saved session still works, and saves what setup
    /// discovery returns.
    func check() async {
        guard let session else { return }
        state = .checking
        do {
            self.session = try await validateAndSave(session)
            state = .valid
        } catch {
            state = .invalid(String(describing: error))
        }
    }

    /// Saves the cookies from the login window. Throws if Apple rejects them.
    func signIn(with cookies: [HTTPCookie]) async throws {
        let session = ICloudSession(cookies: cookies.map {
            ICloudSession.Cookie(name: $0.name, value: $0.value, domain: $0.domain)
        })
        self.session = try await validateAndSave(session)
        state = .valid
    }

    func signOut() {
        do {
            try store.delete()
            session = nil
            state = .signedOut
        } catch {
            state = .invalid(String(describing: error))
        }
    }

    private func validateAndSave(_ session: ICloudSession) async throws -> ICloudSession {
        let client = ICloudClient(session: session)
        try await client.validate()
        let validated = await client.session
        try store.save(validated)
        return validated
    }
}
