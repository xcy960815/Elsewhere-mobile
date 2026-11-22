import Combine
import CoreText
import SwiftUI
import UIKit

struct MotionTimeline<Content: View>: View {
    let animated: Bool
    let fps: Double
    @ViewBuilder let content: (Date?) -> Content

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        Group {
            if animated && !reduceMotion && !lowPower {
                TimelineView(.animation(minimumInterval: 1 / fps, paused: scenePhase != .active)) { timeline in
                    content(timeline.date)
                }
            } else {
                content(nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}

struct CodeField: View {
    var dark: Bool
    var animated = false
    var calm: (center: CGPoint, radius: CGSize)?
    var calmColumn: CGFloat?
    var calmBottom: CGFloat?
    var strength: Double = 1
    var fps: Double = 12
    var model: CodeFieldModel?

    @State private var own = CodeFieldModel()

    var body: some View {
        let field = model ?? own
        MotionTimeline(animated: animated, fps: field.excited ? max(fps, 30) : fps) { date in
            Canvas { ctx, size in
                field.draw(in: &ctx, size: size, now: date, dark: dark, calm: calm, column: calmColumn,
                           bottom: calmBottom, strength: strength)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { field.drag(to: $0.location) }
                .onEnded { _ in field.endDrag() }, including: date == nil ? .none : .all)
        }
        .accessibilityHidden(true)
    }
}

@Observable @MainActor
final class CodeFieldModel {
    private(set) var excited = false
    private static let cell = CGSize(width: 7, height: 12)
    private static let charset = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ0123456789".utf16)
    private static let font = UIFont.monospacedSystemFont(ofSize: 9.5, weight: .medium) as CTFont
    private static let glyphs: [CGGlyph] = {
        var out = [CGGlyph](repeating: 0, count: charset.count)
        CTFontGetGlyphsForCharacters(font, charset, &out, charset.count)
        return out
    }()

    private static let levels = 32
    @ObservationIgnored private var cols = 0
    @ObservationIgnored private var rows = 0
    @ObservationIgnored private var chars: [UInt8] = []
    @ObservationIgnored private var seeds: [Double] = []
    @ObservationIgnored private var start: Date?
    @ObservationIgnored private var ripples: [Ripple] = []
    @ObservationIgnored private var rippleIndex = 0
    @ObservationIgnored private var dark = false
    @ObservationIgnored private var lastDrag: Date?

    private struct Ripple {
        var point: CGPoint
        var time: Date
        var color: (Double, Double, Double)
        var s = 1.0, speed = 0.26, width = 34.0, life = 1500.0
    }

    private static func palette(dark: Bool) -> [(Double, Double, Double)] {
        dark ? [(46, 87, 219), (26, 194, 224), (158, 189, 255), (120, 160, 255)]
             : [(49, 131, 216), (66, 122, 214), (42, 163, 217), (95, 168, 238)]
    }

    private static func randomChar() -> UInt8 { UInt8.random(in: 0..<UInt8(charset.count)) }

    func tap(at point: CGPoint, strength: Double = 1) {
        let p = Self.palette(dark: dark)
        add(Ripple(point: point, time: Date(), color: p[rippleIndex % p.count], s: strength))
        rippleIndex += 1
    }

    func reveal(at point: CGPoint) {
        add(Ripple(point: point, time: Date(), color: Self.palette(dark: dark)[0], s: 1.1, speed: 0.85, width: 40, life: 900))
    }

    func drag(to point: CGPoint) {
        let now = Date()
        if let last = lastDrag {
            guard now.timeIntervalSince(last) >= 0.09 else { return }
            tap(at: point, strength: 0.6)
        } else {
            tap(at: point)
        }
        lastDrag = now
    }

    func endDrag() { lastDrag = nil }

    private func add(_ ripple: Ripple) {
        ripples.append(ripple)
        if ripples.count > 14 { ripples.removeFirst() }
        if !excited { excited = true }
    }

    private func prepare(_ size: CGSize) {
        let c = Int((size.width / Self.cell.width).rounded(.up)), r = Int((size.height / Self.cell.height).rounded(.up))
        guard c != cols || r != rows else { return }
        cols = c; rows = r
        let n = c * r
        // 和设计稿同一个种子，静止的第一帧和设计稿一致
        var rng = Mulberry32(state: 20261018)
        chars = (0..<n).map { _ in UInt8(Int(rng.next() * Double(Self.charset.count))) }
        seeds = (0..<n).map { _ in rng.next() }
    }

    func draw(in ctx: inout GraphicsContext, size: CGSize, now: Date?, dark: Bool,
              calm: (center: CGPoint, radius: CGSize)?, column: CGFloat?, bottom: CGFloat?, strength: Double) {
        self.dark = dark
        prepare(size)
        let n = chars.count
        guard n > 0 else { return }
        let base = dark ? (232.0, 237.0, 240.0) : (70.0, 80.0, 98.0)

        var tt = 0.0
        // 每个波纹已经过去的毫秒数，逐格计算时不再重复取时间
        var live: [(ripple: Ripple, dt: Double)] = []
        if let now {
            if start == nil { start = now }
            tt = now.timeIntervalSince(start!)
            for _ in 0..<max(1, n * 12 / 1000) { chars[Int.random(in: 0..<n)] = Self.randomChar() }
            ripples.removeAll { now.timeIntervalSince($0.time) > 3.2 }
            if ripples.isEmpty && excited {
                // 画的时候不能改被观察的值，放到下一轮
                DispatchQueue.main.async { [weak self] in
                    if let self, self.ripples.isEmpty { self.excited = false }
                }
            }
            live = ripples.map { ($0, now.timeIntervalSince($0.time) * 1000) }
        }

        let ascent = CTFontGetAscent(Self.font)
        var batchGlyphs = [[CGGlyph]](repeating: [], count: Self.levels)
        var batchPositions = [[CGPoint]](repeating: [], count: Self.levels)
        ctx.withCGContext { cg in
            // Canvas 的坐标是 y 向下，字形要翻过来画；文字矩阵也会作用在位置上，所以 y 取负
            cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            for r in 0..<rows {
                let y = Double(r) * Self.cell.height
                for c in 0..<cols {
                    let i = r * cols + c
                    let x = Double(c) * Self.cell.width
                    let cx = x + 3, cy = y + 6
                    let noise = 0.5 + 0.25 * sin(x * 0.021 + tt * 0.12) * cos(y * 0.017 - tt * 0.09)
                        + 0.25 * sin((x + y) * 0.011 + tt * 0.07 + seeds[i] * 0.6)
                    let quiet = calmFactor(cx, cy, calm) * columnFactor(cx, width: size.width, column: column)
                        * bottomFactor(cy, height: size.height, bottom: bottom)
                    let a = (0.012 + 0.2 * min(1, max(0, (noise - 0.56) / 0.26))) * quiet

                    var amp = 0.0
                    var tint: (Double, Double, Double)?
                    for (p, dt) in live {
                        let d = hypot(cx - p.point.x, cy - p.point.y)
                        let ring = exp(-pow((d - dt * p.speed) / p.width, 2))
                        let core = 0.55 * exp(-(d * d) / (2 * 38 * 38)) * exp(-dt / 350)
                        let v = (ring + core) * exp(-dt / p.life) * p.s
                        if v > amp { amp = v; tint = p.color }
                    }
                    if !live.isEmpty {
                        amp *= 0.2 + 0.8 * quiet
                        if amp > 0.35, Double.random(in: 0..<1) < 0.25 { chars[i] = Self.randomChar() }
                    }

                    let alpha = min(0.92, a + amp * 0.85) * strength
                    guard alpha >= 0.02 else { continue }
                    let position = CGPoint(x: x, y: -(y + ascent))
                    let glyph = Self.glyphs[Int(chars[i])]
                    if let col = tint, amp > 0.02 {
                        let m = min(1, amp * 2.2)
                        cg.setFillColor(red: (base.0 + (col.0 - base.0) * m) / 255,
                                        green: (base.1 + (col.1 - base.1) * m) / 255,
                                        blue: (base.2 + (col.2 - base.2) * m) / 255, alpha: alpha)
                        var g = glyph, pos = position
                        CTFontDrawGlyphs(Self.font, &g, &pos, 1, cg)
                    } else {
                        // 同一透明度的字形合批，减少 CoreText 调用
                        let level = min(Self.levels - 1, Int(alpha / 0.92 * Double(Self.levels)))
                        batchGlyphs[level].append(glyph)
                        batchPositions[level].append(position)
                    }
                }
            }
            for level in 0..<Self.levels where !batchGlyphs[level].isEmpty {
                let alpha = (Double(level) + 0.5) / Double(Self.levels) * 0.92
                cg.setFillColor(red: base.0 / 255, green: base.1 / 255, blue: base.2 / 255, alpha: alpha)
                CTFontDrawGlyphs(Self.font, batchGlyphs[level], batchPositions[level], batchGlyphs[level].count, cg)
            }
        }
    }

    private func columnFactor(_ x: Double, width: Double, column: CGFloat?) -> Double {
        guard let column else { return 1 }
        let edge = abs(x - width / 2) - Double(column) / 2
        return 0.18 + 0.82 * min(1, max(0, (edge + 24) / 48))
    }

    private func bottomFactor(_ y: Double, height: Double, bottom: CGFloat?) -> Double {
        guard let bottom else { return 1 }
        return 1 - 0.75 * min(1, max(0, (y - (height - Double(bottom))) / 50))
    }

    private func calmFactor(_ x: Double, _ y: Double, _ calm: (center: CGPoint, radius: CGSize)?) -> Double {
        guard let calm else { return 1 }
        let dx = (x - calm.center.x) / calm.radius.width, dy = (y - calm.center.y) / calm.radius.height
        return min(1, max(0.08, (dx * dx + dy * dy - 0.55) / 0.6))
    }
}

private struct Mulberry32 {
    var state: UInt32

    mutating func next() -> Double {
        state &+= 0x6D2B_79F5
        var t = (state ^ (state >> 15)) &* (1 | state)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}
