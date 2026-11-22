import Combine
import Foundation
import Network
import UserNotifications

@MainActor
final class AppEnvironment: ObservableObject {
    static let modePreferences = UserDefaults(suiteName: AppIdentifiers.current.modePreferencesSuite) ?? .standard
    let capabilities: AppCapabilities
    let engine: any LocationEngineProtocol
    let pairingStore: PairingStore
    let tunnelCoordinator: TunnelCoordinator
    let stateStore: AppStateStore
    let exitService: ExitIPService
    let notifier: Notifier
    let commandService: CommandService
    let exitMonitor: ExitMonitorService
    var isDemo: Bool { engine is DemoLocationEngine }
    var demoDeviceID: DeviceID { DemoLocationEngine.defaultDevice.id }
    var abiVersion: UInt32 { engine.abiVersion }

    init(engine: any LocationEngineProtocol, pairingStore: PairingStore, tunnel: TunnelCoordinator,
         stateStore: AppStateStore, exitService: ExitIPService, notifier: Notifier, capabilities: AppCapabilities = .current) {
        self.capabilities = capabilities
        self.engine = engine
        self.pairingStore = pairingStore
        tunnelCoordinator = tunnel
        self.stateStore = stateStore
        self.exitService = exitService
        self.notifier = notifier
        commandService = CommandService(engine: engine, tunnel: tunnel, stateStore: stateStore, exitService: exitService)
        exitMonitor = ExitMonitorService(exitService: exitService, commandService: commandService, tunnel: tunnel,
                                         notifier: notifier, stateStore: stateStore)
    }

    static func demo() -> AppEnvironment {
        let pairings = PairingStore(baseDirectory: URL.temporaryDirectory.appending(path: UUID().uuidString),
                                    keyProvider: InMemoryPairingKeyProvider(), inspector: RustLocationEngine.makePairingInspector())
        return AppEnvironment(engine: DemoLocationEngine(), pairingStore: pairings, tunnel: TunnelCoordinator(adapter: DemoTunnel()),
                              stateStore: AppStateStore(storageDirectory: nil), exitService: ExitIPService(transport: DemoExit()),
                              notifier: Notifier(center: DemoNotifications()))
    }

    static func live() throws(EngineError) -> AppEnvironment {
        let pairings = PairingStore(inspector: RustLocationEngine.makePairingInspector())
        let engine = RustLocationEngine(handle: try RustEngineHandle(), pairingStore: pairings,
                                        ddiRepository: DDIRepository(verifier: RustLocationEngine.makeDDIVerifier()))
        return AppEnvironment(engine: engine, pairingStore: pairings, tunnel: TunnelCoordinator(),
                              stateStore: AppStateStore(), exitService: ExitIPService(), notifier: Notifier())
    }

    func monitorExit(context: @escaping @MainActor () -> (AppSettings, ExitProxyAddress?, [TargetDevice]),
                     receive: @escaping @MainActor (ExitRefreshOutcome) -> Void) -> Task<Void, Never> {
        Task {
            await notifier.requestAuthorizationIfNeeded()
            guard !Task.isCancelled else { return }
            let (events, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let paths = NWPathMonitor()
            paths.pathUpdateHandler = { [tunnelCoordinator] _ in
                Task { if !(await tunnelCoordinator.isSwitchingChannel) { signal.yield(()) } }
            }
            paths.start(queue: DispatchQueue(label: AppIdentifiers.current.hostBundleID + ".foreground-path"))
            let timer = Task {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(30))
                    signal.yield(())
                }
            }
            defer { timer.cancel(); paths.cancel(); signal.finish() }
            for await _ in events {
                guard !Task.isCancelled else { return }
                let (settings, proxy, targets) = context()
                let outcome = await exitMonitor.checkChange(settings: settings, proxy: proxy, targets: targets)
                guard !Task.isCancelled else { return }
                receive(outcome)
            }
        }
    }

    typealias StageReport = @Sendable (DeviceID, EngineOperationStage) -> Void

    func withProgress<T>(_ progress: @escaping @MainActor (DeviceID, EngineOperationStage) -> Void,
                         operation: @MainActor (@escaping StageReport) async throws -> T) async rethrows -> T {
        let (events, signal) = AsyncStream<(DeviceID, EngineOperationStage)>.makeStream()
        let display = Task {
            for await (id, stage) in events {
                guard !Task.isCancelled else { return }
                progress(id, stage)
            }
        }
        defer { signal.finish(); display.cancel() }
        let result = try await operation { signal.yield(($0, $1)) }
        signal.finish()
        await display.value
        return result
    }

    func checkTimeZone(record: AppliedLocationRecord, device: TargetDevice) async -> TimeZoneMatchResult {
        guard device.timeZoneID != nil else { return .unavailable }
        let place = isDemo ? nil : await Geo.place(at: record.coordinate)
        return TimeZoneService.evaluate(record: record, device: device, targetTimeZone: place?.zone)
    }

    func startFollowing(_ sample: ExitInfo?, latest: ExitInfo?, targets: [TargetDevice], settings: AppSettings,
                        onStage: @escaping StageReport) -> Task<(ExitInfo, BatchOutcome), Error> {
        Task {
            guard settings.exitFeaturesEnabled else {
                throw EngineError(code: .cancelled, stage: "exit", message: String(localized: "出口功能已关闭，请先在设置中开启。"))
            }
            if let sample, sample.sampledAt.timeIntervalSinceNow < -60 || latest.map({ $0.sampledAt > sample.sampledAt && $0.ip != sample.ip }) == true {
                throw EngineError(code: .cancelled, stage: "exit", message: String(localized: "这次出口变化已过期，请刷新出口后再跟随。"))
            }
            return try await commandService.followExit(prefetched: sample, targets: targets, settings: settings,
                                                       proxy: settings.parsedProxy.get(), onStage: onStage)
        }
    }

    func probe(_ id: DeviceID, host: String, settings: AppSettings) async -> (DeviceID, DeviceConnectionState, EngineError?) {
        do {
            let device = try await commandService.probe(deviceID: id, endpointHost: host, settings: settings)
            return (device.id, DeviceStateMachine.reduce(state: .probing, event: .probeSucceeded(device)), nil)
        } catch {
            let event: DeviceStateEvent = switch error.code {
            case .locked: .probeFailedLocked(error.message)
            case .not_paired: .probeFailedNotPaired(error.message)
            case .tunnel_unavailable, .not_found: .probeFailedChannel(error.message)
            default: .probeFailedOther(error.message)
            }
            return (id, DeviceStateMachine.reduce(state: .probing, event: event), error)
        }
    }
}

