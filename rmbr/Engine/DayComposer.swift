import Foundation

/// A place label that composition wanted and did not have.
///
/// Composition never waits on the network. It emits the day with the place marked
/// unknown and reports the lookup it would like, so the day is readable immediately
/// and gains its label on a later revision (RQ-051, RE-051).
struct PendingPlaceLookup: Sendable, Hashable {
    let anchorID: PlaceAnchorID
    let coordinate: Coordinate
}

struct CompositionResult: Sendable {
    let day: Day
    let pendingPlaceLookups: [PendingPlaceLookup]
}

/// Turns a day's normalised captures into a `Day`.
///
/// Pure, synchronous and deterministic: identical records, tuning and engine version
/// produce an identical day, whatever order the records arrive in (RQ-001). It reads no
/// framework and performs no I/O, which is what lets the phase-0 fixtures run as tests.
struct DayComposer: Sendable {
    let tuning: ReconstructionTuningProfile
    let boundaryPolicy: any DayBoundaryPolicy

    init(
        tuning: ReconstructionTuningProfile = .v1,
        boundaryPolicy: any DayBoundaryPolicy = MidnightDayBoundaryPolicy()
    ) {
        self.tuning = tuning
        self.boundaryPolicy = boundaryPolicy
    }

    struct Context: Sendable {
        let timeZone: TimeZone
        let timeZoneTier: TimeZoneTier
        /// Whether the person granted access to the whole library. Limited access means
        /// no count may be presented as exhaustive (RQ-053).
        let hasFullLibraryAccess: Bool
        /// Labels already resolved and stored, looked up by anchor centroid.
        let placeLabels: PlaceLabelLookup
        let composedAt: Date

        init(
            timeZone: TimeZone,
            timeZoneTier: TimeZoneTier = .deviceTimeZoneAtIndexing,
            hasFullLibraryAccess: Bool,
            placeLabels: PlaceLabelLookup = .empty,
            composedAt: Date
        ) {
            self.timeZone = timeZone
            self.timeZoneTier = timeZoneTier
            self.hasFullLibraryAccess = hasFullLibraryAccess
            self.placeLabels = placeLabels
            self.composedAt = composedAt
        }
    }

    /// Synchronous lookup of an already-stored label for a coordinate.
    struct PlaceLabelLookup: Sendable {
        let label: @Sendable (Coordinate) -> ResolvedPlaceLabel?
        static let empty = PlaceLabelLookup { _ in nil }
    }

    func compose(date: LocalDate, captures: [CaptureRecord], context: Context) -> CompositionResult {
        let dayID = DayID(date: date, homeTimeZoneID: context.timeZone.identifier)
        let interval = boundaryPolicy.interval(
            for: date,
            evidence: .withoutSleep(timeZone: context.timeZone, tier: context.timeZoneTier)
        )

        let counts = Self.rawCounts(of: captures)
        var exclusions = MediaExclusionCounts()
        for capture in captures {
            if let reason = capture.exclusionReason { exclusions.record(reason) }
        }

        let eligible = captures.filter(\.isEligible).sorted(by: MomentBuilder.captureOrder)

        var observations: [ObservationID: PlaceObservation] = [:]
        var orderedObservations: [PlaceObservation] = []
        for capture in eligible {
            guard let observation = capture.observation(
                precisionLimit: tuning.preciseLocationMaximumAccuracyMetres
            ) else { continue }
            observations[observation.id] = observation
            orderedObservations.append(observation)
        }

        let places = PlaceAnchorResolver(tuning: tuning).resolve(observations: orderedObservations)
        let drafts = MomentBuilder(tuning: tuning).build(
            MomentBuilder.Input(
                captures: eligible,
                anchorByObservation: places.anchorByObservation
            )
        )
        let selection = MediaSelector(tuning: tuning).select(moments: drafts)

        var pending: [PendingPlaceLookup] = []
        var dayWarnings: Set<DayWarning> = []
        if context.timeZoneTier == .deviceTimeZoneAtIndexing {
            dayWarnings.insert(.boundaryTimeZoneFromDevice)
        }

        var moments: [Moment] = []
        for draft in drafts {
            var warnings = draft.warnings
            var occurrence: PlaceOccurrence?

            if let anchorID = draft.anchorID, let anchor = places.anchors[anchorID] {
                let label = context.placeLabels.label(anchor.centroid)
                if label == nil {
                    pending.append(PendingPlaceLookup(anchorID: anchorID, coordinate: anchor.centroid))
                    warnings.insert(.placeLabelUnresolved)
                    dayWarnings.insert(.placeLabelsIncomplete)
                }
                let floor: EvidenceValue<DateIntervalValue>
                if case .captureFloor(let first, let last, _) = draft.durationClaim,
                   let value = DateIntervalValue(start: first.instant, end: last.instant) {
                    floor = .known(value)
                } else {
                    floor = .unknown(.notEstablished)
                }
                occurrence = PlaceOccurrence(
                    anchorID: anchorID,
                    observationIDs: anchor.observationIDs,
                    coordinate: anchor.centroid,
                    // No public API returns pre-install visit history, so a photographs-only
                    // day can never know an arrival or a departure (RQ-011, RE-019).
                    visitInterval: .unknown(.notCollectedBeforeInstall),
                    captureFloor: floor,
                    label: label.map { EvidenceValue.known($0) } ?? .unknown(.notEstablished)
                )
            }

            if draft.captures.contains(where: { !$0.captureTime.hasTrustworthyTimeZone })
                && draft.captures.count > 1 {
                // Every capture in the moment came from the same library read, so their
                // ordering relative to each other is sound. The warning records that
                // ordering against an absolute-time source would not be.
                warnings.insert(.orderingDependsOnUnknownTimeZone)
            }

            moments.append(
                Moment(
                    id: draft.id,
                    kind: draft.kind,
                    chronology: draft.chronology,
                    durationClaim: draft.durationClaim,
                    place: occurrence,
                    allMediaIDs: draft.captures.map(\.id),
                    displayedMediaIDs: selection.displayedByMoment[draft.id] ?? [],
                    representativeMediaID: selection.representativeByMoment[draft.id],
                    evidenceIDs: draft.captures.map(\.evidenceID),
                    warnings: warnings
                )
            )
        }

        let selectedIDs = Set(selection.selectedMediaIDs)
        var references: [MediaID: MediaReference] = [:]
        for capture in eligible {
            references[capture.id] = capture.mediaReference(
                selection: selectedIDs.contains(capture.id) ? .selected : .notSelected
            )
        }

        let placeCount = places.anchors.count
        let facts = DayFacts(
            // Milestone 1 reads no health source. Not zero, not denied: not collected.
            steps: .unknown(.sourceNotCollected),
            walkingRunningDistanceMetres: .unknown(.sourceNotCollected),
            sleep: .unknown(.sourceNotCollected),
            workoutCount: .unknown(.sourceNotCollected),
            // A day with no geotagged capture has not established that the person went
            // nowhere. The number of places is unknown, not zero.
            placeCount: placeCount > 0 ? .known(placeCount) : .unknown(.notEstablished),
            weather: .unknown(.sourceNotCollected)
        )

        let state: CompositionState
        if captures.isEmpty {
            state = context.hasFullLibraryAccess ? .knownEmpty : .composed
        } else {
            state = .composed
        }

        let day = Day(
            id: dayID,
            schemaVersion: ReconstructionVersion.schema,
            interval: interval,
            compositionState: state,
            moments: moments,
            media: DayMedia(
                rawCounts: context.hasFullLibraryAccess
                    ? .known(counts)
                    : .unknown(.partialAuthorization),
                eligibleMediaIDs: eligible.map(\.id),
                selectedMediaIDs: selection.selectedMediaIDs,
                coverMediaID: selection.coverMediaID,
                exclusionCounts: exclusions
            ),
            mediaReferences: references,
            observations: observations,
            anchors: places.anchors,
            facts: facts,
            sourceCoverage: Self.coverage(
                counts: counts,
                observationCount: observations.count,
                hasFullLibraryAccess: context.hasFullLibraryAccess
            ),
            reconstruction: ReconstructionMetadata(
                engineVersion: ReconstructionVersion.engine,
                schemaVersion: ReconstructionVersion.schema,
                tuningProfileVersion: tuning.version,
                composedAt: context.composedAt,
                fingerprint: Self.fingerprint(captures: captures, tuning: tuning),
                warnings: dayWarnings,
                containsDeviceOnlyHealthEnrichment: false
            )
        )

        return CompositionResult(day: day, pendingPlaceLookups: pending)
    }

