import Testing
import SwiftUI
@testable import UltraDesign

/// The thinking star is traced from a design file; this holds the tracing to the shape
/// it is meant to be, so a retrace that drops a segment or loses the scale is caught.
@Suite("Thinking star")
struct ThinkingStarTests {

    @Test("it fills the square it is given, and no more")
    func fillsItsSquare() {
        let bounds = ThinkingStar().path(in: CGRect(x: 0, y: 0, width: 100, height: 100)).boundingRect
        #expect(bounds.minX >= -0.5 && bounds.maxX <= 100.5)
        #expect(bounds.minY >= -0.5 && bounds.maxY <= 100.5)
        #expect(bounds.width > 99, "the points reach the edges")
        #expect(bounds.height > 98)
    }

    @Test("it is centred in a frame that is not square")
    func centredInAWideFrame() {
        let bounds = ThinkingStar().path(in: CGRect(x: 0, y: 0, width: 300, height: 100)).boundingRect
        #expect(abs(bounds.midX - 150) < 1)
        #expect(abs(bounds.midY - 50) < 1)
        #expect(bounds.width <= 100.5, "scaled to the shorter side")
    }

    /// Four points: the shape is the same picture after a quarter turn, which is what lets
    /// the spin repeat without a seam.
    @Test("a quarter turn lands on the same shape")
    func fourFoldSymmetry() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let path = ThinkingStar().path(in: rect)
        let turned = path.applying(CGAffineTransform(translationX: 50, y: 50)
                                     .rotated(by: .pi / 2)
                                     .translatedBy(x: -50, y: -50))
        // Sample along the axes and diagonals: a point inside one is inside the other.
        for step in stride(from: 2.0, through: 98.0, by: 4.0) {
            for point in [CGPoint(x: step, y: 50), CGPoint(x: 50, y: step),
                          CGPoint(x: step, y: step), CGPoint(x: step, y: 100 - step)] {
                #expect(path.contains(point) == turned.contains(point),
                        "\(point) differs after a quarter turn")
            }
        }
    }
}
