import BackgroundTasks
import Foundation
import Network

enum ExitRefreshOutcome: Equatable, Sendable {
    case disabled
    case unchanged(ExitInfo?)
    case updated(ExitInfo)
    case discrepancy(probeIP: String, detailIP: String)
    case pendingChange(ExitInfo)
    case autoFollowed(ExitInfo, BatchOutcome)
    case failed(String)
}

actor ExitMonitorService {
    private enum Refresh { case manual, change }

    private let exitService: ExitIPService
    private let commandService: CommandService
    private let tunnel: TunnelCoordinator
    private let notifier: Notifier
    private let stateStore: AppStateStore
    private let now: @Sendable () -> Date
    private(set) var lastConfirmedIP: String?
    private(set) var lastExit: ExitInfo?
    private(set) var lastFetchedAt: Date?
    private(set) var pendingRetryIP: String?
    private var inFlight: (kind: Refresh, task: Task<ExitRefreshOutcome, Never>)?
    private var foreground: Task<Void, Never>?

    init(exitService: ExitIPService, commandService: CommandService, tunnel: TunnelCoordinator,
         notifier: Notifier, stateStore: AppStateStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.exitService = exitService
        self.commandService = commandService
        self.tunnel = tunnel
        self.notifier = notifier
        self.stateStore = stateStore
        self.now = now
    }

    func refreshManually(settings: AppSettings, proxy: ExitProxyAddress?) async -> ExitRefreshOutcome {
        guard settings.exitFeaturesEnabled else {
            await invalidateDisabledState()
            return .disabled
        }
        inFlight?.task.cancel()
        return await run(.manual) { monitor in
            let settings = try await monitor.stateStore.load().settings
            try Task.checkCancellation()
            guard settings.exitFeaturesEnabled else {
                await monitor.invalidateDisabledState()
                return .disabled
            }
            let exit = try await monitor.exitService.lookup(proxy: proxy)
            try await monitor.confirm(exit)
            return .updated(exit)
        }
    }

    func handleForegroundReturn(settings: AppSettings, proxy: ExitProxyAddress?) async -> ExitRefreshOutcome? {
        guard settings.exitFeaturesEnabled else {
            await invalidateDisabledState()
            return nil
        }
        if let lastFetchedAt, now().timeIntervalSince(lastFetchedAt) <= 60 { return nil }
        return await refreshManually(settings: settings, proxy: proxy)
    }

    func checkChange(settings: AppSettings, proxy: ExitProxyAddress?, targets: [TargetDevice],
                     isBackground: Bool = false) async -> ExitRefreshOutcome {
        guard settings.exitFeaturesEnabled else {
            await invalidateDisabledState()
            return .disabled
        }
        guard settings.watchMode != .off else {
            if inFlight?.kind == .change { inFlight?.task.cancel() }
            return .disabled
        }
        guard inFlight == nil else { return .unchanged(lastExit) }
        return await run(.change) { monitor in
            guard !(await monitor.tunnel.isSwitchingChannel) else { return .unchanged(monitor.lastExit) }
            let initial = try await monitor.stateStore.load().settings
            try Task.checkCancellation()
            guard initial.exitFeaturesEnabled else {
                await monitor.invalidateDisabledState()
                return .disabled
            }
            guard initial.watchMode != .off else { return .disabled }
            let revision = await monitor.commandService.manualRevision
            let ip = try await monitor.exitService.currentIP(proxy: proxy)
            try Task.checkCancellation()
            let needsDetail = ExitPolicy.shouldFetchDetail(featuresEnabled: settings.exitFeaturesEnabled, watchMode: settings.watchMode,
                                                           previousIP: monitor.lastConfirmedIP, observedIP: ip)
            guard needsDetail || monitor.pendingRetryIP == ip else {
                monitor.lastConfirmedIP = ip
                monitor.pendingRetryIP = nil
                return .unchanged(monitor.lastExit)
            }
            monitor.pendingRetryIP = ip
            let exit = try await monitor.exitService.lookup(proxy: proxy)
            let state = try await monitor.stateStore.load()
            try Task.checkCancellation()
            guard state.settings.exitFeaturesEnabled else {
                await monitor.invalidateDisabledState()
                return .disabled
            }
            let current = state.settings == initial ? settings : state.settings
            let decision = ExitPolicy.decide(featuresEnabled: current.exitFeaturesEnabled, watchMode: current.watchMode,
                previousIP: monitor.lastConfirmedIP, probeIP: ip, fetchedExit: exit, targetDeviceIDs: targets.map(\.id), records: state.records)
            switch decision {
            case .ignore(.watchOff), .ignore(.disabled): return .disabled
            case .ignore: return .unchanged(monitor.lastExit)
            case .notifyDiscrepancy(let probeIP, let detailIP):
                monitor.notifier.post(title: String(localized: "出口 IP 不一致"),
                                      body: String(localized: "检测到 \(probeIP)，位置服务报告 \(detailIP)。请核对网络路径。"))
                return .discrepancy(probeIP: probeIP, detailIP: detailIP)
            case .evaluateTargets(_, let actions):
                try await monitor.confirm(exit)
                return try await monitor.handleChange(exit, actions: actions, targets: targets, settings: current,
                                                      proxy: proxy, revision: revision, isBackground: isBackground)
            }
        }
    }

    private func handleChange(_ exit: ExitInfo, actions: [DeviceID: TargetExitAction], targets: [TargetDevice],
                              settings: AppSettings, proxy: ExitProxyAddress?, revision: UInt64, isBackground: Bool) async throws -> ExitRefreshOutcome {
        let automatic = targets.filter { actions[$0.id] == .autoApply }
        var pending = targets.filter { actions[$0.id] == .notify }
        var outcome: BatchOutcome?
        if !automatic.isEmpty {
            var route = settings
            if isBackground, settings.channelMode == .builtInTunnel, await tunnel.status() != .connected {
                pending += automatic
            } else {
                // 状态检查后通道仍可能断开。后台沿已有路由下发，不能让租约重新启动 VPN。
                if isBackground { route.channelMode = .existingRoute }
                outcome = try await Self.followIfCurrent(commandService, revision: revision, exit: exit, targets: automatic, settings: route, proxy: proxy)
                if let outcome {
                    if isBackground { pending += outcome.failed.map(\.device) }
                } else { pending += automatic }
            }
        }
        let live = try await stateStore.load().settings
        try Task.checkCancellation()
        guard live.exitFeaturesEnabled else {
            await invalidateDisabledState()
            return .disabled
        }
        guard live.watchMode != .off else { return .disabled }
        if !pending.isEmpty {
            let names = pending.map(\.name).joined(separator: "、")
            notifier.post(title: String(localized: "代理出口变了"),
                          body: String(localized: "\(names)：\(exit.displayCity)（\(exit.ip)）"), category: Notifier.exitChangedCategory)
        }
        if let outcome { return .autoFollowed(exit, outcome) }
        return pending.isEmpty ? .updated(exit) : .pendingChange(exit)
    }

    private static func followIfCurrent(_ service: isolated CommandService, revision: UInt64, exit: ExitInfo, targets: [TargetDevice],
                                        settings: AppSettings, proxy: ExitProxyAddress?) async throws -> BatchOutcome? {
        try Task.checkCancellation()
        guard service.manualRevision == revision else { return nil }
        let (_, outcome) = try await service.followExit(prefetched: exit, targets: targets, settings: settings, proxy: proxy, isAutomatic: true)
        return outcome.succeeded.isEmpty && outcome.unknown.isEmpty && outcome.failed.isEmpty ? nil : outcome
    }

    private func confirm(_ exit: ExitInfo) async throws {
        let date = now()
        try await stateStore.saveExitSnapshot(exit, at: date)
        try Task.checkCancellation()
        lastConfirmedIP = exit.ip
        lastExit = exit
        lastFetchedAt = date
        pendingRetryIP = nil
    }

    private func run(_ kind: Refresh, operation: @escaping @Sendable (isolated ExitMonitorService) async throws -> ExitRefreshOutcome) async -> ExitRefreshOutcome {
        let task = Task {
            do {
                try Task.checkCancellation()
                return try await operation(self)
            } catch is CancellationError {
                if (try? await stateStore.load().settings.exitFeaturesEnabled) == false, !Task.isCancelled {
                    await invalidateDisabledState()
                    return .disabled
                }
                return .unchanged(lastExit)
            } catch {
                return Task.isCancelled ? .unchanged(lastExit) : .failed(error.localizedDescription)
            }
        }
        inFlight = (kind, task)
        defer { if inFlight?.task == task { inFlight = nil } }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func invalidateDisabledState() async {
        inFlight?.task.cancel()
        inFlight = nil
        stopForegroundMonitoring()
        lastExit = nil
        lastConfirmedIP = nil
        lastFetchedAt = nil
        pendingRetryIP = nil
        try? await stateStore.saveExitSnapshot(nil, at: now())
    }

    func startForegroundMonitoring(context: @escaping @Sendable () async -> (AppSettings, ExitProxyAddress?, [TargetDevice])) {
        stopForegroundMonitoring()
        foreground = Task { [weak self, tunnel] in
            let (initial, _, _) = await context()
            guard !Task.isCancelled, initial.exitFeaturesEnabled, initial.watchMode != .off else { return }
            let paths = NWPathMonitor()
            let (events, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            paths.pathUpdateHandler = { _ in
                Task { if !(await tunnel.isSwitchingChannel) { signal.yield(()) } }
            }
            paths.start(queue: DispatchQueue(label: "com.elsewhere.mobile.exit-path"))
            let timer = Task {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(30))
                    signal.yield(())
                }
            }
            defer { timer.cancel(); paths.cancel(); signal.finish() }
            for await _ in events {
                let (settings, proxy, devices) = await context()
                guard let self, !Task.isCancelled else { return }
                _ = await self.checkChange(settings: settings, proxy: proxy, targets: devices)
                if settings.watchMode == .off { return }
            }
        }
    }

    func stopForegroundMonitoring() {
        foreground?.cancel()
        foreground = nil
    }

    @MainActor func handleBackgroundRefresh(_ task: BGAppRefreshTask, settings: AppSettings, proxy: ExitProxyAddress?, targets: [TargetDevice]) {
        let (completion, result) = AsyncStream<Bool>.makeStream()
        let check = Task {
            let outcome = await checkChange(settings: settings, proxy: proxy, targets: targets, isBackground: true)
            if case .failed = outcome { result.yield(false) }
            else { result.yield(!Task.isCancelled) }
            result.finish()
        }
        task.expirationHandler = { @Sendable in
            result.finish()
            check.cancel()
        }
        Task {
            var iterator = completion.makeAsyncIterator()
            task.setTaskCompleted(success: await iterator.next() ?? false)
        }
    }
}
