import Foundation

/// One capture, normalised out of PhotoKit into plain values.
///
/// This is the boundary the engine is written against. Everything downstream of it is
/// pure and testable without a photo library, which is what lets the five saved phase-0
/// days work as regression fixtures with no device attached.
struct CaptureRecord: Sendable, Codable, Hashable, Identifiable {
    let id: MediaID
    let localIdentifier: String
    let kind: MediaKind
    /// Local wall-clock time as PhotoKit reported it, with the zone it was read in.
    let captureTime: SourceTime
    /// Precomputed instant for sorting. Equal to `captureTime.instant`, held so the
    /// whole-library index does not recompute calendar arithmetic per comparison.
    let instant: Date
    let duration: TimeInterval?
    let pixelWidth: Int
    let pixelHeight: Int
    let isFavorite: Bool
    let hasAdjustments: Bool
    let isScreenshot: Bool
    let isScreenRecording: Bool
    let isHidden: Bool
    let burstIdentifier: String?
    let isRepresentativeBurstFrame: Bool
    let representedBurstFrames: Int
    let coordinate: Coordinate?
    /// Metres, or `nil` - embedded photo GPS normally reports none.
    let horizontalAccuracyMetres: Double?

    /// Which hard gate, if any, keeps this capture out of automatic display.
    ///
    /// Screenshots and screen recordings are excluded unconditionally. Tickets are
    /// included in that: the exception for text-bearing screenshots was considered
    /// and settled against on 2026-08-14, and a favourite does not override the gate.
    var exclusionReason: MediaExclusionReason? {
        if isHidden { return .hidden }
        if isScreenshot { return .screenshot }
        if isScreenRecording { return .screenRecording }
        if burstIdentifier != nil && !isRepresentativeBurstFrame { return .nonRepresentativeBurstFrame }
        return nil
    }

    var isEligible: Bool { exclusionReason == nil }

    var evidenceID: EvidenceID { EvidenceID("photo:\(localIdentifier)") }

    var observationID: ObservationID? {
        coordinate == nil ? nil : ObservationID("obs:\(localIdentifier)")
    }

    func accuracyState(precisionLimit: Double) -> AccuracyState {
        guard let accuracy = horizontalAccuracyMetres, accuracy > 0 else { return .unreported }
        return accuracy <= precisionLimit ? .precise : .imprecise
    }

    func observation(precisionLimit: Double) -> PlaceObservation? {
        guard let coordinate, let observationID else { return nil }
        return PlaceObservation(
            id: observationID,
            coordinate: coordinate,
            horizontalAccuracyMetres: horizontalAccuracyMetres,
            timestamp: captureTime,
            accuracyState: accuracyState(precisionLimit: precisionLimit),
            sourceKind: .photoAssetMetadata,
            sourceReference: localIdentifier
        )
    }

    func mediaReference(selection: MediaSelection = .notSelected) -> MediaReference {
        MediaReference(
            id: id,
            localIdentifier: localIdentifier,
            kind: kind,
            captureTime: captureTime,
            duration: duration,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            isFavorite: isFavorite,
            hasAdjustments: hasAdjustments,
            burstIdentifier: burstIdentifier,
            representedBurstFrames: representedBurstFrames,
            locationObservationID: observationID,
            eligibility: exclusionReason.map { MediaEligibility.excluded($0) } ?? .eligible,
            selection: selection
        )
    }
}
