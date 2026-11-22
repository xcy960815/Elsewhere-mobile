import CryptoKit
import XCTest
@testable import ElsewhereMobile

extension XCTestCase {
    func makeTemporaryDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    func makePairingStore() throws -> (PairingStore, URL, InMemoryPairingKeyProvider) {
        let directory = try makeTemporaryDirectory()
        let keys = InMemoryPairingKeyProvider()
        return (PairingStore(baseDirectory: directory, keyProvider: keys, inspector: RustLocationEngine.makePairingInspector()), directory, keys)
    }
}

struct LockdownPlist: Encodable {
    var udid: String?
    var hostID = "test-host"
    var hostKey = LockdownPlist.key

    private static let certificate = Data("""
        -----BEGIN CERTIFICATE-----
        MIIBnDCCAUOgAwIBAgIUARtHevn3WSceKenp57gKZHlTBH8wCgYIKoZIzj0EAwIw
        JDEiMCAGA1UEAwwZRWxzZXdoZXJlIE9mZmxpbmUgRml4dHVyZTAeFw0yNjExMjIw
        NDMzNDRaFw0zNjExMTkwNDMzNDRaMCQxIjAgBgNVBAMMGUVsc2V3aGVyZSBPZmZs
        aW5lIEZpeHR1cmUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATdXL19bGCBF1yg
        8jgBg6GnQVIgiOBGDjrRpiXeG1h9Fv7vPZQzZQd5aUTZ1j1NJ7X5KnyHcSwpENHW
        SZfMRXZBo1MwUTAdBgNVHQ4EFgQUA7d1wjIegiAPMzDyPAZnRQmqVkowHwYDVR0j
        BBgwFoAUA7d1wjIegiAPMzDyPAZnRQmqVkowDwYDVR0TAQH/BAUwAwEB/zAKBggq
        hkjOPQQDAgNHADBEAiBkyyYD0XZDLWbCcnVvAz/ndlIHl+sBTGfMpOFhxqrgCgIg
        C+qyH/UnttrOzrJq/WixDTTktscsCY+exsYOAz5zgWU=
        -----END CERTIFICATE-----

        """.utf8)
    private static let key = Data("""
        -----BEGIN PRIVATE KEY-----
        MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgf6BtYyfyIC6wfsf7
        zUpzshBdhQ7ReuNZePYHm1qPevihRANCAATdXL19bGCBF1yg8jgBg6GnQVIgiOBG
        DjrRpiXeG1h9Fv7vPZQzZQd5aUTZ1j1NJ7X5KnyHcSwpENHWSZfMRXZB
        -----END PRIVATE KEY-----

        """.utf8)

    private enum Keys: String, CodingKey {
        case UDID, HostID, SystemBUID, WiFiMACAddress, HostPrivateKey, RootPrivateKey, HostCertificate, RootCertificate, DeviceCertificate, EscrowBag
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: Keys.self)
        try fields.encodeIfPresent(udid, forKey: .UDID)
        try fields.encode(hostID, forKey: .HostID)
        try fields.encode("test-system", forKey: .SystemBUID)
        try fields.encode("02:00:00:00:00:01", forKey: .WiFiMACAddress)
        for field in [Keys.HostCertificate, .RootCertificate, .DeviceCertificate] {
            try fields.encode(Self.certificate, forKey: field)
        }
        try fields.encode(hostKey, forKey: .HostPrivateKey)
        try fields.encode(Self.key, forKey: .RootPrivateKey)
        try fields.encode(Data("test escrow secret".utf8), forKey: .EscrowBag)
    }

    func data(_ format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = format
        return try encoder.encode(self)
    }

    static func assertNoCredentials(in text: String, file: StaticString = #filePath, line: UInt = #line) {
        for marker in ["-----BEGIN", "PRIVATE KEY", "CERTIFICATE", "MIGHAgEAMBMG", "MIIBnDCCAUOg", "test escrow secret", "damaged-test-key"] {
            XCTAssertFalse(text.contains(marker), "错误详情中出现配对凭据", file: file, line: line)
        }
    }
}

final class PairingStoreTests: XCTestCase {
    func testXMLAndBinaryImportsEncryptAndRoundTripWithAndWithoutUDID() async throws {
        let (store, directory, _) = try makePairingStore()
        let formats: [PropertyListSerialization.PropertyListFormat] = [.xml, .binary]
        for format in formats {
            for udid in [nil, "test-device"] {
                let data = try LockdownPlist(udid: udid).data(format)
                XCTAssertEqual(data.starts(with: "bplist00".utf8), format == .binary)
                let record = try await store.importPairing(data: data, endpointHost: "::1", deviceName: nil)
                XCTAssertEqual(record.udid, udid.flatMap(DeviceID.init(rawValue:)))
                XCTAssertEqual(record.hostID, "test-host")
                XCTAssertEqual(record.systemBUID, "test-system")
                XCTAssertEqual(record.wifiMACAddress, "02:00:00:00:00:01")
                let sealed = try Data(contentsOf: directory.appending(path: "\(record.id.uuidString).enc"))
                for marker in ["<?xml", "bplist00", "HostPrivateKey", "-----BEGIN", "MIGHAgEAMBMG", "test escrow secret"] {
                    XCTAssertNil(sealed.range(of: Data(marker.utf8)))
                }
                let recovered = try await store.pairingBytes(for: record.id)
                XCTAssertEqual(recovered, data)
            }
        }
    }

