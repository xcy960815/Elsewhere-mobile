import ElsewhereCore
import Foundation
import os

enum PairingInspectOutcome: Equatable, Sendable, Decodable {
    case lockdown(PairingInspection), remotePairing

    private enum CodingKeys: String, CodingKey {
        case format, udid, hostId, systemBuid, wifiMacAddress, hasEscrowBag
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .format) {
        case "remote_pairing": self = .remotePairing
        case "lockdown":
            self = .lockdown(try PairingInspection(udid: values.decodeIfPresent(DeviceID.self, forKey: .udid),
                                                  hostID: values.decode(String.self, forKey: .hostId),
                                                  systemBUID: values.decode(String.self, forKey: .systemBuid),
                                                  wifiMACAddress: values.decodeIfPresent(String.self, forKey: .wifiMacAddress),
                                                  hasEscrowBag: values.decode(Bool.self, forKey: .hasEscrowBag)))
        default:
            throw DecodingError.dataCorruptedError(forKey: .format, in: values, debugDescription: "配对格式无效")
        }
    }
}

enum RustCoreBridge: Sendable {
    static var abiVersion: UInt32 { ew_abi_version() }
    static var lockdownPort: UInt16 { ew_lockdown_port() }

    static func targetTransport(major: Int, minor: Int) -> TargetTransport {
        switch ew_target_transport(UInt32(clamping: major), UInt32(clamping: minor)) {
        case EwTransportRemotePairing: .remotePairing
        case EwTransportCoreDeviceProxy: .coreDeviceProxy
        default: .unsupported
        }
    }

    static func isCoordinateValid(latitude: Double, longitude: Double) -> Bool {
        ew_coordinate_is_valid(latitude, longitude)
    }

    static func inspectPairing(_ data: Data) throws(EngineError) -> PairingInspectOutcome {
        try decode(PairingInspectOutcome.self, from: reply(to: data, at: EwStageConnecting, using: ew_pairing_inspect), at: .connecting)
    }

    static func verifyDDI(at directory: URL) throws(EngineError) -> String {
        struct Verification: Decodable { let valid: Bool, digestHex: String }
        let bytes = try reply(to: Data(directory.path.utf8), at: EwStageVerifyingDdi, using: ew_ddi_verify)
        let result = try decode(Verification.self, from: bytes, at: .verifyingDDI)
        guard result.valid, result.digestHex.utf8.count == 96, result.digestHex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw EngineError(code: .ddi_missing, stage: EngineOperationStage.verifyingDDI.rawValue,
                              message: String(localized: "开发者组件的 SHA-384 摘要无效"))
        }
        return result.digestHex
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, at stage: EngineOperationStage,
                                     deviceAlias: String? = nil) throws(EngineError) -> T {
        guard let reply = try? JSONDecoder().decode(type, from: data) else {
            throw EngineError(code: .failed, stage: stage.rawValue, deviceAlias: deviceAlias, message: String(localized: "无法解析引擎返回的数据"))
        }
        return reply
    }

    private static func reply(to input: Data, at stage: EwStage,
                              using call: (UnsafePointer<UInt8>?, Int, EwSyncCallback?, UnsafeMutableRawPointer?) -> Void) throws(EngineError) -> Data {
        typealias Reply = (code: EwErrorCode, payload: Data)
        var reply: Reply = (EwErrorOk, Data())
        withUnsafeMutablePointer(to: &reply) { context in
            input.withUnsafeBytes { bytes in
                call(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, { code, start, count, context in
                    context?.assumingMemoryBound(to: Reply.self).pointee = (code, Data(UnsafeBufferPointer(start: start, count: count)))
                }, context)
            }
        }
        guard reply.code == EwErrorOk else { throw error(reply.code, at: stage, detail: reply.payload) }
        return reply.payload
    }

    fileprivate static func error(_ code: EwErrorCode, at stage: EwStage, deviceAlias: String? = nil,
                                  detail: Data? = nil, outcomeUnknown: Bool = false) -> EngineError {
        let reason: (EngineErrorCode, String) = switch code {
        case EwErrorLocked: (.locked, String(localized: "请解锁目标设备"))
        case EwErrorNotPaired: (.not_paired, String(localized: "目标设备未接受此配对记录"))
        case EwErrorNotFound: (.not_found, String(localized: "找不到目标设备或请求的项目"))
        case EwErrorDdiMissing: (.ddi_missing, String(localized: "开发者组件缺失或校验失败"))
        case EwErrorDdiMount: (.ddi_mount, String(localized: "无法挂载开发者组件"))
        case EwErrorNoService: (.no_service, String(localized: "开发者服务不可用，请检查开发者模式"))
        case EwErrorTunnelUnavailable: (.tunnel_unavailable, String(localized: "无法连接目标设备，请检查通道与设备地址"))
        case EwErrorCancelled: (.cancelled, String(localized: "操作已取消"))
        case EwErrorInvalidInput: (.invalid_input, String(localized: "输入数据无效"))
        default: (.failed, String(localized: "设备协议请求失败"))
        }
        let message = outcomeUnknown ? String(localized: "\(reason.1)。设备端的执行结果待确认") : reason.1
        return EngineError(code: reason.0, stage: stage.operationStage.rawValue, deviceAlias: deviceAlias, message: message,
                           rawDetail: detail.flatMap { String(data: $0, encoding: .utf8) }, outcomeUnknown: outcomeUnknown)
    }
}

