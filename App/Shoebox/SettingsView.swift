import AppKit
import ShoeboxCore
import ShoeboxS3
import ServiceManagement
import SwiftUI

/// Edits ~/.shoebox/config.json. The CLI reads the same file.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// One draft for all tabs, so that Save in one tab keeps the edits in the other.
    @State private var draft = SettingsDraft()

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Destination", systemImage: "externaldrive") {
                DestinationSettings(draft: draft)
            }
            Tab("Schedule", systemImage: "calendar.badge.clock") {
                ScheduleSettings(draft: draft)
            }
            Tab("Backup", systemImage: "slider.horizontal.3") {
                BackupSettings(draft: draft)
            }
            Tab("iCloud", systemImage: "icloud") {
                ICloudSettings()
            }
        }
        .frame(width: 520)
        .onAppear {
            if !draft.hasChanges { draft.reload() }
        }
        .onChange(of: draft.saved) { model.reloadSchedule() }
    }
}

/// A copy of the settings that the user edits. Save writes it to config.json.
@MainActor
@Observable
final class SettingsDraft {
    enum Kind: String, CaseIterable, Identifiable {
        case folder = "Folder"
        case s3 = "Amazon S3"
        var id: Self { self }
    }

    var kind = Kind.folder
    var folder = ""
    var bucket = ""
    var prefix = ""
    var profile = ""
    var region = ""
    var endpoint = ""
    var forcePathStyle = false
    var sse = ""
    var kmsKeyID = ""
    var storageClass = ""
    var workers = 4
    var retryFailed = false
    /// The access key in the Keychain. Empty fields mean the AWS profile.
    var useAccessKey = false
    var accessKeyID = ""
    var accessKeySecret = ""
    private(set) var savedAccessKey: AccessKey?
    var frequency = Schedule.Frequency.off
    /// Only the time of these dates matters.
    var windowStart = Date()
    var windowEnd = Date()
    var requirePower = true
    var skipExpensiveNetwork = true
    var onMount = true
    var wifiNetworks: [String] = []

    private(set) var saved = ShoeboxCore.Settings()
    var loadError: String?
    var saveError: String?

    init() {
        reload()
    }

    func reload() {
        do {
            saved = try ShoeboxCore.Settings.load()
            loadError = nil
        } catch {
            saved = ShoeboxCore.Settings()
            loadError = String(describing: error)
        }
        do {
            savedAccessKey = try AccessKeyStore().load()
        } catch {
            savedAccessKey = nil
            loadError = String(describing: error)
        }
        useAccessKey = savedAccessKey != nil
        accessKeyID = savedAccessKey?.id ?? ""
        accessKeySecret = savedAccessKey?.secret ?? ""
        let destination = saved.destination ?? ""
        if let (bucket, prefix) = try? S3Rules.parse(destination) {
            kind = .s3
            self.bucket = bucket
            self.prefix = prefix
            folder = ""
        } else {
            kind = .folder
            folder = destination
            bucket = ""
            prefix = ""
        }
        let s3 = saved.s3 ?? ShoeboxCore.Settings.S3()
        profile = s3.profile ?? ""
        region = s3.region ?? ""
        endpoint = s3.endpoint ?? ""
        forcePathStyle = s3.forcePathStyle == true
        sse = s3.sse ?? ""
        kmsKeyID = s3.kmsKeyID ?? ""
        storageClass = s3.storageClass ?? ""
        workers = saved.workers ?? 4
        retryFailed = saved.retryFailed == true
        let rules = ScheduleRules(saved.schedule ?? Schedule())
        frequency = rules.frequency
        windowStart = Self.date(rules.windowStart)
        windowEnd = Self.date(rules.windowEnd)
        let schedule = saved.schedule ?? Schedule()
        requirePower = schedule.requirePowerEnabled
        skipExpensiveNetwork = schedule.skipExpensiveNetworkEnabled
        onMount = schedule.onMountEnabled
        wifiNetworks = schedule.allowedWiFi
        saveError = nil
    }

