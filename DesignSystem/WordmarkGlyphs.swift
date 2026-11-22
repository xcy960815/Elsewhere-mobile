import CoreGraphics
import SwiftUI

// ELSEWHERE 字标的字形：Jost Light 大写（和 Nebulium 字标同一款字体，SIL Open Font License 1.1），字距 337/1000，和 Nebulium 一致。
// 由 Jost 的字形轮廓导出，按框高归一化到单位框（x、y 都除以框高，y 向下）。
// 指令：0 move(x, y)，1 line(x, y)，2 quad(cx, cy, x, y)，3 close。
enum WordmarkGlyphs {
    static let aspectRatio: Double = 6.86403
    static let leftStem = CGRect(x: 4.11666, y: 0.19298, width: 0.04846, height: 0.61404)
    static let rightStem = CGRect(x: 4.52416, y: 0.00000, width: 0.04846, height: 1.00000)
    static let crossbar = CGRect(x: 4.16513, y: 0.45000, width: 0.35903, height: 0.04561)
    static let ink: [Double] = [
        0, 0.02544, 0.80702,
        1, 0.32982, 0.80702,
        1, 0.32982, 0.76140,
        1, 0.02544, 0.76140,
        3,
        0, 0.02544, 0.23860,
        1, 0.32982, 0.23860,
        1, 0.32982, 0.19298,
        1, 0.02544, 0.19298,
        3,
        0, 0.02544, 0.49334,
        1, 0.31228, 0.49334,
        1, 0.31228, 0.44772,
        1, 0.02544, 0.44772,
        3,
        0, 0.00000, 0.19298,
        1, 0.00000, 0.80702,
        1, 0.04860, 0.80702,
        1, 0.04860, 0.19298,
        3,
        0, 0.76403, 0.19298,
        1, 0.76403, 0.80702,
        1, 1.06579, 0.80702,
        1, 1.06579, 0.76140,
        1, 0.81228, 0.76140,
        1, 0.81228, 0.19298,
        3,
        0, 1.45193, 0.62947,
        1, 1.41228, 0.65474,
        2, 1.42719, 0.69719, 1.45447, 0.73394,
        2, 1.48176, 0.77070, 1.52220, 0.79289,
        2, 1.56264, 0.81509, 1.61543, 0.81509,
        2, 1.65333, 0.81509, 1.68570, 0.80298,
        2, 1.71806, 0.79087, 1.74236, 0.76877,
        2, 1.76667, 0.74667, 1.78026, 0.71579,
        2, 1.79386, 0.68491, 1.79386, 0.64737,
        2, 1.79386, 0.60666, 1.77982, 0.57728,
        2, 1.76579, 0.54789, 1.74324, 0.52693,
        2, 1.72069, 0.50596, 1.69368, 0.49193,
        2, 1.66667, 0.47789, 1.64105, 0.46842,
        2, 1.59175, 0.45070, 1.55850, 0.43114,
        2, 1.52526, 0.41158, 1.50859, 0.38675,
        2, 1.49193, 0.36192, 1.49193, 0.32843,
        2, 1.49193, 0.28666, 1.52087, 0.25921,
        2, 1.54982, 0.23176, 1.60369, 0.23176,
        2, 1.64350, 0.23176, 1.67078, 0.24684,
        2, 1.69807, 0.26192, 1.71596, 0.28491,
        2, 1.73385, 0.30789, 1.74386, 0.33140,
        1, 1.78614, 0.30789,
        2, 1.77404, 0.27825, 1.75018, 0.25009,
        2, 1.72631, 0.22193, 1.69079, 0.20342,
        2, 1.65526, 0.18491, 1.60632, 0.18491,
        2, 1.55841, 0.18491, 1.52105, 0.20377,
        2, 1.48369, 0.22263, 1.46246, 0.25631,
        2, 1.44123, 0.28999, 1.44123, 0.33421,
        2, 1.44123, 0.37351, 1.45640, 0.40158,
        2, 1.47157, 0.42965, 1.49613, 0.44938,
        2, 1.52069, 0.46912, 1.54929, 0.48289,
        2, 1.57789, 0.49667, 1.60421, 0.50632,
        2, 1.63929, 0.51894, 1.67131, 0.53623,
        2, 1.70333, 0.55351, 1.72350, 0.58088,
        2, 1.74368, 0.60825, 1.74368, 0.65263,
        2, 1.74368, 0.70315, 1.70982, 0.73614,
        2, 1.67596, 0.76912, 1.61702, 0.76912,
        2, 1.57245, 0.76912, 1.54087, 0.75035,
        2, 1.50929, 0.73158, 1.48798, 0.69982,
        2, 1.46667, 0.66806, 1.45193, 0.62947,
        3,
        0, 2.22807, 0.80702,
        1, 2.53245, 0.80702,
        1, 2.53245, 0.76140,
        1, 2.22807, 0.76140,
        3,
        0, 2.22807, 0.23860,
        1, 2.53245, 0.23860,
        1, 2.53245, 0.19298,
        1, 2.22807, 0.19298,
        3,
        0, 2.22807, 0.49334,
        1, 2.51491, 0.49334,
        1, 2.51491, 0.44772,
        1, 2.22807, 0.44772,
        3,
        0, 2.20263, 0.19298,
        1, 2.20263, 0.80702,
        1, 2.25123, 0.80702,
        1, 2.25123, 0.19298,
        3,
        0, 3.50684, 0.70053,
        1, 3.32017, 0.16930,
        1, 3.13561, 0.70053,
        1, 2.95911, 0.19298,
        1, 2.90526, 0.19298,
        1, 3.13245, 0.83070,
        1, 3.32017, 0.30158,
        1, 3.50789, 0.83070,
        1, 3.73508, 0.19298,
        1, 3.68122, 0.19298,
        3,
        0, 5.04105, 0.80702,
        1, 5.34543, 0.80702,
        1, 5.34543, 0.76140,
        1, 5.04105, 0.76140,
        3,
        0, 5.04105, 0.23860,
        1, 5.34543, 0.23860,
        1, 5.34543, 0.19298,
        1, 5.04105, 0.19298,
        3,
        0, 5.04105, 0.49334,
        1, 5.32789, 0.49334,
        1, 5.32789, 0.44772,
        1, 5.04105, 0.44772,
        3,
        0, 5.01561, 0.19298,
        1, 5.01561, 0.80702,
        1, 5.06421, 0.80702,
        1, 5.06421, 0.19298,
        3,
        0, 5.88367, 0.51421,
        1, 6.08718, 0.80702,
        1, 6.14736, 0.80702,
        1, 5.93788, 0.51421,
        3,
        0, 5.77964, 0.19298,
        1, 5.77964, 0.80702,
        1, 5.82824, 0.80702,
        1, 5.82824, 0.19298,
        3,
        0, 5.80508, 0.23631,
        1, 5.91999, 0.23631,
        2, 5.96684, 0.23631, 6.00272, 0.25175,
        2, 6.03859, 0.26719, 6.05903, 0.29701,
        2, 6.07946, 0.32684, 6.07946, 0.37123,
        2, 6.07946, 0.41527, 6.05920, 0.44544,
        2, 6.03894, 0.47562, 6.00289, 0.49106,
        2, 5.96684, 0.50650, 5.91999, 0.50650,
        1, 5.80508, 0.50650,
        1, 5.80508, 0.54948,
        1, 5.91999, 0.54948,
        2, 5.97964, 0.54948, 6.02639, 0.52851,
        2, 6.07315, 0.50754, 6.10061, 0.46745,
        2, 6.12807, 0.42737, 6.12807, 0.37123,
        2, 6.12807, 0.31421, 6.10061, 0.27456,
        2, 6.07315, 0.23491, 6.02639, 0.21395,
        2, 5.97964, 0.19298, 5.91999, 0.19298,
        1, 5.80508, 0.19298,
        3,
        0, 6.55964, 0.80702,
        1, 6.86403, 0.80702,
        1, 6.86403, 0.76140,
        1, 6.55964, 0.76140,
        3,
        0, 6.55964, 0.23860,
        1, 6.86403, 0.23860,
        1, 6.86403, 0.19298,
        1, 6.55964, 0.19298,
        3,
        0, 6.55964, 0.49334,
        1, 6.84648, 0.49334,
        1, 6.84648, 0.44772,
        1, 6.55964, 0.44772,
        3,
        0, 6.53420, 0.19298,
        1, 6.53420, 0.80702,
        1, 6.58280, 0.80702,
        1, 6.58280, 0.19298,
        3,
    ]

