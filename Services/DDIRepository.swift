import Foundation

protocol DDIDownloader: Sendable {
    // 本地镜像可借用源 URL。临时下载文件的所有权随返回值转移，以免重复占用大映像的空间。
    func download(from url: URL) async throws -> URL
}

struct URLSessionDDIDownloader: DDIDownloader {
    func download(from url: URL) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("Elsewhere-iOS", forHTTPHeaderField: "User-Agent")
        let (file, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: file)
            throw DDIRepositoryError.httpStatus(http.statusCode)
        }
        return file
    }
}

typealias DDIVerifier = @Sendable (URL) async throws -> String

struct DDIReleaseLease: Sendable {
    let directory: URL
    var versionID: String { directory.lastPathComponent }
    fileprivate let token = UUID()
}

enum DDIRepositoryError: LocalizedError, Equatable, Sendable {
    case httpStatus(Int), verificationFailed(String), storageFailure(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status): String(localized: "开发者组件下载失败（HTTP \(status)）")
        case .verificationFailed(let reason), .storageFailure(let reason): reason
        }
    }
}

actor DDIRepository {
    static let requiredFiles = ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"]

    private let baseDirectory: URL
    private let mirrorBaseURL: URL?
    private let download: @Sendable (URL) async throws -> URL
    private let verifier: DDIVerifier
    private var preparation: Task<Result<URL, DDIRepositoryError>, Never>?
    private var observers: [UUID: @Sendable (String) -> Void] = [:]
    private var stage: String?
    private var leases: [String: Set<UUID>] = [:]
    private var versions: URL { baseDirectory.appending(path: "versions", directoryHint: .isDirectory) }
    private var pointer: URL { baseDirectory.appending(path: "current.txt") }

    init(baseDirectory: URL = URL.applicationSupportDirectory.appending(path: "ElsewhereMobile/DDI"),
         mirrorBaseURL: URL? = URL(string: "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/"),
         downloader: some DDIDownloader = URLSessionDDIDownloader(), verifier: @escaping DDIVerifier) {
        self.baseDirectory = baseDirectory
        self.mirrorBaseURL = mirrorBaseURL
        download = downloader.download(from:)
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

    func acquirePrepared(forceRefresh: Bool = false,
                         onStage: @escaping @Sendable (String) -> Void = { _ in }) async throws(DDIRepositoryError) -> DDIReleaseLease {
        if !forceRefresh {
            while let directory = currentDirectory() {
                if let lease = await verifiedLease(for: directory) { return lease }
                if directory == currentDirectory() { break }
            }
        }
        let observer = UUID()
        observers[observer] = onStage
        if let stage { onStage(stage) }
        let task = preparation ?? Task {
            do throws(DDIRepositoryError) { return .success(try await prepare()) }
            catch { return .failure(error) }
        }
        preparation = task
        // 最后一个等待者取得租约后才能启动下一次刷新，否则迟到的等待者可能拿到已回收的目录。
        defer {
            observers[observer] = nil
            if observers.isEmpty {
                preparation = nil
                stage = nil
            }
        }
        return retain(try await task.value.get())
    }

    func release(_ lease: DDIReleaseLease) {
        guard leases[lease.versionID]?.remove(lease.token) != nil, leases[lease.versionID]?.isEmpty == true else { return }
        leases[lease.versionID] = nil
        if let current = currentDirectory(), current != lease.directory {
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
        for observer in observers.values { observer(value.rawValue) }
    }

    private func verifiedDigest(in directory: URL) async throws(DDIRepositoryError) -> String {
        for name in Self.requiredFiles {
            let file = directory.appending(component: name)
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw .verificationFailed(String(localized: "开发者组件缺少 \(name)"))
            }
        }
        do {
            return try await verifier(directory)
        } catch let error as DDIRepositoryError {
            throw error
        } catch {
            throw .verificationFailed(error.localizedDescription)
        }
    }

    private func pinnedMirror() async throws -> URL {
        guard let mirrorBaseURL else { throw DDIRepositoryError.storageFailure(String(localized: "镜像地址无效")) }
        guard var raw = URLComponents(url: mirrorBaseURL, resolvingAgainstBaseURL: false),
              raw.host == "raw.githubusercontent.com" else { return mirrorBaseURL }
        var path = raw.path.split(separator: "/").map(String.init)
        guard path.count >= 3 else { throw DDIRepositoryError.storageFailure(String(localized: "镜像地址缺少修订")) }
        let revision = path[2]
        if revision.count == 40, revision.allSatisfy(\.isHexDigit) { return mirrorBaseURL }
        var api = URLComponents()
        api.scheme = "https"
        api.host = "api.github.com"
        api.path = "/repos/\(path[0])/\(path[1])/commits/\(revision)"
        // 代理共享出口易触发 GitHub API 限流，解析提交失败时回退到原镜像，仍由摘要校验保证三件配套。
        guard let reference = api.url, let file = try? await download(reference) else { return mirrorBaseURL }
        defer { try? FileManager.default.removeItem(at: file) }
        struct Commit: Decodable { let sha: String }
        guard let commit = try? JSONDecoder().decode(Commit.self, from: Data(contentsOf: file)),
              commit.sha.count == 40, commit.sha.allSatisfy(\.isHexDigit) else { return mirrorBaseURL }
        path[2] = commit.sha
        raw.path = "/" + path.joined(separator: "/") + "/"
        return raw.url ?? mirrorBaseURL
    }

    private func prepare() async throws(DDIRepositoryError) -> URL {
        let fm = FileManager.default
        let staging = baseDirectory.appending(path: "staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: versions, withIntermediateDirectories: true)
            for item in try fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) {
                let name = item.lastPathComponent
                if name.hasPrefix("staging-"), UUID(uuidString: String(name.dropFirst("staging-".count))) != nil {
                    try? fm.removeItem(at: item)
                }
            }
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: staging) }
            report(.downloadingDDI)
            let mirror = try await pinnedMirror()
            for name in Self.requiredFiles {
                let source = mirror.appending(component: name)
                let file = try await download(source)
                let destination = staging.appending(component: name)
                if source.isFileURL, file.standardizedFileURL == source.standardizedFileURL {
                    try fm.copyItem(at: file, to: destination)
                } else {
                    defer { try? fm.removeItem(at: file) }
                    try fm.moveItem(at: file, to: destination)
                }
            }
            report(.verifyingDDI)
            let digest = try await verifiedDigest(in: staging)
            // 同一映像摘要可以配不同的清单或 trust cache，每次发布都要保留独立目录。
            let versionID = "\(digest).\(UUID().uuidString)"
            guard let directory = versionDirectory(named: versionID) else {
                throw DDIRepositoryError.verificationFailed(String(localized: "开发者组件摘要无效"))
            }
            try fm.moveItem(at: staging, to: directory)
            do {
                try Data(versionID.utf8).write(to: pointer, options: .atomic)
            } catch {
                try? fm.removeItem(at: directory)
                throw error
            }
            if let previous = try? fm.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil) {
                for old in previous where old.lastPathComponent != versionID && leases[old.lastPathComponent] == nil {
                    try? fm.removeItem(at: old)
                }
            }
            return directory
        } catch let error as DDIRepositoryError {
            throw error
        } catch {
            throw .storageFailure(error.localizedDescription)
        }
    }
}
