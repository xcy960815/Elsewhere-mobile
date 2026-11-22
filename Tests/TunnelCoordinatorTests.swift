import Darwin
import XCTest
@testable import ElsewhereMobile

private actor MockTunnelProviderAdapter: TunnelProviderAdapter {
    enum Event: Equatable, Sendable {
        case status, start(String), stop(cancelled: Bool)
    }

    private(set) var events: [Event] = []
    private var state: TunnelConnectionStatus
    private let onStart: @Sendable () async throws -> Void
    private let onStop: @Sendable () async -> Void
    nonisolated let hasPendingRecovery: Bool

    init(_ state: TunnelConnectionStatus = .disconnected, hasPendingRecovery: Bool = false,
         onStart: @escaping @Sendable () async throws -> Void = {}, onStop: @escaping @Sendable () async -> Void = {}) {
        self.state = state
        self.hasPendingRecovery = hasPendingRecovery
        self.onStart = onStart
        self.onStop = onStop
    }

    func currentStatus() -> TunnelConnectionStatus {
        events.append(.status)
        return state
    }

    func start(targetHost: String) async throws {
        events.append(.start(targetHost))
        try await onStart()
        state = .connected
    }

    func stop() async {
        events.append(.stop(cancelled: Task.isCancelled))
        await onStop()
        state = .disconnected
    }
}

final class TunnelCoordinatorTests: XCTestCase {
    func testExistingRouteNeverConsultsAdapter() async throws {
        let adapter = MockTunnelProviderAdapter(), coordinator = TunnelCoordinator(adapter: adapter)
        let value = try await coordinator.withChannel(mode: .existingRoute, targetHost: "192.0.2.1", autoDisconnect: true) { 42 }
        let events = await adapter.events
        XCTAssertEqual(value, 42)
        XCTAssertEqual(events, [])
    }