    static func path(_ c: [Double], in rect: CGRect) -> Path {
        let s = rect.height
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        var i = 0
        while i < c.count {
            switch c[i] {
            case 0: path.move(to: point(c[i + 1], c[i + 2])); i += 3
            case 1: path.addLine(to: point(c[i + 1], c[i + 2])); i += 3
            case 2: path.addQuadCurve(to: point(c[i + 3], c[i + 4]), control: point(c[i + 1], c[i + 2])); i += 5
            default: path.closeSubpath(); i += 1
            }
        }
        return path
    }

    static func place(_ unit: CGRect, in rect: CGRect) -> CGRect {
        let s = rect.height
        return CGRect(x: rect.minX + unit.minX * s, y: rect.minY + unit.minY * s, width: unit.width * s, height: unit.height * s)
    }
}

struct Wordmark: View {
    var breathing = false

    @Environment(\.colorScheme) private var scheme
    @State private var opened = Date()

    var body: some View {
        MotionTimeline(animated: breathing, fps: 12) { date in
            Canvas { ctx, size in
                let dark = scheme == .dark
                let box = CGRect(origin: .zero, size: size).insetBy(dx: 40, dy: 40)
                let ink = dark ? Color(.sRGB, red: 232 / 255, green: 237 / 255, blue: 240 / 255)
                               : Color(.sRGB, red: 17 / 255, green: 17 / 255, blue: 19 / 255)
                ctx.fill(WordmarkGlyphs.path(WordmarkGlyphs.ink, in: box), with: .color(ink))
                let glow = date.map { 0.75 + 0.25 * cos($0.timeIntervalSince(opened) * 2 * .pi / 9.6) } ?? 1
                drawH(in: &ctx, box: box, dark: dark, glow: glow)
            }
            .padding(-40)
        }
        .aspectRatio(WordmarkGlyphs.aspectRatio, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Elsewhere")
    }

    private func drawH(in ctx: inout GraphicsContext, box: CGRect, dark: Bool, glow: Double) {
        let left = WordmarkGlyphs.place(WordmarkGlyphs.leftStem, in: box)
        let right = WordmarkGlyphs.place(WordmarkGlyphs.rightStem, in: box)
        let bar = WordmarkGlyphs.place(WordmarkGlyphs.crossbar, in: box)
        let blue = Color(.sRGB, red: 0x31 / 255, green: 0x83 / 255, blue: 0xD8 / 255)
        let core = dark ? Color.white : blue
        let halos: [(radius: CGFloat, color: Color)] = dark
            ? [(12, Color(.sRGB, red: 132 / 255, green: 190 / 255, blue: 230 / 255).opacity(0.6)),
               (4, Color(.sRGB, red: 194 / 255, green: 222 / 255, blue: 242 / 255).opacity(0.9))]
            : [(10, blue.opacity(0.28)), (2.5, blue.opacity(0.3))]
        func paint(_ layer: inout GraphicsContext, _ color: Color) {
            Self.fillBeam(&layer, rect: left, color: color)
            Self.fillBeam(&layer, rect: right, color: color)
            layer.fill(Path(bar), with: .color(color))
        }
        for halo in halos {
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: halo.radius))
                layer.opacity = glow
                paint(&layer, halo.color)
            }
        }
        paint(&ctx, core)
    }

    private static func fillBeam(_ ctx: inout GraphicsContext, rect: CGRect, color: Color) {
        let end = rect.height * 0.18
        let top = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: end)
        let bottom = CGRect(x: rect.minX, y: rect.maxY - end, width: rect.width, height: end)
        let middle = CGRect(x: rect.minX, y: top.maxY, width: rect.width, height: bottom.minY - top.maxY)
        ctx.fill(Path(middle), with: .color(color))
        ctx.fill(Path(top), with: .linearGradient(Gradient(colors: [color.opacity(0), color]),
                                                  startPoint: CGPoint(x: top.midX, y: top.minY),
                                                  endPoint: CGPoint(x: top.midX, y: top.maxY)))
        ctx.fill(Path(bottom), with: .linearGradient(Gradient(colors: [color, color.opacity(0)]),
                                                     startPoint: CGPoint(x: bottom.midX, y: bottom.minY),
                                                     endPoint: CGPoint(x: bottom.midX, y: bottom.maxY)))
    }
}
