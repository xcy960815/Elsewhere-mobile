import Foundation

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

struct WidgetSnapshot: Codable, Equatable, Sendable {
    let selectedDeviceName: String?
    let locationName: String?
    let coordinate: WGS84Coordinate?
    let source: LocationSource?
    let appliedAt: Date?
    let exitSummary: String?
    let exitFeaturesEnabled: Bool
    let updatedAt: Date
}

actor AppStateStore {
    struct State: Codable, Equatable, Sendable {
        var settings = AppSettings()
        var cities = Place.defaults
        var records: [DeviceID: AppliedLocationRecord] = [:]
        var selectedDeviceID: DeviceID?
    }

    static let defaultSnapshotSuiteName = "group.com.elsewhere.mobile.snapshot"
    private static let snapshotKey = "widgetSnapshot"
    private static let writes = NSLock()
    private let file: URL?
    private let snapshotSuiteName: String?
    private var memory = State()
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

    private func update(_ change: (inout State) -> Void) throws {
        guard let file else {
            change(&memory)
            return
        }
        // 多个 store 打开同一目录时，一次字段更新必须包含读取和原子替换。
        try Self.writes.withLock {
            var state = try load()
            change(&state)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
        }
    }

    var widgetSnapshot: WidgetSnapshot? {
        Self.readWidgetSnapshot(suiteName: snapshotSuiteName) ?? memorySnapshot
    }

    func writeWidgetSnapshot(_ snapshot: WidgetSnapshot) throws {
        guard let snapshotSuiteName else {
            memorySnapshot = snapshot
            return
        }
        guard let defaults = UserDefaults(suiteName: snapshotSuiteName) else { throw CocoaError(.fileWriteUnknown) }
        defaults.set(try JSONEncoder().encode(snapshot), forKey: Self.snapshotKey)
    }

    static func readWidgetSnapshot(suiteName: String? = defaultSnapshotSuiteName) -> WidgetSnapshot? {
        guard let suiteName, let data = UserDefaults(suiteName: suiteName)?.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
