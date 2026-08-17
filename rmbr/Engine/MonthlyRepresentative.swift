import Foundation

/// The metadata-only signals a day offers the monthly cascade.
///
/// Everything here comes from the PhotoKit metadata index and the pure moment
/// partition. Nothing needs pixels, a network call or a health read, which is what
/// lets older-month refinement run without waiting for enrichment (RQ-070).
struct DaySignals: Sendable, Hashable {
    let date: LocalDate
    let eligibleMediaCount: Int
    let favoriteEligibleMediaCount: Int
    let momentCount: Int
    let momentsWithMediaCount: Int
    /// Centroids of the day's confident place anchors.
    let placeAnchorCentroids: [Coordinate]
    /// What the library held on this day, before any display filtering. Display rules
    /// exclude screenshots; the factual summary of what the day contained never does, so
    /// a day of twenty-one screenshots is not a day that held nothing (RE-012, RQ-053).
    var rawCounts: RawCaptureCounts = RawCaptureCounts()
    /// The day's anchors in the order its moments occur. A month row names the first of
    /// these the ledger can supply a label for, which is exactly what the opened day
    /// prints first, so the two can never disagree about where the day was.
    var chronologicalAnchorCentroids: [Coordinate] = []

    var distinctPlaceCount: Int { placeAnchorCentroids.count }
}

/// Why a day was chosen to represent its month.
///
/// One reason code, expressible as a sentence to the person - "this month is here
/// because you favourited a photo that day" - rather than a blended score (RE-044).
enum RepresentativeReason: String, Sendable, Codable, Hashable {
    case favoriteMedia
    case archiveUniquePlace
    case greatestDistinctPlaceCount
    case greatestMomentCount
    case greatestEligibleMediaCount
    case nearestMonthMidpoint
}

struct MonthlyRepresentative: Sendable, Codable, Hashable {
    let month: Month
    let date: LocalDate
    let reason: RepresentativeReason
}

/// Whether a month has a representative, and why not when it does not.
enum MonthEntry: Sendable, Codable, Hashable {
    case representative(MonthlyRepresentative)
    case noRepresentative(month: Month, reason: NoRepresentativeReason)

    var month: Month {
        switch self {
        case .representative(let value): value.month
        case .noRepresentative(let month, _): month
        }
    }
}

enum NoRepresentativeReason: String, Sendable, Codable, Hashable {
    case noIndexedDays
    case noQualifyingDay
}

/// Chooses at most one representative day for a calendar month older than the recent window.
///
/// A month with nothing worth showing stays visibly thin. Promoting the least bad day
/// to fill a gap would make rmbr look certain about a month it knows nothing about,
/// which is the exact failure the whole engine is built to avoid (RE-047, RQ-068).
struct MonthlyRepresentativeSelector: Sendable {
    let tuning: ReconstructionTuningProfile

    /// A day may represent its month only if it clears one positive-signal branch.
    ///
    /// Milestone 1 can satisfy three of the specified branches: a favourite, a confident
    /// place with eligible media, or at least two eligible captures in distinct moments.
    /// The note, calendar and workout branches need sources this milestone does not read.
    func qualifies(_ signals: DaySignals) -> Bool {
        if signals.favoriteEligibleMediaCount > 0 { return true }
        if signals.distinctPlaceCount > 0 && signals.eligibleMediaCount > 0 { return true }
        if signals.momentsWithMediaCount >= tuning.monthlyMinimumDistinctPlaces
            && signals.eligibleMediaCount >= 2 { return true }
        return false
    }

