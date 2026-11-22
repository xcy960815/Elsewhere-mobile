import SwiftUI
import UIKit

struct FeedbackMessage: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case success, failure, info }

    let id = UUID()
    let kind: Kind
    let title: String
    var detail: String?
    var rawLog: String?
}

struct FeedbackBanner: View {
    let message: FeedbackMessage
    let onDismiss: () -> Void

    @State private var expanded = false
    @State private var copied = false
    @ScaledMetric(relativeTo: .caption) private var logHeight: CGFloat = 140

    var body: some View {
        let style: (icon: String, tint: Color) = switch message.kind {
        case .success: ("checkmark.circle.fill", .green)
        case .failure: ("exclamationmark.triangle.fill", .red)
        case .info: ("info.circle.fill", .secondary)
        }
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label {
                        Text(message.title).font(.headline)
                    } icon: {
                        Image(systemName: style.icon).foregroundStyle(style.tint)
                    }
                    Spacer(minLength: 0)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("关闭")
                }
                if let detail = message.detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                if let log = message.rawLog {
                    DisclosureGroup("原始输出", isExpanded: $expanded) {
                        VStack(alignment: .trailing, spacing: 8) {
                            ScrollView {
                                Text(verbatim: log)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: logHeight)
                            Button {
                                UIPasteboard.general.string = log
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                copied = true
                            } label: {
                                if copied {
                                    Label("已拷贝", systemImage: "checkmark")
                                } else {
                                    Label("拷贝", systemImage: "doc.on.doc")
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .font(.subheadline)
                }
            }
        }
        .buttonStyle(.borderless)
        .tint(.primary)
        .onChange(of: message) {
            expanded = false
            copied = false
        }
    }
}

struct StatusPill: View {
    let title: LocalizedStringKey
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct SurfaceCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5).allowsHitTesting(false))
            .accessibilityElement(children: .contain)
    }
}

struct HintBanner: View {
    let title: LocalizedStringKey
    var systemImage = "info.circle"
    var action: (title: LocalizedStringKey, perform: () -> Void)?

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let action {
                    Button(action.title, action: action.perform)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(.primary)
                }
            }
        }
    }
}
