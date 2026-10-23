import Foundation

/// Formats a byte count with binary units, as `formatBytes` in the Go tool:
/// `512B`, `1.5KB`, `2.0GB`.
func formatBytes(_ bytes: Int64) -> String {
    let unit: Int64 = 1024
    guard bytes >= unit else { return "\(bytes)B" }
    var divisor = unit
    var exponent = 0
    var n = bytes / unit
    while n >= unit {
        divisor *= unit
        exponent += 1
        n /= unit
    }
    let prefixes = Array("KMGTPE")
    return String(format: "%.1f%@B", Double(bytes) / Double(divisor), String(prefixes[exponent]))
}

/// Prints a value as indented JSON.
func printJSON(_ value: some Encodable, sortedKeys: Bool = false) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    if sortedKeys {
        encoder.outputFormatting.insert(.sortedKeys)
    }
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

/// Aligns rows in columns, as Go's tabwriter with padding 2 does. The last
/// cell of each row is not padded.
func formatTable(_ rows: [[String]]) -> String {
    var widths: [Int] = []
    for row in rows {
        for (index, cell) in row.dropLast().enumerated() {
            if index == widths.count { widths.append(0) }
            widths[index] = max(widths[index], cell.count)
        }
    }
    return rows.map { row in
        row.enumerated().map { index, cell in
            index == row.count - 1 ? cell : cell.padding(toLength: widths[index] + 2, withPad: " ", startingAt: 0)
        }.joined()
    }.map { $0 + "\n" }.joined()
}

/// Prints a line to standard error.
func printError(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
