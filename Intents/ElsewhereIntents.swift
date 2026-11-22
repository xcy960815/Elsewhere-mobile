import AppIntents
import Foundation

private struct ElsewhereIntentError: LocalizedError, CustomLocalizedStringResourceConvertible {
    let localizedStringResource: LocalizedStringResource
    var errorDescription: String? { String(localized: localizedStringResource) }
}

#if !ELSEWHERE_WIDGET_EXTENSION
enum IntentExecutor {
    case followExit, setCity(CityEntity), setCoordinate(latitude: Double, longitude: Double, name: String?), restoreRealLocation

    @MainActor
    func run(in store: AppStore) async throws -> String {
        let env = store.environment
        let needsProbe = store.readyDevices.isEmpty
        @MainActor func loadSettings() async throws {
            if !store.loaded || needsProbe {
                guard await store.loadSettingsOnly() else { throw ElsewhereIntentError(localizedStringResource: "无法加载应用状态") }
            }
        }
        @MainActor func followProxy() throws -> ExitProxyAddress? {
            guard store.settings.exitFeaturesEnabled else {
                throw ElsewhereIntentError(localizedStringResource: "出口功能已关闭，请先在设置中开启。")
            }
            return try store.settings.parsedProxy.get()
        }

        var sample: AppStore.ExitSample?
        if case .followExit = self, needsProbe {
            sample = try await store.prefetchExitBeforeProbing {
                try await loadSettings()
                let proxy = try followProxy()
                return (try await env.exitService.lookup(proxy: proxy), proxy)
            }
        } else {
            try await loadSettings()
            if case .followExit = self { _ = try followProxy() }
        }
        if store.readyDevices.isEmpty { await store.refreshDevices() }
        else { await store.waitForDeviceRefresh() }
        try Task.checkCancellation()
        if let busy = store.busyMessage { throw ElsewhereIntentError(localizedStringResource: "设备正忙：\(busy)") }
        store.dismissFeedback()
        switch self {
        case .followExit:
            let currentProxy = try followProxy()
            guard env === store.environment, sample.map({ $0.proxy == currentProxy }) != false else {
                throw ElsewhereIntentError(localizedStringResource: "这次出口变化已过期，请刷新出口后再跟随。")
            }
            await store.followExit(prefetched: sample?.exit)
        case .setCity(let city):
            guard let place = store.cities.first(where: { $0.id == city.id }) else {
                throw ElsewhereIntentError(localizedStringResource: "常用城市里没有「\(city.name)」")
            }
            await store.apply(place: place, source: .city)
        case let .setCoordinate(latitude, longitude, name):
            guard let coordinate = WGS84Coordinate(latitude: latitude, longitude: longitude) else {
                throw ElsewhereIntentError(localizedStringResource: "无效的 WGS-84 坐标")
            }
            let title = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            await store.apply(name: title.isEmpty ? coordinate.formatted : title, coordinate: coordinate, source: .custom)
        case .restoreRealLocation:
            await store.clearLocation()
        }
        guard let feedback = store.feedback else { throw ElsewhereIntentError(localizedStringResource: "未收到定位操作结果") }
        if feedback.kind == .failure {
            let detail = [feedback.title, feedback.detail].compactMap { $0 }.joined(separator: "：")
            throw ElsewhereIntentError(localizedStringResource: "\(detail)")
        }
        return feedback.title
    }
}
#endif

struct FollowExitIntent: AppIntent {
    static let title: LocalizedStringResource = "跟随代理出口"
    static let description = IntentDescription("查询代理出口 IP 的位置，把 iPhone 的定位改过去。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> IntentResultContainer<String, Never, Never, IntentDialog> {
        #if ELSEWHERE_WIDGET_EXTENSION
        throw ElsewhereIntentError(localizedStringResource: "请在 Elsewhere 中执行此操作。")
        #else
        let text = try await IntentExecutor.followExit.run(in: AppStore.shared)
        return .result(value: text, dialog: "\(text)")
        #endif
    }
}

