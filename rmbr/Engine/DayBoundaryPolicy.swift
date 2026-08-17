import Foundation

/// Evidence a boundary policy may consult.
///
/// Milestone 1 supplies no sleep episodes, because sleep evidence comes from HealthKit
/// and this milestone reads photographs only. Milestone 2 fills `sleepEpisodes` and the
/// sleep-aware policy below starts closing days without any other file changing.
struct BoundaryEvidence: Sendable {
    /// Measured asleep intervals overlapping the search window, already unioned.
    let sleepEpisodes: [DateIntervalValue]
    /// Evidence for which zone the day's boundary should be resolved in.
    let timeZone: TimeZone
    /// Which tier of the time-zone cascade won (RQ-024).
    let timeZoneTier: TimeZoneTier

    static func withoutSleep(timeZone: TimeZone, tier: TimeZoneTier) -> BoundaryEvidence {
        BoundaryEvidence(sleepEpisodes: [], timeZone: timeZone, timeZoneTier: tier)
    }
}

/// Which evidence established the boundary time zone, in cascade order.
enum TimeZoneTier: String, Sendable, Codable, Hashable {
    case personCorrection
    case precisePostInstallLocation
    case geotaggedCaptureCluster
    case deviceTimeZoneAtIndexing
}

/// Resolves the interval a civil date owns.
///
/// The settled product rule is that a day ends when the person went to sleep, and
/// falls back to civil midnight where no sleep evidence exists. Both branches live
/// behind this one protocol so the fallback shipping first is a configuration choice
/// rather than an assumption baked through the engine.
protocol DayBoundaryPolicy: Sendable {
    func interval(for date: LocalDate, evidence: BoundaryEvidence) -> DayInterval
}

/// The fallback branch: a day runs from civil midnight to civil midnight.
///
/// This is what milestone 1 uses for every day, because sleep evidence is out of scope.
/// It is the same branch the sleep-aware policy falls back to when a person has no
/// readable sleep for a night, so it is not throwaway code.
struct MidnightDayBoundaryPolicy: DayBoundaryPolicy {
    func interval(for date: LocalDate, evidence: BoundaryEvidence) -> DayInterval {
        let zone = evidence.timeZone
        let start = date.startOfDay(in: zone)
        let end = date.adding(days: 1, in: zone).startOfDay(in: zone)
        return DayInterval(
            start: start,
            end: end,
            startReason: .civilMidnight(timeZoneID: zone.identifier),
            endReason: .civilMidnight(timeZoneID: zone.identifier)
        )
    }
}

/// The settled branch, for milestone 2.
///
/// A day closes at the start of the longest qualifying measured-sleep episode
/// beginning between local noon on the day and local noon the next day, and the
/// next day opens exactly where this one closed so no instant belongs to two days
/// or to none (RQ-019, RQ-020, RQ-023). It falls back to midnight per night, not
/// per library, because a person can have sleep evidence for one night and not the next.
///
/// It is unreachable in milestone 1 only because `BoundaryEvidence.sleepEpisodes` is
/// always empty; nothing else has to change to switch it on.
struct SleepAwareDayBoundaryPolicy: DayBoundaryPolicy {
    let tuning: ReconstructionTuningProfile
    /// Supplies the evidence for the preceding date, so the opening boundary is the
    /// previous day's close.
    let evidenceForDate: @Sendable (LocalDate) -> BoundaryEvidence

    func interval(for date: LocalDate, evidence: BoundaryEvidence) -> DayInterval {
        let zone = evidence.timeZone
        let previous = date.adding(days: -1, in: zone)
        let (start, startReason) = close(of: previous, evidence: evidenceForDate(previous))
            ?? (date.startOfDay(in: zone), BoundaryReason.civilMidnight(timeZoneID: zone.identifier))
        let (end, endReason) = close(of: date, evidence: evidence)
            ?? (date.adding(days: 1, in: zone).startOfDay(in: zone),
                BoundaryReason.civilMidnight(timeZoneID: zone.identifier))
        return DayInterval(start: start, end: end, startReason: startReason, endReason: endReason)
    }

    private func close(of date: LocalDate, evidence: BoundaryEvidence) -> (Date, BoundaryReason)? {
        let zone = evidence.timeZone
        let calendar = RmbrCalendar.calendar(in: zone)
        let searchStart = calendar.date(
            byAdding: .hour, value: tuning.primarySleepSearchStartHour, to: date.startOfDay(in: zone)
        )
        let searchEnd = calendar.date(
            byAdding: .hour,
            value: tuning.primarySleepSearchEndHour,
            to: date.adding(days: 1, in: zone).startOfDay(in: zone)
        )
        guard let searchStart, let searchEnd else { return nil }
        let qualifying = evidence.sleepEpisodes
            .filter { $0.start >= searchStart && $0.start <= searchEnd }
            .filter { $0.duration >= tuning.minimumPrimarySleep }
        guard let principal = qualifying.max(by: { $0.duration < $1.duration }) else { return nil }
        return (principal.start, .primarySleep(EvidenceID("sleep:\(principal.start.timeIntervalSince1970)")))
    }
}
