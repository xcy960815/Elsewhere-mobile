import ElsewhereCore
import Foundation

final class RustLocationEngine: LocationEngineProtocol {
    private let handle: RustEngineHandle
    private let pairingStore: PairingStore
    private let ddiRepository: DDIRepository
    private let timeoutMs: UInt32
    var abiVersion: UInt32 { RustCoreBridge.abiVersion }

    init(handle: RustEngineHandle, pairingStore: PairingStore, ddiRepository: DDIRepository, timeoutMs: UInt32 = 0) {
        self.handle = handle
        self.pairingStore = pairingStore
        self.ddiRepository = ddiRepository
        self.timeoutMs = timeoutMs
    }

    static func makePairingInspector() -> @Sendable (Data) async throws -> PairingInspection {
        { data in
            switch try RustCoreBridge.inspectPairing(data) {
            case .lockdown(let inspection): return inspection
            case .remotePairing: throw PairingStoreError.remotePairingUnsupported
            }
        }
    }

    static func makeDDIVerifier() -> DDIVerifier { RustCoreBridge.verifyDDI(at:) }

    func probe(deviceID: DeviceID, endpointHost: String) async throws(EngineError) -> TargetDevice {
        struct Probe: Decodable {
            let udid: DeviceID
            let name, deviceClass, productType, osVersion, timeZone: String?
            let paired: Bool
            let developerMode, wifi, cellular, ddiMounted: Bool?
        }
        let (record, request) = try await pairedRequest(EwCommandProbe, for: deviceID, endpointHost: endpointHost)
        let data = try await handle.submit(request, deviceAlias: record.deviceName) { _ in }
        let reply = try RustCoreBridge.decode(Probe.self, from: data, at: .connecting, deviceAlias: record.deviceName)
        let name = reply.name ?? record.deviceName ?? reply.udid.rawValue
        if record.udid == nil || (reply.name != nil && reply.name != record.deviceName) {
            do {
                _ = try await pairingStore.bindIdentity(recordID: record.id, udid: reply.udid, deviceName: name)
            } catch {
                throw pairingError(error, deviceAlias: record.deviceName)
            }
        }
        return TargetDevice(id: reply.udid, name: name, deviceClass: reply.deviceClass ?? String(localized: "未知"),
                            productType: reply.productType, osVersion: reply.osVersion.flatMap(OSVersion.init), endpointHost: endpointHost,
                            paired: reply.paired, developerMode: reply.developerMode, wifiEnabled: reply.wifi, timeZoneID: reply.timeZone,
                            cellular: reply.cellular, ddiMounted: reply.ddiMounted)
    }

    func prepareDDI(for deviceID: DeviceID, onStage: @escaping @Sendable (EngineOperationStage) -> Void) async throws(EngineError) {
        let (record, request) = try await pairedRequest(EwCommandMountDdi, for: deviceID)
        if try await isDDIMounted(request, deviceAlias: record.deviceName, onStage: onStage) { return }
        try await submitWithPreparedDDI(request, deviceAlias: record.deviceName, onStage: onStage)
    }

    func setLocation(_ coordinate: WGS84Coordinate, on deviceID: DeviceID,
                     onStage: @escaping @Sendable (EngineOperationStage) -> Void) async throws(EngineError) {
        let (record, request) = try await pairedRequest(EwCommandSetLocation, for: deviceID, coordinate: coordinate)
        do {
            let applied: Bool? = try await ddiRepository.withCachedDDI { directory in
                var job = request
                job.ddiDirectory = directory
                _ = try await self.handle.submit(job, deviceAlias: record.deviceName, onStage: onStage)
                return true
            }
            if applied == true { return }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError(code: .cancelled, stage: EngineOperationStage.verifyingDDI.rawValue, deviceAlias: record.deviceName,
                              message: error.localizedDescription)
        }
        if try await isDDIMounted(request, deviceAlias: record.deviceName, onStage: onStage) {
            do throws(EngineError) {
                _ = try await handle.submit(request, deviceAlias: record.deviceName, onStage: onStage)
                return
            } catch {
                guard error.code == .ddi_missing, !error.outcomeUnknown else { throw error }
            }
        }
        try await submitWithPreparedDDI(request, deviceAlias: record.deviceName, onStage: onStage)
    }

