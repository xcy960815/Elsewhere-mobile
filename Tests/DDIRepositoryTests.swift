import CryptoKit
import XCTest
@testable import ElsewhereMobile

actor LocalDDIDownloader: DDIDownloader {
    private(set) var files: [String] = []
    private var gate: (stream: AsyncStream<Void>, onStart: @Sendable () -> Void)?

    func pauseNextDownload(onStart: @escaping @Sendable () -> Void = {}) -> AsyncStream<Void>.Continuation {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        gate = (stream, onStart)
        return continuation
    }

    func download(from url: URL) async throws -> URL {
        files.append(url.lastPathComponent)
        if let gate {
            self.gate = nil
            gate.onStart()
            for await _ in gate.stream {}
            try Task.checkCancellation()
        }
        return url
    }
}

private struct PinnedMirrorDownloader: DDIDownloader {
    let mirror: URL
    let revision: String
    let rateLimited: Bool

    func download(from url: URL) async throws -> URL {
        let file = mirror.appending(path: UUID().uuidString)
        if url.host == "api.github.com" {
            guard !rateLimited else { throw DDIRepositoryError.httpStatus(403) }
            try JSONEncoder().encode(["sha": revision]).write(to: file)
        } else {
            guard url.pathComponents.contains(revision) else { throw DDIRepositoryError.httpStatus(404) }
            try FileManager.default.copyItem(at: mirror.appending(component: url.lastPathComponent), to: file)
        }
        return file
    }
}

func writeRelease(to directory: URL, byte: UInt8 = 0x78) throws -> String {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let image = Data(repeating: byte, count: 131_075)
    let digest = Data(SHA384.hash(data: image))
    let trustCache = Data("test trust cache".utf8)
    let manifest = ["BuildIdentities": [["Manifest": ["PersonalizedDMG": ["Digest": digest],
                                                   "LoadableTrustCache": ["Digest": Data(SHA384.hash(data: trustCache))]]]]]
    try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        .write(to: directory.appending(path: "BuildManifest.plist"))
    try image.write(to: directory.appending(path: "Image.dmg"))
    try trustCache.write(to: directory.appending(path: "Image.dmg.trustcache"))
    return digest.map { String(format: "%02x", $0) }.joined()
}

