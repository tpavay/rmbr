import Foundation

/// What kind of evidence anchors a moment.
///
/// Milestone 1 reads photographs only, so it can produce `.historicalCapture` and
/// `.media`. The other cases exist because the engine's construction order is defined
/// over all of them and milestone 2 adds their sources without reshaping the contract.
enum MomentKind: String, Sendable, Codable, Hashable {
    /// Anchored by a logged workout. Requires HealthKit.
    case workout
    /// Anchored by a post-install `CLVisit` with both arrival and departure.
    case completedVisit
    /// Anchored by geotagged captures sharing one place anchor.
    case historicalCapture
    /// Anchored by captures alone, with no supported place.
    case media
    /// Anchored by something the person wrote or said.
    case userNote
}

/// Anchor priority for ordering moments that start at the same instant (RQ-037).
extension MomentKind {
    var anchorPriority: Int {
        switch self {
        case .workout: 0
        case .completedVisit: 1
        case .historicalCapture: 2
        case .media: 3
        case .userNote: 4
        }
    }
}

/// What length of time the evidence actually supports.
///
/// There is deliberately no single unlabelled `duration`. A completed visit, a
/// recorded workout and a span between two photographs are three different facts,
/// and the third is only ever a floor (RE-009, RQ-038 through RQ-040).
enum DurationClaim: Sendable, Codable, Hashable {
    /// Arrival and departure both observed. Only Core Location can supply this.
    case completedVisit(arrival: Date, departure: Date, evidenceID: EvidenceID)
    /// A logged workout interval.
    case recordedWorkout(start: Date, end: Date, evidenceIDs: [EvidenceID])
    /// At least this long passed between the first and last capture. Not time spent there.
    case captureFloor(firstCapture: SourceTime, lastCapture: SourceTime, evidenceIDs: [EvidenceID])
    /// A single observation. An instant, not a zero-length duration.
    case none
}

/// The observed span of a moment's supporting evidence.
struct FactualRange: Sendable, Codable, Hashable {
    let start: SourceTime
    let end: SourceTime
    /// True when both endpoints are the same observation.
    var isInstant: Bool { start == end }
}

/// Something that happened at a time, and possibly at a place.
struct Moment: Sendable, Codable, Hashable, Identifiable {
    let id: MomentID
    let kind: MomentKind
    let chronology: FactualRange
    let durationClaim: DurationClaim
    /// Present only when location evidence supports it. A moment with no geotagged
    /// capture has no place at all and never borrows one from a neighbour.
    let place: PlaceOccurrence?
    /// Every eligible capture assigned to this moment.
    let allMediaIDs: [MediaID]
    /// The budgeted subset shown inline for this moment.
    let displayedMediaIDs: [MediaID]
    let representativeMediaID: MediaID?
    let evidenceIDs: [EvidenceID]
    let warnings: Set<MomentWarning>
}

enum MomentWarning: String, Sendable, Codable, Hashable {
    /// Ordering against another source depends on a photograph's unknown time zone.
    case orderingDependsOnUnknownTimeZone
    /// Two candidate place anchors fall in the ambiguous band and were left separate.
    case ambiguousPlace
    /// A place label was requested but could not be resolved.
    case placeLabelUnresolved
}
