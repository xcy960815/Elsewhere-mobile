import SwiftUI
import UniformTypeIdentifiers

struct OnboardingView: View {
    private enum SetupScenario { case thisDevice, lanDevice }

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var step = 1
    @State private var scenario = SetupScenario.thisDevice
    @State private var host = LoopbackTarget.defaultPeer
    @State private var importing = false
    @State private var importingDDI = false
    @State private var working = false
    @State private var selectedID: UUID?
    @State private var testedID: UUID?

    private var record: StoredPairingRecord? {
        store.pairingRecords.first { $0.id == selectedID } ?? store.pairingRecords.last
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Wordmark().frame(width: 110).padding(.vertical, 8)
                ProgressView(value: Double(step), total: 3) {
                    Text("第 \(step) 步，共 3 步").font(.caption).foregroundStyle(.secondary)
                }
                switch step {
                case 1: scenarios
                case 2: pairing
                default: connection
                }
                if let message = store.feedback {
                    FeedbackBanner(message: message, onDismiss: store.dismissFeedback)
                }
                HStack {
                    if step > 1 { Button("上一步") { step -= 1 } }
                    Spacer()
                    if step == 2 {
                        Button("下一步") { step += 1 }
                            .buttonStyle(.borderedProminent).disabled(record == nil)
                    } else if step == 3 {
                        Button(testedID != nil && testedID == record?.id ? "完成配置" : "先进入主界面", action: finish)
                            .buttonStyle(.borderedProminent).disabled(record == nil)
                    }
                }
                Button("稍后再说", action: finish)
            }
            .frame(maxWidth: 540, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
            .disabled(working || store.busyMessage != nil)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [
            UTType(importedAs: "com.elsewhere.mobile.mobiledevicepairing", conformingTo: .propertyList), .propertyList
        ]) { result in
            switch result {
            case .success(let url):
                working = true
                Task {
                    defer { working = false }
                    if let imported = try? await store.importPairing(url: url, endpointHost: host, deviceName: nil) {
                        selectedID = imported.id
                        testedID = nil
                    }
                }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { store.fail(String(localized: "无法打开配对文件"), error) }
            }
        }
        .onChange(of: store.settings.channelMode) { testedID = nil }
        .onChange(of: selectedID) { testedID = nil }
        .onChange(of: scenario) { testedID = nil }
        .sensoryFeedback(trigger: store.feedback) { _, message in message?.sensation }
    }

    private var scenarios: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择使用场景").font(.largeTitle.bold())
            Text("目标设备须已开启「设置 › 隐私与安全性 › 开发者模式」。").font(.footnote).foregroundStyle(.secondary)
            Button {
                scenario = .thisDevice
                host = LoopbackTarget.defaultPeer
                step = 2
            } label: {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("修改这台设备（本机）· 推荐", systemImage: "iphone").font(.headline)
                        Text("配合 LocalDevVPN / StosVPN，或完整版的内置通道使用。").font(.subheadline)
                    }
                }
            }
            Button {
                scenario = .lanDevice
                if host == LoopbackTarget.defaultPeer { host = "" }
                working = true
                Task {
                    await store.updateSettings { $0.channelMode = .existingRoute }
                    working = false
                    step = 2
                }
            } label: {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("修改同一 Wi-Fi 的另一台设备", systemImage: "wifi").font(.headline)
                        Text("通过局域网无线连接另一台 iPhone / iPad。").font(.subheadline)
                    }
                }
            }
            Button {
                Task {
                    await store.switchToDemo(true)
                    if store.isDemo { dismiss() }
                }
            } label: {
                SurfaceCard { Label("先用演示模式体验", systemImage: "play.circle") }
            }
        }
        .buttonStyle(.plain)
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导入配对与准备组件").font(.largeTitle.bold())
            Text("用已信任目标设备的电脑，通过 idevice_pair 导出 Lockdown 配对文件，保存到本机的「文件」。")
            TextField(scenario == .thisDevice ? "本机回环对端 IP" : "同一 Wi-Fi 下目标设备 IP", text: $host)
                .textFieldStyle(.roundedBorder).keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            let valid = LoopbackTarget.addressBytes(host) != nil
            Text(scenario == .thisDevice
                 ? (valid ? "请与回环通道对端一致，默认为 \(LoopbackTarget.defaultPeer)。" : "请输入有效的回环对端 IPv4 或 IPv6 地址。")
                 : (valid ? "请填写同一 Wi-Fi 下目标设备的 IP。" : "请输入有效的局域网 IPv4 或 IPv6 地址。"))
                .font(.footnote).foregroundStyle(valid ? Color.secondary : .red)
            Button { importing = true } label: { Label("选择配对文件", systemImage: "doc.badge.plus") }
                .buttonStyle(.bordered).disabled(!valid)
            ForEach(store.pairingRecords) { item in
                Label(item.deviceName ?? item.udid?.rawValue ?? item.endpointHost, systemImage: "checkmark.circle")
                    .font(.subheadline).accessibilityLabel("已导入 \(item.deviceName ?? item.endpointHost)")
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("开发者组件（DDI）").font(.headline)
                    switch store.ddiCacheStatus {
                    case .ready(_, let totalBytes):
                        Label("已就绪 · \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .notDownloaded:
                        Text("建议趁当前网络或代理畅通时预先下载，切到本机回环后无需联网。").font(.footnote)
                    }
                    if let message = store.busyMessage { ProgressView(value: store.ddiProgress) { Text(message) } }
                    Button("预下载组件") { Task { await store.prepareDDICache() } }
                    Button("从文件导入") { importingDDI = true }
                        .fileImporter(isPresented: $importingDDI, allowedContentTypes: [.folder, .propertyList, .data], allowsMultipleSelection: true) { result in
                            switch result {
                            case .success(let urls): Task { await store.importLocalDDI(urls: urls) }
                            case .failure(let error):
                                if (error as? CocoaError)?.code != .userCancelled { store.fail(String(localized: "无法打开开发者组件"), error) }
                            }
                        }
                }
            }
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("接通通道并测试").font(.largeTitle.bold())
            if let record {
                Menu {
                    ForEach(store.pairingRecords) { item in
                        Button(item.deviceName ?? item.udid?.rawValue ?? item.endpointHost) { selectedID = item.id }
                    }
                } label: {
                    Label(record.deviceName ?? record.udid?.rawValue ?? record.endpointHost, systemImage: "iphone")
                }
                Text(record.endpointHost).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if scenario == .thisDevice, store.capabilities.hasBuiltInTunnel {
                Picker("连接通道", selection: Binding(get: { store.settings.channelMode }, set: { mode in
                    working = true
                    Task {
                        await store.updateSettings {
                            $0.channelMode = mode
                            if mode == .builtInTunnel { $0.autoDisconnectTunnel = true }
                        }
                        working = false
                    }
                })) {
                    Text("已有路由（推荐）").tag(ChannelMode.existingRoute)
                    Text("内置回环通道").tag(ChannelMode.builtInTunnel)
                }
                .pickerStyle(.segmented)
            }
            Text(scenario == .lanDevice ? "让两台设备连接同一 Wi-Fi，解锁目标设备，然后点「测试连接」。"
                 : store.capabilities.hasBuiltInTunnel && store.settings.channelMode == .builtInTunnel
                 ? "点「测试连接」启动内置通道，首次使用需批准系统 VPN 配置。"
                 : "先切去打开 LocalDevVPN / StosVPN，确认回环对端与目标 IP 一致，再回到这里点「测试连接」。")
                .font(.subheadline).foregroundStyle(.secondary)
            if let record {
                Button("测试连接") {
                    working = true
                    testedID = nil
                    Task {
                        if await store.testConnection(recordID: record.id) { testedID = record.id }
                        working = false
                    }
                }
                .buttonStyle(.bordered)
            }
            if working { ProgressView() }
            if testedID != nil, testedID == record?.id { Label("设备已通过连接测试", systemImage: "checkmark.circle").foregroundStyle(.green) }
        }
    }

    private func finish() {
        Task {
            await store.completeOnboarding()
            if store.settings.hasCompletedOnboarding { dismiss() }
        }
    }
}
