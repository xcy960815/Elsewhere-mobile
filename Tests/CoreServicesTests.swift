import UserNotifications
import XCTest
import os
@testable import ElsewhereMobile

private actor StubHTTPTransport: HTTPDataTransport {
    enum Reply: Sendable {
        case http(Int, String), failure(URLError.Code)
    }

    private var replies: [Reply]
    private(set) var calls: [(request: URLRequest, proxy: ExitProxyAddress?, at: ContinuousClock.Instant)] = []

    init(_ replies: Reply...) { self.replies = replies }

    func data(for request: URLRequest, proxy: ExitProxyAddress?) throws -> (Data, HTTPURLResponse) {
        calls.append((request, proxy, .now))
        guard !replies.isEmpty else {
            XCTFail("意外的网络请求 \(request)")
            throw URLError(.resourceUnavailable)
        }
        switch replies.removeFirst() {
        case .http(let status, let body):
            return (Data(body.utf8), HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil)!)
        case .failure(let code): throw URLError(code)
        }
    }
}

private struct StubNotificationCenter: NotificationCenterAdapter {
    struct State {
        var registered = false
        var status = UNAuthorizationStatus.notDetermined
        var prompts = 0
        var post: [String] = []
    }
    let state = OSAllocatedUnfairLock(initialState: State())

    func register(delegate: UNUserNotificationCenterDelegate) { state.withLock { $0.registered = true } }
    func authorizationStatus() async -> UNAuthorizationStatus { state.withLock { $0.status } }
    func requestAuthorization() async {
        state.withLock {
            $0.prompts += 1
            $0.status = .denied
        }
    }
    func post(_ content: UNNotificationContent) {
        let fields = [content.title, content.body, content.categoryIdentifier]
        state.withLock { $0.post = fields }
    }
}

final class CoreServicesTests: XCTestCase {
    private let record = AppliedLocationRecord(deviceID: DeviceID(rawValue: "target")!, deviceName: "iPad", name: "东京",
        coordinate: WGS84Coordinate(latitude: 35.68, longitude: 139.76)!, appliedAt: Date(timeIntervalSince1970: 1_704_067_200),
        source: .city, exitIP: nil, confidence: .confirmed)

    private func device(_ cellular: Bool?, zone: String? = "America/Phoenix") -> TargetDevice {
        TargetDevice(id: record.deviceID, name: record.deviceName, deviceClass: "iPad", productType: nil, osVersion: nil,
                     endpointHost: "localhost", paired: true, developerMode: true, wifiEnabled: true,
                     timeZoneID: zone, cellular: cellular, ddiMounted: nil)
    }

    private var snapshot: WidgetSnapshot {
        WidgetSnapshot(selectedDeviceName: record.deviceName, locationName: record.name, coordinate: record.coordinate,
                       source: record.source, appliedAt: record.appliedAt, exitSummary: "Tokyo, Japan",
                       exitFeaturesEnabled: true, updatedAt: record.appliedAt)
    }

    func testExitLookupParsesLocationAndUsesSamplingClock() async throws {
        let transport = StubHTTPTransport(.http(200, """
        {"ip":"2001:db8::1","city":"Tokyo","region":"Kanto","country":"JP","loc":"35.68,139.76","org":"AS64500"}
        """))
        let sampled = record.appliedAt
        let proxy = try XCTUnwrap(ExitProxyAddress("[2001:db8::2]:8080"))
        let info = try await ExitIPService(transport: transport, now: { sampled }).lookup(proxy: proxy)
        XCTAssertEqual(info, ExitInfo(ip: "2001:db8::1", city: "Tokyo", region: "Kanto", country: "JP",
                                      coordinate: record.coordinate, org: "AS64500", sampledAt: sampled))
        let calls = await transport.calls
        XCTAssertEqual(calls.map { $0.request.url?.absoluteString }, ["https://ipinfo.io/json"])
        XCTAssertEqual(calls.map(\.proxy), [proxy])
    }

