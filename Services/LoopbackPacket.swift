import Darwin
import Foundation

enum LoopbackTarget: Equatable, Sendable {
    case ipv4(local: String, peer: String)
    case ipv6(local: String, peer: String)

    static let defaultPeer = "10.7.0.1"

    static func parse(peer: String = defaultPeer) -> Self? {
        guard var local = addressBytes(peer) else { return nil }
        let ipv4 = local.count == 4
        if ipv4 {
            // /30 的两个主机位只取 01 或 10，避开网络地址和广播地址。
            let last = local[3]
            local[3] = (last & 0xfc) | (last.isMultiple(of: 2) ? 1 : 2)
        } else {
            local[15] ^= 1
        }
        let address = withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(INET6_ADDRSTRLEN)) { buffer in
            local.withUnsafeBytes {
                String(cString: inet_ntop(ipv4 ? AF_INET : AF_INET6, $0.baseAddress, buffer.baseAddress, socklen_t(buffer.count))!)
            }
        }
        return ipv4 ? .ipv4(local: address, peer: peer) : .ipv6(local: address, peer: peer)
    }

    static func addressBytes(_ address: String) -> Data? {
        guard !address.utf8.contains(0) else { return nil }
        let ipv6 = address.contains(":")
        var bytes = Data(count: ipv6 ? 16 : 4)
        let parsed = bytes.withUnsafeMutableBytes { inet_pton(ipv6 ? AF_INET6 : AF_INET, address, $0.baseAddress) }
        return parsed == 1 ? bytes : nil
    }
}

enum LoopbackPacket: Sendable {
    static func rewrite(_ packet: Data, protocolFamily: Int32, localBytes: Data, peerBytes: Data) -> Data? {
        let start = packet.startIndex
        let source, destination: Range<Int>
        switch protocolFamily {
        case AF_INET:
            guard packet.count >= 20, packet[start] >> 4 == 4 else { return nil }
            let headerLength = Int(packet[start] & 0x0f) * 4
            let totalLength = Int(packet[start + 2]) << 8 | Int(packet[start + 3])
            guard headerLength >= 20, headerLength <= totalLength, totalLength <= packet.count else { return nil }
            source = (start + 12)..<(start + 16)
            destination = (start + 16)..<(start + 20)
        case AF_INET6:
            guard packet.count >= 40, packet[start] >> 4 == 6 else { return nil }
            let payloadLength = Int(packet[start + 4]) << 8 | Int(packet[start + 5])
            guard 40 + payloadLength <= packet.count else { return nil }
            source = (start + 8)..<(start + 24)
            destination = (start + 24)..<(start + 40)
        default:
            return nil
        }
        guard packet[source] == localBytes, packet[destination] == peerBytes else { return nil }
        // 互换地址仅改变 16 位加数的顺序，IPv4 首部和 TCP/UDP 伪首部的一补数和保持不变。
        var result = packet
        result[source] = peerBytes
        result[destination] = localBytes
        return result
    }
}
