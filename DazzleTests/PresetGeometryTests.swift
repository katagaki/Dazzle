import CoreGraphics
import Testing
@testable import Dazzle

@Suite("Speech bubble geometry")
struct PresetGeometryTests {
    private let presets = ["wedgeRectCallout", "wedgeRoundRectCallout", "wedgeEllipseCallout"]
    private let rect = CGRect(x: 10, y: 20, width: 208, height: 150)

    @Test("Tails preserve the body fill and never stroke through its text")
    func bodyAndTail() {
        let positions = [
            [-20_833, 62_500], [50_000, 75_000], [80_000, 10_000],
            [-80_000, 10_000], [10_000, -80_000], [0, 0],
        ]
        for preset in presets {
            for position in positions {
                let path = PresetGeometry.path(preset, adjustments: ["adj1": position[0], "adj2": position[1]], in: rect)
                let stroke = path.copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
                // All samples lie inside the inscribed text area, including
                // the region removed by the old overlapping triangle.
                for x in stride(from: 0.25, through: 0.75, by: 0.05) {
                    for y in stride(from: 0.25, through: 0.75, by: 0.05) {
                        let point = CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
                        #expect(path.contains(point, using: .evenOdd), "\(preset), \(position), \(point)")
                        #expect(!stroke.contains(point), "\(preset), \(position), \(point)")
                    }
                }
                if position != [0, 0] {
                    let tip = CGPoint(x: rect.midX + rect.width * CGFloat(position[0]) / 100_000,
                                      y: rect.midY + rect.height * CGFloat(position[1]) / 100_000)
                    let attachment: CGPoint
                    if preset == "wedgeEllipseCallout" {
                        let angle = atan2(CGFloat(position[1]), CGFloat(position[0]))
                        attachment = CGPoint(x: rect.midX + rect.width / 2 * cos(angle),
                                             y: rect.midY + rect.height / 2 * sin(angle))
                    } else if abs(position[1]) > abs(position[0]) {
                        attachment = CGPoint(x: rect.minX + rect.width * (position[0] > 0 ? 17 : 7) / 24,
                                             y: position[1] > 0 ? rect.maxY : rect.minY)
                    } else {
                        attachment = CGPoint(x: position[0] > 0 ? rect.maxX : rect.minX,
                                             y: rect.minY + rect.height * (position[1] > 0 ? 17 : 7) / 24)
                    }
                    let nearTip = CGPoint(x: tip.x * 0.99 + attachment.x * 0.01,
                                          y: tip.y * 0.99 + attachment.y * 0.01)
                    #expect(path.contains(nearTip, using: .evenOdd), "\(preset), \(position)")
                }
            }
        }
    }

    @Test("Rounded bubbles honor the corner adjustment")
    func cornerAdjustment() {
        let square = PresetGeometry.path("wedgeRoundRectCallout", adjustments: ["adj3": 0], in: rect)
        let rounded = PresetGeometry.path("wedgeRoundRectCallout", adjustments: ["adj3": 30_000], in: rect)
        let cornerPoint = CGPoint(x: rect.minX + 1, y: rect.minY + 1)
        #expect(square.contains(cornerPoint, using: .evenOdd))
        #expect(!rounded.contains(cornerPoint, using: .evenOdd))
        let text = PresetGeometry.textRect("wedgeRoundRectCallout", adjustments: ["adj3": 30_000], in: rect)
        #expect(text.minX > rect.minX)
        #expect(text.maxY < rect.maxY)
    }
}
