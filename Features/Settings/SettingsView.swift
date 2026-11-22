import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var proxyText = ""
    let openOnboarding: () -> Void
    let replaySplash: () -> Void

    var body: some View {
        Form {
            if let message = store.feedback {
                FeedbackBanner(message: message, onDismiss: store.dismissFeedback)
            }
            Section("设备与通道") {
                NavigationLink {
                    PairingManagementView()
                } label: {
                    LabeledContent("设备与配对", value: String(localized: "\(store.pairingRecords.count) 个配对 · \(store.readyDevices.count) 台就绪"))
                }
                Toggle("同时修改所有设备", isOn: setting(\.applyToAll))
                Toggle("重新连接后恢复定位", isOn: setting(\.autoRestore))
                if store.capabilities.hasBuiltInTunnel {
                    Picker("连接通道", selection: setting(\.channelMode)) {
                        Text("已有路由").tag(ChannelMode.existingRoute)
                        Text("内置通道").tag(ChannelMode.builtInTunnel)
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("内置通道状态", value: store.tunnelStatus.localizedTitle)
                    if store.settings.channelMode == .builtInTunnel {
                        Toggle("操作完成后自动断开", isOn: setting(\.autoDisconnectTunnel))
                        Text("断开本次启动的内置通道，释放系统 VPN 槽位供代理 App 使用。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ExistingRouteInfo()
                }
                Button("打开配置向导", action: openOnboarding).disabled(store.isDemo)
            }
            Section("代理出口") {
                Toggle("代理出口功能", isOn: setting(\.exitFeaturesEnabled))
                if store.settings.exitFeaturesEnabled {
                    Picker("出口变化时", selection: setting(\.watchMode)) {
                        Text("不检测").tag(ExitWatchMode.off)
                        Text("提醒我").tag(ExitWatchMode.notify)
                        Text("自动改").tag(ExitWatchMode.auto)
                    }
                    .pickerStyle(.segmented)
                    Text("自动改仅在当前定位来自跟随出口时生效。")
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField("自定义 HTTP 代理", text: $proxyText, prompt: Text("host:port 或 [IPv6]:port"))
                        .keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.body.monospaced())
                    if !proxyText.allSatisfy(\.isWhitespace), case .failure(let error) = ExitProxyAddress.parse(proxyText) {
                        Text(error.localizedDescription).font(.footnote).foregroundStyle(.orange)
                    } else if proxyText != store.settings.customProxyText {
                        Button("保存代理地址") {
                            let address = proxyText
                            Task { await store.updateSettings { $0.customProxyText = address } }
                        }
                    } else {
                        Text("留空时使用本机网络。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section("演示与外观") {
                Toggle("演示模式（无需真机）", isOn: Binding(get: { store.isDemo }, set: { enabled in
                    Task { await store.switchToDemo(enabled) }
                }))
                .disabled(store.busyMessage != nil)
                Button("重看开场页", action: replaySplash)
            }
            Section("关于与许可") {
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    LabeledContent("App 版本", value: version)
                }
                LabeledContent("构建版本", value: buildKindTitle)
                LabeledContent("包标识", value: Bundle.main.bundleIdentifier ?? AppIdentifiers.current.hostBundleID)
                LabeledContent("Core ABI 版本", value: String(store.environment.abiVersion))
                Text("© OpenStreetMap contributors · ODbL 1.0")
                Text("香港特别行政区政府民政事务总署 · 政府开放数据")
                Text("Natural Earth · 公有领域")
                Text("Jost 字标 · SIL OFL 1.1")
            }
        }
        .navigationTitle("设置")
        .onChange(of: store.settings.customProxyText, initial: true) { _, address in proxyText = address }
        .sensoryFeedback(trigger: store.feedback) { _, message in message?.sensation }
    }

    private var buildKindTitle: String {
        switch store.capabilities.buildKind {
        case .full: String(localized: "完整版")
        case .partial: String(localized: "部分能力可用")
        case .sideloadFree: String(localized: "精简侧载版")
        }
    }

    private func setting<Value>(_ key: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { store.settings[keyPath: key] }, set: { value in
            Task { await store.updateSettings { $0[keyPath: key] = value } }
        })
    }
}

struct ExistingRouteInfo: View {
    var body: some View {
        LabeledContent("连接通道", value: String(localized: "已有路由"))
        Text("连接本机时，可从 App Store 免费安装 LocalDevVPN，或使用已安装的 StosVPN。开启 VPN，确认回环对端与目标 IP 一致（默认 \(LoopbackTarget.defaultPeer)），再回到配置向导点「测试连接」。连接同一局域网内的其他设备时，请填写该设备的 IP。")
            .font(.footnote).foregroundStyle(.secondary)
    }
}
