import Foundation

struct DeviceID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    var description: String { rawValue }

    init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        self.rawValue = value
    }
}

struct OSVersion: Codable, Hashable, Sendable, Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ string: String) {
        let fields = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(fields.count) else { return nil }
        let numbers = fields.compactMap { $0.allSatisfy(\.isNumber) ? Int($0) : nil }
        guard numbers.count == fields.count else { return nil }
        major = numbers[0]
        minor = numbers[1]
        patch = fields.count == 3 ? numbers[2] : 0
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        major = try values.decode(Int.self, forKey: .major)
        minor = try values.decode(Int.self, forKey: .minor)
        patch = try values.decode(Int.self, forKey: .patch)
        guard major >= 0, minor >= 0, patch >= 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "系统版本不能包含负数"))
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var preferredTransport: TargetTransport {
        if major < 17 { return .unsupported }
        return major == 17 && minor < 4 ? .remotePairing : .coreDeviceProxy
    }
}

enum TargetTransport: UInt8, Codable, Hashable, Sendable {
    case unsupported = 0, remotePairing = 1, coreDeviceProxy = 2
}

enum ChannelMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case existingRoute, builtInTunnel
    var id: String { rawValue }
}

struct TargetDevice: Codable, Identifiable, Hashable, Sendable {
    let id: DeviceID
    let name: String
    let deviceClass: String
    let productType: String?
    let osVersion: OSVersion?
    let endpointHost: String
    let paired: Bool
    let developerMode: Bool?
    let wifiEnabled: Bool?
    let timeZoneID: String?
    let cellular: Bool?
    let ddiMounted: Bool?

    var kind: String { deviceClass == "iPad" ? "iPad" : "iPhone" }
    var isReady: Bool { paired && developerMode != false }
}

enum AppliedConfidence: String, Codable, Hashable, Sendable {
    case confirmed, lastSet, unknownOutcome
}

struct AppliedLocationRecord: Codable, Equatable, Sendable {
    let deviceID: DeviceID
    let deviceName: String
    let name: String
    let coordinate: WGS84Coordinate
    let appliedAt: Date
    let source: LocationSource
    let exitIP: String?
    let confidence: AppliedConfidence
}
