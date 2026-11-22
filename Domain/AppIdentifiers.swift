import Foundation

struct AppIdentifiers: Equatable, Sendable {
    static let current = AppIdentifiers(bundleIdentifier: Bundle.main.bundleIdentifier,
                                        infoDictionary: Bundle.main.infoDictionary ?? [:])

    let hostBundleID: String
    let tunnelProviderBundleID: String?
    let snapshotAppGroup: String?
    let importAppGroup: String?
    let backgroundRefreshID: String
    var keychainService: String { "\(hostBundleID).pairing-keys" }
    var modePreferencesSuite: String { "\(hostBundleID).mode" }

    init(bundleIdentifier: String?, infoDictionary: [String: Any]) {
        var hostID = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while let suffix = [".widgets", ".tunnel", ".pairingimport", ".free"].first(where: { hostID.hasSuffix($0) }) {
            hostID.removeLast(suffix.count)
        }
        if hostID.isEmpty { hostID = "com.elsewhere.mobile" }
        hostBundleID = hostID

        func configured(_ key: String, fallback: String) -> String? {
            guard let value = infoDictionary[key] as? String else { return fallback }
            if value.isEmpty { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : trimmed
        }

        let derivedTunnel = hostID + ".tunnel"
        let prefix = hostID + "."
        tunnelProviderBundleID = configured("ElsewhereTunnelBundleID", fallback: derivedTunnel).map {
            $0.hasPrefix(prefix) ? $0 : derivedTunnel
        }
        snapshotAppGroup = configured("ElsewhereSnapshotAppGroup", fallback: "group.\(hostID).snapshot")
        importAppGroup = configured("ElsewhereImportAppGroup", fallback: "group.\(hostID).import")
        backgroundRefreshID = (infoDictionary["BGTaskSchedulerPermittedIdentifiers"] as? [Any])?
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            ?? "\(hostID).exit-refresh"
    }
}

struct AppCapabilities: Equatable, Sendable {
    enum BuildKind: Equatable, Sendable { case full, partial, sideloadFree }

    static let current = AppCapabilities(identifiers: .current, plugInsURL: Bundle.main.builtInPlugInsURL)

    let hasBuiltInTunnel: Bool
    let resolvedTunnelProviderBundleID: String?
    let hasSnapshotAppGroup: Bool
    let hasImportAppGroup: Bool

    var buildKind: BuildKind {
        if hasBuiltInTunnel && hasSnapshotAppGroup && hasImportAppGroup { return .full }
        if hasBuiltInTunnel || hasSnapshotAppGroup || hasImportAppGroup { return .partial }
        return .sideloadFree
    }

    init(hasBuiltInTunnel: Bool, resolvedTunnelProviderBundleID: String?, hasSnapshotAppGroup: Bool, hasImportAppGroup: Bool) {
        self.hasBuiltInTunnel = hasBuiltInTunnel
        self.resolvedTunnelProviderBundleID = resolvedTunnelProviderBundleID
        self.hasSnapshotAppGroup = hasSnapshotAppGroup
        self.hasImportAppGroup = hasImportAppGroup
    }

    init(identifiers: AppIdentifiers, plugInsURL: URL?, canAccessGroup: (String) -> Bool = {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
    }) {
        hasSnapshotAppGroup = identifiers.snapshotAppGroup.map(canAccessGroup) ?? false
        hasImportAppGroup = identifiers.importAppGroup.map(canAccessGroup) ?? false
        guard let configuredID = identifiers.tunnelProviderBundleID else {
            hasBuiltInTunnel = false
            resolvedTunnelProviderBundleID = nil
            return
        }

        let entries = plugInsURL.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
        var foundTunnel = false
        var discoveredIDs = [String]()
        for entry in entries where entry.pathExtension == "appex" {
            guard let data = try? Data(contentsOf: entry.appending(path: "Info.plist")),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let ext = plist["NSExtension"] as? [String: Any],
                  ext["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel" else { continue }
            foundTunnel = true
            if let value = plist["CFBundleIdentifier"] as? String {
                let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty { discoveredIDs.append(id) }
            }
        }
        hasBuiltInTunnel = foundTunnel
        resolvedTunnelProviderBundleID = discoveredIDs.contains(configuredID) ? configuredID : (discoveredIDs.min() ?? configuredID)
    }
}
