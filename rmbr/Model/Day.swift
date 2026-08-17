import Foundation

/// Why a day's interval opens or closes where it does.
///
/// The settled product rule is that a day ends when the person went to sleep, falling
/// back to civil midnight where there is no sleep evidence. Sleep evidence needs
/// HealthKit, which milestone 1 does not read, so every day composed here takes the
/// midnight branch and says so (RQ-022). `primarySleep` exists so the sleep-aware
/// branch drops in without reshaping `Day`.
enum BoundaryReason: Sendable, Codable, Hashable {
    case primarySleep(EvidenceID)
    case civilMidnight(timeZoneID: String)
}

struct DayInterval: Sendable, Codable, Hashable {
    let start: Date
    let end: Date
    let startReason: BoundaryReason
    let endReason: BoundaryReason
}

/// How complete this day's composition is.
enum CompositionState: String, Sendable, Codable, Hashable {
    /// Indexed but not composed. Composes when opened.
    case metadataOnly
    /// Composed from every source in scope.
    case composed
    /// Composed, and every source in scope had nothing for this day.
    case knownEmpty
    /// A cached composition whose inputs have since changed.
    case stale
}

/// What each source could say about this day.
enum CoverageState: Sendable, Codable, Hashable {
    /// The source contributed this many records.
    case contributed(itemCount: Int)
    /// The source was readable and genuinely had nothing.
    case readableEmpty
    /// Authorised over a subset only, so counts are not exhaustive.
    case partialAuthorization(itemCount: Int)
    /// The source was read but the platform does not reveal whether reading was allowed.
    case readGrantUnobservable(itemCount: Int)
    /// The source is not readable in this build.
    case unavailable(reason: String)
    /// Out of scope for this milestone. Not the same as empty.
    case notCollected
}

/// What location evidence a day had.
///
/// No public API returns pre-install visit history, established empirically in phase 0.
/// A rebuilt past day therefore has a place only where a photograph carried
/// coordinates, and this enum makes that the named, visible state rather than an
/// absence that reads like a failure.
enum LocationCoverageState: Sendable, Codable, Hashable {
    case historicalPhotoCoordinates(observationCount: Int)
    case postInstallVisits(completed: Int, ongoing: Int)
    case both(photoCoordinates: Int, completedVisits: Int, ongoingVisits: Int)
    case noHistoricalVisitSource
    case reducedAccuracyOnly(observationCount: Int)
    case unavailable(reason: String)
}

struct SourceCoverage: Sendable, Codable, Hashable {
    let photos: CoverageState
    let videos: CoverageState
    let workouts: CoverageState
    let sleep: CoverageState
    let steps: CoverageState
    let distance: CoverageState
    let calendar: CoverageState
    let weather: CoverageState
    let location: LocationCoverageState
}

/// Whole-day figures, as distinct from things that happened at a time.
///
/// Every field is `EvidenceValue`. Milestone 1 reads no health source, so health
/// figures are `.unknown(.sourceNotCollected)` - which the day page omits entirely
/// rather than printing as zero (RQ-017).
struct DayFacts: Sendable, Codable, Hashable {
    let steps: EvidenceValue<Int>
    let walkingRunningDistanceMetres: EvidenceValue<Double>
    let sleep: EvidenceValue<SleepSummary>
    let workoutCount: EvidenceValue<Int>
    let placeCount: EvidenceValue<Int>
    let weather: EvidenceValue<WeatherObservation>
}

/// Placeholder shapes for milestone 2 sources, present so `DayFacts` does not change
/// when they arrive.
struct SleepSummary: Sendable, Codable, Hashable {
    let totalAsleep: TimeInterval
    let bedtime: EvidenceValue<Date>
    let wake: EvidenceValue<Date>
    let reconciliation: String
    let sourceNames: [String]
}

struct WeatherObservation: Sendable, Codable, Hashable {
    let conditionCode: String
    let temperatureCelsius: Double
}

/// A fingerprint of everything that could change this day's composition.
///
/// Participates in every cache key so a tuning change, an engine change or a new
/// asset invalidates exactly the days it can affect (RQ-072).
struct SourceFingerprint: Sendable, Codable, Hashable {
    let engineVersion: String
    let tuningProfileVersion: String
    /// Hash over the day's contributing source records.
    let sourceHash: String
}

struct ReconstructionMetadata: Sendable, Codable, Hashable {
    let engineVersion: String
    let schemaVersion: Int
    let tuningProfileVersion: String
    let composedAt: Date
    let fingerprint: SourceFingerprint
    let warnings: Set<DayWarning>
    /// Always false in milestone 1: no HealthKit value is read, so none can be cached.
    let containsDeviceOnlyHealthEnrichment: Bool
}

enum DayWarning: String, Sendable, Codable, Hashable {
    /// The boundary time zone came from the device rather than from location evidence.
    case boundaryTimeZoneFromDevice
    /// At least one place label could not be resolved.
    case placeLabelsIncomplete
    /// At least one capture's pixels are not currently readable.
    case mediaPending
}

/// A reconstructed day. The only thing presentation ever consumes.
///
/// Presentation must be able to lay this out with PhotoKit, HealthKit, Core Location,
/// MapKit and the network all unavailable (RQ-003). Nothing here is a live framework
/// object and nothing here is generated prose (RQ-002).
struct Day: Sendable, Codable, Hashable, Identifiable {
    let id: DayID
    let schemaVersion: Int
    let interval: DayInterval
    let compositionState: CompositionState
    let moments: [Moment]
    let media: DayMedia
    /// Every media reference the day cites, keyed for lookup by the renderer.
    let mediaReferences: [MediaID: MediaReference]
    let observations: [ObservationID: PlaceObservation]
    let anchors: [PlaceAnchorID: PlaceAnchor]
    let facts: DayFacts
    let sourceCoverage: SourceCoverage
    let reconstruction: ReconstructionMetadata

    var date: LocalDate { id.date }

    func media(_ mediaID: MediaID) -> MediaReference? { mediaReferences[mediaID] }

    /// Attribution lines that must be displayed with this day, deduplicated.
    ///
    /// Geoapify's terms require OpenStreetMap attribution wherever stored location
    /// data is reused, so the requirement travels with the day rather than depending
    /// on a screen remembering to add it.
    var placeAttributions: [String] {
        var seen: [String] = []
        for moment in moments {
            guard let label = moment.place?.label.knownValue else { continue }
            for line in label.attributions where !seen.contains(line) { seen.append(line) }
        }
        return seen
    }

    var hasAnyContent: Bool {
        !moments.isEmpty || !media.eligibleMediaIDs.isEmpty
    }
}
