import SwiftUI
import WebKit

/// Signs in to iCloud.com in a web view, then saves the session. The web
/// view keeps nothing on disk. The Keychain holds the only copy.
struct LoginView: View {
    static let windowID = "icloud-login"

    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var login = LoginPage()

    var body: some View {
        VStack(spacing: 0) {
            WebView(login.page)
            Divider()
            HStack(spacing: 8) {
                switch login.state {
                case .waiting:
                    Image(systemName: "person.crop.circle.badge.questionmark")
                    Text("Sign in with your Apple Account. Shoebox saves the session when the sign-in completes.")
                case .saving:
                    ProgressView().controlSize(.small)
                    Text("Checking the session with Apple…")
                case .failed(let message):
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text("Apple rejected the session: \(message)")
                        .lineLimit(2)
                }
                Spacer()
            }
            .font(.callout)
            .padding(10)
        }
        .task {
            await login.run(account: model.account)
            dismissWindow(id: Self.windowID)
        }
    }
}

@MainActor
@Observable
final class LoginPage {
    enum State: Equatable {
        case waiting
        case saving
        case failed(String)
    }

    let page: WebPage
    private(set) var state = State.waiting
    private let dataStore = WKWebsiteDataStore.nonPersistent()

    init() {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        page = WebPage(configuration: configuration)
        // iCloud.com rejects browsers that it does not support.
        page.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    }

    /// Loads iCloud.com and returns when the session is saved, or when the
    /// task is cancelled because the window closed.
    func run(account: ICloudAccount) async {
        page.load(URLRequest(url: URL(string: "https://www.icloud.com/photos/")!))
        // Each new token gets a few attempts, because iCloud can set more
        // cookies after the token.
        var attempts: (token: String, count: Int)?
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            let cookies = await appleCookies()
            guard let token = cookies.first(where: { $0.name == "X-APPLE-WEBAUTH-TOKEN" })?.value else { continue }
            let count = attempts?.token == token ? attempts!.count + 1 : 1
            guard count <= 3 else { continue }
            attempts = (token, count)
            try? await Task.sleep(for: .seconds(2))
            state = .saving
            do {
                try await account.signIn(with: await appleCookies())
                return
            } catch {
                state = .failed(String(describing: error))
            }
        }
    }

    private func appleCookies() async -> [HTTPCookie] {
        let bases = ["apple.com", "icloud.com", "icloud.com.cn", "apple.com.cn"]
        return await dataStore.httpCookieStore.allCookies().filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return bases.contains { domain == $0 || domain.hasSuffix("." + $0) }
        }
    }
}
