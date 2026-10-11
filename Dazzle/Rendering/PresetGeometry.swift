import CoreGraphics
import Foundation

/// Outlines for DrawingML's preset shapes.
///
/// Covers the shapes decks are actually built from; anything else is drawn
/// as its bounding rectangle, which keeps it in place and the right size.
enum PresetGeometry {
    /// Whether the preset is a line rather than an area, so is never filled.
    static func isOpen(_ name: String) -> Bool {
        name == "line" || name == "arc" || name.hasSuffix("Connector1") || name.hasSuffix("Connector2")
            || name.hasSuffix("Connector3") || name.hasSuffix("Connector4") || name.hasSuffix("Connector5")
            || name == "leftBracket" || name == "rightBracket" || name == "leftBrace" || name == "rightBrace"
            || name == "bracketPair" || name == "bracePair"
    }

    static func path(_ name: String, adjustments: [String: Int], in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let w = rect.width
        let h = rect.height
        let x = rect.minX
        let y = rect.minY
        let shortSide = min(w, h)
        /// An adjust value as a fraction, from the file or the preset's default.
        func adjust(_ key: String, _ fallback: Int) -> CGFloat {
            CGFloat(adjustments[key] ?? fallback) / 100_000
        }
        func point(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: x + px, y: y + py) }
        func polygon(_ points: [CGPoint]) {
            path.addLines(between: points)
            path.closeSubpath()
        }

