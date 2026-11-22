import Foundation
import WidgetKit

struct AppSettings: Codable, Equatable, Sendable {
    var exitFeaturesEnabled = true
    var watchMode: ExitWatchMode = .notify
    var applyToAll = false
    var autoRestore = true
    var channelMode: ChannelMode = .existingRoute
    var autoDisconnectTunnel = true
    var customProxyText = ""
    var hasSeenSplash = false
    var hasCompletedOnboarding = false
}

struct ExitBaseline: Codable, Equatable, Sendable {
    let proxyKey: String
    let lastConfirmedIP: String
    let lastExit: ExitInfo?
    let lastFetchedAt: Date
}

struct PendingExitEvent: Codable, Equatable, Sendable {
    let id: UUID
    let exit: ExitInfo
    let targetDeviceIDs: [DeviceID]
    let createdAt: Date
}

enum WidgetLocationState: String, Codable, Equatable, Sendable {
    case real, simulated, unknownOutcome, clearUnknown
}

struct WidgetSnapshot: Codable, Equatable, Sendable {
    let selectedDeviceName: String?
    let locationName: String?
    let coordinate: WGS84Coordinate?
    let source: LocationSource?
    let appliedAt: Date?
    let exitSummary: String?
    let exitFeaturesEnabled: Bool
    let updatedAt: Date
    var locationState: WidgetLocationState = .real
}

extension WidgetSnapshot {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        selectedDeviceName = try values.decodeIfPresent(String.self, forKey: .selectedDeviceName)
        locationName = try values.decodeIfPresent(String.self, forKey: .locationName)
        coordinate = try values.decodeIfPresent(WGS84Coordinate.self, forKey: .coordinate)
        source = try values.decodeIfPresent(LocationSource.self, forKey: .source)
        appliedAt = try values.decodeIfPresent(Date.self, forKey: .appliedAt)
        exitSummary = try values.decodeIfPresent(String.self, forKey: .exitSummary)
        exitFeaturesEnabled = try values.decode(Bool.self, forKey: .exitFeaturesEnabled)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        locationState = try values.decodeIfPresent(WidgetLocationState.self, forKey: .locationState)
            ?? (locationName == nil ? .real : .simulated)
    }
}