    /// - Parameter archivePlaces: every confident anchor in the indexed library, used to
    ///   decide whether a day's place is unique across the archive. Uniqueness is
    ///   compared by anchor proximity against the whole indexed horizon, never by a
    ///   coordinate merely looking novel (RE-045).
    func select(
        month: Month,
        days: [DaySignals],
        archivePlaces: ArchivePlaceIndex,
        dismissed: Set<LocalDate> = []
    ) -> MonthEntry {
        guard !days.isEmpty else {
            return .noRepresentative(month: month, reason: .noIndexedDays)
        }
        let candidates = days
            .filter { qualifies($0) && !dismissed.contains($0.date) }
            .sorted { $0.date < $1.date }
        guard !candidates.isEmpty else {
            return .noRepresentative(month: month, reason: .noQualifyingDay)
        }

        // Ordered cascade. The engine stops at the first tier containing a candidate and
        // never blends tiers into one score.
        let tiers: [(RepresentativeReason, (DaySignals) -> Bool)] = [
            (.favoriteMedia, { $0.favoriteEligibleMediaCount > 0 }),
            (.archiveUniquePlace, { day in
                day.placeAnchorCentroids.contains { archivePlaces.isUnique($0, to: day.date) }
            })
        ]

        for (reason, predicate) in tiers {
            let matching = candidates.filter(predicate)
            if let winner = breakTies(matching, month: month) {
                return .representative(
                    MonthlyRepresentative(month: month, date: winner.date, reason: reason)
                )
            }
        }

        let byPlaces = maxima(candidates) { $0.distinctPlaceCount }
        if byPlaces.first?.distinctPlaceCount ?? 0 > 0, let winner = breakTies(byPlaces, month: month) {
            return .representative(
                MonthlyRepresentative(month: month, date: winner.date, reason: .greatestDistinctPlaceCount)
            )
        }

        let byMoments = maxima(candidates) { $0.momentCount }
        if byMoments.count < candidates.count, let winner = breakTies(byMoments, month: month) {
            return .representative(
                MonthlyRepresentative(month: month, date: winner.date, reason: .greatestMomentCount)
            )
        }

        let byMedia = maxima(candidates) { $0.eligibleMediaCount }
        if byMedia.count < candidates.count, let winner = breakTies(byMedia, month: month) {
            return .representative(
                MonthlyRepresentative(month: month, date: winner.date, reason: .greatestEligibleMediaCount)
            )
        }

        guard let winner = breakTies(candidates, month: month) else {
            return .noRepresentative(month: month, reason: .noQualifyingDay)
        }
        return .representative(
            MonthlyRepresentative(month: month, date: winner.date, reason: .nearestMonthMidpoint)
        )
    }

    private func maxima(_ days: [DaySignals], by value: (DaySignals) -> Int) -> [DaySignals] {
        guard let best = days.map(value).max() else { return [] }
        return days.filter { value($0) == best }
    }

    /// Final tie-break: nearest the month's midpoint, then the earlier date.
    private func breakTies(_ days: [DaySignals], month: Month) -> DaySignals? {
        guard !days.isEmpty else { return nil }
        let midpoint = 15.5
        return days.min { lhs, rhs in
            let lhsDistance = abs(Double(lhs.date.day) - midpoint)
            let rhsDistance = abs(Double(rhs.date.day) - midpoint)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs.date < rhs.date
        }
    }
}

/// Every confident place anchor in the indexed library, searchable by proximity.
///
/// Backed by a coarse grid so a uniqueness question costs a handful of comparisons
/// rather than a scan of the archive, while the comparison itself remains an exact
/// distance test rather than a bucket match.
struct ArchivePlaceIndex: Sendable {
    private static let cellDegrees = 0.001

    private var cells: [Cell: [Entry]] = [:]
    private let mergeDistanceMetres: Double

    private struct Cell: Hashable {
        let latitude: Int
        let longitude: Int
    }

    private struct Entry {
        let coordinate: Coordinate
        let date: LocalDate
    }

    init(mergeDistanceMetres: Double) {
        self.mergeDistanceMetres = mergeDistanceMetres
    }

    mutating func insert(_ coordinate: Coordinate, on date: LocalDate) {
        cells[Self.cell(for: coordinate), default: []].append(Entry(coordinate: coordinate, date: date))
    }

    /// Whether this anchor appears on `date` and on no other indexed day.
    func isUnique(_ coordinate: Coordinate, to date: LocalDate) -> Bool {
        for entry in nearby(coordinate) where entry.date != date {
            if entry.coordinate.distance(to: coordinate) <= mergeDistanceMetres { return false }
        }
        return true
    }

    private func nearby(_ coordinate: Coordinate) -> [Entry] {
        let origin = Self.cell(for: coordinate)
        // A degree of longitude shrinks towards the poles, so the number of cells that
        // must be scanned to cover the merge distance grows with latitude.
        let metresPerLongitudeCell = max(
            0.5,
            Self.cellDegrees * 111_320 * cos(coordinate.latitude * .pi / 180)
        )
        let longitudeSpan = max(1, Int((mergeDistanceMetres / metresPerLongitudeCell).rounded(.up)))
        let latitudeSpan = max(1, Int((mergeDistanceMetres / (Self.cellDegrees * 110_574)).rounded(.up)))

        var result: [Entry] = []
        for latitudeOffset in -latitudeSpan...latitudeSpan {
            for longitudeOffset in -longitudeSpan...longitudeSpan {
                let cell = Cell(
                    latitude: origin.latitude + latitudeOffset,
                    longitude: origin.longitude + longitudeOffset
                )
                if let entries = cells[cell] { result.append(contentsOf: entries) }
            }
        }
        return result
    }

    private static func cell(for coordinate: Coordinate) -> Cell {
        Cell(
            latitude: Int((coordinate.latitude / cellDegrees).rounded(.down)),
            longitude: Int((coordinate.longitude / cellDegrees).rounded(.down))
        )
    }
}
