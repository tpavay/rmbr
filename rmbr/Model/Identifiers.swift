import Foundation

/// A stable identity for a civil day.
///
/// Identity is the civil date plus the time zone the boundary was resolved in, not
/// midnight arithmetic and not a UTC date. Serialising a day in another zone must
/// not move it (RQ-018).
struct DayID: Sendable, Codable, Hashable, Comparable, CustomStringConvertible {
    enum CalendarIdentifier: String, Sendable, Codable, Hashable {
        case gregorian
    }

    let calendar: CalendarIdentifier
    let date: LocalDate
    let homeTimeZoneID: String

    init(date: LocalDate, homeTimeZoneID: String, calendar: CalendarIdentifier = .gregorian) {
        self.calendar = calendar
        self.date = date
        self.homeTimeZoneID = homeTimeZoneID
    }

    var timeZone: TimeZone { TimeZone(identifier: homeTimeZoneID) ?? .current }

    static func < (lhs: DayID, rhs: DayID) -> Bool { lhs.date < rhs.date }

    var description: String { "\(date)@\(homeTimeZoneID)" }
}

/// Identity of a moment inside a day.
///
/// Derived from the durable source references the moment was built from, so an
/// unchanged moment keeps its identity across recompositions (RE-008, RQ-001).
struct MomentID: Sendable, Codable, Hashable, CustomStringConvertible {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }
}

/// Identity of one capture, stable for as long as the asset exists in the library.
struct MediaID: Sendable, Codable, Hashable, Identifiable, CustomStringConvertible {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    var id: String { rawValue }
    var description: String { rawValue }
}

/// Identity of a source record cited as evidence for a displayed fact.
struct EvidenceID: Sendable, Codable, Hashable, CustomStringConvertible {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }
}

/// Identity of a raw coordinate observation.
struct ObservationID: Sendable, Codable, Hashable, CustomStringConvertible {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }
}

/// Identity of a physical place hypothesis: a building, property or bounded feature.
struct PlaceAnchorID: Sendable, Codable, Hashable, CustomStringConvertible {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }
}
