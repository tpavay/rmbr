import Foundation

/// One row in the Life scroll.
enum LifeEntry: Sendable, Hashable, Identifiable {
    case monthHeader(Month, subtitle: String)
    case day(LocalDate, treatment: BackfillTreatment)
    /// A single day inside the window that holds nothing. It keeps a card, so time
    /// never skips over one quiet Wednesday.
    case emptyDay(LocalDate)
    /// Two or more consecutive empty days, collapsed into one row a third the height.
    case gap(newest: LocalDate, oldest: LocalDate, days: Int)
    case emptyMonth(Month, reason: NoRepresentativeReason)

    var id: String {
        switch self {
        case .monthHeader(let month, _): "header-\(month)"
        case .day(let date, _): "day-\(date)"
        case .emptyDay(let date): "empty-\(date)"
        case .gap(let newest, _, _): "gap-\(newest)"
        case .emptyMonth(let month, _): "thin-\(month)"
        }
    }
}

/// Turns the index and the month decisions into the rows Life shows.
///
/// Inside the recent window every calendar day gets a row: a day with captures, or an
/// empty day, or a collapsed run of empty days. Before the window, a month contributes
/// its one representative day or an explicit thin-month row. That is the settled
/// backfill shape, and it is why a library reaching back to 2008 scrolls as a few
/// hundred rows rather than six thousand.
///
/// Life used to list only the days that held something, which meant an empty day had no
/// row at all and could be reached only from the month. Time now runs continuously
/// through the window and nothing is unreachable.
enum LifeEntryBuilder {
    static func build(
        index: CaptureIndex,
        monthEntries: [MonthEntry],
        today: LocalDate,
        tuning: ReconstructionTuningProfile
    ) -> [LifeEntry] {
        // Nothing is shown before the first photograph in the library: a person who
        // started last week does not scroll through two years of empty days. With no
        // photograph at all there is nothing to draw, and Life shows an empty state
        // rather than two years of outlines standing in for a life it cannot see.
        guard let earliest = index.earliestDate else { return [] }
        let earliestMonth = Month(year: earliest.year, month: earliest.month)

        let policy = BackfillPolicy(tuning: tuning)
        let windowStart = policy.windowStart(today: today)
        var entries: [LifeEntry] = []

        for month in policy.months(today: today).reversed() {
            if month < earliestMonth { continue }

            let dates = Set(index.dates(in: month))
            let newestDay = lastDrawableDay(of: month, today: today, datesWithCaptures: dates)
            // The oldest day this month may show is its first, or the library's own first
            // day where that falls inside it.
            var oldestDay = 1
            if month == earliestMonth { oldestDay = earliest.day }
            guard newestDay >= oldestDay else { continue }

            var rows: [LifeEntry] = []
            var daysDrawn = 0
            var runNewest: Int?
            var runOldest: Int?

            func flushRun() {
                guard let runNewest, let runOldest else { return }
                let newest = LocalDate(year: month.year, month: month.month, day: runNewest)
                if runNewest == runOldest {
                    rows.append(.emptyDay(newest))
                } else {
                    let oldest = LocalDate(year: month.year, month: month.month, day: runOldest)
                    rows.append(
                        .gap(newest: newest, oldest: oldest, days: runNewest - runOldest + 1)
                    )
                }
            }

            for day in stride(from: newestDay, through: oldestDay, by: -1) {
                let date = LocalDate(year: month.year, month: month.month, day: day)
                if dates.contains(date) {
                    flushRun()
                    runNewest = nil
                    runOldest = nil
                    rows.append(.day(date, treatment: .fullyComposed))
                    daysDrawn += 1
                } else {
                    if runNewest == nil { runNewest = day }
                    runOldest = day
                }
            }
            flushRun()

            // The rule counts the day rows underneath it rather than every indexed day in
            // the month, so Life can never print three days above two of them.
            entries.append(.monthHeader(month, subtitle: subtitle(forDaysWithCaptures: daysDrawn)))
            entries.append(contentsOf: rows)
        }

        let older = monthEntries
            .filter { $0.month < windowStart }
            .sorted { $0.month > $1.month }
        for entry in older {
            switch entry {
            case .representative(let value):
                entries.append(.monthHeader(value.month, subtitle: "one day"))
                entries.append(.day(value.date, treatment: .monthlyRepresentative))
            case .noRepresentative(let month, let reason):
                entries.append(.monthHeader(month, subtitle: "nothing to show"))
                entries.append(.emptyMonth(month, reason: reason))
            }
        }

        return entries
    }

    private static func subtitle(forDaysWithCaptures count: Int) -> String {
        count == 0 ? "nothing recorded" : DayFormatting.count(count, singular: "day", plural: "days")
    }

    /// The newest day of a month that may be drawn, so Life and the mosaic agree.
    ///
    /// The current month stops at today, because rmbr does not draw a day that has not
    /// happened. A day that holds photographs has happened whatever the phone's clock
    /// says: `CaptureIndex` bins a capture by its own civil day, so one taken in a zone
    /// ahead of the phone's belongs to a date after today and must still be reachable.
    static func lastDrawableDay(
        of month: Month,
        today: LocalDate,
        datesWithCaptures: some Sequence<LocalDate>
    ) -> Int {
        let full = daysIn(month)
        guard month == Month(year: today.year, month: today.month) else { return full }
        let newestCapture = datesWithCaptures
            .lazy
            .filter { month.contains($0) }
            .map(\.day)
            .max() ?? 0
        return min(full, max(today.day, newestCapture))
    }

    /// Length of a Gregorian month, without a calendar. The engine stays pure.
    static func daysIn(_ month: Month) -> Int {
        switch month.month {
        case 1, 3, 5, 7, 8, 10, 12: 31
        case 4, 6, 9, 11: 30
        default: isLeap(month.year) ? 29 : 28
        }
    }

    private static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }
}
