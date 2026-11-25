import CryptoKit
import Foundation
import Network
import os

protocol DDIDownloader: Sendable {
    // 本地镜像可借用源 URL。临时下载文件的所有权随返回值转移，以免重复占用大映像的空间。
    func download(from url: URL) async throws -> URL
}

struct URLSessionDDIDownloader: DDIDownloader {
    func download(from url: URL) async throws -> URL {
        try await download(from: url, proxy: nil, onProgress: nil)
    }

    func download(from url: URL, proxy: ExitProxyAddress?, onProgress: (@Sendable (Double?) -> Void)?) async throws -> URL {
        let session: URLSession
        if let proxy {
            let config = URLSessionConfiguration.ephemeral
            let endpoint = NWEndpoint.hostPort(host: .init(proxy.host), port: .init(rawValue: UInt16(proxy.port))!)
            var proxyConfig = ProxyConfiguration(httpCONNECTProxy: endpoint)
            proxyConfig.allowFailover = false
            config.proxyConfigurations = [proxyConfig]
            session = URLSession(configuration: config)
        } else {
            session = .shared
        }
        defer { if proxy != nil { session.invalidateAndCancel() } }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("Elsewhere-iOS", forHTTPHeaderField: "User-Agent")
        let download = OSAllocatedUnfairLock<URLSessionDownloadTask?>(initialState: nil)
        onProgress?(nil)
        let file: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request)
                task.delegate = DDIDownloadDelegate(continuation: continuation, onProgress: onProgress)
                download.withLock { $0 = task }
                if Task.isCancelled { task.cancel() }
                else { task.resume() }
            }
        } onCancel: {
            download.withLock { $0?.cancel() }
        }
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: file)
            throw CancellationError()
        }
        return file
    }
}

private final class DDIDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let state: OSAllocatedUnfairLock<(continuation: CheckedContinuation<URL, Error>?, progress: Double)>
    private let onProgress: (@Sendable (Double?) -> Void)?

    init(continuation: CheckedContinuation<URL, Error>, onProgress: (@Sendable (Double?) -> Void)?) {
        state = OSAllocatedUnfairLock(initialState: (continuation, 0))
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        state.withLock { state in
            guard progress - state.progress >= 0.02 else { return }
            state.progress = progress
            onProgress?(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let result: Result<URL, Error> = Result {
            guard let http = downloadTask.response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 else { throw DDIRepositoryError.httpStatus(http.statusCode) }
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: file)
            onProgress?(downloadTask.countOfBytesExpectedToReceive > 0 ? 1 : nil)
            return file
        }
        state.withLock { state in
            state.continuation?.resume(with: result)
            state.continuation = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        state.withLock { state in
            state.continuation?.resume(throwing: error)
            state.continuation = nil
        }
    }
}

typealias DDIVerifier = @Sendable (URL) async throws -> String

struct DDIReleaseLease: Sendable {
    let directory: URL
    var versionID: String { directory.lastPathComponent }
    fileprivate let token = UUID()
}

enum DDIRepositoryError: LocalizedError, Equatable, Sendable {
    case cancelled, httpStatus(Int), verificationFailed(String), storageFailure(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: String(localized: "开发者组件准备已取消")
        case .httpStatus(let status): String(localized: "开发者组件下载失败（HTTP \(status)）")
        case .verificationFailed(let reason), .storageFailure(let reason): reason
        }
    }
}

