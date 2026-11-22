import CoreLocation
import XCTest
@testable import ElsewhereMobile

final class ChinaCoordinateTests: XCTestCase {
    func testMainlandCityRoundTripsStayWithinOneCentimetre() throws {
        let cities = [
            ("北京", 39.9042, 116.4074), ("上海", 31.2304, 121.4737), ("成都", 30.5728, 104.0668),
            ("广州", 23.1291, 113.2644), ("哈尔滨", 45.8038, 126.5350), ("乌鲁木齐", 43.8256, 87.6168),
            ("拉萨", 29.6500, 91.1400), ("三亚", 18.2528, 109.5119), ("深圳市中心", 22.5431, 114.0579),
            ("珠海", 22.2707, 113.5767),
        ]
        for (name, latitude, longitude) in cities {
            let gps = try XCTUnwrap(WGS84Coordinate(latitude: latitude, longitude: longitude), name)
            XCTAssertTrue(ChinaCoordinate.isInMainland(latitude: latitude, longitude: longitude), name)
            let gcj = ChinaCoordinate.wgsToGcj(gps)
            XCTAssertNotEqual(gcj.longitude, longitude, name)
            let map = ChinaCoordinate.gpsToMap(gps)
            XCTAssertEqual(map.latitude, gcj.latitude, name)
            XCTAssertEqual(map.longitude, gcj.longitude, name)
            let restored = try XCTUnwrap(ChinaCoordinate.gcjToWgs(gcj), name)
            let distance = CLLocation(latitude: latitude, longitude: longitude)
                .distance(from: CLLocation(latitude: restored.latitude, longitude: restored.longitude))
            XCTAssertLessThan(distance, 0.01, name)
            XCTAssertEqual(ChinaCoordinate.mapToGPS(map), restored, name)
        }
    }

    func testMainlandSideOfBordersAndCoastalIslands() {
        let locations = [
            ("罗湖口岸深圳侧", 22.5324, 114.1137), ("福田", 22.5217, 114.0557), ("蛇口", 22.4864, 113.9154),
            ("珠海香洲", 22.2673, 113.5431), ("横琴", 22.1430, 113.5060), ("海南海口", 20.0440, 110.1999),
            ("厦门岛", 24.4798, 118.0894), ("崇明岛", 31.6290, 121.3973),
        ]
        for (name, latitude, longitude) in locations {
            XCTAssertTrue(ChinaCoordinate.isInMainland(latitude: latitude, longitude: longitude), name)
        }
    }

    func testOutsideMainlandKeepsBothMapDirectionsUnchanged() throws {
        let locations = [
            ("香港中环", 22.2800, 114.1588), ("旺角", 22.3193, 114.1694), ("沙田", 22.3820, 114.1880),
            ("落马洲港侧", 22.5146, 114.0655), ("香港机场", 22.3080, 113.9185),
            ("澳门半岛", 22.1987, 113.5439), ("氹仔", 22.1540, 113.5563), ("路环", 22.1185, 113.5557),
            ("台北", 25.0330, 121.5654), ("高雄", 22.6273, 120.3014), ("金门", 24.4321, 118.3171),
            ("马祖", 26.1579, 119.9510), ("首尔", 37.5665, 126.9780), ("东京", 35.6812, 139.7671),
            ("河内", 21.0285, 105.8542), ("海参崴", 43.1155, 131.8855),
        ]
        for (name, latitude, longitude) in locations {
            XCTAssertFalse(ChinaCoordinate.isInMainland(latitude: latitude, longitude: longitude), name)
            let gps = try XCTUnwrap(WGS84Coordinate(latitude: latitude, longitude: longitude), name)
            let map = ChinaCoordinate.gpsToMap(gps)
            XCTAssertEqual(map.latitude, latitude, name)
            XCTAssertEqual(map.longitude, longitude, name)
            XCTAssertEqual(ChinaCoordinate.mapToGPS(gps.clCoordinate), gps, name)
        }
    }
}
