import Foundation
import Testing
@testable import rmbr

@Suite("Day composition")
struct DayCompositionTests {
    let composer = DayComposer()

    @Test("A screenshot never becomes displayed media, even when it is a favourite")
    func screenshotsAreAHardGate() {
        let date = LocalDate(year: 2025, month: 2, day: 27)
        let captures = [
            Fixture.capture("11:30:49", on: date, in: Fixture.baltimore, isScreenshot: true, isFavorite: true),
            Fixture.capture("11:31:44", on: date, in: Fixture.baltimore, isScreenshot: true),
            Fixture.capture("15:21:49", on: date, in: Fixture.baltimore)
        ]
        let day = composer.compose(date: date, captures: captures, context: Fixture.context()).day

        #expect(day.media.eligibleMediaIDs.count == 1)
        #expect(day.media.selectedMediaIDs.count == 1)
        #expect(day.media.coverMediaID == captures[2].id)
        for id in day.media.selectedMediaIDs {
            #expect(day.media(id)?.eligibility.isEligible == true)
        }
        #expect(day.media.exclusionCounts.count(of: .screenshot) == 2)
    }

    @Test("Filtering never lowers the day's true capture counts")
    func captureCountsStayTruthful() {
        let date = LocalDate(year: 2026, month: 6, day: 17)
        var captures = (0..<21).map {
            Fixture.capture(
                "13:0\($0 % 6):0\($0 % 10)", on: date, in: Fixture.chicago,
                isScreenshot: true, identifier: "shot-\($0)"
            )
        }
        captures.append(Fixture.capture("16:07:48", on: date, in: Fixture.chicago))
        for index in 0..<10 {
            captures.append(
                Fixture.capture(
                    "17:1\(index):00", on: date, in: Fixture.chicago,
                    kind: .video, duration: 20, identifier: "video-\(index)"
                )
            )
        }

        let day = composer.compose(date: date, captures: captures, context: Fixture.context()).day
        let counts = try! #require(day.media.rawCounts.knownValue)

        #expect(counts.accessibleCaptureCount == 32)
        #expect(counts.screenshotCount == 21)
        #expect(day.media.eligibleMediaIDs.count == 11)
        #expect(day.media.selectedMediaIDs.count <= 10)
    }

    @Test("A day with no geotagged capture has no place, and no place is inferred")
    func noCoordinateMeansNoPlace() {
        let date = LocalDate(year: 2023, month: 10, day: 9)
        let captures = [Fixture.capture("16:33:41", on: date, in: Fixture.chicago)]
        let result = composer.compose(
            date: date,
            captures: captures,
            // Even with a resolver that would name anything, an ungeotagged day gets
            // nothing: there is no coordinate to name.
            context: Fixture.context(labels: Fixture.namingEverything("Somewhere"))
        )

        #expect(result.day.moments.count == 1)
        #expect(result.day.moments[0].place == nil)
        #expect(result.day.anchors.isEmpty)
        #expect(result.pendingPlaceLookups.isEmpty)
        #expect(result.day.facts.placeCount.isKnown == false)
        if case .noHistoricalVisitSource = result.day.sourceCoverage.location {} else {
            Issue.record("location coverage should say there is no historical visit source")
        }
    }

    @Test("An ungeotagged capture never joins a geotagged neighbour's place")
    func proximityDoesNotLendAPlace() {
        let date = LocalDate(year: 2026, month: 6, day: 17)
        let coordinate = Coordinate(latitude: 41.8757, longitude: -87.6580)
        let captures = [
            Fixture.capture("17:13:00", on: date, in: Fixture.chicago, coordinate: coordinate),
            Fixture.capture("17:14:00", on: date, in: Fixture.chicago)
        ]
        let day = composer.compose(date: date, captures: captures, context: Fixture.context()).day

        #expect(day.moments.count == 2)
        let placed = day.moments.filter { $0.place != nil }
        #expect(placed.count == 1)
        #expect(placed.first?.allMediaIDs == [captures[0].id])
    }

    @Test("Two captures at one place give a floor, never time spent there")
    func captureFloorIsAFloor() {
        let date = LocalDate(year: 2021, month: 8, day: 9)
        let coordinate = Coordinate(latitude: 39.2903, longitude: -76.6212)
        let captures = [
            Fixture.capture("13:22:32", on: date, in: Fixture.baltimore, coordinate: coordinate),
            Fixture.capture("14:38:21", on: date, in: Fixture.baltimore, coordinate: coordinate)
        ]
        let day = composer.compose(date: date, captures: captures, context: Fixture.context()).day

        #expect(day.moments.count == 1)
        guard case .captureFloor(let first, let last, _) = day.moments[0].durationClaim else {
            Issue.record("expected a capture floor")
            return
        }
        #expect(last.instant.timeIntervalSince(first.instant) == 4_549)
        #expect(day.moments[0].place?.visitInterval.isKnown == false)

        let printed = DayFormatting.durationClaim(day.moments[0].durationClaim, in: Fixture.baltimore) ?? ""
        for forbidden in ["spent", "arrived", "left", " for "] {
            #expect(!printed.lowercased().contains(forbidden))
        }
        #expect(printed.contains("at least"))
    }

