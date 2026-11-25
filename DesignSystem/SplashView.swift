import SwiftUI

struct SplashView: View {
    let onFinish: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var field = CodeFieldModel()
    @State private var markIn = false
    @State private var arrived = false
    @State private var leaving = false
    @State private var revealing = false
    @ScaledMetric(relativeTo: .headline) private var buttonHeight: CGFloat = 46

    var body: some View {
        GeometryReader { safe in
            GeometryReader { full in
                let size = full.size
                let insets = safe.safeAreaInsets
                let x = insets.leading + safe.size.width / 2
                let width = min(580, safe.size.width * 0.78)
                let markHeight = width / CGFloat(WordmarkGlyphs.aspectRatio)
                let button = CGPoint(x: x, y: size.height - insets.bottom - buttonHeight / 2 - min(40, safe.size.height * 0.06))
                let center = CGPoint(x: x, y: min(insets.top + safe.size.height * 0.42,
                                                  button.y - buttonHeight / 2 - 16 - markHeight / 2))
                let dark = scheme == .dark
                ZStack {
                    dark ? Color(red: 5 / 255, green: 6 / 255, blue: 7 / 255) : .white
                    CodeField(dark: dark, animated: true,
                              calm: (center, CGSize(width: width / 2 + 45, height: markHeight / 2 + 60)),
                              calmBottom: size.height - button.y + buttonHeight, model: field)
                    Wordmark(breathing: true)
                        .frame(width: width)
                        .position(center)
                        .opacity(markIn ? 1 : 0)
                        .allowsHitTesting(false)
                    Button("开始使用") { start(from: button, size: size) }
                        .font(.headline)
                        .buttonStyle(StartButtonStyle(dark: dark, width: min(260, safe.size.width * 0.68), height: buttonHeight))
                        .position(button)
                        .opacity(arrived && !leaving ? 1 : 0)
                        .offset(y: reduceMotion ? 0 : (leaving ? 16 : (arrived ? 0 : 14)))
                        .disabled(!arrived || leaving)
                }
                .mask {
                    HoleMask(point: button, size: size, progress: revealing && !reduceMotion ? 1 : 0)
                }
                .opacity(revealing && reduceMotion ? 0 : 1)
                .task {
                    withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.8)) { markIn = true }
                    if !reduceMotion {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled else { return }
                        field.tap(at: center, strength: 0.8)
                        try? await Task.sleep(for: .milliseconds(200))
                        guard !Task.isCancelled else { return }
                    }
                    withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.65)) { arrived = true }
                }
            }
            .ignoresSafeArea()
        }
    }

    private func start(from point: CGPoint, size: CGSize) {
        withAnimation(.easeOut(duration: 0.24), completionCriteria: .removed) { leaving = true } completion: {
            if !reduceMotion { field.reveal(at: point) }
            let duration = reduceMotion ? 0.3 : HoleMask.extent(from: point, in: size) / 850
            withAnimation(.linear(duration: duration), completionCriteria: .removed) {
                revealing = true
            } completion: { onFinish() }
        }
    }
}

private struct HoleMask: View, Animatable {
    let point: CGPoint
    let size: CGSize
    var progress: Double
    private static let edge: CGFloat = 70

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    static func extent(from point: CGPoint, in size: CGSize) -> CGFloat {
        hypot(max(point.x, size.width - point.x), max(point.y, size.height - point.y)) + edge
    }

    var body: some View {
        Rectangle()
            .overlay {
                if progress > 0 {
                    let radius = progress * Self.extent(from: point, in: size)
                    Circle()
                        .fill(RadialGradient(stops: [.init(color: .black, location: max(0, 1 - Self.edge / radius)),
                                                     .init(color: .clear, location: 1)],
                                             center: .center, startRadius: 0, endRadius: radius))
                        .frame(width: radius * 2, height: radius * 2)
                        .position(point)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
    }
}

private struct StartButtonStyle: ButtonStyle {
    let dark: Bool
    let width: CGFloat
    let height: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let accent = dark ? Color(.sRGB, red: 0x8E / 255, green: 0xC2 / 255, blue: 0xFE / 255)
                          : Color(.sRGB, red: 0x31 / 255, green: 0x83 / 255, blue: 0xD8 / 255)
        configuration.label
            .frame(width: width, height: height)
            .foregroundStyle(dark ? Color(red: 5 / 255, green: 6 / 255, blue: 7 / 255) : .white)
            .background(accent, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(dark ? 0.25 : 0.35), lineWidth: 0.5))
            .shadow(color: accent.opacity(dark ? 0.3 : 0.32), radius: dark ? 14 : 9, y: dark ? 4 : 6)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Capsule())
    }
}
