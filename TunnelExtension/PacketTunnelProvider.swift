import NetworkExtension
import os

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    // 系统可在停止后交付上一次读取的回调，写回和续读须与会话切换互斥。
    private let session = OSAllocatedUnfairLock<UUID?>(initialState: nil)

    override func startTunnel(options: [String: NSObject]?) async throws {
        let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let value = options?["peerAddress"] ?? configuration?["peerAddress"] ?? LoopbackTarget.defaultPeer
        guard !protocolConfiguration.includeAllNetworks, let peer = value as? String, let target = LoopbackTarget.parse(peer: peer) else {
            throw NEVPNError(.configurationInvalid)
        }
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: peer)
        let local: String
        switch target {
        case .ipv4(let address, _):
            local = address
            let mask = "255.255.255.255"
            let ipv4 = NEIPv4Settings(addresses: [local], subnetMasks: [mask])
            ipv4.includedRoutes = [NEIPv4Route(destinationAddress: peer, subnetMask: mask)]
            settings.ipv4Settings = ipv4
        case .ipv6(let address, _):
            local = address
            let ipv6 = NEIPv6Settings(addresses: [local], networkPrefixLengths: [128])
            ipv6.includedRoutes = [NEIPv6Route(destinationAddress: peer, networkPrefixLength: 128)]
            settings.ipv6Settings = ipv6
        }
        settings.mtu = 1500
        let id = (options?["sessionID"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        session.withLock { $0 = id }
        try await setTunnelNetworkSettings(settings)
        try session.withLock { current in
            guard current == id else { throw CancellationError() }
            readPackets(id: id, local: LoopbackTarget.addressBytes(local)!, peer: LoopbackTarget.addressBytes(peer)!)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        session.withLock { $0 = nil }
        try? await setTunnelNetworkSettings(nil)
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        session.withLock { id in
            guard let id else { return nil }
            return messageData == Data(id.uuidString.utf8) ? messageData : Data()
        }
    }

    private func readPackets(id: UUID, local: Data, peer: Data) {
        packetFlow.readPackets { [weak self] packets, families in
            guard let self else { return }
            session.withLock { current in
                guard current == id else { return }
                var replies: [Data] = [], protocols: [NSNumber] = []
                for (packet, family) in zip(packets, families) {
                    if let reply = LoopbackPacket.rewrite(packet, protocolFamily: family.int32Value, localBytes: local, peerBytes: peer) {
                        replies.append(reply)
                        protocols.append(family)
                    }
                }
                if !replies.isEmpty, !self.packetFlow.writePackets(replies, withProtocols: protocols) {
                    self.cancelTunnelWithError(NEVPNError(.connectionFailed))
                    return
                }
                self.readPackets(id: id, local: local, peer: peer)
            }
        }
    }
}
