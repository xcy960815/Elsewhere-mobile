import SwiftUI

struct LocationView: View {
    @Environment(AppStore.self) private var store
    @State private var tappedCity: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                deviceCard
                currentLocation
                if let feedback = store.feedback {
                    FeedbackBanner(message: feedback, onDismiss: store.dismissFeedback)
                }
                if case let .mismatch(_, _, hint, estimated) = store.timeZoneResult {
                    HintBanner(title: "\(estimated ? "时区估算 · " : "")\(hint)", systemImage: "clock")
                }
                if store.settings.exitFeaturesEnabled {
                    if let change = store.pendingExitChange {
                        HintBanner(title: "代理出口已变为 \(change.displayCity)（\(change.ip)）", systemImage: "network",
                                   action: ("改过去", { Task { await store.followExit(prefetched: change) } }))
                            .disabled(!store.canOperate)
                    }
                    exitCard
                }
                Text("常用城市").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
                    ForEach(store.cities) { place in
                        let matched = store.selectedRecord.map { $0.confidence != .unknownOutcome && $0.coordinate.isSameSpot(as: place.coordinate) } == true
                        Button {
                            tappedCity = UUID()
                            Task { await store.apply(place: place, source: .city) }
                        } label: {
                            HStack {
                                Text(place.name)
                                Spacer(minLength: 2)
                                if matched { Image(systemName: "checkmark.circle.fill") }
                            }
                            .padding(12)
                            .background(matched ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 12))
                        }
                        .accessibilityAddTraits(matched ? .isSelected : [])
                        .disabled(!store.canOperate)
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

    private var deviceCard: some View {
        let device = store.selectedDevice
        let state = (store.selectedDeviceID ?? device?.id).flatMap { store.deviceStates[$0] }
        return SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("目标设备").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("自动选择") { Task { await store.selectDevice(nil) } }
                        ForEach(store.devices) { device in
                            Button(device.name) { Task { await store.selectDevice(device.id) } }
                        }
                    } label: {
                        Image(systemName: "arrow.left.arrow.right").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("切换目标设备")
                    Button { Task { await store.refreshDevices() } } label: {
                        Image(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("刷新设备")
                    .disabled(store.busyMessage != nil)
                }
                Text(device?.name ?? store.selectedDeviceID?.rawValue ?? "未连接设备").font(.title2.bold())
                if let device, let version = device.osVersion {
                    Text("\(device.kind == "iPad" ? "iPadOS" : "iOS") \(version.major).\(version.minor).\(version.patch)")
                        .font(.subheadline).monospacedDigit()
                }
                StatusPill(title: "\(state?.diagnosis ?? "设备未就绪")", color: state?.isReady == true ? .green : .secondary)
                Text(store.settings.channelMode == .existingRoute ? "已有路由" : "内置通道 · \(store.tunnelStatus.title)")
                    .font(.caption).foregroundStyle(.secondary)
                if store.settings.applyToAll { Text("将操作全部 \(store.readyDevices.count) 台就绪设备").font(.caption) }
                if let message = store.busyMessage {
                    ProgressView { Text(message).font(.caption) }.progressViewStyle(.linear)
                }
            }
        }
    }

    private var currentLocation: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                if let record = store.selectedRecord {
                    Text(record.confidence == .unknownOutcome ? "模拟结果待确认" : "上次设置的位置")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(record.name).font(.title2.bold())
                    Text("WGS-84 · \(record.coordinate.formatted)").monospacedDigit().textSelection(.enabled)
                    HStack {
                        Text(record.source == .exitIP ? "代理出口" : record.source == .city ? "常用城市" : "自定义坐标")
                        Text(record.appliedAt, style: .relative)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Button("恢复真实定位") { Task { await store.clearLocation() } }
                        .buttonStyle(.borderedProminent).disabled(!store.canOperate)
                } else {
                    Label("当前使用真实定位", systemImage: "location")
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
                }
                if store.customProxyInvalid {
                    Label("自定义代理地址无效，请在设置中检查主机和端口。", systemImage: "exclamationmark.triangle")
                } else if let error = store.exitError { Text(error).foregroundStyle(.secondary) }
                if let exit = store.exit {
                    Text(exit.summary(locale: AppLanguage.locale)).font(.title3.weight(.semibold))
                    Text(exit.ip).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    if let org = exit.org { Text(org).font(.caption).foregroundStyle(.secondary) }
                }
                HStack {
                    Spacer()
                    Button("跟随出口") { Task { await store.followExit() } }.buttonStyle(.borderedProminent)
                        .disabled(!store.canOperate || store.customProxyInvalid || store.exitLoading)
                }
            }
        }
    }
}

private extension TunnelConnectionStatus {
    var title: String {
        switch self {
        case .disconnected: "已断开"
        case .connecting: "连接中"
        case .connected: "已连接"
        case .disconnecting: "正在断开"
        case .unavailable: "不可用"
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
