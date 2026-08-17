import Foundation

/// Reverse geocodes a coordinate through Geoapify.
///
/// Geoapify rather than MapKit, and the reason is licensing rather than quality. Apple's
/// Developer Program License Agreement, Attachment 6 section 2.5, permits caching Map
/// Data "on a temporary and limited basis" only, and a returned `MKMapItem.name` is Map
/// Data. rmbr's whole point is that the label recorded on the day it happened stays that
/// label forever, so a provider that only licenses temporary storage cannot supply it.
/// Geoapify licenses indefinite storage of the returned address and location data and
/// requires OpenStreetMap attribution in return, which is why every label carries its
/// attribution string with it.
///
/// The request sends a latitude and a longitude. It carries no asset identifier, no
/// timestamp, no device identifier and nothing else about the library.
struct GeoapifyReverseGeocoder: Sendable {
    /// Distance within which a returned named feature is treated as containing the
    /// query point rather than merely being the nearest thing to it.
    ///
    /// This is a deliberately conservative stand-in for the calibrated POI-confidence
    /// model the specification asks for (RQ-043's 0.85 confidence and 0.20 margin).
    /// That model needs a labelled venue corpus that does not exist yet, and picking
    /// the nearest business by distance alone is exactly what the naming rules forbid
    /// (RE-033). Until the corpus exists, a name is used only when the provider puts
    /// the feature effectively on top of the anchor; anything further away falls to a
    /// coarser tier.
    static let venueContainmentMetres: Double = 25.0

    enum Failure: Error, Sendable {
        case missingAPIKey
        case badResponse(status: Int)
        case decoding
    }

    /// The key travels as a query item, so nothing about this exchange may touch the
    /// disk: an ephemeral session keeps its cache, cookies and credentials in memory
    /// alone, which leaves the keychain the only place the key is ever written. A URL
    /// cache would buy nothing regardless - the ledger is permanent, so a coordinate is
    /// asked about once for the life of the install.
    static let privateSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    let session: URLSession
    let apiKey: String

    init(apiKey: String, session: URLSession = GeoapifyReverseGeocoder.privateSession) {
        self.apiKey = apiKey
        self.session = session
    }

    func label(for coordinate: Coordinate, now: Date = Date()) async throws -> ResolvedPlaceLabel? {
        var components = URLComponents(string: "https://api.geoapify.com/v1/geocode/reverse")!
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.6f", coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.6f", coordinate.longitude)),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "apiKey", value: apiKey)
        ]
        guard let url = components.url else { throw Failure.decoding }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.badResponse(status: http.statusCode)
        }
        let payload = try JSONDecoder().decode(GeoapifyReverseResponse.self, from: data)
        return Self.label(from: payload, at: now)
    }

    /// Applies the naming cascade to one provider response.
    ///
    /// Named point of interest, then neighbourhood, then city, then no place phrase at
    /// all. There is no building tier and there is never a street address: reverse
    /// geocoding answers with the nearest feature, so a coordinate on one side of a
    /// street resolves to the address of a different building - a precise-looking false
    /// statement about where somebody was, which is the exact class of claim this engine
    /// exists to refuse (RE-033, RQ-044). Precision comes from a person's own correction,
    /// not from the geocoder.
    ///
    /// A provider name is only a point of interest when the result carries a category.
    /// `result_type` cannot make that distinction - it reads `building` for a park - so
    /// the category is the signal, and a named result without one is an address or a
    /// building match that falls through to the geography tiers.
    static func label(from payload: GeoapifyReverseResponse, at now: Date) -> ResolvedPlaceLabel? {
        guard let result = payload.results.first else { return nil }
        let attribution = result.datasource?.attribution?.trimmed
        let datasourceCredit = (attribution?.isEmpty == false ? attribution! : OpenStreetMap.attribution)

        func make(_ text: String, _ specificity: PlaceSpecificity, _ origin: PlaceLabelOrigin) -> ResolvedPlaceLabel {
            ResolvedPlaceLabel(
                text: text,
                specificity: specificity,
                origin: origin,
                confidence: nil,
                provider: "geoapify",
                attribution: datasourceCredit,
                serviceAttribution: OpenStreetMap.attribution,
                fetchedAt: now
            )
        }

        let isContained = (result.distance ?? .greatestFiniteMagnitude) <= venueContainmentMetres
        let isPointOfInterest = !(result.categories ?? []).isEmpty

        if let name = result.name?.trimmed, !name.isEmpty, isContained, isPointOfInterest {
            return make(name, .venue, .providerPOI)
        }
        if let neighbourhood = (result.suburb ?? result.district ?? result.quarter)?.trimmed,
           !neighbourhood.isEmpty {
            return make(neighbourhood, .neighbourhood, .providerGeography)
        }
        if let city = (result.city ?? result.town ?? result.village)?.trimmed, !city.isEmpty {
            return make(city, .city, .providerGeography)
        }
        // The cascade stops at the city. A day labelled by its state or its country says
        // nothing a person would recognise as where they were, so the place phrase is
        // omitted entirely rather than widened until something matches.
        return nil
    }
}

enum OpenStreetMap {
    /// Geoapify's terms require OpenStreetMap attribution wherever the service's data is
    /// used, including for stored results.
    static let attribution = "© OpenStreetMap contributors"
}

/// The subset of Geoapify's reverse-geocode response rmbr reads.
struct GeoapifyReverseResponse: Sendable, Codable {
    struct Result: Sendable, Codable {
        let name: String?
        let street: String?
        let suburb: String?
        let district: String?
        let quarter: String?
        let city: String?
        let town: String?
        let village: String?
        let state: String?
        let country: String?
        let formatted: String?
        let distance: Double?
        let resultType: String?
        /// What kind of feature the provider matched, e.g. `leisure.park`. Present for a
        /// point of interest and absent for an address or a plain building match, which
        /// is what makes it the usable venue signal.
        let categories: [String]?
        let datasource: Datasource?

        enum CodingKeys: String, CodingKey {
            case name, street, suburb, district, quarter, city, town, village
            case state, country, formatted, distance, categories, datasource
            case resultType = "result_type"
        }
    }

    struct Datasource: Sendable, Codable {
        let sourcename: String?
        let attribution: String?
        let license: String?
        let url: String?
    }

    let results: [Result]
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