actor AppStateStore {
    struct State: Codable, Equatable, Sendable {
        var settings = AppSettings()
        var cities = Place.defaults
        var records: [DeviceID: AppliedLocationRecord] = [:]
        var selectedDeviceID: DeviceID?
        var lastAppliedBatchIDs: [DeviceID] = []
        var exitBaseline: ExitBaseline?
        var pendingExitEvent: PendingExitEvent?
        var knownDeviceNames: [DeviceID: String] = [:]
    }

    static let defaultSnapshotSuiteName = "group.com.elsewhere.mobile.snapshot"
    private static let snapshotKey = "widgetSnapshot"
    private static let writes = NSLock()
    private let file: URL?
    private let snapshotSuiteName: String?
    private var memory = State()
    private var automaticDisplayID: DeviceID?
    private var memorySnapshot: WidgetSnapshot?

    init(storageDirectory: URL? = URL.applicationSupportDirectory.appending(path: "ElsewhereMobile"),
         snapshotSuiteName: String? = AppStateStore.defaultSnapshotSuiteName) {
        file = storageDirectory?.appending(path: "state.json")
        self.snapshotSuiteName = storageDirectory == nil ? nil : snapshotSuiteName
    }

    func load() throws -> State {
        guard let file else { return memory }
        do {
            return try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile {
            return State()
        }
    }

    func saveSettings(_ settings: AppSettings) throws { try update { $0.settings = settings } }
    func saveCities(_ cities: [Place]) throws { try update { $0.cities = cities } }
    func saveRecords(_ records: [DeviceID: AppliedLocationRecord]) throws { try update { $0.records = records } }
    func saveSelectedDeviceID(_ id: DeviceID?) throws { try update { $0.selectedDeviceID = id } }

    func markSplashSeen() throws { try update { $0.settings.hasSeenSplash = true } }

    @discardableResult
    func commitDeviceRecord(_ record: AppliedLocationRecord?, for id: DeviceID, deviceName: String?) throws -> State {
        try update {
            $0.records[id] = record
            if let deviceName { $0.knownDeviceNames[id] = deviceName }
        }
    }

    func saveLastAppliedBatchIDs(_ ids: [DeviceID]) throws { try update { $0.lastAppliedBatchIDs = ids } }
    func removeClearedBatchIDs(_ ids: Set<DeviceID>) throws {
        try update { $0.lastAppliedBatchIDs.removeAll(where: ids.contains) }
    }
    func resetExitState(disabled: Bool, at date: Date) throws {
        let state = try update {
            $0.exitBaseline = nil
            $0.pendingExitEvent = nil
        }
        try writeDisplaySnapshot(state: state, selectedDeviceName: nil, exitEnabled: !disabled && state.settings.exitFeaturesEnabled,
                                 exitSummary: nil, at: date)
    }
    func saveExitBaseline(_ baseline: ExitBaseline?) throws {
        try Task.checkCancellation()
        try update {
            $0.exitBaseline = baseline
            if $0.pendingExitEvent?.exit.ip != baseline?.lastConfirmedIP { $0.pendingExitEvent = nil }
        }
    }
    func savePendingExitEvent(_ event: PendingExitEvent?) throws {
        try Task.checkCancellation()
        try update { $0.pendingExitEvent = event }
    }
    func clearPendingExitEvent(id: UUID?) throws {
        try update { if id == nil || $0.pendingExitEvent?.id == id { $0.pendingExitEvent = nil } }
    }
    func updateKnownDeviceNames(_ names: [DeviceID: String]) throws {
        try update { $0.knownDeviceNames.merge(names) { _, new in new } }
    }

    @discardableResult
    private func update(_ change: (inout State) -> Void) throws -> State {
        guard let file else {
            change(&memory)
            return memory
        }
        // 多个 store 打开同一目录时，一次字段更新必须包含读取和原子替换。
        return try Self.writes.withLock {
            var state = try load()
            change(&state)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
            return state
        }
    }

    var widgetSnapshot: WidgetSnapshot? {
        Self.readWidgetSnapshot(suiteName: snapshotSuiteName) ?? memorySnapshot
    }

    func refreshDisplaySnapshot(selectedDevice: TargetDevice?, at date: Date) throws {
        let state = try load()
        automaticDisplayID = selectedDevice?.id
        let selectedName = state.selectedDeviceID == nil || state.selectedDeviceID == selectedDevice?.id ? selectedDevice?.name : nil
        try writeDisplaySnapshot(state: state, selectedDeviceName: selectedName, exitEnabled: state.settings.exitFeaturesEnabled,
                                 exitSummary: widgetSnapshot?.exitSummary, at: date)
    }

    func writeDisplaySnapshot(state: State, selectedDeviceName: String?, exitEnabled: Bool, exitSummary: String?, at date: Date) throws {
        let id = state.selectedDeviceID ?? automaticDisplayID
        let record = if let id {
            state.records[id]
        } else {
            state.records.values.max { ($0.appliedAt, $0.deviceID.rawValue) < ($1.appliedAt, $1.deviceID.rawValue) }
        }
        let locationState: WidgetLocationState = switch record?.confidence {
        case nil: .real
        case .unknownOutcome: .unknownOutcome
        case .clearUnknown: .clearUnknown
        case .confirmed, .lastSet: .simulated
        }
        let onlyKnownName = id == nil && state.knownDeviceNames.count == 1 ? state.knownDeviceNames.values.first : nil
        let deviceName = selectedDeviceName ?? id.flatMap { state.knownDeviceNames[$0] } ?? record?.deviceName ?? onlyKnownName
        try writeWidgetSnapshot(WidgetSnapshot(selectedDeviceName: deviceName, locationName: record?.name,
            coordinate: record?.coordinate, source: record?.source, appliedAt: record?.appliedAt,
            exitSummary: exitEnabled ? exitSummary : nil, exitFeaturesEnabled: exitEnabled, updatedAt: date, locationState: locationState))
    }

    func writeWidgetSnapshot(_ snapshot: WidgetSnapshot) throws {
        guard let snapshotSuiteName else {
            memorySnapshot = snapshot
            return
        }
        guard let defaults = UserDefaults(suiteName: snapshotSuiteName) else { throw CocoaError(.fileWriteUnknown) }
        defaults.set(try JSONEncoder().encode(snapshot), forKey: Self.snapshotKey)
        if snapshotSuiteName == Self.defaultSnapshotSuiteName {
            WidgetCenter.shared.reloadTimelines(ofKind: "ElsewhereLocation")
        }
    }

    static func readWidgetSnapshot(suiteName: String? = defaultSnapshotSuiteName) -> WidgetSnapshot? {
        guard let suiteName, let data = UserDefaults(suiteName: suiteName)?.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

extension AppStateStore.State {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        settings = try values.decode(AppSettings.self, forKey: .settings)
        cities = try values.decode([Place].self, forKey: .cities)
        records = try values.decode([DeviceID: AppliedLocationRecord].self, forKey: .records)
        selectedDeviceID = try values.decodeIfPresent(DeviceID.self, forKey: .selectedDeviceID)
        lastAppliedBatchIDs = try values.decodeIfPresent([DeviceID].self, forKey: .lastAppliedBatchIDs) ?? []
        exitBaseline = try values.decodeIfPresent(ExitBaseline.self, forKey: .exitBaseline)
        pendingExitEvent = try values.decodeIfPresent(PendingExitEvent.self, forKey: .pendingExitEvent)
        knownDeviceNames = try values.decodeIfPresent([DeviceID: String].self, forKey: .knownDeviceNames) ?? [:]
    }
}