private actor DemoTunnel: TunnelProviderAdapter {
    private var status = TunnelConnectionStatus.disconnected
    func currentStatus() -> TunnelConnectionStatus { status }
    func start(targetHost: String) { status = .connected }
    func stop() { status = .disconnected }
}

private struct DemoExit: HTTPDataTransport {
    func data(for request: URLRequest, proxy: ExitProxyAddress?) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let city = String(localized: "东京")
        let payload = url.path == "/json"
            ? #"{"ip":"203.0.113.24","city":"\#(city)","country":"JP","loc":"35.6812,139.7671","org":"AS64496 Demo"}"#
            : "203.0.113.24"
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badServerResponse)
        }
        return (Data(payload.utf8), response)
    }
}

private struct DemoNotifications: NotificationCenterAdapter {
    func register(delegate: UNUserNotificationCenterDelegate) {}
    func authorizationStatus() async -> UNAuthorizationStatus { .denied }
    func requestAuthorization() async {}
    func post(_ content: UNNotificationContent) {}
}

extension AppSettings {
    var parsedProxy: Result<ExitProxyAddress?, ExitProxyParseError> {
        customProxyText.allSatisfy(\.isWhitespace) ? .success(nil) : ExitProxyAddress.parse(customProxyText).map(Optional.some)
    }
}

private extension DeviceID {
    init(pairingID: UUID) { rawValue = pairingID.uuidString }
}

extension StoredPairingRecord {
    var probeID: DeviceID { udid ?? DeviceID(pairingID: id) }
}

extension DeviceConnectionState {
    var diagnosis: String {
        switch self {
        case .unpaired: String(localized: "尚未配对")
        case .probing: String(localized: "正在探测")
        case .channelUnavailable(let detail): String(localized: "通道不可用 · ") + detail
        case .notPaired(let detail): String(localized: "配对失效 · ") + detail
        case .locked(let detail): String(localized: "请先解锁设备 · ") + detail
        case .failed(let detail): String(localized: "设备异常 · ") + detail
        case .developerModeOff: String(localized: "请开启开发者模式")
        case .preparingDDI: String(localized: "正在准备开发者组件")
        case .ready: String(localized: "设备就绪")
        case .operating: String(localized: "正在操作")
        }
    }
}

extension EngineOperationStage {
    var title: String {
        switch self {
        case .connecting: String(localized: "正在连接设备")
        case .downloadingDDI: String(localized: "正在下载开发者组件")
        case .verifyingDDI: String(localized: "正在校验开发者组件")
        case .signingDDI: String(localized: "正在签名开发者组件")
        case .uploadingDDI: String(localized: "正在传输开发者组件")
        case .mountingDDI: String(localized: "正在挂载开发者组件")
        case .applyingLocation: String(localized: "正在设置模拟位置")
        case .clearingLocation: String(localized: "正在恢复真实定位")
        }
    }
}

extension BatchOutcome {
    func feedback(title: String) -> FeedbackMessage {
        let errors = failed.map { String(localized: "\($0.device.name) · \($0.error.message)") }
            + unknown.map { String(localized: "\($0.name) · 设备回执缺失，定位结果待确认") }
        var details = succeeded.map { device in
            let location = records[device.id]?.name ?? String(localized: "已恢复真实定位")
            return String(localized: "\(device.name) · \(location)")
        }
        if succeeded.contains(where: { records[$0.id] == nil && $0.kind == "iPad" && $0.cellular == false }) {
            details.append(String(localized: "Wi-Fi iPad 重新取得真实位置可能需要片刻。"))
        }
        if !errors.isEmpty {
            let logs = failed.map { [$0.error.stage, $0.error.rawDetail ?? $0.error.message].joined(separator: " · ") }
            return .init(kind: .failure, title: String(localized: "部分或全部设备未确认成功"), detail: (details + errors).joined(separator: "\n"),
                         rawLog: (logs + unknown.map { String(localized: "\($0.name) · 未收到回执") }).joined(separator: "\n"))
        }
        return succeeded.isEmpty ? .init(kind: .info, title: String(localized: "本次未更改定位")) :
            .init(kind: .success, title: title, detail: details.joined(separator: "\n"))
    }
}
