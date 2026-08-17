import Foundation

/// The whole archive's metadata-only picture: what each day offers, and where every
/// confident place anchor in the library is.
///
/// Built in one pass over the resident index, with no pixels, no network and no health
/// read, which is what lets older-month refinement run behind the recent window rather
/// than in front of it (RQ-070).
struct ArchiveSurvey: Sendable {
    var signalsByDate: [LocalDate: DaySignals] = [:]
    var places: ArchivePlaceIndex
    var elapsedSeconds: Double = 0

    init(mergeDistanceMetres: Double) {
        self.places = ArchivePlaceIndex(mergeDistanceMetres: mergeDistanceMetres)
    }
}

enum ArchiveSurveyor {
    /// Computes each day's candidate signals.
    ///
    /// This runs the same anchor resolver and moment builder a full composition does,
    /// so a day's moment count here is the moment count the person will see. It stops
    /// short of media selection and place naming, which are the parts that cost
    /// something.
    static func survey(index: CaptureIndex, tuning: ReconstructionTuningProfile) -> ArchiveSurvey {
        let started = Date()
        var survey = ArchiveSurvey(mergeDistanceMetres: tuning.placeHardMergeDistanceMetres)
        let anchorResolver = PlaceAnchorResolver(tuning: tuning)
        let momentBuilder = MomentBuilder(tuning: tuning)

        for date in index.datesWithCaptures {
            let captures = index.records(on: date)
            let rawCounts = DayComposer.rawCounts(of: captures)
            let eligible = captures.filter(\.isEligible)
            guard !eligible.isEmpty else {
                survey.signalsByDate[date] = DaySignals(
                    date: date,
                    eligibleMediaCount: 0,
                    favoriteEligibleMediaCount: 0,
                    momentCount: 0,
                    momentsWithMediaCount: 0,
                    placeAnchorCentroids: [],
                    rawCounts: rawCounts
                )
                continue
            }

            var observations: [ObservationID: PlaceObservation] = [:]
            var ordered: [PlaceObservation] = []
            for capture in eligible {
                guard let observation = capture.observation(
                    precisionLimit: tuning.preciseLocationMaximumAccuracyMetres
                ) else { continue }
                observations[observation.id] = observation
                ordered.append(observation)
            }

            let places = anchorResolver.resolve(observations: ordered)
            let moments = momentBuilder.build(
                MomentBuilder.Input(
                captures: eligible,
                anchorByObservation: places.anchorByObservation
            )
            )
            let centroids = places.anchors.values
                .sorted { $0.id.rawValue < $1.id.rawValue }
                .map(\.centroid)
            for centroid in centroids {
                survey.places.insert(centroid, on: date)
            }

            // Moments arrive in chronological order, so the first one carrying an anchor
            // is the place the composed day prints first.
            let headline = moments
                .compactMap(\.anchorID)
                .first
                .flatMap { places.anchors[$0]?.centroid }

            survey.signalsByDate[date] = DaySignals(
                date: date,
                eligibleMediaCount: eligible.count,
                favoriteEligibleMediaCount: eligible.filter(\.isFavorite).count,
                momentCount: moments.count,
                momentsWithMediaCount: moments.filter { !$0.captures.isEmpty }.count,
                placeAnchorCentroids: centroids,
                rawCounts: rawCounts,
                headlineAnchorCentroid: headline
            )
        }

        survey.elapsedSeconds = Date().timeIntervalSince(started)
        return survey
    }

    /// Chooses one representative for every calendar month older than the recent window.
    static func monthEntries(
        index: CaptureIndex,
        survey: ArchiveSurvey,
        today: LocalDate,
        tuning: ReconstructionTuningProfile
    ) -> [MonthEntry] {
        let policy = BackfillPolicy(tuning: tuning)
        let selector = MonthlyRepresentativeSelector(tuning: tuning)
        let windowStart = policy.windowStart(today: today)

        return index.monthsWithCaptures()
            .filter { $0 < windowStart }
            .map { month in
                let days = index.dates(in: month).compactMap { survey.signalsByDate[$0] }
                return selector.select(month: month, days: days, archivePlaces: survey.places)
            }
    }
}
