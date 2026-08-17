import Foundation

/// Groups a day's eligible captures into moments.
///
/// Construction order is fixed: workouts, then completed or historical visits, then
/// leftover media, then notes, then corroborated calendar labels (RQ-026). Milestone 1
/// reads photographs only, so it enters that order at the historical-visit step and
/// leaves after leftover media. Randomising the order captures arrive in must not
/// change the partition, which is why grouping works from sorted, normalised records
/// rather than from PhotoKit's delivery order.
struct MomentBuilder: Sendable {
    let tuning: ReconstructionTuningProfile

    struct Input: Sendable {
        /// Eligible captures only, in capture-time order.
        let captures: [CaptureRecord]
        /// Which anchor each venue-eligible observation joined, if any.
        let anchorByObservation: [ObservationID: PlaceAnchorID]
    }

    /// A moment before media selection has decided what is displayed.
    struct DraftMoment: Sendable {
        let id: MomentID
        let kind: MomentKind
        let chronology: FactualRange
        let durationClaim: DurationClaim
        let anchorID: PlaceAnchorID?
        let captures: [CaptureRecord]
        var warnings: Set<MomentWarning>
    }

    func build(_ input: Input) -> [DraftMoment] {
        let ordered = input.captures.sorted(by: Self.captureOrder)

        var assigned: Set<MediaID> = []
        var drafts: [DraftMoment] = []

        // Historical-capture anchors. Geotagged captures sharing one place anchor form
        // one moment while consecutive captures stay inside the continuation gap
        // (RQ-032). An anchor visited twice in a day with a long gap between the visits
        // is two moments, not one long one.
        var byAnchor: [PlaceAnchorID: [CaptureRecord]] = [:]
        for capture in ordered {
            guard let observationID = capture.observationID,
                  let anchorID = input.anchorByObservation[observationID] else { continue }
            byAnchor[anchorID, default: []].append(capture)
        }

        for anchorID in byAnchor.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let captures = byAnchor[anchorID] ?? []
            for group in Self.split(captures, whenGapExceeds: tuning.historicalCaptureContinuationGap) {
                drafts.append(makeDraft(kind: .historicalCapture, anchorID: anchorID, captures: group))
                assigned.formUnion(group.map(\.id))
            }
        }

        // Leftover media. Everything not assigned to an anchor - which is every capture
        // that carried no coordinate, and every capture whose coordinate was too
        // imprecise to place - clusters on time alone (RQ-035). Proximity to a
        // geotagged cluster never lends an ungeotagged capture that cluster's place
        // (RQ-034): a photograph with no coordinate has no place, full stop.
        let leftovers = ordered.filter { !assigned.contains($0.id) }
        for group in splitLeftovers(leftovers) {
            drafts.append(makeDraft(kind: .media, anchorID: nil, captures: group))
        }

        return drafts.sorted(by: Self.momentOrder)
    }

    private func makeDraft(
        kind: MomentKind,
        anchorID: PlaceAnchorID?,
        captures: [CaptureRecord]
    ) -> DraftMoment {
        let sorted = captures.sorted(by: Self.captureOrder)
        let first = sorted.first!
        let last = sorted.last!
        let identity = MomentID(
            "moment:\(kind.rawValue):\(StableHash.hex(of: sorted.map(\.localIdentifier).sorted()))"
        )
        // A single capture is an instant, not a zero-length duration, and two captures
        // at one place establish only that at least that long passed between them
        // (RQ-039, RQ-040, RE-030). Neither may be promoted to time spent there.
        let claim: DurationClaim = sorted.count > 1 && first.instant != last.instant
            ? .captureFloor(
                firstCapture: first.captureTime,
                lastCapture: last.captureTime,
                evidenceIDs: sorted.map(\.evidenceID)
            )
            : .none
        return DraftMoment(
            id: identity,
            kind: kind,
            chronology: FactualRange(start: first.captureTime, end: last.captureTime),
            durationClaim: claim,
            anchorID: anchorID,
            captures: sorted,
            warnings: []
        )
    }

    /// Splits leftover captures on the time gap, and additionally where two adjacent
    /// captures carry coordinates that contradict each other.
    private func splitLeftovers(_ captures: [CaptureRecord]) -> [[CaptureRecord]] {
        var groups: [[CaptureRecord]] = []
        var current: [CaptureRecord] = []

        for capture in captures {
            guard let previous = current.last else {
                current = [capture]
                continue
            }
            let gap = capture.instant.timeIntervalSince(previous.instant)
            var contradicts = false
            if let a = previous.coordinate, let b = capture.coordinate {
                contradicts = a.distance(to: b) > tuning.placeAmbiguousUpperDistanceMetres
            }
            if gap > tuning.leftoverMediaGap || contradicts {
                groups.append(current)
                current = [capture]
            } else {
                current.append(capture)
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private static func split(
        _ captures: [CaptureRecord],
        whenGapExceeds gap: TimeInterval
    ) -> [[CaptureRecord]] {
        var groups: [[CaptureRecord]] = []
        var current: [CaptureRecord] = []
        for capture in captures {
            if let previous = current.last,
               capture.instant.timeIntervalSince(previous.instant) > gap {
                groups.append(current)
                current = []
            }
            current.append(capture)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Deterministic capture order: time, then a stable identifier.
    static func captureOrder(_ a: CaptureRecord, _ b: CaptureRecord) -> Bool {
        if a.instant != b.instant { return a.instant < b.instant }
        return a.localIdentifier < b.localIdentifier
    }

    /// Moments sort by factual start, then factual end, then anchor priority, then a
    /// stable identifier (RQ-037).
    static func momentOrder(_ a: DraftMoment, _ b: DraftMoment) -> Bool {
        let aStart = a.chronology.start.instant
        let bStart = b.chronology.start.instant
        if aStart != bStart { return aStart < bStart }
        let aEnd = a.chronology.end.instant
        let bEnd = b.chronology.end.instant
        if aEnd != bEnd { return aEnd < bEnd }
        if a.kind.anchorPriority != b.kind.anchorPriority {
            return a.kind.anchorPriority < b.kind.anchorPriority
        }
        return a.id.rawValue < b.id.rawValue
    }
}
