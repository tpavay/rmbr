import Foundation

/// Groups a day's coordinate observations into physical place hypotheses.
///
/// The spike's single 150 m rolling centroid is deliberately not reproduced. It chains:
/// each new point can drag the centroid while staying inside the radius, so a cluster's
/// real span grows without limit, and in a dense city 150 m reaches several unrelated
/// buildings. This resolver instead admits a fix only when it is within the hard-merge
/// distance of an existing centroid *and* the anchor's total span stays inside the
/// ambiguous upper bound, which bounds the anchor to something a person would call one
/// place (RQ-042).
///
/// Fixes in the ambiguous band, and fixes beyond it, stay separate. Milestone 1 has no
/// identity evidence - no Place ID, no building footprint, no recurrence model - so
/// there is nothing that could licence a merge across the band, and a false merge is
/// harder to repair than a false split.
struct PlaceAnchorResolver: Sendable {
    let tuning: ReconstructionTuningProfile

    struct Result: Sendable {
        var anchors: [PlaceAnchorID: PlaceAnchor]
        /// Only for observations that were venue-eligible and joined an anchor.
        var anchorByObservation: [ObservationID: PlaceAnchorID]
    }

    /// - Parameter observations: in capture-time order. Order affects nothing but the
    ///   sequence anchors are created in, and identity is derived from membership, so
    ///   the result is stable for a stable input set.
    func resolve(observations: [PlaceObservation]) -> Result {
        struct Cluster {
            var centroid: Coordinate
            var members: [PlaceObservation]
        }

        var clusters: [Cluster] = []

        for observation in observations where observation.isVenueEligible {
            var bestIndex: Int?
            var bestDistance = Double.greatestFiniteMagnitude

            for (index, cluster) in clusters.enumerated() {
                let distance = cluster.centroid.distance(to: observation.coordinate)
                guard distance <= tuning.placeHardMergeDistanceMetres else { continue }
                let candidateCentroid = Self.centroid(
                    of: cluster.members.map(\.coordinate) + [observation.coordinate]
                )
                let candidateSpan = Self.span(
                    of: cluster.members.map(\.coordinate) + [observation.coordinate],
                    around: candidateCentroid
                )
                guard candidateSpan <= tuning.placeAmbiguousUpperDistanceMetres else { continue }
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }

            if let bestIndex {
                clusters[bestIndex].members.append(observation)
                clusters[bestIndex].centroid = Self.centroid(of: clusters[bestIndex].members.map(\.coordinate))
            } else {
                clusters.append(Cluster(centroid: observation.coordinate, members: [observation]))
            }
        }

        var anchors: [PlaceAnchorID: PlaceAnchor] = [:]
        var anchorByObservation: [ObservationID: PlaceAnchorID] = [:]

        for cluster in clusters {
            let memberIDs = cluster.members.map(\.id.rawValue).sorted()
            let anchorID = PlaceAnchorID("anchor:\(StableHash.hex(of: memberIDs))")
            let centroid = Self.centroid(of: cluster.members.map(\.coordinate))
            anchors[anchorID] = PlaceAnchor(
                id: anchorID,
                centroid: centroid,
                spanMetres: Self.span(of: cluster.members.map(\.coordinate), around: centroid),
                observationIDs: cluster.members.map(\.id)
            )
            for member in cluster.members {
                anchorByObservation[member.id] = anchorID
            }
        }

        return Result(anchors: anchors, anchorByObservation: anchorByObservation)
    }

    /// Arithmetic mean of the coordinates.
    ///
    /// Adequate for anchors bounded to 75 m, where the difference from a spherical
    /// mean is far below the noise in the fixes themselves.
    static func centroid(of coordinates: [Coordinate]) -> Coordinate {
        guard !coordinates.isEmpty else { return Coordinate(latitude: 0, longitude: 0) }
        let count = Double(coordinates.count)
        return Coordinate(
            latitude: coordinates.reduce(0) { $0 + $1.latitude } / count,
            longitude: coordinates.reduce(0) { $0 + $1.longitude } / count
        )
    }

    static func span(of coordinates: [Coordinate], around centroid: Coordinate) -> Double {
        coordinates.map { centroid.distance(to: $0) }.max() ?? 0
    }
}
