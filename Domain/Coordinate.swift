import CoreLocation
import Foundation

struct WGS84Coordinate: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    init?(latitude: Double, longitude: Double) {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let coordinate = try Self(latitude: values.decode(Double.self, forKey: .latitude),
                                        longitude: values.decode(Double.self, forKey: .longitude)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "无效的 WGS-84 坐标"))
        }
        self = coordinate
    }

    var clCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    private static let locale = Locale(identifier: "en_US_POSIX")
    var formatted: String { String(format: "%.4f, %.4f", locale: Self.locale, latitude, longitude) }
    var preciseLatitude: String { String(format: "%.6f", locale: Self.locale, latitude) }
    var preciseLongitude: String { String(format: "%.6f", locale: Self.locale, longitude) }

    func isSameSpot(as other: Self) -> Bool {
        abs(latitude - other.latitude) < 0.0001 && abs(longitude - other.longitude) < 0.0001
    }
}

enum CoordinateParseError: LocalizedError, Equatable, Sendable {
    case empty, invalidFormat, latitudeOutOfRange, longitudeOutOfRange

    var errorDescription: String? {
        switch self {
        case .empty: String(localized: "请输入纬度和经度")
        case .invalidFormat: String(localized: "请用逗号或空格分隔两个有效数字")
        case .latitudeOutOfRange: String(localized: "纬度须在 -90 到 90 之间")
        case .longitudeOutOfRange: String(localized: "经度须在 -180 到 180 之间")
        }
    }
}

enum CoordinateParser: Sendable {
    static func parse(_ text: String) -> Result<WGS84Coordinate, CoordinateParseError> {
        guard !text.allSatisfy(\.isWhitespace) else { return .failure(.empty) }
        let fields = text.split(omittingEmptySubsequences: false) { $0 == "," || $0 == "，" }
        let parts = fields.count == 1 ? text.split(whereSeparator: \.isWhitespace) : fields
        guard parts.count == 2,
              let latitude = Double(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)), latitude.isFinite,
              let longitude = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)), longitude.isFinite else {
            return .failure(.invalidFormat)
        }
        guard let coordinate = WGS84Coordinate(latitude: latitude, longitude: longitude) else {
            return .failure(abs(latitude) > 90 ? .latitudeOutOfRange : .longitudeOutOfRange)
        }
        return .success(coordinate)
    }

    static func parse(latitudeText: String, longitudeText: String) -> Result<WGS84Coordinate, CoordinateParseError> {
        let latitude = latitudeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if latitude.contains(where: { $0 == "," || $0 == "，" || $0.isWhitespace }) { return parse(latitude) }
        guard !latitude.isEmpty, !longitudeText.allSatisfy(\.isWhitespace) else { return .failure(.empty) }
        return parse("\(latitude),\(longitudeText)")
    }
}