    func testExitLookupRejectsHTTPAndInvalidPayloads() async throws {
        let bodies = [#"{"ip":"192.0.2.1"}"#, #"{"ip":"192.0.2.1","loc":"91,0"}"#, #"{"ip":"","loc":"0,0"}"#]
        let failures: [(Int, String, ExitIPError)] = [(429, "quota", .http(429, "quota"))] + bodies.map { (200, $0, .badResponse($0)) }
        for (status, body, expected) in failures {
            do {
                _ = try await ExitIPService(transport: StubHTTPTransport(.http(status, body))).lookup()
                XCTFail("应拒绝 \(body)")
            } catch let error as ExitIPError { XCTAssertEqual(error, expected) }
        }
    }

    func testCurrentIPFallsBackThroughTheSameProxy() async throws {
        let proxy = try XCTUnwrap(ExitProxyAddress("localhost:8123"))
        for first in [StubHTTPTransport.Reply.failure(.timedOut), .http(503, ""), .http(200, " \n"), .http(200, String(repeating: "x", count: 46))] {
            let transport = StubHTTPTransport(first, .http(200, "2001:db8::5\n"))
            let ip = try await ExitIPService(transport: transport).currentIP(proxy: proxy)
            XCTAssertEqual(ip, "2001:db8::5")
            let calls = await transport.calls
            XCTAssertEqual(calls.map { $0.request.url?.absoluteString }, ["https://api.ipify.org", "https://ipinfo.io/ip"])
            XCTAssertEqual(calls.map(\.proxy), [proxy, proxy])
        }
        let failed = StubHTTPTransport(.failure(.cannotConnectToHost), .failure(.cannotConnectToHost))
        do {
            _ = try await ExitIPService(transport: failed).currentIP(proxy: proxy)
            XCTFail("代理不可达")
        } catch ExitIPError.proxy(let address, _) { XCTAssertEqual(address, proxy.display) }
        let calls = await failed.calls
        XCTAssertEqual(calls.map(\.proxy), [proxy, proxy])
    }

    func testCurrentIPStopsAfterSuccessfulDirectProbe() async throws {
        let transport = StubHTTPTransport(.http(200, "192.0.2.1\r\n"))
        let ip = try await ExitIPService(transport: transport).currentIP()
        XCTAssertEqual(ip, "192.0.2.1")
        let calls = await transport.calls
        XCTAssertEqual(calls.map { $0.request.url?.absoluteString }, ["https://api.ipify.org"])
        XCTAssertEqual(calls.map(\.proxy), [nil])
    }

    func testCancelledIPProbeSkipsTheFallback() async throws {
        let transport = StubHTTPTransport(.failure(.cancelled))
        do {
            _ = try await ExitIPService(transport: transport).currentIP()
            XCTFail("请求已取消")
        } catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testPhotonUsesLongitudeFirstAndDropsInvalidFeatures() async throws {
        let transport = StubHTTPTransport(.http(200, """
        {"features":[{"geometry":{"coordinates":[139.76,35.68]},"properties":{"name":"Tokyo","city":"Tokyo","country":"Japan","osm_id":1}},
                     {"geometry":{"coordinates":[0,91]},"properties":{"name":"bad"}}]}
        """))
        let client = OpenStreetMapClient(transport: transport, photonEndpoint: URL(string: "https://test.invalid/photon")!)
        let places = try await client.suggest("Tokyo")
        XCTAssertEqual(places.map(\.coordinate), [record.coordinate])
        XCTAssertEqual(places.map(\.name), ["Tokyo"])
        XCTAssertEqual(places.map(\.detail), ["Japan"])
        let calls = await transport.calls
        XCTAssertEqual(calls.first?.request.url?.path, "/photon")
        XCTAssertEqual(calls.first?.request.value(forHTTPHeaderField: "User-Agent"), "Elsewhere-iOS/1.0 (iOS location tool)")
    }

    func testNominatimSharesPendingAndCachedResults() async throws {
        let transport = StubHTTPTransport(.http(200, """
        [{"name":"洛杉矶;洛杉磯","display_name":"洛杉矶, 美国","lat":"34.05","lon":"-118.24"}]
        """), .http(200, "[]"))
        let client = OpenStreetMapClient(transport: transport, nominatimEndpoint: URL(string: "https://test.invalid/search")!)
        async let first = client.search(" 洛杉矶 ")
        async let second = client.search("洛杉矶")
        let (places, concurrent) = try await (first, second)
        let cached = try await client.search("洛杉矶")
        XCTAssertEqual(places, concurrent)
        XCTAssertEqual(places, cached)
        XCTAssertEqual(places.map(\.name), ["洛杉矶"])
        XCTAssertEqual(places.map(\.detail), ["洛杉矶, 美国"])
        XCTAssertEqual(places.first?.coordinate, WGS84Coordinate(latitude: 34.05, longitude: -118.24))
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
        let firstCall = try XCTUnwrap(calls.first)
        let url = try XCTUnwrap(firstCall.request.url)
        XCTAssertEqual(url.host, "test.invalid")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "format", value: "jsonv2")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "q", value: "洛杉矶")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "limit", value: "3")))
        XCTAssertEqual(firstCall.request.value(forHTTPHeaderField: "User-Agent"), "Elsewhere-iOS/1.0 (iOS location tool)")
        XCTAssertEqual(firstCall.request.value(forHTTPHeaderField: "Accept-Language"),
                       AppLanguage.isChinese ? "zh-CN,zh;q=0.9,en;q=0.8" : "en,zh-CN;q=0.5")
        let otherLimit = try await client.search("洛杉矶", limit: 1)
        XCTAssertTrue(otherLimit.isEmpty)
        let last = await transport.calls.last
        XCTAssertGreaterThanOrEqual(firstCall.at.duration(to: try XCTUnwrap(last).at), .seconds(1))
    }

    func testGracePeriodAndDSTUseTheSuppliedInstant() {
        let target = TimeZone(identifier: "America/Denver")
        let end = record.appliedAt.addingTimeInterval(60)
        XCTAssertEqual(TimeZoneService.evaluate(record: record, device: device(nil), targetTimeZone: target,
                                                 now: end.addingTimeInterval(-0.001)), .withinGracePeriod)
        XCTAssertEqual(TimeZoneService.evaluate(record: record, device: device(nil), targetTimeZone: target, now: end), .matched)
        let summer = Date(timeIntervalSince1970: 1_719_792_000)
        guard case .mismatch("America/Phoenix", "America/Denver", _, false) = TimeZoneService.evaluate(
            record: record, device: device(nil), targetTimeZone: target, now: summer) else { return XCTFail("丹佛夏季比凤凰城快一小时") }
        XCTAssertEqual(TimeZoneService.evaluate(record: record, device: device(nil, zone: nil), targetTimeZone: target, now: end), .unavailable)
    }

    func testMismatchExplainsEachCellularCapabilityAndMarksEstimates() {
        let hints: [(Bool?, String)] = [(false, "打开「自动设定时区」"), (true, "关闭「自动设定时区」"), (nil, "检查设备的时区")]
        for (cellular, expected) in hints {
            let result = TimeZoneService.evaluate(record: record, device: device(cellular), targetTimeZone: nil,
                                                  now: record.appliedAt.addingTimeInterval(60), locale: Locale(identifier: "zh-Hans"))
            guard case .mismatch("America/Phoenix", "Asia/Tokyo", let hint, true) = result else { return XCTFail("应标明离线估算") }
            XCTAssertTrue(hint.contains(expected))
            if cellular == true {
                XCTAssertTrue(hint.contains("运营商"))
                XCTAssertTrue(hint.contains("手动选择"))
            }
        }
        let result = TimeZoneService.evaluate(record: record, device: device(false), targetTimeZone: TimeZone(identifier: "Asia/Tokyo"),
                                              isEstimated: true, now: record.appliedAt.addingTimeInterval(60), locale: Locale(identifier: "en"))
        guard case .mismatch(_, _, let hint, true) = result else { return XCTFail("应保留估算标记") }
        XCTAssertTrue(hint.contains("Turn on Set Automatically"))
    }

    func testOfflineZonesIncludeRemoteAndFractionalOffsets() throws {
        for (lat, lon, name) in [(-43.95, -176.55, "Pacific/Chatham"), (27.72, 85.32, "Asia/Kathmandu"), (-72.01, 2.53, "Antarctica/Troll")] {
            let point = try XCTUnwrap(WGS84Coordinate(latitude: lat, longitude: lon))
            XCTAssertEqual(TimeZoneService.nearestZone(to: point), try XCTUnwrap(TimeZone(identifier: name)))
        }
    }

    @MainActor func testNotificationPermissionPostingAndFollowAction() async {
        let center = StubNotificationCenter()
        let notifier = Notifier(center: center)
        async let first: Void = notifier.requestAuthorizationIfNeeded()
        async let second: Void = notifier.requestAuthorizationIfNeeded()
        _ = await (first, second)
        await notifier.requestAuthorizationIfNeeded()
        notifier.post(title: "出口变了", body: "Tokyo", category: Notifier.exitChangedCategory)
        let state = center.state.withLock { $0 }
        XCTAssertTrue(state.registered)
        XCTAssertEqual(state.prompts, 1)
        XCTAssertEqual(state.post, ["出口变了", "Tokyo", "EXIT_CHANGED"])
        var count = 0
        notifier.onFollow = { count += 1 }
        notifier.handleResponse(category: "other", action: "FOLLOW_EXIT")
        notifier.handleResponse(category: "EXIT_CHANGED", action: UNNotificationDismissActionIdentifier)
        XCTAssertEqual(count, 0)
        notifier.handleResponse(category: "EXIT_CHANGED", action: "FOLLOW_EXIT")
        notifier.handleResponse(category: "EXIT_CHANGED", action: UNNotificationDefaultActionIdentifier)
        XCTAssertEqual(count, 2)
    }

    func testDiskStateSurvivesReopeningAndIndividualUpdates() async throws {
        let directory = try makeTemporaryDirectory().appending(path: "state")
        let store = AppStateStore(storageDirectory: directory, snapshotSuiteName: nil)
        let other = AppStateStore(storageDirectory: directory, snapshotSuiteName: nil)
        let initial = try await store.load()
        XCTAssertEqual(initial, AppStateStore.State())
        let settings = AppSettings(exitFeaturesEnabled: false, watchMode: .auto, applyToAll: true, autoRestore: false,
            channelMode: .builtInTunnel, autoDisconnectTunnel: false, customProxyText: "[::1]:8080",
            hasSeenSplash: true, hasCompletedOnboarding: true)
        let cities = Array(Place.defaults.reversed())
        async let writeSettings: Void = store.saveSettings(settings)
        async let writeCities: Void = other.saveCities(cities)
        _ = try await (writeSettings, writeCities)
        try await store.saveRecords([record.deviceID: record])
        try await other.saveSelectedDeviceID(record.deviceID)
        let saved = try await AppStateStore(storageDirectory: directory, snapshotSuiteName: nil).load()
        XCTAssertEqual(saved, AppStateStore.State(settings: settings, cities: cities, records: [record.deviceID: record],
                                                  selectedDeviceID: record.deviceID))
        try await store.saveSelectedDeviceID(nil)
        try await other.saveCities([])
        let cleared = try await store.load()
        XCTAssertEqual(cleared, AppStateStore.State(settings: settings, cities: [], records: saved.records))
    }

    func testWidgetSuiteContainsOnlyDisplayFields() async throws {
        let suite = "ElsewhereTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStateStore(storageDirectory: try makeTemporaryDirectory(), snapshotSuiteName: suite)
        try await store.saveSettings(AppSettings(customProxyText: "private.example:1234"))
        try await store.writeWidgetSnapshot(snapshot)
        XCTAssertEqual(AppStateStore.readWidgetSnapshot(suiteName: suite), snapshot)
        let domain = try XCTUnwrap(defaults.persistentDomain(forName: suite))
        XCTAssertEqual(Set(domain.keys), ["widgetSnapshot"])
        let data = try XCTUnwrap(domain["widgetSnapshot"] as? Data)
        let fields = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: NSObject])
        XCTAssertEqual(Set(fields.keys), ["selectedDeviceName", "locationName", "coordinate", "source", "appliedAt", "exitSummary", "exitFeaturesEnabled", "updatedAt"])
        let point = try XCTUnwrap(fields["coordinate"] as? [String: NSNumber])
        XCTAssertEqual(Set(point.keys), ["latitude", "longitude"])
    }

    func testMemoryModeIsIsolatedEvenWithASnapshotSuite() async throws {
        let disk = URL.applicationSupportDirectory.appending(path: "ElsewhereMobile/state.json")
        let before = try? Data(contentsOf: disk)
        let suite = "ElsewhereTests.\(UUID().uuidString)"
        let memory = AppStateStore(storageDirectory: nil, snapshotSuiteName: suite)
        try await memory.saveSettings(AppSettings(hasSeenSplash: true))
        try await memory.saveCities([])
        try await memory.saveRecords([record.deviceID: record])
        try await memory.saveSelectedDeviceID(record.deviceID)
        try await memory.writeWidgetSnapshot(snapshot)
        let state = try await memory.load()
        XCTAssertEqual(state, AppStateStore.State(settings: AppSettings(hasSeenSplash: true), cities: [],
                                                 records: [record.deviceID: record], selectedDeviceID: record.deviceID))
        let stored = await memory.widgetSnapshot
        XCTAssertEqual(stored, snapshot)
        let fresh = try await AppStateStore(storageDirectory: nil, snapshotSuiteName: nil).load()
        XCTAssertEqual(fresh, AppStateStore.State())
        XCTAssertNil(UserDefaults(suiteName: suite)?.persistentDomain(forName: suite))
        XCTAssertEqual(try? Data(contentsOf: disk), before)
    }
}
