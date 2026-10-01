import SwiftUI

/// The four-pointed star that turns while a model is working: the mark the chat shows in
/// its send slot until the answer is in.
///
/// Drawn, not a symbol. SF Symbols has sparkles, but none that are one star with soft
/// concave sides, and a symbol cannot be handed to a keyframe animator the way a shape
/// can. The outline is the design's own, traced once into unit coordinates here, and
/// scaled to the square that fits whatever frame it is given, so the same shape serves
/// a 16pt slot and a preview at ten times that.
///
/// Four points, so a quarter turn lands on the same picture: a spin that stops at 90°,
/// 180° or 270° has nothing to hide.
public struct ThinkingStar: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * side, y: origin.y + y * side)
        }
        var path = Path()
        path.move(to: p(0.5000, 0.0045))
        path.addCurve(to: p(0.5939, 0.0751), control1: p(0.5457, 0.0045), control2: p(0.5812, 0.0322))
        path.addLine(to: p(0.6484, 0.2694))
        path.addCurve(to: p(0.6651, 0.3157), control1: p(0.6552, 0.2936), control2: p(0.6586, 0.3058))
        path.addCurve(to: p(0.6892, 0.3396), control1: p(0.6713, 0.3253), control2: p(0.6795, 0.3335))
        path.addCurve(to: p(0.7357, 0.3558), control1: p(0.6992, 0.3459), control2: p(0.7114, 0.3492))
        path.addLine(to: p(0.9289, 0.4080))
        path.addCurve(to: p(1.0000, 0.4987), control1: p(0.9721, 0.4180), control2: p(1.0000, 0.4559))
        path.addCurve(to: p(0.9289, 0.5920), control1: p(1.0000, 0.5441), control2: p(0.9721, 0.5794))
        path.addLine(to: p(0.7346, 0.6464))
        path.addCurve(to: p(0.6888, 0.6628), control1: p(0.7106, 0.6531), control2: p(0.6987, 0.6565))
        path.addCurve(to: p(0.6651, 0.6864), control1: p(0.6793, 0.6689), control2: p(0.6712, 0.6769))
        path.addCurve(to: p(0.6485, 0.7322), control1: p(0.6587, 0.6963), control2: p(0.6553, 0.7083))
        path.addLine(to: p(0.5939, 0.9249))
        path.addCurve(to: p(0.5000, 0.9955), control1: p(0.5812, 0.9678), control2: p(0.5457, 0.9955))
        path.addCurve(to: p(0.4061, 0.9249), control1: p(0.4543, 0.9955), control2: p(0.4188, 0.9678))
        path.addLine(to: p(0.3516, 0.7306))
        path.addCurve(to: p(0.3349, 0.6843), control1: p(0.3448, 0.7064), control2: p(0.3414, 0.6942))
        path.addCurve(to: p(0.3108, 0.6604), control1: p(0.3287, 0.6747), control2: p(0.3205, 0.6665))
        path.addCurve(to: p(0.2643, 0.6442), control1: p(0.3008, 0.6541), control2: p(0.2886, 0.6508))
        path.addLine(to: p(0.0711, 0.5920))
        path.addCurve(to: p(0.0000, 0.4987), control1: p(0.0305, 0.5794), control2: p(0.0025, 0.5441))
        path.addCurve(to: p(0.0711, 0.4080), control1: p(0.0000, 0.4559), control2: p(0.0279, 0.4206))
        path.addLine(to: p(0.2670, 0.3537))
        path.addCurve(to: p(0.3134, 0.3372), control1: p(0.2913, 0.3470), control2: p(0.3034, 0.3436))
        path.addCurve(to: p(0.3373, 0.3132), control1: p(0.3230, 0.3310), control2: p(0.3312, 0.3228))
        path.addCurve(to: p(0.3537, 0.2667), control1: p(0.3437, 0.3032), control2: p(0.3470, 0.2910))
        path.addLine(to: p(0.4061, 0.0751))
        path.addCurve(to: p(0.5000, 0.0045), control1: p(0.4188, 0.0322), control2: p(0.4543, 0.0045))
        path.closeSubpath()
        return path
    }
}

#Preview("Thinking star", traits: .fixedLayout(width: 160, height: 160)) {
    ThinkingStar()
        .fill(Token.Colour.label)
        .padding(20)
}
