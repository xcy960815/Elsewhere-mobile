// 系统从私有队列交付任务，旧 SDK 没有标注这次向主执行器的单向移交。
@preconcurrency import BackgroundTasks
import SwiftUI
import UIKit

@main
struct ElsewhereMobileApp: App {
    private static let refreshID = "com.elsewhere.mobile.exit-refresh"

    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: nil) { @Sendable task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                let store = AppStore.shared, env = store.environment
                do {
                    let state = try await env.stateStore.load()
                    guard env === store.environment, !env.isDemo else { refresh.setTaskCompleted(success: true); return }
                    Self.scheduleRefresh(settings: state.settings)
                    guard state.settings.exitFeaturesEnabled, state.settings.watchMode != .off else {
                        refresh.setTaskCompleted(success: true)
                        return
                    }
                    let proxy = try state.settings.parsedProxy.get()
                    var devices = store.readyDevices
                    if devices.isEmpty {
                        devices = try await env.pairingStore.records().map { record in
                            let id = record.probeID
                            return TargetDevice(id: id, name: state.knownDeviceNames[id] ?? record.deviceName ?? record.endpointHost,
                                deviceClass: "", productType: nil, osVersion: nil, endpointHost: record.endpointHost,
                                paired: true, developerMode: nil, wifiEnabled: nil, timeZoneID: nil, cellular: nil, ddiMounted: nil)
                        }.sorted { $0.id.rawValue < $1.id.rawValue }
                    }
                    guard env === store.environment else { refresh.setTaskCompleted(success: true); return }
                    let selected = state.selectedDeviceID ?? devices.first?.id
                    let targets = devices.filter { state.settings.applyToAll || $0.id == selected }
                    env.exitMonitor.handleBackgroundRefresh(refresh, settings: state.settings, proxy: proxy, targets: targets)
                } catch { refresh.setTaskCompleted(success: false) }
            }
        }
    }

    fileprivate static func scheduleRefresh(settings: AppSettings) {
        guard !AppStore.shared.isDemo, settings.exitFeaturesEnabled, settings.watchMode != .off,
              case .success = settings.parsedProxy else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshID)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    var body: some Scene {
        WindowGroup { MobileNavigation().environment(AppStore.shared) }
    }
}

private enum Page: String, CaseIterable {
    case location = "定位", map = "地图", cities = "城市", settings = "设置"

    @MainActor var label: some View {
        let symbol = switch self {
        case .location: "location"
        case .map: "map"
        case .cities: "building.2"
        case .settings: "gearshape"
        }
        return Label(LocalizedStringKey(rawValue), systemImage: symbol)
    }
}

private struct MobileNavigation: View {
    @Environment(AppStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = Page.location
    @State private var showingSplash: Bool?
    @AppStorage("ElsewhereHasSeenSplash", store: AppEnvironment.modePreferences) private var hasSeenSplash = false
    @State private var showingOnboarding = false
    @State private var activeLoadFinished = false
    @State private var importReport = [String]()

    var body: some View {
        ZStack {
            navigation
                .accessibilityHidden(showingSplash != false)
                .allowsHitTesting(showingSplash == false)
            if showingSplash == true {
                SplashView {
                    Task {
                        await store.markSplashSeen()
                        hasSeenSplash = true
                        showingSplash = false
                    }
                }
            } else if showingSplash == nil {
                Color(uiColor: .systemBackground).ignoresSafeArea().overlay { ProgressView() }
            }
        }
        .task {
            if hasSeenSplash { showingSplash = false }
            else { showingSplash = (try? await store.environment.stateStore.load().settings.hasSeenSplash) != true }
        }
        .safeAreaInset(edge: .top) { if !showingOnboarding { importSummary } }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView().safeAreaInset(edge: .top) { importSummary }
        }
        .onChange(of: activeLoadFinished && showingSplash == false && scenePhase == .active && store.needsOnboarding) { _, needed in
            if needed { showingOnboarding = true }
        }
        .onChange(of: showingSplash == false && scenePhase == .active, initial: true) { _, ready in
            guard ready else { return }
            Task {
                await store.handleSceneActive()
                let results = await store.importPendingPairings()
                importReport.append(contentsOf: results)
                activeLoadFinished = true
            }
        }
        .onChange(of: scenePhase) { previous, phase in
            guard previous != phase, phase == .inactive || phase == .background else { return }
            ElsewhereMobileApp.scheduleRefresh(settings: store.settings)
            Task {
                await store.handleSceneInactive()
            }
        }
        .onOpenURL { url in
            guard url.isFileURL, ["plist", "mobiledevicepairing"].contains(url.pathExtension.lowercased()) else { return }
            Task {
                do {
                    _ = try await store.importPairing(url: url, endpointHost: LoopbackTarget.defaultPeer, deviceName: nil)
                    importReport.append(String(localized: "已导入 · \(url.lastPathComponent)"))
                    if !store.isDemo { await store.refreshDevices() }
                } catch { importReport.append("\(url.lastPathComponent) · \(error.localizedDescription)") }
            }
        }
    }