        switch name {
        case "ellipse", "flowChartConnector":
            path.addEllipse(in: rect)
        case "roundRect", "flowChartAlternateProcess":
            let radius = min(shortSide * adjust("adj", 16_667), shortSide / 2)
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        case "flowChartTerminator":
            path.addRoundedRect(in: rect, cornerWidth: min(w / 2, h / 2), cornerHeight: h / 2)
        case "round2SameRect":
            let radius = min(shortSide * adjust("adj1", 16_667), shortSide / 2)
            path.move(to: point(0, h))
            path.addLine(to: point(0, radius))
            path.addArc(tangent1End: point(0, 0), tangent2End: point(radius, 0), radius: radius)
            path.addLine(to: point(w - radius, 0))
            path.addArc(tangent1End: point(w, 0), tangent2End: point(w, radius), radius: radius)
            path.addLine(to: point(w, h))
            path.closeSubpath()
        case "snip1Rect":
            let snip = shortSide * adjust("adj", 16_667)
            polygon([point(0, 0), point(w - snip, 0), point(w, snip), point(w, h), point(0, h)])
        case "triangle", "flowChartExtract":
            polygon([point(w * adjust("adj", 50_000), 0), point(w, h), point(0, h)])
        case "rtTriangle":
            polygon([point(0, 0), point(w, h), point(0, h)])
        case "diamond", "flowChartDecision":
            polygon([point(w / 2, 0), point(w, h / 2), point(w / 2, h), point(0, h / 2)])
        case "parallelogram", "flowChartInputOutput":
            let offset = min(shortSide * adjust("adj", 25_000), w)
            polygon([point(offset, 0), point(w, 0), point(w - offset, h), point(0, h)])
        case "trapezoid":
            let offset = min(shortSide * adjust("adj", 25_000), w / 2)
            polygon([point(offset, 0), point(w - offset, 0), point(w, h), point(0, h)])
        case "pentagon", "homePlate":
            if name == "homePlate" {
                let tip = min(shortSide * adjust("adj", 50_000), w)
                polygon([point(0, 0), point(w - tip, 0), point(w, h / 2), point(w - tip, h), point(0, h)])
            } else {
                polygon(regularPolygon(sides: 5, in: rect))
            }
        case "chevron":
            let tip = min(shortSide * adjust("adj", 50_000), w)
            polygon([point(0, 0), point(w - tip, 0), point(w, h / 2), point(w - tip, h), point(0, h), point(tip, h / 2)])
        case "hexagon":
            let inset = min(shortSide * adjust("adj", 25_000), w / 2)
            polygon([point(inset, 0), point(w - inset, 0), point(w, h / 2), point(w - inset, h), point(inset, h), point(0, h / 2)])
        case "octagon":
            let inset = shortSide * adjust("adj", 29_289)
            polygon([
                point(inset, 0), point(w - inset, 0), point(w, inset), point(w, h - inset),
                point(w - inset, h), point(inset, h), point(0, h - inset), point(0, inset),
            ])
        case "star4", "star5", "star6", "star7", "star8", "star10", "star12", "star16", "star24", "star32":
            let points = Int(name.dropFirst(4)) ?? 5
            let defaults = [4: 12_500, 5: 19_098, 6: 28_868, 7: 34_601, 8: 37_500, 10: 42_533, 12: 37_500]
            let inner = adjust("adj", defaults[points] ?? 37_500) * 2
            polygon(star(points: points, innerRatio: inner, in: rect))
        case "plus", "mathPlus":
            let arm = shortSide * adjust("adj", 25_000)
            polygon([
                point(arm, 0), point(w - arm, 0), point(w - arm, arm), point(w, arm), point(w, h - arm),
                point(w - arm, h - arm), point(w - arm, h), point(arm, h), point(arm, h - arm), point(0, h - arm),
                point(0, arm), point(arm, arm),
            ])
        case "rightArrow", "leftArrow", "upArrow", "downArrow", "leftRightArrow":
            arrow(name, path: path, rect: rect, shaft: adjust("adj1", 50_000), head: adjust("adj2", 50_000))
        case "donut":
            path.addEllipse(in: rect)
            let thickness = shortSide * adjust("adj", 25_000)
            path.addEllipse(in: rect.insetBy(dx: thickness, dy: thickness))
        case "heart":
            path.move(to: point(w / 2, h / 4))
            path.addCurve(to: point(w / 2, h), control1: point(w * 1.1, -h / 3), control2: point(w * 1.25, h / 2))
            path.addCurve(to: point(w / 2, h / 4), control1: point(-w * 0.25, h / 2), control2: point(-w * 0.1, -h / 3))
            path.closeSubpath()
        case "wedgeRectCallout", "wedgeRoundRectCallout", "wedgeEllipseCallout":
            callout(name, path: path, rect: rect,
                    offset: CGPoint(x: adjust("adj1", -20_833), y: adjust("adj2", 62_500)),
                    corner: adjust("adj3", 16_667))
        case "can", "flowChartMagneticDisk":
            let lid = h * adjust("adj", 25_000) / 2
            path.move(to: point(0, lid / 2))
            path.addLine(to: point(0, h - lid / 2))
            path.addCurve(to: point(w, h - lid / 2), control1: point(0, h + lid / 6), control2: point(w, h + lid / 6))
            path.addLine(to: point(w, lid / 2))
            path.addEllipse(in: CGRect(x: x, y: y, width: w, height: lid))
        case "line", "straightConnector1":
            path.move(to: point(0, 0))
            path.addLine(to: point(w, h))
        case "bentConnector2":
            path.addLines(between: [point(0, 0), point(w, 0), point(w, h)])
        case "bentConnector3", "bentConnector4", "bentConnector5":
            let bend = w * adjust("adj1", 50_000)
            path.addLines(between: [point(0, 0), point(bend, 0), point(bend, h), point(w, h)])
        case "curvedConnector2", "curvedConnector3", "curvedConnector4", "curvedConnector5":
            path.move(to: point(0, 0))
            path.addCurve(to: point(w, h), control1: point(w / 2, 0), control2: point(w / 2, h))
        case "arc":
            let start = CGFloat(adjustments["adj1"] ?? 16_200_000) / 60_000 * .pi / 180
            let end = CGFloat(adjustments["adj2"] ?? 0) / 60_000 * .pi / 180
            let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY).scaledBy(x: w / 2, y: h / 2)
            path.addArc(center: .zero, radius: 1, startAngle: start, endAngle: end, clockwise: false, transform: transform)
        case "leftBracket", "rightBracket":
            let isLeft = name == "leftBracket"
            let edge = isLeft ? w : 0
            let spine = isLeft ? 0 : w
            path.move(to: point(edge, 0))
            path.addQuadCurve(to: point(spine, h * 0.1), control: point(spine, 0))
            path.addLine(to: point(spine, h * 0.9))
            path.addQuadCurve(to: point(edge, h), control: point(spine, h))
        case "cloud", "cloudCallout", "ellipseRibbon", "wave", "doubleWave":
            path.addEllipse(in: rect)
        default:
            path.addRect(rect)
        }
        return path
    }

    /// The rectangle text is laid out in, which for most presets is smaller
    /// than the shape so text stays inside its outline.
    static func textRect(_ name: String, adjustments: [String: Int], in rect: CGRect) -> CGRect {
        let w = rect.width
        let h = rect.height
        let shortSide = min(w, h)
        func adjust(_ key: String, _ fallback: Int) -> CGFloat {
            CGFloat(adjustments[key] ?? fallback) / 100_000
        }
        func inset(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) -> CGRect {
            CGRect(x: rect.minX + left, y: rect.minY + top, width: max(w - left - right, 1), height: max(h - top - bottom, 1))
        }
        switch name {
        case "ellipse", "flowChartConnector", "donut", "wedgeEllipseCallout", "cloud", "cloudCallout":
            // The square inscribed in the circle: 1 − 1/√2, halved.
            return inset(left: w * 0.146_4, top: h * 0.146_4, right: w * 0.146_4, bottom: h * 0.146_4)
        case "roundRect", "flowChartAlternateProcess":
            let corner = min(shortSide * adjust("adj", 16_667), shortSide / 2) * 0.292_9
            return inset(left: corner, top: corner, right: corner, bottom: corner)
        case "wedgeRoundRectCallout":
            let corner = min(max(shortSide * adjust("adj3", 16_667), 0), shortSide / 2) * 0.292_9
            return inset(left: corner, top: corner, right: corner, bottom: corner)
        case "diamond", "flowChartDecision":
            return inset(left: w / 4, top: h / 4, right: w / 4, bottom: h / 4)
        case "triangle", "flowChartExtract":
            let apex = w * adjust("adj", 50_000)
            return CGRect(x: rect.minX + apex / 2, y: rect.minY + h / 2, width: w / 2, height: h / 2)
        case "rtTriangle":
            return inset(left: w / 12, top: h * 7 / 12, right: w * 7 / 12, bottom: h / 12)
        case "star4", "star5", "star6", "star7", "star8":
            return inset(left: w * 0.31, top: h * 0.38, right: w * 0.31, bottom: h * 0.24)
        case "hexagon", "octagon":
            let side = shortSide * adjust("adj", name == "hexagon" ? 25_000 : 29_289) * 0.5
            return inset(left: side, top: side, right: side, bottom: side)
        case "parallelogram", "trapezoid", "flowChartInputOutput":
            let slant = min(shortSide * adjust("adj", 25_000), w / 2) * 0.5
            return inset(left: slant, top: 0, right: slant, bottom: 0)
        case "rightArrow", "leftArrow", "leftRightArrow":
            let shaft = h * (1 - adjust("adj1", 50_000)) / 2
            return inset(left: name == "rightArrow" ? 0 : shortSide * 0.25, top: shaft,
                         right: name == "leftArrow" ? 0 : shortSide * 0.25, bottom: shaft)
        case "upArrow", "downArrow":
            let shaft = w * (1 - adjust("adj1", 50_000)) / 2
            return inset(left: shaft, top: 0, right: shaft, bottom: 0)
        case "chevron", "homePlate":
            let tip = min(shortSide * adjust("adj", 50_000), w) * 0.5
            return inset(left: name == "chevron" ? tip : 0, top: 0, right: tip, bottom: 0)
        default:
            return rect
        }
    }

    /// The tail replaces part of the body's perimeter. Separate overlapping
    /// subpaths would cut a hole with even-odd filling and stroke across the text.
    private static func callout(_ name: String, path: CGMutablePath, rect: CGRect, offset: CGPoint, corner: CGFloat) {
        let w = rect.width
        let h = rect.height
        guard w > 0, h > 0 else { return }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x, y: rect.minY + y)
        }
        let tip = point(w * (0.5 + offset.x), h * (0.5 + offset.y))
        if name == "wedgeEllipseCallout" {
            guard hypot(offset.x * 2, offset.y * 2) > 1 else {
                path.addEllipse(in: rect)
                return
            }
            let angle = atan2(offset.y, offset.x)
            let gap = CGFloat.pi * 11 / 180
            let start = angle + gap
            let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .scaledBy(x: w / 2, y: h / 2)
            path.move(to: tip)
            path.addLine(to: point(w / 2 * (1 + cos(start)), h / 2 * (1 + sin(start))))
            path.addArc(center: .zero, radius: 1, startAngle: start,
                        endAngle: angle - gap + 2 * .pi, clockwise: false, transform: transform)
            path.closeSubpath()
            return
        }

        let radius = name == "wedgeRoundRectCallout" ? min(max(min(w, h) * corner, 0), min(w, h) / 2) : 0
        // DrawingML attaches to the dominant axis in normalized shape space.
        let vertical = abs(offset.y) > abs(offset.x)
        let side = vertical ? (offset.y > 0 ? 2 : 0) : (offset.x > 0 ? 1 : 3)
        let hasTail = max(abs(offset.x), abs(offset.y)) > 0.5
        let x1 = min(w - radius, max(radius, w * (offset.x > 0 ? 7 : 2) / 12))
        let x2 = min(w - radius, max(radius, w * (offset.x > 0 ? 10 : 5) / 12))
        let y1 = min(h - radius, max(radius, h * (offset.y > 0 ? 7 : 2) / 12))
        let y2 = min(h - radius, max(radius, h * (offset.y > 0 ? 10 : 5) / 12))
        func tail(_ edge: Int, from: CGPoint, to: CGPoint) {
            guard hasTail, side == edge else { return }
            path.addLine(to: from)
            path.addLine(to: tip)
            path.addLine(to: to)
        }
        func turn(_ x: CGFloat, _ y: CGFloat, _ endX: CGFloat, _ endY: CGFloat) {
            if radius > 0 {
                path.addArc(tangent1End: point(x, y), tangent2End: point(endX, endY), radius: radius)
            } else {
                path.addLine(to: point(x, y))
            }
        }
        path.move(to: point(radius, 0))
        tail(0, from: point(x1, 0), to: point(x2, 0))
        path.addLine(to: point(w - radius, 0))
        turn(w, 0, w, radius)
        tail(1, from: point(w, y1), to: point(w, y2))
        path.addLine(to: point(w, h - radius))
        turn(w, h, w - radius, h)
        tail(2, from: point(x2, h), to: point(x1, h))
        path.addLine(to: point(radius, h))
        turn(0, h, 0, h - radius)
        tail(3, from: point(0, y2), to: point(0, y1))
        path.addLine(to: point(0, radius))
        turn(0, 0, radius, 0)
        path.closeSubpath()
    }

    private static func regularPolygon(sides: Int, in rect: CGRect) -> [CGPoint] {
        (0..<sides).map { index in
            let angle = -CGFloat.pi / 2 + CGFloat(index) * 2 * .pi / CGFloat(sides)
            return CGPoint(x: rect.midX + rect.width / 2 * cos(angle), y: rect.midY + rect.height / 2 * sin(angle))
        }
    }

    private static func star(points: Int, innerRatio: CGFloat, in rect: CGRect) -> [CGPoint] {
        (0..<(points * 2)).map { index in
            let angle = -CGFloat.pi / 2 + CGFloat(index) * .pi / CGFloat(points)
            let scale = index.isMultiple(of: 2) ? 1 : innerRatio
            return CGPoint(
                x: rect.midX + rect.width / 2 * scale * cos(angle),
                y: rect.midY + rect.height / 2 * scale * sin(angle)
            )
        }
    }

    /// Block arrows, drawn pointing right and turned to face their way.
    private static func arrow(_ name: String, path: CGMutablePath, rect: CGRect, shaft: CGFloat, head: CGFloat) {
        let isVertical = name == "upArrow" || name == "downArrow"
        // Lay the arrow out along its own length.
        let length = isVertical ? rect.height : rect.width
        let breadth = isVertical ? rect.width : rect.height
        let headLength = min(min(length, breadth) * head, length)
        let shaftInset = breadth * (1 - shaft) / 2
        var points: [CGPoint]
        if name == "leftRightArrow" {
            points = [
                CGPoint(x: 0, y: breadth / 2), CGPoint(x: headLength, y: 0), CGPoint(x: headLength, y: shaftInset),
                CGPoint(x: length - headLength, y: shaftInset), CGPoint(x: length - headLength, y: 0),
                CGPoint(x: length, y: breadth / 2), CGPoint(x: length - headLength, y: breadth),
                CGPoint(x: length - headLength, y: breadth - shaftInset), CGPoint(x: headLength, y: breadth - shaftInset),
                CGPoint(x: headLength, y: breadth),
            ]
        } else {
            points = [
                CGPoint(x: 0, y: shaftInset), CGPoint(x: length - headLength, y: shaftInset),
                CGPoint(x: length - headLength, y: 0), CGPoint(x: length, y: breadth / 2),
                CGPoint(x: length - headLength, y: breadth), CGPoint(x: length - headLength, y: breadth - shaftInset),
                CGPoint(x: 0, y: breadth - shaftInset),
            ]
        }
        points = points.map { local in
            switch name {
            case "leftArrow": CGPoint(x: rect.maxX - local.x, y: rect.minY + local.y)
            case "downArrow": CGPoint(x: rect.minX + local.y, y: rect.minY + local.x)
            case "upArrow": CGPoint(x: rect.minX + local.y, y: rect.maxY - local.x)
            default: CGPoint(x: rect.minX + local.x, y: rect.minY + local.y)
            }
        }
        path.addLines(between: points)
        path.closeSubpath()
    }

    /// A freeform outline, scaled from its own coordinate space to `rect`.
    static func path(_ paths: [ShapeGeometry.CustomPath], in rect: CGRect) -> (fill: CGPath, stroke: CGPath) {
        let fill = CGMutablePath()
        let stroke = CGMutablePath()
        for custom in paths {
            let scaleX = custom.width > 0 ? rect.width / custom.width : 1
            let scaleY = custom.height > 0 ? rect.height / custom.height : 1
            let path = CGMutablePath()
            var current = CGPoint.zero
            func map(_ px: Double, _ py: Double) -> CGPoint {
                CGPoint(x: rect.minX + px * scaleX, y: rect.minY + py * scaleY)
            }
            for command in custom.commands {
                switch command {
                case .move(let px, let py):
                    current = map(px, py)
                    path.move(to: current)
                case .line(let px, let py):
                    current = map(px, py)
                    path.addLine(to: current)
                case .cubic(let x1, let y1, let x2, let y2, let x3, let y3):
                    current = map(x3, y3)
                    path.addCurve(to: current, control1: map(x1, y1), control2: map(x2, y2))
                case .quadratic(let x1, let y1, let x2, let y2):
                    current = map(x2, y2)
                    path.addQuadCurve(to: current, control: map(x1, y1))
                case .arc(let widthRadius, let heightRadius, let start, let sweep):
                    let rx = widthRadius * scaleX
                    let ry = heightRadius * scaleY
                    let startRadians = start * .pi / 180
                    let endRadians = (start + sweep) * .pi / 180
                    let center = CGPoint(x: current.x - rx * cos(startRadians), y: current.y - ry * sin(startRadians))
                    let transform = CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: max(rx, 0.001), y: max(ry, 0.001))
                    if path.isEmpty { path.move(to: current) }
                    path.addArc(
                        center: .zero, radius: 1, startAngle: startRadians, endAngle: endRadians,
                        clockwise: sweep < 0, transform: transform
                    )
                    current = CGPoint(x: center.x + rx * cos(endRadians), y: center.y + ry * sin(endRadians))
                case .close:
                    path.closeSubpath()
                }
            }
            if custom.isFilled { fill.addPath(path) }
            if custom.isStroked { stroke.addPath(path) }
        }
        return (fill, stroke)
    }
}
