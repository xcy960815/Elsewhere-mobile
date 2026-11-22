import Foundation

struct DeviceFailure: Equatable, Sendable {
    let device: TargetDevice
    let error: EngineError
}

struct BatchOutcome: Equatable, Sendable {
    var succeeded: [TargetDevice] = []
    var failed: [DeviceFailure] = []
    var unknown: [TargetDevice] = []
    var records: [DeviceID: AppliedLocationRecord] = [:]
}

extension AppStateStore {
    func saveCommandResult(_ record: AppliedLocationRecord?, for device: TargetDevice, settings: AppSettings,
                           at date: Date) throws -> [DeviceID: AppliedLocationRecord] {
        let state = try commitDeviceRecord(record, for: device.id, deviceName: device.name)
        let enabled = settings.exitFeaturesEnabled && state.settings.exitFeaturesEnabled
        try writeDisplaySnapshot(state: state, selectedDeviceName: nil, exitEnabled: enabled,
                                 exitSummary: widgetSnapshot?.exitSummary, at: date)
        return state.records
    }

    func saveExitSnapshot(_ exit: ExitInfo, at date: Date) throws {
        let state = try load()
        try Task.checkCancellation()
        guard state.settings.exitFeaturesEnabled else { throw CancellationError() }
        try writeDisplaySnapshot(state: state, selectedDeviceName: nil, exitEnabled: true, exitSummary: exit.summary(locale: AppLanguage.locale), at: date)
    }
}

