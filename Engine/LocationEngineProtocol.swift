import Foundation

enum EngineErrorCode: String, Codable, Hashable, Sendable {
    case locked, not_paired, not_found, ddi_missing, ddi_mount, no_service, tunnel_unavailable, cancelled, invalid_input, failed
}

struct EngineError: LocalizedError, Equatable, Sendable {
    let code: EngineErrorCode
    let stage: String
    let deviceAlias: String?
    let message: String
    let rawDetail: String?
    let outcomeUnknown: Bool

    init(code: EngineErrorCode, stage: String, deviceAlias: String? = nil, message: String, rawDetail: String? = nil,
         outcomeUnknown: Bool = false) {
        self.code = code
        self.stage = stage
        self.deviceAlias = deviceAlias
        self.message = message
        self.rawDetail = rawDetail
        self.outcomeUnknown = outcomeUnknown
    }

    var errorDescription: String? { message }
}

enum EngineOperationStage: String, Equatable, Sendable {
    case connecting, downloadingDDI, verifyingDDI, signingDDI, uploadingDDI, mountingDDI, applyingLocation, clearingLocation
}

protocol LocationEngineProtocol: Sendable {
    var abiVersion: UInt32 { get }
    func probe(deviceID: DeviceID, endpointHost: String) async throws(EngineError) -> TargetDevice
    func prepareDDI(for deviceID: DeviceID, onStage: @escaping @Sendable (EngineOperationStage) -> Void) async throws(EngineError)
    func setLocation(_ coordinate: WGS84Coordinate, on deviceID: DeviceID,
                     onStage: @escaping @Sendable (EngineOperationStage) -> Void) async throws(EngineError)
    func clearLocation(on deviceID: DeviceID, onStage: @escaping @Sendable (EngineOperationStage) -> Void) async throws(EngineError)
}
