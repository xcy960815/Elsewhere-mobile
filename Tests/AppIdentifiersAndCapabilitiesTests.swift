import NetworkExtension
import XCTest
@testable import ElsewhereMobile

final class AppIdentifiersAndCapabilitiesTests: XCTestCase {
    func testMissingConfigurationDerivesIdentifiersFromTheHost() {
        for bundle in [nil, "", "  "] as [String?] {
            let ids = AppIdentifiers(bundleIdentifier: bundle, infoDictionary: [:])
            XCTAssertEqual(ids.hostBundleID, "com.elsewhere.mobile")
            XCTAssertEqual(ids.tunnelProviderBundleID, "com.elsewhere.mobile.tunnel")
            XCTAssertEqual(ids.snapshotAppGroup, "group.com.elsewhere.mobile.snapshot")
            XCTAssertEqual(ids.importAppGroup, "group.com.elsewhere.mobile.import")
            XCTAssertEqual(ids.backgroundRefreshID, "com.elsewhere.mobile.exit-refresh")
            XCTAssertEqual(ids.keychainService, "com.elsewhere.mobile.pairing-keys")
            XCTAssertEqual(ids.modePreferencesSuite, "com.elsewhere.mobile.mode")
        }
        for suffix in ["", ".widgets", ".tunnel", ".pairingimport", ".free", ".free.widgets"] {
            let ids = AppIdentifiers(bundleIdentifier: "org.resigned.app" + suffix, infoDictionary: [
                "ElsewhereTunnelBundleID": "org.resigned.app2.tunnel"
            ])
            XCTAssertEqual(ids.hostBundleID, "org.resigned.app")
            XCTAssertEqual(ids.tunnelProviderBundleID, "org.resigned.app.tunnel")
            XCTAssertEqual(ids.backgroundRefreshID, "org.resigned.app.exit-refresh")
        }
    }

    func testConfiguredIdentifiersAndPermittedRefreshTaskTakePrecedence() {
        let ids = AppIdentifiers(bundleIdentifier: "org.example", infoDictionary: [
            "ElsewhereTunnelBundleID": "org.example.vpn", "ElsewhereSnapshotAppGroup": "group.shared.snapshot",
            "ElsewhereImportAppGroup": "group.shared.import", "BGTaskSchedulerPermittedIdentifiers": ["", "custom.refresh", "other"]
        ])
        XCTAssertEqual(ids.tunnelProviderBundleID, "org.example.vpn")
        XCTAssertEqual(ids.snapshotAppGroup, "group.shared.snapshot")
        XCTAssertEqual(ids.importAppGroup, "group.shared.import")
        XCTAssertEqual(ids.backgroundRefreshID, "custom.refresh")
    }

