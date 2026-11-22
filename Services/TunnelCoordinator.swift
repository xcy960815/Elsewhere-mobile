import NetworkExtension

enum TunnelConnectionStatus: String, Equatable, Sendable {
    case disconnected, connecting, connected, disconnecting, unavailable
}

protocol TunnelProviderAdapter: Sendable {
    var hasPendingRecovery: Bool { get }
    func currentStatus() async -> TunnelConnectionStatus
    func connectedPeerHost() async throws -> String?
    func start(targetHost: String) async throws
    func stop() async
}

extension TunnelProviderAdapter {
    var hasPendingRecovery: Bool { false }
    func connectedPeerHost() async throws -> String? { nil }
}

struct SystemTunnelProviderAdapter: TunnelProviderAdapter {
    private let bundleIdentifier = "com.elsewhere.mobile.tunnel"
    private let sessionKey = "ElsewhereTunnelSessionID"
    var hasPendingRecovery: Bool { UserDefaults.standard.string(forKey: sessionKey) != nil }

    private func installedManager() async throws -> NETunnelProviderManager? {
        try await NETunnelProviderManager.loadAllFromPreferences().first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == bundleIdentifier
        }
    }

    func currentStatus() async -> TunnelConnectionStatus {
        do {
            guard let manager = try await installedManager() else { return .disconnected }
            switch manager.connection.status {
            case .invalid: return .unavailable
            case .disconnected: return .disconnected
            case .connecting, .reasserting: return .connecting
            case .connected: return .connected
            case .disconnecting: return .disconnecting
            @unknown default: return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    func connectedPeerHost() async throws -> String? {
        let configuration = try await installedManager()?.protocolConfiguration as? NETunnelProviderProtocol
        return configuration?.providerConfiguration?["peerAddress"] as? String ?? LoopbackTarget.defaultPeer
    }

    func start(targetHost: String) async throws {
        guard LoopbackTarget.addressBytes(targetHost) != nil else { throw NEVPNError(.configurationInvalid) }
        let manager = try await installedManager() ?? NETunnelProviderManager()
        let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        if !manager.isEnabled || configuration.includeAllNetworks || configuration.serverAddress != targetHost
            || configuration.providerConfiguration?["peerAddress"] as? String != targetHost {
            guard [.invalid, .disconnected].contains(manager.connection.status) else { throw NEVPNError(.connectionFailed) }
            configuration.providerBundleIdentifier = bundleIdentifier
            configuration.serverAddress = targetHost
            configuration.providerConfiguration = ["peerAddress": targetHost]
            configuration.includeAllNetworks = false
            manager.protocolConfiguration = configuration
            manager.localizedDescription = String(localized: "Elsewhere 通道")
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }
        guard let connection = manager.connection as? NETunnelProviderSession, [.disconnected, .invalid].contains(connection.status) else {
            throw NEVPNError(.connectionFailed)
        }
        let id = UUID().uuidString
        // 启动选项只属于这次会话，系统设置里手动重连的扩展会生成另一个 ID。
        UserDefaults.standard.set(id, forKey: sessionKey)
        do {
            try connection.startTunnel(options: ["sessionID": id])
            let deadline = ContinuousClock.now + .seconds(15)
            while connection.status != .connected {
                guard connection.status != .disconnecting else { throw NEVPNError(.connectionFailed) }
                guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            await stop()
            throw error
        }
    }

    private func matchesSession(_ session: NETunnelProviderSession, id: String) async -> Bool? {
        let message = Data(id.utf8)
        let replies = AsyncStream<Bool> { continuation in
            let timeout = Task {
                try await Task.sleep(for: .seconds(3))
                continuation.finish()
            }
            continuation.onTermination = { _ in timeout.cancel() }
            do {
                try session.sendProviderMessage(message) { reply in
                    if let reply { continuation.yield(reply == message) }
                    continuation.finish()
                }
            } catch {
                continuation.finish()
            }
        }
        var iterator = replies.makeAsyncIterator()
        return await iterator.next()
    }

    func stop() async {
        guard let id = UserDefaults.standard.string(forKey: sessionKey) else { return }
        let manager: NETunnelProviderManager?
        do { manager = try await installedManager() } catch { return }
        if let session = manager?.connection as? NETunnelProviderSession, ![.disconnected, .invalid].contains(session.status) {
            let connectedAt = session.connectedDate
            guard let owned = await matchesSession(session, id: id) else { return }
            if owned {
                guard session.connectedDate == connectedAt else { return }
                session.stopVPNTunnel()
                let deadline = ContinuousClock.now + .seconds(15)
                while session.status != .disconnected, session.status != .invalid {
                    guard ContinuousClock.now < deadline else { return }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
        }
        if UserDefaults.standard.string(forKey: sessionKey) == id { UserDefaults.standard.removeObject(forKey: sessionKey) }
    }
}

actor TunnelCoordinator {
    private let adapter: any TunnelProviderAdapter
    private var opening: (host: String, task: Task<Void, Error>)?
    private var closing: Task<Void, Never>?
    private var activePeerHost: String?
    private var peerWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    private(set) var activeLeases = 0
    private(set) var startedByUs = false
    private(set) var isSwitchingChannel = false

    init(adapter: any TunnelProviderAdapter = SystemTunnelProviderAdapter()) {
        self.adapter = adapter
    }

    func status() async -> TunnelConnectionStatus { await adapter.currentStatus() }

    func withChannel<T: Sendable>(mode: ChannelMode, targetHost: String, autoDisconnect: Bool,
                                  operation: @Sendable () async throws -> T) async throws -> T {
        guard mode == .builtInTunnel else { return try await operation() }
        while true {
            try Task.checkCancellation()
            if closing == nil {
                if let opening {
                    if opening.host == targetHost { break }
                } else if let activePeerHost, activePeerHost != targetHost, startedByUs || adapter.hasPendingRecovery {
                    beginDisconnectIfIdle()
                } else { break }
            }
            let id = UUID()
            let (stream, waiter) = AsyncStream<Void>.makeStream()
            peerWaiters[id] = waiter
            for await _ in stream {}
            peerWaiters[id] = nil
        }

        let ready = opening?.task ?? Task { try await connect(to: targetHost) }
        opening = (targetHost, ready)
        // 等待同一次启动的调用也占租约，避免先完成的操作提前断开通道。
        activeLeases += 1
        let result: Result<T, Error>
        do {
            defer {
                activeLeases -= 1
                if activeLeases == 0 {
                    opening = nil
                    wakePeerWaiters()
                }
            }
            try await ready.value
            try Task.checkCancellation()
            result = .success(try await operation())
        } catch {
            result = .failure(error)
        }
        if autoDisconnect, startedByUs { await disconnectOwnedTunnelIfIdle() }
        return try result.get()
    }

    private func connect(to host: String) async throws {
        var status = await adapter.currentStatus()
        let deadline = ContinuousClock.now + .seconds(15)
        while status == .connecting || status == .disconnecting {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(100))
            status = await adapter.currentStatus()
        }
        if status == .connected {
            let peer = try await adapter.connectedPeerHost() ?? activePeerHost
            if peer == nil || peer == host {
                activePeerHost = host
                return
            }
            guard adapter.hasPendingRecovery else { throw NEVPNError(.configurationInvalid) }
            await adapter.stop()
            guard await adapter.currentStatus() == .disconnected else { throw NEVPNError(.connectionFailed) }
        }
        activePeerHost = nil
        startedByUs = true
        isSwitchingChannel = true
        defer { isSwitchingChannel = false }
        do {
            try await adapter.start(targetHost: host)
            activePeerHost = host
        } catch {
            startedByUs = false
            throw error
        }
    }

    func disconnectOwnedTunnelIfIdle() async {
        beginDisconnectIfIdle()
        await closing?.value
    }

    private func wakePeerWaiters() {
        for waiter in peerWaiters.values { waiter.finish() }
        peerWaiters.removeAll()
    }

    private func beginDisconnectIfIdle() {
        guard closing == nil, activeLeases == 0, startedByUs || adapter.hasPendingRecovery else { return }
        isSwitchingChannel = true
        closing = Task {
            await adapter.stop()
            startedByUs = false
            activePeerHost = nil
            isSwitchingChannel = false
            closing = nil
            wakePeerWaiters()
        }
    }
}
