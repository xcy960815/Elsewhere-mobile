import XCTest
@testable import ElsewhereMobile

final class DomainModelTests: XCTestCase {
    func testAutomaticExitChangeNotifiesForUnknownRecordsEvenWhenIPsMatch() throws {
        let id = try XCTUnwrap(DeviceID(rawValue: "following"))
        let previous = "203.0.113.1"
        let exit = ExitInfo(ip: "203.0.113.2", city: "", region: "", country: "",
                            coordinate: try XCTUnwrap(WGS84Coordinate(latitude: 52.52, longitude: 13.405)),
                            org: nil, sampledAt: Date())
        for confidence in [AppliedConfidence.unknownOutcome, .clearUnknown] {
            for ip in [previous, exit.ip] {
                let record = AppliedLocationRecord(deviceID: id, deviceName: id.rawValue, name: "", coordinate: exit.coordinate,
                                                   appliedAt: exit.sampledAt, source: .exitIP, exitIP: ip, confidence: confidence)
                let decision = ExitPolicy.decide(featuresEnabled: true, watchMode: .auto, previousIP: previous, probeIP: exit.ip,
                                                 fetchedExit: exit, targetDeviceIDs: [id], records: [id: record])
                XCTAssertEqual(decision, .evaluateTargets(exit: exit, actions: [id: .notify]), "\(confidence), \(ip)")
            }
        }
    }
}