struct SetCityIntent: AppIntent {
    static let title: LocalizedStringResource = "改到常用城市"
    static let description = IntentDescription("把 iPhone 的定位改到一个常用城市。")
    static let openAppWhenRun = true

    @Parameter(title: "城市") var city: CityEntity

    static var parameterSummary: some ParameterSummary { Summary("把定位改到 \(\.$city)") }

    @MainActor
    func perform() async throws -> IntentResultContainer<String, Never, Never, IntentDialog> {
        #if ELSEWHERE_WIDGET_EXTENSION
        throw ElsewhereIntentError(localizedStringResource: "请在 Elsewhere 中执行此操作。")
        #else
        let text = try await IntentExecutor.setCity(city).run(in: AppStore.shared)
        return .result(value: text, dialog: "\(text)")
        #endif
    }
}

struct SetCoordinateIntent: AppIntent {
    static let title: LocalizedStringResource = "改到坐标"
    static let description = IntentDescription("把 iPhone 的定位改到指定的 GPS 坐标（WGS-84）。")
    static let openAppWhenRun = true

    @Parameter(title: "纬度", inclusiveRange: (-90, 90)) var latitude: Double
    @Parameter(title: "经度", inclusiveRange: (-180, 180)) var longitude: Double
    @Parameter(title: "名称") var name: String?

    static var parameterSummary: some ParameterSummary {
        Summary("把定位改到 \(\.$latitude), \(\.$longitude)") { \.$name }
    }

    @MainActor
    func perform() async throws -> IntentResultContainer<String, Never, Never, IntentDialog> {
        #if ELSEWHERE_WIDGET_EXTENSION
        throw ElsewhereIntentError(localizedStringResource: "请在 Elsewhere 中执行此操作。")
        #else
        let text = try await IntentExecutor.setCoordinate(latitude: latitude, longitude: longitude, name: name).run(in: AppStore.shared)
        return .result(value: text, dialog: "\(text)")
        #endif
    }
}

struct RestoreRealLocationIntent: AppIntent {
    static let title: LocalizedStringResource = "恢复真实定位"
    static let description = IntentDescription("停止模拟，让 iPhone 恢复真实定位。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> IntentResultContainer<String, Never, Never, IntentDialog> {
        #if ELSEWHERE_WIDGET_EXTENSION
        throw ElsewhereIntentError(localizedStringResource: "请在 Elsewhere 中执行此操作。")
        #else
        let text = try await IntentExecutor.restoreRealLocation.run(in: AppStore.shared)
        return .result(value: text, dialog: "\(text)")
        #endif
    }
}

struct CityEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "常用城市"
    static let defaultQuery = CityQuery()
    let id: UUID
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct CityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [CityEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [CityEntity] {
        #if ELSEWHERE_WIDGET_EXTENSION
        let cities = Place.defaults
        #else
        let store = AppStore.shared
        // 冷启动时城市尚未载入，Siri 枚举候选不需要探测设备或查询出口。
        let cities = store.deviceStates.isEmpty ? try await store.environment.stateStore.load().cities : store.cities
        #endif
        return cities.map { CityEntity(id: $0.id, name: $0.displayName) }
    }
}

#if !ELSEWHERE_WIDGET_EXTENSION
struct ElsewhereShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FollowExitIntent(),
                    phrases: ["用 \(.applicationName) 跟随代理出口", "\(.applicationName) 跟随出口",
                              "Follow proxy exit with \(.applicationName)", "\(.applicationName) follow exit"],
                    shortTitle: "跟随代理出口", systemImageName: "network")
        AppShortcut(intent: SetCityIntent(),
                    phrases: ["用 \(.applicationName) 改到 \(\.$city)", "\(.applicationName) 改到常用城市",
                              "Move to \(\.$city) with \(.applicationName)", "\(.applicationName) move to favorite city"],
                    shortTitle: "改到常用城市", systemImageName: "building.2")
        AppShortcut(intent: RestoreRealLocationIntent(),
                    phrases: ["用 \(.applicationName) 恢复真实定位", "Use real location with \(.applicationName)"],
                    shortTitle: "恢复真实定位", systemImageName: "location.slash")
    }
}
#endif
