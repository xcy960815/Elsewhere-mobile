import SwiftUI

struct LocationView: View {
    @Environment(AppStore.self) private var store
    @State private var tappedCity: UUID?
    let openMap: () -> Void
    let openOnboarding: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                modeCard
                if let pending = store.pendingAction {
                    HintBanner(title: "待应用目标 · \(pending.displayTitle)\n代理与回环通道互斥时，可开启 LocalDevVPN / StosVPN 或解锁设备后自动应用。", systemImage: "clock.arrow.circlepath",
                               action: ("立即检测并应用", { Task { await store.executePendingAction(probeFirst: true) } }),
                               actionDisabled: store.busyMessage != nil, secondaryAction: ("取消", store.cancelPendingAction))
                }
                deviceCard
                if let feedback = store.feedback { FeedbackBanner(message: feedback, onDismiss: store.dismissFeedback) }
                if case let .mismatch(_, _, hint, estimated) = store.timeZoneResult {
                    HintBanner(title: "\(estimated ? String(localized: "时区估算 · ") : "")\(hint)", systemImage: "clock")
                }
                if store.settings.exitFeaturesEnabled, let change = store.pendingExitChange {
                    HintBanner(title: "代理出口已变为 \(change.displayCity)（\(change.ip)）", systemImage: "network",
                               action: ("改过去", { Task { await store.followExitOrQueue(prefetched: change) } }),
                               actionDisabled: !store.canSelectTarget,
                               secondaryAction: ("忽略", { Task { await store.dismissPendingExitChange() } }))
                }
                currentLocation
                if store.settings.exitFeaturesEnabled { exitCard }
                HStack {
                    Text("常用城市").font(.headline)
                    Spacer()
                    NavigationLink("管理") { CitiesView(openMap: openMap, openOnboarding: openOnboarding) }
                }
                if store.cities.isEmpty { Text("还没有常用城市").foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
                    ForEach(store.cities) { place in
                        let matched = store.selectedRecord.map { $0.confidence.isConfirmedSimulated && $0.coordinate.isSameSpot(as: place.coordinate) } == true
                        Button {
                            tappedCity = UUID()
                            Task { await store.applyOrQueue(place: place, source: .city) }
                        } label: {
                            HStack {
                                Text(place.displayName)
                                Spacer(minLength: 2)
                                if matched { Image(systemName: "checkmark.circle.fill") }
                            }
                            .padding(12)
                            .background(matched ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 12))
                        }
                        .accessibilityAddTraits(matched ? .isSelected : [])
                        .disabled(!store.canSelectTarget)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding()
        }
        .navigationTitle("定位")
        .refreshable { await store.refreshDevices(); await store.refreshExit() }
        .sensoryFeedback(.impact(weight: .light), trigger: tappedCity)
        .sensoryFeedback(trigger: store.feedback) { _, message in message?.sensation }
    }

    @ViewBuilder private var modeCard: some View {
        if store.needsPairingSetup {
            HintBanner(title: "尚未配置真机", systemImage: "iphone.badge.exclamationmark",
                       action: ("开启演示模式", { Task { await store.switchToDemo(true) } }), actionDisabled: store.busyMessage != nil,
                       secondaryAction: ("打开配置向导", openOnboarding))
        } else if store.isDemo {
            HintBanner(title: "演示模式 · 定位操作仅作用于模拟设备", systemImage: "sparkles",
                       action: ("切换真机模式", { Task { await store.switchToDemo(false) } }), actionDisabled: store.busyMessage != nil)
        }
    }

    private var deviceCard: some View {
        let device = store.selectedDevice
        let pairing = store.pairingRecords.first { store.selectedDeviceID == nil || $0.probeID == store.selectedDeviceID }
        let state = (store.selectedDeviceID ?? device?.id ?? pairing?.probeID).flatMap { store.deviceStates[$0] }
        return SurfaceCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device?.name ?? pairing?.deviceName ?? pairing?.endpointHost ?? String(localized: "未连接设备")).font(.headline)
                        StatusPill(title: state?.diagnosis ?? String(localized: "设备未就绪"), color: state?.isReady == true ? .green : state == nil || state == .unpaired ? .secondary : .orange)
                    }
                    Spacer()
                    if store.devices.count > 1 || store.pairingRecords.count > 1 {
                        Menu {
                            Button("自动选择") { Task { await store.selectDevice(nil) } }
                            ForEach(store.devices) { device in
                                Button(device.name) { Task { await store.selectDevice(device.id) } }
                            }
                            ForEach(store.pairingRecords.filter { record in !store.devices.contains { $0.id == record.probeID } }) { record in
                                Button(record.deviceName ?? record.endpointHost) { Task { await store.selectDevice(record.probeID) } }
                            }
                        } label: {
                            Image(systemName: "arrow.left.arrow.right").frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("切换目标设备")
                    }
                    Button { Task { await store.refreshDevices() } } label: {
                        Image(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("刷新设备")
                    .disabled(store.busyMessage != nil)
                }
                Text(store.settings.channelMode == .existingRoute ? String(localized: "已有路由") : String(localized: "内置通道 · \(store.tunnelStatus.localizedTitle)"))
                    .font(.caption).foregroundStyle(.secondary)
                if store.settings.applyToAll { Text("将操作全部 \(store.readyDevices.count) 台就绪设备").font(.caption) }
                if !store.needsPairingSetup {
                    switch state {
                    case .channelUnavailable where (device?.endpointHost ?? pairing?.endpointHost)?.hasPrefix("10.7.0.") == true:
                        Text("未连上回环通道，请打开 LocalDevVPN / StosVPN 后点刷新").font(.caption).foregroundStyle(.secondary)
                    case .locked: Text("请先解锁目标设备").font(.caption).foregroundStyle(.secondary)
                    case .developerModeOff: Text("请在目标设备「设置 › 隐私与安全性 › 开发者模式」开启").font(.caption).foregroundStyle(.secondary)
                    default: EmptyView()
                    }
                }
                if let message = store.busyMessage {
                    if let progress = store.ddiProgress {
                        ProgressView(value: progress) { Text(message).font(.caption) }.progressViewStyle(.linear)
                    } else {
                        ProgressView { Text(message).font(.caption) }
                    }
                }
            }
        }
    }

    private var currentLocation: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                if let record = store.selectedRecord {
                    if record.confidence.isUnknown {
                        Text(record.confidence == .clearUnknown ? "清除结果待确认" : "模拟结果待确认").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(record.name).font(.title2.bold())
                    Text("WGS-84 · \(record.coordinate.formatted)").monospacedDigit().textSelection(.enabled)
                    Text("\(record.source == .exitIP ? String(localized: "代理出口") : record.source == .city ? String(localized: "常用城市") : String(localized: "自定义坐标")) · \(record.appliedAt, style: .relative)")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("恢复真实定位") { Task { await store.clearLocationOrQueue() } }
                            .buttonStyle(.borderedProminent).disabled(!store.canSelectTarget)
                        Button("在地图查看", action: openMap).buttonStyle(.bordered)
                    }
                } else {
                    HStack {
                        Label("无本地模拟记录", systemImage: "location")
                        Spacer()
                        Button("清除模拟") { Task { await store.clearLocationOrQueue() } }.disabled(!store.canSelectTarget)
                    }
                }
            }
        }
    }

    private var exitCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("代理出口").font(.headline)
                    Spacer()
                    if store.exitLoading { ProgressView().accessibilityLabel("正在查询出口") }
                    Button("刷新") { Task { await store.refreshExit() } }.disabled(store.exitLoading || store.customProxyInvalid)
                    Button("跟随出口") { Task { await store.followExitOrQueue() } }.buttonStyle(.borderedProminent)
                        .disabled(!store.canSelectTarget || store.customProxyInvalid || store.exitLoading)
                }
                if store.customProxyInvalid {
                    Label("自定义代理地址无效，请在设置中检查主机和端口。", systemImage: "exclamationmark.triangle")
                } else if let error = store.exitError { Text(error).foregroundStyle(.secondary) }
                if let exit = store.exit {
                    Text(exit.summary(locale: AppLanguage.locale)).font(.title3.weight(.semibold))
                    Text(exit.ip).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    if let org = exit.org { Text(org).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

struct PairingSetupActions: View {
    @Environment(AppStore.self) private var store
    let setupTitle: LocalizedStringKey
    let openOnboarding: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { buttons }
            VStack(alignment: .leading) { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        Button("开启演示模式") { Task { await store.switchToDemo(true) } }
            .buttonStyle(.borderedProminent).disabled(store.busyMessage != nil)
        Button(setupTitle, action: openOnboarding).buttonStyle(.bordered)
    }
}

extension TunnelConnectionStatus {
    var localizedTitle: String {
        switch self {
        case .disconnected: String(localized: "已断开")
        case .connecting: String(localized: "连接中")
        case .connected: String(localized: "已连接")
        case .disconnecting: String(localized: "正在断开")
        case .unavailable: String(localized: "不可用")
        }
    }
}

extension FeedbackMessage {
    var sensation: SensoryFeedback? {
        switch kind {
        case .success: .success
        case .failure: .error
        case .info: nil
        }
    }
}
