import Foundation

/// One row in the Life scroll.
enum LifeEntry: Sendable, Hashable, Identifiable {
    case monthHeader(Month, subtitle: String)
    case day(LocalDate, treatment: BackfillTreatment)
    case emptyMonth(Month, reason: NoRepresentativeReason)

    var id: String {
        switch self {
        case .monthHeader(let month, _): "header-\(month)"
        case .day(let date, _): "day-\(date)"
        case .emptyMonth(let month, _): "empty-\(month)"
        }
    }
}

/// Turns the index and the month decisions into the rows Life shows.
///
/// Inside the recent window every day with captures gets a row. Before it, a month
/// contributes its one representative day, or an explicit thin-month row. That is the
/// settled backfill shape, and it is why a library reaching back to 2008 scrolls as a
/// few hundred rows rather than six thousand.
enum LifeEntryBuilder {
    static func build(
        index: CaptureIndex,
        monthEntries: [MonthEntry],
        today: LocalDate,
        tuning: ReconstructionTuningProfile
    ) -> [LifeEntry] {
        let policy = BackfillPolicy(tuning: tuning)
        let windowStart = policy.windowStart(today: today)
        var entries: [LifeEntry] = []

        for month in policy.months(today: today).reversed() {
            let dates = index.dates(in: month).sorted(by: >)
            guard !dates.isEmpty else { continue }
            entries.append(.monthHeader(
                month,
                subtitle: DayFormatting.count(dates.count, singular: "day", plural: "days")
            ))
            for date in dates {
                entries.append(.day(date, treatment: .fullyComposed))
            }
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
}