    func clearLocation(on deviceID: DeviceID, onStage: @escaping @Sendable (EngineOperationStage) -> Void) async throws(EngineError) {
        let (record, request) = try await pairedRequest(EwCommandClearLocation, for: deviceID)
        _ = try await handle.submit(request, deviceAlias: record.deviceName, onStage: onStage)
    }

    private func pairedRequest(_ command: EwCommand, for deviceID: DeviceID, endpointHost: String? = nil,
                               coordinate: WGS84Coordinate? = nil) async throws(EngineError) -> (StoredPairingRecord, JobRequest) {
        do throws(PairingStoreError) {
            let records = try await pairingStore.records()
            let record: StoredPairingRecord
            if let bound = records.first(where: { $0.udid == deviceID }) {
                record = bound
            } else {
                guard let endpointHost else { throw .recordNotFound }
                let candidates = records.filter { $0.endpointHost == endpointHost }
                guard candidates.count <= 1 else { throw .invalidPairing(String(localized: "此地址对应多份配对记录，请按设备标识选择")) }
                guard let candidate = candidates.first, candidate.udid == nil else { throw .recordNotFound }
                record = candidate
            }
            let bytes = try await pairingStore.pairingBytes(for: record.id)
            return (record, JobRequest(command: command, endpointHost: endpointHost ?? record.endpointHost, ipv6ScopeID: 0,
                                       pairing: bytes, expectedUDID: record.udid, coordinate: coordinate, timeoutMs: timeoutMs))
        } catch {
            throw pairingError(error)
        }
    }

    private func pairingError(_ error: PairingStoreError, deviceAlias: String? = nil) -> EngineError {
        let code: EngineErrorCode = switch error {
        case .recordNotFound, .invalidPairing, .remotePairingUnsupported: .not_paired
        case .fileTooLarge, .unreadableFile: .invalid_input
        case .cryptoFailure, .storageFailure: .failed
        }
        return EngineError(code: code, stage: EngineOperationStage.connecting.rawValue, deviceAlias: deviceAlias, message: error.localizedDescription)
    }

    private func isDDIMounted(_ request: JobRequest, deviceAlias: String?,
                              onStage: @escaping @Sendable (EngineOperationStage) -> Void) async throws(EngineError) -> Bool {
        struct Status: Decodable { let mounted: Bool }
        var check = request
        check.command = EwCommandCheckDdi
        let data = try await handle.submit(check, deviceAlias: deviceAlias, onStage: onStage)
        return try RustCoreBridge.decode(Status.self, from: data, at: .connecting, deviceAlias: deviceAlias).mounted
    }

    private func submitWithPreparedDDI(_ request: JobRequest, deviceAlias: String?,
                                       onStage: @escaping @Sendable (EngineOperationStage) -> Void) async throws(EngineError) {
        do {
            try await ddiRepository.withPreparedDDI(onStage: { value in
                if let stage = EngineOperationStage(rawValue: value) { onStage(stage) }
            }) { directory in
                var job = request
                job.ddiDirectory = directory
                _ = try await self.handle.submit(job, deviceAlias: deviceAlias, onStage: onStage)
            }
        } catch let error as EngineError {
            throw error
        } catch is CancellationError, DDIRepositoryError.cancelled {
            throw EngineError(code: .cancelled, stage: EngineOperationStage.verifyingDDI.rawValue, deviceAlias: deviceAlias,
                              message: String(localized: "操作已取消"))
        } catch DDIRepositoryError.verificationFailed {
            throw EngineError(code: .ddi_missing, stage: EngineOperationStage.verifyingDDI.rawValue, deviceAlias: deviceAlias,
                              message: String(localized: "开发者组件校验失败"))
        } catch DDIRepositoryError.httpStatus(let status) {
            throw EngineError(code: .ddi_missing, stage: EngineOperationStage.downloadingDDI.rawValue, deviceAlias: deviceAlias,
                              message: DDIRepositoryError.httpStatus(status).localizedDescription)
        } catch {
            throw EngineError(code: .ddi_missing, stage: EngineOperationStage.downloadingDDI.rawValue, deviceAlias: deviceAlias,
                              message: String(localized: "无法下载或保存开发者组件"))
        }
    }
}
