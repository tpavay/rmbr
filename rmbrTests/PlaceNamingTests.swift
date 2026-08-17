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
        "categories":["commercial","commercial.gym"],
        "city":"Chicago","suburb":"West Loop",
        "datasource":{"sourcename":"openstreetmap","attribution":"© OpenStreetMap contributors"}}]}
        """)
        let label = try #require(GeoapifyReverseGeocoder.label(from: payload, at: now))
        #expect(label.text == "POW! Gym")
        #expect(label.specificity == .venue)
        #expect(label.origin == .providerPOI)
        #expect(label.attribution == "© OpenStreetMap contributors")
    }

    @Test("A named result with no category is an address match, never a place name")
    func categorylessNameIsNotAVenue() throws {
        // The live API answers a building or an address with a name and no category, and
        // reverse geocoding matches the nearest feature - so this name is a precise
        // claim about a building the person may never have been inside.
        let payload = try response("""
        {"results":[{"name":"1035 West Van Buren Street","result_type":"building",
        "distance":12,"street":"W Van Buren St","housenumber":"1035",
        "suburb":"West Loop","city":"Chicago"}]}
        """)
        let label = try #require(GeoapifyReverseGeocoder.label(from: payload, at: now))
        #expect(label.text == "West Loop")
        #expect(label.specificity == .neighbourhood)
        #expect(label.origin == .providerGeography)
    }

    @Test("A named feature merely near the anchor falls to a coarser tier")
    func distantVenueDoesNotWin() throws {
        let payload = try response("""
        {"results":[{"name":"Some Cafe","result_type":"amenity","distance":140,
        "categories":["catering","catering.cafe"],
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

    @Test("Nothing above the city tier is a place a day can be labelled with")
    func stateAndCountryAreNotLabels() throws {
        let payload = try response("""
        {"results":[{"state":"Illinois","country":"United States","distance":8400,
        "formatted":"Illinois, United States"}]}
        """)
        // A day headed by its state or its country says nothing about where the person
        // was, so the place phrase is omitted rather than widened until something fits.
        #expect(GeoapifyReverseGeocoder.label(from: payload, at: now) == nil)
    }

    @Test("A missing attribution falls back to the required OpenStreetMap credit")
    func attributionAlwaysPresent() throws {
        let payload = try response("""
        {"results":[{"name":"Millennium Park","result_type":"building","distance":1,
        "categories":["leisure","leisure.park"]}]}
        """)
        let label = try #require(GeoapifyReverseGeocoder.label(from: payload, at: now))
        #expect(label.text == "Millennium Park")
        #expect(label.attribution == OpenStreetMap.attribution)
        #expect(label.attributions == [OpenStreetMap.attribution])
    }

    @Test("A label from another datasource still carries the service credit")
    func nonOpenStreetMapResultKeepsBothCredits() throws {
        // Geoapify answers from OpenAddresses and Who is On First as well as
        // OpenStreetMap, and the service credit is owed whichever one answered.
        let payload = try response("""
        {"results":[{"suburb":"West Loop","city":"Chicago",
        "datasource":{"sourcename":"openaddresses","attribution":"OpenAddresses contributors"}}]}
        """)
        let label = try #require(GeoapifyReverseGeocoder.label(from: payload, at: now))
        #expect(label.attributions == [OpenStreetMap.attribution, "OpenAddresses contributors"])
    }

    @Test("An OpenStreetMap result is credited once, not twice")
    func openStreetMapCreditIsNotDuplicated() throws {
        // The live API returns the credit without the copyright symbol the service credit
        // carries, so raw string comparison would print the same obligation twice.
        let payload = try response("""
        {"results":[{"suburb":"West Loop","city":"Chicago",
        "datasource":{"sourcename":"openstreetmap","attribution":"OpenStreetMap contributors"}}]}
        """)
        let label = try #require(GeoapifyReverseGeocoder.label(from: payload, at: now))
        #expect(label.attributions == [OpenStreetMap.attribution])
    }

    @Test("A ledger written before the service credit existed still reads back")
    func olderStoredLabelGainsTheServiceCredit() throws {
        let stored = """
        {"text":"Millennium Park","specificity":"venue","origin":"providerPOI",
        "provider":"geoapify","attribution":"Who is On First","fetchedAt":0}
        """
        let label = try JSONDecoder().decode(ResolvedPlaceLabel.self, from: Data(stored.utf8))
        #expect(label.attributions == [OpenStreetMap.attribution, "Who is On First"])
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

    @Test("A label named under a superseded cascade is asked again; a person's own is kept")
    func supersededProviderLabelsAreReResolved() throws {
        let corrected = Fixture.offset(origin, metresNorth: 400)
        let unnameable = Fixture.offset(origin, metresNorth: 800)
        var current = PlaceLabelLedger()
        current.record(.resolved(Fixture.label("1035 West Van Buren Street")), at: origin)
        current.record(.resolved(Fixture.label("Home", origin: .personCorrection)), at: corrected)
        current.record(.unlabelled(attemptedAt: Date()), at: unnameable)

        // A ledger written before the cascade was versioned carries no version at all.
        var raw = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
        )
        raw.removeValue(forKey: "policyVersion")
        var legacy = try JSONDecoder().decode(
            PlaceLabelLedger.self,
            from: try JSONSerialization.data(withJSONObject: raw)
        )

        let migrated = legacy.adoptCurrentNamingPolicy()
        #expect(migrated)
        #expect(legacy.label(near: origin) == nil)
        #expect(legacy.needsLookup(origin))
        // The person's own label is their content, and an answered-but-unnameable
        // coordinate stays answered: the new cascade is stricter, not looser.
        #expect(legacy.label(near: corrected)?.text == "Home")
        #expect(legacy.needsLookup(unnameable) == false)
        let migratedAgain = legacy.adoptCurrentNamingPolicy()
        #expect(migratedAgain == false)
    }

    @Test("A ledger written under the current cascade is left alone")
    func currentLedgerIsNotMigrated() {
        var ledger = PlaceLabelLedger()
        ledger.record(.resolved(Fixture.label("Millennium Park")), at: origin)
        let migrated = ledger.adoptCurrentNamingPolicy()
        #expect(migrated == false)
        #expect(ledger.label(near: origin)?.text == "Millennium Park")
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
