import Foundation
import Testing
@testable import rmbr

/// Which months a person may page to, and what a tile too small for a photograph says.
///
/// The rules that matter here are all about the two ends. The newest end is the one that
/// can lie: a capture is binned by its own civil day, so a photograph taken in a zone
/// ahead of the phone puts a month in the index that has not happened. Life's walk stops
/// at today's month, and if the mosaic did not, the two surfaces would disagree about
/// which days exist (#4, #5).
@Suite("Month browsing")
struct MonthBrowsingTests {
    let today = LocalDate(year: 2026, month: 8, day: 20)

    // MARK: - The two ends

    @Test("The newest month is today's, and the oldest is the library's first")
    func rangeSpansTheLibrary() {
        let months = MonthBrowsing.months(
            earliestIndexedDate: LocalDate(year: 2024, month: 11, day: 3),
            today: today
        )
        #expect(months.first == Month(year: 2026, month: 8))
        #expect(months.last == Month(year: 2024, month: 11))
        // November 2024 through August 2026 inclusive.
        #expect(months.count == 22)
    }

    @Test("Months run newest first, one at a time, with none missing")
    func rangeIsContiguousNewestFirst() {
        let months = MonthBrowsing.months(
            earliestIndexedDate: LocalDate(year: 2025, month: 12, day: 31),
            today: today
        )
        #expect(months == [
            Month(year: 2026, month: 8),
            Month(year: 2026, month: 7),
            Month(year: 2026, month: 6),
            Month(year: 2026, month: 5),
            Month(year: 2026, month: 4),
            Month(year: 2026, month: 3),
            Month(year: 2026, month: 2),
            Month(year: 2026, month: 1),
            Month(year: 2025, month: 12)
        ])
    }

    @Test("A capture dated into next month does not drag the pager past today")
    func futureDatedCaptureDoesNotExtendTheRange() {
        // The index's newest month is September; the phone is still in August. Paging to
        // September would show a month Life cannot draw at all.
        let months = MonthBrowsing.months(
            earliestIndexedDate: LocalDate(year: 2026, month: 3, day: 1),
            today: today
        )
        #expect(months.first == Month(year: 2026, month: 8))
        #expect(!months.contains(Month(year: 2026, month: 9)))
    }

    @Test("A capture dated after today inside today's month is still drawn")
    func futureDatedCaptureInsideTodaysMonthStaysReachable() {
        // The month ceiling is fixed, the day ceiling is not: `lastDrawableDay` is what
        // decides how far into today's month the mosaic draws, and it lets a capture
        // dated ahead of the phone through.
        let month = Month(year: 2026, month: 8)
        let last = LifeEntryBuilder.lastDrawableDay(
            of: month,
            today: today,
            datesWithCaptures: [LocalDate(year: 2026, month: 8, day: 27)]
        )
        #expect(last == 27)
    }

    @Test("A library with nothing in it still browses today's month")
    func emptyLibraryBrowsesTodayAlone() {
        let months = MonthBrowsing.months(earliestIndexedDate: nil, today: today)
        #expect(months == [Month(year: 2026, month: 8)])
    }

    @Test("An earliest date after today collapses to today's month rather than inverting")
    func earliestAfterTodayCollapses() {
        let months = MonthBrowsing.months(
            earliestIndexedDate: LocalDate(year: 2027, month: 1, day: 4),
            today: today
        )
        #expect(months == [Month(year: 2026, month: 8)])
    }

    // MARK: - Density

    @Test("Days with captures are bucketed by the month they fall in")
    func densityBucketsByMonth() {
        let dates = [
            LocalDate(year: 2026, month: 8, day: 2),
            LocalDate(year: 2026, month: 8, day: 2),
            LocalDate(year: 2026, month: 8, day: 19),
            LocalDate(year: 2026, month: 7, day: 30)
        ]
        let density = MonthBrowsing.density(of: dates)
        #expect(density[Month(year: 2026, month: 8).ordinal] == [2, 19])
        #expect(density[Month(year: 2026, month: 7).ordinal] == [30])
        #expect(density[Month(year: 2026, month: 6).ordinal] == nil)
    }

    @Test("A month tile knows its own calendar length")
    func densityCarriesCalendarLength() {
        let february = MonthDensity(
            month: Month(year: 2024, month: 2),
            days: LifeEntryBuilder.daysIn(Month(year: 2024, month: 2)),
            daysWithCaptures: [29]
        )
        #expect(february.days == 29)
        #expect(february.hasCaptures(on: 29))
        #expect(!february.hasCaptures(on: 28))
        #expect(february.count == 1)
    }

    @Test("A month with nothing in it is empty rather than absent")
    func densityOfAQuietMonth() {
        let quiet = MonthDensity(
            month: Month(year: 2019, month: 4),
            days: 30,
            daysWithCaptures: []
        )
        #expect(quiet.isEmpty)
        #expect(quiet.count == 0)
    }

    // MARK: - Years

    @Test("Every year between the ends is drawn, including the ones that hold nothing")
    func yearsIncludeQuietOnes() {
        let months = MonthBrowsing.months(
            earliestIndexedDate: LocalDate(year: 2022, month: 5, day: 9),
            today: today
        )
        #expect(MonthBrowsing.years(of: months) == [2026, 2025, 2024, 2023, 2022])
    }

    @Test("One month is one year")
    func yearsOfASingleMonth() {
        #expect(MonthBrowsing.years(of: [Month(year: 2026, month: 8)]) == [2026])
    }

    @Test("No months is no years rather than a crash")
    func yearsOfNothing() {
        #expect(MonthBrowsing.years(of: []).isEmpty)
    }

    // MARK: - The column key

    @Test("A year's columns are keyed by the locale's own month initials")
    func monthInitialsKeyTheColumns() {
        #expect(DayFormatting.monthInitial(1) == "J")
        #expect(DayFormatting.monthInitial(8) == "A")
        #expect(DayFormatting.monthInitial(12) == "D")
    }

    @Test("A month outside the calendar prints its number rather than crashing")
    func monthInitialOutOfRange() {
        #expect(DayFormatting.monthInitial(0) == "0")
        #expect(DayFormatting.monthInitial(13) == "13")
    }
}
