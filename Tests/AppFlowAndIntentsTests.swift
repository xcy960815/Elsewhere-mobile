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
    func testSkippedSetupWithNoPairingCanEnterDemo() async {
        let demo = AppEnvironment.demo()
        let env = AppEnvironment(engine: CommandIO([]), pairingStore: demo.pairingStore, tunnel: demo.tunnelCoordinator,
            stateStore: demo.stateStore, exitService: demo.exitService, notifier: demo.notifier)
        let store = AppStore(environment: env)
        XCTAssertFalse(store.needsOnboarding)
        await store.load()
        XCTAssertTrue(store.needsOnboarding)
        await store.completeOnboarding()
        XCTAssertFalse(store.needsOnboarding)
        XCTAssertTrue(store.needsPairingSetup)
        XCTAssertFalse(store.canOperate)

        let preferences = AppEnvironment.modePreferences
        let previousMode = preferences.object(forKey: "ElsewhereDemoMode")
        defer { preferences.set(previousMode, forKey: "ElsewhereDemoMode") }
        await store.switchToDemo(true)
        XCTAssertTrue(store.isDemo)
        XCTAssertFalse(store.needsPairingSetup)
        XCTAssertTrue(store.canOperate)
    }

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
        let tunnelCapable = AppCapabilities(hasBuiltInTunnel: true, resolvedTunnelProviderBundleID: "com.elsewhere.mobile.tunnel",
                                            hasSnapshotAppGroup: false, hasImportAppGroup: false)
        let env = AppEnvironment(engine: demo.engine, pairingStore: demo.pairingStore, tunnel: tunnel,
            stateStore: demo.stateStore, exitService: ExitIPService(transport: io), notifier: demo.notifier, capabilities: tunnelCapable)
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
    func testBuiltInLoadSamplesExitBeforeTunnelAndForegroundDoesNotPoll() async throws {
        let demo = AppEnvironment.demo(), phone = DemoLocationEngine.defaultDevice
        let io = CommandIO([#"{"ip":"192.0.2.8","city":"Tokyo","loc":"35,139"}"#])
        let (stream, path) = AsyncStream<Void>.makeStream()
        defer { path.finish() }
        let capabilities = AppCapabilities(hasBuiltInTunnel: true, resolvedTunnelProviderBundleID: "com.elsewhere.mobile.tunnel",
                                           hasSnapshotAppGroup: false, hasImportAppGroup: false)
        let env = AppEnvironment(engine: io, pairingStore: demo.pairingStore, tunnel: TunnelCoordinator(adapter: CommandTunnel(io: io)),
            stateStore: demo.stateStore, exitService: ExitIPService(transport: io), notifier: demo.notifier, capabilities: capabilities,
            pathUpdates: { stream })
        _ = try await env.pairingStore.importPairing(data: LockdownPlist(udid: phone.id.rawValue).data(),
            endpointHost: phone.endpointHost, deviceName: nil)
        try await env.stateStore.saveSettings(AppSettings(channelMode: .builtInTunnel))
        let store = AppStore(environment: env)
        await store.load()
        let loaded = await io.events
        XCTAssertEqual(loaded, [.exitLookup, .tunnelStart, .tunnelStop])
        XCTAssertTrue(store.canOperate)

        await store.updateSettings { $0.exitFeaturesEnabled = false }
        await store.apply(place: Place.defaults[0], source: .city)
        XCTAssertEqual(store.selectedRecord?.confidence, .confirmed)
        await store.handleSceneActive()
        let activated = await io.events
        let polled = expectation(description: "内置通道不应周期探活")
        polled.isInverted = true
        let release = await io.pause(.tunnelStart, entered: polled)
        let result = await XCTWaiter.fulfillment(of: [polled], timeout: 16)
        release.finish()
        await store.waitForDeviceRefresh()
        XCTAssertEqual(result, .completed)
        let inactive = await io.events
        XCTAssertEqual(inactive, activated)
        let switching = await env.tunnelCoordinator.isSwitchingChannel
        XCTAssertFalse(switching)
        let refreshed = expectation(description: "路径变化按需探活")
        let refresh = await io.pause(.tunnelStart, entered: refreshed)
        path.yield(())
        let changed = await XCTWaiter.fulfillment(of: [refreshed], timeout: 3)
        refresh.finish()
        await store.waitForDeviceRefresh()
        XCTAssertEqual(changed, .completed)
        await store.handleSceneInactive()
        let events = await io.events
        XCTAssertEqual(events, activated + [.tunnelStart, .tunnelStop])
    }

    @MainActor
    func testUnavailableDeviceQueuesActionsAndAppliesExitWhenRouteRecovers() async throws {
        let demo = AppEnvironment.demo(), phone = DemoLocationEngine.defaultDevice
        let io = CommandIO([#"{"ip":"192.0.2.8","city":"Tokyo","loc":"35,139"}"#])
        let env = AppEnvironment(engine: io, pairingStore: demo.pairingStore, tunnel: demo.tunnelCoordinator,
            stateStore: demo.stateStore, exitService: ExitIPService(transport: io), notifier: demo.notifier)
        let store = AppStore(environment: env)
        let pairing = try await store.importPairing(data: LockdownPlist(udid: phone.id.rawValue).data(),
            endpointHost: "192.0.2.99", deviceName: nil)
        await store.refreshDevices()
        XCTAssertFalse(store.canOperate)
        XCTAssertTrue(store.canSelectTarget)
        XCTAssertFalse(store.needsPairingSetup)

        let city = Place.defaults[0]
        await store.applyOrQueue(place: city, source: .city)
        let queued = try XCTUnwrap(store.pendingAction)
        XCTAssertEqual(queued, .set(name: city.displayName, coordinate: city.coordinate, source: .city, exitIP: nil, createdAt: queued.createdAt))
        store.cancelPendingAction()
        XCTAssertNil(store.pendingAction)
        await store.clearLocationOrQueue()
        let clear = try XCTUnwrap(store.pendingAction)
        XCTAssertEqual(clear, .clear(createdAt: clear.createdAt))
        store.cancelPendingAction()
        XCTAssertNil(store.pendingAction)

        await store.followExitOrQueue()
        let exit = try XCTUnwrap(store.exit), follow = try XCTUnwrap(store.pendingAction)
        XCTAssertEqual(exit.ip, "192.0.2.8")
        XCTAssertEqual(follow, .set(name: exit.displayCity, coordinate: exit.coordinate, source: .exitIP, exitIP: exit.ip, createdAt: follow.createdAt))
        let before = await io.events
        XCTAssertEqual(before, [.exitLookup])
        XCTAssertNil(store.selectedRecord)
        _ = try await env.pairingStore.updateEndpointHost(phone.endpointHost, for: pairing.id)
        await store.refreshDevices()
        XCTAssertTrue(store.canOperate)
        XCTAssertNil(store.pendingAction)
        XCTAssertEqual(store.selectedRecord?.source, .exitIP)
        XCTAssertEqual(store.selectedRecord?.exitIP, exit.ip)
        XCTAssertEqual(store.selectedRecord?.coordinate, exit.coordinate)
        let after = await io.events
        XCTAssertEqual(after, [.exitLookup, .set(phone.id)])

        _ = try await env.pairingStore.updateEndpointHost("192.0.2.99", for: pairing.id)
        await store.refreshDevices()
        XCTAssertFalse(store.canOperate)
        await store.deletePairing(id: pairing.id)
        XCTAssertTrue(store.needsPairingSetup)
        XCTAssertFalse(store.canSelectTarget)
        await store.applyOrQueue(name: city.displayName, coordinate: city.coordinate, source: .custom)
        XCTAssertNil(store.pendingAction)
        await store.clearLocationOrQueue()
        XCTAssertNil(store.pendingAction)
        let unpaired = await io.events
        XCTAssertEqual(unpaired, after)
    }

    @MainActor
    func testSettingsResetInvalidatesQueuedExitAndRejectsSupersededFollow() async throws {
        let demo = AppEnvironment.demo(), phone = DemoLocationEngine.defaultDevice
        let io = CommandIO([#"{"ip":"192.0.2.8","city":"Tokyo","loc":"35,139"}"#]
            + Array(repeating: #"{"ip":"192.0.2.9","city":"Tokyo","loc":"35,139"}"#, count: 3))
        let env = AppEnvironment(engine: io, pairingStore: demo.pairingStore, tunnel: demo.tunnelCoordinator,
            stateStore: demo.stateStore, exitService: ExitIPService(transport: io), notifier: demo.notifier)
        let store = AppStore(environment: env)
        let pairing = try await store.importPairing(data: LockdownPlist(udid: phone.id.rawValue).data(),
            endpointHost: "192.0.2.99", deviceName: nil)
        await store.refreshDevices()
        XCTAssertFalse(store.canOperate)
        await store.followExitOrQueue()
        let exit = try XCTUnwrap(store.exit), queued = try XCTUnwrap(store.pendingAction)
        XCTAssertEqual(queued, .set(name: exit.displayCity, coordinate: exit.coordinate, source: .exitIP, exitIP: "192.0.2.8", createdAt: queued.createdAt))
        await store.updateSettings { $0.exitFeaturesEnabled = false }
        XCTAssertNil(store.pendingAction)
        await store.updateSettings { $0.exitFeaturesEnabled = true }
        XCTAssertNil(store.pendingAction)
        _ = try await env.pairingStore.updateEndpointHost(phone.endpointHost, for: pairing.id)
        await store.refreshDevices()
        XCTAssertTrue(store.canOperate)
        XCTAssertNil(store.selectedRecord)

        _ = try await env.pairingStore.updateEndpointHost("192.0.2.99", for: pairing.id)
        await store.refreshDevices()
        await store.followExitOrQueue()
        XCTAssertNotNil(store.pendingAction)
        await store.updateSettings { $0.customProxyText = "localhost:9000" }
        XCTAssertNil(store.pendingAction)
        XCTAssertEqual(store.exit?.ip, "192.0.2.9")
        let prefetched = ExitInfo(ip: exit.ip, city: exit.city, region: exit.region, country: exit.country,
            coordinate: exit.coordinate, org: exit.org, sampledAt: Date(timeIntervalSinceNow: -30))
        XCTAssertLessThan(Date().timeIntervalSince(prefetched.sampledAt), 60)
        XCTAssertGreaterThan(try XCTUnwrap(store.exit).sampledAt, prefetched.sampledAt)
        await store.followExitOrQueue(prefetched: prefetched)
        XCTAssertEqual(store.exit?.ip, "192.0.2.9")
        let current = try XCTUnwrap(store.pendingAction)
        XCTAssertEqual(current, .set(name: exit.displayCity, coordinate: exit.coordinate, source: .exitIP, exitIP: "192.0.2.9", createdAt: current.createdAt))
        _ = try await env.pairingStore.updateEndpointHost(phone.endpointHost, for: pairing.id)
        await store.refreshDevices()
        XCTAssertTrue(store.canOperate)
        XCTAssertNil(store.pendingAction)
        XCTAssertEqual(store.exit?.ip, "192.0.2.9")
        XCTAssertEqual(store.selectedRecord?.exitIP, "192.0.2.9")
        let events = await io.events
        XCTAssertEqual(events, Array(repeating: .exitLookup, count: 4) + [.set(phone.id)])
    }

    @MainActor
    func testIdentityBindingMigratesSelectedDeviceID() async throws {
        struct BindingEngine: LocationEngineProtocol {
            let abiVersion: UInt32 = 1
            let pairing: StoredPairingRecord
            func probe(deviceID: DeviceID, endpointHost: String) -> TargetDevice {
                XCTAssertEqual(deviceID, pairing.probeID)
                XCTAssertEqual(endpointHost, pairing.endpointHost)
                return DemoLocationEngine.defaultDevice
            }
            func prepareDDI(for deviceID: DeviceID, onStage: @Sendable (EngineOperationStage) -> Void) { XCTFail("身份绑定不应准备 DDI") }
            func setLocation(_ coordinate: WGS84Coordinate, on deviceID: DeviceID, onStage: @Sendable (EngineOperationStage) -> Void) { XCTFail("身份绑定不应下发定位") }
            func clearLocation(on deviceID: DeviceID, onStage: @Sendable (EngineOperationStage) -> Void) { XCTFail("身份绑定不应清除定位") }
        }
        let demo = AppEnvironment.demo(), phone = DemoLocationEngine.defaultDevice
        let (pairings, _, _) = try makePairingStore()
        let pairing = try await pairings.importPairing(data: LockdownPlist().data(), endpointHost: phone.endpointHost, deviceName: nil)
        let env = AppEnvironment(engine: BindingEngine(pairing: pairing), pairingStore: pairings, tunnel: demo.tunnelCoordinator,
            stateStore: AppStateStore(storageDirectory: try makeTemporaryDirectory()), exitService: demo.exitService, notifier: demo.notifier)
        let store = AppStore(environment: env)
        XCTAssertNil(pairing.udid)
        XCTAssertNotEqual(pairing.probeID, phone.id)
        await store.selectDevice(pairing.probeID)
        XCTAssertEqual(store.selectedDeviceID, pairing.probeID)
        await store.refreshDevices()
        XCTAssertEqual(store.selectedDeviceID, phone.id)
        XCTAssertEqual(store.selectedDevice?.id, phone.id)
        XCTAssertTrue(store.canOperate)
        let saved = try await env.stateStore.load()
        XCTAssertEqual(saved.selectedDeviceID, phone.id)
    }

    @MainActor
    func testQueuedFailurePreservesRetryWhileUnknownOutcomeDoesNot() async throws {
        let demo = AppEnvironment.demo(), phone = DemoLocationEngine.defaultDevice, io = CommandIO([])
        let env = AppEnvironment(engine: io, pairingStore: demo.pairingStore, tunnel: demo.tunnelCoordinator,
            stateStore: demo.stateStore, exitService: demo.exitService, notifier: demo.notifier)
        let store = AppStore(environment: env), city = Place.defaults[0]
        await store.updateSettings { $0.autoRestore = false }
        let pairing = try await store.importPairing(data: LockdownPlist(udid: phone.id.rawValue).data(),
            endpointHost: "192.0.2.99", deviceName: nil)
        await store.refreshDevices()
        await store.applyOrQueue(place: city, source: .city)
        let queued = try XCTUnwrap(store.pendingAction)
        await io.fail(.set(phone.id))
        _ = try await env.pairingStore.updateEndpointHost(phone.endpointHost, for: pairing.id)
        await store.refreshDevices()
        XCTAssertEqual(store.pendingAction, queued)
        XCTAssertNil(store.selectedRecord)
        XCTAssertEqual(store.deviceStates[phone.id], .failed("设备错误"))
        await store.executePendingAction()
        XCTAssertNil(store.pendingAction)
        XCTAssertEqual(store.selectedRecord?.coordinate, city.coordinate)
        XCTAssertEqual(store.selectedRecord?.confidence, .confirmed)
        let retried = await io.events
        XCTAssertEqual(retried, [.set(phone.id), .set(phone.id)])

        _ = try await env.pairingStore.updateEndpointHost("192.0.2.99", for: pairing.id)
        await store.refreshDevices()
        await store.clearLocationOrQueue()
        let clear = try XCTUnwrap(store.pendingAction)
        XCTAssertEqual(clear, .clear(createdAt: clear.createdAt))
        await io.fail(.clear(phone.id), unknown: true)
        _ = try await env.pairingStore.updateEndpointHost(phone.endpointHost, for: pairing.id)
        await store.refreshDevices()
        XCTAssertNil(store.pendingAction)
        XCTAssertEqual(store.selectedRecord?.confidence, .clearUnknown)
        await store.executePendingAction()
        let events = await io.events
        XCTAssertEqual(events, retried + [.clear(phone.id)])
    }

    func testPendingLocationActionsExpireAfterTenMinutes() {
        let now = Date(timeIntervalSince1970: 1_000), city = Place.defaults[0]
        let set = PendingLocationAction.set(name: city.displayName, coordinate: city.coordinate, source: .city,
                                           exitIP: nil, createdAt: now.addingTimeInterval(-601))
        let clear = PendingLocationAction.clear(createdAt: set.createdAt)
        for action in [set, clear] {
            XCTAssertFalse(action.isFresh(at: now))
            XCTAssertTrue(action.isFresh(at: now.addingTimeInterval(-1)))
        }
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
        XCTAssertFalse(store.needsPairingSetup)
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
        XCTAssertNil(store.feedback)
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
