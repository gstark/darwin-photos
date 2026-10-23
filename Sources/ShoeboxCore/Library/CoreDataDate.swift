import Foundation

/// A Photos.sqlite timestamp: seconds since 2001-01-01 00:00:00 UTC.
///
/// The value keeps whole nanoseconds, as the Go tool does, so that formatted
/// dates match the Go output exactly.
public struct CoreDataDate: Sendable, Hashable, Comparable {
    /// Nanoseconds since 2001-01-01 00:00:00 UTC.
    public var nanoseconds: Int64

    /// Returns nil for 0, which Photos.sqlite uses for "no date".
    ///
    /// Out-of-range values saturate, as Go's float-to-int conversion does on
    /// arm64. Some photos have bogus dates, such as year 1.
    public init?(timestamp seconds: Double) {
        guard seconds != 0 else { return nil }
        let product = seconds * 1e9
        if product.isNaN {
            nanoseconds = 0
        } else if product >= 9.223372036854775807e18 {
            nanoseconds = .max
        } else if product <= -9.223372036854775808e18 {
            nanoseconds = .min
        } else {
            nanoseconds = Int64(product)
        }
    }

    public init(nanoseconds: Int64) {
        self.nanoseconds = nanoseconds
    }

    public init(_ date: Date) {
        self = CoreDataDate(timestamp: date.timeIntervalSinceReferenceDate) ?? CoreDataDate(nanoseconds: 0)
    }

    /// Seconds since 2001-01-01, the value that Photos.sqlite stores.
    public var timestamp: Double { Double(nanoseconds) / 1e9 }

    public var date: Date { Date(timeIntervalSinceReferenceDate: timestamp) }

    /// Seconds since 1970 and the nanosecond remainder, rounded toward
    /// negative infinity.
    var unixParts: (seconds: Int64, nanos: Int64) {
        // Split before adding the epoch offset, so that no step overflows.
        var seconds = nanoseconds / 1_000_000_000 + 978_307_200
        var nanos = nanoseconds % 1_000_000_000
        if nanos < 0 {
            seconds -= 1
            nanos += 1_000_000_000
        }
        return (seconds, nanos)
    }

    public static func < (lhs: CoreDataDate, rhs: CoreDataDate) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
}

extension CoreDataDate {
    private static let utc = TimeZone(identifier: "UTC")!

    private var utcComponents: DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        let date = Date(timeIntervalSince1970: TimeInterval(unixParts.seconds))
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    /// `2006-01-02T15:04:05Z`, in UTC, without fractional seconds.
    public var iso8601Seconds: String {
        let c = utcComponents
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    /// RFC 3339 in UTC with as many fractional digits as needed, as Go
    /// formats a `time.Time` in JSON.
    public var rfc3339Nano: String {
        let base = iso8601Seconds.dropLast()
        let nanos = unixParts.nanos
        guard nanos != 0 else { return base + "Z" }
        var fraction = String(format: "%09lld", nanos)
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return base + "." + fraction + "Z"
    }

    /// `2006-01-02 15:04:05`, in UTC.
    public var dateTime: String {
        let c = utcComponents
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    /// `Jan _2 15:04`, in UTC. The day is padded with a space.
    public var shortDateTime: String {
        let c = utcComponents
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return String(format: "%@ %2d %02d:%02d", months[c.month! - 1], c.day!, c.hour!, c.minute!)
    }
}
