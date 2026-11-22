import os
import XCTest
@testable import ElsewhereMobile

final class RustBridgeAndDemoEngineTests: XCTestCase {
    func testCoreABIAndTransportMatchDeviceVersions() throws {
        XCTAssertEqual(RustCoreBridge.abiVersion, 3)
        XCTAssertEqual(RustCoreBridge.lockdownPort, 62078)
        for text in ["0.0", "16.7.10", "17.0", "17.3.9", "17.4", "17.10", "18.3", "4294967296.0"] {
            let version = try XCTUnwrap(OSVersion(text), text)
            XCTAssertEqual(RustCoreBridge.targetTransport(major: version.major, minor: version.minor), version.preferredTransport, text)
        }
    }

    func testCoreCoordinateValidation() {
        for (latitude, longitude, valid) in coordinateValidityCases {
            XCTAssertEqual(RustCoreBridge.isCoordinateValid(latitude: latitude, longitude: longitude), valid, "\(latitude), \(longitude)")
        }
    }

    @MainActor
    func testDemoEnvironmentProbesAPairedReadyDevice() async throws {
        let environment = AppEnvironment.demo()
        XCTAssertTrue(environment.isDemo)
        XCTAssertEqual(environment.abiVersion, 3)
        let device = try await environment.engine.probe(deviceID: environment.demoDeviceID, endpointHost: "10.7.0.1")
        XCTAssertEqual(device.id, environment.demoDeviceID)
        XCTAssertEqual(device.name, "iPhone")
        XCTAssertEqual(device.osVersion, OSVersion("18.3"))
        XCTAssertEqual(device.endpointHost, "10.7.0.1")
        XCTAssertTrue(device.isReady)
    }

    func testDemoMountsOnceAndReportsOrderedLocationChanges() async throws {
        let engine = DemoLocationEngine()
        let phone = DemoLocationEngine.defaultDevice
        let stages = OSAllocatedUnfairLock(initialState: [EngineOperationStage]())
        let onStage: @Sendable (EngineOperationStage) -> Void = { stage in stages.withLock { $0.append(stage) } }
        let initial = await engine.simulatedCoordinate(for: phone.id)
        XCTAssertNil(initial)
        try await engine.prepareDDI(for: phone.id, onStage: onStage)
        let mounted = try await engine.probe(deviceID: phone.id, endpointHost: phone.endpointHost)
        XCTAssertEqual(mounted.ddiMounted, true)
        try await engine.prepareDDI(for: phone.id, onStage: onStage)
        for latitude in [22.5431, 39.9042] {
            let coordinate = try XCTUnwrap(WGS84Coordinate(latitude: latitude, longitude: 114.0579))
            try await engine.setLocation(coordinate, on: phone.id, onStage: onStage)
            let applied = await engine.simulatedCoordinate(for: phone.id)
            XCTAssertEqual(applied, coordinate)
        }
        try await engine.clearLocation(on: phone.id, onStage: onStage)
        try await engine.clearLocation(on: phone.id, onStage: onStage)
        let cleared = await engine.simulatedCoordinate(for: phone.id)
        XCTAssertNil(cleared)
        XCTAssertEqual(stages.withLock { $0 }, [.downloadingDDI, .verifyingDDI, .signingDDI, .uploadingDDI, .mountingDDI,
                                                .applyingLocation, .applyingLocation, .clearingLocation, .clearingLocation])
    }

    func testInjectedDevicesMountAndStoreCoordinatesIndependently() async throws {
        let phone = DemoLocationEngine.defaultDevice, pad = tablet()
        let engine = DemoLocationEngine(devices: [phone, pad])
        let found = try await engine.probe(deviceID: pad.id, endpointHost: pad.endpointHost)
        XCTAssertEqual(found, pad)
        try await engine.clearLocation(on: pad.id) { _ in }
        let berlin = try XCTUnwrap(WGS84Coordinate(latitude: 52.52, longitude: 13.405))
        let paris = try XCTUnwrap(WGS84Coordinate(latitude: 48.8566, longitude: 2.3522))
        try await engine.setLocation(berlin, on: phone.id) { _ in }
        let mounted = try await engine.probe(deviceID: phone.id, endpointHost: phone.endpointHost)
        let unmounted = try await engine.probe(deviceID: pad.id, endpointHost: pad.endpointHost)
        XCTAssertEqual(mounted.ddiMounted, true)
        XCTAssertEqual(unmounted.ddiMounted, false)
        try await engine.setLocation(paris, on: pad.id) { _ in }
        try await engine.clearLocation(on: phone.id) { _ in }
        let phoneCoordinate = await engine.simulatedCoordinate(for: phone.id)
        let padCoordinate = await engine.simulatedCoordinate(for: pad.id)
        XCTAssertNil(phoneCoordinate)
        XCTAssertEqual(padCoordinate, paris)
    }

    func testProbeRejectsMissingDevicesAndWrongEndpoint() async {
        let phone = DemoLocationEngine.defaultDevice
        do {
            _ = try await DemoLocationEngine(devices: []).probe(deviceID: phone.id, endpointHost: phone.endpointHost)
            XCTFail("空设备列表不应探测成功")
        } catch {
            XCTAssertEqual(error.code, .not_found)
            XCTAssertEqual(error.stage, EngineOperationStage.connecting.rawValue)
            XCTAssertNil(error.deviceAlias)
        }
        do {
            _ = try await DemoLocationEngine().probe(deviceID: phone.id, endpointHost: "192.0.2.8")
            XCTFail("端点不匹配不应探测成功")
        } catch {
            XCTAssertEqual(error.code, .tunnel_unavailable)
            XCTAssertEqual(error.deviceAlias, phone.name)
            XCTAssertEqual(error.errorDescription, error.message)
        }
    }

    func testUnpairedAndDeveloperModeOffDevicesRejectOperations() async throws {
        let unpaired = tablet(paired: false)
        do {
            try await DemoLocationEngine(devices: [unpaired]).prepareDDI(for: unpaired.id) { _ in XCTFail("配对失效时不应开始挂载") }
            XCTFail("配对失效时不应准备成功")
        } catch {
            XCTAssertEqual(error.code, .not_paired)
            XCTAssertEqual(error.stage, EngineOperationStage.mountingDDI.rawValue)
        }
        let disabled = tablet(developerMode: false)
        let engine = DemoLocationEngine(devices: [disabled])
        let found = try await engine.probe(deviceID: disabled.id, endpointHost: disabled.endpointHost)
        XCTAssertEqual(found.developerMode, false)
        let coordinate = try XCTUnwrap(WGS84Coordinate(latitude: 0, longitude: 0))
        do {
            try await engine.setLocation(coordinate, on: disabled.id) { _ in XCTFail("开发者模式关闭时不应下发定位") }
            XCTFail("开发者模式关闭时不应设置成功")
        } catch {
            XCTAssertEqual(error.code, .no_service)
            XCTAssertEqual(error.stage, EngineOperationStage.applyingLocation.rawValue)
        }
        let current = await engine.simulatedCoordinate(for: disabled.id)
        XCTAssertNil(current)
    }

    private func tablet(paired: Bool = true, developerMode: Bool = true) -> TargetDevice {
        TargetDevice(id: DeviceID(rawValue: "demo-ipad")!, name: "iPad", deviceClass: "iPad", productType: nil,
                     osVersion: OSVersion("17.4"), endpointHost: "192.0.2.2", paired: paired, developerMode: developerMode,
                     wifiEnabled: true, timeZoneID: "Asia/Shanghai", cellular: false, ddiMounted: false)
    }
}
