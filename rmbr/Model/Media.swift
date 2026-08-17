import Foundation

enum MediaKind: String, Sendable, Codable, Hashable {
    case photo
    case livePhoto
    case video
}

/// Why a capture is kept out of automatic display.
///
/// Exclusion is a hard gate applied before ranking, never a score penalty, and a
/// favourite never overrides it (RE-037, RQ-009). The categories are reported as
/// counts so a day can stay truthfully dense without revealing excluded pixels.
enum MediaExclusionReason: String, Sendable, Codable, Hashable, CaseIterable {
    case screenshot
    case screenRecording
    case hidden
    case nonRepresentativeBurstFrame
    case duplicate
    case unreadable
}

/// A capture's standing in automatic display.
enum MediaEligibility: Sendable, Codable, Hashable {
    case eligible
    case excluded(MediaExclusionReason)

    var isEligible: Bool {
        if case .eligible = self { return true }
        return false
    }

    var exclusionReason: MediaExclusionReason? {
        if case .excluded(let reason) = self { return reason }
        return nil
    }
}

/// Whether a capture was chosen for inline display, and by whose decision.
enum MediaSelection: String, Sendable, Codable, Hashable {
    case selected
    case notSelected
    case selectedByPerson
    case removedByPerson
}

/// A reference to one capture in the library. Never a `PHAsset`.
///
/// The renderer must be able to lay a day out with PhotoKit unavailable, so this
/// carries every fact presentation needs and no live framework object (RE-001, RQ-003).
struct MediaReference: Sendable, Codable, Hashable, Identifiable {
    let id: MediaID
    /// Device-scoped PhotoKit identifier. Durable only on this device.
    let localIdentifier: String
    let kind: MediaKind
    let captureTime: SourceTime
    /// Playback length. Video only - never a claim about the length of the event.
    let duration: TimeInterval?
    let pixelWidth: Int
    let pixelHeight: Int
    let isFavorite: Bool
    let hasAdjustments: Bool
    let burstIdentifier: String?
    /// Frames the burst contained, of which this reference represents one.
    let representedBurstFrames: Int
    /// The coordinate observation this capture carried, when it carried one.
    let locationObservationID: ObservationID?
    let eligibility: MediaEligibility
    var selection: MediaSelection

    var aspectRatio: Double {
        guard pixelHeight > 0 else { return 1 }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    var evidenceID: EvidenceID { EvidenceID("photo:\(localIdentifier)") }
}

/// Capture counts as the library actually holds them, taken before any display filtering.
///
/// Filtering must never reduce these. A day that contained thirty-two captures reports
/// thirty-two even when one photograph is displayed (RE-012, RQ-053).
struct RawCaptureCounts: Sendable, Codable, Hashable {
    var accessibleCaptureCount: Int = 0
    var photoCount: Int = 0
    var videoCount: Int = 0
    var livePhotoCount: Int = 0
    var screenshotCount: Int = 0
    var screenRecordingCount: Int = 0
    var rawBurstFrameCount: Int = 0
    var favoriteCount: Int = 0
    var geotaggedCount: Int = 0
}

/// Counts of what was kept out of automatic display, by category.
struct MediaExclusionCounts: Sendable, Codable, Hashable {
    var byReason: [String: Int] = [:]

    var total: Int { byReason.values.reduce(0, +) }

    mutating func record(_ reason: MediaExclusionReason) {
        byReason[reason.rawValue, default: 0] += 1
    }

    func count(of reason: MediaExclusionReason) -> Int {
        byReason[reason.rawValue] ?? 0
    }
}

/// A day's media: everything eligible, the budgeted inline subset, and the cover.
struct DayMedia: Sendable, Codable, Hashable {
    /// Truthful counts, or unknown when access was declined or limited and the
    /// library cannot be claimed to have been seen exhaustively.
    let rawCounts: EvidenceValue<RawCaptureCounts>
    /// Every eligible capture on the day, so full-screen paging never has to borrow
    /// from another day (RQ-062).
    let eligibleMediaIDs: [MediaID]
    /// The budgeted subset displayed inline.
    let selectedMediaIDs: [MediaID]
    let coverMediaID: MediaID?
    let exclusionCounts: MediaExclusionCounts
}
