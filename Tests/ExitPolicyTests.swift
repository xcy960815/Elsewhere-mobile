import XCTest
@testable import ElsewhereMobile

final class ExitPolicyTests: XCTestCase {
    private let previousIP = "203.0.113.1"
    private let exit = ExitInfo(ip: "203.0.113.2", city: "柏林", region: "", country: "DE",
                                coordinate: WGS84Coordinate(latitude: 52.52, longitude: 13.405)!, org: nil,
                                sampledAt: Date(timeIntervalSince1970: 60))

    func testPollingGatesAlsoRejectDetailResults() {
        let gates: [(Bool, ExitWatchMode, String?, ExitChangeDecision.IgnoreReason)] = [
            (false, .auto, previousIP, .disabled), (false, .off, nil, .disabled),
            (true, .off, previousIP, .watchOff), (true, .auto, nil, .baselineInitialized),
            (true, .notify, exit.ip, .unchanged),
        ]
        for (enabled, mode, previous, reason) in gates {
            XCTAssertFalse(ExitPolicy.shouldFetchDetail(featuresEnabled: enabled, watchMode: mode, previousIP: previous, observedIP: exit.ip))
            XCTAssertEqual(ExitPolicy.decide(featuresEnabled: enabled, watchMode: mode, previousIP: previous, probeIP: exit.ip,
                                             fetchedExit: exit, targetDeviceIDs: [], records: [:]), .ignore(reason))
        }
    }

    func testDifferentIpifyAndIpinfoResultsSuspendAutomaticApplication() throws {
        let id = try XCTUnwrap(DeviceID(rawValue: "following"))
        let probeIP = "2001:db8::1"
        XCTAssertTrue(ExitPolicy.shouldFetchDetail(featuresEnabled: true, watchMode: .auto, previousIP: previousIP, observedIP: probeIP))
        XCTAssertEqual(ExitPolicy.decide(featuresEnabled: true, watchMode: .auto, previousIP: previousIP, probeIP: probeIP,
                                         fetchedExit: exit, targetDeviceIDs: [id], records: [id: record(id, .exitIP, ip: previousIP)]),
                       .notifyDiscrepancy(probeIP: probeIP, detailIP: exit.ip))
    }

    func testChangedExitOnlyFollowsEligibleDevicesInAutomaticMode() throws {
        let following = try XCTUnwrap(DeviceID(rawValue: "following"))
        let matched = try XCTUnwrap(DeviceID(rawValue: "matched"))
        let city = try XCTUnwrap(DeviceID(rawValue: "city"))
        let custom = try XCTUnwrap(DeviceID(rawValue: "custom"))
        let unrecorded = try XCTUnwrap(DeviceID(rawValue: "new"))
        let targets = [following, matched, city, custom, unrecorded]
        let records = [following: record(following, .exitIP, ip: previousIP), matched: record(matched, .exitIP, ip: exit.ip),
                       city: record(city, .city), custom: record(custom, .custom)]
        let modes: [(ExitWatchMode, TargetExitAction)] = [(.notify, .notify), (.auto, .autoApply)]
        for (mode, action) in modes {
            XCTAssertTrue(ExitPolicy.shouldFetchDetail(featuresEnabled: true, watchMode: mode, previousIP: previousIP, observedIP: exit.ip))
            let decision = ExitPolicy.decide(featuresEnabled: true, watchMode: mode, previousIP: previousIP, probeIP: exit.ip,
                                             fetchedExit: exit, targetDeviceIDs: targets, records: records)
            XCTAssertEqual(decision, .evaluateTargets(exit: exit, actions: [following: action, matched: .alreadyMatched,
                                                                            city: .notify, custom: .notify, unrecorded: .notify]))
        }
    }

    private func record(_ id: DeviceID, _ source: LocationSource, ip: String? = nil) -> AppliedLocationRecord {
        AppliedLocationRecord(deviceID: id, deviceName: id.rawValue, name: exit.city, coordinate: exit.coordinate,
                              appliedAt: Date(timeIntervalSince1970: 0), source: source, exitIP: ip, confidence: .confirmed)
    }
}