private extension EwStage {
    var operationStage: EngineOperationStage {
        switch self {
        case EwStageDownloadingDdi: .downloadingDDI
        case EwStageVerifyingDdi: .verifyingDDI
        case EwStageSigningDdi: .signingDDI
        case EwStageUploadingDdi: .uploadingDDI
        case EwStageMountingDdi: .mountingDDI
        case EwStageApplyingLocation: .applyingLocation
        case EwStageClearingLocation: .clearingLocation
        default: .connecting
        }
    }
}

struct JobRequest: Sendable {
    var command: EwCommand
    let endpointHost: String
    let ipv6ScopeID: UInt32
    let pairing: Data
    let expectedUDID: DeviceID?
    var ddiDirectory: URL?
    let coordinate: WGS84Coordinate?
    let timeoutMs: UInt32

    fileprivate func submit(to handle: OpaquePointer, id: UInt64, callback: EwJobCallback, context: UnsafeMutableRawPointer) -> Bool {
        Array(endpointHost.utf8).withUnsafeBufferPointer { host in
            Array((expectedUDID?.rawValue ?? "").utf8).withUnsafeBufferPointer { udid in
                Array((ddiDirectory?.path ?? "").utf8).withUnsafeBufferPointer { directory in
                    pairing.withUnsafeBytes { bytes in
                        var request = EwRequest(command: command, endpoint_host_ptr: host.baseAddress, endpoint_host_len: host.count,
                                                ipv6_scope_id: ipv6ScopeID, pairing_ptr: bytes.bindMemory(to: UInt8.self).baseAddress,
                                                pairing_len: bytes.count, expected_udid_ptr: udid.baseAddress, expected_udid_len: udid.count,
                                                ddi_dir_ptr: directory.baseAddress, ddi_dir_len: directory.count, latitude: coordinate?.latitude ?? .nan,
                                                longitude: coordinate?.longitude ?? .nan, timeout_ms: timeoutMs)
                        return ew_submit(handle, id, &request, callback, context)
                    }
                }
            }
        }
    }
}

final class RustEngineHandle: @unchecked Sendable {
    private final class Job: Sendable {
        let owner: RustEngineHandle
        let deviceAlias: String?
        let onStage: @Sendable (EngineOperationStage) -> Void
        let continuation: CheckedContinuation<Result<Data, EngineError>, Never>

        init(owner: RustEngineHandle, deviceAlias: String?, onStage: @escaping @Sendable (EngineOperationStage) -> Void,
             continuation: CheckedContinuation<Result<Data, EngineError>, Never>) {
            self.owner = owner
            self.deviceAlias = deviceAlias
            self.onStage = onStage
            self.continuation = continuation
        }
    }

    private let handle: OpaquePointer
    private let jobID = OSAllocatedUnfairLock(initialState: UInt64(0))

    init() throws(EngineError) {
        guard let handle = ew_engine_create() else {
            throw EngineError(code: .failed, stage: EngineOperationStage.connecting.rawValue, message: String(localized: "无法启动定位引擎"))
        }
        self.handle = handle
    }

    deinit { ew_engine_destroy(handle) }

    func submit(_ request: JobRequest, deviceAlias: String?,
                onStage: @escaping @Sendable (EngineOperationStage) -> Void) async throws(EngineError) -> Data {
        guard !Task.isCancelled else { throw RustCoreBridge.error(EwErrorCancelled, at: EwStageConnecting, deviceAlias: deviceAlias) }
        let id = jobID.withLock {
            $0 += 1
            return $0
        }
        // destroy 会等待回调线程退出。末次引用须由恢复后的 Swift 任务持有。
        defer { withExtendedLifetime(self) {} }
        let result: Result<Data, EngineError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let job = Unmanaged.passRetained(Job(owner: self, deviceAlias: deviceAlias, onStage: onStage, continuation: continuation))
                if !request.submit(to: handle, id: id, callback: Self.receive, context: job.toOpaque()) {
                    job.release()
                    continuation.resume(returning: .failure(RustCoreBridge.error(EwErrorFailed, at: EwStageConnecting, deviceAlias: deviceAlias)))
                } else if Task.isCancelled {
                    // 取消处理器可能早于 Rust 登记任务。
                    ew_cancel(handle, id)
                }
            }
        } onCancel: {
            ew_cancel(self.handle, id)
        }
        return try result.get()
    }

    private static let receive: EwJobCallback = { event, context in
        guard let event = event?.pointee, let context else { return }
        let job = Unmanaged<Job>.fromOpaque(context)
        if event.kind == EwEventStage {
            job.takeUnretainedValue().onStage(event.stage.operationStage)
            return
        }
        let payload = Data(UnsafeBufferPointer(start: event.payload_ptr, count: event.payload_len))
        let result: Result<Data, EngineError> = event.kind == EwEventSuccess ? .success(payload) :
            .failure(RustCoreBridge.error(event.error_code, at: event.stage, deviceAlias: job.takeUnretainedValue().deviceAlias,
                                          detail: payload, outcomeUnknown: event.outcome_unknown))
        let continuation = job.takeRetainedValue().continuation
        continuation.resume(returning: result)
    }
}