    @ViewBuilder private var importSummary: some View {
        if !importReport.isEmpty {
            let detail = importReport.joined(separator: "\n") + (store.isDemo ? String(localized: "\n演示配对仅供本次演示使用。") : "")
            FeedbackBanner(message: .init(kind: .info, title: String(localized: "配对文件导入结果"), detail: detail)) {
                importReport.removeAll()
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder private var navigation: some View {
        if UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular {
            NavigationSplitView {
                List(selection: Binding<Page?>($selection)) {
                    Section {
                        ForEach(Page.allCases, id: \.self) { page in
                            NavigationLink(value: page) { page.label }
                        }
                    } header: { Wordmark().frame(width: 116).padding(.vertical, 8) }
                    if let device = store.selectedDevice {
                        Section("目标设备") { Label(device.name, systemImage: "iphone") }
                    }
                }
                .listStyle(.sidebar)
            } detail: {
                NavigationStack {
                    content(selection)
                        .scrollContentBackground(.hidden)
                        .background(alignment: .bottom) {
                            if selection != .map {
                                CodeField(dark: scheme == .dark, animated: true, strength: 0.14)
                                    .frame(height: 170).allowsHitTesting(false)
                            }
                        }
                }
                .id(selection)
            }
        } else {
            TabView(selection: $selection) {
                ForEach(Page.allCases, id: \.self) { page in
                    NavigationStack { content(page) }
                        .tabItem { page.label }
                        .tag(page)
                }
            }
        }
    }

    @ViewBuilder private func content(_ page: Page) -> some View {
        switch page {
        case .location: LocationView(openCities: { selection = .cities })
        case .map: MapView()
        case .cities: CitiesView(openMap: { selection = .map })
        case .settings: SettingsView(openOnboarding: { showingOnboarding = true }, replaySplash: { showingSplash = true })
        }
    }
}

extension AppStore {
    func importPendingPairings(from inbox: PairingInbox? = nil) async -> [String] {
        guard !isDemo else { return [] }
        let inbox = inbox ?? PairingInbox()
        let env = environment
        let pending = await Task.detached(priority: .utility) { inbox.pendingItems() }.value
        var results = [String]()
        var imported = false
        for item in pending {
            guard environment === env else { break }
            let name = item.suggestedName ?? String(localized: "共享配对文件")
            do {
                _ = try await importPairing(data: item.data, endpointHost: LoopbackTarget.defaultPeer, deviceName: nil)
                await Task.detached(priority: .utility) { inbox.acknowledge(id: item.id) }.value
                imported = true
                results.append(String(localized: "已导入 · \(name)"))
            } catch { results.append("\(name) · \(error.localizedDescription)") }
        }
        if imported, environment === env { await refreshDevices() }
        return results
    }
}
