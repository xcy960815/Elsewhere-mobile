import Darwin
import XCTest
@testable import ElsewhereMobile

final class RustLocationEngineTests: XCTestCase {
    @MainActor
    func testLiveEnvironmentUsesTheRustEngine() throws {
        let environment = try AppEnvironment.live()
        XCTAssertFalse(environment.isDemo)
        XCTAssertTrue(environment.engine is RustLocationEngine)
        XCTAssertEqual(environment.abiVersion, 3)
    }

    func testProbeAndSetRequireAPairingRecord() async throws {
        let (engine, _) = try makeEngine()
        let id = try XCTUnwrap(DeviceID(rawValue: "unpaired"))
        let coordinate = try XCTUnwrap(WGS84Coordinate(latitude: 22.5431, longitude: 114.0579))
        do {
            _ = try await engine.probe(deviceID: id, endpointHost: "127.0.0.1")
            XCTFail("未配对设备不应探测成功")
        } catch {
            XCTAssertEqual(error.code, .not_paired)
        }
        do {
            try await engine.setLocation(coordinate, on: id) { _ in XCTFail("未配对时不应连接设备") }
            XCTFail("未配对设备不应接受定位")
        } catch {
            XCTAssertEqual(error.code, .not_paired)
        }
    }

    func testRefusedLoopbackProbeReportsSanitizedTunnelFailure() async throws {
        let (socket, host) = try reserveLockdownPort()
        defer { Darwin.close(socket) }
        let (engine, store) = try makeEngine()
        let id = try XCTUnwrap(DeviceID(rawValue: "loopback-device"))
        _ = try await store.importPairing(data: LockdownPlist(udid: id.rawValue).data(), endpointHost: host, deviceName: "测试设备")
        do {
            _ = try await engine.probe(deviceID: id, endpointHost: host)
            XCTFail("未监听的回环端口不应接受连接")
        } catch {
            XCTAssertEqual(error.code, .tunnel_unavailable)
            XCTAssertEqual(error.stage, EngineOperationStage.connecting.rawValue)
            XCTAssertEqual(error.deviceAlias, "测试设备")
            XCTAssertFalse(error.outcomeUnknown)
            LockdownPlist.assertNoCredentials(in: error.message)
            LockdownPlist.assertNoCredentials(in: try XCTUnwrap(error.rawDetail))
        }
    }

    func testCancellingAnAcceptedProbeInterruptsRustBeforeItsTimeout() async throws {
        let (socket, host) = try reserveLockdownPort()
        defer { Darwin.close(socket) }
        guard Darwin.listen(socket, 1) == 0, fcntl(socket, F_SETFL, O_NONBLOCK) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let (engine, store) = try makeEngine(timeoutMs: 15_000)
        let id = try XCTUnwrap(DeviceID(rawValue: "unbound-probe"))
        _ = try await store.importPairing(data: LockdownPlist().data(), endpointHost: host, deviceName: nil)
        let probe = Task { try await engine.probe(deviceID: id, endpointHost: host) }
        defer { probe.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        var peer = Darwin.accept(socket, nil, nil)
        while peer < 0 && (errno == EWOULDBLOCK || errno == EINTR) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            peer = Darwin.accept(socket, nil, nil)
        }
        guard peer >= 0 else { return XCTFail("Rust 未在时限内建立回环 TCP 连接") }
        defer { Darwin.close(peer) }
        let start = ContinuousClock.now
        probe.cancel()
        do {
            _ = try await probe.value
            XCTFail("取消在途探测应中断正在等待的设备回包")
        } catch let error as EngineError {
            XCTAssertEqual(error.code, .cancelled)
            XCTAssertFalse(error.outcomeUnknown)
            XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        }
    }

