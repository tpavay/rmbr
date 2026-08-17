import Foundation

/// The gregorian calendar used for every civil-date decision in the engine.
///
/// Held once so day assignment, boundary arithmetic and formatting cannot silently
/// disagree about first weekday or era.
enum RmbrCalendar {
    static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static let utc = TimeZone(identifier: "UTC") ?? .gmt
}

/// A time as its source expressed it, with the source's own semantics preserved.
///
/// PhotoKit's `creationDate` carries no time zone. Reading it back in a different
/// zone than the one the photograph was taken in shifts its civil date, which is a
/// real and unfixable property of the source (`docs/phase-0-findings.md`, "Time is
/// not one thing"). Storing the local components together with the zone they were
/// read in keeps the original reading stable forever: a later phone-zone change
/// cannot rewrite which day a photograph belongs to (RE-006).
///
/// Core Location and HealthKit timestamps are true instants and use `.absolute`.
enum SourceTime: Sendable, Codable, Hashable {
    /// An instant that is unambiguous in every time zone.
    case absolute(Date)
    /// Local wall-clock components whose originating time zone is unknown, plus the
    /// zone rmbr was in when it first read them.
    case floatingLocal(components: DateComponents, readTimeZoneID: String)

    /// The instant this time denotes, resolved through the zone recorded with it.
    ///
    /// For `.floatingLocal` this is a reading, not a fact: it is what the components
    /// mean *if* the capture happened in `readTimeZoneID`.
    var instant: Date {
        switch self {
        case .absolute(let date):
            return date
        case .floatingLocal(let components, let zoneID):
            let zone = TimeZone(identifier: zoneID) ?? .current
            var resolved = components
            resolved.timeZone = zone
            return RmbrCalendar.calendar(in: zone).date(from: resolved) ?? .distantPast
        }
    }

    /// Whether cross-source ordering against an absolute instant is trustworthy.
    var hasTrustworthyTimeZone: Bool {
        if case .absolute = self { return true }
        return false
    }

    /// Wall-clock components in the zone the value was recorded against.
    func localComponents(defaultTimeZone: TimeZone) -> DateComponents {
        switch self {
        case .absolute(let date):
            return RmbrCalendar.calendar(in: defaultTimeZone)
                .dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        case .floatingLocal(let components, _):
            return components
        }
    }

    /// Builds a floating-local time from an instant read in `timeZone`.
    static func floatingLocal(from instant: Date, readIn timeZone: TimeZone) -> SourceTime {
        let components = RmbrCalendar.calendar(in: timeZone)
            .dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: instant)
        return .floatingLocal(components: components, readTimeZoneID: timeZone.identifier)
    }
}

/// A civil date with no time and no zone of its own.
struct LocalDate: Sendable, Codable, Hashable, Comparable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init?(components: DateComponents) {
        guard let year = components.year, let month = components.month, let day = components.day else {
            return nil
        }
        self.init(year: year, month: month, day: day)
    }

    init(instant: Date, in timeZone: TimeZone) {
        let components = RmbrCalendar.calendar(in: timeZone)
            .dateComponents([.year, .month, .day], from: instant)
        self.init(year: components.year ?? 1, month: components.month ?? 1, day: components.day ?? 1)
    }

    /// Midnight opening this date in `timeZone`.
    func startOfDay(in timeZone: TimeZone) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = timeZone
        return RmbrCalendar.calendar(in: timeZone).date(from: components) ?? .distantPast
    }

    func adding(days: Int, in timeZone: TimeZone) -> LocalDate {
        let calendar = RmbrCalendar.calendar(in: timeZone)
        let shifted = calendar.date(byAdding: .day, value: days, to: startOfDay(in: timeZone)) ?? .distantPast
        return LocalDate(instant: shifted, in: timeZone)
    }

    var month0: Month { Month(year: year, month: month) }

    static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// A calendar month, the unit the backfill policy buckets history into.
struct Month: Sendable, Codable, Hashable, Comparable, CustomStringConvertible {
    let year: Int
    let month: Int

    /// Months since year 0, so month arithmetic never needs a calendar.
    var ordinal: Int { year * 12 + (month - 1) }

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(ordinal: Int) {
        self.year = ordinal / 12
        self.month = ordinal % 12 + 1
    }

    func adding(months: Int) -> Month { Month(ordinal: ordinal + months) }

    func contains(_ date: LocalDate) -> Bool {
        date.year == year && date.month == month
    }

    static func < (lhs: Month, rhs: Month) -> Bool { lhs.ordinal < rhs.ordinal }

    var description: String { String(format: "%04d-%02d", year, month) }
}
