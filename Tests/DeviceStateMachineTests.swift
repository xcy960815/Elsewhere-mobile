import XCTest
@testable import ElsewhereMobile

final class DeviceStateMachineTests: XCTestCase {
    private let phoneID = DeviceID(rawValue: "phone")!
    private let otherID = DeviceID(rawValue: "other")!

    func testProbeOutcomesAndSubsequentProbes() {
        let probing = DeviceStateMachine.reduce(state: .unpaired, event: .probeStarted)
        XCTAssertEqual(probing, .probing)
        XCTAssertEqual(DeviceStateMachine.reduce(state: probing, event: .probeStarted), .probing)
        let ready = device(phoneID), disabled = device(phoneID, developerMode: false), unknown = device(phoneID, developerMode: nil)
        let outcomes: [(DeviceStateEvent, DeviceConnectionState)] = [
            (.probeFailedChannel("通道超时"), .channelUnavailable("通道超时")),
            (.probeFailedNotPaired("信任失效"), .notPaired("信任失效")),
            (.probeFailedLocked("已锁定"), .locked("已锁定")),
            (.probeFailedOther("服务失败"), .failed("服务失败")),
            (.probeSucceeded(device(phoneID, paired: false)), .notPaired(String(localized: "设备配对已失效"))),
            (.probeSucceeded(disabled), .developerModeOff(disabled)), (.probeSucceeded(unknown), .ready(unknown)),
            (.probeSucceeded(ready), .ready(ready)),
        ]
        for (event, expected) in outcomes {
            let state = DeviceStateMachine.reduce(state: probing, event: event)
            XCTAssertEqual(state, expected)
            XCTAssertEqual(DeviceStateMachine.reduce(state: state, event: .probeStarted), .probing)
        }
    }

    func testDDIProgressAndOperationTerminals() {
        let phone = device(phoneID)
        var state = DeviceConnectionState.ready(phone)
        for stage: DDIStage in [.downloading, .verifying, .signing, .uploading, .mounting] {
            state = DeviceStateMachine.reduce(state: state, event: .ddiStageChanged(stage))
            XCTAssertEqual(state, .preparingDDI(phone, stage))
            XCTAssertEqual(DeviceStateMachine.reduce(state: state, event: .probeStarted), state)
        }
        XCTAssertEqual(DeviceStateMachine.reduce(state: state, event: .operationFailed("挂载失败")), .failed("挂载失败"))
        let operating = DeviceStateMachine.reduce(state: state, event: .operationStarted(.setLocation))
        XCTAssertEqual(operating, .operating(phone, .setLocation))
        XCTAssertEqual(DeviceStateMachine.reduce(state: operating, event: .probeStarted), operating)
        XCTAssertEqual(DeviceStateMachine.reduce(state: operating, event: .operationFinished(device(otherID))), operating)
        XCTAssertEqual(DeviceStateMachine.reduce(state: operating, event: .operationFinished(phone)), .ready(phone))
        XCTAssertEqual(DeviceStateMachine.reduce(state: operating, event: .operationFailed("写入失败")), .failed("写入失败"))

        for kind: DeviceOperationKind in [.setLocation, .clearLocation, .restoreLocation] {
            let direct = DeviceStateMachine.reduce(state: .ready(phone), event: .operationStarted(kind))
            XCTAssertEqual(direct, .operating(phone, kind))
        }
        let updated = device(phoneID, developerMode: false)
        XCTAssertEqual(DeviceStateMachine.reduce(state: operating, event: .operationFinished(updated)), .developerModeOff(updated))
    }

    func testDisconnectAndPairingRemovalInvalidateCompletions() {
        let phone = device(phoneID)
        let disconnected = DeviceConnectionState.channelUnavailable(String(localized: "设备已断开连接"))
        XCTAssertEqual(DeviceStateMachine.reduce(state: .unpaired, event: .disconnected), .unpaired)
        let states: [DeviceConnectionState] = [.probing, .locked("锁屏"), .notPaired("失效"), disconnected,
                                               .developerModeOff(device(phoneID, developerMode: false)), .ready(phone),
                                               .preparingDDI(phone, .mounting), .operating(phone, .clearLocation), .failed("失败")]
        for state in states {
            XCTAssertEqual(DeviceStateMachine.reduce(state: state, event: .disconnected), disconnected)
            XCTAssertEqual(DeviceStateMachine.reduce(state: state, event: .pairingRemoved), .unpaired)
        }
        for state: DeviceConnectionState in [disconnected, .unpaired] {
            XCTAssertEqual(DeviceStateMachine.reduce(state: state, event: .probeSucceeded(phone)), state)
            XCTAssertEqual(DeviceStateMachine.reduce(state: state, event: .operationFinished(phone)), state)
        }
    }

