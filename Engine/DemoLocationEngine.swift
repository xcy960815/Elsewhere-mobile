import Foundation

actor DemoLocationEngine: LocationEngineProtocol {
    static let defaultDevice = TargetDevice(id: DeviceID(rawValue: "demo-iphone")!, name: "iPhone", deviceClass: "iPhone",
                                            productType: nil, osVersion: OSVersion("18.3"), endpointHost: "10.7.0.1",
                                            paired: true, developerMode: true, wifiEnabled: true, timeZoneID: nil,
                                            cellular: true, ddiMounted: false)

    private var devices: [DeviceID: TargetDevice]
    private var coordinates: [DeviceID: WGS84Coordinate] = [:]
    nonisolated var abiVersion: UInt32 { RustCoreBridge.abiVersion }

    init(devices: [TargetDevice] = [DemoLocationEngine.defaultDevice]) {
        self.devices = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { _, device in device })
    }

    func probe(deviceID: DeviceID, endpointHost: String) async throws(EngineError) -> TargetDevice {
        let device = try pairedDevice(deviceID, at: .connecting)
        guard device.endpointHost == endpointHost else {
            throw EngineError(code: .tunnel_unavailable, stage: EngineOperationStage.connecting.rawValue, deviceAlias: device.name,
                              message: String(localized: "无法通过此地址连接演示设备"), rawDetail: endpointHost)
        }
        return device
    }

    func prepareDDI(for deviceID: DeviceID, onStage: @Sendable (EngineOperationStage) -> Void) async throws(EngineError) {
        mountDDI(on: try readyDevice(deviceID, at: .mountingDDI), onStage: onStage)
    }

    func setLocation(_ coordinate: WGS84Coordinate, on deviceID: DeviceID,
                     onStage: @Sendable (EngineOperationStage) -> Void) async throws(EngineError) {
        mountDDI(on: try readyDevice(deviceID, at: .applyingLocation), onStage: onStage)
        onStage(.applyingLocation)
        coordinates[deviceID] = coordinate
    }

    func clearLocation(on deviceID: DeviceID, onStage: @Sendable (EngineOperationStage) -> Void) async throws(EngineError) {
        _ = try readyDevice(deviceID, at: .clearingLocation)
        onStage(.clearingLocation)
        coordinates[deviceID] = nil
    }

    func simulatedCoordinate(for deviceID: DeviceID) -> WGS84Coordinate? { coordinates[deviceID] }

    private func pairedDevice(_ id: DeviceID, at stage: EngineOperationStage) throws(EngineError) -> TargetDevice {
        guard let device = devices[id] else {
            throw EngineError(code: .not_found, stage: stage.rawValue, deviceAlias: nil,
                              message: String(localized: "找不到演示设备"), rawDetail: nil)
        }
        guard device.paired else {
            throw EngineError(code: .not_paired, stage: stage.rawValue, deviceAlias: device.name,
                              message: String(localized: "设备配对已失效"), rawDetail: nil)
        }
        return device
    }

    private func readyDevice(_ id: DeviceID, at stage: EngineOperationStage) throws(EngineError) -> TargetDevice {
        let device = try pairedDevice(id, at: stage)
        guard device.developerMode != false else {
            throw EngineError(code: .no_service, stage: stage.rawValue, deviceAlias: device.name,
                              message: String(localized: "请开启开发者模式"), rawDetail: nil)
        }
        return device
    }

    private func mountDDI(on device: TargetDevice, onStage: @Sendable (EngineOperationStage) -> Void) {
        guard device.ddiMounted != true else { return }
        for stage: EngineOperationStage in [.downloadingDDI, .verifyingDDI, .signingDDI, .uploadingDDI, .mountingDDI] {
            onStage(stage)
        }
        devices[device.id] = TargetDevice(id: device.id, name: device.name, deviceClass: device.deviceClass,
                                          productType: device.productType, osVersion: device.osVersion, endpointHost: device.endpointHost,
                                          paired: device.paired, developerMode: device.developerMode, wifiEnabled: device.wifiEnabled,
                                          timeZoneID: device.timeZoneID, cellular: device.cellular, ddiMounted: true)
    }
}
