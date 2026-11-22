import XCTest
@testable import ElsewhereMobile

let coordinateValidityCases: [(latitude: Double, longitude: Double, valid: Bool)] = [
    (-90, -180, true), (-90, 180, true), (90, -180, true), (90, 180, true), (0, 0, true),
    (-90.0001, 0, false), (90.0001, 0, false), (0, -180.0001, false), (0, 180.0001, false),
    (.nan, 0, false), (0, .nan, false), (.infinity, 0, false), (-.infinity, 0, false),
    (0, .infinity, false), (0, -.infinity, false),
]

final class CoordinateAndProxyParsingTests: XCTestCase {
    func testWGS84BoundsAndNonFiniteNumbers() {
        for (latitude, longitude, valid) in coordinateValidityCases {
            XCTAssertEqual(WGS84Coordinate(latitude: latitude, longitude: longitude) != nil, valid, "\(latitude), \(longitude)")
        }
    }

    func testWGS84DecodingValidatesExternalNumbers() throws {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        for json in [#"{"latitude":91,"longitude":0}"#, #"{"latitude":0,"longitude":-181}"#,
                     #"{"latitude":"nan","longitude":1}"#, #"{"latitude":1,"longitude":"inf"}"#,
                     #"{"latitude":"-inf","longitude":0}"#, #"{"latitude":null,"longitude":0}"#,
                     #"{"latitude":42}"#, #"{"latitude":"1","longitude":2}"#] {
            XCTAssertThrowsError(try decoder.decode(WGS84Coordinate.self, from: Data(json.utf8)), json)
        }
        let corner = try XCTUnwrap(WGS84Coordinate(latitude: -90, longitude: 180))
        XCTAssertEqual(try decoder.decode(WGS84Coordinate.self, from: JSONEncoder().encode(corner)), corner)
    }

    func testCoordinateSeparatorsAndPastedPair() throws {
        let coordinate = try XCTUnwrap(WGS84Coordinate(latitude: 22.5431, longitude: 114.0579))
        for input in ["22.5431,114.0579", "22.5431，114.0579", "22.5431 114.0579",
                      " \t22.5431\t \n114.0579 ", "22.5431 \t，\n 114.0579"] {
            XCTAssertEqual(CoordinateParser.parse(input), .success(coordinate), input)
            XCTAssertEqual(CoordinateParser.parse(latitudeText: input, longitudeText: ""), .success(coordinate), input)
        }
        XCTAssertEqual(CoordinateParser.parse(latitudeText: " 22.5431 ", longitudeText: "114.0579"), .success(coordinate))
        XCTAssertEqual(CoordinateParser.parse(latitudeText: "22.5431,114.0579", longitudeText: "0"), .success(coordinate))
    }

    func testInvalidCoordinatesReportTheFieldOrFormat() {
        let cases: [(String, CoordinateParseError)] = [
            ("", .empty), (" \n\t", .empty), ("nan,1", .invalidFormat), ("1 -inf", .invalidFormat),
            ("inf，2", .invalidFormat), ("1,2,3", .invalidFormat), ("1 2 3", .invalidFormat),
            ("1,,2", .invalidFormat), ("1,", .invalidFormat), (",2", .invalidFormat),
            ("-90.1,0", .latitudeOutOfRange), ("91,0", .latitudeOutOfRange),
            ("0,-180.1", .longitudeOutOfRange), ("0,181", .longitudeOutOfRange),
        ]
        for (input, error) in cases {
            XCTAssertEqual(CoordinateParser.parse(input), .failure(error), input)
        }
        XCTAssertEqual(CoordinateParser.parse(latitudeText: "", longitudeText: "1"), .failure(.empty))
        XCTAssertEqual(CoordinateParser.parse(latitudeText: "1", longitudeText: " "), .failure(.empty))
        XCTAssertEqual(CoordinateParser.parse(latitudeText: "1，2，3", longitudeText: ""), .failure(.invalidFormat))
    }

    func testProxyHostsPortsAndJSONRoundTrip() throws {
        let cases = [("192.0.2.1:8080", "192.0.2.1", 8080), ("proxy.example:1", "proxy.example", 1),
                     ("proxy.example.:65535", "proxy.example.", 65535), ("[2001:db8::1]:443", "2001:db8::1", 443)]
        for (input, host, port) in cases {
            let address = try ExitProxyAddress.parse(input).get()
            XCTAssertEqual(address.host, host)
            XCTAssertEqual(address.port, port)
            XCTAssertEqual(address.display, input)
            let data = try JSONEncoder().encode(address)
            XCTAssertEqual(try JSONDecoder().decode(String.self, from: data), input)
            XCTAssertEqual(try JSONDecoder().decode(ExitProxyAddress.self, from: data), address)
        }
    }

    func testInvalidProxyAddresses() {
        let cases: [(String, ExitProxyParseError)] = [
            ("", .empty), (":8080", .emptyHost), ("[]:80", .emptyHost), ("proxy.example", .missingPort),
            ("proxy.example:", .missingPort), ("[2001:db8::1]", .missingPort), ("2001:db8::1:80", .invalidHost),
            ("999.999.999.999:8080", .invalidHost), ("代理.example:80", .invalidHost), ("http://proxy:80", .invalidHost),
            ("proxy:80/path", .invalidHost), ("user@proxy:80", .invalidHost), ("proxy:0", .invalidPort),
            ("proxy:65536", .invalidPort), ("proxy:-1", .invalidPort), ("proxy:http", .invalidPort),
        ]
        for (input, error) in cases {
            XCTAssertEqual(ExitProxyAddress.parse(input), .failure(error), input)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ExitProxyAddress.self, from: Data(#""proxy:0""#.utf8)))
    }

    func testDefaultCityOrderAndStableIDs() {
        let names: [String.LocalizationValue] = ["柏林", "法兰克福", "伦敦", "巴黎", "阿姆斯特丹", "纽约",
                                                  "洛杉矶", "旧金山", "东京", "香港", "新加坡"]
        XCTAssertEqual(Place.defaults.map(\.name), names.map { String(localized: $0) })
        XCTAssertEqual(Place.defaults.map(\.id.uuidString), "123456789AB".map { "620852A9-BDCD-4CCC-8D4F-42CB74AD830\($0)" })
    }

    func testOSVersionParsingComparisonAndTransports() throws {
        let versions: [(String, Int, Int, Int, TargetTransport)] = [
            ("16.7.10", 16, 7, 10, .unsupported), ("17.0", 17, 0, 0, .remotePairing),
            ("17.3.9", 17, 3, 9, .remotePairing), ("17.4", 17, 4, 0, .coreDeviceProxy),
            ("18.3", 18, 3, 0, .coreDeviceProxy),
        ]
        for (text, major, minor, patch, transport) in versions {
            let version = try XCTUnwrap(OSVersion(text), text)
            XCTAssertEqual([version.major, version.minor, version.patch], [major, minor, patch], text)
            XCTAssertEqual(version.preferredTransport, transport, text)
        }
        XCTAssertLessThan(try XCTUnwrap(OSVersion("17.3.9")), try XCTUnwrap(OSVersion("17.3.10")))
        for input in ["", "17", "17.", "17..4", "17.4.1.2", "-17.4", "17.beta"] {
            XCTAssertNil(OSVersion(input), input)
        }
    }
}
