import SwiftUI

@MainActor @Observable final class AppStore {
    static let shared = AppStore()
    private(set) var environment: AppEnvironment
    private var state = AppStateStore.State()
    private(set) var pairingRecords = [StoredPairingRecord]()
    private(set) var deviceStates = [DeviceID: DeviceConnectionState]()
    private(set) var exit: ExitInfo?
    private(set) var pendingExitChange: ExitInfo?
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
    @ObservationIgnored private var loaded = false
    private var active = false
    @ObservationIgnored private var monitoring: Task<Void, Never>?
    @ObservationIgnored private var zoneCheck: Task<Void, Never>?
    var exitLoading: Bool { exitRequest != nil }
    var settings: AppSettings { state.settings }
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
    var needsOnboarding: Bool { !isDemo && pairingRecords.isEmpty && !settings.hasCompletedOnboarding }

    init(environment: AppEnvironment) { self.environment = environment }
    convenience init() {
        do { self.init(environment: AppEnvironment.modePreferences.bool(forKey: "ElsewhereDemoMode") ? .demo() : try .live()) }
        catch { self.init(environment: .demo()); fail("无法启动设备模式", error) }
    }
    func fail(_ title: String, _ error: Error) {
        feedback = FeedbackMessage(kind: .failure, title: title, detail: error.localizedDescription,
                                   rawLog: (error as? EngineError).map { [$0.stage, $0.rawDetail ?? $0.message].joined(separator: " · ") } ?? String(describing: error))
    }
    func dismissFeedback() { feedback = nil }
    func load() async {
        let env = environment
        do {
            let state = try await env.stateStore.load()
            guard env === environment else { return }
            (self.state, loaded) = (state, true)
            env.notifier.onFollow = { [weak self] in
                guard let self, let pending = self.pendingExitChange, self.settings.exitFeaturesEnabled else { return }
                Task { await self.followExit(prefetched: pending) }
            }
            await refreshDevices()
            if env === environment { await refreshExit() }
        } catch { fail("无法加载应用状态", error) }
    }
    func handleSceneActive() async {
        active = true
        let env = environment
        if !loaded { await load(); startMonitoring(); return }
        await refreshDevices()
        guard active, env === environment, settings.exitFeaturesEnabled, !customProxyInvalid else { return }
        await queryExit { [settings, exitProxy] in await env.exitMonitor.handleForegroundReturn(settings: settings, proxy: exitProxy) }
        startMonitoring()
    }
    func handleSceneInactive() async {
        active = false
        monitoring?.cancel()
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
        guard loaded, active, settings.exitFeaturesEnabled, settings.watchMode != .off, !customProxyInvalid else { return }
        monitoring = environment.monitorExit(context: { (self.settings, self.exitProxy, self.targets) }, receive: receive)
    }
    func refreshDevices() async {
        guard busyMessage == nil else { return }
        busyMessage = "正在探测设备"
        defer { busyMessage = nil; checkTimeZone() }
        do {
            pairingRecords = try await environment.pairingStore.records()
            let endpoints = isDemo ? [(environment.demoDeviceID, DemoLocationEngine.defaultDevice.endpointHost)] :
                pairingRecords.map { ($0.probeID, $0.endpointHost) }
            deviceStates = deviceStates.filter { entry in endpoints.contains { $0.0 == entry.key } }
            for (id, host) in endpoints { _ = await probe(id, host: host) }
            if !isDemo { pairingRecords = try await environment.pairingStore.records() }
            let restored = await environment.withProgress(progress) { stage in
                await self.environment.commandService.observeDevicesAndRestoreIfNeeded(readyDevices: self.readyDevices, settings: self.settings, onStage: stage)
            }
            for result in restored { finish(result, title: "已恢复上次模拟位置") }
            await updateTunnelStatus()
        } catch { fail("无法刷新设备", error) }
    }
    private func probe(_ id: DeviceID, host: String) async -> Bool {
        deviceStates[id] = DeviceStateMachine.reduce(state: deviceStates[id] ?? .unpaired, event: .probeStarted)
        let (bound, state, error) = await environment.probe(id, host: host, settings: settings)
        if id != bound { deviceStates[id] = nil }
        deviceStates[bound] = state
        if let error { fail("无法连接设备 · " + host, error) }
        else if !state.isReady { feedback = .init(kind: .failure, title: "设备尚未就绪", detail: state.diagnosis, rawLog: host) }
        return state.isReady
    }
    func testConnection(recordID: UUID) async -> Bool {
        guard busyMessage == nil else { return false }
        guard let record = pairingRecords.first(where: { $0.id == recordID }) else { fail("无法测试连接", PairingStoreError.recordNotFound); return false }
        busyMessage = "正在验证设备配对"
        defer { busyMessage = nil }
        let ready = await probe(record.probeID, host: record.endpointHost)
        do { pairingRecords = try await environment.pairingStore.records() } catch { fail("无法读取认证结果", error); return false }
        await updateTunnelStatus()
        if ready { feedback = .init(kind: .success, title: "已连接并验证设备", detail: record.endpointHost) }
        return ready
    }
    func selectDevice(_ id: DeviceID?) async {
        let env = environment
        do { try await env.stateStore.saveSelectedDeviceID(id); if env === environment { state.selectedDeviceID = id; pendingExitChange = nil; checkTimeZone() } }
        catch { fail("无法保存目标设备", error) }
    }
    private func checkTimeZone() {
        zoneCheck?.cancel()
        zoneCheck = environment.checkTimeZone(record: selectedRecord, device: selectedDevice) { self.timeZoneResult = $0 }
    }
    func refreshExit() async {
        guard settings.exitFeaturesEnabled, !exitLoading else { return }
        if case .failure(let error) = settings.parsedProxy { fail("自定义代理地址无效", error); return }
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
        case .updated(let info): (exit, pendingExitChange, exitError) = (info, nil, nil)
        case .pendingChange(let info): (exit, pendingExitChange, exitError) = (info, info, nil)
        case .autoFollowed(let info, let result): (exit, pendingExitChange, exitError) = (info, nil, nil); finish(result, title: "已跟随出口")
        case .discrepancy(let probe, let detail): exitError = "出口检测结果不一致（\(probe) / \(detail)）"; pendingExitChange = nil
        case .failed(let reason): exitError = reason
        case .disabled, .unchanged: return
        }
        if let exitError { feedback = .init(kind: .failure, title: "出口查询异常", detail: exitError, rawLog: exitError) }
    }
    func followExit(prefetched: ExitInfo? = nil) async {
        await operate("正在跟随出口") { targets, stage in
            let task = self.environment.startFollowing(prefetched, latest: self.exit, targets: targets, settings: self.settings, onStage: stage)
            self.following = task
            defer { self.following = nil }
            let (info, result) = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            if !task.isCancelled, self.settings.exitFeaturesEnabled {
                self.exit = info
                if !result.succeeded.isEmpty { self.pendingExitChange = nil }
            }
            return result
        }
    }
    func apply(place: Place, source: LocationSource) async { await apply(name: place.name, coordinate: place.coordinate, source: source) }
    func apply(name: String, coordinate: WGS84Coordinate, source: LocationSource) async {
        await operate("正在设置模拟位置") { targets, stage in
            await self.environment.commandService.applyLocation(name: name, coordinate: coordinate, source: source, exitIP: nil,
                targets: targets, settings: self.settings, onStage: stage)
        }
    }
    func clearLocation() async {
        await operate("正在恢复真实定位") { targets, stage in
            await self.environment.commandService.clearLocation(targets: targets, allReadyDevices: self.readyDevices, settings: self.settings, onStage: stage)
        }
    }
    private func progress(_ id: DeviceID, _ stage: EngineOperationStage) {
        busyMessage = [deviceStates[id]?.device?.name, stage.title].compactMap { $0 }.joined(separator: " · ")
    }
    private func operate(_ title: String, _ action: @MainActor ([TargetDevice], @escaping AppEnvironment.StageReport) async throws -> BatchOutcome) async {
        guard busyMessage == nil else { return }
        guard !targets.isEmpty else { feedback = .init(kind: .failure, title: "没有就绪的目标设备", detail: "请检查配对和通道连接。", rawLog: "readyTargets=0"); return }
        busyMessage = title
        defer { busyMessage = nil }
        do {
            let batch = targets
            let result = try await environment.withProgress(progress) { try await action(batch, $0) }
            finish(result, title: "定位操作完成")
        } catch { fail("定位操作失败", error) }
        await updateTunnelStatus()
    }
    private func finish(_ result: BatchOutcome, title: String) {
        state.records = result.records
        feedback = result.feedback(title: title)
        checkTimeZone()
    }
    private func saveCities(_ change: (inout [Place]) -> Void) async {
        let previous = cities, env = environment
        change(&state.cities)
        let updated = cities
        do { try await env.stateStore.saveCities(updated) }
        catch { if env === environment, cities == updated { state.cities = previous; fail("无法保存城市", error) } }
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
        } catch { fail("无法更新配对记录", error); throw error }
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
        let updated = settings
        let reset = previous.exitFeaturesEnabled != updated.exitFeaturesEnabled || previous.customProxyText != updated.customProxyText
        if reset { monitoring?.cancel(); following?.cancel(); exitRequest?.cancel(); (exit, pendingExitChange, exitError, exitRequest) = (nil, nil, nil, nil) }
        do {
            try await env.stateStore.saveSettings(updated)
            if previous.exitFeaturesEnabled && !updated.exitFeaturesEnabled { await env.exitMonitor.invalidateDisabledState() }
            guard env === environment, settings == updated else { return }
            if reset && updated.exitFeaturesEnabled { await refreshExit() }
            if reset || previous.watchMode != updated.watchMode { startMonitoring() }
        } catch { if env === environment, settings == updated { state.settings = previous; fail("无法保存设置", error); startMonitoring() } }
    }
    func markSplashSeen() async { await updateSettings { $0.hasSeenSplash = true } }
    func completeOnboarding() async { await updateSettings { $0.hasCompletedOnboarding = true } }
    func switchToDemo(_ enabled: Bool) async {
        guard enabled != isDemo, busyMessage == nil else { return }
        do {
            let next: AppEnvironment = enabled ? .demo() : try .live()
            monitoring?.cancel()
            exitRequest?.cancel()
            zoneCheck?.cancel()
            environment.notifier.onFollow = nil
            busyMessage = "正在切换模式"
            await environment.tunnelCoordinator.disconnectOwnedTunnelIfIdle()
            environment = next
            AppEnvironment.modePreferences.set(enabled, forKey: "ElsewhereDemoMode")
            (exit, pendingExitChange, exitError, exitRequest) = (nil, nil, nil, nil)
            state = AppStateStore.State(); loaded = false
            (pairingRecords, deviceStates, feedback, busyMessage) = ([], [:], nil, nil)
            await load()
            startMonitoring()
        } catch { fail("无法切换运行模式", error) }
    }
}