    func testSetLocationUsesCachedDDILeaseWithOneConnectionAndNoDownload() async throws {
        let (socket, host) = try reserveLockdownPort()
        defer { Darwin.close(socket) }
        guard Darwin.listen(socket, 2) == 0, fcntl(socket, F_SETFL, O_NONBLOCK) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let (store, directory, _) = try makePairingStore(), mirror = directory.appending(path: "mirror")
        let digest = try writeRelease(to: mirror), downloader = LocalDDIDownloader()
        let repository = DDIRepository(baseDirectory: directory.appending(path: "ddi"), mirrorBaseURL: mirror,
                                       downloader: downloader, verifier: RustLocationEngine.makeDDIVerifier())
        _ = try await repository.importLocalFiles(from: [mirror])
        let cached = await repository.cachedDirectory(), release = try XCTUnwrap(cached)
        let engine = RustLocationEngine(handle: try RustEngineHandle(), pairingStore: store, ddiRepository: repository, timeoutMs: 15_000)
        let id = try XCTUnwrap(DeviceID(rawValue: "cached-ddi-device"))
        _ = try await store.importPairing(data: LockdownPlist(udid: id.rawValue).data(), endpointHost: host, deviceName: nil)
        let operation = Task {
            do throws(EngineError) {
                try await engine.setLocation(Place.defaults[0].coordinate, on: id) { stage in
                    XCTAssertEqual(stage, .connecting)
                }
                XCTFail("拒绝服务连接的设备不应接受定位")
            } catch {
                XCTAssertEqual(error.code, .tunnel_unavailable)
                XCTAssertFalse(error.outcomeUnknown)
            }
        }
        defer { operation.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        var peer = Darwin.accept(socket, nil, nil)
        while peer < 0 && (errno == EWOULDBLOCK || errno == EINTR) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            peer = Darwin.accept(socket, nil, nil)
        }
        guard peer >= 0 else { return XCTFail("Rust 未在时限内建立回环 TCP 连接") }
        defer { Darwin.close(peer) }
        // 预检查失败也只连接一次；在途租约才能证明已经进入缓存直用路径。
        try await repository.clearCache()
        XCTAssertEqual(try RustCoreBridge.verifyDDI(at: release), digest)
        XCTAssertEqual(Darwin.shutdown(peer, SHUT_RDWR), 0)
        await operation.value
        let extra = Darwin.accept(socket, nil, nil), acceptError = errno
        if extra >= 0 { Darwin.close(extra) }
        XCTAssertEqual(extra, -1)
        XCTAssertEqual(acceptError, EWOULDBLOCK)
        XCTAssertFalse(FileManager.default.fileExists(atPath: release.path))
        let files = await downloader.files
        XCTAssertTrue(files.isEmpty)
    }

    private func makeEngine(timeoutMs: UInt32 = 2_000) throws -> (RustLocationEngine, PairingStore) {
        let (store, directory, _) = try makePairingStore()
        let repository = DDIRepository(baseDirectory: directory.appending(path: "ddi"), mirrorBaseURL: directory,
                                       downloader: LocalDDIDownloader(), verifier: RustLocationEngine.makeDDIVerifier())
        return (RustLocationEngine(handle: try RustEngineHandle(), pairingStore: store, ddiRepository: repository, timeoutMs: timeoutMs), store)
    }

    private func reserveLockdownPort() throws -> (Int32, String) {
        for host in ["127.0.0.1", "::1"] {
            var hints = addrinfo()
            hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, String(RustCoreBridge.lockdownPort), &hints, &result)
            guard status == 0, let address = result else { throw NSError(domain: "getaddrinfo", code: Int(status)) }
            defer { freeaddrinfo(address) }
            let endpoint = address.pointee
            let socket = Darwin.socket(endpoint.ai_family, endpoint.ai_socktype, endpoint.ai_protocol)
            guard socket >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if Darwin.bind(socket, endpoint.ai_addr, endpoint.ai_addrlen) == 0 { return (socket, host) }
            let code = errno
            Darwin.close(socket)
            if code != EADDRINUSE { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        }
        throw XCTSkip("IPv4 和 IPv6 回环地址的 Lockdown 端口 62078 均已被占用")
    }
}
