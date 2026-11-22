import SwiftUI

@MainActor @Observable final class AppStore {
    static let shared = AppStore()
    private(set) var environment: AppEnvironment
    private var state = AppStateStore.State()
    private(set) var pairingRecords = [StoredPairingRecord]()
    private(set) var deviceStates = [DeviceID: DeviceConnectionState]()
    private(set) var exit: ExitInfo?
    private(set) var pendingExitEvent: PendingExitEvent?
    var pendingExitChange: ExitInfo? { pendingExitEvent?.exit }
    private(set) var exitError: String?
    @ObservationIgnored private var following: Task<(ExitInfo, BatchOutcome), Error>?
    private var exitRequest: Task<ExitRefreshOutcome?, Never>?
    private(set) var busyMessage: String?
    private(set) var feedback: FeedbackMessage? {
        didSet {
            guard let message = feedback, message.kind == .success else { return }
            Task {
                try await Task.sleep(for: .seconds(5))
                if feedback?.id == message.id { dismissFeedback() }
            }
        }
    }
    private(set) var timeZoneResult = TimeZoneMatchResult.unavailable
    private(set) var tunnelStatus = TunnelConnectionStatus.disconnected
    @ObservationIgnored private(set) var loaded = false
    typealias ExitSample = (exit: ExitInfo, proxy: ExitProxyAddress?)
    @ObservationIgnored private var coldExitLookup: Task<ExitSample, Error>?
    @ObservationIgnored private var deviceWatch: Task<Void, Never>?
    @ObservationIgnored private var deviceRefresh: Task<Void, Never>?
    private var active = false
    @ObservationIgnored private var monitoring: Task<Void, Never>?
    @ObservationIgnored private var zoneCheck: Task<Void, Never>?
    var exitLoading: Bool { exitRequest != nil }
    var capabilities: AppCapabilities { environment.capabilities }
    var effectiveSettings: AppSettings { state.settings.adapted(to: capabilities) }
    var settings: AppSettings { effectiveSettings }
    var cities: [Place] { state.cities }
    var records: [DeviceID: AppliedLocationRecord] { state.records }
    var selectedDeviceID: DeviceID? { state.selectedDeviceID }
    var isDemo: Bool { environment.isDemo }
    var devices: [TargetDevice] { deviceStates.values.compactMap(\.device).sorted { $0.id.rawValue < $1.id.rawValue } }
    var readyDevices: [TargetDevice] { devices.filter { deviceStates[$0.id]?.isReady == true } }
    var selectedDevice: TargetDevice? { if let selectedDeviceID { deviceStates[selectedDeviceID]?.device } else { readyDevices.first ?? devices.first } }
    var selectedRecord: AppliedLocationRecord? { (selectedDeviceID ?? selectedDevice?.id).flatMap { records[$0] } }
    private var targets: [TargetDevice] { settings.applyToAll ? readyDevices : readyDevices.filter { $0.id == selectedDevice?.id } }
    var canOperate: Bool { busyMessage == nil && !targets.isEmpty }
    var exitProxy: ExitProxyAddress? { try? settings.parsedProxy.get() }
    var customProxyInvalid: Bool { if case .failure = settings.parsedProxy { true } else { false } }
    var needsOnboarding: Bool { !isDemo && !settings.hasCompletedOnboarding && readyDevices.isEmpty }

    init(environment: AppEnvironment) {
        self.environment = environment
        bindNotifications()
    }

    private func bindNotifications() {
        environment.notifier.onFollow = { [weak self] id in
            Task { await self?.followNotification(id) }
        }
    }
    convenience init() {
        do { self.init(environment: AppEnvironment.modePreferences.bool(forKey: "ElsewhereDemoMode") ? .demo() : try .live()) }
        catch { self.init(environment: .demo()); fail(String(localized: "无法启动设备模式"), error) }
    }
    func fail(_ title: String, _ error: Error) {
        feedback = FeedbackMessage(kind: .failure, title: title, detail: error.localizedDescription,
                                   rawLog: (error as? EngineError).map { [$0.stage, $0.rawDetail ?? $0.message].joined(separator: " · ") } ?? String(describing: error))
    }
    func dismissFeedback() { feedback = nil }
    @discardableResult
    func loadSettingsOnly() async -> Bool {
        let env = environment
        do {
            let saved = try await env.stateStore.load(adaptingTo: env.capabilities)
            guard env === environment else { return false }
            state = saved
            loaded = true
            let sameProxy = saved.exitBaseline?.proxyKey == (exitProxy?.display ?? "")
            exit = settings.exitFeaturesEnabled && sameProxy ? saved.exitBaseline?.lastExit : nil
            let pending = settings.exitFeaturesEnabled && sameProxy ? saved.pendingExitEvent : nil
            if pending != pendingExitEvent { pendingExitEvent = pending }
            return true
        } catch {
            fail(String(localized: "无法加载应用状态"), error)
            return false
        }
    }

