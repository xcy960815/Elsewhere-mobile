import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        var loading = UIContentUnavailableConfiguration.loading()
        loading.text = String(localized: "正在接收配对文件")
        contentUnavailableConfiguration = loading

        for case let item as NSExtensionItem in extensionContext?.inputItems ?? [] {
            for provider in item.attachments ?? [] {
                guard let type = [UTType.propertyList, .fileURL, .data].first(where: {
                    provider.hasItemConformingToTypeIdentifier($0.identifier)
                }) else { continue }
                if type == .fileURL {
                    provider.loadObject(ofClass: URL.self) { url, _ in self.receive(url) }
                } else {
                    provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in self.receive(url) }
                }
                return
            }
        }
        showResult(.unreadableFile)
    }

    private nonisolated func receive(_ url: URL?) {
        let failure: PairingInboxError?
        do throws(PairingInboxError) {
            guard let url, url.isFileURL else { throw .unreadableFile }
            _ = try PairingInbox().enqueue(fileURL: url)
            failure = nil
        } catch {
            failure = error
        }
        Task { @MainActor in showResult(failure) }
    }

    private func showResult(_ error: PairingInboxError?) {
        var result = UIContentUnavailableConfiguration.empty()
        result.image = UIImage(systemName: error == nil ? "checkmark.circle" : "exclamationmark.circle")
        result.text = error?.localizedDescription ?? String(localized: "已转交 Elsewhere，请打开 App 完成验证")
        result.button.title = String(localized: "完成")
        result.buttonProperties.primaryAction = UIAction { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
        contentUnavailableConfiguration = result
    }
}