    @Test("A single capture is an instant, not a zero-length duration")
    func singleCaptureIsAnInstant() {
        let date = LocalDate(year: 2021, month: 8, day: 9)
        let coordinate = Coordinate(latitude: 39.2903, longitude: -76.6212)
        let captures = [Fixture.capture("13:22:32", on: date, in: Fixture.baltimore, coordinate: coordinate)]
        let day = composer.compose(date: date, captures: captures, context: Fixture.context()).day

        #expect(day.moments.count == 1)
        #expect(day.moments[0].durationClaim == .none)
        #expect(DayFormatting.durationClaim(day.moments[0].durationClaim, in: Fixture.baltimore) == nil)
    }

    @Test("A day with nothing in it composes, and says nothing more")
    func emptyDayIsValid() {
        let date = LocalDate(year: 2018, month: 5, day: 21)
        let day = composer.compose(date: date, captures: [], context: Fixture.context()).day

        #expect(day.compositionState == .knownEmpty)
        #expect(day.moments.isEmpty)
        #expect(day.media.coverMediaID == nil)
        #expect(day.media.rawCounts.knownValue?.accessibleCaptureCount == 0)
        #expect(day.hasAnyContent == false)
    }

    @Test("Out-of-scope sources report unknown, never zero")
    func unknownIsNotZero() {
        let date = LocalDate(year: 2018, month: 5, day: 21)
        let day = composer.compose(date: date, captures: [], context: Fixture.context()).day

        #expect(day.facts.steps == .unknown(.sourceNotCollected))
        #expect(day.facts.sleep == .unknown(.sourceNotCollected))
        #expect(day.facts.workoutCount == .unknown(.sourceNotCollected))
        #expect(day.facts.walkingRunningDistanceMetres == .unknown(.sourceNotCollected))
        #expect(day.facts.steps.knownValue == nil)
        #expect(day.reconstruction.containsDeviceOnlyHealthEnrichment == false)
    }

    @Test("Limited access never produces counts presented as exhaustive")
    func limitedAccessCannotClaimExhaustiveCounts() {
        let date = LocalDate(year: 2024, month: 3, day: 2)
        let captures = [Fixture.capture("10:00:00", on: date, in: Fixture.chicago)]
        let day = composer.compose(
            date: date,
            captures: captures,
            context: Fixture.context(fullAccess: false)
        ).day

        #expect(day.media.rawCounts.isKnown == false)
        #expect(day.media.rawCounts == .unknown(.partialAuthorization))
    }

    @Test("Composition is deterministic whatever order the records arrive in")
    func compositionIsDeterministic() {
        let date = LocalDate(year: 2026, month: 6, day: 17)
        let coordinate = Coordinate(latitude: 41.8757, longitude: -87.6580)
        let captures = [
            Fixture.capture("11:03:59", on: date, in: Fixture.chicago, kind: .video, duration: 6),
            Fixture.capture("16:07:48", on: date, in: Fixture.chicago, coordinate: coordinate),
            Fixture.capture("17:13:00", on: date, in: Fixture.chicago, kind: .video, coordinate: coordinate, duration: 22),
            Fixture.capture("18:11:03", on: date, in: Fixture.chicago, kind: .video, coordinate: coordinate, duration: 69)
        ]

        let forwards = composer.compose(date: date, captures: captures, context: Fixture.context()).day
        let backwards = composer.compose(date: date, captures: captures.reversed(), context: Fixture.context()).day
        let shuffled = composer.compose(
            date: date,
            captures: [captures[2], captures[0], captures[3], captures[1]],
            context: Fixture.context()
        ).day

        #expect(forwards == backwards)
        #expect(forwards == shuffled)
        #expect(forwards.reconstruction.fingerprint == shuffled.reconstruction.fingerprint)
    }

    @Test("A stored label carries the attribution its licence requires")
    func labelsCarryAttribution() {
        let date = LocalDate(year: 2026, month: 6, day: 17)
        let coordinate = Coordinate(latitude: 41.8757, longitude: -87.6580)
        let captures = [Fixture.capture("17:13:00", on: date, in: Fixture.chicago, coordinate: coordinate)]
        let day = composer.compose(
            date: date,
            captures: captures,
            context: Fixture.context(labels: Fixture.namingEverything("Van Buren Lofts"))
        ).day

        #expect(day.moments[0].place?.label.knownValue?.text == "Van Buren Lofts")
        #expect(day.placeAttributions == [OpenStreetMap.attribution])
    }

    @Test("An unresolved place is reported as pending, not guessed")
    func unresolvedPlacesArePending() {
        let date = LocalDate(year: 2026, month: 6, day: 17)
        let coordinate = Coordinate(latitude: 41.8757, longitude: -87.6580)
        let captures = [Fixture.capture("17:13:00", on: date, in: Fixture.chicago, coordinate: coordinate)]
        let result = composer.compose(date: date, captures: captures, context: Fixture.context())

        #expect(result.pendingPlaceLookups.count == 1)
        #expect(result.day.moments[0].place?.label.isKnown == false)
        #expect(result.day.moments[0].warnings.contains(.placeLabelUnresolved))
        #expect(result.day.reconstruction.warnings.contains(.placeLabelsIncomplete))
    }

    @Test("Hidden assets are neither shown nor counted")
    func hiddenAssetsAreInvisible() {
        let date = LocalDate(year: 2024, month: 3, day: 2)
        let captures = [
            Fixture.capture("10:00:00", on: date, in: Fixture.chicago, isHidden: true),
            Fixture.capture("11:00:00", on: date, in: Fixture.chicago)
        ]
        let day = composer.compose(date: date, captures: captures, context: Fixture.context()).day

        #expect(day.media.rawCounts.knownValue?.accessibleCaptureCount == 1)
        #expect(day.media.eligibleMediaIDs.count == 1)
    }
}