    /// The settings that Save writes. Empty fields remove their keys.
    var edited: ShoeboxCore.Settings {
        var settings = saved
        switch kind {
        case .folder:
            settings.destination = nonEmpty(folder)
        case .s3:
            let bucket = bucket.trimmingCharacters(in: .whitespaces)
            let prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            settings.destination = bucket.isEmpty ? nil : "s3://\(bucket)/" + (prefix.isEmpty ? "" : prefix + "/")
        }
        var s3 = ShoeboxCore.Settings.S3()
        s3.profile = nonEmpty(profile)
        s3.region = nonEmpty(region)
        s3.endpoint = nonEmpty(endpoint)
        s3.forcePathStyle = forcePathStyle ? true : nil
        s3.sse = nonEmpty(sse)
        s3.kmsKeyID = sse == "aws:kms" ? nonEmpty(kmsKeyID) : nil
        s3.storageClass = nonEmpty(storageClass)
        settings.s3 = s3 == ShoeboxCore.Settings.S3() ? nil : s3
        // Keep "workers" out of the file while it has the default value.
        settings.workers = workers == 4 && saved.workers == nil ? nil : workers
        settings.retryFailed = retryFailed ? true : (saved.retryFailed == nil ? nil : false)
        // Keep defaults out of the file until the user changes them.
        let old = saved.schedule
        var schedule = old ?? Schedule()
        schedule.frequency = frequency == .off && old?.frequency == nil ? nil : frequency
        let start = Self.time(windowStart)
        let end = Self.time(windowEnd)
        schedule.windowStart = start == Schedule.defaultWindowStart && old?.windowStart == nil ? nil : start.description
        schedule.windowEnd = end == Schedule.defaultWindowEnd && old?.windowEnd == nil ? nil : end.description
        schedule.requirePower = requirePower && old?.requirePower == nil ? nil : requirePower
        schedule.skipExpensiveNetwork = skipExpensiveNetwork && old?.skipExpensiveNetwork == nil ? nil : skipExpensiveNetwork
        schedule.onMount = onMount && old?.onMount == nil ? nil : onMount
        schedule.wifiNetworks = wifiNetworks.isEmpty && old?.wifiNetworks == nil ? nil : wifiNetworks
        settings.schedule = schedule == Schedule() ? nil : schedule
        return settings
    }

