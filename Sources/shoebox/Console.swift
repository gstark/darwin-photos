import ArgumentParser
import Foundation
import Synchronization

/// Unbuffered terminal output, so partial lines and progress bars appear at once.
enum Console {
    static func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    static func line(_ text: String = "") {
        write(text + "\n")
    }
}

/// A one-line progress bar that redraws in place, ported from cmd/progress.go.
struct ProgressBar {
    let total: Int
    let totalBytes: Int64
    let width = 30
    let start = Date()

    func draw(done: Int, bytesDone: Int64) {
        Console.write("\r" + render(done: done, bytesDone: bytesDone).padding(toLength: 100, withPad: " ", startingAt: 0))
    }

    func render(done: Int, bytesDone: Int64) -> String {
        let fraction = totalBytes > 0 ? Double(bytesDone) / Double(totalBytes) : (total > 0 ? Double(done) / Double(total) : 1)
        let clamped = min(max(fraction, 0), 1)
        let filled = Int(clamped * Double(width))
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)

        var extra = ""
        let elapsed = Date().timeIntervalSince(start)
        if bytesDone > 0, elapsed > 0 {
            extra = " \(formatBytes(Int64(Double(bytesDone) / elapsed)))/s"
            if bytesDone < totalBytes {
                extra += " ETA \(formatDuration(elapsed / Double(bytesDone) * Double(totalBytes - bytesDone)))"
            }
        }
        let stats = "\(formatBytes(bytesDone))/\(formatBytes(totalBytes)) (\(done)/\(total))"
        return "[\(bar)] \(stats) (\(Int((clamped * 100).rounded()))%)\(extra)"
    }
}

/// `45s`, `3m12s`, or `2h5m`, as the Go tool formats durations.
func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m\(s % 60)s" }
    return "\(s / 3600)h\((s / 60) % 60)m"
}

/// Runs `body`. The first Ctrl-C calls `stop`, so the run can finish the
/// files in progress and remove its temporary files. A second Ctrl-C quits
/// at once.
func withInterruptHandler<T>(stop: @escaping @Sendable () -> Void, _ body: () async throws -> T) async throws -> T {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue(label: "shoebox.interrupt"))
    let interrupted = Mutex(false)
    source.setEventHandler {
        if interrupted.withLock({ value in defer { value = true }; return value }) {
            exit(130)
        }
        Console.line("\nStopping after the files in progress. Press Ctrl-C again to quit at once.")
        stop()
    }
    source.resume()
    defer {
        source.cancel()
        signal(SIGINT, SIG_DFL)
    }
    do {
        return try await body()
    } catch is CancellationError {
        Console.line("Interrupted.")
        throw ExitCode(130)
    }
}