    private func addExtension(at directory: URL, name: String, point: String, bundleID: String?) throws {
        let url = directory.appending(path: name + ".appex")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        var info: [String: Any] = ["NSExtension": ["NSExtensionPointIdentifier": point]]
        info["CFBundleIdentifier"] = bundleID
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: url.appending(path: "Info.plist"))
    }

    func testPacketTunnelDiscoveryAfterResigningAndExtensionRemoval() throws {
        let plugins = try makeTemporaryDirectory()
        let ids = AppIdentifiers(bundleIdentifier: "org.example.host", infoDictionary: [:])
        try addExtension(at: plugins, name: "Widget", point: "com.apple.widgetkit-extension", bundleID: "org.example.widget")
        let stripped = AppCapabilities(identifiers: ids, plugInsURL: plugins) { $0 == ids.snapshotAppGroup }
        XCTAssertFalse(stripped.hasBuiltInTunnel)
        XCTAssertEqual(stripped.resolvedTunnelProviderBundleID, ids.tunnelProviderBundleID)
        XCTAssertTrue(stripped.hasSnapshotAppGroup)
        XCTAssertFalse(stripped.hasImportAppGroup)
        XCTAssertEqual(stripped.buildKind, .partial)

        try addExtension(at: plugins, name: "Unnamed", point: "com.apple.networkextension.packet-tunnel", bundleID: nil)
        let fallback = AppCapabilities(identifiers: ids, plugInsURL: plugins) { _ in false }
        XCTAssertTrue(fallback.hasBuiltInTunnel)
        XCTAssertEqual(fallback.resolvedTunnelProviderBundleID, ids.tunnelProviderBundleID)

        try addExtension(at: plugins, name: "Provider", point: "com.apple.networkextension.packet-tunnel", bundleID: "org.example.host.renamed")
        let full = AppCapabilities(identifiers: ids, plugInsURL: plugins) { _ in true }
        XCTAssertTrue(full.hasBuiltInTunnel)
        XCTAssertEqual(full.resolvedTunnelProviderBundleID, "org.example.host.renamed")
        XCTAssertEqual(full.buildKind, .full)

        let disabled = AppIdentifiers(bundleIdentifier: "org.example.host", infoDictionary: [
            "ElsewhereTunnelBundleID": "", "ElsewhereImportAppGroup": "", "ElsewhereSnapshotAppGroup": ""
        ])
        XCTAssertNil(disabled.tunnelProviderBundleID)
        XCTAssertNil(disabled.importAppGroup)
        XCTAssertNil(disabled.snapshotAppGroup)
        let free = AppCapabilities(identifiers: disabled, plugInsURL: plugins) { _ in
            XCTFail("An explicitly disabled group must never be queried")
            return true
        }
        XCTAssertFalse(free.hasBuiltInTunnel)
        XCTAssertNil(free.resolvedTunnelProviderBundleID)
        XCTAssertEqual(free.buildKind, .sideloadFree)
    }

    func testUnavailableAdaptersRejectValidTargets() async {
        for adapter in [SystemTunnelProviderAdapter(providerBundleIdentifier: "org.example.vpn", isAvailable: false),
                        SystemTunnelProviderAdapter(providerBundleIdentifier: nil, isAvailable: true)] {
            let status = await adapter.currentStatus()
            XCTAssertEqual(status, .unavailable)
            do {
                try await adapter.start(targetHost: LoopbackTarget.defaultPeer)
                XCTFail("An unavailable provider started")
            } catch let error as NEVPNError {
                XCTAssertEqual(error.code, .configurationInvalid)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testStoreAdaptsSavedChannelAndPreservesOtherSettings() async throws {
        let demo = AppEnvironment.demo()
        let ids = AppIdentifiers(bundleIdentifier: "org.example.host", infoDictionary: [:])
        let stripped = AppCapabilities(identifiers: ids, plugInsURL: nil) { _ in false }
        let env = AppEnvironment(engine: demo.engine, pairingStore: demo.pairingStore, tunnel: demo.tunnelCoordinator,
                                 stateStore: demo.stateStore, exitService: demo.exitService, notifier: demo.notifier, capabilities: stripped)
        var saved = AppSettings(applyToAll: true, channelMode: .builtInTunnel, customProxyText: "localhost:9000")
        try await env.stateStore.saveSettings(saved)
        let store = AppStore(environment: env)
        let loaded = await store.loadSettingsOnly()
        XCTAssertTrue(loaded)
        saved.channelMode = .existingRoute
        XCTAssertEqual(store.settings, saved)
        XCTAssertEqual(store.effectiveSettings, saved)
        let migrated = try await env.stateStore.load()
        XCTAssertEqual(migrated.settings, saved)
        await store.updateSettings { $0.channelMode = .builtInTunnel }
        let persisted = try await env.stateStore.load()
        XCTAssertEqual(persisted.settings, saved)
    }

    func testDiskStateAndMemorySnapshotWithoutSnapshotGroup() async throws {
        let directory = try makeTemporaryDirectory()
        let store = AppStateStore(storageDirectory: directory, snapshotSuiteName: nil)
        let device = DemoLocationEngine.defaultDevice
        let point = try XCTUnwrap(WGS84Coordinate(latitude: 35, longitude: 139))
        let date = Date()
        let record = AppliedLocationRecord(deviceID: device.id, deviceName: device.name, name: "Tokyo", coordinate: point,
                                           appliedAt: date, source: .city, exitIP: nil, confidence: .confirmed)
        let committed = try await store.commitDeviceRecord(record, for: device.id, deviceName: device.name)
        XCTAssertEqual(committed.records[device.id], record)
        let records = try await store.saveCommandResult(record, for: device, settings: AppSettings(), at: date)
        XCTAssertEqual(records[device.id], record)
        let commandSnapshot = await store.widgetSnapshot
        XCTAssertEqual(commandSnapshot?.coordinate, point)
        let exit = ExitInfo(ip: "192.0.2.1", city: "Tokyo", region: "", country: "", coordinate: point, org: nil, sampledAt: date)
        try await store.saveExitSnapshot(exit, at: date)
        let snapshot = await store.widgetSnapshot
        XCTAssertEqual(snapshot?.exitSummary, "Tokyo")
        XCTAssertEqual(snapshot?.locationState, .simulated)
        let reopened = AppStateStore(storageDirectory: directory, snapshotSuiteName: nil)
        let state = try await reopened.load()
        let otherSnapshot = await reopened.widgetSnapshot
        XCTAssertEqual(state.records[device.id], record)
        XCTAssertNil(otherSnapshot)
    }
}