    func testSuccessAndErrorBothWaitForDisconnect() async throws {
        let adapter = MockTunnelProviderAdapter(), coordinator = TunnelCoordinator(adapter: adapter)
        let peer = "10.7.0.1"
        let status = try await coordinator.withChannel(mode: .builtInTunnel, targetHost: peer, autoDisconnect: true) {
            await coordinator.status()
        }
        XCTAssertEqual(status, .connected)
        do {
            try await coordinator.withChannel(mode: .builtInTunnel, targetHost: peer, autoDisconnect: true) {
                throw URLError(.networkConnectionLost)
            }
            XCTFail("应返回操作抛出的错误")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        let events = await adapter.events
        XCTAssertEqual(events, [.status, .start(peer), .status, .stop(cancelled: false), .status, .start(peer), .stop(cancelled: false)])
    }

    func testCancellationStopsInAnUncancelledTask() async throws {
        let adapter = MockTunnelProviderAdapter(), coordinator = TunnelCoordinator(adapter: adapter)
        let entered = expectation(description: "操作已取得租约")
        let task = Task {
            try await coordinator.withChannel(mode: .builtInTunnel, targetHost: "10.7.0.1", autoDisconnect: true) {
                entered.fulfill()
                try await Task.sleep(for: .seconds(30))
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        do {
            try await task.value
            XCTFail("取消应传回调用者")
        } catch is CancellationError {}
        let events = await adapter.events
        XCTAssertEqual(events, [.status, .start("10.7.0.1"), .stop(cancelled: false)])
    }

    func testThreeLeasesSharePendingStartAndOnlyLastReleaseStops() async throws {
        let peer = "fd00::1", starting = expectation(description: "启动请求已发出")
        let (startup, resume) = AsyncStream<Void>.makeStream()
        let adapter = MockTunnelProviderAdapter(onStart: {
            starting.fulfill()
            for await _ in startup {}
        })
        let coordinator = TunnelCoordinator(adapter: adapter)
        let gates = (0..<3).map { _ in AsyncStream<Void>.makeStream() }
        let entered = (0..<3).map { expectation(description: "操作 \($0) 已取得租约") }
        let tasks = gates.indices.map { index in
            Task {
                try await coordinator.withChannel(mode: .builtInTunnel, targetHost: peer, autoDisconnect: true) {
                    entered[index].fulfill()
                    for await _ in gates[index].stream {}
                }
            }
        }
        defer { for gate in gates { gate.continuation.finish() } }
        await fulfillment(of: [starting], timeout: 5)
        let deadline = ContinuousClock.now + .seconds(5)
        while await coordinator.activeLeases < 3, ContinuousClock.now < deadline { await Task.yield() }
        let pending = await coordinator.activeLeases, switching = await coordinator.isSwitchingChannel
        XCTAssertEqual(pending, 3)
        XCTAssertTrue(switching)
        resume.finish()
        await fulfillment(of: entered, timeout: 5)
        await coordinator.disconnectOwnedTunnelIfIdle()
        for index in gates.indices {
            gates[index].continuation.finish()
            try await tasks[index].value
            let remaining = await coordinator.activeLeases, events = await adapter.events
            XCTAssertEqual(remaining, 2 - index)
            XCTAssertEqual(events, index == 2 ? [.status, .start(peer), .stop(cancelled: false)] : [.status, .start(peer)])
        }
    }

    func testPreconnectedTunnelSurvivesAutomaticAndIdleCleanup() async throws {
        let adapter = MockTunnelProviderAdapter(.connected), coordinator = TunnelCoordinator(adapter: adapter)
        try await coordinator.withChannel(mode: .builtInTunnel, targetHost: "10.7.0.1", autoDisconnect: true) {}
        await coordinator.disconnectOwnedTunnelIfIdle()
        let events = await adapter.events
        XCTAssertEqual(events, [.status])
    }

    func testOwnedTunnelCanBeKeptAndReclaimedWhenIdle() async throws {
        let adapter = MockTunnelProviderAdapter(), coordinator = TunnelCoordinator(adapter: adapter)
        try await coordinator.withChannel(mode: .builtInTunnel, targetHost: "10.7.0.1", autoDisconnect: false) {}
        let kept = await adapter.events
        XCTAssertEqual(kept, [.status, .start("10.7.0.1")])
        await coordinator.disconnectOwnedTunnelIfIdle()
        await coordinator.disconnectOwnedTunnelIfIdle()
        let events = await adapter.events
        XCTAssertEqual(events, kept + [.stop(cancelled: false)])

        let recovered = MockTunnelProviderAdapter(.connected, hasPendingRecovery: true)
        await TunnelCoordinator(adapter: recovered).disconnectOwnedTunnelIfIdle()
        let recovery = await recovered.events
        XCTAssertEqual(recovery, [.stop(cancelled: false)])
    }

    func testNewLeaseWaitsForStopBeforeStartingAgain() async throws {
        let stopping = expectation(description: "断开请求已发出")
        let (shutdown, resume) = AsyncStream<Void>.makeStream()
        let adapter = MockTunnelProviderAdapter(onStop: {
            stopping.fulfill()
            for await _ in shutdown {}
        })
        let coordinator = TunnelCoordinator(adapter: adapter), peer = "10.7.0.1"
        let first = Task { try await coordinator.withChannel(mode: .builtInTunnel, targetHost: peer, autoDisconnect: true) {} }
        await fulfillment(of: [stopping], timeout: 5)
        let switching = await coordinator.isSwitchingChannel
        XCTAssertTrue(switching)
        let next = Task { try await coordinator.withChannel(mode: .builtInTunnel, targetHost: peer, autoDisconnect: false) {} }
        resume.finish()
        try await first.value
        try await next.value
        let events = await adapter.events
        XCTAssertEqual(events, [.status, .start(peer), .stop(cancelled: false), .status, .start(peer)])
    }

    func testSwitchingPeersReleasesEvenAKeptTunnel() async throws {
        let adapter = MockTunnelProviderAdapter(), coordinator = TunnelCoordinator(adapter: adapter)
        try await coordinator.withChannel(mode: .builtInTunnel, targetHost: "10.7.0.1", autoDisconnect: false) {}
        try await coordinator.withChannel(mode: .builtInTunnel, targetHost: "fd00::1", autoDisconnect: true) {}
        let events = await adapter.events
        XCTAssertEqual(events, [.status, .start("10.7.0.1"), .stop(cancelled: false),
                                .status, .start("fd00::1"), .stop(cancelled: false)])
    }

    func testCancellingPeerWaitBeforeOldChannelFinishesStopping() async throws {
        let stopping = expectation(description: "正为新 peer 释放旧通道")
        let (gate, release) = AsyncStream<Void>.makeStream()
        let adapter = MockTunnelProviderAdapter(onStop: {
            stopping.fulfill()
            for await _ in gate {}
        })
        let coordinator = TunnelCoordinator(adapter: adapter)
        try await coordinator.withChannel(mode: .builtInTunnel, targetHost: "10.7.0.1", autoDisconnect: false) {}
        let cancelled = expectation(description: "取消不依赖旧通道断开")
        let next = Task {
            do {
                try await coordinator.withChannel(mode: .builtInTunnel, targetHost: "fd00::1", autoDisconnect: true) {
                    XCTFail("取消的请求不应执行")
                }
                XCTFail("应报告取消")
            } catch is CancellationError { cancelled.fulfill() }
        }
        defer { release.finish() }
        await fulfillment(of: [stopping], timeout: 3)
        next.cancel()
        await fulfillment(of: [cancelled], timeout: 3)
        release.finish()
        try await next.value
        await coordinator.disconnectOwnedTunnelIfIdle()
        let events = await adapter.events, leases = await coordinator.activeLeases
        XCTAssertEqual(events, [.status, .start("10.7.0.1"), .stop(cancelled: false)])
        XCTAssertEqual(leases, 0)
    }

    func testFailedStartReleasesReservationWithoutRunningOperation() async throws {
        let adapter = MockTunnelProviderAdapter(onStart: { throw URLError(.timedOut) })
        let coordinator = TunnelCoordinator(adapter: adapter)
        for _ in 0..<2 {
            do {
                try await coordinator.withChannel(mode: .builtInTunnel, targetHost: "10.7.0.1", autoDisconnect: true) {
                    XCTFail("启动失败不应执行操作")
                }
                XCTFail("应报告启动错误")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .timedOut)
            }
        }
        let events = await adapter.events, leases = await coordinator.activeLeases
        XCTAssertEqual(leases, 0)
        XCTAssertEqual(events, [.status, .start("10.7.0.1"), .status, .start("10.7.0.1")])
    }

    func testLoopbackTargetUsesAdjacentAddresses() {
        XCTAssertEqual(LoopbackTarget.parse(), .ipv4(local: "10.7.0.2", peer: "10.7.0.1"))
        XCTAssertEqual(LoopbackTarget.parse(peer: "10.7.0.254"), .ipv4(local: "10.7.0.253", peer: "10.7.0.254"))
        XCTAssertEqual(LoopbackTarget.parse(peer: "fd00::1"), .ipv6(local: "fd00::", peer: "fd00::1"))
        for invalid in ["", "example.org", "10.7.0.256", "10.7.0.1\0suffix", "fd00:::1", "[fd00::1]"] {
            XCTAssertNil(LoopbackTarget.parse(peer: invalid), invalid)
        }
    }

    func testPacketReflectionPreservesHeadersPayloadAndChecksums() {
        let v4 = Data([10, 7, 0, 2]), v6 = Data([0xfd, 0] + Array(repeating: 0, count: 14))
        let packets: [(Int32, Data, Data, Data, Data)] = [
            (AF_INET, Data([0x46, 0, 0, 35, 0x12, 0x34, 0x40, 0, 64, 17, 0x11, 0x85]), v4, Data([10, 7, 0, 1]),
             Data([1, 1, 1, 0, 0xc0, 0, 0xf2, 0x7e, 0, 11, 0x74, 0xe5, 97, 98, 99])),
            (AF_INET6, Data([0x60, 0, 0, 0, 0, 20, 6, 64]), v6, v6.dropLast() + Data([1]),
             Data([0xc0, 0, 0xf2, 0x7e, 0, 0, 0, 42, 0, 0, 0, 0, 0x50, 2, 0x10, 0, 0xf3, 0x36, 0, 0]))
        ]
        for (family, header, local, peer, payload) in packets {
            let packet = header + local + peer + payload, expected = header + peer + local + payload
            let slice = (Data([0]) + packet).dropFirst()
            XCTAssertEqual(LoopbackPacket.rewrite(slice, protocolFamily: family, localBytes: local, peerBytes: peer), expected)
            for invalid in [expected, header + local + local + payload, header + peer + peer + payload, packet.dropLast(), packet.prefix(16)] {
                XCTAssertNil(LoopbackPacket.rewrite(invalid, protocolFamily: family, localBytes: local, peerBytes: peer))
            }
            XCTAssertNil(LoopbackPacket.rewrite(packet, protocolFamily: AF_UNIX, localBytes: local, peerBytes: peer))
            var malformed = packet
            malformed[0] = family == AF_INET ? 0x44 : 0x40
            XCTAssertNil(LoopbackPacket.rewrite(malformed, protocolFamily: family, localBytes: local, peerBytes: peer))
            if family == AF_INET {
                malformed[0] = 0x4f
                XCTAssertNil(LoopbackPacket.rewrite(malformed, protocolFamily: family, localBytes: local, peerBytes: peer))
            }
        }
    }
}
