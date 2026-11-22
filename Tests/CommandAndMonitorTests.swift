import UserNotifications
import XCTest
import os
@testable import ElsewhereMobile

private let phone = DemoLocationEngine.defaultDevice, city = Place.defaults[0]
private let builtIn = AppSettings(channelMode: .builtInTunnel)
private let oldIP = "192.0.2.1", newIP = "192.0.2.2"

private func detail(_ ip: String) -> String { #"{"ip":"\#(ip)","city":"Tokyo","loc":"35.68,139.76"}"# }

private func device(_ id: String, host: String = phone.endpointHost) -> TargetDevice {
    TargetDevice(id: DeviceID(rawValue: id)!, name: id, deviceClass: "iPhone", productType: nil, osVersion: nil,
                 endpointHost: host, paired: true, developerMode: true, wifiEnabled: nil,
                 timeZoneID: nil, cellular: nil, ddiMounted: true)
}

actor CommandIO: HTTPDataTransport, LocationEngineProtocol {
    enum Event: Hashable, Sendable { case exitLookup, currentIP, tunnelStart, tunnelStop, mounting(DeviceID), set(DeviceID), clear(DeviceID) }
    private(set) var events: [Event] = []
    private(set) var coordinates: [DeviceID: WGS84Coordinate] = [:]
    private let devices: DemoLocationEngine
    private var replies: [String?]
    private var gates: [Event: @Sendable () async -> Void] = [:]
    private var failures: [Event: EngineError] = [:]
    nonisolated let abiVersion: UInt32 = 1

    init(_ replies: [String?], devices: [TargetDevice] = [DemoLocationEngine.defaultDevice]) {
        self.replies = replies
        self.devices = DemoLocationEngine(devices: devices)
    }

    func pause(_ event: Event, entered: XCTestExpectation) -> AsyncStream<Void>.Continuation {
        let (stream, release) = AsyncStream<Void>.makeStream()
        gates[event] = { entered.fulfill(); for await _ in stream {} }
        return release
    }

    func record(_ event: Event) async {
        events.append(event)
        if let gate = gates.removeValue(forKey: event) { await gate() }
    }

    func fail(_ event: Event, unknown: Bool = false) {
        failures[event] = EngineError(code: unknown ? .no_service : .locked, stage: "device", message: "设备错误", outcomeUnknown: unknown)
    }

    func data(for request: URLRequest, proxy: ExitProxyAddress?) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        await record(url.path == "/json" ? .exitLookup : .currentIP)
        guard !replies.isEmpty else { XCTFail("意外请求 \(url)"); throw URLError(.badURL) }
        guard let body = replies.removeFirst() else { throw URLError(.timedOut) }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func probe(deviceID: DeviceID, endpointHost: String) async throws(EngineError) -> TargetDevice {
        try await devices.probe(deviceID: deviceID, endpointHost: endpointHost)
    }
    func prepareDDI(for deviceID: DeviceID, onStage: @Sendable (EngineOperationStage) -> Void) { XCTFail("引擎负责准备 DDI") }
    func setLocation(_ coordinate: WGS84Coordinate, on deviceID: DeviceID, onStage: @Sendable (EngineOperationStage) -> Void) async throws(EngineError) {
        if let mounting = gates.removeValue(forKey: .mounting(deviceID)) {
            onStage(.mountingDDI)
            await mounting()
        }
        onStage(.applyingLocation)
        await record(.set(deviceID))
        if let error = failures.removeValue(forKey: .set(deviceID)) { throw error }
        coordinates[deviceID] = coordinate
    }
    func clearLocation(on deviceID: DeviceID, onStage: @Sendable (EngineOperationStage) -> Void) async throws(EngineError) {
        await record(.clear(deviceID))
        if let error = failures.removeValue(forKey: .clear(deviceID)) { throw error }
        coordinates[deviceID] = nil
        onStage(.clearingLocation)
    }
}

actor CommandTunnel: TunnelProviderAdapter {
    let io: CommandIO
    private(set) var hosts = [String]()
    private var status = TunnelConnectionStatus.disconnected
    init(io: CommandIO) { self.io = io }
    func currentStatus() -> TunnelConnectionStatus { status }
    func start(targetHost: String) async { hosts.append(targetHost); await io.record(.tunnelStart); status = .connected }
    func stop() async { await io.record(.tunnelStop); status = .disconnected }
}

private struct MonitorNotifications: NotificationCenterAdapter {
    let categories = OSAllocatedUnfairLock(initialState: [String]())
    let eventIDs = OSAllocatedUnfairLock(initialState: [UUID]())
    func register(delegate: UNUserNotificationCenterDelegate) {}
    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization() async {}
    func post(_ content: UNNotificationContent) {
        let category = content.categoryIdentifier
        categories.withLock { $0.append(category) }
        if let string = content.userInfo[Notifier.eventIDKey] as? String, let id = UUID(uuidString: string) {
            eventIDs.withLock { $0.append(id) }
        }
    }
}

private struct Fixture: Sendable {
    let io: CommandIO, tunnel: TunnelCoordinator, commands: CommandService, monitor: ExitMonitorService
    let store: AppStateStore, notices = MonitorNotifications()
    let adapter: CommandTunnel

    init(_ replies: [String?] = [], directory: URL? = nil, now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 100) }) {
        store = AppStateStore(storageDirectory: directory, snapshotSuiteName: nil)
        io = CommandIO(replies)
        adapter = CommandTunnel(io: io)
        tunnel = TunnelCoordinator(adapter: adapter)
        let exit = ExitIPService(transport: io, now: now)
        commands = CommandService(engine: io, tunnel: tunnel, stateStore: store, exitService: exit, clock: now)
        monitor = ExitMonitorService(exitService: exit, commandService: commands, tunnel: tunnel,
                                     notifier: Notifier(center: notices), stateStore: store, now: now)
    }
}

