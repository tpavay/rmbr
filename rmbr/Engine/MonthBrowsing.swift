import Foundation

/// One month's shape, small enough that a whole life can be drawn at once.
///
/// The years plate stands for every month a person has, so it cannot ask the index a
/// month at a time - filtering the library's dates once per tile is quadratic in the
/// size of a life. This is the projection the survey already implies, kept by month, so
/// a tile costs a dictionary lookup rather than a walk.
struct MonthDensity: Sendable, Hashable {
    let month: Month
    /// Calendar length, so a tile draws February as February.
    let days: Int
    let daysWithCaptures: Set<Int>

    var count: Int { daysWithCaptures.count }
    var isEmpty: Bool { daysWithCaptures.isEmpty }

    func hasCaptures(on day: Int) -> Bool { daysWithCaptures.contains(day) }
}

/// Which months the mosaic may page through, and how full each one is.
///
/// Kept out of `LibraryModel` because none of it needs a photo library, a clock or a
/// main actor: it is arithmetic over a date and a set of dates, and it is tested as such.
enum MonthBrowsing {

    /// Every month a person may page to, newest first.
    ///
    /// The newest is **today's month**, and deliberately not the newest month the index
    /// holds. A capture can be dated after today - taken in a zone ahead of the phone, or
    /// with a wrong clock - and `CaptureIndex` bins it by its own civil day, so the index
    /// can hold a month that has not happened. Life's walk stops at today's month
    /// (`BackfillPolicy.months(today:)`), so paging past it would let the mosaic show a
    /// month Life cannot, and the two surfaces would disagree about which days exist.
    ///
    /// Inside today's month a future-dated capture is still drawn, because
    /// `LifeEntryBuilder.lastDrawableDay` allows it. Only the month ceiling is fixed here.
    ///
    /// A library with nothing in it still browses: today's month alone, every day of it
    /// outlined, which is the truth rather than an empty screen.
    static func months(earliestIndexedDate earliest: LocalDate?, today: LocalDate) -> [Month] {
        let newest = Month(year: today.year, month: today.month)
        guard let earliest else { return [newest] }
        let oldest = min(Month(year: earliest.year, month: earliest.month), newest)
        return stride(from: newest.ordinal, through: oldest.ordinal, by: -1)
            .map(Month.init(ordinal:))
    }

    /// Days with captures, bucketed by month ordinal, in one pass over the library.
    static func density(of datesWithCaptures: some Sequence<LocalDate>) -> [Int: Set<Int>] {
        var byMonth: [Int: Set<Int>] = [:]
        for date in datesWithCaptures {
            byMonth[Month(year: date.year, month: date.month).ordinal, default: []].insert(date.day)
        }
        return byMonth
    }

    /// The years a plate draws, newest first.
    ///
    /// Every year between the oldest and newest browsable month, including the ones that
    /// hold nothing: a year a person took no photographs in is part of their life and the
    /// plate says so with an empty row rather than by skipping it.
    static func years(of months: [Month]) -> [Int] {
        guard let newest = months.first, let oldest = months.last else { return [] }
        guard newest.year >= oldest.year else { return [] }
        return Array(stride(from: newest.year, through: oldest.year, by: -1))
    }
}
