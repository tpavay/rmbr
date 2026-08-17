import Foundation
import Testing
@testable import rmbr

@Suite("Place clustering")
struct PlaceClusteringTests {
    let resolver = PlaceAnchorResolver(tuning: .v1)
    let origin = Coordinate(latitude: 41.8757, longitude: -87.6580)

    private func observation(_ index: Int, _ coordinate: Coordinate, accuracy: Double? = nil) -> PlaceObservation {
        PlaceObservation(
            id: ObservationID("obs-\(index)"),
            coordinate: coordinate,
            horizontalAccuracyMetres: accuracy,
            timestamp: .absolute(Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60)),
            accuracyState: accuracy.map { $0 <= 50 ? .precise : .imprecise } ?? .unreported,
            sourceKind: .photoAssetMetadata,
            sourceReference: "asset-\(index)"
        )
    }

    @Test("Fixes 24 metres apart merge")
    func hardMergeBand() {
        let result = resolver.resolve(observations: [
            observation(0, origin),
            observation(1, Fixture.offset(origin, metresNorth: 24))
        ])
        #expect(result.anchors.count == 1)
    }

    @Test("Fixes 50 metres apart stay separate without identity evidence")
    func ambiguousBandStaysSeparate() {
        let result = resolver.resolve(observations: [
            observation(0, origin),
            observation(1, Fixture.offset(origin, metresNorth: 50))
        ])
        #expect(result.anchors.count == 2)
    }

    @Test("Fixes 76 metres apart stay separate")
    func beyondTheBand() {
        let result = resolver.resolve(observations: [
            observation(0, origin),
            observation(1, Fixture.offset(origin, metresNorth: 76))
        ])
        #expect(result.anchors.count == 2)
    }

    @Test("A chain of near fixes cannot grow one anchor past the ambiguous bound")
    func chainingIsBounded() {
        // Each step is inside the hard-merge distance, which is exactly the case the
        // spike's rolling centroid got wrong: it would absorb all of these into one
        // cluster spanning 120 metres.
        let observations = (0...6).map { observation($0, Fixture.offset(origin, metresNorth: Double($0) * 20)) }
        let result = resolver.resolve(observations: observations)

        #expect(result.anchors.count > 1)
        for anchor in result.anchors.values {
            #expect(anchor.spanMetres <= ReconstructionTuningProfile.v1.placeAmbiguousUpperDistanceMetres)
        }
    }

    @Test("A reduced-precision fix cannot name a venue")
    func impreciseFixesDoNotCluster() {
        let result = resolver.resolve(observations: [
            observation(0, origin, accuracy: 3_000),
            observation(1, Fixture.offset(origin, metresNorth: 5), accuracy: 3_000)
        ])
        #expect(result.anchors.isEmpty)
    }

    @Test("Anchor identity is stable across runs and processes")
    func anchorIdentityIsStable() {
        let observations = [observation(0, origin), observation(1, Fixture.offset(origin, metresNorth: 10))]
        let first = resolver.resolve(observations: observations).anchors.keys.map(\.rawValue).sorted()
        let second = resolver.resolve(observations: observations.reversed()).anchors.keys.map(\.rawValue).sorted()
        #expect(first == second)
    }
}

@Suite("Day boundary")
struct DayBoundaryTests {
    @Test("With no sleep source, a day runs midnight to midnight and says so")
    func midnightFallback() {
        let date = LocalDate(year: 2026, month: 6, day: 17)
        let interval = MidnightDayBoundaryPolicy().interval(
            for: date,
            evidence: .withoutSleep(timeZone: Fixture.chicago, tier: .deviceTimeZoneAtIndexing)
        )

        #expect(interval.start == date.startOfDay(in: Fixture.chicago))
        #expect(interval.end == date.adding(days: 1, in: Fixture.chicago).startOfDay(in: Fixture.chicago))
        #expect(interval.endReason == .civilMidnight(timeZoneID: Fixture.chicago.identifier))
    }

    @Test("Adjacent days meet exactly, with no overlap and no gap")
    func intervalsAreContiguous() {
        let policy = MidnightDayBoundaryPolicy()
        let evidence = BoundaryEvidence.withoutSleep(
            timeZone: Fixture.chicago, tier: .deviceTimeZoneAtIndexing
        )
        var cursor = LocalDate(year: 2026, month: 2, day: 26)
        var previousEnd = policy.interval(for: cursor, evidence: evidence).end

        for _ in 0..<40 {
            cursor = cursor.adding(days: 1, in: Fixture.chicago)
            let interval = policy.interval(for: cursor, evidence: evidence)
            #expect(interval.start == previousEnd)
            previousEnd = interval.end
        }
    }

    @Test("The sleep-aware branch closes a day at the main sleep, not at a nap")
    func sleepAwareBranchIsReady() {
        // Milestone 1 never reaches this branch, because no source supplies sleep. The
        // test exists so the branch milestone 2 switches on is known to work now.
        let date = LocalDate(year: 2026, month: 6, day: 17)
        let zone = Fixture.chicago
        let nap = DateIntervalValue(
            start: date.startOfDay(in: zone).addingTimeInterval(14 * 3600),
            end: date.startOfDay(in: zone).addingTimeInterval(15.5 * 3600)
        )!
        let night = DateIntervalValue(
            start: date.startOfDay(in: zone).addingTimeInterval(22 * 3600),
            end: date.startOfDay(in: zone).addingTimeInterval(29 * 3600)
        )!

        let policy = SleepAwareDayBoundaryPolicy(tuning: .v1) { candidate in
            candidate == date
                ? BoundaryEvidence(sleepEpisodes: [nap, night], timeZone: zone, timeZoneTier: .deviceTimeZoneAtIndexing)
                : .withoutSleep(timeZone: zone, tier: .deviceTimeZoneAtIndexing)
        }
        let interval = policy.interval(
            for: date,
            evidence: BoundaryEvidence(
                sleepEpisodes: [nap, night], timeZone: zone, timeZoneTier: .deviceTimeZoneAtIndexing
            )
        )

        #expect(interval.end == night.start)
        // The preceding day had no readable sleep, so this day still opens at midnight.
        #expect(interval.startReason == .civilMidnight(timeZoneID: zone.identifier))
    }
}

@Suite("Source time")
struct SourceTimeTests {
    @Test("A photograph's stored components do not move when the phone changes zone")
    func floatingTimeIsStable() {
        let instant = Date(timeIntervalSince1970: 1_628_500_000)
        let stored = SourceTime.floatingLocal(from: instant, readIn: Fixture.baltimore)

        let readInBaltimore = stored.localComponents(defaultTimeZone: Fixture.baltimore)
        let readInChicago = stored.localComponents(defaultTimeZone: Fixture.chicago)

        #expect(readInBaltimore.hour == readInChicago.hour)
        #expect(readInBaltimore.day == readInChicago.day)
        #expect(stored.hasTrustworthyTimeZone == false)
    }

    @Test("An absolute instant declares that its zone is trustworthy")
    func absoluteTimeIsTrustworthy() {
        #expect(SourceTime.absolute(Date()).hasTrustworthyTimeZone)
    }
}
