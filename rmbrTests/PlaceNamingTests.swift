import Foundation
import Testing
@testable import rmbr

@Suite("Place naming")
struct PlaceNamingTests {
    private func response(_ json: String) throws -> GeoapifyReverseResponse {
        try JSONDecoder().decode(GeoapifyReverseResponse.self, from: Data(json.utf8))
    }

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    @Test("A named feature on top of the anchor becomes the label")
    func containedVenueWins() throws {
        let payload = try response("""
        {"results":[{"name":"POW! Gym","result_type":"amenity","distance":4.2,
        "city":"Chicago","suburb":"West Loop",
        "datasource":{"sourcename":"openstreetmap","attribution":"© OpenStreetMap contributors"}}]}
        """)
        let label = try #require(GeoapifyReverseGeocoder.label(from: payload, at: now))
        #expect(label.text == "POW! Gym")
        #expect(label.specificity == .venue)
        #expect(label.origin == .providerPOI)
        #expect(label.attribution == "© OpenStreetMap contributors")
    }

    @Test("A named feature merely near the anchor falls to a coarser tier")
    func distantVenueDoesNotWin() throws {
        let payload = try response("""
        {"results":[{"name":"Some Cafe","result_type":"amenity","distance":140,
        "suburb":"West Loop","city":"Chicago"}]}
        """)
        let label = try #require(GeoapifyReverseGeocoder.label(from: payload, at: now))
        // Nearest-business-by-distance is exactly what the naming rules forbid.
        #expect(label.text == "West Loop")
        #expect(label.specificity == .neighbourhood)
        #expect(label.origin == .providerGeography)
    }

    @Test("A bare street address is never the printed label")
    func addressIsNotALabel() throws {
        let payload = try response("""
        {"results":[{"street":"W Van Buren St","housenumber":"1101","city":"Chicago",
        "formatted":"1101 W Van Buren St, Chicago, IL"}]}
        """)
        let label = try #require(GeoapifyReverseGeocoder.label(from: payload, at: now))
        #expect(label.text == "Chicago")
        #expect(!label.text.contains("1101"))
        #expect(!label.text.contains("Van Buren"))
    }

    @Test("A response supporting nothing produces no label at all")
    func emptyResponseNamesNothing() throws {
        #expect(try GeoapifyReverseGeocoder.label(from: response("{\"results\":[]}"), at: now) == nil)
    }

    @Test("A missing attribution falls back to the required OpenStreetMap credit")
    func attributionAlwaysPresent() throws {
        let payload = try response("""
        {"results":[{"name":"Millennium Park","result_type":"amenity","distance":1}]}
        """)
        let label = try #require(GeoapifyReverseGeocoder.label(from: payload, at: now))
        #expect(label.attribution == OpenStreetMap.attribution)
    }
}

@Suite("Place label ledger")
struct PlaceLabelLedgerTests {
    let origin = Coordinate(latitude: 41.8757, longitude: -87.6580)

    @Test("One anchor is looked up once, however many days visit it")
    func nearbyCoordinatesShareOneLabel() {
        var ledger = PlaceLabelLedger()
        ledger.record(.resolved(Fixture.label("Home")), at: origin)

        #expect(ledger.label(near: Fixture.offset(origin, metresNorth: 10))?.text == "Home")
        #expect(ledger.needsLookup(Fixture.offset(origin, metresNorth: 10)) == false)
        #expect(ledger.count == 1)
    }

    @Test("A coordinate beyond the match distance still needs its own lookup")
    func distantCoordinatesAreSeparate() {
        var ledger = PlaceLabelLedger()
        ledger.record(.resolved(Fixture.label("Home")), at: origin)
        #expect(ledger.needsLookup(Fixture.offset(origin, metresNorth: 400)))
        #expect(ledger.label(near: Fixture.offset(origin, metresNorth: 400)) == nil)
    }

    @Test("An answered-but-unnameable coordinate is not asked about again")
    func negativeResultsAreRemembered() {
        var ledger = PlaceLabelLedger()
        ledger.record(.unlabelled(attemptedAt: Date()), at: origin)
        #expect(ledger.needsLookup(origin) == false)
        #expect(ledger.label(near: origin) == nil)
        #expect(ledger.resolvedCount == 0)
    }

    @Test("The ledger survives a round trip to disk")
    func ledgerRoundTrips() throws {
        var ledger = PlaceLabelLedger()
        ledger.record(.resolved(Fixture.label("Van Buren Lofts", specificity: .building)), at: origin)

        let encoded = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(PlaceLabelLedger.self, from: encoded)

        let label = try #require(decoded.label(near: origin))
        #expect(label.text == "Van Buren Lofts")
        #expect(label.specificity == .building)
        #expect(label.attribution == OpenStreetMap.attribution)
    }
}

@Suite("Credential storage")
struct CredentialTests {
    @Test("The key round-trips through the keychain and can be removed")
    func keychainRoundTrip() {
        let store = GeoapifyCredentialStore(service: "com.TylerPavay.rmbr.tests.\(UUID().uuidString)")
        #expect(store.hasKey == false)
        #expect(store.write("test-key-value"))
        #expect(store.read() == "test-key-value")
        #expect(store.delete())
        #expect(store.read() == nil)
    }

    @Test("An empty key is refused rather than stored")
    func emptyKeyIsRefused() {
        let store = GeoapifyCredentialStore(service: "com.TylerPavay.rmbr.tests.\(UUID().uuidString)")
        #expect(store.write("   ") == false)
        #expect(store.hasKey == false)
    }
}
