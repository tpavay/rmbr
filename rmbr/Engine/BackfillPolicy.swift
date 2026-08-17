import Foundation

/// How much work a day is entitled to.
enum BackfillTreatment: Sendable, Hashable {
    /// Inside the recent window: composed and cached, including days that are empty.
    case fullyComposed
    /// Chosen to represent an older calendar month.
    case monthlyRepresentative
    /// Older and not chosen: indexed only, and composed when the person opens it.
    case composeOnOpen
}

/// Decides which days are composed up front and which wait to be opened.
///
/// The window is 24 calendar month buckets - the current partial month plus the 23
/// complete months before it - and not 730 days of arithmetic, so it lands on the same
/// month boundaries whichever day of the month it is evaluated on (RQ-064, RE-043).
struct BackfillPolicy: Sendable {
    let tuning: ReconstructionTuningProfile

    /// The oldest month that is fully composed.
    func windowStart(today: LocalDate) -> Month {
        Month(year: today.year, month: today.month)
            .adding(months: -(tuning.fullyComposedMonthBuckets - 1))
    }

    func months(today: LocalDate) -> [Month] {
        let start = windowStart(today: today)
        return (0..<tuning.fullyComposedMonthBuckets).map { start.adding(months: $0) }
    }

    func isInRecentWindow(_ date: LocalDate, today: LocalDate) -> Bool {
        let month = Month(year: date.year, month: date.month)
        return month >= windowStart(today: today)
            && month <= Month(year: today.year, month: today.month)
    }

    func treatment(
        for date: LocalDate,
        today: LocalDate,
        representatives: Set<LocalDate>
    ) -> BackfillTreatment {
        if isInRecentWindow(date, today: today) { return .fullyComposed }
        if representatives.contains(date) { return .monthlyRepresentative }
        return .composeOnOpen
    }
}
