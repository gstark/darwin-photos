import ShoeboxCore
import SwiftUI

/// The runs in history.json, newest first, and the log of the selected run.
struct HistoryView: View {
    static let windowID = "history"

    @Environment(AppModel.self) private var model
    @State private var records: [RunRecord] = []
    @State private var selection: Date?
    private let history = RunHistory()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(DayGroup.group(records, date: \.startedAt, now: Date())) { day in
                    Section(day.title) {
                        ForEach(day.items, id: \.startedAt) { RunRow(run: $0) }
                    }
                }
            }
            .overlay {
                if records.isEmpty {
                    ContentUnavailableView("No Backups", systemImage: "clock.arrow.circlepath")
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let run = records.first(where: { $0.startedAt == selection }) {
                RunDetailView(run: run, history: history)
            } else {
                ContentUnavailableView("Select a Backup", systemImage: "clock.arrow.circlepath")
            }
        }
        .toolbar {
            Button("Reload", systemImage: "arrow.clockwise", action: load)
        }
        .onAppear(perform: load)
        // A run of the app ends. Runs of the CLI need Reload.
        .onChange(of: model.lastRun) { load() }
    }

    private func load() {
        records = history.records().reversed()
        if selection == nil || !records.contains(where: { $0.startedAt == selection }) {
            selection = records.first?.startedAt
        }
    }
}

private struct RunRow: View {
    let run: RunRecord

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(run.startedAt.formatted(date: .omitted, time: .shortened))
                Text(run.shortSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            OutcomeIcon(run: run)
        }
    }
}

/// The summary of a run, then its log.
private struct RunDetailView: View {
    let run: RunRecord
    let history: RunHistory
    @State private var log: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                OutcomeIcon(run: run)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 12) {
                    Text(run.headline)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(run.facts, id: \.label) { fact in
                            GridRow {
                                Text(fact.label)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                Text(fact.value)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(20)
            Divider()
            ScrollView {
                Text(log ?? "This backup has no log.")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(log == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .task(id: run.startedAt) {
            log = history.log(for: run)
        }
    }
}

private struct OutcomeIcon: View {
    let run: RunRecord

    var body: some View {
        switch run.outcome {
        case .succeeded where run.failed > 0 || run.waitingForSignIn > 0:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .cancelled:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

private extension RunRecord {
    var shortSummary: String {
        switch outcome {
        case .succeeded:
            var parts = ["\(stored.formatted()) new"]
            if failed > 0 { parts.append("\(failed.formatted()) failed") }
            return parts.joined(separator: " · ")
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }

    var headline: String {
        let time = finishedAt.formatted(date: .abbreviated, time: .shortened)
        return switch outcome {
        case .succeeded: "Backup finished \(time)"
        case .cancelled: "Backup cancelled \(time)"
        case .failed: "Backup failed \(time)"
        }
    }

    var facts: [(label: String, value: String)] {
        var facts: [(label: String, value: String)] = []
        if let destination {
            facts.append(("Destination:", destination))
        }
        facts.append(("Started by:", trigger.label))
        if case .failed(let reason) = outcome {
            facts.append(("Error:", reason))
        }
        if outcome == .succeeded {
            var stored = "\(self.stored.formatted()) photos"
            if let bytesStored {
                stored += ", " + bytesStored.formatted(.byteCount(style: .file))
            }
            if let copied, let downloaded, copied > 0, downloaded > 0 {
                stored += " (\(copied.formatted()) copied, \(downloaded.formatted()) downloaded)"
            }
            facts.append(("Stored:", stored))
            if failed > 0 {
                facts.append(("Failed:", "\(failed.formatted()) photos"))
            }
            if waitingForSignIn > 0 {
                facts.append(("Waiting:", "\(waitingForSignIn.formatted()) photos need an iCloud sign-in"))
            }
        }
        facts.append(("Duration:", Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))))
        return facts
    }
}

private extension RunRecord.Trigger {
    var label: String {
        switch self {
        case .manual: "Back Up Now"
        case .scheduled: "Schedule"
        case .cli: "Command line"
        }
    }
}
