import Foundation
import os
import Security

protocol PairingKeyProvider: Sendable {
    func keyData(for account: String) throws -> Data?
    func saveKeyData(_ data: Data, for account: String) throws
    func deleteKeyData(for account: String) throws
}

enum KeychainStoreError: LocalizedError, Equatable, Sendable {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let status): String(localized: "无法访问配对密钥（OSStatus \(status)）")
        }
    }
}

struct KeychainPairingKeyProvider: PairingKeyProvider {
    private func query(for account: String) -> [CFString: CFTypeRef] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: AppIdentifiers.current.keychainService as CFString,
         kSecAttrAccount: account as CFString]
    }

    func keyData(for account: String) throws(KeychainStoreError) -> Data? {
        var search = query(for: account)
        search[kSecReturnData] = kCFBooleanTrue
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw .status(status) }
        guard let data = result as? Data else { throw .status(errSecDecode) }
        return data
    }

    func saveKeyData(_ data: Data, for account: String) throws(KeychainStoreError) {
        let search = query(for: account)
        let attributes: [CFString: CFTypeRef] = [kSecValueData: data as CFData,
                                                 kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemAdd(search.merging(attributes) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(search as CFDictionary, attributes as CFDictionary)
        }
        guard status == errSecSuccess else { throw .status(status) }
    }

    func deleteKeyData(for account: String) throws(KeychainStoreError) {
        let status = SecItemDelete(query(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .status(status) }
    }
}

final class InMemoryPairingKeyProvider: PairingKeyProvider {
    private let keys = OSAllocatedUnfairLock(initialState: [String: Data]())

    func keyData(for account: String) -> Data? {
        keys.withLock { $0[account] }
    }

    func saveKeyData(_ data: Data, for account: String) {
        keys.withLock { $0[account] = data }
    }

    func deleteKeyData(for account: String) {
        keys.withLock { $0[account] = nil }
    }
}