    func testFirstPresenceOnlyEstablishesBaselineAndReconnectRequiresARecord() {
        var tracker = AutoRestoreTracker()
        tracker.observe(presentIDs: [phoneID, otherID], recordedIDs: [phoneID])
        XCTAssertEqual(tracker.pendingAttempts, [:])
        tracker.observe(presentIDs: [], recordedIDs: [phoneID])
        XCTAssertEqual(tracker.pendingAttempts, [:])
        tracker.observe(presentIDs: [phoneID, otherID], recordedIDs: [phoneID])
        XCTAssertEqual(tracker.pendingAttempts, [phoneID: 0])
    }

    func testColdMountLossRequiresPresenceAndOnlyQueuesEachLossOnce() {
        var tracker = AutoRestoreTracker()
        let recorded: Set<DeviceID> = [phoneID, otherID]
        tracker.observe(presentIDs: [phoneID], recordedIDs: recorded, confirmedUnmountedIDs: recorded)
        XCTAssertEqual(tracker.pendingAttempts, [phoneID: 0])
        XCTAssertEqual(tracker.recordFailure(deviceID: phoneID), .retry)
        tracker.observe(presentIDs: [phoneID], recordedIDs: recorded, confirmedUnmountedIDs: recorded)
        XCTAssertEqual(tracker.pendingAttempts, [phoneID: 1])
        tracker.invalidate(deviceID: phoneID)
        tracker.observe(presentIDs: [phoneID], recordedIDs: recorded, confirmedUnmountedIDs: recorded)
        XCTAssertEqual(tracker.pendingAttempts, [:])
        tracker.observe(presentIDs: [phoneID], recordedIDs: recorded)
        tracker.observe(presentIDs: [phoneID], recordedIDs: recorded, confirmedUnmountedIDs: [phoneID])
        XCTAssertEqual(tracker.pendingAttempts, [phoneID: 0])
    }

    func testFifteenthFailureExhaustsTheQueueDespiteRepeatedMountEvidence() {
        var tracker = AutoRestoreTracker()
        tracker.observe(presentIDs: [phoneID], recordedIDs: [phoneID], confirmedUnmountedIDs: [phoneID])
        for attempt in 1..<15 {
            XCTAssertEqual(tracker.recordFailure(deviceID: phoneID), .retry)
            tracker.observe(presentIDs: [phoneID], recordedIDs: [phoneID], confirmedUnmountedIDs: [phoneID])
            XCTAssertEqual(tracker.pendingAttempts[phoneID], attempt)
        }
        XCTAssertEqual(tracker.recordFailure(deviceID: phoneID), .exhausted)
        tracker.observe(presentIDs: [phoneID], recordedIDs: [phoneID], confirmedUnmountedIDs: [phoneID])
        XCTAssertEqual(tracker.pendingAttempts, [:])
        XCTAssertEqual(tracker.recordFailure(deviceID: phoneID), .notPending)
    }

    func testManualOperationAndSuccessfulClearInvalidateTheirOwnQueues() {
        var tracker = AutoRestoreTracker()
        let both: Set<DeviceID> = [phoneID, otherID]
        tracker.observe(presentIDs: both, recordedIDs: both, confirmedUnmountedIDs: both)
        tracker.invalidate(deviceID: phoneID)
        tracker.observe(presentIDs: both, recordedIDs: both, confirmedUnmountedIDs: both)
        XCTAssertEqual(tracker.pendingAttempts, [otherID: 0])
        tracker.observe(presentIDs: both, recordedIDs: [phoneID], confirmedUnmountedIDs: both)
        XCTAssertEqual(tracker.recordFailure(deviceID: otherID), .notPending)
        XCTAssertEqual(tracker.pendingAttempts, [:])
    }

    func testTurningOffAutoRestoreInvalidatesAllQueues() {
        var tracker = AutoRestoreTracker()
        let both: Set<DeviceID> = [phoneID, otherID]
        tracker.observe(presentIDs: both, recordedIDs: both, confirmedUnmountedIDs: both)
        XCTAssertEqual(tracker.pendingAttempts, [phoneID: 0, otherID: 0])
        tracker.observe(presentIDs: both, recordedIDs: both, confirmedUnmountedIDs: both, autoRestore: false)
        XCTAssertEqual(tracker.pendingAttempts, [:])
        tracker.observe(presentIDs: both, recordedIDs: both, confirmedUnmountedIDs: both)
        XCTAssertEqual(tracker.pendingAttempts, [:])
    }

    private func device(_ id: DeviceID, paired: Bool = true, developerMode: Bool? = true) -> TargetDevice {
        TargetDevice(id: id, name: id.rawValue, deviceClass: "iPhone", productType: nil, osVersion: OSVersion("18.3"),
                     endpointHost: "192.0.2.1", paired: paired, developerMode: developerMode, wifiEnabled: nil,
                     timeZoneID: nil, cellular: nil, ddiMounted: nil)
    }
}
