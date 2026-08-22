import SwiftUI
import UltraDesign

/// A single series over time, drawn thin and unlabelled.
///
/// No axes, no grid, no per-point numbers: the current value is shown once, as text, beside
/// it. A sparkline's job is the SHAPE — whether the thing is climbing, spiking, or flat —
/// and any furniture added to it competes with the shape for the same few pixels.
struct Sparkline: View {
    let samples: Samples
    /// Upper bound of the y-scale. Fixed rather than auto-fitted, so a flat-but-busy series
    /// does not look identical to a flat-and-idle one.
    var ceiling: Double = 100

    var body: some View {
        GeometryReader { geometry in
            let values = samples.values
            let top = max(ceiling, samples.peak)
            Path { path in
                guard values.count > 1 else { return }
                let step = geometry.size.width / CGFloat(samples.capacity - 1)
                // Right-aligned: the newest sample sits at the trailing edge, so a
                // half-full ring still reads as "now" rather than drifting.
                let offset = CGFloat(samples.capacity - values.count) * step
                for (index, value) in values.enumerated() {
                    let x = offset + CGFloat(index) * step
                    let y = geometry.size.height * (1 - CGFloat(value / top))
                    let point = CGPoint(x: x, y: y)
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            .stroke(Token.Colour.accent,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .accessibilityLabel("Recent activity")
        .accessibilityValue("\(Int(samples.latest)) percent, peak \(Int(samples.peak)) percent")
    }
}
