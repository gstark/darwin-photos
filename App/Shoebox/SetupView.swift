import Photos
import SwiftUI

/// Asks for Full Disk Access and Photos access. The app opens this window at
/// launch when a permission is missing.
struct SetupView: View {
    static let windowID = "setup"

    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Shoebox needs two permissions to back up your library.")
                .font(.headline)

            PermissionRow(
                title: "Full Disk Access",
                detail: "Shoebox reads the Photos library database to find every photo, including hidden photos. macOS gives this access only through Full Disk Access.",
                granted: model.permissions.fullDiskAccess
            ) {
                Button("Open Full Disk Access Settings") { Permissions.openFullDiskAccessSettings() }
                Text("Turn on Shoebox in the list. If it is not in the list, click +, then select the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PermissionRow(
                title: "Photos",
                detail: "Shoebox downloads cloud-only originals through Photos. Select Allow Full Access.",
                granted: model.permissions.photosGranted
            ) {
                if model.permissions.photos == .notDetermined {
                    Button("Allow Photos Access") { Task { await model.requestPhotosAccess() } }
                } else {
                    Button("Open Photos Settings") { Permissions.openPhotosSettings() }
                    Text("Select Full Access for Shoebox.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismissWindow(id: Self.windowID) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.permissions.complete)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { model.refreshPermissions() }
    }
}

private struct PermissionRow<Actions: View>: View {
    let title: String
    let detail: String
    let granted: Bool
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title3.weight(.semibold))
                Text(detail).fixedSize(horizontal: false, vertical: true)
                if !granted {
                    actions
                }
            }
        }
    }
}