    private static func date(_ time: TimeOfDay) -> Date {
        Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date())!
    }

    private static func time(_ date: Date) -> TimeOfDay {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    /// The key that Save writes. Nil removes the key from the Keychain.
    var editedAccessKey: AccessKey? {
        guard useAccessKey, let id = nonEmpty(accessKeyID), let secret = nonEmpty(accessKeySecret) else { return nil }
        return AccessKey(id: id, secret: secret)
    }

    var hasChanges: Bool { edited != saved || editedAccessKey != savedAccessKey }

    func save() {
        do {
            try edited.save()
            if let key = editedAccessKey {
                try AccessKeyStore().save(key)
            } else if savedAccessKey != nil {
                try AccessKeyStore().delete()
            }
            reload()
        } catch {
            saveError = String(describing: error)
        }
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct DestinationSettings: View {
    @Bindable var draft: SettingsDraft
    @State private var test: TestState = .idle

    enum TestState: Equatable {
        case idle
        case running
        case passed
        case failed(String)
    }

    var body: some View {
        Form {
            if let error = draft.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Picker("Back up to", selection: $draft.kind) {
                ForEach(SettingsDraft.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch draft.kind {
            case .folder:
                folderSection
            case .s3:
                s3Sections
            }

            Section {
                HStack {
                    testResult
                    Spacer()
                    Button("Test Connection", action: runTest)
                        .disabled(test == .running || draft.edited.destination == nil)
                    Button("Revert") { draft.reload(); test = .idle }
                        .disabled(!draft.hasChanges)
                    Button("Save") { draft.save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draft.hasChanges)
                }
                if let error = draft.saveError {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: draft.edited) { test = .idle }
        .onChange(of: draft.editedAccessKey) { test = .idle }
    }

    private var folderSection: some View {
        Section {
            HStack {
                TextField("Folder", text: $draft.folder, prompt: Text("/Volumes/Backup/Photos"))
                Button("Choose…", action: chooseFolder)
            }
        } footer: {
            Text("Each photo is saved as <UUID>.<extension>. A backup copies only the photos that the folder does not have yet.")
        }
    }

    @ViewBuilder
    private var s3Sections: some View {
        Section {
            TextField("Bucket", text: $draft.bucket, prompt: Text("my-photos-bucket"))
            TextField("Prefix", text: $draft.prefix, prompt: Text("backup"))
        } footer: {
            if let destination = draft.edited.destination {
                Text("Objects are saved as \(destination)<UUID>.<extension>. Uploads never replace an object.")
            }
        }
        Section {
            Picker("Sign in with", selection: $draft.useAccessKey) {
                Text("AWS profile").tag(false)
                Text("Access key").tag(true)
            }
            if draft.useAccessKey {
                TextField("Access key ID", text: $draft.accessKeyID, prompt: Text("AKIA…"))
                SecureField("Secret access key", text: $draft.accessKeySecret)
            } else {
                TextField("AWS profile", text: $draft.profile, prompt: Text("default"))
            }
            TextField("Region", text: $draft.region, prompt: Text("From the profile"))
        } header: {
            Text("Credentials")
        } footer: {
            Text(draft.useAccessKey
                ? "The key is saved in the Keychain. Use the key of a backup user that can only list the bucket and add objects. scripts/create-backup-iam-user.sh creates one. The command-line tool still uses the AWS profile."
                : "A profile that asks a password manager for credentials can make scheduled backups fail while the password manager is locked.")
        }
        Section("Encryption and storage") {
            Picker("Server-side encryption", selection: $draft.sse) {
                Text("Bucket default").tag("")
                Text("SSE-S3 (AES256)").tag("AES256")
                Text("SSE-KMS").tag("aws:kms")
            }
            if draft.sse == "aws:kms" {
                TextField("KMS key ID", text: $draft.kmsKeyID, prompt: Text("Bucket default key"))
            }
            Picker("Storage class", selection: $draft.storageClass) {
                Text("Standard").tag("")
                ForEach(["STANDARD_IA", "ONEZONE_IA", "INTELLIGENT_TIERING", "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE"], id: \.self) {
                    Text($0).tag($0)
                }
                if !["", "STANDARD_IA", "ONEZONE_IA", "INTELLIGENT_TIERING", "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE"].contains(draft.storageClass) {
                    Text(draft.storageClass).tag(draft.storageClass)
                }
            }
        }
        Section("S3-compatible service") {
            TextField("Endpoint", text: $draft.endpoint, prompt: Text("AWS"))
            Toggle("Path-style addressing", isOn: $draft.forcePathStyle)
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch test {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .passed:
            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(3)
                .help(message)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if !draft.folder.isEmpty {
            panel.directoryURL = URL(filePath: draft.folder)
        }
        if panel.runModal() == .OK, let url = panel.url {
            draft.folder = url.path(percentEncoded: false)
        }
    }

    /// Opens the edited destination without saving it. For S3, this lists
    /// the bucket with the credentials.
    private func runTest() {
        let settings = draft.edited
        guard let target = settings.destination else { return }
        var options = S3Options(config: settings.s3 ?? ShoeboxCore.Settings.S3())
        options.accessKey = draft.editedAccessKey
        test = .running
        Task {
            do {
                _ = try await openDestination(target, s3: options)
                test = .passed
            } catch {
                test = .failed(String(describing: error))
            }
        }
    }
}

private struct BackupSettings: View {
    @Bindable var draft: SettingsDraft

    var body: some View {
        Form {
            Section {
                Stepper("Parallel transfers: \(draft.workers)", value: $draft.workers, in: 1...16)
            } footer: {
                Text("The number of photos that copy, download, or upload at the same time.")
            }
            Section {
                Toggle("Retry failed photos on each backup", isOn: $draft.retryFailed)
            } footer: {
                Text("When this is off, a backup skips photos that failed before. Show Failures lists them.")
            }
            Section {
                HStack {
                    Spacer()
                    Button("Revert") { draft.reload() }
                        .disabled(!draft.hasChanges)
                    Button("Save") { draft.save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draft.hasChanges)
                }
                if let error = draft.saveError {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ICloudSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let account = model.account
        Form {
            Section {
                LabeledContent("Status") { status(account.state) }
                if let session = account.session {
                    LabeledContent("Saved", value: session.savedAt.formatted(date: .abbreviated, time: .shortened))
                }
            } footer: {
                Text("Most cloud-only photos download through Photos and need no sign-in. Only photos that Photos cannot see, such as hidden photos, need an iCloud session. The command-line tool uses the same session.")
            }
            Section {
                HStack {
                    if account.isSignedIn {
                        Button("Sign Out", role: .destructive) { account.signOut() }
                        Spacer()
                        Button("Check Session") { Task { await account.check() } }
                            .disabled(account.state == .checking)
                    } else {
                        Spacer()
                    }
                    Button(account.isSignedIn ? "Sign In Again…" : "Sign In…") {
                        openWindow(id: LoginView.windowID)
                        NSApp.activate()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { account.reload() }
    }

    @ViewBuilder
    private func status(_ state: ICloudAccount.State) -> some View {
        switch state {
        case .signedOut:
            Text("Not signed in")
        case .unchecked:
            Text("Signed in")
        case .checking:
            ProgressView().controlSize(.small)
        case .valid:
            Label("Session works", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .invalid(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(3)
                .help(message)
        }
    }
}

private struct ScheduleSettings: View {
    @Bindable var draft: SettingsDraft
    @Environment(AppModel.self) private var model
    @State private var newNetwork = ""
    @State private var wifiMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("Back up automatically", selection: $draft.frequency) {
                    Text("Off").tag(Schedule.Frequency.off)
                    Text("Every day").tag(Schedule.Frequency.daily)
                    Text("Every week").tag(Schedule.Frequency.weekly)
                }
            }
            if draft.frequency != .off {
                Section {
                    DatePicker("Start after", selection: $draft.windowStart, displayedComponents: .hourAndMinute)
                    DatePicker("Preferred end", selection: $draft.windowEnd, displayedComponents: .hourAndMinute)
                } header: {
                    Text("Time window")
                } footer: {
                    Text("Backups start in this window when the Mac is awake. If the Mac sleeps through the window, the backup starts soon after the Mac wakes. A backup that you start yourself, or with the command-line tool, also counts.")
                }
                Section {
                    Toggle("Only on power adapter", isOn: $draft.requirePower)
                    Toggle("Not on hotspots or Low Data Mode networks", isOn: $draft.skipExpensiveNetwork)
                    if draft.kind == .folder {
                        Toggle("Check when the backup drive connects", isOn: $draft.onMount)
                    }
                } header: {
                    Text("Conditions")
                } footer: {
                    Text("A scheduled backup waits until these conditions are true. Back Up Now ignores them.")
                }
                wifiSection
            }
            Section {
                HStack {
                    Spacer()
                    Button("Revert") { draft.reload() }
                        .disabled(!draft.hasChanges)
                    Button("Save") { draft.save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draft.hasChanges)
                }
                if let error = draft.saveError {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var wifiSection: some View {
        Section {
            ForEach(draft.wifiNetworks, id: \.self) { name in
                HStack {
                    Label(name, systemImage: "wifi")
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") {
                        draft.wifiNetworks.removeAll { $0 == name }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Network name", text: $newNetwork)
                    .onSubmit(addTypedNetwork)
                Button("Add", action: addTypedNetwork)
                    .disabled(newNetwork.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Add Current Network", action: addCurrentNetwork)
            }
            if let wifiMessage {
                Text(wifiMessage).foregroundStyle(.secondary)
            }
        } header: {
            Text("Allowed Wi-Fi networks")
        } footer: {
            Text("With networks in this list, scheduled backups run only on these Wi-Fi networks or on a wired connection. An empty list allows every network. macOS gives the network name only with Location Services permission. Shoebox does not use your location.")
        }
    }

    private func add(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !draft.wifiNetworks.contains(name) else { return }
        draft.wifiNetworks.append(name)
    }

    private func addTypedNetwork() {
        add(newNetwork)
        newNetwork = ""
    }

    private func addCurrentNetwork() {
        let monitor = model.monitor
        guard monitor.locationAllowed else {
            monitor.requestLocationAccess()
            wifiMessage = "Allow Location Services for Shoebox, then click Add Current Network again."
            return
        }
        guard let name = monitor.wifiName else {
            wifiMessage = "The Mac is not on a Wi-Fi network."
            return
        }
        add(name)
        wifiMessage = nil
    }
}

/// Settings that only the app uses. They apply at once.
private struct GeneralSettings: View {
    @AppStorage(Notifier.levelKey) private var notifications = Notifier.Level.problems
    @State private var loginItem = SMAppService.mainApp.status
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Start Shoebox at login", isOn: Binding(
                    get: { loginItem == .enabled || loginItem == .requiresApproval },
                    set: setStartAtLogin
                ))
                if loginItem == .requiresApproval {
                    HStack {
                        Text("Allow Shoebox in Login Items to finish.")
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginItemError {
                    Text(loginItemError).foregroundStyle(.red)
                }
            } footer: {
                Text("Scheduled backups run only while Shoebox is open.")
            }
            Section {
                Picker("Notifications", selection: $notifications) {
                    ForEach(Notifier.Level.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Problems are failed backups, photos that failed, and photos that wait for an iCloud sign-in.")
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem = SMAppService.mainApp.status }
    }

    private func setStartAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        loginItem = SMAppService.mainApp.status
    }
}
