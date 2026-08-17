import Foundation
import Testing
@testable import rmbr

/// What the day page is allowed to print.
///
/// The page assembles strings from typed facts and nothing else, so these tests can
/// assert the exact text without rendering a view - which is where the honesty rules
/// actually bite.
@Suite("Day presentation")
struct DayPresentationTests {
    let composer = DayComposer()
    let date = LocalDate(year: 2026, month: 6, day: 17)
    let coordinate = Coordinate(latitude: 41.8757, longitude: -87.6580)

    private func day(_ captures: [CaptureRecord], labels: DayComposer.PlaceLabelLookup = .empty) -> Day {
        composer.compose(date: date, captures: captures, context: Fixture.context(labels: labels)).day
    }

    @Test("A named place leads the key facts")
    func placeLeadsKeyFacts() {
        let captures = [
            Fixture.capture("17:13:00", on: date, in: Fixture.chicago, coordinate: coordinate),
            Fixture.capture("17:14:00", on: date, in: Fixture.chicago, coordinate: coordinate)
        ]
        let facts = DayFormatting.keyFacts(
            for: day(captures, labels: Fixture.namingEverything("Van Buren Lofts"))
        )
        #expect(facts.first == "Van Buren Lofts")
        #expect(facts.contains("2 photos"))
        #expect(facts.count <= 3)
    }

    @Test("An unnamed day still states what it contained")
    func unnamedDayStillHasFacts() {
        let captures = [Fixture.capture("16:33:41", on: date, in: Fixture.chicago)]
        let facts = DayFormatting.keyFacts(for: day(captures))
        #expect(facts == ["1 photo"])
    }

    @Test("A day rmbr knows nothing about produces no key facts to print")
    func emptyDayHasNoFacts() {
        #expect(DayFormatting.keyFacts(for: day([])).isEmpty)
    }

    @Test("The capture summary counts videos separately from photographs")
    func captureSummaryDistinguishesKinds() {
        let captures = [
            Fixture.capture("10:00:00", on: date, in: Fixture.chicago, identifier: "p"),
            Fixture.capture("10:30:00", on: date, in: Fixture.chicago, kind: .video,
                            duration: 20, identifier: "v")
        ]
        let counts = try! #require(day(captures).media.rawCounts.knownValue)
        #expect(DayFormatting.captureSummary(counts) == "1 photo · 1 video")
    }

    @Test("Excluded captures are summarised as categories, never as content")
    func exclusionSummaryIsCategoricalOnly() {
        var counts = MediaExclusionCounts()
        for _ in 0..<21 { counts.record(.screenshot) }
        counts.record(.screenRecording)
        let summary = try! #require(DayFormatting.exclusionSummary(counts))
        #expect(summary == "21 screenshots · 1 screen recording kept out of memories")
    }

    @Test("A single capture prints no duration at all")
    func instantPrintsNoDuration() {
        let captures = [Fixture.capture("16:33:41", on: date, in: Fixture.chicago, coordinate: coordinate)]
        let moment = day(captures).moments[0]
        #expect(DayFormatting.durationClaim(moment.durationClaim, in: Fixture.chicago) == nil)
    }

    @Test("A capture floor is printed as a floor and never as time spent")
    func floorIsPrintedAsAFloor() {
        let captures = [
            Fixture.capture("13:22:32", on: date, in: Fixture.chicago, coordinate: coordinate),
            Fixture.capture("14:38:21", on: date, in: Fixture.chicago, coordinate: coordinate)
        ]
        let moment = day(captures).moments[0]
        let text = try! #require(DayFormatting.durationClaim(moment.durationClaim, in: Fixture.chicago))
        #expect(text.contains("captures from"))
        #expect(text.contains("at least 1 hr 15 min"))
        for forbidden in ["spent", "arrived", "left", "stayed"] {
            #expect(!text.lowercased().contains(forbidden))
        }
    }

    @Test("Today is headed 'Today'; every other day is headed by its date")
    func headingNamesTheDay() {
        #expect(DayFormatting.heading(for: date, today: date) == "Today")
        let heading = DayFormatting.heading(for: date, today: LocalDate(year: 2026, month: 6, day: 18))
        #expect(heading.contains("2026"))
        #expect(heading != "Today")
    }

