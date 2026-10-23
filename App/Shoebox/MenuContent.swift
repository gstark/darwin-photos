import AppKit
import ShoeboxCore
import SwiftUI

/// The content of the menu bar window.
struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.permissions.complete {
                Label("Shoebox needs permissions to back up.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Finish Setup…") { open(SetupView.windowID) }
                    .buttonStyle(.borderedProminent)
                Divider()
            }

            if model.isRunning {
                RunProgressView(progress: model.progress)
            } else {
                // Relative times go stale while the menu stays open or hidden.
                TimelineView(.everyMinute) { _ in
                    VStack(alignment: .leading, spacing: 10) {
                        LastRunView(run: model.lastRun)
                        if model.waitReasons.isEmpty {
                            Text(nextRunLine)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !model.waitReasons.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A scheduled backup is waiting:")
                        ForEach(model.waitReasons, id: \.description) { Text($0.description) }
                    }
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
            }

            if let failures = model.failureCount, failures > 0 {
                Text("\(failures.formatted()) recorded failures")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if model.isRunning {
                Button("Cancel Backup", role: .cancel) { model.cancel() }
                    .frame(maxWidth: .infinity)
            } else {
                Button("Back Up Now") { model.backUpNow() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(!model.permissions.complete)
            }

            Divider()
            if let waiting = model.lastRun?.waitingForSignIn, waiting > 0 {
                MenuRow("Sign In to iCloud…") { open(LoginView.windowID) }
            }
            MenuRow("Show History…") { open(HistoryView.windowID) }
            MenuRow("Show Failures…") { open(FailuresView.windowID) }
            MenuRow("Settings…") {
                openSettings()
                NSApp.activate()
            }
            Divider()
            MenuRow("Quit Shoebox") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300)
    }

    private var nextRunLine: String {
        guard let next = model.nextRun else { return "Scheduled backups are off" }
        if next <= Date() { return "Next backup: due now" }
        return "Next backup: " + Self.nextRunFormatter.string(from: next)
    }

    /// "Tomorrow at 1:00 AM", or a date for later days.
    private static let nextRunFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
    }
}

/// The stage, a progress bar, and the counts of the run in progress.
private struct RunProgressView: View {
    let progress: AppModel.Progress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            if let fraction = progress.fraction {
                ProgressView(value: min(fraction, 1))
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            ForEach(details, id: \.self) { line in
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var title: String {
        switch progress.stage {
        case .copyingLocal: "Copying local photos"
        case .downloadingCloud: "Downloading cloud-only photos"
        case nil: progress.libraryCount == nil ? "Scanning library…" : "Scanning destination…"
        }
    }

    private var details: [String] {
        var lines: [String] = []
        guard progress.stage != nil else {
            if let count = progress.libraryCount {
                lines.append("\(count.formatted()) photos in the library")
            }
            return lines
        }
        lines.append("\(progress.done.formatted()) of \(progress.total.formatted()) photos")
        if progress.bytesTotal > 0 {
            lines.append("\(bytes(progress.bytesDone)) of \(bytes(progress.bytesTotal))")
        }
        var speed: [String] = []
        if let rate = progress.bytesPerSecond {
            speed.append("\(bytes(Int64(rate)))/s")
        }
        if let seconds = progress.secondsLeft {
            speed.append(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)) + " left")
        }
        if !speed.isEmpty {
            lines.append(speed.joined(separator: " · "))
        }
        if let plan = progress.plan, plan.localCount > 0, plan.cloudCount > 0 {
            lines.append("Total: \(plan.localCount.formatted()) local, \(plan.cloudCount.formatted()) cloud-only")
        }
        if progress.failed > 0 {
            lines.append("\(progress.failed.formatted()) failed in this run")
        }
        return lines
    }

    private func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }
}

/// The result of the last run.
private struct LastRunView: View {
    let run: RunRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: String {
        guard let run else { return "No backup yet" }
        let time = run.finishedAt.formatted(.relative(presentation: .named))
        return switch run.outcome {
        case .succeeded: "Last backup: \(time)"
        case .cancelled: "Backup cancelled \(time)"
        case .failed: "Backup failed \(time)"
        }
    }

    private var detail: String? {
        guard let run else { return nil }
        switch run.outcome {
        case .succeeded:
            var parts = ["\(run.stored.formatted()) new"]
            if run.failed > 0 { parts.append("\(run.failed.formatted()) failed") }
            if run.waitingForSignIn > 0 { parts.append("\(run.waitingForSignIn.formatted()) wait for iCloud sign-in") }
            return parts.joined(separator: " · ")
        case .cancelled:
            return nil
        case .failed(let reason):
            return reason
        }
    }
}

/// A full-width button that looks like a menu item.
private struct MenuRow: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(hovering ? Color.accentColor : .clear, in: .rect(cornerRadius: 5))
                .foregroundStyle(hovering ? .white : .primary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
