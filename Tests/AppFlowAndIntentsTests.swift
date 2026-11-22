import Observation
import XCTest
@testable import ElsewhereMobile

private actor ChangingExit: HTTPDataTransport {
    private(set) var requests = 0
    private var details = 0

    func data(for request: URLRequest, proxy: ExitProxyAddress?) throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        requests += 1
        let body: String
        if url.path == "/json" {
            details += 1
            guard details <= 2 else { throw URLError(.timedOut) }
            let ip = details == 1 ? "203.0.113.24" : "203.0.113.25"
            body = #"{"ip":"\#(ip)","city":"东京","loc":"35.6812,139.7671"}"#
        } else {
            body = "203.0.113.25"
        }
        return (Data(body.utf8), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}

final class AppFlowAndIntentsTests: XCTestCase {
    @MainActor
    func testLoadDemoDeviceAndTokyoExit() async {
        let store = AppStore(environment: .demo())
        await store.load()
        XCTAssertTrue(store.canOperate)
        XCTAssertEqual(store.devices.count, 1)
        XCTAssertEqual(store.exit?.ip, "203.0.113.24")
        XCTAssertEqual(store.exit?.city, "东京")
    }

    @MainActor
    func testCityEditsPersistInOrderAndResetToDefaults() async throws {
        let store = AppStore(environment: .demo())
        await store.load()
        let original = store.cities
        let city = Place(name: "京都", coordinate: try XCTUnwrap(WGS84Coordinate(latitude: 35.01, longitude: 135.77)))
        await store.addCity(city)
        XCTAssertEqual(store.cities, original + [city])
        await store.moveCities(from: IndexSet(integer: original.count), to: 0)
        XCTAssertEqual(store.cities, [city] + original)
        await store.removeCities(at: IndexSet(integer: 1))
        let edited = try await store.environment.stateStore.load()
        XCTAssertEqual(edited.cities, [city] + original.dropFirst())
        XCTAssertEqual(store.cities, edited.cities)
        await store.resetCities()
        await store.load()
        XCTAssertEqual(store.cities, Place.defaults)
        XCTAssertEqual(store.cities.count, 11)
    }

    @MainActor
    func testDisableClearsExitStateAndRejectsSavedShortcut() async {
        let demo = AppEnvironment.demo(), transport = ChangingExit()
        let environment = AppEnvironment(engine: demo.engine, pairingStore: demo.pairingStore, tunnel: demo.tunnelCoordinator,
                                         stateStore: demo.stateStore, exitService: ExitIPService(transport: transport), notifier: demo.notifier)
        let store = AppStore(environment: environment)
        await store.load()
        let change = XCTestExpectation(description: "收到待确认的出口变化")
        withObservationTracking { _ = store.pendingExitChange } onChange: { change.fulfill() }
        await store.handleSceneActive()
        let result = await XCTWaiter.fulfillment(of: [change], timeout: 5)
        await store.handleSceneInactive()
        XCTAssertEqual(result, .completed)
        await store.refreshExit()
        XCTAssertEqual(store.exit?.ip, "203.0.113.25")
        XCTAssertEqual(store.pendingExitChange?.ip, "203.0.113.25")
        XCTAssertNotNil(store.exitError)

        await store.updateSettings { $0.exitFeaturesEnabled = false }
        XCTAssertNil(store.exit)
        XCTAssertNil(store.pendingExitChange)
        XCTAssertNil(store.exitError)
        let before = await transport.requests
        do {
            _ = try await IntentExecutor.followExit.run(in: store)
            XCTFail("旧快捷指令应受出口总开关约束")
        } catch {
            XCTAssertEqual(error.localizedDescription, String(localized: "出口功能已关闭，请先在设置中开启。"))
        }
        let after = await transport.requests
        XCTAssertEqual(after, before)
        XCTAssertTrue(store.records.isEmpty)
    }

    @MainActor
    func testIntentFlowFromColdStartThroughRestore() async throws {
        let store = AppStore(environment: .demo())
        let result = try await IntentExecutor.followExit.run(in: store)
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(store.selectedRecord?.source, .exitIP)
        XCTAssertEqual(store.selectedRecord?.exitIP, "203.0.113.24")

        let city = try XCTUnwrap(store.cities.first)
        let saved = CityEntity(id: city.id, name: "保存快捷指令时的旧名称")
        _ = try await IntentExecutor.setCity(saved).run(in: store)
        XCTAssertEqual(store.selectedRecord?.source, .city)
        XCTAssertEqual(store.selectedRecord?.name, city.name)
        XCTAssertEqual(store.selectedRecord?.coordinate, city.coordinate)

        let coordinate = try XCTUnwrap(WGS84Coordinate(latitude: -90, longitude: 180))
        _ = try await IntentExecutor.setCoordinate(latitude: -90, longitude: 180, name: "  ").run(in: store)
        let record = try XCTUnwrap(store.selectedRecord)
        XCTAssertEqual(record.source, .custom)
        XCTAssertEqual(record.name, coordinate.formatted)
        XCTAssertEqual(record.coordinate, coordinate)
        for (latitude, longitude) in [(Double.nan, 0.0), (91, 0), (0, 181)] {
            do {
                _ = try await IntentExecutor.setCoordinate(latitude: latitude, longitude: longitude, name: nil).run(in: store)
                XCTFail("不应接受无效坐标")
            } catch {
                XCTAssertEqual(error.localizedDescription, String(localized: "无效的 WGS-84 坐标"))
            }
            XCTAssertEqual(store.selectedRecord, record)
        }

        _ = try await IntentExecutor.restoreRealLocation.run(in: store)
        XCTAssertTrue(store.records.isEmpty)
        let state = try await store.environment.stateStore.load()
        XCTAssertTrue(state.records.isEmpty)
    }
}
