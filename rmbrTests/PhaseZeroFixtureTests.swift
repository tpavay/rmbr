import Foundation
import Testing
@testable import rmbr

/// The five saved phase-0 days, run through the engine as permanent regression fixtures.
///
/// The saved reports record capture times, media kinds and whether a capture carried
/// coordinates, but not the coordinates themselves. Where a coordinate is needed, these
/// fixtures use a synthetic one consistent with the address the report printed, and the
/// assertions are about structure - how many moments, which captures joined which, what
/// duration claim each moment may make - rather than about the exact metres.
///
/// Two fixtures also differ from the reconstruction specification's published output on
/// purpose. That output is for the whole engine, where a workout anchors a moment and
/// absorbs the media around it. Milestone 1 reads photographs only, so a workout day
/// partitions differently here. The difference is the measurement this milestone exists
/// to produce, not a defect.
@Suite("Phase 0 saved days")
struct PhaseZeroFixtureTests {
    let composer = DayComposer()

    // MARK: - 2018-05-21, nothing known

    @Test("2018-05-21 composes as an honest blank")
    func nothingKnown() {
        let date = LocalDate(year: 2018, month: 5, day: 21)
        let day = composer.compose(date: date, captures: [], context: Fixture.context()).day

        #expect(day.compositionState == .knownEmpty)
        #expect(day.moments.isEmpty)
        #expect(day.media.eligibleMediaIDs.isEmpty)
        #expect(day.media.coverMediaID == nil)
        #expect(day.facts.placeCount.isKnown == false)

        let signals = signals(for: day)
        #expect(MonthlyRepresentativeSelector(tuning: .v1).qualifies(signals) == false)
    }

    // MARK: - 2021-08-09, the Baltimore hard case

    @Test("2021-08-09 produces five moments, and only the geotagged ones have a place")
    func baltimore() {
        let date = LocalDate(year: 2021, month: 8, day: 9)
        let zone = Fixture.baltimore
        // 17 N Eutaw St and the University of Maryland campus, roughly 300 m apart.
        let eutaw = Coordinate(latitude: 39.29144, longitude: -76.62210)
        let campus = Coordinate(latitude: 39.28870, longitude: -76.62490)

        let captures = [
            Fixture.capture("11:15:31", on: date, in: zone, kind: .video, duration: 18, identifier: "a"),
            Fixture.capture("13:22:32", on: date, in: zone, coordinate: eutaw, identifier: "b"),
            Fixture.capture("13:22:53", on: date, in: zone, coordinate: campus, identifier: "c"),
            Fixture.capture("14:38:21", on: date, in: zone, coordinate: eutaw, identifier: "d"),
            Fixture.capture("18:00:56", on: date, in: zone, kind: .video, duration: 2, identifier: "e"),
            Fixture.capture("19:18:56", on: date, in: zone, kind: .video, duration: 8, identifier: "f"),
            Fixture.capture("19:20:27", on: date, in: zone, identifier: "g"),
            Fixture.capture("19:21:59", on: date, in: zone, kind: .video, duration: 14, identifier: "h"),
            Fixture.capture("19:22:03", on: date, in: zone, kind: .video, duration: 10, identifier: "i")
        ]

        let day = composer.compose(date: date, captures: captures, context: Fixture.context(timeZone: zone)).day

        #expect(day.moments.count == 5)
        #expect(day.media.eligibleMediaIDs.count == 9)
        // Nine eligible captures gives a budget of five.
        #expect(day.media.selectedMediaIDs.count == 5)

        // The two Eutaw Street captures are one moment with a floor between them; the
        // campus capture 21 seconds later is its own place and stays separate, because
        // nothing in the evidence licenses merging two anchors 300 m apart.
        let eutawMoment = try! #require(
            day.moments.first { $0.allMediaIDs.contains(MediaID("b")) }
        )
        #expect(eutawMoment.allMediaIDs == [MediaID("b"), MediaID("d")])
        guard case .captureFloor = eutawMoment.durationClaim else {
            Issue.record("two captures at one anchor establish a floor")
            return
        }