    func load() async {
        let env = environment, wasActive = active
        guard await loadSettingsOnly(), !wasActive || active else { return }
        await refreshDevices()
        guard env === environment, !wasActive || active, settings.exitFeaturesEnabled, !customProxyInvalid else { return }
        await queryExit { [settings, exitProxy, targets] in
            await env.exitMonitor.handleForegroundReturn(settings: settings, proxy: exitProxy, targets: targets)
        }
    }

    func handleSceneActive() async {
        active = true
        await load()
        startMonitoring()
    }

    func handleSceneInactive() async {
        active = false
        monitoring?.cancel()
        deviceWatch?.cancel()
        deviceWatch = nil
        zoneCheck?.cancel()
        await updateTunnelStatus()
    }
    private func updateTunnelStatus() async {
        let env = environment
        if !active { await env.tunnelCoordinator.disconnectOwnedTunnelIfIdle() }
        let status = await env.tunnelCoordinator.status()
        if env === environment { tunnelStatus = status }
    }
    private func startMonitoring() {
        monitoring?.cancel()
        guard loaded, active else { return }
        if !isDemo, deviceWatch == nil {
            deviceWatch = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    guard let self else { return }
                    guard self.active, self.busyMessage == nil, self.deviceRefresh == nil else { continue }
                    let needsProbe = self.pairingRecords.contains {
                        self.deviceStates[$0.probeID]?.isReady != true || self.records[$0.probeID]?.confidence.isConfirmedSimulated == true
                    }
                    if needsProbe {
                        await self.refreshDevices(silently: true)
                    }
                }
            }
        }
        guard settings.exitFeaturesEnabled, settings.watchMode != .off, !customProxyInvalid else { return }
        monitoring = environment.monitorExit(context: { (self.settings, self.exitProxy, self.targets) }, receive: receive)
    }

    // 快捷指令与场景激活可以同时冷启动。设备探测共享这次采样的完成点。
    func prefetchExitBeforeProbing(_ lookup: @escaping @MainActor () async throws -> ExitSample) async throws -> ExitSample {
        if let coldExitLookup { return try await coldExitLookup.value }
        let task = Task { try await lookup() }
        coldExitLookup = task
        defer { coldExitLookup = nil }
        return try await task.value
    }

    func waitForDeviceRefresh() async { await deviceRefresh?.value }

    func refreshDevices() async { await refreshDevices(silently: false) }

    private func refreshDevices(silently: Bool) async {
        if let deviceRefresh { return await deviceRefresh.value }
        guard busyMessage == nil else { return }
        let task = Task {
            defer { deviceRefresh = nil }
            await performDeviceRefresh(silently: silently)
        }
        deviceRefresh = task
        if silently {
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        } else {
            await task.value
        }
    }

    private func performDeviceRefresh(silently: Bool) async {
        let previous = deviceStates
        if !silently { busyMessage = String(localized: "正在探测设备") }
        defer {
            busyMessage = nil
            if !Task.isCancelled, !silently || previous != deviceStates { checkTimeZone() }
        }
        do {
            pairingRecords = try await environment.pairingStore.records()
            let endpoints = isDemo ? [(environment.demoDeviceID, DemoLocationEngine.defaultDevice.endpointHost)] :
                pairingRecords.map { ($0.probeID, $0.endpointHost) }
            let ids = Set(endpoints.map { $0.0 })
            if !Set(deviceStates.keys).isSubset(of: ids) { deviceStates = deviceStates.filter { ids.contains($0.key) } }
            if let coldExitLookup { _ = await coldExitLookup.result }
            for (id, host) in endpoints {
                try Task.checkCancellation()
                _ = await probe(id, host: host, silently: silently)
            }
            try Task.checkCancellation()
            if !isDemo { pairingRecords = try await environment.pairingStore.records() }
            let restored = await environment.withProgress({ self.progress($0, $1, restoring: true) }) { stage in
                await self.environment.commandService.observeDevicesAndRestoreIfNeeded(readyDevices: self.readyDevices, settings: self.settings, onStage: stage)
            }
            for result in restored { finish(result, title: String(localized: "已恢复上次模拟位置")) }
            let names = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.name) })
            if names.contains(where: { state.knownDeviceNames[$0.key] != $0.value }) {
                try await environment.stateStore.updateKnownDeviceNames(names)
                state.knownDeviceNames.merge(names) { _, new in new }
            }
            if !silently || previous != deviceStates || !restored.isEmpty { try await refreshDisplaySnapshot() }
            await updateTunnelStatus()
        } catch {
            if !Task.isCancelled { fail(String(localized: "无法刷新设备"), error) }
        }
    }

    private func probe(_ id: DeviceID, host: String, silently: Bool = false) async -> Bool {
        let previous = deviceStates[id]
        if !silently { deviceStates[id] = DeviceStateMachine.reduce(state: previous ?? .unpaired, event: .probeStarted) }
        let (bound, state, error) = await environment.probe(id, host: host, settings: settings)
        if Task.isCancelled {
            if !silently { deviceStates[id] = previous }
            return false
        }
        if id != bound { deviceStates[id] = nil }
        if deviceStates[bound] != state { deviceStates[bound] = state }
        if !silently || previous != state {
            if let error { fail(String(localized: "无法连接设备 · ") + host, error) }
            else if !state.isReady { feedback = .init(kind: .failure, title: String(localized: "设备尚未就绪"), detail: state.diagnosis, rawLog: host) }
        }
        return state.isReady
    }
    func testConnection(recordID: UUID) async -> Bool {
        guard busyMessage == nil, deviceRefresh == nil else { return false }
        guard let record = pairingRecords.first(where: { $0.id == recordID }) else { fail(String(localized: "无法测试连接"), PairingStoreError.recordNotFound); return false }
        busyMessage = String(localized: "正在验证设备配对")
        defer { busyMessage = nil }
        let ready = await probe(record.probeID, host: record.endpointHost)
        do { pairingRecords = try await environment.pairingStore.records() } catch { fail(String(localized: "无法读取认证结果"), error); return false }
        await updateTunnelStatus()
        if ready { feedback = .init(kind: .success, title: String(localized: "已连接并验证设备"), detail: record.endpointHost) }
        return ready
    }
    func selectDevice(_ id: DeviceID?) async {
        let env = environment
        do {
            try await env.stateStore.saveSelectedDeviceID(id)
            guard env === environment else { return }
            state.selectedDeviceID = id
            try await refreshDisplaySnapshot()
            checkTimeZone()
        } catch { fail(String(localized: "无法保存目标设备"), error) }
    }

    private func refreshDisplaySnapshot() async throws {
        try await environment.stateStore.refreshDisplaySnapshot(selectedDevice: selectedDevice, at: Date())
    }

    private func checkTimeZone() {
        zoneCheck?.cancel()
        zoneCheck = Task {
            let selected = selectedDevice?.id
            let ordered = readyDevices.filter { $0.id == selected } + readyDevices.filter { $0.id != selected }
            var nextCheck: Date?
            var result = TimeZoneMatchResult.unavailable
            for device in ordered {
                guard let record = records[device.id], record.confidence.isConfirmedSimulated else { continue }
                let deadline = record.appliedAt.addingTimeInterval(60)
                if deadline > Date() {
                    nextCheck = min(nextCheck ?? deadline, deadline)
                    continue
                }
                let evaluated = await environment.checkTimeZone(record: record, device: device)
                guard !Task.isCancelled else { return }
                if case .mismatch = evaluated { timeZoneResult = evaluated; return }
                if evaluated == .matched { result = .matched }
            }
            guard !Task.isCancelled else { return }
            timeZoneResult = nextCheck == nil ? result : .withinGracePeriod
            if let nextCheck {
                do { try await Task.sleep(for: .seconds(max(0, nextCheck.timeIntervalSinceNow))) } catch { return }
                if active, !isDemo, busyMessage == nil {
                    await refreshDevices(silently: true)
                }
                if !Task.isCancelled { checkTimeZone() }
            }
        }
    }
    func refreshExit() async {
        guard settings.exitFeaturesEnabled, !exitLoading else { return }
        if case .failure(let error) = settings.parsedProxy { fail(String(localized: "自定义代理地址无效"), error); return }
        await queryExit { [environment, settings, exitProxy] in await environment.exitMonitor.refreshManually(settings: settings, proxy: exitProxy) }
    }
    private func queryExit(_ fetch: @escaping @MainActor () async -> ExitRefreshOutcome?) async {
        let request = exitRequest ?? Task { await fetch() }
        exitRequest = request
        let outcome = await request.value
        guard exitRequest == request else { return }
        exitRequest = nil
        if let outcome { receive(outcome) }
    }
    private func receive(_ outcome: ExitRefreshOutcome) {
        guard settings.exitFeaturesEnabled else { return }
        switch outcome {
        case .updated(let info):
            (exit, exitError) = (info, nil)
            if pendingExitEvent?.exit.ip != info.ip { pendingExitEvent = nil }
        case .pendingChange(let event):
            (exit, pendingExitEvent, exitError) = (event.exit, event, nil)
        case .autoFollowed(let info, let result, let pending):
            (exit, pendingExitEvent, exitError) = (info, pending, nil)
            finish(result, title: String(localized: "已跟随出口"))
        case .discrepancy(let probe, let detail): exitError = String(localized: "出口检测结果不一致（\(probe) / \(detail)）")
        case .failed(let reason): exitError = reason
        case .unchanged(let info):
            if let info { exit = info }
            return
        case .disabled: return
        }
        if let exitError { feedback = .init(kind: .failure, title: String(localized: "出口查询异常"), detail: exitError, rawLog: exitError) }
    }

    func dismissPendingExitChange() async {
        let id = pendingExitEvent?.id
        pendingExitEvent = nil
        await environment.exitMonitor.clearPendingEvent(id: id)
    }

    private func followNotification(_ id: UUID?) async {
        let env = environment
        if !loaded, !(await loadSettingsOnly()) { return }
        guard let id, settings.exitFeaturesEnabled, let event = await env.exitMonitor.pendingEvent(for: id),
              env === environment, isCurrent(event) else {
            feedback = .init(kind: .failure, title: String(localized: "这次出口变化已过期，请刷新出口后再跟随。"))
            return
        }
        if readyDevices.isEmpty || deviceRefresh != nil { await refreshDevices() }
        guard env === environment, settings.exitFeaturesEnabled, isCurrent(event),
              await env.exitMonitor.pendingEvent(for: id) == event else {
            feedback = .init(kind: .failure, title: String(localized: "这次出口变化已过期，请刷新出口后再跟随。"))
            return
        }
        pendingExitEvent = event
        await followExit(sample: event.exit, event: event)
    }

    private func isCurrent(_ event: PendingExitEvent) -> Bool {
        let age = Date().timeIntervalSince(event.createdAt)
        return (0...60).contains(age) && event.exit.sampledAt.timeIntervalSinceNow >= -60
            && !(exit.map { $0.sampledAt > event.exit.sampledAt && $0.ip != event.exit.ip } ?? false)
    }

    func followExit(prefetched: ExitInfo? = nil) async {
        if let event = pendingExitEvent, prefetched == event.exit {
            await followNotification(event.id)
        } else {
            await followExit(sample: prefetched, event: nil)
        }
    }

    private func followExit(sample: ExitInfo?, event: PendingExitEvent?) async {
        await operate(String(localized: "正在跟随出口"), targetIDs: event.map { Set($0.targetDeviceIDs) }) { targets, stage in
            let task = self.environment.startFollowing(sample, latest: self.exit, targets: targets, settings: self.settings, onStage: stage)
            self.following = task
            defer { self.following = nil }
            let (info, result) = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            if !task.isCancelled, self.settings.exitFeaturesEnabled {
                self.exit = info
                if let event, Set(event.targetDeviceIDs).isSubset(of: Set(result.succeeded.map(\.id))) {
                    await self.environment.exitMonitor.clearPendingEvent(id: event.id)
                    if self.pendingExitEvent?.id == event.id { self.pendingExitEvent = nil }
                }
            }
            return result
        }
    }
    func apply(place: Place, source: LocationSource) async { await apply(name: place.displayName, coordinate: place.coordinate, source: source) }
    func apply(name: String, coordinate: WGS84Coordinate, source: LocationSource) async {
        await operate(String(localized: "正在设置模拟位置")) { targets, stage in
            await self.environment.commandService.applyLocation(name: name, coordinate: coordinate, source: source, exitIP: nil,
                targets: targets, settings: self.settings, onStage: stage)
        }
    }
    func clearLocation() async {
        await operate(String(localized: "正在恢复真实定位")) { targets, stage in
            await self.environment.commandService.clearLocation(targets: targets, allReadyDevices: self.readyDevices, settings: self.settings, onStage: stage)
        }
    }
    private func progress(_ id: DeviceID, _ stage: EngineOperationStage, restoring: Bool = false) {
        let event: DeviceStateEvent? = switch stage {
        case .connecting: nil
        case .downloadingDDI: .ddiStageChanged(.downloading)
        case .verifyingDDI: .ddiStageChanged(.verifying)
        case .signingDDI: .ddiStageChanged(.signing)
        case .uploadingDDI: .ddiStageChanged(.uploading)
        case .mountingDDI: .ddiStageChanged(.mounting)
        case .applyingLocation: .operationStarted(restoring ? .restoreLocation : .setLocation)
        case .clearingLocation: .operationStarted(.clearLocation)
        }
        if let event, let current = deviceStates[id] {
            deviceStates[id] = DeviceStateMachine.reduce(state: current, event: event)
        }
        if let name = deviceStates[id]?.device?.name { busyMessage = String(localized: "\(name) · \(stage.title)") }
        else { busyMessage = stage.title }
    }
    private func operate(_ title: String, targetIDs: Set<DeviceID>? = nil, _ action: @MainActor ([TargetDevice], @escaping AppEnvironment.StageReport) async throws -> BatchOutcome) async {
        if let deviceRefresh { await deviceRefresh.value }
        guard busyMessage == nil else {
            feedback = .init(kind: .failure, title: String(localized: "设备正忙：\(busyMessage ?? title)"))
            return
        }
        let batch = targetIDs.map { ids in readyDevices.filter { ids.contains($0.id) } } ?? targets
        guard !batch.isEmpty else { feedback = .init(kind: .failure, title: String(localized: "没有就绪的目标设备"), detail: String(localized: "请检查配对和通道连接。"), rawLog: "readyTargets=0"); return }
        busyMessage = title
        defer { busyMessage = nil }
        do {
            let result = try await environment.withProgress({ self.progress($0, $1) }) { try await action(batch, $0) }
            finish(result, title: String(localized: "定位操作完成"))
            try await refreshDisplaySnapshot()
        } catch {
            for device in batch {
                if let current = deviceStates[device.id] {
                    deviceStates[device.id] = DeviceStateMachine.reduce(state: current, event: .operationFailed(error.localizedDescription))
                }
            }
            fail(String(localized: "定位操作失败"), error)
        }
        await updateTunnelStatus()
    }
    private func finish(_ result: BatchOutcome, title: String) {
        for device in result.succeeded + result.unknown {
            if let current = deviceStates[device.id] {
                deviceStates[device.id] = DeviceStateMachine.reduce(state: current, event: .operationFinished(device))
            }
        }
        for failure in result.failed {
            if let current = deviceStates[failure.device.id] {
                deviceStates[failure.device.id] = DeviceStateMachine.reduce(state: current, event: .operationFailed(failure.error.message))
            }
        }
        state.records = result.records
        feedback = result.feedback(title: title)
        checkTimeZone()
    }
    private func saveCities(_ change: (inout [Place]) -> Void) async {
        let previous = cities, env = environment
        change(&state.cities)
        let updated = cities
        do { try await env.stateStore.saveCities(updated) }
        catch { if env === environment, cities == updated { state.cities = previous; fail(String(localized: "无法保存城市"), error) } }
    }
    func addCity(_ place: Place) async { await saveCities { $0.append(place) } }
    func removeCities(at offsets: IndexSet) async { await saveCities { $0.remove(atOffsets: offsets) } }
    func moveCities(from source: IndexSet, to destination: Int) async { await saveCities { $0.move(fromOffsets: source, toOffset: destination) } }
    func resetCities() async { await saveCities { $0 = Place.defaults } }

    private func editPairing<T>(_ action: @MainActor (PairingStore) async throws -> T) async throws -> T {
        do {
            let env = environment, value = try await action(env.pairingStore)
            let latest = try await env.pairingStore.records()
            guard env === environment else { throw CancellationError() }
            pairingRecords = latest
            return value
        } catch { fail(String(localized: "无法更新配对记录"), error); throw error }
    }
    func importPairing(url: URL, endpointHost: String, deviceName: String?) async throws -> StoredPairingRecord {
        try await editPairing { try await $0.importPairing(fromSecurityScopedURL: url, endpointHost: endpointHost, deviceName: deviceName) }
    }
    func importPairing(data: Data, endpointHost: String, deviceName: String?) async throws -> StoredPairingRecord {
        try await editPairing { try await $0.importPairing(data: data, endpointHost: endpointHost, deviceName: deviceName) }
    }
    func deletePairing(id: UUID) async {
        if (try? await editPairing { try await $0.delete(id: id) }) != nil { await refreshDevices() }
    }
    func updateEndpointHost(_ host: String, for id: UUID) async {
        if (try? await editPairing { try await $0.updateEndpointHost(host, for: id) }) != nil { await refreshDevices() }
    }
    func updateSettings(_ mutate: (inout AppSettings) -> Void) async {
        let previous = settings, env = environment
        mutate(&state.settings)
        state.settings = effectiveSettings
        let updated = settings
        let reset = previous.exitFeaturesEnabled != updated.exitFeaturesEnabled || previous.customProxyText != updated.customProxyText
        if reset { monitoring?.cancel(); following?.cancel(); exitRequest?.cancel(); (exit, pendingExitEvent, exitError, exitRequest) = (nil, nil, nil, nil) }
        do {
            try await env.stateStore.saveSettings(updated)
            guard env === environment, settings == updated else { return }
            if previous.customProxyText != updated.customProxyText {
                await env.exitMonitor.resetForProxyChange()
            } else if previous.exitFeaturesEnabled && !updated.exitFeaturesEnabled {
                await env.exitMonitor.invalidateDisabledState()
            }
            guard env === environment, settings == updated else { return }
            if reset && updated.exitFeaturesEnabled { await refreshExit() }
            if reset || previous.watchMode != updated.watchMode { startMonitoring() }
        } catch { if env === environment, settings == updated { state.settings = previous; fail(String(localized: "无法保存设置"), error); startMonitoring() } }
    }
    func markSplashSeen() async {
        let env = environment
        do {
            try await env.stateStore.markSplashSeen()
            if env === environment { state.settings.hasSeenSplash = true }
        } catch { fail(String(localized: "无法保存设置"), error) }
    }
    func completeOnboarding() async { await updateSettings { $0.hasCompletedOnboarding = true } }
    func switchToDemo(_ enabled: Bool) async {
        guard enabled != isDemo, busyMessage == nil, deviceRefresh == nil else { return }
        do {
            let next: AppEnvironment = enabled ? .demo() : try .live()
            monitoring?.cancel()
            exitRequest?.cancel()
            zoneCheck?.cancel()
            deviceWatch?.cancel()
            deviceWatch = nil
            environment.notifier.onFollow = nil
            busyMessage = String(localized: "正在切换模式")
            await environment.tunnelCoordinator.disconnectOwnedTunnelIfIdle()
            environment = next
            bindNotifications()
            AppEnvironment.modePreferences.set(enabled, forKey: "ElsewhereDemoMode")
            (exit, pendingExitEvent, exitError, exitRequest) = (nil, nil, nil, nil)
            state = AppStateStore.State(); loaded = false
            (pairingRecords, deviceStates, feedback, busyMessage) = ([], [:], nil, nil)
            await load()
            startMonitoring()
        } catch { fail(String(localized: "无法切换运行模式"), error) }
    }
}
