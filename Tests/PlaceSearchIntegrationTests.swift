import MapKit
import XCTest
@testable import ElsewhereMobile

final class PlaceSearchIntegrationTests: XCTestCase {
    @MainActor
    private func offlineStore(isDemo: Bool, unexpectedRequest: XCTestExpectation) -> PlaceSearchStore {
        PlaceSearchStore(isDemo: isDemo, makeCompleter: { _, _ in
            unexpectedRequest.fulfill()
            return MKLocalSearchCompleter()
        }, suggest: { _ in
            unexpectedRequest.fulfill()
            return []
        }, lookUpOSM: { _ in
            unexpectedRequest.fulfill()
            return nil
        }, appleLookup: { _, _ in
            unexpectedRequest.fulfill()
            return nil
        })
    }

    @MainActor
    func testCoordinateInputBypassesSuggestionsAndBothSearchProviders() async throws {
        let request = XCTestExpectation(description: "No provider receives the coordinates")
        request.isInverted = true
        let store = offlineStore(isDemo: false, unexpectedRequest: request)
        let gps = try XCTUnwrap(WGS84Coordinate(latitude: 31.243672, longitude: 121.485834))
        store.query = "31.243672"
        store.query = "31.243672，"
        store.query = " 31.243672，121.485834 "
        let match = await store.submit(store.query)
        XCTAssertEqual(match, .coordinate(gps))
        XCTAssertFalse(store.hasSuggestions)
        // Keep the query active beyond the Photon debounce interval.
        let result = await XCTWaiter.fulfillment(of: [request], timeout: 0.65)
        XCTAssertEqual(result, .completed)
    }

    @MainActor
    func testNominatimFailureFallsBackToAppleAndConvertsMainlandCoordinates() async throws {
        let map = CLLocationCoordinate2D(latitude: 31.241701, longitude: 121.490317)
        var calls: [String] = []
        let store = PlaceSearchStore(lookUpOSM: { text in
            calls.append("osm " + text)
            throw URLError(.timedOut)
        }, appleLookup: { request, _ in
            calls.append("apple " + (request.naturalLanguageQuery ?? ""))
            return ("The Bund", map)
        })

        let match = await store.submit(" Shanghai ")
        XCTAssertEqual(calls, ["osm Shanghai", "apple Shanghai"])
        guard case let .apple(name, gps) = match else { return XCTFail("Expected an Apple result") }
        XCTAssertEqual(name, "The Bund")
        XCTAssertEqual(gps.latitude, 31.243672, accuracy: 0.00005)
        XCTAssertEqual(gps.longitude, 121.485834, accuracy: 0.00005)
    }

    @MainActor
    func testNominatimHitPreservesWGS84AndSkipsApple() async throws {
        let gps = try XCTUnwrap(WGS84Coordinate(latitude: 31.243672, longitude: 121.485834))
        let place = OSMPlace(name: "The Bund", detail: "Shanghai", coordinate: gps)
        let store = PlaceSearchStore(lookUpOSM: { _ in place }, appleLookup: { _, _ in
            XCTFail("Apple lookup after a Nominatim hit")
            return nil
        })
        let match = await store.submit("Shanghai")
        XCTAssertEqual(match, .osm(place))
    }

    @MainActor
    func testLateSubmissionCannotReplaceNewerMatchOrStartFallback() async {
        let started = XCTestExpectation(description: "First lookup started")
        let (gate, release) = AsyncStream<Void>.makeStream()
        // Model a provider that still delivers its response after cancellation.
        let lateResponse = Task { for await _ in gate {} }
        let place = OSMPlace(name: "Berlin", detail: "", coordinate: Place.defaults[0].coordinate)
        let store = PlaceSearchStore(lookUpOSM: { text in
            if text == "old" {
                started.fulfill()
                await lateResponse.value
                throw URLError(.timedOut)
            }
            return place
        }, appleLookup: { _, _ in
            XCTFail("Superseded lookup started a fallback")
            return nil
        })
        let old = Task { await store.submit("old") }
        let entered = await XCTWaiter.fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(entered, .completed)
        let match = await store.submit("Berlin")
        release.finish()
        let stale = await old.value
        XCTAssertNil(stale)
        XCTAssertNil(store.nominatimError)
        XCTAssertEqual(match, .osm(place))
    }