    static func rawCounts(of captures: [CaptureRecord]) -> RawCaptureCounts {
        var counts = RawCaptureCounts()
        for capture in captures {
            // Hidden assets are neither displayed nor counted in the day summary.
            guard !capture.isHidden else { continue }
            guard capture.isRepresentativeBurstFrame || capture.burstIdentifier == nil else {
                counts.rawBurstFrameCount += 1
                continue
            }
            counts.accessibleCaptureCount += 1
            counts.rawBurstFrameCount += max(0, capture.representedBurstFrames)
            if capture.isScreenshot { counts.screenshotCount += 1 }
            if capture.isScreenRecording { counts.screenRecordingCount += 1 }
            switch capture.kind {
            case .photo: counts.photoCount += 1
            case .livePhoto:
                counts.photoCount += 1
                counts.livePhotoCount += 1
            case .video: counts.videoCount += 1
            }
            if capture.isFavorite { counts.favoriteCount += 1 }
            if capture.coordinate != nil { counts.geotaggedCount += 1 }
        }
        return counts
    }

    static func coverage(
        counts: RawCaptureCounts,
        observationCount: Int,
        hasFullLibraryAccess: Bool
    ) -> SourceCoverage {
        func photoState(_ count: Int) -> CoverageState {
            guard hasFullLibraryAccess else { return .partialAuthorization(itemCount: count) }
            return count > 0 ? .contributed(itemCount: count) : .readableEmpty
        }
        return SourceCoverage(
            photos: photoState(counts.photoCount),
            videos: photoState(counts.videoCount),
            // Named, and named as out of scope. "Not collected" is not "empty" and is
            // not "denied": milestone 1 does not read these sources at all.
            workouts: .notCollected,
            sleep: .notCollected,
            steps: .notCollected,
            distance: .notCollected,
            calendar: .notCollected,
            weather: .notCollected,
            location: observationCount > 0
                ? .historicalPhotoCoordinates(observationCount: observationCount)
                : .noHistoricalVisitSource
        )
    }

    static func fingerprint(
        captures: [CaptureRecord],
        tuning: ReconstructionTuningProfile
    ) -> SourceFingerprint {
        let parts = captures
            .map { capture in
                [
                    capture.localIdentifier,
                    String(capture.instant.timeIntervalSince1970),
                    capture.isFavorite ? "f" : "-",
                    capture.hasAdjustments ? "a" : "-",
                    capture.coordinate.map { "\($0.latitude),\($0.longitude)" } ?? "-"
                ].joined(separator: ":")
            }
            .sorted()
        return SourceFingerprint(
            engineVersion: ReconstructionVersion.engine,
            tuningProfileVersion: tuning.version,
            sourceHash: StableHash.hex(of: parts)
        )
    }
}
