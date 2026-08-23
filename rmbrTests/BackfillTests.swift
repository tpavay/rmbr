import Foundation
import Testing
@testable import rmbr

@Suite("Backfill scope")
struct BackfillTests {
    let policy = BackfillPolicy(tuning: .v1)

    @Test("The window is 24 calendar month buckets wherever in the month it is evaluated",
          arguments: [1, 15, 31])
    func windowIsMonthBuckets(day: Int) {
        let today = LocalDate(year: 2026, month: 8, day: min(day, 31))
        #expect(policy.months(today: today).count == 24)
        #expect(policy.windowStart(today: today) == Month(year: 2024, month: 9))
        #expect(policy.months(today: today).last == Month(year: 2026, month: 8))
    }

    @Test("A day inside the window is fully composed; an older one waits to be opened")
    func treatmentFollowsTheWindow() {
        let today = LocalDate(year: 2026, month: 8, day: 16)
        #expect(policy.treatment(
            for: LocalDate(year: 2024, month: 9, day: 1), today: today, representatives: []
        ) == .fullyComposed)
        #expect(policy.treatment(
            for: LocalDate(year: 2024, month: 8, day: 31), today: today, representatives: []
        ) == .composeOnOpen)
        #expect(policy.treatment(
            for: LocalDate(year: 2019, month: 4, day: 2),
            today: today,
            representatives: [LocalDate(year: 2019, month: 4, day: 2)]
        ) == .monthlyRepresentative)
    }
}

@Suite("Monthly representative")
struct MonthlyRepresentativeTests {
    let selector = MonthlyRepresentativeSelector(tuning: .v1)
    let month = Month(year: 2019, month: 4)

    private func signals(
        day: Int,
        media: Int = 0,
        favorites: Int = 0,
        moments: Int = 0,
        momentsWithMedia: Int = 0,
        places: [Coordinate] = []
    ) -> DaySignals {
        DaySignals(
            date: LocalDate(year: 2019, month: 4, day: day),
            eligibleMediaCount: media,
            favoriteEligibleMediaCount: favorites,
            momentCount: moments,
            momentsWithMediaCount: momentsWithMedia,
            placeAnchorCentroids: places
        )
    }

    private var emptyArchive: ArchivePlaceIndex {
        ArchivePlaceIndex(mergeDistanceMetres: 25)
    }

    @Test("A month whose only days are thin promotes nobody")
    func poorMonthStaysThin() {
        let days = [
            signals(day: 3),
            signals(day: 9, media: 1, moments: 1, momentsWithMedia: 1)
        ]
        let entry = selector.select(month: month, days: days, archivePlaces: emptyArchive)
        guard case .noRepresentative(_, let reason) = entry else {
            Issue.record("a month of thin days must not promote one")
            return
        }
        #expect(reason == .noQualifyingDay)
    }

    @Test("A favourite beats a higher-volume day without one")
    func favouriteWinsTheFirstTier() {
        let days = [
            signals(day: 4, media: 40, moments: 6, momentsWithMedia: 6),
            signals(day: 20, media: 2, favorites: 1, moments: 2, momentsWithMedia: 2)
        ]
        let entry = selector.select(month: month, days: days, archivePlaces: emptyArchive)
        guard case .representative(let winner) = entry else {
            Issue.record("expected a representative")
            return
        }
        #expect(winner.date.day == 20)
        #expect(winner.reason == .favoriteMedia)
    }

    @Test("A place seen on no other day wins over sheer volume")
    func archiveUniquePlaceWins() {
        let unique = Coordinate(latitude: 48.8584, longitude: 2.2945)
        let familiar = Coordinate(latitude: 41.8757, longitude: -87.6580)
        var archive = emptyArchive
        archive.insert(unique, on: LocalDate(year: 2019, month: 4, day: 12))
        archive.insert(familiar, on: LocalDate(year: 2019, month: 4, day: 5))
        archive.insert(familiar, on: LocalDate(year: 2020, month: 1, day: 5))

        let days = [
            signals(day: 5, media: 30, moments: 5, momentsWithMedia: 5, places: [familiar]),
            signals(day: 12, media: 3, moments: 2, momentsWithMedia: 2, places: [unique])
        ]
        let entry = selector.select(month: month, days: days, archivePlaces: archive)
        guard case .representative(let winner) = entry else {
            Issue.record("expected a representative")
            return
        }
        #expect(winner.date.day == 12)
        #expect(winner.reason == .archiveUniquePlace)
    }

    @Test("The same input always chooses the same date")
    func selectionIsDeterministic() {
        let days = [
            signals(day: 2, media: 6, moments: 3, momentsWithMedia: 3),
            signals(day: 21, media: 6, moments: 3, momentsWithMedia: 3),
            signals(day: 14, media: 6, moments: 3, momentsWithMedia: 3)
        ]
        let forwards = selector.select(month: month, days: days, archivePlaces: emptyArchive)
        let backwards = selector.select(month: month, days: days.reversed(), archivePlaces: emptyArchive)
        #expect(forwards == backwards)
        guard case .representative(let winner) = forwards else {
            Issue.record("expected a representative")
            return
        }
        // Nearest the middle of the month breaks the final tie.
        #expect(winner.date.day == 14)
    }

    @Test("A month with no indexed day is named as empty rather than dropped")
    func emptyMonthIsStillAddressable() {
        let entry = selector.select(month: month, days: [], archivePlaces: emptyArchive)
        #expect(entry == .noRepresentative(month: month, reason: .noIndexedDays))
        #expect(entry.month == month)
    }
}

