import Foundation

/// Decides which of a day's eligible captures appear inline, and which is the cover.
///
/// Two rules matter more than any ranking here. A day of five or fewer eligible
/// captures shows all of them, whatever a quality signal thinks of them - three
/// eligible captures means three appear, even when two are poor (RQ-055). And every
/// media-bearing moment gets a slot before any moment gets a second one, so a dense
/// moment cannot crowd a quiet one off the page (RQ-057).
///
/// Milestone 1 computes no Vision signal: no aesthetics score, no `isUtility`, no face
/// quality, no near-duplicate feature print. Those occupy the lower tiers of the
/// ranking ladder, below the metadata signals implemented here, and the composition
/// must be valid before they run in any case (RQ-051). Where they would have broken a
/// tie, a stable identifier does, so the result stays deterministic rather than
/// arbitrary.
struct MediaSelector: Sendable {
    let tuning: ReconstructionTuningProfile

    struct Selection: Sendable {
        /// Displayed captures per moment, in chronological order.
        var displayedByMoment: [MomentID: [MediaID]]
        /// Every displayed capture across the day, chronologically.
        var selectedMediaIDs: [MediaID]
        var representativeByMoment: [MomentID: MediaID]
        var coverMediaID: MediaID?
    }

    /// The display budget.
    ///
    /// Sublinear in the day's volume, and capped at ten. The reconstruction PRD would
    /// raise the cap to cover every media-bearing moment; the engine specification caps
    /// it at ten outright and allocates coverage inside that cap. The specification
    /// governs mechanism, so ten is hard here.
    func budget(forEligibleCount count: Int) -> Int {
        guard count > tuning.smallDayMaximum else { return count }
        let root = Int(Double(count).squareRoot().rounded(.up))
        return min(tuning.busyDayMaximumBudget, max(tuning.busyDayMinimumBudget, root))
    }

    func select(moments: [MomentBuilder.DraftMoment]) -> Selection {
        let eligibleCount = moments.reduce(0) { $0 + $1.captures.count }
        var remaining = budget(forEligibleCount: eligibleCount)

        let mediaBearing = moments.filter { !$0.captures.isEmpty }
        var allocation: [MomentID: Int] = [:]

        // One slot per media-bearing moment while slots remain, moments ordered by
        // person selection, then favourite presence, then anchoring, then volume,
        // then chronology.
        for moment in mediaBearing.sorted(by: Self.momentCoveragePriority) {
            guard remaining > 0 else { break }
            allocation[moment.id] = 1
            remaining -= 1
        }

        // Remaining slots proportional to the square root of each represented moment's
        // eligible count, by largest remainder, with chronology breaking remainder ties.
        if remaining > 0 {
            let represented = mediaBearing.filter { (allocation[$0.id] ?? 0) > 0 }
            let weights = represented.map { Double($0.captures.count).squareRoot() }
            let weightTotal = weights.reduce(0, +)
            if weightTotal > 0 {
                var exact: [(MomentID, Double, Int)] = []
                for (index, moment) in represented.enumerated() {
                    let share = Double(remaining) * weights[index] / weightTotal
                    exact.append((moment.id, share, index))
                }
                var awarded = 0
                for (id, share, _) in exact {
                    let whole = Int(share)
                    let capacity = (represented.first { $0.id == id }?.captures.count ?? 0)
                        - (allocation[id] ?? 0)
                    let granted = min(whole, max(0, capacity))
                    allocation[id, default: 0] += granted
                    awarded += granted
                }
                var leftovers = remaining - awarded
                let byRemainder = exact
                    .sorted { lhs, rhs in
                        let lhsRemainder = lhs.1 - Double(Int(lhs.1))
                        let rhsRemainder = rhs.1 - Double(Int(rhs.1))
                        if lhsRemainder != rhsRemainder { return lhsRemainder > rhsRemainder }
                        return lhs.2 < rhs.2
                    }
                var pass = 0
                while leftovers > 0 && pass < byRemainder.count * 2 {
                    var progressed = false
                    for (id, _, _) in byRemainder where leftovers > 0 {
                        let capacity = (represented.first { $0.id == id }?.captures.count ?? 0)
                            - (allocation[id] ?? 0)
                        if capacity > 0 {
                            allocation[id, default: 0] += 1
                            leftovers -= 1
                            progressed = true
                        }
                    }
                    if !progressed { break }
                    pass += 1
                }
            }
        }

        var displayedByMoment: [MomentID: [MediaID]] = [:]
        var representativeByMoment: [MomentID: MediaID] = [:]

        for moment in moments {
            let ranked = rankWithinMoment(moment.captures)
            guard let best = ranked.first else { continue }
            representativeByMoment[moment.id] = best.id
            let slots = min(allocation[moment.id] ?? 0, ranked.count)
            guard slots > 0 else { continue }
            displayedByMoment[moment.id] = Array(ranked.prefix(slots))
                .sorted(by: MomentBuilder.captureOrder)
                .map(\.id)
        }

        let selected = moments
            .flatMap { displayedByMoment[$0.id] ?? [] }
        let byCaptureTime = moments
            .flatMap(\.captures)
            .filter { capture in selected.contains(capture.id) }
            .sorted(by: MomentBuilder.captureOrder)
            .map(\.id)

        return Selection(
            displayedByMoment: displayedByMoment,
            selectedMediaIDs: byCaptureTime,
            representativeByMoment: representativeByMoment,
            coverMediaID: chooseCover(moments: moments, selected: Set(selected))
        )
    }

