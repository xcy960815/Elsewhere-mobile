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
        XCTAssertEqual(store.exit?.city, String(localized: "东京"))
    }

    @MainActor
    func testColdFollowSamplesBeforeTheFirstProbeTunnel() async throws {
        let demo = AppEnvironment.demo(), io = CommandIO([#"{"ip":"192.0.2.8","city":"Tokyo","loc":"35,139"}"#])
        let tunnel = TunnelCoordinator(adapter: CommandTunnel(io: io))
        let env = AppEnvironment(engine: demo.engine, pairingStore: demo.pairingStore, tunnel: tunnel,
            stateStore: demo.stateStore, exitService: ExitIPService(transport: io), notifier: demo.notifier)
        try await env.stateStore.saveSettings(AppSettings(channelMode: .builtInTunnel))
        let store = AppStore(environment: env)
        let entered = XCTestExpectation(description: "快捷指令正在采样出口")
        let release = await io.pause(.exitLookup, entered: entered)
        let intent = Task { try await IntentExecutor.followExit.run(in: store) }
        _ = await XCTWaiter.fulfillment(of: [entered], timeout: 3)
        let probe = Task { await store.refreshDevices() }
        let deadline = ContinuousClock.now + .seconds(3)
        while store.busyMessage == nil, ContinuousClock.now < deadline { await Task.yield() }
        let beforeSample = await io.events
        XCTAssertEqual(beforeSample, [.exitLookup])
        release.finish()
        _ = try await intent.value
        await probe.value
        let events = await io.events
        XCTAssertEqual(events, [.exitLookup, .tunnelStart, .tunnelStop, .tunnelStart, .tunnelStop])
        XCTAssertEqual(store.selectedRecord?.exitIP, "192.0.2.8")
    }

    @MainActor
    func testColdSplashDismissalPreservesExistingSettings() async throws {
        let demo = AppEnvironment.demo()
        var saved = AppSettings(exitFeaturesEnabled: false, channelMode: .builtInTunnel, customProxyText: "localhost:9000")
        try await demo.stateStore.saveSettings(saved)
        let store = AppStore(environment: demo)
        await store.markSplashSeen()
        XCTAssertTrue(store.settings.hasSeenSplash)
        saved.hasSeenSplash = true
        let persisted = try await demo.stateStore.load()
        XCTAssertEqual(persisted.settings, saved)
    }

    @MainActor
    func testDemoLeavesSharedInboxItemsForDeviceMode() async throws {
        let inbox = PairingInbox(directory: try makeTemporaryDirectory())
        let id = try inbox.enqueue(data: LockdownPlist().data(), suggestedName: "shared.plist")
        let store = AppStore(environment: .demo())
        let results = await store.importPendingPairings(from: inbox)
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(store.pairingRecords.isEmpty)
        XCTAssertEqual(inbox.pendingItems().map(\.id), [id])
    }

    @MainActor
    func testDeviceModeAcknowledgesOnlySuccessfulInboxItemsAndProbesImportedDevice() async throws {
        let inbox = PairingInbox(directory: try makeTemporaryDirectory()), demo = AppEnvironment.demo()
        let phone = DemoLocationEngine.defaultDevice
        _ = try inbox.enqueue(data: LockdownPlist(udid: phone.id.rawValue).data(), suggestedName: "valid.plist")
        let invalid = try inbox.enqueue(data: Data("invalid".utf8), suggestedName: "invalid.plist")
        let env = AppEnvironment(engine: CommandIO([]), pairingStore: demo.pairingStore, tunnel: demo.tunnelCoordinator,
            stateStore: demo.stateStore, exitService: demo.exitService, notifier: demo.notifier)
        let store = AppStore(environment: env)
        let report = await store.importPendingPairings(from: inbox)
        XCTAssertEqual(report.count, 2)
        XCTAssertEqual(inbox.pendingItems().map(\.id), [invalid])
        XCTAssertEqual(store.readyDevices, [phone])
        XCTAssertFalse(store.needsOnboarding)
    }

    @MainActor
    func testExpiredNotificationIDReportsFailureWithoutApplying() async throws {
        let env = AppEnvironment.demo(), store = AppStore(environment: env)
        let exit = try await env.exitService.lookup()
        let event = PendingExitEvent(id: UUID(), exit: exit, targetDeviceIDs: [env.demoDeviceID], createdAt: Date(timeIntervalSinceNow: -61))
        try await env.stateStore.savePendingExitEvent(event)
        let reported = XCTestExpectation(description: "过期通知可见反馈")
        withObservationTracking { _ = store.feedback } onChange: { reported.fulfill() }
        env.notifier.handleResponse(category: Notifier.exitChangedCategory, action: Notifier.followAction, eventID: event.id)
        let result = await XCTWaiter.fulfillment(of: [reported], timeout: 3)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(store.feedback?.title, String(localized: "这次出口变化已过期，请刷新出口后再跟随。"))
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(store.devices.isEmpty)
    }

    @MainActor
    func testNotificationUsesItsTargetsAcrossAColdStartAndRejectsAReplacedID() async throws {
        let demo = AppEnvironment.demo(), phone = DemoLocationEngine.defaultDevice
        let tablet = TargetDevice(id: DeviceID(rawValue: "tablet")!, name: "iPad", deviceClass: "iPad", productType: nil,
            osVersion: nil, endpointHost: "fd00::1", paired: true, developerMode: true, wifiEnabled: true,
            timeZoneID: nil, cellular: false, ddiMounted: true)
        let io = CommandIO([], devices: [phone, tablet])
        let env = AppEnvironment(engine: io, pairingStore: demo.pairingStore, tunnel: demo.tunnelCoordinator,
            stateStore: demo.stateStore, exitService: demo.exitService, notifier: demo.notifier)
        let store = AppStore(environment: env)
        for target in [phone, tablet] {
            _ = try await env.pairingStore.importPairing(data: LockdownPlist(udid: target.id.rawValue).data(),
                endpointHost: target.endpointHost, deviceName: target.name)
        }
        try await env.stateStore.saveSettings(AppSettings(applyToAll: true))
        try await env.stateStore.saveSelectedDeviceID(phone.id)
        let exit = try await env.exitService.lookup()
        let event = PendingExitEvent(id: UUID(), exit: exit, targetDeviceIDs: [tablet.id], createdAt: Date())
        try await env.stateStore.saveExitBaseline(ExitBaseline(proxyKey: "", lastConfirmedIP: exit.ip, lastExit: exit, lastFetchedAt: Date()))
        try await env.stateStore.savePendingExitEvent(event)
        let stale = XCTestExpectation(description: "旧通知不可跟随")
        withObservationTracking { _ = store.feedback } onChange: { stale.fulfill() }
        env.notifier.handleResponse(category: Notifier.exitChangedCategory, action: Notifier.followAction, eventID: UUID())
        _ = await XCTWaiter.fulfillment(of: [stale], timeout: 3)
        XCTAssertEqual(store.feedback?.kind, .failure)
        let retained = await env.exitMonitor.pendingEvent(for: event.id)
        XCTAssertEqual(retained, event)

        let finished = XCTestExpectation(description: "只跟随事件中的设备")
        withObservationTracking { _ = store.feedback } onChange: { finished.fulfill() }
        env.notifier.handleResponse(category: Notifier.exitChangedCategory, action: Notifier.followAction, eventID: event.id)
        _ = await XCTWaiter.fulfillment(of: [finished], timeout: 3)
        let events = await io.events, saved = try await env.stateStore.load()
        XCTAssertEqual(events, [.set(tablet.id)])
        XCTAssertEqual(Set(saved.records.keys), [tablet.id])
        XCTAssertNil(saved.pendingExitEvent)
        XCTAssertNil(store.pendingExitChange)

        try await env.stateStore.savePendingExitEvent(event)
        await store.loadSettingsOnly()
        await store.dismissPendingExitChange()
        let dismissed = await env.exitMonitor.pendingEvent(for: event.id)
        XCTAssertNil(dismissed)
        XCTAssertNil(store.pendingExitChange)
    }

    @MainActor
    func testDeviceStateTracksDDIAndOperationUntilReceipt() async throws {
        let demo = AppEnvironment.demo(), io = CommandIO([]), phone = DemoLocationEngine.defaultDevice
        let env = AppEnvironment(engine: io, pairingStore: demo.pairingStore, tunnel: demo.tunnelCoordinator,
            stateStore: demo.stateStore, exitService: demo.exitService, notifier: demo.notifier)
        let store = AppStore(environment: env)
        _ = try await store.importPairing(data: LockdownPlist(udid: phone.id.rawValue).data(), endpointHost: phone.endpointHost, deviceName: nil)
        await store.refreshDevices()
        let mounting = XCTestExpectation(description: "挂载中"), writing = XCTestExpectation(description: "下发中")
        let mount = await io.pause(.mounting(phone.id), entered: mounting)
        let write = await io.pause(.set(phone.id), entered: writing)
        let operation = Task { await store.apply(place: Place.defaults[0], source: .city) }
        _ = await XCTWaiter.fulfillment(of: [mounting], timeout: 3)
        await waitForState(.preparingDDI(phone, .mounting), id: phone.id, in: store)
        mount.finish()
        _ = await XCTWaiter.fulfillment(of: [writing], timeout: 3)
        await waitForState(.operating(phone, .setLocation), id: phone.id, in: store)
        write.finish()
        await operation.value
        XCTAssertEqual(store.deviceStates[phone.id], .ready(phone))
    }

    @MainActor
    private func waitForState(_ state: DeviceConnectionState, id: DeviceID, in store: AppStore) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while store.deviceStates[id] != state, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(store.deviceStates[id], state)
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
