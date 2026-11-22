import SwiftUI
import UniformTypeIdentifiers

struct PairingManagementView: View {
    @Environment(AppStore.self) private var store
    @State private var host = LoopbackTarget.defaultPeer
    @State private var importing = false
    @State private var working = false
    @State private var editing: UUID?
    @State private var editedHost = ""

    var body: some View {
        List {
            if store.isDemo {
                Section {
                    Label("当前使用演示设备", systemImage: "iphone")
                    Button("退出演示模式") { Task { await store.switchToDemo(false) } }
                } footer: {
                    Text("演示期间导入的配对记录仅供本次演示使用。")
                }
            }
            if let message = store.feedback { FeedbackBanner(message: message, onDismiss: store.dismissFeedback) }
            Section("已导入的配对") {
                if store.pairingRecords.isEmpty { Text("尚未导入配对文件").foregroundStyle(.secondary) }
                ForEach(store.pairingRecords) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(record.deviceName ?? store.deviceStates[record.probeID]?.device?.name ?? String(localized: "未命名设备"))
                            .font(.headline)
                        if let udid = record.udid {
                            Text("UDID · \(udid.rawValue)").font(.caption.monospaced())
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                        if editing == record.id {
                            TextField("目标 IP 地址", text: $editedHost)
                                .keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                Button("取消") { editing = nil }
                                Button("保存地址") {
                                    working = true
                                    let address = editedHost
                                    Task {
                                        await store.updateEndpointHost(address, for: record.id)
                                        if store.pairingRecords.contains(where: { $0.id == record.id && $0.endpointHost == address }) {
                                            editing = nil
                                        }
                                        working = false
                                    }
                                }
                                .disabled(LoopbackTarget.addressBytes(editedHost) == nil)
                            }
                        } else {
                            Text("目标地址 · \(record.endpointHost)").font(.subheadline.monospacedDigit())
                            HStack {
                                Button("测试连接") { Task { _ = await store.testConnection(recordID: record.id) } }
                                Button("修改地址") { editedHost = record.endpointHost; editing = record.id }
                            }
                        }
                        Text(store.deviceStates[record.probeID]?.diagnosis ?? String(localized: "尚未测试连接"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .swipeActions(allowsFullSwipe: false) {
                        Button("删除", role: .destructive) {
                            working = true
                            Task { await store.deletePairing(id: record.id); working = false }
                        }
                    }
                }
            }
            Section {
                TextField("目标 IP 地址", text: $host)
                    .keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button { importing = true } label: { Label("导入配对文件", systemImage: "doc.badge.plus") }
                    .disabled(LoopbackTarget.addressBytes(host) == nil)
            } header: {
                Text("导入新设备")
            } footer: {
                Text("填写虚拟对端或局域网设备的 IP，然后选择 .mobiledevicepairing 或 .plist 文件。")
            }
            if let message = store.busyMessage { ProgressView { Text(message) }.progressViewStyle(.linear) }
        }
        .navigationTitle("设备与配对")
        .disabled(working || store.busyMessage != nil)
        .fileImporter(isPresented: $importing, allowedContentTypes: [
            UTType(importedAs: "com.elsewhere.mobile.mobiledevicepairing", conformingTo: .propertyList), .propertyList
        ]) { result in
            switch result {
            case .success(let url):
                working = true
                Task {
                    _ = try? await store.importPairing(url: url, endpointHost: host, deviceName: nil)
                    working = false
                }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { store.fail(String(localized: "无法打开配对文件"), error) }
            }
        }
        .sensoryFeedback(trigger: store.feedback) { _, message in message?.sensation }
    }
}
