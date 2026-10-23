import AppKit
import SwiftUI

@main
struct ShoeboxApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("Set Up Shoebox", id: SetupView.windowID) {
            SetupView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.permissions.complete ? .suppressed : .presented)

        Settings {
            SettingsView()
                .environment(model)
        }

        Window("Sign In to iCloud", id: LoginView.windowID) {
            LoginView()
                .environment(model)
        }
        .defaultSize(width: 1000, height: 760)

        Window("History", id: HistoryView.windowID) {
            HistoryView()
                .environment(model)
        }
        .defaultSize(width: 900, height: 600)

        Window("Failures", id: FailuresView.windowID) {
            FailuresView()
                .environment(model)
        }
        .defaultSize(width: 820, height: 480)
    }
}

/// The menu bar icon. It also opens the login window when a notification
/// asks for it, because this view exists for the whole life of the app.
private struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.isRunning {
                Image(nsImage: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    ? ActivityIcon.still
                    : ActivityIcon.frames[model.activityFrame])
            } else {
                Image(nsImage: ActivityIcon.idle(needsAttention: model.needsAttention))
            }
        }
        .onChange(of: model.loginWindowRequests) {
            openWindow(id: LoginView.windowID)
            NSApp.activate()
        }
    }
}
