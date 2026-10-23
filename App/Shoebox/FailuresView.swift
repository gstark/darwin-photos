import ShoeboxCore
import SwiftUI

/// The records in failures.db. Backups skip these assets unless
/// "retry_failed" is set.
struct FailuresView: View {
    static let windowID = "failures"

    @Environment(AppModel.self) private var model
    @State private var records: [FailureStore.Record] = []
    @State private var loadError: String?

    var body: some View {
        Table(of: FailureStore.Record.self) {
            TableColumn("Time") { Text($0.lastFailedAt.formatted(date: .omitted, time: .shortened)) }
                .width(min: 70, ideal: 75, max: 90)
            TableColumn("UUID", value: \.uuid)
                .width(min: 260, ideal: 290, max: 320)
            TableColumn("Type", value: \.category.rawValue)
                .width(min: 45, ideal: 50, max: 60)
            TableColumn("Attempts") { Text("\($0.attempts)") }
                .width(min: 55, ideal: 60, max: 70)
            TableColumn("Reason", value: \.reason)
        } rows: {
            ForEach(DayGroup.group(records, date: \.lastFailedAt, now: Date())) { day in
                Section(day.title) {
                    ForEach(day.items) { TableRow($0) }
                }
            }
        }
        .overlay {
            if let loadError {
                ContentUnavailableView("Cannot Read Failures", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if records.isEmpty {
                ContentUnavailableView("No Failures", systemImage: "checkmark.circle")
            }
        }
        .toolbar {
            Button("Reload", systemImage: "arrow.clockwise", action: load)
        }
        .navigationSubtitle("\(records.count) recorded")
        .onAppear(perform: load)
        .onChange(of: model.isRunning) { load() }
    }

    private func load() {
        do {
            records = try FailureStore().list()
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
        model.refreshFailureCount()
    }
}

/// Items from the same day, such as failures or backup runs. The title
/// follows the pattern of Mail and Messages: Today, Yesterday, the weekday
/// for the rest of the past week, then the date.
struct DayGroup<Item>: Identifiable {
    let day: Date
    let title: String
    let items: [Item]

    var id: Date { day }

    /// `items` must be sorted newest first.
    static func group(_ items: [Item], date: (Item) -> Date, now: Date, calendar: Calendar = .current) -> [DayGroup] {
        var groups: [DayGroup] = []
        for item in items {
            let day = calendar.startOfDay(for: date(item))
            if let last = groups.last, last.day == day {
                groups[groups.count - 1] = DayGroup(day: day, title: last.title, items: last.items + [item])
            } else {
                groups.append(DayGroup(day: day, title: title(for: day, now: now, calendar: calendar), items: [item]))
            }
        }
        return groups
    }

    static func title(for day: Date, now: Date, calendar: Calendar) -> String {
        let daysAgo = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: now)).day ?? 0
        switch daysAgo {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2...6: return day.formatted(.dateTime.weekday(.wide))
        default:
            let sameYear = calendar.isDate(day, equalTo: now, toGranularity: .year)
            return sameYear
                ? day.formatted(.dateTime.month(.wide).day())
                : day.formatted(.dateTime.month(.wide).day().year())
        }
    }
}

extension FailureStore.Record: @retroactive Identifiable {
    public var id: String { uuid }
}
