import CryptoKit
import XCTest
@testable import ElsewhereMobile

actor LocalDDIDownloader: DDIDownloader {
    private(set) var files: [String] = []
    private var gate: AsyncStream<Void>?

    func pauseNextDownload() -> AsyncStream<Void>.Continuation {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        gate = stream
        return continuation
    }

    func download(from url: URL) async throws -> URL {
        files.append(url.lastPathComponent)
        if let gate {
            self.gate = nil
            for await _ in gate {}
        }
        return url
    }
}

final class DDIRepositoryTests: XCTestCase {
    private func writeRelease(to directory: URL, byte: UInt8 = 0x78) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = Data(repeating: byte, count: 131_075)
        let digest = Data(SHA384.hash(data: image))
        let manifest = ["BuildIdentities": [["Manifest": ["PersonalizedDMG": ["Digest": digest]]]]]
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
            .write(to: directory.appending(path: "BuildManifest.plist"))
        try image.write(to: directory.appending(path: "Image.dmg"))
        try Data("test trust cache".utf8).write(to: directory.appending(path: "Image.dmg.trustcache"))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func testFourConcurrentAcquisitionsDownloadEachFileOnce() async throws {
        let directory = try makeTemporaryDirectory(), mirror = directory.appending(path: "mirror")
        let digest = try writeRelease(to: mirror)
        let downloader = LocalDDIDownloader()
        let repository = DDIRepository(baseDirectory: directory, mirrorBaseURL: mirror, downloader: downloader,
                                       verifier: RustLocationEngine.makeDDIVerifier())
        let resume = await downloader.pauseNextDownload()
        let starts = (1...4).map { expectation(description: "第 \($0) 个请求开始准备组件") }
        let tasks = starts.map { started in
            Task {
                try await repository.acquirePrepared { stage in
                    if stage == EngineOperationStage.downloadingDDI.rawValue { started.fulfill() }
                }
            }
        }
        await fulfillment(of: starts, timeout: 5)
        resume.finish()
        var leases: [DDIReleaseLease] = []
        for task in tasks { leases.append(try await task.value) }
        let files = await downloader.files
        XCTAssertEqual(files.sorted(), DDIRepository.requiredFiles.sorted())
        let first = try XCTUnwrap(leases.first)
        XCTAssertEqual(Set(leases.map(\.directory)), [first.directory])
        XCTAssertEqual(try RustCoreBridge.verifyDDI(at: first.directory), digest)
        XCTAssertEqual(try String(contentsOf: directory.appending(path: "current.txt"), encoding: .utf8), first.versionID)
        for lease in leases { await repository.release(lease) }
    }

    func testBadDigestAndMissingFilesPreserveThePublishedRelease() async throws {
        let directory = try makeTemporaryDirectory(), mirror = directory.appending(path: "mirror")
        let digest = try writeRelease(to: mirror)
        let verify = RustLocationEngine.makeDDIVerifier()
        let repository = DDIRepository(baseDirectory: directory, mirrorBaseURL: mirror, downloader: LocalDDIDownloader(), verifier: verify)
        let old = try await repository.acquirePrepared()
        await repository.release(old)
        let pointer = directory.appending(path: "current.txt")
        let published = try Data(contentsOf: pointer)
        XCTAssertEqual(String(decoding: published, as: UTF8.self), old.versionID)

        for missing in [nil] + DDIRepository.requiredFiles.map(Optional.some) {
            let file = mirror.appending(path: missing ?? "Image.dmg")
            let original = try Data(contentsOf: file)
            if missing != nil {
                try FileManager.default.removeItem(at: file)
            } else {
                var changed = original
                changed[changed.count - 1] ^= 1
                try changed.write(to: file)
            }
            do {
                _ = try await verify(mirror)
                XCTFail("FFI 应拒绝损坏或缺件的镜像")
            } catch let error as EngineError {
                XCTAssertEqual(error.code, .ddi_missing)
                XCTAssertTrue(error.rawDetail?.contains(missing ?? "SHA-384") == true)
            }
            do {
                let lease = try await repository.acquirePrepared(forceRefresh: true)
                await repository.release(lease)
                XCTFail("刷新失败时不应发布新版本")
            } catch {
                switch error {
                case .verificationFailed: break
                case .storageFailure where missing != nil: break
                default: XCTFail("应报告本地文件读取失败或摘要校验失败")
                }
            }
            XCTAssertEqual(try Data(contentsOf: pointer), published)
            let cached = await repository.cachedDirectory()
            XCTAssertEqual(cached, old.directory)
            let cachedDigest = try await verify(old.directory)
            XCTAssertEqual(cachedDigest, digest)
            try original.write(to: file)
            for name in DDIRepository.requiredFiles {
                XCTAssertEqual(try Data(contentsOf: old.directory.appending(path: name)), try Data(contentsOf: mirror.appending(path: name)))
            }
        }
    }

    func testRefreshSwitchesPointerAndRetiresOldDirectoryAfterItsLastLease() async throws {
        let directory = try makeTemporaryDirectory(), mirror = directory.appending(path: "mirror")
        let originalDigest = try writeRelease(to: mirror)
        let downloader = LocalDDIDownloader()
        let repository = DDIRepository(baseDirectory: directory, mirrorBaseURL: mirror, downloader: downloader,
                                       verifier: RustLocationEngine.makeDDIVerifier())
        let first = try await repository.acquirePrepared(), second = try await repository.acquirePrepared()
        XCTAssertEqual(first.directory, second.directory)
        let nextDigest = try writeRelease(to: mirror, byte: 0x79)
        let resume = await downloader.pauseNextDownload()
        let started = expectation(description: "新版本开始下载")
        let refresh = Task {
            try await repository.acquirePrepared(forceRefresh: true) { stage in
                if stage == EngineOperationStage.downloadingDDI.rawValue { started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 5)
        let pointer = directory.appending(path: "current.txt")
        XCTAssertEqual(try String(contentsOf: pointer, encoding: .utf8), first.versionID)
        resume.finish()
        let next = try await refresh.value
        XCTAssertNotEqual(next.directory, first.directory)
        XCTAssertEqual(try String(contentsOf: pointer, encoding: .utf8), next.versionID)
        XCTAssertEqual(try RustCoreBridge.verifyDDI(at: next.directory), nextDigest)
        await repository.release(first)
        XCTAssertEqual(try RustCoreBridge.verifyDDI(at: second.directory), originalDigest)
        await repository.release(second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.path))
        await repository.release(next)
        let cached = await repository.cachedDirectory()
        XCTAssertEqual(cached, next.directory)
    }
}