    /// Ranks a moment's captures lexicographically.
    ///
    /// Explicit person intent first, then favourites, then temporal spread, then edit
    /// state, then a stable identifier. Spread is computed as a farthest-point ordering
    /// rather than a score so that a second pick from a moment lands as far from the
    /// first as the moment allows, instead of next to it.
    func rankWithinMoment(_ captures: [CaptureRecord]) -> [CaptureRecord] {
        let favourites = captures.filter(\.isFavorite).sorted(by: MomentBuilder.captureOrder)
        let rest = captures.filter { !$0.isFavorite }.sorted(by: MomentBuilder.captureOrder)
        return spread(favourites) + spread(rest)
    }

    private func spread(_ captures: [CaptureRecord]) -> [CaptureRecord] {
        guard captures.count > 2 else { return captures }
        var remaining = captures
        var picked: [CaptureRecord] = [remaining.removeFirst()]
        while !remaining.isEmpty {
            var bestIndex = 0
            var bestDistance = -Double.greatestFiniteMagnitude
            for (index, candidate) in remaining.enumerated() {
                let distance = picked
                    .map { abs(candidate.instant.timeIntervalSince($0.instant)) }
                    .min() ?? 0
                let better = distance > bestDistance
                    || (distance == bestDistance && Self.tieBreak(candidate, remaining[bestIndex]))
                if better {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            picked.append(remaining.remove(at: bestIndex))
        }
        return picked
    }

    private static func tieBreak(_ a: CaptureRecord, _ b: CaptureRecord) -> Bool {
        if a.hasAdjustments != b.hasAdjustments { return a.hasAdjustments }
        return a.localIdentifier < b.localIdentifier
    }

    /// Moments compete for their first slot in this order (RQ-057).
    static func momentCoveragePriority(
        _ a: MomentBuilder.DraftMoment,
        _ b: MomentBuilder.DraftMoment
    ) -> Bool {
        let aFavourite = a.captures.contains(where: \.isFavorite)
        let bFavourite = b.captures.contains(where: \.isFavorite)
        if aFavourite != bFavourite { return aFavourite }
        if a.kind.anchorPriority != b.kind.anchorPriority {
            return a.kind.anchorPriority < b.kind.anchorPriority
        }
        if a.captures.count != b.captures.count { return a.captures.count > b.captures.count }
        return MomentBuilder.momentOrder(a, b)
    }

    /// The cover competes across every displayed capture, with stills and video equal.
    ///
    /// There is no still-photo preference and no video quota: a video-only day gets a
    /// video cover (RQ-059, RE-040).
    private func chooseCover(
        moments: [MomentBuilder.DraftMoment],
        selected: Set<MediaID>
    ) -> MediaID? {
        let candidates = moments.flatMap(\.captures).filter { selected.contains($0.id) }
        guard !candidates.isEmpty else { return nil }
        let best = candidates.min { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            if a.hasAdjustments != b.hasAdjustments { return a.hasAdjustments }
            return MomentBuilder.captureOrder(a, b)
        }
        return best?.id
    }
}
