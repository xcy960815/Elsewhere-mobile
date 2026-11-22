import Foundation

enum DDIStage: String, Equatable, Sendable {
    case downloading, verifying, signing, uploading, mounting
}

enum DeviceOperationKind: String, Equatable, Sendable {
    case setLocation, clearLocation, restoreLocation
}

enum DeviceConnectionState: Equatable, Sendable {
    case unpaired
    case probing
    case channelUnavailable(String)
    case notPaired(String)
    case locked(String)
    case developerModeOff(TargetDevice)
    case preparingDDI(TargetDevice, DDIStage)
    case ready(TargetDevice)
    case operating(TargetDevice, DeviceOperationKind)
    case failed(String)

    var device: TargetDevice? {
        switch self {
        case .developerModeOff(let device), .preparingDDI(let device, _), .ready(let device), .operating(let device, _): device
        default: nil
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .probing, .preparingDDI, .operating: true
        default: false
        }
    }
}

enum DeviceStateEvent: Equatable, Sendable {
    case pairingRemoved, probeStarted
    case probeSucceeded(TargetDevice)
    case probeFailedChannel(String), probeFailedNotPaired(String), probeFailedLocked(String), probeFailedOther(String)
    case ddiStageChanged(DDIStage)
    case operationStarted(DeviceOperationKind), operationFinished(TargetDevice), operationFailed(String)
    case disconnected
}

enum DeviceStateMachine: Sendable {
    static func reduce(state: DeviceConnectionState, event: DeviceStateEvent) -> DeviceConnectionState {
        switch (state, event) {
        case (_, .pairingRemoved), (.unpaired, .disconnected): return .unpaired
        case (_, .disconnected): return .channelUnavailable(String(localized: "设备已断开连接"))
        case (_, .probeStarted) where !state.isBusy: return .probing
        case (.probing, .probeSucceeded(let device)): return connected(device)
        case (.probing, .probeFailedChannel(let reason)): return .channelUnavailable(reason)
        case (.probing, .probeFailedNotPaired(let reason)): return .notPaired(reason)
        case (.probing, .probeFailedLocked(let reason)): return .locked(reason)
        case (.probing, .probeFailedOther(let reason)): return .failed(reason)
        case (.ready(let device), .ddiStageChanged(let stage)), (.preparingDDI(let device, _), .ddiStageChanged(let stage)):
            return .preparingDDI(device, stage)
        case (.ready(let device), .operationStarted(let kind)), (.preparingDDI(let device, _), .operationStarted(let kind)):
            return .operating(device, kind)
        case (.operating(let active, _), .operationFinished(let device)) where active.id == device.id:
            return connected(device)
        case (.operating, .operationFailed(let reason)), (.preparingDDI, .operationFailed(let reason)):
            return .failed(reason)
        default: return state
        }
    }

    private static func connected(_ device: TargetDevice) -> DeviceConnectionState {
        guard device.paired else { return .notPaired(String(localized: "设备配对已失效")) }
        return device.developerMode == false ? .developerModeOff(device) : .ready(device)
    }
}

struct AutoRestoreTracker: Equatable, Sendable {
    enum FailureResult: Equatable, Sendable {
        case notPending, retry, exhausted
    }

    static let maxAttempts = 15
    private(set) var presentIDs: Set<DeviceID>?
    private(set) var pendingAttempts: [DeviceID: Int] = [:]
    private var reportedMountLosses: Set<DeviceID> = []

    // 同一次掉挂载可能连续多次探测到，不能因此重置重试上限或重放已失效的任务。
    mutating func observe(presentIDs ids: Set<DeviceID>, recordedIDs: Set<DeviceID>,
                          confirmedUnmountedIDs: Set<DeviceID> = [], autoRestore: Bool = true) {
        defer { presentIDs = ids }
        guard autoRestore else {
            invalidate()
            reportedMountLosses = confirmedUnmountedIDs
            return
        }
        let reappeared = presentIDs.map { ids.subtracting($0) } ?? []
        let candidates = reappeared.union(confirmedUnmountedIDs.subtracting(reportedMountLosses))
        reportedMountLosses = confirmedUnmountedIDs
        pendingAttempts = pendingAttempts.filter { recordedIDs.contains($0.key) }
        for id in candidates.intersection(ids).intersection(recordedIDs) where pendingAttempts[id] == nil {
            pendingAttempts[id] = 0
        }
    }

    mutating func recordFailure(deviceID: DeviceID) -> FailureResult {
        guard let attempts = pendingAttempts[deviceID] else { return .notPending }
        guard attempts + 1 < Self.maxAttempts else {
            pendingAttempts[deviceID] = nil
            return .exhausted
        }
        pendingAttempts[deviceID] = attempts + 1
        return .retry
    }

    mutating func invalidate(deviceID: DeviceID? = nil) {
        if let deviceID { pendingAttempts[deviceID] = nil }
        else { pendingAttempts.removeAll() }
    }
}