final class CommandAndMonitorTests: XCTestCase {
    func testDisabledEntriesAndWatchOffMakeNoRequests() async throws {
        let fixture = Fixture(), off = AppSettings(exitFeaturesEnabled: false)
        let manual = await fixture.monitor.refreshManually(settings: off, proxy: nil)
        let foreground = await fixture.monitor.handleForegroundReturn(settings: off, proxy: nil, targets: [phone])
        let check = await fixture.monitor.checkChange(settings: off, proxy: nil, targets: [phone])
        let watchOff = await fixture.monitor.checkChange(settings: AppSettings(watchMode: .off), proxy: nil, targets: [phone])
        XCTAssertEqual([manual, check, watchOff], [.disabled, .disabled, .disabled])
        XCTAssertNil(foreground)
        do {
            _ = try await fixture.commands.followExit(targets: [phone], settings: off, proxy: nil)
            XCTFail("关闭出口后不应跟随")
        } catch is CancellationError {}
        let events = await fixture.io.events, snapshot = await fixture.store.widgetSnapshot
        XCTAssertEqual(events, [])
        XCTAssertEqual(snapshot?.exitFeaturesEnabled, false)
    }

    func testExitSamplePrecedesTunnel() async throws {
        let fixture = Fixture([detail(newIP)])
        let (exit, result) = try await fixture.commands.followExit(targets: [phone], settings: builtIn, proxy: nil)
        let events = await fixture.io.events
        XCTAssertEqual(events, [.exitLookup, .tunnelStart, .set(phone.id), .tunnelStop])
        XCTAssertEqual(result.records[phone.id]?.exitIP, exit.ip)
    }

    func testManualCityWinsDuringAutomaticLookup() async throws {
        let fixture = Fixture([detail(newIP)]), entered = expectation(description: "出口查询在途")
        let release = await fixture.io.pause(.exitLookup, entered: entered)
        let follow = Task { try await fixture.commands.followExit(targets: [phone], settings: builtIn, proxy: nil, isAutomatic: true) }
        await fulfillment(of: [entered], timeout: 5)
        let manual = await fixture.commands.applyLocation(name: city.name, coordinate: city.coordinate, source: .city, exitIP: nil,
                                                         targets: [phone], settings: AppSettings())
        release.finish()
        let (_, result) = try await follow.value
        let events = await fixture.io.events, snapshot = await fixture.store.widgetSnapshot
        XCTAssertEqual(result, BatchOutcome(records: manual.records))
        XCTAssertEqual(events, [.exitLookup, .set(phone.id)])
        XCTAssertEqual(snapshot?.locationName, city.name)
    }

