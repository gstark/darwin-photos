import ShoeboxCore
import Testing

struct CoreDataDateTests {
    @Test func zeroMeansNoDate() {
        #expect(CoreDataDate(timestamp: 0) == nil)
    }

    @Test func formatsLikeGo() throws {
        let date = try #require(CoreDataDate(timestamp: 86_400))
        #expect(date.iso8601Seconds == "2001-01-02T00:00:00Z")
        #expect(date.rfc3339Nano == "2001-01-02T00:00:00Z")
        #expect(date.dateTime == "2001-01-02 00:00:00")
        #expect(date.shortDateTime == "Jan  2 00:00")
    }

    @Test func fractionalSecondsDropTrailingZeros() throws {
        #expect(try #require(CoreDataDate(timestamp: 86_400.25)).rfc3339Nano == "2001-01-02T00:00:00.25Z")
        #expect(try #require(CoreDataDate(timestamp: 86_400.000001)).rfc3339Nano == "2001-01-02T00:00:00.000001Z")
    }

    @Test func datesBefore2001() throws {
        let date = try #require(CoreDataDate(timestamp: -0.5))
        #expect(date.rfc3339Nano == "2000-12-31T23:59:59.5Z")
        #expect(try #require(CoreDataDate(timestamp: -86_400 * 365)).iso8601Seconds == "2000-01-02T00:00:00Z")
    }

    @Test func outOfRangeTimestampsSaturateLikeGo() throws {
        // Year 1, as some cameras write. Go saturates to the minimum duration.
        let early = try #require(CoreDataDate(timestamp: -63_113_904_000))
        #expect(early.nanoseconds == .min)
        #expect(early.rfc3339Nano == "1708-09-22T00:12:43.145224192Z")

        let late = try #require(CoreDataDate(timestamp: 1e12))
        #expect(late.nanoseconds == .max)
        #expect(late.rfc3339Nano == "2293-04-11T23:47:16.854775807Z")
    }
}
