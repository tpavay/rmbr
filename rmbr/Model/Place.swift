import Foundation

/// A coordinate, kept as the source gave it.
struct Coordinate: Sendable, Codable, Hashable {
    let latitude: Double
    let longitude: Double

    /// Great-circle distance in metres.
    func distance(to other: Coordinate) -> Double {
        let earthRadius = 6_372_797.6
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let deltaLat = (other.latitude - latitude) * .pi / 180
        let deltaLon = (other.longitude - longitude) * .pi / 180
        let a = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// How trustworthy a fix's precision is.
///
/// A photograph's embedded coordinate usually reports no horizontal accuracy at all.
/// That is not the same as a reduced-accuracy Core Location fix, which may be tens of
/// kilometres out and must never enter venue clustering (RQ-012), so the two states
/// stay separate rather than both becoming "unknown accuracy".
enum AccuracyState: String, Sendable, Codable, Hashable {
    /// Horizontal accuracy is reported and within the precise threshold.
    case precise
    /// Horizontal accuracy is reported and worse than the precise threshold.
    case imprecise
    /// No horizontal accuracy accompanies the fix, as is normal for embedded photo GPS.
    case unreported
    /// The person granted approximate location only. City-level geography at best.
    case reducedAuthorization
}

enum LocationSourceKind: String, Sendable, Codable, Hashable {
    case photoAssetMetadata
    case coreLocationVisit
    case coreLocationFix
    case userProvided
}

/// One raw coordinate reading. Clustering and labelling never rewrite it (RQ-041, RE-032).
struct PlaceObservation: Sendable, Codable, Hashable, Identifiable {
    let id: ObservationID
    let coordinate: Coordinate
    /// Metres, or `nil` when the source reported none.
    let horizontalAccuracyMetres: Double?
    let timestamp: SourceTime
    let accuracyState: AccuracyState
    let sourceKind: LocationSourceKind
    /// The asset or event this reading came from.
    let sourceReference: String

    /// Whether this reading may take part in venue-level clustering.
    var isVenueEligible: Bool {
        switch accuracyState {
        case .precise, .unreported: true
        case .imprecise, .reducedAuthorization: false
        }
    }
}

/// A physical place hypothesis: a building, property or bounded feature that may
/// contain several semantic places.
///
/// An anchor is not a business and not a name. Keeping it separate from provider
/// identity and from a person's own label is what makes corrections, provider
/// renames and moves reversible (RE-032 through RE-036).
struct PlaceAnchor: Sendable, Codable, Hashable, Identifiable {
    let id: PlaceAnchorID
    /// Mean of the contributing coordinates.
    var centroid: Coordinate
    /// Greatest distance in metres between any contributing coordinate and the centroid.
    var spanMetres: Double
    var observationIDs: [ObservationID]
}

/// How specific a printed place label is.
enum PlaceSpecificity: String, Sendable, Codable, Hashable, Comparable {
    case venue
    case building
    case neighbourhood
    case city
    case region
    case country

    private var rank: Int {
        switch self {
        case .venue: 0
        case .building: 1
        case .neighbourhood: 2
        case .city: 3
        case .region: 4
        case .country: 5
        }
    }

    static func < (lhs: PlaceSpecificity, rhs: PlaceSpecificity) -> Bool { lhs.rank < rhs.rank }
}

/// Which tier of the naming cascade produced a label (RQ-044, RE-033).
enum PlaceLabelOrigin: String, Sendable, Codable, Hashable {
    case personCorrection
    case providerPOI
    case providerGeography
}

/// The label rmbr prints for a place, together with what licenses it to be stored.
///
/// Apple forbids permanent storage of MapKit place names, so the durable label comes
/// from Geoapify, whose terms permit indefinite retention and require OpenStreetMap
/// attribution wherever the stored data is reused.
///
/// Two credits are owed and both travel with the label. The service credit is owed for
/// using Geoapify at all, whichever datasource happened to answer, and the datasource
/// credit is owed by the individual result - Geoapify answers from OpenAddresses and Who
/// is On First as well as OpenStreetMap, so crediting only the datasource would let a day
/// built from OpenAddresses results show no OpenStreetMap credit at all.
struct ResolvedPlaceLabel: Sendable, Codable, Hashable {
    let text: String
    let specificity: PlaceSpecificity
    let origin: PlaceLabelOrigin
    let confidence: Double?
    /// Provider name, e.g. `geoapify`.
    let provider: String
    /// Credit owed by the datasource that answered this particular query.
    let attribution: String
    /// Credit owed for using the service, whatever answered.
    let serviceAttribution: String
    /// When the label was fetched. The stored label is historical and is never re-resolved.
    let fetchedAt: Date

    /// Every line that must appear wherever this label is shown, in display order.
    var attributions: [String] {
        var lines = [serviceAttribution]
        if !attribution.isEmpty, attribution != serviceAttribution { lines.append(attribution) }
        return lines
    }

    init(
        text: String,
        specificity: PlaceSpecificity,
        origin: PlaceLabelOrigin,
        confidence: Double?,
        provider: String,
        attribution: String,
        serviceAttribution: String = OpenStreetMap.attribution,
        fetchedAt: Date
    ) {
        self.text = text
        self.specificity = specificity
        self.origin = origin
        self.confidence = confidence
        self.provider = provider
        self.attribution = attribution
        self.serviceAttribution = serviceAttribution
        self.fetchedAt = fetchedAt
    }

    /// A ledger written before the service credit was stored separately still names real
    /// places, so it is read back with the service credit restored rather than discarded.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        specificity = try container.decode(PlaceSpecificity.self, forKey: .specificity)
        origin = try container.decode(PlaceLabelOrigin.self, forKey: .origin)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        provider = try container.decode(String.self, forKey: .provider)
        attribution = try container.decode(String.self, forKey: .attribution)
        serviceAttribution = try container.decodeIfPresent(
            String.self,
            forKey: .serviceAttribution
        ) ?? OpenStreetMap.attribution
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
    }
}

/// A place as it appears on one moment.
struct PlaceOccurrence: Sendable, Codable, Hashable {
    let anchorID: PlaceAnchorID
    let observationIDs: [ObservationID]
    let coordinate: Coordinate
    /// Known only for a completed post-install visit, which milestone 1 cannot produce.
    let visitInterval: EvidenceValue<DateIntervalValue>
    /// Known only when at least two captures at this anchor differ in time.
    let captureFloor: EvidenceValue<DateIntervalValue>
    /// The printed label, or an explicit unknown. Never invented, never inferred from a neighbour.
    let label: EvidenceValue<ResolvedPlaceLabel>
}

/// A `DateInterval` that round-trips through `Codable` without Foundation's
/// interval encoding, and cannot be silently constructed backwards.
struct DateIntervalValue: Sendable, Codable, Hashable {
    let start: Date
    let end: Date

    init?(start: Date, end: Date) {
        guard end >= start else { return nil }
        self.start = start
        self.end = end
    }

    var duration: TimeInterval { end.timeIntervalSince(start) }
}