    func testForegroundFreshnessAndDisableDuringLookup() async {
        let time = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 100))
        let fixture = Fixture([detail(oldIP), newIP, detail(newIP)], now: { time.withLock { $0 } }), settings = AppSettings()
        guard case .updated? = await fixture.monitor.handleForegroundReturn(settings: settings, proxy: nil, targets: [phone]) else { return XCTFail("首次应刷新") }
        time.withLock { $0.addTimeInterval(60) }
        let recent = await fixture.monitor.handleForegroundReturn(settings: settings, proxy: nil, targets: [phone])
        XCTAssertNil(recent)
        time.withLock { $0.addTimeInterval(1) }
        let entered = expectation(description: "过期出口重新采样"), release = await fixture.io.pause(.exitLookup, entered: entered)
        let refresh = Task { await fixture.monitor.handleForegroundReturn(settings: settings, proxy: nil, targets: [phone]) }
        await fulfillment(of: [entered], timeout: 5)
        await fixture.monitor.invalidateDisabledState()
        release.finish()
        _ = await refresh.value
        let ip = await fixture.monitor.lastConfirmedIP, exit = await fixture.monitor.lastExit, snapshot = await fixture.store.widgetSnapshot
        XCTAssertNil(ip)
        XCTAssertNil(exit)
        XCTAssertNil(snapshot?.exitSummary)
        XCTAssertEqual(snapshot?.exitFeaturesEnabled, false)
    }

    func testPartialBatchAndClearOnlyChangeAcknowledgedRecords() async throws {
        let fixture = Fixture(), other = device("other"), absent = device("absent"), locked = device("locked"), lost = device("lost")
        let earlier = await fixture.commands.applyLocation(name: city.name, coordinate: city.coordinate, source: .city, exitIP: nil,
                                                          targets: [locked], settings: AppSettings())
        await fixture.io.fail(.set(locked.id))
        await fixture.io.fail(.set(lost.id), unknown: true)
        await fixture.io.fail(.clear(other.id))
        let batch = await fixture.commands.applyLocation(name: city.name, coordinate: city.coordinate, source: .custom, exitIP: nil,
                                                        targets: [phone, other, absent, locked, lost], settings: builtIn)
        let events = await fixture.io.events
        XCTAssertEqual(events, [.set(locked.id), .tunnelStart, .set(phone.id), .set(other.id), .set(absent.id), .set(locked.id), .set(lost.id), .tunnelStop])
        XCTAssertEqual(batch.succeeded, [phone, other, absent])
        XCTAssertEqual(batch.records[phone.id]?.confidence, .confirmed)
        XCTAssertEqual(batch.failed.map(\.device), [locked])
        XCTAssertEqual(batch.records[locked.id], earlier.records[locked.id])
        XCTAssertEqual(batch.unknown, [lost])
        XCTAssertEqual(batch.records[lost.id]?.confidence, .unknownOutcome)
        let clear = await fixture.commands.clearLocation(targets: [phone], allReadyDevices: [other, phone, lost, locked], settings: builtIn)
        XCTAssertEqual(clear.succeeded, [phone])
        XCTAssertEqual(clear.failed.map(\.device), [other])
        XCTAssertEqual(clear.records, batch.records.filter { $0.key != phone.id })
        let persisted = try await fixture.store.load().records, after = await fixture.io.events
        XCTAssertEqual(persisted, clear.records)
        XCTAssertEqual(Array(after.dropFirst(events.count)), [.tunnelStart, .clear(phone.id), .clear(other.id), .tunnelStop])
    }

    func testRestartClearsPreviousBatchAndKeepsOnlyUnclearedIDs() async throws {
        let dir = try makeTemporaryDirectory(), other = device("other"), offline = device("offline")
        let first = Fixture(directory: dir)
        _ = await first.commands.applyLocation(name: city.name, coordinate: city.coordinate, source: .city,
            exitIP: nil, targets: [phone, other, offline], settings: builtIn)
        let reopened = Fixture(directory: dir)
        let cleared = await reopened.commands.clearLocation(targets: [phone], allReadyDevices: [phone, other], settings: builtIn)
        XCTAssertEqual(cleared.succeeded, [phone, other])
        let state = try await reopened.store.load()
        XCTAssertEqual(state.lastAppliedBatchIDs, [offline.id])
        XCTAssertEqual(Set(state.records.keys), [offline.id])
    }

    func testUnacknowledgedClearPreservesLocationAndBlocksRestoreAndSupplementalClear() async throws {
        let fixture = Fixture(), other = device("other")
        try await fixture.store.saveSelectedDeviceID(phone.id)
        _ = await fixture.commands.applyLocation(name: city.name, coordinate: city.coordinate, source: .city,
            exitIP: nil, targets: [phone, other], settings: builtIn)
        await fixture.io.fail(.clear(phone.id), unknown: true)
        let clear = await fixture.commands.clearLocation(targets: [phone], allReadyDevices: [], settings: builtIn)
        XCTAssertEqual(clear.unknown, [phone])
        let record = try await fixture.store.load().records[phone.id]
        XCTAssertEqual(record?.confidence, .clearUnknown)
        XCTAssertEqual(record?.name, city.name)
        XCTAssertEqual(record?.coordinate, city.coordinate)
        let snapshot = await fixture.store.widgetSnapshot
        XCTAssertEqual(snapshot?.locationState, .clearUnknown)
        for ready in [[phone], [], [phone]] {
            let result = await fixture.commands.observeDevicesAndRestoreIfNeeded(readyDevices: ready, settings: builtIn)
            XCTAssertTrue(result.isEmpty)
        }
        let second = await fixture.commands.clearLocation(targets: [other], allReadyDevices: [phone, other], settings: builtIn)
        XCTAssertEqual(second.succeeded, [other])
        XCTAssertEqual(second.records[phone.id], record)
        let retry = await fixture.commands.clearLocation(targets: [phone], allReadyDevices: [], settings: builtIn)
        XCTAssertEqual(retry.succeeded, [phone])
        let final = await fixture.store.widgetSnapshot
        XCTAssertEqual(final?.locationState, .real)
        XCTAssertEqual(final?.selectedDeviceName, phone.name)
    }

    func testBuiltInChannelGroupsAdjacentDevicesByPeer() async {
        let fixture = Fixture(), second = device("second"), third = device("third", host: "fd00::1")
        let result = await fixture.commands.applyLocation(name: city.name, coordinate: city.coordinate, source: .city,
            exitIP: nil, targets: [phone, second, third], settings: builtIn)
        let hosts = await fixture.adapter.hosts, events = await fixture.io.events
        XCTAssertEqual(hosts, [phone.endpointHost, third.endpointHost])
        XCTAssertEqual(events, [.tunnelStart, .set(phone.id), .set(second.id), .tunnelStop, .tunnelStart, .set(third.id), .tunnelStop])
        XCTAssertEqual(result.succeeded, [phone, second, third])
    }

    func testForegroundReturnUsesPersistedBaselineAfterSixtySeconds() async throws {
        let dir = try makeTemporaryDirectory()
        let first = Fixture([detail(oldIP)], directory: dir)
        _ = await first.monitor.refreshManually(settings: builtIn, proxy: nil)
        let reopened = Fixture([newIP, detail(newIP)], directory: dir, now: { Date(timeIntervalSince1970: 161) })
        let outcome = await reopened.monitor.handleForegroundReturn(settings: builtIn, proxy: nil, targets: [phone])
        guard case .pendingChange(let event)? = outcome else { return XCTFail("应报告后台期间的变化") }
        XCTAssertEqual(event.exit.ip, newIP)
        XCTAssertEqual(event.targetDeviceIDs, [phone.id])
        let saved = try await reopened.store.load()
        XCTAssertEqual(saved.pendingExitEvent, event)
        XCTAssertEqual(saved.exitBaseline?.lastConfirmedIP, newIP)
    }

    func testProxySwitchClearsPriorBaselineEventAndDisplay() async throws {
        let proxy = try XCTUnwrap(ExitProxyAddress("localhost:8123"))
        let fixture = Fixture([oldIP, newIP, detail(newIP), oldIP])
        _ = await fixture.monitor.checkChange(settings: builtIn, proxy: nil, targets: [phone])
        _ = await fixture.monitor.checkChange(settings: builtIn, proxy: nil, targets: [phone])
        let switched = await fixture.monitor.checkChange(settings: builtIn, proxy: proxy, targets: [phone])
        XCTAssertEqual(switched, .unchanged(nil))
        let saved = try await fixture.store.load(), snapshot = await fixture.store.widgetSnapshot
        XCTAssertEqual(saved.exitBaseline?.proxyKey, proxy.display)
        XCTAssertNil(saved.pendingExitEvent)
        XCTAssertNil(snapshot?.exitSummary)
        await fixture.monitor.resetForProxyChange()
        let reset = try await fixture.store.load()
        XCTAssertNil(reset.exitBaseline)
        let ip = await fixture.monitor.lastConfirmedIP
        XCTAssertNil(ip)
    }

    func testCancellationKeepsReceivedAckAndReleasesBatchLease() async {
        let fixture = Fixture(), other = device("other"), entered = expectation(description: "等待第一台回执")
        let release = await fixture.io.pause(.set(phone.id), entered: entered)
        let task = Task { await fixture.commands.applyLocation(name: city.name, coordinate: city.coordinate, source: .city, exitIP: nil,
                                                              targets: [phone, other], settings: builtIn) }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        release.finish()
        let batch = await task.value, events = await fixture.io.events
        XCTAssertEqual(batch.succeeded, [phone])
        XCTAssertEqual(batch.failed.map(\.error.code), [.cancelled])
        XCTAssertEqual(Set(batch.records.keys), [phone.id])
        XCTAssertEqual(events, [.tunnelStart, .set(phone.id), .tunnelStop])
    }

    func testOverlappingBatchesQueueWhileAnotherDeviceFinishes() async {
        let fixture = Fixture(), second = device("second"), third = device("third"), entered = expectation(description: "首台设备正在写入")
        let release = await fixture.io.pause(.set(phone.id), entered: entered)
        let batch = Task { await fixture.commands.applyLocation(name: city.name, coordinate: city.coordinate, source: .city, exitIP: nil,
                                                               targets: [phone, second], settings: AppSettings()) }
        await fulfillment(of: [entered], timeout: 5)
        let clear = Task { await fixture.commands.clearLocation(targets: [second], allReadyDevices: [], settings: AppSettings()) }
        let separate = await fixture.commands.applyLocation(name: city.name, coordinate: city.coordinate, source: .city, exitIP: nil,
                                                           targets: [third], settings: AppSettings())
        XCTAssertEqual(separate.succeeded, [third])
        release.finish()
        _ = await batch.value
        let result = await clear.value, events = await fixture.io.events
        XCTAssertEqual(events, [.set(phone.id), .set(third.id), .set(second.id), .clear(second.id)])
        XCTAssertEqual(Set(result.records.keys), [phone.id, third.id])
    }

    func testFailedDetailRetriesThenFollowsAndNotifiesPerDevice() async throws {
        let next = "192.0.2.3", fixture = Fixture([oldIP, newIP, nil, newIP, detail(newIP), next, detail(next)])
        let settings = AppSettings(watchMode: .auto, channelMode: .builtInTunnel), other = device("other")
        try await fixture.store.saveSettings(settings)
        _ = await fixture.commands.applyLocation(name: "old", coordinate: city.coordinate, source: .exitIP, exitIP: oldIP, targets: [phone], settings: AppSettings())
        let baseline = await fixture.monitor.checkChange(settings: settings, proxy: nil, targets: [phone])
        XCTAssertEqual(baseline, .unchanged(nil))
        guard case .failed = await fixture.monitor.checkChange(settings: settings, proxy: nil, targets: [phone]) else { return XCTFail("详情应失败") }
        let confirmed = await fixture.monitor.lastConfirmedIP, retry = await fixture.monitor.pendingRetryIP
        XCTAssertEqual(confirmed, oldIP)
        XCTAssertEqual(retry, newIP)
        guard case let .autoFollowed(exit, batch, pendingEvent) = await fixture.monitor.checkChange(settings: settings, proxy: nil, targets: [other, phone])
        else { return XCTFail("重试应自动跟随") }
        XCTAssertEqual(batch.succeeded, [phone])
        XCTAssertEqual(batch.records[phone.id]?.exitIP, exit.ip)
        let event = try XCTUnwrap(pendingEvent)
        XCTAssertEqual(event.targetDeviceIDs, [other.id])
        XCTAssertEqual(event.exit, exit)
        XCTAssertEqual(fixture.notices.eventIDs.withLock { $0 }, [event.id])
        let saved = await fixture.monitor.pendingEvent(for: event.id)
        XCTAssertEqual(saved, event)
        guard case .pendingChange = await fixture.monitor.checkChange(settings: settings, proxy: nil, targets: [phone], isBackground: true)
        else { return XCTFail("后台没有通道时应提醒") }
        let events = await fixture.io.events, pending = await fixture.monitor.pendingRetryIP
        XCTAssertNil(pending)
        XCTAssertEqual(events, [.set(phone.id), .currentIP, .currentIP, .exitLookup, .currentIP, .exitLookup,
                                .tunnelStart, .set(phone.id), .tunnelStop, .currentIP, .exitLookup])
        XCTAssertEqual(fixture.notices.categories.withLock { $0 }, [Notifier.exitChangedCategory, Notifier.exitChangedCategory])
    }

    func testOwnTunnelSwitchIgnoresPathChange() async throws {
        let fixture = Fixture(), entered = expectation(description: "通道正在启动")
        let release = await fixture.io.pause(.tunnelStart, entered: entered)
        let probe = Task { try await fixture.commands.probe(deviceID: phone.id, endpointHost: phone.endpointHost, settings: builtIn) }
        await fulfillment(of: [entered], timeout: 5)
        let switching = await fixture.tunnel.isSwitchingChannel, check = await fixture.monitor.checkChange(settings: builtIn, proxy: nil, targets: [phone])
        release.finish()
        let result = try await probe.value, events = await fixture.io.events
        XCTAssertTrue(switching)
        XCTAssertEqual(check, .unchanged(nil))
        XCTAssertEqual(result, phone)
        XCTAssertEqual(events, [.tunnelStart, .tunnelStop])
    }

    func testDiscrepancyPostsWithoutFollowActionOrTunnel() async {
        let fixture = Fixture([oldIP, newIP, detail(oldIP)])
        _ = await fixture.monitor.checkChange(settings: builtIn, proxy: nil, targets: [phone])
        let result = await fixture.monitor.checkChange(settings: builtIn, proxy: nil, targets: [phone])
        let ip = await fixture.monitor.lastConfirmedIP, events = await fixture.io.events
        XCTAssertEqual(result, .discrepancy(probeIP: newIP, detailIP: oldIP))
        XCTAssertEqual(ip, oldIP)
        XCTAssertEqual(events, [.currentIP, .currentIP, .exitLookup])
        XCTAssertEqual(fixture.notices.categories.withLock { $0 }, [""])
    }

    func testReconnectAndMountLossReplayUntilManuallyInvalidatedOrDisabled() async {
        let fixture = Fixture(), ready = device(phone.id.rawValue), settings = AppSettings()
        _ = await fixture.commands.applyLocation(name: city.name, coordinate: city.coordinate, source: .city, exitIP: nil, targets: [ready], settings: settings)
        for (devices, expected) in [([ready], []), ([], []), ([ready], [ready]), ([phone], [phone]), ([ready], [])] {
            let results = await fixture.commands.observeDevicesAndRestoreIfNeeded(readyDevices: devices, settings: settings)
            XCTAssertEqual(results.flatMap(\.succeeded), expected)
        }
        let coordinate = await fixture.io.coordinates[phone.id]
        XCTAssertEqual(coordinate, city.coordinate)
        await fixture.io.fail(.set(phone.id))
        let loss = await fixture.commands.observeDevicesAndRestoreIfNeeded(readyDevices: [phone], settings: settings)
        XCTAssertEqual(loss.first?.failed.map(\.device), [phone])
        _ = await fixture.commands.applyLocation(name: "manual", coordinate: city.coordinate, source: .custom, exitIP: nil, targets: [phone], settings: settings)
        let manual = await fixture.commands.observeDevicesAndRestoreIfNeeded(readyDevices: [phone], settings: settings)
        XCTAssertEqual(manual, [])
        _ = await fixture.commands.observeDevicesAndRestoreIfNeeded(readyDevices: [], settings: settings)
        await fixture.io.fail(.set(phone.id))
        _ = await fixture.commands.observeDevicesAndRestoreIfNeeded(readyDevices: [phone], settings: settings)
        _ = await fixture.commands.observeDevicesAndRestoreIfNeeded(readyDevices: [phone], settings: AppSettings(autoRestore: false))
        let reenabled = await fixture.commands.observeDevicesAndRestoreIfNeeded(readyDevices: [phone], settings: settings)
        XCTAssertEqual(reenabled, [])
        _ = await fixture.commands.observeDevicesAndRestoreIfNeeded(readyDevices: [], settings: settings)
        for _ in 0..<AutoRestoreTracker.maxAttempts {
            await fixture.io.fail(.set(phone.id))
            let retry = await fixture.commands.observeDevicesAndRestoreIfNeeded(readyDevices: [phone], settings: settings)
            XCTAssertEqual(retry.first?.failed.map(\.device), [phone])
        }
        let exhausted = await fixture.commands.observeDevicesAndRestoreIfNeeded(readyDevices: [phone], settings: settings)
        XCTAssertEqual(exhausted, [])
    }
}