actor DDIRepository {
    static let requiredFiles = ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"]

    private struct Waiter {
        let proxy: ExitProxyAddress?
        let onStage: @Sendable (String) -> Void
        let onProgress: @Sendable (Double?) -> Void
        let continuation: CheckedContinuation<Result<DDIReleaseLease, DDIRepositoryError>, Never>
        var cacheCheck: Task<Void, Never>?
    }

    private let baseDirectory: URL
    private let mirrorBaseURL: URL?
    private let download: @Sendable (URL, ExitProxyAddress?, (@Sendable (Double?) -> Void)?) async throws -> URL
    private let proxyProvider: (@Sendable () async -> ExitProxyAddress?)?
    private let verifier: DDIVerifier
    private var preparation: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var observers: [UUID: Waiter] = [:]
    private var cleanedStaging = false
    private var stage: String?
    private var progress: Double?
    private var leases: [String: Set<UUID>] = [:]
    private var versions: URL { baseDirectory.appending(path: "versions", directoryHint: .isDirectory) }
    private var pointer: URL { baseDirectory.appending(path: "current.txt") }

    init(baseDirectory: URL = URL.applicationSupportDirectory.appending(path: "ElsewhereMobile/DDI"),
         mirrorBaseURL: URL? = URL(string: "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/"),
         downloader: some DDIDownloader = URLSessionDDIDownloader(),
         proxyProvider: (@Sendable () async -> ExitProxyAddress?)? = nil, verifier: @escaping DDIVerifier) {
        self.baseDirectory = baseDirectory
        self.mirrorBaseURL = mirrorBaseURL
        if let downloader = downloader as? URLSessionDDIDownloader {
            download = downloader.download(from:proxy:onProgress:)
        } else {
            download = { url, _, _ in try await downloader.download(from: url) }
        }
        self.proxyProvider = proxyProvider
        self.verifier = verifier
    }

    func cachedDirectory() async -> URL? {
        while let directory = currentDirectory() {
            let lease = await verifiedLease(for: directory)
            if let lease { release(lease) }
            if directory == currentDirectory() { return lease?.directory }
        }
        return nil
    }

    func cacheStatus() async -> DDICacheStatus {
        guard let directory = currentDirectory() else { return .notDownloaded }
        var total: Int64 = 0
        for name in Self.requiredFiles {
            guard let values = try? directory.appending(component: name).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize else { return .notDownloaded }
            total += Int64(size)
        }
        return .ready(versionID: directory.lastPathComponent, totalBytes: total)
    }

    func withCachedDDI<T: Sendable>(operation: @Sendable (URL) async throws -> T) async throws -> T? {
        guard let directory = currentDirectory(), let lease = await verifiedLease(for: directory) else { return nil }
        defer { release(lease) }
        try Task.checkCancellation()
        return try await operation(lease.directory)
    }

    func prepareCache(forceRefresh: Bool = false, proxy: ExitProxyAddress? = nil,
                      onStage: @escaping @Sendable (String) -> Void = { _ in },
                      onProgress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws(DDIRepositoryError) -> DDICacheStatus {
        let lease = try await acquirePrepared(forceRefresh: forceRefresh, proxy: proxy, onStage: onStage, onProgress: onProgress)
        release(lease)
        return await cacheStatus()
    }

    func importLocalFiles(from urls: [URL]) async throws(DDIRepositoryError) -> DDICacheStatus {
        let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let staging = try makeStagingDirectory()
            defer { try? FileManager.default.removeItem(at: staging) }
            let files: [URL]
            if urls.count == 1, let directory = urls.first,
               try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                files = Self.requiredFiles.map { directory.appending(component: $0) }
            } else {
                files = urls
            }
            for name in Self.requiredFiles {
                try Task.checkCancellation()
                guard let source = files.first(where: { $0.lastPathComponent == name }),
                      (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    throw DDIRepositoryError.verificationFailed(String(localized: "开发者组件缺少 \(name)"))
                }
                try FileManager.default.copyItem(at: source, to: staging.appending(component: name))
            }
            let digest = try await verifiedDigest(in: staging)
            try Task.checkCancellation()
            _ = try publish(staging, digest: digest)
            return await cacheStatus()
        } catch let error as DDIRepositoryError {
            throw error
        } catch {
            if Task.isCancelled { throw .cancelled }
            throw .storageFailure(error.localizedDescription)
        }
    }

    func clearCache() throws(DDIRepositoryError) {
        generation &+= 1
        preparation?.cancel()
        preparation = nil
        stage = nil
        progress = nil
        for (id, waiter) in observers where waiter.cacheCheck == nil {
            observers[id] = nil
            waiter.continuation.resume(returning: .failure(.cancelled))
        }
        do {
            do { try FileManager.default.removeItem(at: pointer) } catch CocoaError.fileNoSuchFile {}
            guard FileManager.default.fileExists(atPath: versions.path) else { return }
            for directory in try FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)
                where leases[directory.lastPathComponent] == nil {
                try FileManager.default.removeItem(at: directory)
            }
        } catch {
            throw .storageFailure(error.localizedDescription)
        }
    }

    func acquirePrepared(forceRefresh: Bool = false, proxy: ExitProxyAddress? = nil,
                         onStage: @escaping @Sendable (String) -> Void = { _ in },
                         onProgress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws(DDIRepositoryError) -> DDIReleaseLease {
        let id = UUID()
        let result: Result<DDIReleaseLease, DDIRepositoryError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .failure(.cancelled))
                    return
                }
                observers[id] = Waiter(proxy: proxy, onStage: onStage, onProgress: onProgress, continuation: continuation)
                if !forceRefresh, let directory = currentDirectory() {
                    observers[id]?.cacheCheck = Task { await checkCache(directory, for: id) }
                } else {
                    joinPreparation(id)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        if Task.isCancelled {
            if case .success(let lease) = result { release(lease) }
            throw .cancelled
        }
        return try result.get()
    }

    private func checkCache(_ initial: URL, for id: UUID) async {
        var directory = initial
        while !Task.isCancelled {
            if let lease = await verifiedLease(for: directory) {
                if let waiter = observers.removeValue(forKey: id) {
                    waiter.continuation.resume(returning: .success(lease))
                } else {
                    release(lease)
                }
                return
            }
            guard observers[id] != nil else { return }
            guard let current = currentDirectory(), current != directory else { break }
            directory = current
        }
        guard !Task.isCancelled else { return }
        observers[id]?.cacheCheck = nil
        joinPreparation(id)
    }

    private func joinPreparation(_ id: UUID) {
        if let stage { observers[id]?.onStage(stage) }
        observers[id]?.onProgress(progress)
        guard preparation == nil else { return }
        let proxy = observers[id]?.proxy
        preparation = Task {
            let result: Result<URL, DDIRepositoryError>
            do throws(DDIRepositoryError) { result = .success(try await prepare(proxy: proxy)) }
            catch { result = .failure(error) }
            guard !Task.isCancelled else { return }
            // 在同一轮 actor 调度中为所有等待者保留目录，避免下一次刷新提前回收它。
            for (id, waiter) in observers where waiter.cacheCheck == nil {
                observers[id] = nil
                waiter.continuation.resume(returning: result.map { retain($0) })
            }
            preparation = nil
            stage = nil
            progress = nil
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = observers.removeValue(forKey: id) else { return }
        waiter.cacheCheck?.cancel()
        if observers.values.allSatisfy({ $0.cacheCheck != nil }) {
            preparation?.cancel()
            preparation = nil
            stage = nil
            progress = nil
        }
        waiter.continuation.resume(returning: .failure(.cancelled))
    }

    func release(_ lease: DDIReleaseLease) {
        guard leases[lease.versionID]?.remove(lease.token) != nil, leases[lease.versionID]?.isEmpty == true else { return }
        leases[lease.versionID] = nil
        if currentDirectory() != lease.directory {
            try? FileManager.default.removeItem(at: lease.directory)
        }
    }

    func withPreparedDDI<T: Sendable>(forceRefresh: Bool = false, onStage: @escaping @Sendable (String) -> Void = { _ in },
                                      operation: @Sendable (URL) async throws -> T) async throws -> T {
        let lease = try await acquirePrepared(forceRefresh: forceRefresh, onStage: onStage)
        defer { release(lease) }
        try Task.checkCancellation()
        return try await operation(lease.directory)
    }

    private func retain(_ directory: URL) -> DDIReleaseLease {
        let lease = DDIReleaseLease(directory: directory)
        leases[lease.versionID, default: []].insert(lease.token)
        return lease
    }

    private func verifiedLease(for directory: URL) async -> DDIReleaseLease? {
        let lease = retain(directory)
        if let digest = try? await verifiedDigest(in: directory), digest == directory.deletingPathExtension().lastPathComponent {
            return lease
        }
        release(lease)
        return nil
    }

    private func currentDirectory() -> URL? {
        guard let id = try? String(contentsOf: pointer, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return versionDirectory(named: id)
    }

    private func versionDirectory(named id: String) -> URL? {
        guard let first = id.first, first != ".", id.allSatisfy({ $0.isLetter || $0.isNumber || "-._".contains($0) }) else { return nil }
        return versions.appending(component: id, directoryHint: .isDirectory)
    }

    private func report(_ value: EngineOperationStage) {
        stage = value.rawValue
        for waiter in observers.values where waiter.cacheCheck == nil { waiter.onStage(value.rawValue) }
    }

    private func verifiedDigest(in directory: URL) async throws(DDIRepositoryError) -> String {
        for name in Self.requiredFiles {
            let file = directory.appending(component: name)
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw .verificationFailed(String(localized: "开发者组件缺少 \(name)"))
            }
        }
        do {
            let digestHex = try await verifier(directory)
            let trustCacheData = try Data(contentsOf: directory.appending(component: "Image.dmg.trustcache"))
            guard trustCacheData.count >= 16 else {
                throw DDIRepositoryError.verificationFailed(String(localized: "开发者组件 trust cache 无效"))
            }
            let manifest = try PropertyListSerialization.propertyList(from: Data(contentsOf: directory.appending(component: "BuildManifest.plist")), format: nil) as? NSDictionary
            for identity in manifest?["BuildIdentities"] as? [NSDictionary] ?? [] {
                guard let components = identity["Manifest"] as? [String: NSDictionary],
                      let digest = components["PersonalizedDMG"]?["Digest"] as? Data,
                      digest.map({ String(format: "%02x", $0) }).joined() == digestHex,
                      let expectedDigest = components["LoadableTrustCache"]?["Digest"] as? Data else { continue }
                guard Data(SHA384.hash(data: trustCacheData)) == expectedDigest else {
                    throw DDIRepositoryError.verificationFailed(String(localized: "开发者组件 trust cache 摘要不匹配"))
                }
            }
            return digestHex
        } catch let error as DDIRepositoryError {
            throw error
        } catch {
            throw .verificationFailed(error.localizedDescription)
        }
    }

    private func pinnedMirror(proxy: ExitProxyAddress?) async throws -> URL {
        guard let mirrorBaseURL else { throw DDIRepositoryError.storageFailure(String(localized: "镜像地址无效")) }
        guard var raw = URLComponents(url: mirrorBaseURL, resolvingAgainstBaseURL: false),
              raw.host == "raw.githubusercontent.com" else { return mirrorBaseURL }
        var path = raw.path.split(separator: "/").map(String.init)
        guard path.count >= 3 else { throw DDIRepositoryError.storageFailure(String(localized: "镜像地址缺少修订")) }
        let revision = path[2]
        func validSHA(_ value: String) -> Bool {
            value.utf8.count == 40 && value.allSatisfy { $0.isASCII && $0.isHexDigit }
        }
        if validSHA(revision) { return mirrorBaseURL }
        var api = URLComponents()
        api.scheme = "https"
        api.host = "api.github.com"
        api.path = "/repos/\(path[0])/\(path[1])/commits/\(revision)"
        let pin = baseDirectory.appending(path: "pinned-commit.txt")
        struct Commit: Decodable { let sha: String }
        var sha: String?
        if let reference = api.url, let file = try? await download(reference, proxy, nil) {
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            if let commit = try? JSONDecoder().decode(Commit.self, from: Data(contentsOf: file)), validSHA(commit.sha) {
                try Data(commit.sha.utf8).write(to: pin, options: .atomic)
                sha = commit.sha
            }
        }
        try Task.checkCancellation()
        guard let pinned = sha ?? (try? String(contentsOf: pin, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
              validSHA(pinned) else { return mirrorBaseURL }
        path[2] = pinned
        raw.path = "/" + path.joined(separator: "/") + "/"
        return raw.url ?? mirrorBaseURL
    }

    private func prepare(proxy: ExitProxyAddress?) async throws(DDIRepositoryError) -> URL {
        let startGeneration = generation
        let fm = FileManager.default
        let (events, signal) = AsyncStream<Double?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let display = Task {
            for await value in events {
                guard !Task.isCancelled else { return }
                progress = value
                for waiter in observers.values where waiter.cacheCheck == nil { waiter.onProgress(value) }
            }
        }
        defer { signal.finish(); display.cancel() }
        do {
            try Task.checkCancellation()
            let staging = try makeStagingDirectory()
            defer { try? fm.removeItem(at: staging) }
            report(.downloadingDDI)
            let proxy = if let proxy { proxy } else { await proxyProvider?() }
            let mirror = try await pinnedMirror(proxy: proxy)
            for name in Self.requiredFiles {
                try Task.checkCancellation()
                let source = mirror.appending(component: name)
                let file = try await download(source, proxy, name == "Image.dmg" ? { @Sendable (value: Double?) -> Void in signal.yield(value) } : nil)
                let destination = staging.appending(component: name)
                if source.isFileURL, file.standardizedFileURL == source.standardizedFileURL {
                    try Task.checkCancellation()
                    try fm.copyItem(at: file, to: destination)
                } else {
                    defer { try? fm.removeItem(at: file) }
                    try Task.checkCancellation()
                    try fm.moveItem(at: file, to: destination)
                }
            }
            try Task.checkCancellation()
            report(.verifyingDDI)
            let digest = try await verifiedDigest(in: staging)
            try Task.checkCancellation()
            guard generation == startGeneration else { throw DDIRepositoryError.cancelled }
            return try publish(staging, digest: digest)
        } catch let error as DDIRepositoryError {
            throw error
        } catch {
            if Task.isCancelled { throw .cancelled }
            throw .storageFailure(error.localizedDescription)
        }
    }

    private func makeStagingDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        if !cleanedStaging {
            for item in try FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) {
                let name = item.lastPathComponent
                if name.hasPrefix("staging-"), UUID(uuidString: String(name.dropFirst("staging-".count))) != nil {
                    try? FileManager.default.removeItem(at: item)
                }
            }
            cleanedStaging = true
        }
        let staging = baseDirectory.appending(path: "staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        return staging
    }

    private func publish(_ staging: URL, digest: String) throws -> URL {
        // 同一映像摘要可以配不同的清单或 trust cache，每次发布都要保留独立目录。
        let versionID = "\(digest).\(UUID().uuidString)"
        guard let directory = versionDirectory(named: versionID) else {
            throw DDIRepositoryError.verificationFailed(String(localized: "开发者组件摘要无效"))
        }
        try FileManager.default.moveItem(at: staging, to: directory)
        do {
            try Data(versionID.utf8).write(to: pointer, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        if let previous = try? FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil) {
            for old in previous where old.lastPathComponent != versionID && leases[old.lastPathComponent] == nil {
                try? FileManager.default.removeItem(at: old)
            }
        }
        return directory
    }
}