final class DDIRepositoryTests: XCTestCase {
    func testPrepareCachePublishesStatusAndSurvivesLeaseReleaseUntilCleared() async throws {
        let directory = try makeTemporaryDirectory(), mirror = directory.appending(path: "mirror")
        let digest = try writeRelease(to: mirror)
        let total = try DDIRepository.requiredFiles.reduce(Int64(0)) { $0 + Int64(try Data(contentsOf: mirror.appending(path: $1)).count) }
        let downloader = LocalDDIDownloader()
        let repository = DDIRepository(baseDirectory: directory, mirrorBaseURL: mirror, downloader: downloader,
                                       verifier: RustLocationEngine.makeDDIVerifier())
        let initial = await repository.cacheStatus()
        XCTAssertEqual(initial, .notDownloaded)
        let prepared = try await repository.prepareCache(forceRefresh: true)
        let cached = await repository.cachedDirectory(), status = await repository.cacheStatus()
        let release = try XCTUnwrap(cached)
        XCTAssertEqual(prepared, .ready(versionID: release.lastPathComponent, totalBytes: total))
        XCTAssertEqual(status, prepared)
        XCTAssertEqual(try RustCoreBridge.verifyDDI(at: release), digest)
        let files = await downloader.files
        XCTAssertEqual(files, DDIRepository.requiredFiles)
        try await repository.clearCache()
        let cleared = await repository.cacheStatus()
        XCTAssertEqual(cleared, .notDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: release.path))
    }

    func testClearCacheCancelsInFlightPreparationAndPreventsPublication() async throws {
        let directory = try makeTemporaryDirectory(), mirror = directory.appending(path: "mirror")
        _ = try writeRelease(to: mirror)
        let downloader = LocalDDIDownloader()
        let repository = DDIRepository(baseDirectory: directory, mirrorBaseURL: mirror, downloader: downloader,
                                       verifier: RustLocationEngine.makeDDIVerifier())
        let downloading = expectation(description: "下载已暂停"), joined = expectation(description: "缓存准备已加入下载")
        let returned = expectation(description: "清理缓存取消所有等待者")
        returned.expectedFulfillmentCount = 2
        let resume = await downloader.pauseNextDownload { downloading.fulfill() }
        let acquisition = Task {
            defer { returned.fulfill() }
            do throws(DDIRepositoryError) {
                let lease = try await repository.acquirePrepared()
                await repository.release(lease)
                XCTFail("清理缓存后不应取得租约")
            } catch { XCTAssertEqual(error, .cancelled) }
        }
        await fulfillment(of: [downloading], timeout: 5)
        let preparation = Task {
            defer { returned.fulfill() }
            do throws(DDIRepositoryError) {
                _ = try await repository.prepareCache(onStage: { stage in
                    if stage == EngineOperationStage.downloadingDDI.rawValue { joined.fulfill() }
                })
                XCTFail("清理缓存后不应完成准备")
            } catch { XCTAssertEqual(error, .cancelled) }
        }
        await fulfillment(of: [joined], timeout: 5)
        let staging = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("staging-") })
        try await repository.clearCache()
        await fulfillment(of: [returned], timeout: 5)
        resume.finish()
        await acquisition.value
        await preparation.value
        let deadline = ContinuousClock.now + .seconds(5)
        while FileManager.default.fileExists(atPath: staging.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let status = await repository.cacheStatus(), cached = await repository.cachedDirectory()
        XCTAssertEqual(status, .notDownloaded)
        XCTAssertNil(cached)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "current.txt").path))
    }

    func testMalformedOrMismatchedTrustcachePreservesPublishedCache() async throws {
        let directory = try makeTemporaryDirectory(), mirror = directory.appending(path: "mirror")
        let digest = try writeRelease(to: mirror)
        let repository = DDIRepository(baseDirectory: directory, downloader: LocalDDIDownloader(), verifier: RustLocationEngine.makeDDIVerifier())
        let published = try await repository.importLocalFiles(from: [mirror])
        let pointer = directory.appending(path: "current.txt"), version = try Data(contentsOf: pointer)
        let cached = await repository.cachedDirectory(), release = try XCTUnwrap(cached)
        let originals = try DDIRepository.requiredFiles.map { try Data(contentsOf: release.appending(path: $0)) }
        for (trustCache, reason) in [(Data([0x01]), String(localized: "开发者组件 trust cache 无效")),
                                     (Data(repeating: 0x01, count: 16), String(localized: "开发者组件 trust cache 摘要不匹配"))] {
            try trustCache.write(to: mirror.appending(path: "Image.dmg.trustcache"))
            do {
                _ = try await repository.importLocalFiles(from: [mirror])
                XCTFail("无效 trust cache 不应替换缓存")
            } catch { XCTAssertEqual(error, .verificationFailed(reason)) }
            let status = await repository.cacheStatus(), current = await repository.cachedDirectory()
            XCTAssertEqual(status, published)
            XCTAssertEqual(current, release)
            XCTAssertEqual(try Data(contentsOf: pointer), version)
            XCTAssertEqual(try RustCoreBridge.verifyDDI(at: release), digest)
            XCTAssertEqual(try DDIRepository.requiredFiles.map { try Data(contentsOf: release.appending(path: $0)) }, originals)
        }
    }

    func testWithCachedDDINeverDownloadsAndProtectsDirectoryUntilOperationReturns() async throws {
        let directory = try makeTemporaryDirectory(), mirror = directory.appending(path: "mirror")
        let digest = try writeRelease(to: mirror), downloader = LocalDDIDownloader()
        let repository = DDIRepository(baseDirectory: directory, mirrorBaseURL: mirror, downloader: downloader,
                                       verifier: RustLocationEngine.makeDDIVerifier())
        let missing = try await repository.withCachedDDI { directory in
            XCTFail("无缓存时不应执行操作")
            return directory
        }
        XCTAssertNil(missing)
        let before = await downloader.files
        XCTAssertTrue(before.isEmpty)
        _ = try await repository.prepareCache()
        let downloaded = await downloader.files
        let used = try await repository.withCachedDDI { directory in
            try await repository.clearCache()
            XCTAssertEqual(try RustCoreBridge.verifyDDI(at: directory), digest)
            return directory
        }
        let release = try XCTUnwrap(used)
        XCTAssertFalse(FileManager.default.fileExists(atPath: release.path))
        let after = await downloader.files
        XCTAssertEqual(after, downloaded)
    }

    func testImportLocalFilesAcceptsIndividualFilesAndDirectory() async throws {
        let directory = try makeTemporaryDirectory(), mirror = directory.appending(path: "mirror")
        let digest = try writeRelease(to: mirror), downloader = LocalDDIDownloader()
        let total = try DDIRepository.requiredFiles.reduce(Int64(0)) { $0 + Int64(try Data(contentsOf: mirror.appending(path: $1)).count) }
        let repository = DDIRepository(baseDirectory: directory, downloader: downloader, verifier: RustLocationEngine.makeDDIVerifier())
        for urls in [DDIRepository.requiredFiles.map { mirror.appending(path: $0) }, [mirror]] {
            let imported = try await repository.importLocalFiles(from: urls)
            let cached = await repository.cachedDirectory(), status = await repository.cacheStatus()
            let release = try XCTUnwrap(cached)
            XCTAssertEqual(imported, .ready(versionID: release.lastPathComponent, totalBytes: total))
            XCTAssertEqual(status, imported)
            XCTAssertEqual(try RustCoreBridge.verifyDDI(at: release), digest)
        }
        let files = await downloader.files
        XCTAssertTrue(files.isEmpty)
    }

    func testInvalidLocalImportsPreservePublishedCache() async throws {
        let directory = try makeTemporaryDirectory(), mirror = directory.appending(path: "mirror")
        let digest = try writeRelease(to: mirror)
        let repository = DDIRepository(baseDirectory: directory, downloader: LocalDDIDownloader(), verifier: RustLocationEngine.makeDDIVerifier())
        let published = try await repository.importLocalFiles(from: [mirror])
        let pointer = directory.appending(path: "current.txt"), version = try Data(contentsOf: pointer)
        for missing in [nil] + DDIRepository.requiredFiles.map(Optional.some) {
            let file = mirror.appending(path: missing ?? "Image.dmg"), original = try Data(contentsOf: file)
            if missing != nil {
                try FileManager.default.removeItem(at: file)
            } else {
                var changed = original
                changed[changed.count - 1] ^= 1
                try changed.write(to: file)
            }
            do {
                _ = try await repository.importLocalFiles(from: [mirror])
                XCTFail("缺件或摘要损坏时不应替换缓存")
            } catch {
                guard case .verificationFailed = error else { return XCTFail("应报告组件校验失败：\(error)") }
            }
            let status = await repository.cacheStatus(), cached = await repository.cachedDirectory()
            XCTAssertEqual(status, published)
            XCTAssertEqual(try Data(contentsOf: pointer), version)
            XCTAssertEqual(try RustCoreBridge.verifyDDI(at: XCTUnwrap(cached)), digest)
            try original.write(to: file)
        }
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

    func testCancellingOneWaiterReturnsWhileOtherWaiterStillDownloads() async throws {
        let directory = try makeTemporaryDirectory(), mirror = directory.appending(path: "mirror")
        let digest = try writeRelease(to: mirror)
        let downloader = LocalDDIDownloader()
        let repository = DDIRepository(baseDirectory: directory, mirrorBaseURL: mirror, downloader: downloader,
                                       verifier: RustLocationEngine.makeDDIVerifier())
        let downloading = expectation(description: "下载已暂停")
        let resume = await downloader.pauseNextDownload { downloading.fulfill() }
        let returned = expectation(description: "已取消的请求独立返回")
        let first = Task {
            defer { returned.fulfill() }
            do throws(DDIRepositoryError) {
                let lease = try await repository.acquirePrepared()
                await repository.release(lease)
                XCTFail("取消的请求不应取得租约")
            } catch { XCTAssertEqual(error, .cancelled) }
        }
        await fulfillment(of: [downloading], timeout: 5)
        let joined = expectation(description: "另一个等待者已加入下载")
        let second = Task {
            try await repository.acquirePrepared { stage in
                if stage == EngineOperationStage.downloadingDDI.rawValue { joined.fulfill() }
            }
        }
        await fulfillment(of: [joined], timeout: 5)
        first.cancel()
        await fulfillment(of: [returned], timeout: 5)
        resume.finish()
        await first.value
        let lease = try await second.value
        XCTAssertEqual(try RustCoreBridge.verifyDDI(at: lease.directory), digest)
        let files = await downloader.files
        XCTAssertEqual(files, DDIRepository.requiredFiles)
        await repository.release(lease)
    }

    func testCancellingLastWaiterCancelsDownloadAndRemovesStaging() async throws {
        let directory = try makeTemporaryDirectory(), mirror = directory.appending(path: "mirror")
        _ = try writeRelease(to: mirror)
        let downloader = LocalDDIDownloader()
        let repository = DDIRepository(baseDirectory: directory, mirrorBaseURL: mirror, downloader: downloader,
                                       verifier: RustLocationEngine.makeDDIVerifier())
        let downloading = expectation(description: "下载已暂停")
        let cancelled = expectation(description: "下载收到取消")
        let returned = expectation(description: "唯一的等待者已返回")
        let resume = await downloader.pauseNextDownload { downloading.fulfill() }
        resume.onTermination = { reason in
            if case .cancelled = reason { cancelled.fulfill() }
        }
        let task = Task {
            defer { returned.fulfill() }
            do throws(DDIRepositoryError) {
                let lease = try await repository.acquirePrepared()
                await repository.release(lease)
                XCTFail("取消的请求不应取得租约")
            } catch { XCTAssertEqual(error, .cancelled) }
        }
        await fulfillment(of: [downloading], timeout: 5)
        let staging = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("staging-") })
        task.cancel()
        await fulfillment(of: [returned, cancelled], timeout: 5)
        resume.finish()
        await task.value
        let deadline = ContinuousClock.now + .seconds(5)
        while FileManager.default.fileExists(atPath: staging.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "current.txt").path))
        let files = await downloader.files
        XCTAssertEqual(files, ["BuildManifest.plist"])
    }

    func testFreshRepositoryReusesPersistedCommitWhenGitHubRateLimits() async throws {
        let directory = try makeTemporaryDirectory(), mirror = directory.appending(path: "mirror")
        let digest = try writeRelease(to: mirror)
        let revision = String(repeating: "0123456789", count: 4)
        for rateLimited in [false, true] {
            let downloader = PinnedMirrorDownloader(mirror: mirror, revision: revision, rateLimited: rateLimited)
            let repository = DDIRepository(baseDirectory: directory, downloader: downloader, verifier: RustLocationEngine.makeDDIVerifier())
            let lease = try await repository.acquirePrepared(forceRefresh: true)
            XCTAssertEqual(try RustCoreBridge.verifyDDI(at: lease.directory), digest)
            XCTAssertEqual(try String(contentsOf: directory.appending(path: "pinned-commit.txt"), encoding: .utf8), revision)
            await repository.release(lease)
        }
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