        let campusMoment = try! #require(
            day.moments.first { $0.allMediaIDs.contains(MediaID("c")) }
        )
        #expect(campusMoment.durationClaim == .none)
        #expect(campusMoment.place != nil)

        // The four ungeotagged evening clips are one moment; the two lone videos are
        // their own. None of them has a place.
        let placeless = day.moments.filter { $0.place == nil }
        #expect(placeless.count == 3)
        #expect(placeless.contains { $0.allMediaIDs.count == 4 })
        #expect(day.facts.placeCount.knownValue == 2)
    }

    // MARK: - 2023-10-09, thin

    @Test("2023-10-09 is one instant with no place, and cannot represent its month")
    func thinDay() {
        let date = LocalDate(year: 2023, month: 10, day: 9)
        let captures = [Fixture.capture("16:33:41", on: date, in: Fixture.chicago, identifier: "only")]
        let day = composer.compose(date: date, captures: captures, context: Fixture.context()).day

        #expect(day.moments.count == 1)
        #expect(day.moments[0].place == nil)
        #expect(day.moments[0].durationClaim == .none)
        #expect(day.media.selectedMediaIDs.count == 1)
        #expect(day.media.coverMediaID == MediaID("only"))
        // One unfavourited, unlocated capture does not promote a poor old month.
        #expect(MonthlyRepresentativeSelector(tuning: .v1).qualifies(signals(for: day)) == false)
    }

    // MARK: - 2025-02-27, workouts with screenshots

    @Test("2025-02-27 keeps six screenshots out and still reports seven captures")
    func workoutDayWithoutWorkouts() {
        let date = LocalDate(year: 2025, month: 2, day: 27)
        let zone = Fixture.baltimore
        let bostonStreet = Coordinate(latitude: 39.28160, longitude: -76.56710)
        let captures = [
            Fixture.capture("11:30:49", on: date, in: zone, isScreenshot: true, identifier: "s1"),
            Fixture.capture("11:31:44", on: date, in: zone, isScreenshot: true, identifier: "s2"),
            Fixture.capture("11:31:47", on: date, in: zone, isScreenshot: true, identifier: "s3"),
            Fixture.capture("15:21:25", on: date, in: zone, isScreenshot: true, identifier: "s4"),
            Fixture.capture("15:21:49", on: date, in: zone, coordinate: bostonStreet, identifier: "photo"),
            Fixture.capture("15:24:21", on: date, in: zone, isScreenshot: true, identifier: "s5"),
            Fixture.capture("16:32:37", on: date, in: zone, isScreenshot: true, identifier: "s6")
        ]

        let day = composer.compose(date: date, captures: captures, context: Fixture.context(timeZone: zone)).day

        #expect(day.media.rawCounts.knownValue?.accessibleCaptureCount == 7)
        #expect(day.media.exclusionCounts.count(of: .screenshot) == 6)
        #expect(day.media.eligibleMediaIDs == [MediaID("photo")])
        #expect(day.moments.count == 1)
        #expect(day.moments[0].kind == .historicalCapture)
        #expect(day.moments[0].durationClaim == .none)
        // Photographs alone cannot know there were two workouts here. They are not
        // reported as absent either: the source is out of scope, not empty.
        #expect(day.facts.workoutCount == .unknown(.sourceNotCollected))
        #expect(day.sourceCoverage.workouts == .notCollected)
    }

    // MARK: - 2026-06-17, the rich day

    @Test("2026-06-17 keeps 21 screenshots out and builds four photographs-only moments")
    func richDay() {
        let date = LocalDate(year: 2026, month: 6, day: 17)
        let zone = Fixture.chicago
        // The two Van Buren buildings the captain confirmed, about 300 m apart.
        let vanBuren1224 = Coordinate(latitude: 41.87600, longitude: -87.65790)
        let vanBuren1101 = Coordinate(latitude: 41.87604, longitude: -87.65430)

        let screenshotTimes = [
            "06:04:58", "06:05:04", "08:08:29", "13:05:22", "13:05:25", "13:05:30",
            "13:05:34", "13:05:49", "13:06:01", "14:26:03", "14:36:43", "14:36:52",
            "14:37:19", "14:37:45", "14:39:05", "14:39:55", "14:49:12", "15:03:51",
            "15:46:23", "16:18:47", "16:40:02"
        ]
        var captures = screenshotTimes.enumerated().map { index, time in
            Fixture.capture(time, on: date, in: zone, isScreenshot: true, identifier: "shot-\(index)")
        }
        captures += [
            Fixture.capture("11:03:59", on: date, in: zone, kind: .video, duration: 6, identifier: "v1"),
            Fixture.capture("11:04:25", on: date, in: zone, kind: .video, duration: 8, identifier: "v2"),
            Fixture.capture("16:07:48", on: date, in: zone, coordinate: vanBuren1224, identifier: "p1"),
            Fixture.capture("16:19:04", on: date, in: zone, kind: .video, duration: 41, identifier: "v3"),
            Fixture.capture("16:24:19", on: date, in: zone, kind: .video, duration: 31, identifier: "v4"),
            Fixture.capture("16:25:45", on: date, in: zone, kind: .video, duration: 110, identifier: "v5"),
            Fixture.capture("17:13:00", on: date, in: zone, kind: .video, coordinate: vanBuren1101, duration: 22, identifier: "v6"),
            Fixture.capture("17:14:01", on: date, in: zone, kind: .video, coordinate: vanBuren1101, duration: 23, identifier: "v7"),
            Fixture.capture("17:14:53", on: date, in: zone, kind: .video, coordinate: vanBuren1101, duration: 3, identifier: "v8"),
            Fixture.capture("17:14:59", on: date, in: zone, kind: .video, coordinate: vanBuren1101, duration: 6, identifier: "v9"),
            Fixture.capture("18:11:03", on: date, in: zone, kind: .video, coordinate: vanBuren1101, duration: 69, identifier: "v10")
        ]

        let day = composer.compose(date: date, captures: captures, context: Fixture.context()).day

        #expect(day.media.rawCounts.knownValue?.accessibleCaptureCount == 32)
        #expect(day.media.exclusionCounts.count(of: .screenshot) == 21)
        #expect(day.media.eligibleMediaIDs.count == 11)
        #expect(day.media.selectedMediaIDs.count == 5)

        // Two ungeotagged clusters, and the two Van Buren buildings kept apart.
        #expect(day.moments.count == 4)
        #expect(day.facts.placeCount.knownValue == 2)

        let anchored = day.moments.filter { $0.place != nil }
        #expect(anchored.count == 2)
        #expect(anchored[0].allMediaIDs == [MediaID("p1")])
        #expect(anchored[1].allMediaIDs == [
            MediaID("v6"), MediaID("v7"), MediaID("v8"), MediaID("v9"), MediaID("v10")
        ])

        // The 56-minute gap before 18:11 is inside the 120-minute same-place
        // continuation, so it stays one moment with a floor across the whole span.
        guard case .captureFloor(let first, let last, _) = anchored[1].durationClaim else {
            Issue.record("expected a capture floor at the second building")
            return
        }
        #expect(last.instant.timeIntervalSince(first.instant) == 3_483)

        // A video wins the cover on a day where ten of eleven eligible captures are video.
        let cover = try! #require(day.media.coverMediaID.flatMap { day.media($0) })
        #expect(cover.kind == .video)

        // No screenshot is anywhere in the day's media.
        for id in day.media.eligibleMediaIDs {
            #expect(day.media(id)?.eligibility.isEligible == true)
        }
        #expect(!day.media.eligibleMediaIDs.contains { $0.rawValue.hasPrefix("shot-") })
    }

    private func signals(for day: Day) -> DaySignals {
        DaySignals(
            date: day.date,
            eligibleMediaCount: day.media.eligibleMediaIDs.count,
            favoriteEligibleMediaCount: day.media.eligibleMediaIDs
                .compactMap { day.media($0) }.filter(\.isFavorite).count,
            momentCount: day.moments.count,
            momentsWithMediaCount: day.moments.filter { !$0.allMediaIDs.isEmpty }.count,
            placeAnchorCentroids: day.anchors.values.map(\.centroid)
        )
    }
}