    func testFileImportEnforces512KiBLimit() async throws {
        let (store, _, _) = try makePairingStore()
        let url = try makeTemporaryDirectory().appending(path: "test.mobiledevicepairing")
        let data = try LockdownPlist().data(.binary)
        try data.write(to: url)
        let record = try await store.importPairing(fromSecurityScopedURL: url, endpointHost: "::1", deviceName: nil)
        let recovered = try await store.pairingBytes(for: record.id)
        XCTAssertEqual(recovered, data)
        try Data(repeating: 0, count: 512 * 1024 + 1).write(to: url)
        do {
            _ = try await store.importPairing(fromSecurityScopedURL: url, endpointHost: "::1", deviceName: nil)
            XCTFail("超过 512 KB 的配对文件不应被导入")
        } catch {
            XCTAssertEqual(error, .fileTooLarge)
        }
    }

    func testRemotePairingIsRecognizedAndRejected() async throws {
        struct Remote: Encodable {
            let identifier = "remote-test"
            let private_key = Data(repeating: 7, count: 32), public_key = Data(repeating: 8, count: 32)
        }
        let (store, _, _) = try makePairingStore()
        let data = try PropertyListEncoder().encode(Remote())
        XCTAssertEqual(try RustCoreBridge.inspectPairing(data), .remotePairing)
        do {
            _ = try await store.importPairing(data: data, endpointHost: "::1", deviceName: nil)
            XCTFail("RemotePairing 不应被导入为 Lockdown 配对")
        } catch {
            XCTAssertEqual(error, .remotePairingUnsupported)
        }
    }

    func testInvalidInputsLeaveNoRecordsOrCredentialDetails() async throws {
        let (store, _, _) = try makePairingStore()
        let broken = try LockdownPlist(hostKey: Data("damaged-test-key".utf8)).data()
        let mismatched = try LockdownPlist(hostKey: Data(P256.Signing.PrivateKey().pemRepresentation.utf8)).data(.binary)
        for data in [Data(), Data("broken plist".utf8), broken, mismatched] {
            do {
                _ = try await store.importPairing(data: data, endpointHost: "::1", deviceName: nil)
                XCTFail("损坏的配对记录不应被导入")
            } catch {
                guard case .invalidPairing = error else { return XCTFail("应报告无效配对") }
                LockdownPlist.assertNoCredentials(in: error.localizedDescription)
            }
            do {
                _ = try RustCoreBridge.inspectPairing(data)
                XCTFail("引擎不应接受损坏的配对记录")
            } catch {
                XCTAssertEqual(error.code, .invalid_input)
                LockdownPlist.assertNoCredentials(in: error.message + (error.rawDetail ?? ""))
            }
        }
        let records = try await store.records()
        XCTAssertTrue(records.isEmpty)
    }

    func testReimportReplacesCredentialsAndDeletingUpdatedEndpointCleansUp() async throws {
        let (store, directory, keys) = try makePairingStore()
        let plist = LockdownPlist(udid: "test-device")
        let first = try await store.importPairing(data: plist.data(), endpointHost: "::1", deviceName: nil)
        let oldFile = directory.appending(path: "\(first.id.uuidString).enc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertNotNil(keys.keyData(for: first.id.uuidString))
        let data = try plist.data(.binary)
        let next = try await store.importPairing(data: data, endpointHost: "::1", deviceName: "iPad")
        XCTAssertNotEqual(next.id, first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertNil(keys.keyData(for: first.id.uuidString))
        XCTAssertNotNil(keys.keyData(for: next.id.uuidString))
        let recovered = try await store.pairingBytes(for: next.id)
        XCTAssertEqual(recovered, data)
        let updated = try await store.updateEndpointHost("127.0.0.1", for: next.id)
        XCTAssertEqual(updated.endpointHost, "127.0.0.1")
        let records = try await store.records()
        XCTAssertEqual(records, [updated])
        try await store.delete(id: updated.id)
        let remaining = try await store.records()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(keys.keyData(for: updated.id.uuidString))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "\(updated.id.uuidString).enc").path))
    }

    func testBindingPersistsIdentityAndRejectsBothConflicts() async throws {
        let (store, _, _) = try makePairingStore()
        let first = try await store.importPairing(data: LockdownPlist().data(), endpointHost: "::1", deviceName: nil)
        let second = try await store.importPairing(data: LockdownPlist(hostID: "another-host").data(), endpointHost: "127.0.0.1", deviceName: nil)
        let phone = try XCTUnwrap(DeviceID(rawValue: "phone")), pad = try XCTUnwrap(DeviceID(rawValue: "pad"))
        let date = Date(timeIntervalSince1970: 1000)
        let bound = try await store.bindIdentity(recordID: first.id, udid: phone, deviceName: "iPhone", verifiedAt: date)
        XCTAssertEqual(bound.udid, phone)
        XCTAssertEqual(bound.deviceName, "iPhone")
        XCTAssertEqual(bound.lastVerifiedAt, date)
        for (id, conflictingID) in [(first.id, pad), (second.id, phone)] {
            do {
                _ = try await store.bindIdentity(recordID: id, udid: conflictingID, deviceName: "冲突")
                XCTFail("身份冲突不应覆盖配对绑定")
            } catch {
                guard case .invalidPairing = error else { return XCTFail("应报告配对身份冲突") }
            }
        }
        let records = try await store.records()
        XCTAssertEqual(records, [bound, second])
    }
}
