import Foundation

struct Place: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var coordinate: WGS84Coordinate

    var displayName: String {
        Self.defaults.first { $0.id == id }?.name ?? name
    }

    static var defaults: [Place] {
        [
            (1, String(localized: "柏林"), 52.5200, 13.4050),
            (2, String(localized: "法兰克福"), 50.1109, 8.6821),
            (3, String(localized: "伦敦"), 51.5074, -0.1278),
            (4, String(localized: "巴黎"), 48.8566, 2.3522),
            (5, String(localized: "阿姆斯特丹"), 52.3676, 4.9041),
            (6, String(localized: "纽约"), 40.7580, -73.9855),
            (7, String(localized: "洛杉矶"), 34.0522, -118.2437),
            (8, String(localized: "旧金山"), 37.7749, -122.4194),
            (9, String(localized: "东京"), 35.6812, 139.7671),
            (10, String(localized: "香港"), 22.2800, 114.1588),
            (11, String(localized: "新加坡"), 1.2834, 103.8607),
        ].compactMap { (key: UInt8, name: String, latitude: Double, longitude: Double) in
            guard let coordinate = WGS84Coordinate(latitude: latitude, longitude: longitude) else { return nil }
            return Place(id: UUID(uuid: (0x62, 0x08, 0x52, 0xa9, 0xbd, 0xcd, 0x4c, 0xcc,
                                         0x8d, 0x4f, 0x42, 0xcb, 0x74, 0xad, 0x83, key)), name: name, coordinate: coordinate)
        }
    }
}

enum LocationSource: String, Codable, Hashable, Sendable {
    case exitIP, city, custom
}
