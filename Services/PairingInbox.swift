import Foundation

struct PendingPairingItem: Codable, Equatable, Sendable {
    let id: UUID
    let suggestedName: String?
    let data: Data
    let receivedAt: Date
}

enum PairingInboxError: LocalizedError, Equatable, Sendable {
    case containerUnavailable, emptyFile, fileTooLarge, unreadableFile, storageFailure

    var errorDescription: String? {
        switch self {
        case .containerUnavailable: String(localized: "无法访问共享收件箱")
        case .emptyFile: String(localized: "配对文件为空")
        case .fileTooLarge: String(localized: "配对文件超过 512 KB")
        case .unreadableFile: String(localized: "无法读取配对文件")
        case .storageFailure: String(localized: "无法写入受保护的配对收件箱")
        }
    }
}

struct PairingInbox: Sendable {
    static var appGroupID: String { AppIdentifiers.current.importAppGroup ?? "group.com.elsewhere.mobile.import" }
    static let maxFileBytes = 512 * 1024
    static let expirationInterval: TimeInterval = 600

    private let directory: URL?
    private let now: @Sendable () -> Date

    private static var defaultDirectory: URL? {
        guard AppIdentifiers.current.importAppGroup != nil else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appending(path: "PairingInbox", directoryHint: .isDirectory)
    }

    init(directory: URL? = PairingInbox.defaultDirectory,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    func enqueue(data: Data, suggestedName: String?) throws(PairingInboxError) -> UUID {
        guard !data.isEmpty else { throw .emptyFile }
        guard data.count <= Self.maxFileBytes else { throw .fileTooLarge }
        guard var directory else { throw .containerUnavailable }
        let item = PendingPairingItem(id: UUID(), suggestedName: suggestedName, data: data, receivedAt: now())
        let file = directory.appending(path: "\(item.receivedAt.timeIntervalSinceReferenceDate)_\(item.id).plist")
        var staging = file.appendingPathExtension("pending")
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            try directory.setResourceValues(values)
            _ = try pendingFiles(in: directory, at: item.receivedAt)
            defer { try? FileManager.default.removeItem(at: staging) }
            try PropertyListEncoder().encode(item).write(to: staging, options: .completeFileProtection)
            try staging.setResourceValues(values)
            try FileManager.default.moveItem(at: staging, to: file)
        } catch {
            throw .storageFailure
        }
        return item.id
    }

    func enqueue(fileURL: URL) throws(PairingInboxError) -> UUID {
        var data = Data()
        do {
            let scoped = fileURL.startAccessingSecurityScopedResource()
            defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
            let file = try FileHandle(forReadingFrom: fileURL)
            defer { try? file.close() }
            while data.count <= Self.maxFileBytes,
                  let chunk = try file.read(upToCount: Self.maxFileBytes + 1 - data.count), !chunk.isEmpty {
                data.append(chunk)
            }
        } catch {
            throw .unreadableFile
        }
        return try enqueue(data: data, suggestedName: fileURL.lastPathComponent)
    }

    func pendingItems() -> [PendingPairingItem] {
        let date = now()
        guard let directory, let files = try? pendingFiles(in: directory, at: date) else { return [] }
        return files.compactMap { file -> PendingPairingItem? in
            guard let data = try? Data(contentsOf: file) else { return nil }
            guard let item = try? PropertyListDecoder().decode(PendingPairingItem.self, from: data),
                  date.timeIntervalSince(item.receivedAt) < Self.expirationInterval else {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            return item
        }.sorted { $0.receivedAt < $1.receivedAt }
    }

    func acknowledge(id: UUID) {
        guard let directory else { return }
        _ = acknowledge(id: id, in: directory)
    }

    func drainPending() -> [PendingPairingItem] {
        guard let directory else { return [] }
        return pendingItems().filter { acknowledge(id: $0.id, in: directory) }
    }

    private func acknowledge(id: UUID, in directory: URL) -> Bool {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return false }
        func matches(_ file: URL) -> Bool {
            guard file.pathExtension == "plist" else { return false }
            return (try? PropertyListDecoder().decode(PendingPairingItem.self, from: Data(contentsOf: file)))?.id == id
        }
        if let named = files.first(where: { $0.lastPathComponent.hasSuffix("_\(id).plist") }), matches(named) {
            return (try? fm.removeItem(at: named)) != nil
        }
        guard let file = files.first(where: matches) else { return false }
        return (try? fm.removeItem(at: file)) != nil
    }

    private func pendingFiles(in directory: URL, at date: Date) throws -> [URL] {
        let cutoff = date.timeIntervalSinceReferenceDate - Self.expirationInterval
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return files.filter { file in
            // 时间戳也在暂存文件名中，扩展被中断后仍能清理未写完整的凭据。
            if let received = TimeInterval(file.lastPathComponent.prefix { $0 != "_" }), received <= cutoff {
                try? FileManager.default.removeItem(at: file)
                return false
            }
            return file.pathExtension == "plist"
        }
    }
}