actor CommandService {
    private enum Write: Sendable {
        case set(String, WGS84Coordinate, LocationSource, String?, UInt64?)
        case clear(Set<DeviceID>)
        case restore(AppliedLocationRecord)

        var location: (name: String, coordinate: WGS84Coordinate, source: LocationSource, ip: String?)? {
            switch self {
            case let .set(name, coordinate, source, ip, _): (name, coordinate, source, ip)
            case let .restore(record): (record.name, record.coordinate, record.source, record.exitIP)
            case .clear: nil
            }
        }
    }

    private let engine: any LocationEngineProtocol
    private let tunnel: TunnelCoordinator
    private let stateStore: AppStateStore
    private let exitService: ExitIPService
    private let clock: @Sendable () -> Date
    private var queues: [DeviceID: Task<BatchOutcome, Never>] = [:]
    private(set) var manualRevision: UInt64 = 0
    private var restoreTracker = AutoRestoreTracker()
    private var restoring: Set<DeviceID> = []

    init(engine: any LocationEngineProtocol, tunnel: TunnelCoordinator, stateStore: AppStateStore,
         exitService: ExitIPService, clock: @escaping @Sendable () -> Date = Date.init) {
        self.engine = engine
        self.tunnel = tunnel
        self.stateStore = stateStore
        self.exitService = exitService
        self.clock = clock
    }

    func probe(deviceID: DeviceID, endpointHost: String, settings: AppSettings) async throws(EngineError) -> TargetDevice {
        do {
            return try await tunnel.withChannel(mode: settings.channelMode, targetHost: endpointHost,
                                                autoDisconnect: settings.autoDisconnectTunnel) { [engine] in
                try await engine.probe(deviceID: deviceID, endpointHost: endpointHost)
            }
        } catch { throw failure(error, code: .tunnel_unavailable) }
    }

    func applyLocation(name: String, coordinate: WGS84Coordinate, source: LocationSource, exitIP: String?,
                       targets: [TargetDevice], settings: AppSettings, expectedManualRevision: UInt64? = nil,
                       onStage: @escaping @Sendable (DeviceID, EngineOperationStage) -> Void = { _, _ in }) async -> BatchOutcome {
        let manual = source != .exitIP || expectedManualRevision == nil
        if manual {
            manualRevision += 1
            for device in targets { restoreTracker.invalidate(deviceID: device.id) }
        }
        if source == .exitIP && (!settings.exitFeaturesEnabled || (!manual && expectedManualRevision != manualRevision)) {
            return BatchOutcome(records: (try? await stateStore.load().records) ?? [:])
        }
        return await enqueue(.set(name, coordinate, source, exitIP, manual ? nil : expectedManualRevision),
                             targets: targets, settings: settings, onStage: onStage)
    }

    func followExit(prefetched: ExitInfo? = nil, targets: [TargetDevice], settings: AppSettings,
                    proxy: ExitProxyAddress?, isAutomatic: Bool = false,
                    onStage: @escaping @Sendable (DeviceID, EngineOperationStage) -> Void = { _, _ in }) async throws -> (exit: ExitInfo, outcome: BatchOutcome) {
        let revision = manualRevision
        guard settings.exitFeaturesEnabled, try await stateStore.load().settings.exitFeaturesEnabled else { throw CancellationError() }
        let info: ExitInfo
        if let prefetched { info = prefetched }
        else { info = try await exitService.lookup(proxy: proxy) }
        if !isAutomatic || (prefetched == nil && manualRevision == revision) {
            try await stateStore.saveExitSnapshot(info, at: clock())
        }
        try Task.checkCancellation()
        let outcome = await applyLocation(name: info.displayCity, coordinate: info.coordinate, source: .exitIP, exitIP: info.ip,
                                          targets: targets, settings: settings, expectedManualRevision: isAutomatic ? revision : nil, onStage: onStage)
        return (info, outcome)
    }

    func clearLocation(targets: [TargetDevice], allReadyDevices: [TargetDevice], settings: AppSettings,
                       onStage: @escaping @Sendable (DeviceID, EngineOperationStage) -> Void = { _, _ in }) async -> BatchOutcome {
        manualRevision += 1
        return await enqueue(.clear(Set(targets.map(\.id))), targets: targets + allReadyDevices, settings: settings, onStage: onStage)
    }

    func observeDevicesAndRestoreIfNeeded(readyDevices: [TargetDevice], settings: AppSettings,
                                          onStage: @escaping @Sendable (DeviceID, EngineOperationStage) -> Void = { _, _ in }) async -> [BatchOutcome] {
        let state: AppStateStore.State
        do { state = try await stateStore.load() } catch {
            return [BatchOutcome(failed: readyDevices.map { DeviceFailure(device: $0, error: failure(error)) })]
        }
        let records = state.records.filter { !$0.value.confidence.isUnknown }
        restoreTracker.observe(presentIDs: Set(readyDevices.map(\.id)), recordedIDs: Set(records.keys),
                               confirmedUnmountedIDs: Set(readyDevices.filter { $0.ddiMounted == false && records[$0.id] != nil }.map(\.id)),
                               autoRestore: settings.autoRestore && state.settings.autoRestore)
        var results: [BatchOutcome] = []
        for device in readyDevices {
            guard restoreTracker.pendingAttempts[device.id] != nil, let record = records[device.id],
                  restoring.insert(device.id).inserted else { continue }
            let outcome = await enqueue(.restore(record), targets: [device], settings: settings, onStage: onStage)
            restoring.remove(device.id)
            if !outcome.failed.isEmpty || !outcome.unknown.isEmpty { _ = restoreTracker.recordFailure(deviceID: device.id) }
            if !outcome.succeeded.isEmpty || !outcome.failed.isEmpty || !outcome.unknown.isEmpty { results.append(outcome) }
        }
        return results
    }

    private func includes(_ device: TargetDevice, in write: Write, state: AppStateStore.State,
                          settings: AppSettings, startingMode: ExitWatchMode? = nil) -> Bool {
        if write.location?.source == .exitIP && !(settings.exitFeaturesEnabled && state.settings.exitFeaturesEnabled) { return false }
        switch write {
        case .set(_, _, _, let ip, let revision):
            guard let revision else { return true }
            guard revision == manualRevision, let record = state.records[device.id], !record.confidence.isUnknown else { return false }
            guard settings.watchMode == .auto else { return true }
            // 手动命令可能在采样前就已排队，直到此刻才把旧的出口记录换成城市或清除。
            guard record.source == .exitIP, record.exitIP != ip else { return false }
            let mode = state.settings.watchMode
            return mode != .off && (startingMode == nil || mode == startingMode || mode == .auto)
        case .clear(let selected):
            return selected.contains(device.id) || (state.lastAppliedBatchIDs.contains(device.id)
                && state.records[device.id].map { !$0.confidence.isUnknown } == true)
        case .restore(let record):
            return state.settings.autoRestore && restoreTracker.pendingAttempts[device.id] != nil
                && restoreTracker.presentIDs?.contains(device.id) == true && state.records[device.id] == record
        }
    }

    private func enqueue(_ write: Write, targets: [TargetDevice], settings: AppSettings,
                         onStage: @escaping @Sendable (DeviceID, EngineOperationStage) -> Void) async -> BatchOutcome {
        var ids: Set<DeviceID> = []
        let devices = targets.filter { ids.insert($0.id).inserted }
        // 一次占好整批设备的队尾，交叉批次不会在第二台设备上互相超车或死锁。
        let predecessors = Set(ids.compactMap { queues[$0] })
        let task = Task {
            for previous in predecessors { _ = await previous.value }
            let state: AppStateStore.State
            do { state = try await stateStore.load() } catch {
                return BatchOutcome(failed: devices.map { DeviceFailure(device: $0, error: failure(error)) })
            }
            let batch = devices.filter { includes($0, in: write, state: state, settings: settings) }
            var outcome = BatchOutcome(records: state.records)
            var groups: [[TargetDevice]] = []
            for device in batch {
                if groups.isEmpty || (settings.channelMode == .builtInTunnel && groups.last?.last?.endpointHost != device.endpointHost) {
                    groups.append([device])
                } else {
                    groups[groups.count - 1].append(device)
                }
            }
            for group in groups {
                do {
                    let result = try await tunnel.withChannel(mode: settings.channelMode, targetHost: group[0].endpointHost,
                                                              autoDisconnect: settings.autoDisconnectTunnel) {
                        await self.execute(write, targets: group, settings: settings, initial: state, onStage: onStage)
                    }
                    outcome.succeeded += result.succeeded
                    outcome.unknown += result.unknown
                    outcome.failed += result.failed
                    outcome.records = result.records
                } catch {
                    outcome.failed += group.map { DeviceFailure(device: $0, error: failure(error, code: .tunnel_unavailable)) }
                }
            }
            let succeeded = outcome.succeeded
            if !succeeded.isEmpty {
                do {
                    switch write {
                    case .set: try await stateStore.saveLastAppliedBatchIDs(succeeded.map(\.id))
                    case .clear: try await stateStore.removeClearedBatchIDs(Set(succeeded.map(\.id)))
                    case .restore: break
                    }
                } catch {
                    outcome.failed += succeeded.map { DeviceFailure(device: $0, error: failure(error)) }
                }
            }
            if let latest = try? await stateStore.load() { outcome.records = latest.records }
            return outcome
        }
        for id in ids { queues[id] = task }
        defer { for id in ids where queues[id] == task { queues[id] = nil } }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func execute(_ write: Write, targets: [TargetDevice], settings: AppSettings, initial: AppStateStore.State,
                         onStage: @escaping @Sendable (DeviceID, EngineOperationStage) -> Void) async -> BatchOutcome {
        var outcome = BatchOutcome(records: initial.records)
        for device in targets {
            do {
                let state = try await stateStore.load()
                try Task.checkCancellation()
                guard includes(device, in: write, state: state, settings: settings, startingMode: initial.settings.watchMode) else { continue }
                let stage: @Sendable (EngineOperationStage) -> Void = { onStage(device.id, $0) }
                let location = write.location
                let confidence: AppliedConfidence
                do throws(EngineError) {
                    if let location { try await engine.setLocation(location.coordinate, on: device.id, onStage: stage) }
                    else { try await engine.clearLocation(on: device.id, onStage: stage) }
                    confidence = .confirmed
                    restoreTracker.invalidate(deviceID: device.id)
                } catch {
                    guard error.outcomeUnknown else {
                        outcome.failed.append(DeviceFailure(device: device, error: error))
                        continue
                    }
                    outcome.unknown.append(device)
                    confidence = location == nil ? .clearUnknown : .unknownOutcome
                }
                let date = clock()
                var record = location.map { AppliedLocationRecord(deviceID: device.id, deviceName: device.name, name: $0.name,
                    coordinate: $0.coordinate, appliedAt: date, source: $0.source, exitIP: $0.ip, confidence: confidence) }
                if confidence == .clearUnknown, let previous = state.records[device.id] {
                    record = AppliedLocationRecord(deviceID: device.id, deviceName: previous.deviceName, name: previous.name,
                        coordinate: previous.coordinate, appliedAt: previous.appliedAt, source: previous.source,
                        exitIP: previous.exitIP, confidence: confidence)
                }
                outcome.records = try await stateStore.saveCommandResult(record, for: device, settings: settings, at: date)
                if confidence == .confirmed { outcome.succeeded.append(device) }
            } catch { outcome.failed.append(DeviceFailure(device: device, error: failure(error))) }
        }
        return outcome
    }

    private func failure(_ error: Error, code: EngineErrorCode = .failed) -> EngineError {
        if let engineError = error as? EngineError { return engineError }
        let reason: EngineErrorCode = error is CancellationError ? .cancelled : code
        return EngineError(code: reason, stage: reason == .failed ? "state_store" : EngineOperationStage.connecting.rawValue,
                           message: error.localizedDescription)
    }
}