@Suite("Life scroll")
struct LifeEntryTests {
    @Test("Older months contribute one day each; recent months contribute every day")
    func lifeShapeFollowsTheBackfillRule() {
        let today = LocalDate(year: 2026, month: 8, day: 16)
        var records: [CaptureRecord] = []

        // Two days inside the recent window.
        records.append(Fixture.capture("10:00:00", on: LocalDate(year: 2026, month: 8, day: 2),
                                       in: Fixture.chicago, identifier: "recent-1"))
        records.append(Fixture.capture("11:00:00", on: LocalDate(year: 2026, month: 8, day: 3),
                                       in: Fixture.chicago, identifier: "recent-2"))
        // Four days in one old month, one of them favourited.
        for day in [4, 9, 14, 19] {
            records.append(
                Fixture.capture(
                    "12:00:00", on: LocalDate(year: 2015, month: 5, day: day),
                    in: Fixture.chicago, isFavorite: day == 14, identifier: "old-\(day)"
                )
            )
        }

        let index = CaptureIndex(records: records, timeZone: Fixture.chicago)
        let survey = ArchiveSurveyor.survey(index: index, tuning: .v1)
        let monthEntries = ArchiveSurveyor.monthEntries(
            index: index, survey: survey, today: today, tuning: .v1
        )
        let entries = LifeEntryBuilder.build(
            index: index, monthEntries: monthEntries, today: today, tuning: .v1
        )

        let dayEntries = entries.compactMap { entry -> LocalDate? in
            if case .day(let date, _) = entry { return date }
            return nil
        }
        #expect(dayEntries.filter { $0.year == 2026 }.count == 2)
        // The whole of May 2015 contributes exactly one row.
        #expect(dayEntries.filter { $0.year == 2015 }.count == 1)
        #expect(dayEntries.first(where: { $0.year == 2015 })?.day == 14)
        // Newest first.
        #expect(dayEntries.first?.year == 2026)
        #expect(dayEntries.last?.year == 2015)
    }

    @Test("Inside the window, one empty day keeps a card and a run collapses")
    func emptyDaysAndGaps() {
        let today = LocalDate(year: 2026, month: 8, day: 8)
        // Captures on the 2nd and the 5th only.
        let records = [2, 5].map { day in
            Fixture.capture(
                "12:00:00", on: LocalDate(year: 2026, month: 8, day: day),
                in: Fixture.chicago, identifier: "aug-\(day)"
            )
        }
        let index = CaptureIndex(records: records, timeZone: Fixture.chicago)
        let survey = ArchiveSurveyor.survey(index: index, tuning: .v1)
        let monthEntries = ArchiveSurveyor.monthEntries(
            index: index, survey: survey, today: today, tuning: .v1
        )
        let entries = LifeEntryBuilder.build(
            index: index, monthEntries: monthEntries, today: today, tuning: .v1
        )

        // Newest first: 8-7-6 empty, 5 held, 4-3 empty, 2 held. Nothing before the 2nd,
        // because the library itself does not reach back that far.
        let shape = entries.compactMap { entry -> String? in
            switch entry {
            case .monthHeader: nil
            case .day(let date, _): "day-\(date.day)"
            case .emptyDay(let date): "empty-\(date.day)"
            case .gap(let newest, let oldest, let days): "gap-\(newest.day)-\(oldest.day)-\(days)"
            case .emptyMonth: "thin"
            }
        }
        #expect(shape == ["gap-8-6-3", "day-5", "gap-4-3-2", "day-2"])
    }

    @Test("A single empty day is a card, never a collapsed run")
    func singleEmptyDayKeepsItsCard() {
        let today = LocalDate(year: 2026, month: 8, day: 3)
        let records = [1, 3].map { day in
            Fixture.capture(
                "09:00:00", on: LocalDate(year: 2026, month: 8, day: day),
                in: Fixture.chicago, identifier: "aug-\(day)"
            )
        }
        let index = CaptureIndex(records: records, timeZone: Fixture.chicago)
        let survey = ArchiveSurveyor.survey(index: index, tuning: .v1)
        let entries = LifeEntryBuilder.build(
            index: index,
            monthEntries: ArchiveSurveyor.monthEntries(
                index: index, survey: survey, today: today, tuning: .v1
            ),
            today: today,
            tuning: .v1
        )
        let hasSingleEmptyDay = entries.contains { entry in
            if case .emptyDay(let date) = entry { return date.day == 2 }
            return false
        }
        let hasGap = entries.contains { if case .gap = $0 { true } else { false } }
        #expect(hasSingleEmptyDay)
        #expect(!hasGap)
    }

    @Test("Life stops at the library's first photograph rather than at the window")
    func nothingBeforeTheFirstPhotograph() {
        let today = LocalDate(year: 2026, month: 8, day: 4)
        let records = [
            Fixture.capture(
                "10:00:00", on: LocalDate(year: 2026, month: 8, day: 3),
                in: Fixture.chicago, identifier: "only"
            )
        ]
        let index = CaptureIndex(records: records, timeZone: Fixture.chicago)
        let survey = ArchiveSurveyor.survey(index: index, tuning: .v1)
        let entries = LifeEntryBuilder.build(
            index: index,
            monthEntries: ArchiveSurveyor.monthEntries(
                index: index, survey: survey, today: today, tuning: .v1
            ),
            today: today,
            tuning: .v1
        )
        // One header, the 4th empty, the 3rd held. Nothing for the 1st and 2nd, and no
        // rows at all for the twenty-three months before this one.
        #expect(entries.count == 3)
        let months = entries.compactMap { entry -> Month? in
            if case .monthHeader(let month, _) = entry { return month }
            return nil
        }
        #expect(months == [Month(year: 2026, month: 8)])
    }
}
