import Foundation

/// Every numeric decision the engine makes, in one versioned record.
///
/// These are starting hypotheses from one person's library, not population findings.
/// They live together, and the profile version participates in the source fingerprint,
/// so changing one constant invalidates exactly the days it can affect and no saved
/// composition can quietly mix two generations of thresholds (RQ-072, RE-020's preamble).
struct ReconstructionTuningProfile: Sendable, Codable, Hashable {
    let version: String

    // Day boundary. Retained for the milestone 2 sleep-aware branch; unused while
    // no sleep source is read.
    let primarySleepSearchStartHour: Int
    let primarySleepSearchEndHour: Int
    let sleepEpisodeJoinGap: TimeInterval
    let minimumPrimarySleep: TimeInterval

    // Moment construction.
    /// Consecutive captures at one anchor stay in the same historical-capture moment
    /// while they are no further apart than this.
    let historicalCaptureContinuationGap: TimeInterval
    /// Leftover captures cluster while adjacent captures are no further apart than this.
    let leftoverMediaGap: TimeInterval

    // Place clustering.
    /// A reported horizontal accuracy worse than this cannot drive a venue merge.
    let preciseLocationMaximumAccuracyMetres: Double
    /// Precise fixes this close may merge on distance alone.
    let placeHardMergeDistanceMetres: Double
    /// Between the hard-merge distance and this, fixes stay separate without identity evidence.
    let placeAmbiguousUpperDistanceMetres: Double

    // Media selection.
    let smallDayMaximum: Int
    let busyDayMinimumBudget: Int
    let busyDayMaximumBudget: Int

    // Backfill.
    /// Calendar months, including the current partial one, that are fully composed.
    let fullyComposedMonthBuckets: Int
    /// A day must clear these to be allowed to represent an older month.
    let monthlyMinimumDistinctPlaces: Int
    let monthlyMinimumCaptureVolume: Int

    static let v1 = ReconstructionTuningProfile(
        version: "tuning.v1",
        primarySleepSearchStartHour: 12,
        primarySleepSearchEndHour: 12,
        sleepEpisodeJoinGap: 30 * 60,
        minimumPrimarySleep: 120 * 60,
        historicalCaptureContinuationGap: 120 * 60,
        leftoverMediaGap: 45 * 60,
        preciseLocationMaximumAccuracyMetres: 50,
        placeHardMergeDistanceMetres: 25,
        placeAmbiguousUpperDistanceMetres: 75,
        smallDayMaximum: 5,
        busyDayMinimumBudget: 5,
        busyDayMaximumBudget: 10,
        fullyComposedMonthBuckets: 24,
        monthlyMinimumDistinctPlaces: 2,
        monthlyMinimumCaptureVolume: 3
    )
}