    @MainActor
    func testCancelledSubmissionDiscardsLateNominatimHit() async {
        let started = XCTestExpectation(description: "Nominatim lookup started")
        let (gate, release) = AsyncStream<Void>.makeStream()
        let lateResponse = Task { for await _ in gate {} }
        let place = OSMPlace(name: "Berlin", detail: "", coordinate: Place.defaults[0].coordinate)
        let store = PlaceSearchStore(lookUpOSM: { _ in
            started.fulfill()
            await lateResponse.value
            return place
        }, appleLookup: { _, _ in
            XCTFail("Cancelled search started an Apple lookup")
            return nil
        })

        let pending = Task { await store.submit("Berlin") }
        let entered = await XCTWaiter.fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(entered, .completed)
        pending.cancel()
        release.finish()
        let result = await pending.value
        XCTAssertNil(result)
        XCTAssertFalse(store.searching)
    }

    @MainActor
    func testDemoSuggestionsSubmissionAndReverseLookupStayOffline() async throws {
        let request = XCTestExpectation(description: "No online search or reverse geocoder in demo mode")
        request.isInverted = true
        let store = offlineStore(isDemo: true, unexpectedRequest: request)
        let tokyo = try XCTUnwrap(Place.defaults.first { $0.name == String(localized: "东京") })
        let reverseLookup: @Sendable (WGS84Coordinate) async -> String? = { _ in
            request.fulfill()
            return nil
        }
        for text in ["toky", "东京", tokyo.displayName] {
            store.query = text
            let suggestion = try XCTUnwrap(store.osmResults.first)
            XCTAssertEqual(suggestion.name, tokyo.displayName)
            XCTAssertEqual(suggestion.coordinate, tokyo.coordinate)
            let match = await store.submit(text)
            XCTAssertEqual(match, .osm(suggestion))
        }

        store.query = "not a default city"
        XCTAssertFalse(store.hasSuggestions)
        let miss = await store.submit(store.query)
        XCTAssertNil(miss)
        let sameSpot = try XCTUnwrap(WGS84Coordinate(latitude: tokyo.coordinate.latitude + 0.00001,
                                                     longitude: tokyo.coordinate.longitude))
        let name = await Geo.placeName(for: sameSpot, isDemo: true, reverseLookup: reverseLookup)
        XCTAssertEqual(name, tokyo.displayName)
        let elsewhere = try XCTUnwrap(WGS84Coordinate(latitude: 0, longitude: 0))
        let unknown = await Geo.placeName(for: elsewhere, isDemo: true, reverseLookup: reverseLookup)
        XCTAssertNil(unknown)
        let result = await XCTWaiter.fulfillment(of: [request], timeout: 0.65)
        XCTAssertEqual(result, .completed)
    }

    @MainActor
    func testSwitchingToDemoDiscardsLateOnlineSuggestions() async {
        let started = XCTestExpectation(description: "Photon suggestions started")
        let finished = XCTestExpectation(description: "Old Photon response returned")
        let (gate, release) = AsyncStream<Void>.makeStream()
        let lateResponse = Task { for await _ in gate {} }
        let old = OSMPlace(name: "Online result", detail: "", coordinate: Place.defaults[0].coordinate)
        let store = PlaceSearchStore(makeCompleter: { _, _ in MKLocalSearchCompleter() }, suggest: { _ in
            started.fulfill()
            await lateResponse.value
            finished.fulfill()
            return [old]
        })
        store.query = "online"
        let entered = await XCTWaiter.fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(entered, .completed)
        store.isDemo = true
        XCTAssertTrue(store.query.isEmpty)
        store.query = "Tokyo"
        let local = store.osmResults
        XCTAssertEqual(local.count, 1)
        release.finish()
        let returned = await XCTWaiter.fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(returned, .completed)
        XCTAssertEqual(store.osmResults, local)
        store.isDemo = false
        XCTAssertFalse(store.hasSuggestions)
    }

    func testBuiltInDisplayNamesUseStableIDsAndCustomNamesSurvive() throws {
        let id = try XCTUnwrap(UUID(uuidString: "620852A9-BDCD-4CCC-8D4F-42CB74AD8309"))
        let tokyo = try XCTUnwrap(Place.defaults.first { $0.id == id })
        let persisted = Place(id: id, name: "Previously localized name", coordinate: tokyo.coordinate)
        XCTAssertEqual(persisted.displayName, String(localized: "东京"))
        let custom = Place(name: "My Tokyo", coordinate: tokyo.coordinate)
        XCTAssertEqual(custom.displayName, "My Tokyo")
    }
}
