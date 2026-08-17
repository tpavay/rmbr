import Foundation
import Testing
@testable import rmbr

/// The engine at the size of a real library.
///
/// The captain's measured library is 23,743 assets over 6,666 days reaching back to
/// 2008. These tests build an index that shape and exercise the paths a scroll actually
/// touches, so "scrolls without stalling" is a measurement rather than a hope. The time
/// bounds are deliberately loose - they are there to catch an accidental quadratic, not
/// to pin a number to one machine - and the measured figures are printed.
@Suite("Scale")
struct ScaleTests {
    static let assetCount = 24_000

    static func library() -> [CaptureRecord] {
        var records: [CaptureRecord] = []
        records.reserveCapacity(assetCount)
        var seed: UInt64 = 0x5EED
        func next() -> UInt64 {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return seed
        }
        let places = [
            Coordinate(latitude: 41.8757, longitude: -87.6580),
            Coordinate(latitude: 41.8760, longitude: -87.6543),
            Coordinate(latitude: 39.2914, longitude: -76.6221),
            Coordinate(latitude: 48.8584, longitude: 2.2945)
        ]
        let start = LocalDate(year: 2008, month: 5, day: 13)
        for index in 0..<assetCount {
            let dayOffset = Int(next() % 6_666)
            let date = start.adding(days: dayOffset, in: Fixture.chicago)
            let hour = 6 + Int(next() % 16)
            let minute = Int(next() % 60)
            let second = Int(next() % 60)
            let roll = next() % 100
            records.append(
                Fixture.capture(
                    String(format: "%02d:%02d:%02d", hour, minute, second),
                    on: date,
                    in: Fixture.chicago,
                    kind: roll < 25 ? .video : .photo,
                    coordinate: roll < 59 ? places[Int(next() % UInt64(places.count))] : nil,
                    isScreenshot: roll >= 88,
                    isFavorite: roll % 37 == 0,
                    duration: roll < 25 ? 12 : nil,
                    identifier: "asset-\(index)"
                )
            )
        }
        return records
    }

    @Test("A whole archive surveys and scrolls without a stall")
    func archiveScale() {
        let records = Self.library()

        let indexStart = Date()
        let index = CaptureIndex(records: records, timeZone: Fixture.chicago)
        let indexSeconds = Date().timeIntervalSince(indexStart)

        let survey = ArchiveSurveyor.survey(index: index, tuning: .v1)

        let today = LocalDate(year: 2026, month: 8, day: 16)
        let monthStart = Date()
        let monthEntries = ArchiveSurveyor.monthEntries(
            index: index, survey: survey, today: today, tuning: .v1
        )
        let lifeEntries = LifeEntryBuilder.build(
            index: index, monthEntries: monthEntries, today: today, tuning: .v1
        )
        let monthSeconds = Date().timeIntervalSince(monthStart)

        // Composing the rows a person can actually reach in one flick.
        let composer = DayComposer()
        let visible = Array(index.datesWithCaptures.suffix(120))
        let composeStart = Date()
        for date in visible {
            _ = composer.compose(
                date: date,
                captures: index.records(on: date),
                context: Fixture.context()
            )
        }
        let perDayMilliseconds = Date().timeIntervalSince(composeStart) / Double(visible.count) * 1000

        print("""
        == rmbr scale ==
        records            : \(records.count)
        days with captures : \(index.datesWithCaptures.count)
        index build        : \(String(format: "%.3f s", indexSeconds))
        archive survey     : \(String(format: "%.3f s", survey.elapsedSeconds))
        month selection    : \(String(format: "%.3f s", monthSeconds))
        compose per day    : \(String(format: "%.3f ms", perDayMilliseconds))
        life rows          : \(lifeEntries.count)
        """)

        #expect(index.totalRecordCount == Self.assetCount)
        #expect(index.earliestDate != nil)
        // Life is a few hundred rows for eighteen years, not six thousand.
        #expect(lifeEntries.count < 2_000)
        // Loose ceilings: these catch an accidental quadratic, not a slow machine.
        #expect(indexSeconds < 20)
        #expect(survey.elapsedSeconds < 30)
        #expect(monthSeconds < 20)
        // One frame is 16.7 ms. Composing a day has to be far cheaper than that.
        #expect(perDayMilliseconds < 5)
    }

    @Test("Every month older than the window contributes at most one day")
    func oldMonthsContributeOneDay() {
        let records = Self.library()
        let index = CaptureIndex(records: records, timeZone: Fixture.chicago)
        let survey = ArchiveSurveyor.survey(index: index, tuning: .v1)
        let today = LocalDate(year: 2026, month: 8, day: 16)
        let monthEntries = ArchiveSurveyor.monthEntries(
            index: index, survey: survey, today: today, tuning: .v1
        )
        let entries = LifeEntryBuilder.build(
            index: index, monthEntries: monthEntries, today: today, tuning: .v1
        )

        let windowStart = BackfillPolicy(tuning: .v1).windowStart(today: today)
        var perOldMonth: [Month: Int] = [:]
        for entry in entries {
            guard case .day(let date, _) = entry else { continue }
            let month = Month(year: date.year, month: date.month)
            guard month < windowStart else { continue }
            perOldMonth[month, default: 0] += 1
        }
        #expect(!perOldMonth.isEmpty)
        for (month, count) in perOldMonth {
            #expect(count == 1, "\(month) contributed \(count) days to Life")
        }
    }
}
