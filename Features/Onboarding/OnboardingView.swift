import SwiftUI
import UniformTypeIdentifiers

struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var step = 1
    @State private var host = LoopbackTarget.defaultPeer
    @State private var importing = false
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
                case 1:
                    Text("开启开发者模式").font(.largeTitle.bold())
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("在目标设备上打开「设置 › 隐私与安全性 › 开发者模式」，开启开发者模式。")
                            Text("按提示重新启动。解锁设备后，在确认框中点「打开」，并输入设备密码。")
                        }
                    }
                case 2: pairing
                default: connection
                }
                if let message = store.feedback {
                    FeedbackBanner(message: message, onDismiss: store.dismissFeedback)
                }
                HStack {
                    if step > 1 { Button("上一步") { step -= 1 } }
                    Spacer()
                    if step < 3 {
                        Button("下一步") { step += 1 }
                            .buttonStyle(.borderedProminent).disabled(step == 2 && record == nil)
                    } else {
                        Button("完成配置", action: finish)
                        .buttonStyle(.borderedProminent).disabled(testedID == nil || testedID != record?.id)
                    }
                }
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { alternatives }
                    VStack(alignment: .leading, spacing: 12) { alternatives }
                }
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
                if (error as? CocoaError)?.code != .userCancelled { store.fail("无法打开配对文件", error) }
            }
        }
        .onChange(of: store.settings.channelMode) { testedID = nil }
        .onChange(of: selectedID) { testedID = nil }
        .sensoryFeedback(trigger: store.feedback) { _, message in message?.sensation }
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导入配对文件").font(.largeTitle.bold())
            Text("用 USB 将目标设备连接到已信任的电脑。在电脑上打开 idevice_pair，选择该设备，导出 Lockdown 配对记录，再将 .mobiledevicepairing 文件保存到本机的「文件」。")
            TextField("目标 IP 地址", text: $host)
                .textFieldStyle(.roundedBorder).keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            let valid = LoopbackTarget.addressBytes(host) != nil
            Text(valid ? "此地址用于连接设备，请填写虚拟对端或局域网设备的 IP。" : "请输入有效的 IPv4 或 IPv6 地址。")
                .font(.footnote).foregroundStyle(valid ? Color.secondary : .red)
            Button { importing = true } label: { Label("选择配对文件", systemImage: "doc.badge.plus") }
                .buttonStyle(.bordered).disabled(!valid)
            ForEach(store.pairingRecords) { item in
                Label(item.deviceName ?? item.udid?.rawValue ?? item.endpointHost, systemImage: "checkmark.circle")
                    .font(.subheadline).accessibilityLabel("已导入 \(item.deviceName ?? item.endpointHost)")
            }
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择通道并测试连接").font(.largeTitle.bold())
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
            Text(store.settings.channelMode == .existingRoute ? "使用已配置的路由连接设备，可与提供目标路由的代理 App 共存。"
                : "首次使用需批准系统 VPN 配置。操作结束后自动断开本次启动的通道。")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("测试连接") {
                guard let record else { return }
                working = true
                testedID = nil
                Task {
                    if await store.testConnection(recordID: record.id) { testedID = record.id }
                    working = false
                }
            }
            .buttonStyle(.bordered).disabled(record == nil)
            if working { ProgressView() }
            if testedID != nil, testedID == record?.id { Label("设备已通过连接测试", systemImage: "checkmark.circle") }
        }
    }

    @ViewBuilder private var alternatives: some View {
        Button("稍后再说", action: finish)
        Button("进入演示模式") {
            Task {
                await store.switchToDemo(true)
                if store.isDemo { dismiss() }
            }
        }
    }

    private func finish() {
        Task {
            await store.completeOnboarding()
            if store.settings.hasCompletedOnboarding { dismiss() }
        }
    }
}
