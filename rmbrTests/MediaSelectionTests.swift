import Foundation
import Testing
@testable import rmbr

@Suite("Media selection")
struct MediaSelectionTests {
    let selector = MediaSelector(tuning: .v1)
    let composer = DayComposer()

    @Test("The budget curve is the published one", arguments: [
        (6, 5), (9, 5), (25, 5), (40, 7), (100, 10), (101, 10)
    ])
    func busyDayBudget(count: Int, expected: Int) {
        #expect(selector.budget(forEligibleCount: count) == expected)
    }

    @Test("A small day shows every eligible capture", arguments: 0...5)
    func smallDayShowsEverything(count: Int) {
        let date = LocalDate(year: 2024, month: 3, day: 2)
        let captures = (0..<count).map {
            Fixture.capture("1\($0):00:00", on: date, in: Fixture.chicago, identifier: "small-\($0)")
        }
        let day = composer.compose(date: date, captures: captures, context: Fixture.context()).day
        #expect(day.media.selectedMediaIDs.count == count)
        #expect(day.media.eligibleMediaIDs.count == count)
    }

    @Test("Three eligible captures means three appear, however poor two of them are")
    func threeMeansThree() {
        let date = LocalDate(year: 2024, month: 3, day: 2)
        let captures = [
            Fixture.capture("09:00:00", on: date, in: Fixture.chicago, identifier: "a"),
            Fixture.capture("09:05:00", on: date, in: Fixture.chicago, identifier: "b"),
            Fixture.capture("09:10:00", on: date, in: Fixture.chicago, identifier: "c")
        ]
        let day = composer.compose(date: date, captures: captures, context: Fixture.context()).day
        #expect(Set(day.media.selectedMediaIDs) == Set(captures.map(\.id)))
    }

    @Test("Every media-bearing moment is covered before any moment gets a second slot")
    func coverageBeforeDepth() {
        let date = LocalDate(year: 2024, month: 3, day: 2)
        var captures: [CaptureRecord] = []
        // A dense morning moment.
        for index in 0..<12 {
            captures.append(
                Fixture.capture("09:\(String(format: "%02d", index)):00", on: date,
                                in: Fixture.chicago, identifier: "dense-\(index)")
            )
        }
        // Three quiet moments, each separated by more than the leftover clustering gap.
        captures.append(Fixture.capture("13:00:00", on: date, in: Fixture.chicago, identifier: "quiet-1"))
        captures.append(Fixture.capture("15:00:00", on: date, in: Fixture.chicago, identifier: "quiet-2"))
        captures.append(Fixture.capture("18:00:00", on: date, in: Fixture.chicago, identifier: "quiet-3"))

        let day = composer.compose(date: date, captures: captures, context: Fixture.context()).day
        #expect(day.moments.count == 4)
        for moment in day.moments {
            #expect(!moment.displayedMediaIDs.isEmpty)
        }
        #expect(day.media.selectedMediaIDs.count <= 10)
    }

    @Test("A video-only day gets a video cover")
    func videoCanWinTheCover() {
        let date = LocalDate(year: 2026, month: 6, day: 17)
        let captures = (0..<4).map {
            Fixture.capture(
                "1\($0):00:00", on: date, in: Fixture.chicago,
                kind: .video, duration: 20, identifier: "clip-\($0)"
            )
        }
        let day = composer.compose(date: date, captures: captures, context: Fixture.context()).day
        let cover = try! #require(day.media.coverMediaID.flatMap { day.media($0) })
        #expect(cover.kind == .video)
    }

    @Test("A still is not preferred over a video that shares its signals")
    func noStillPreference() {
        let date = LocalDate(year: 2026, month: 6, day: 17)
        let video = Fixture.capture(
            "10:00:00", on: date, in: Fixture.chicago,
            kind: .video, isFavorite: true, duration: 20, identifier: "aaa-video"
        )
        let still = Fixture.capture("10:00:30", on: date, in: Fixture.chicago, identifier: "bbb-still")
        let day = composer.compose(date: date, captures: [video, still], context: Fixture.context()).day
        // The favourite wins because it is a favourite, not because of its kind.
        #expect(day.media.coverMediaID == video.id)
    }

    @Test("The cover is always one of the selected captures")
    func coverIsSelected() {
        let date = LocalDate(year: 2024, month: 3, day: 2)
        let captures = (0..<30).map {
            Fixture.capture(
                "09:\(String(format: "%02d", $0)):00", on: date,
                in: Fixture.chicago, identifier: "many-\($0)"
            )
        }
        let day = composer.compose(date: date, captures: captures, context: Fixture.context()).day
        let cover = try! #require(day.media.coverMediaID)
        #expect(day.media.selectedMediaIDs.contains(cover))
    }

    @Test("Full-screen paging sees every eligible capture, not just the budgeted ones")
    func eligibleSetIsComplete() {
        let date = LocalDate(year: 2024, month: 3, day: 2)
        let captures = (0..<40).map {
            Fixture.capture(
                "09:\(String(format: "%02d", $0 % 60)):0\($0 / 60)", on: date,
                in: Fixture.chicago, identifier: "wide-\($0)"
            )
        }
        let day = composer.compose(date: date, captures: captures, context: Fixture.context()).day
        #expect(day.media.eligibleMediaIDs.count == 40)
        #expect(day.media.selectedMediaIDs.count <= 10)
        for id in day.media.eligibleMediaIDs {
            #expect(day.media(id) != nil)
        }
    }
}
