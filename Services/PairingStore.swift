import CryptoKit
import Darwin
import Foundation

struct PairingInspection: Codable, Equatable, Sendable {
    let udid: DeviceID?
    let hostID: String
    let systemBUID: String
    let wifiMACAddress: String?
    let hasEscrowBag: Bool
}

struct StoredPairingRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var udid: DeviceID?
    var deviceName: String?
    var endpointHost: String
    let hostID: String
    let systemBUID: String
    let wifiMACAddress: String?
    let importedAt: Date
    var lastVerifiedAt: Date?
}

enum PairingStoreError: LocalizedError, Equatable, Sendable {
    case fileTooLarge, unreadableFile, invalidPairing(String), remotePairingUnsupported
    case recordNotFound, cryptoFailure, storageFailure(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: String(localized: "配对文件超过 512 KB")
        case .unreadableFile: String(localized: "无法读取配对文件")
        case .invalidPairing(let reason), .storageFailure(let reason): reason
        case .remotePairingUnsupported: String(localized: "请导入 Lockdown 配对记录，此记录使用 RemotePairing 格式")
        case .recordNotFound: String(localized: "找不到配对记录")
        case .cryptoFailure: String(localized: "无法加密或解密配对记录")
        }
    }
}

actor PairingStore {
    static let maxFileBytes = 512 * 1024

    private let baseDirectory: URL
    private let keyProvider: any PairingKeyProvider
    private let inspector: @Sendable (Data) async throws -> PairingInspection
    private var needsCleanup = true
    private var indexURL: URL { baseDirectory.appending(path: "index.json") }

    init(baseDirectory: URL = URL.applicationSupportDirectory.appending(path: "ElsewhereMobile/Pairings"),
         keyProvider: any PairingKeyProvider = KeychainPairingKeyProvider(),
         inspector: @escaping @Sendable (Data) async throws -> PairingInspection) {
        self.baseDirectory = baseDirectory
        self.keyProvider = keyProvider
        self.inspector = inspector
    }

    func records() throws(PairingStoreError) -> [StoredPairingRecord] {
        let records: [StoredPairingRecord]
        do {
            records = try JSONDecoder().decode([StoredPairingRecord].self, from: Data(contentsOf: indexURL))
        } catch CocoaError.fileReadNoSuchFile {
            records = []
        } catch {
            throw .storageFailure(String(localized: "无法读取配对索引"))
        }
        // 索引决定哪些密钥仍在用。中断后，孤立密文的文件名保留了待清理的 Keychain 账号。
        if needsCleanup, let files = try? FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) {
            needsCleanup = false
            let active = Set(records.map(\.id))
            for file in files where file.pathExtension == "enc" {
                if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !active.contains(id) {
                    try? removeCredentials(for: id)
                }
            }
        }
        return records
    }

    func importPairing(data: Data, endpointHost: String, deviceName: String?) async throws(PairingStoreError) -> StoredPairingRecord {
        guard !data.isEmpty else { throw .invalidPairing(String(localized: "配对文件为空")) }
        guard data.count <= Self.maxFileBytes else { throw .fileTooLarge }
        let inspection: PairingInspection
        do {
            inspection = try await inspector(data)
        } catch PairingStoreError.remotePairingUnsupported {
            throw .remotePairingUnsupported
        } catch {
            throw .invalidPairing(String(localized: "Lockdown 配对内容校验失败"))
        }

        let existing = try records()
        let retired = Set(existing.filter { record in
            if let udid = inspection.udid { return record.udid == udid }
            return record.udid == nil && record.hostID == inspection.hostID
        }.map(\.id))
        let record = StoredPairingRecord(id: UUID(), udid: inspection.udid, deviceName: deviceName, endpointHost: endpointHost,
                                         hostID: inspection.hostID, systemBUID: inspection.systemBUID,
                                         wifiMACAddress: inspection.wifiMACAddress, importedAt: Date(), lastVerifiedAt: nil)
        let key = SymmetricKey(size: .bits256)
        guard let sealed = try? AES.GCM.seal(data, using: key).combined else { throw .cryptoFailure }
        try writeProtected(sealed, to: encryptedURL(for: record.id))
        do {
            try keyProvider.saveKeyData(key.withUnsafeBytes { Data($0) }, for: record.id.uuidString)
            try saveIndex(existing.filter { !retired.contains($0.id) } + [record])
        } catch {
            try removeCredentials(for: record.id)
            throw .storageFailure(String(localized: "无法保存新配对记录"))
        }
        for id in retired { try? removeCredentials(for: id) }
        return record
    }

    func importPairing(fromSecurityScopedURL url: URL, endpointHost: String,
                       deviceName: String?) async throws(PairingStoreError) -> StoredPairingRecord {
        var data = Data()
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            while data.count <= Self.maxFileBytes,
                  let chunk = try file.read(upToCount: Self.maxFileBytes + 1 - data.count), !chunk.isEmpty {
                data.append(chunk)
            }
        } catch {
            throw .unreadableFile
        }
        return try await importPairing(data: data, endpointHost: endpointHost, deviceName: deviceName)
    }

    func pairingBytes(for id: UUID) throws(PairingStoreError) -> Data {
        guard try records().contains(where: { $0.id == id }) else { throw .recordNotFound }
        let encrypted: Data
        let key: Data?
        do {
            encrypted = try Data(contentsOf: encryptedURL(for: id))
            key = try keyProvider.keyData(for: id.uuidString)
        } catch {
            throw .storageFailure(String(localized: "无法读取配对密文或密钥"))
        }
        guard let key else { throw .cryptoFailure }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: SymmetricKey(data: key))
        } catch {
            throw .cryptoFailure
        }
    }

    func bindIdentity(recordID: UUID, udid: DeviceID, deviceName: String,
                      verifiedAt: Date = Date()) throws(PairingStoreError) -> StoredPairingRecord {
        var records = try records()
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { throw .recordNotFound }
        if let bound = records[index].udid, bound != udid {
            throw .invalidPairing(String(localized: "认证设备与这份配对记录的设备不一致"))
        }
        guard !records.contains(where: { $0.udid == udid && $0.id != recordID }) else {
            throw .invalidPairing(String(localized: "此设备已绑定另一份配对记录"))
        }
        records[index].udid = udid
        records[index].deviceName = deviceName
        records[index].lastVerifiedAt = verifiedAt
        try saveIndex(records)
        return records[index]
    }

    func updateEndpointHost(_ host: String, for id: UUID) throws(PairingStoreError) -> StoredPairingRecord {
        var records = try records()
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw .recordNotFound }
        records[index].endpointHost = host
        try saveIndex(records)
        return records[index]
    }

    func delete(id: UUID) throws(PairingStoreError) {
        let existing = try records()
        let remaining = existing.filter { $0.id != id }
        if remaining.count != existing.count {
            try saveIndex(remaining)
        } else if !FileManager.default.fileExists(atPath: encryptedURL(for: id).path) {
            return
        }
        try removeCredentials(for: id)
    }

    private func encryptedURL(for id: UUID) -> URL {
        baseDirectory.appending(path: "\(id.uuidString).enc")
    }

    private func removeCredentials(for id: UUID) throws(PairingStoreError) {
        do {
            try keyProvider.deleteKeyData(for: id.uuidString)
            do { try FileManager.default.removeItem(at: encryptedURL(for: id)) }
            catch CocoaError.fileNoSuchFile { return }
        } catch {
            needsCleanup = true
            throw .storageFailure(String(localized: "配对凭据尚未清理，请解锁后重试"))
        }
    }

    private func saveIndex(_ records: [StoredPairingRecord]) throws(PairingStoreError) {
        guard let data = try? JSONEncoder().encode(records) else { throw .storageFailure(String(localized: "无法编码配对索引")) }
        try writeProtected(data, to: indexURL)
    }

    private func writeProtected(_ data: Data, to destination: URL) throws(PairingStoreError) {
        var directory = baseDirectory
        var pending = directory.appending(path: ".pending")
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            try directory.setResourceValues(values)
            try data.write(to: pending, options: [.atomic, .completeFileProtection])
            defer { try? FileManager.default.removeItem(at: pending) }
            try pending.setResourceValues(values)
            // 保护属性也须先就绪，否则切换索引后的失败会被误当成可以回滚。
            guard Darwin.rename(pending.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        } catch {
            throw .storageFailure(String(localized: "无法写入受保护的配对存储"))
        }
    }
}