    @Test("A stored label's attribution is exposed for the page to print")
    func attributionReachesThePage() {
        let captures = [Fixture.capture("17:13:00", on: date, in: Fixture.chicago, coordinate: coordinate)]
        let named = day(captures, labels: Fixture.namingEverything("Millennium Park"))
        #expect(named.placeAttributions == [OpenStreetMap.attribution])
        // Nothing to attribute when nothing was named.
        #expect(day(captures).placeAttributions.isEmpty)
    }

    @Test("A photograph's printed time comes from its own components, not the phone's zone")
    func timeIsPrintedInItsOwnTerms() {
        let capture = Fixture.capture("18:42:00", on: date, in: Fixture.baltimore)
        let inBaltimore = DayFormatting.time(capture.captureTime, in: Fixture.baltimore)
        let inChicago = DayFormatting.time(capture.captureTime, in: Fixture.chicago)
        // Reading the same photograph in another zone must not move its hour, and the
        // hour it keeps is the one it was taken at - not the instant seen from anywhere.
        #expect(inBaltimore == inChicago)
        #expect(inBaltimore == Fixture.shortTime(hour: 18, minute: 42))
    }

    @Test("A day with photographs rmbr can see never reads as empty")
    func limitedAccessRowStatesWhatIsVisible() {
        let captures = [Fixture.capture("09:05:00", on: date, in: Fixture.chicago)]
        let limited = composer.compose(
            date: date,
            captures: captures,
            context: Fixture.context(fullAccess: false)
        ).day
        // Limited access leaves the raw counts unknown, so there is no key fact to print.
        #expect(DayFormatting.keyFacts(for: limited).isEmpty)
        #expect(DayFormatting.rowFallback(for: limited) == "1 capture rmbr can see")
        #expect(DayFormatting.rowFallback(for: day([])) == "Nothing recorded")
    }

    @Test("A day whose captures were all filtered out never claims to be empty")
    func filteredDayDoesNotReadAsEmpty() {
        let captures = [
            Fixture.capture("09:05:00", on: date, in: Fixture.chicago, isScreenshot: true)
        ]
        let limited = composer.compose(
            date: date,
            captures: captures,
            context: Fixture.context(fullAccess: false)
        ).day
        #expect(DayFormatting.keyFacts(for: limited).isEmpty)
        #expect(DayFormatting.rowFallback(for: limited) == "1 capture kept out of memories")
        #expect(
            DayFormatting.emptyDayStatement(for: limited)
                == "1 capture from this day is kept out of memories."
        )
        #expect(
            DayFormatting.emptyDayStatement(for: day([]))
                == "rmbr has nothing recorded for this day."
        )
    }

    @Test("A place count drawn from part of a library says so")
    func limitedPlaceCountIsQualified() {
        let elsewhere = Coordinate(latitude: 41.9000, longitude: -87.6200)
        let captures = [
            Fixture.capture("09:00:00", on: date, in: Fixture.chicago, coordinate: coordinate),
            Fixture.capture("14:00:00", on: date, in: Fixture.chicago, coordinate: elsewhere)
        ]
        let limited = composer.compose(
            date: date,
            captures: captures,
            context: Fixture.context(fullAccess: false, labels: Fixture.namingEverything("Home"))
        ).day
        #expect(DayFormatting.keyFacts(for: limited).contains("2 places rmbr can see"))

        let full = composer.compose(
            date: date,
            captures: captures,
            context: Fixture.context(labels: Fixture.namingEverything("Home"))
        ).day
        #expect(DayFormatting.keyFacts(for: full).contains("2 places"))
    }

    @Test("A moment the budget showed nothing of states what it holds")
    func unshownMomentStatesItsContents() {
        let references = [
            Fixture.capture("11:00:00", on: date, in: Fixture.chicago),
            Fixture.capture("11:01:00", on: date, in: Fixture.chicago),
            Fixture.capture("11:02:00", on: date, in: Fixture.chicago, kind: .video, duration: 12)
        ].map { $0.mediaReference() }
        #expect(DayFormatting.mediaComposition(of: references) == "2 photographs and 1 video")
        #expect(DayFormatting.mediaComposition(of: [references[0]]) == "1 photograph")
        #expect(DayFormatting.mediaComposition(of: []) == nil)
    }
}
