import CoreGraphics
import CoreText
import Foundation

/// Draws a chart from its data, in the look PowerPoint gives a new chart:
/// theme accent colours, light gridlines, a legend, and the title above.
struct ChartRenderer {
    let chart: Chart
    let style: SlideStyleContext

    private var fontSize: CGFloat { CGFloat(chart.fontSize ?? 1_200) / 100 }
    private var textColor: RGBAColor { style.color(.scheme("tx1")).applying(.init(name: "lumMod", value: 65_000)).applying(.init(name: "lumOff", value: 35_000)) }
    private var gridColor: RGBAColor { style.color(.scheme("tx1")).applying(.init(name: "lumMod", value: 15_000)).applying(.init(name: "lumOff", value: 85_000)) }

    /// Draws the chart filling `frame`, in a context whose y axis points down.
    func draw(in frame: CGRect, context: CGContext) {
        guard frame.width > 20, frame.height > 20 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: frame)
        let padding = min(frame.width, frame.height) * 0.04 + 4
        var area = frame.insetBy(dx: padding, dy: padding)

        if let title = chart.title, !title.isEmpty {
            let size = fontSize * 1.55
            let height = drawText(title, in: CGRect(x: area.minX, y: area.minY, width: area.width, height: size * 1.4),
                                  size: size, alignment: .center, context: context, measureOnly: false)
            area.origin.y += height + padding / 2
            area.size.height -= height + padding / 2
        }
        if chart.hasLegend { area = drawLegend(in: area, padding: padding, context: context) }
        guard area.width > 10, area.height > 10 else { return }

        if chart.kind.colorsByPoint {
            drawPie(in: area, context: context)
        } else if chart.kind == .scatter {
            drawScatter(in: area, context: context)
        } else {
            drawCategoryPlots(in: area, context: context)
        }
    }

    // MARK: - Colours

    /// The colour of the `index`th series or slice: the theme's six accents,
    /// then the same again darker, then lighter.
    func color(at index: Int) -> RGBAColor {
        var color = DrawingColor.scheme("accent\(index % 6 + 1)")
        switch (index / 6) % 3 {
        case 1: color.transforms = [.init(name: "lumMod", value: 60_000)]
        case 2: color.transforms = [.init(name: "lumMod", value: 80_000), .init(name: "lumOff", value: 20_000)]
        default: break
        }
        return style.color(color)
    }

    private func seriesColor(_ series: Chart.Series, index: Int) -> RGBAColor {
        series.color.map { style.color($0) } ?? color(at: index)
    }

    // MARK: - Legend

    private func drawLegend(in area: CGRect, padding: CGFloat, context: CGContext) -> CGRect {
        let entries: [(String, RGBAColor)] = chart.kind.colorsByPoint
            ? chart.categories.enumerated().map { index, name in
                (name, chart.plots.first?.series.first?.pointColors[index].map { style.color($0) } ?? color(at: index))
            }
            : chart.allSeries.enumerated().map { ($1.name, seriesColor($1, index: $0)) }
        guard !entries.isEmpty else { return area }
        let swatch = fontSize * 0.7
        let lineHeight = fontSize * 1.5
        let widths = entries.map { measure($0.0, size: fontSize).width + swatch + fontSize * 0.5 }
        var plot = area
        switch chart.legendPosition {
        case "b", "t":
            let total = widths.reduce(0, +) + CGFloat(entries.count - 1) * fontSize
            var x = area.midX - min(total, area.width) / 2
            let y = chart.legendPosition == "b" ? area.maxY - lineHeight : area.minY
            for (index, entry) in entries.enumerated() {
                drawLegendEntry(entry, at: CGPoint(x: x, y: y + (lineHeight - swatch) / 2), swatch: swatch, context: context)
                x += widths[index] + fontSize
            }
            plot.size.height -= lineHeight + padding / 2
            if chart.legendPosition == "t" { plot.origin.y += lineHeight + padding / 2 }
        default:
            let width = min((widths.max() ?? 0) + padding, area.width * 0.4)
            let total = CGFloat(entries.count) * lineHeight
            var y = area.midY - total / 2
            let x = chart.legendPosition == "l" ? area.minX : area.maxX - width + padding / 2
            for entry in entries {
                drawLegendEntry(entry, at: CGPoint(x: x, y: y + (lineHeight - swatch) / 2), swatch: swatch, context: context)
                y += lineHeight
            }
            plot.size.width -= width
            if chart.legendPosition == "l" { plot.origin.x += width }
        }
        return plot
    }

    private func drawLegendEntry(_ entry: (String, RGBAColor), at point: CGPoint, swatch: CGFloat, context: CGContext) {
        context.setFillColor(entry.1.cgColor)
        context.fill(CGRect(x: point.x, y: point.y, width: swatch, height: swatch))
        drawText(entry.0, in: CGRect(x: point.x + swatch + fontSize * 0.35, y: point.y + swatch / 2 - fontSize * 0.7,
                                    width: 1_000, height: fontSize * 1.4),
                 size: fontSize, alignment: .left, context: context, measureOnly: false)
    }

    // MARK: - Columns, bars, lines and areas

    /// Where the value axis runs, and its steps.
    struct Scale: Equatable {
        var minimum: Double
        var maximum: Double
        var step: Double

        /// A range from `low` to `high` rounded out to steps of 1, 2 or 5
        /// times a power of ten, about five of them.
        static func nice(low: Double, high: Double, fixedMinimum: Double? = nil, fixedMaximum: Double? = nil) -> Scale {
            var low = min(low, 0)
            var high = max(high, 0)
            if let fixedMinimum { low = fixedMinimum }
            if let fixedMaximum { high = fixedMaximum }
            if high <= low { high = low + 1 }
            let rough = (high - low) / 5
            let magnitude = pow(10, floor(log10(rough)))
            let step = [1.0, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= rough } ?? rough
            return Scale(
                minimum: fixedMinimum ?? floor(low / step) * step,
                maximum: fixedMaximum ?? ceil(high / step) * step, step: step
            )
        }

        var ticks: [Double] {
            guard step > 0, maximum > minimum else { return [minimum] }
            return Array(stride(from: minimum, through: maximum + step / 1_000, by: step))
        }
    }

    private func valueScale() -> Scale {
        var low = 0.0
        var high = 0.0
        for plot in chart.plots {
            let count = chart.categories.count
            if plot.grouping == .percentStacked {
                high = max(high, 1)
                continue
            }
            if plot.grouping == .stacked && plot.kind != .line {
                for index in 0..<count {
                    let values = plot.series.compactMap { $0.values.indices.contains(index) ? $0.values[index] : nil }
                    high = max(high, values.filter { $0 > 0 }.reduce(0, +))
                    low = min(low, values.filter { $0 < 0 }.reduce(0, +))
                }
            } else {
                let values = plot.series.flatMap { $0.values.compactMap(\.self) }
                high = max(high, values.max() ?? 0)
                low = min(low, values.min() ?? 0)
            }
        }
        return .nice(low: low, high: high, fixedMinimum: chart.minimum, fixedMaximum: chart.maximum)
    }

    private func drawCategoryPlots(in area: CGRect, context: CGContext) {
        let horizontal = chart.kind == .bar
        let scale = valueScale()
        let isPercent = chart.plots.first?.grouping == .percentStacked
        let labels = scale.ticks.map { format($0, percent: isPercent) }
        let labelWidth = (labels.map { measure($0, size: fontSize).width }.max() ?? 0) + fontSize * 0.5
        let categoryHeight = fontSize * 1.6
        var plot = area
        if horizontal {
            let widest = (chart.categories.map { measure($0, size: fontSize).width }.max() ?? 0) + fontSize * 0.6
            plot.origin.x += min(widest, area.width * 0.3)
            plot.size.width -= min(widest, area.width * 0.3)
            plot.size.height -= categoryHeight
        } else {
            plot.origin.x += labelWidth
            plot.size.width -= labelWidth
            plot.size.height -= categoryHeight
        }
        guard plot.width > 4, plot.height > 4 else { return }

        // A value's position along the value axis.
        func position(_ value: Double) -> CGFloat {
            let fraction = (value - scale.minimum) / (scale.maximum - scale.minimum)
            return horizontal ? plot.minX + plot.width * fraction : plot.maxY - plot.height * fraction
        }

        // Gridlines and value labels.
        context.setLineWidth(0.75)
        for (index, tick) in scale.ticks.enumerated() {
            let at = position(tick)
            if chart.showsGridlines {
                context.setStrokeColor(gridColor.cgColor)
                context.move(to: horizontal ? CGPoint(x: at, y: plot.minY) : CGPoint(x: plot.minX, y: at))
                context.addLine(to: horizontal ? CGPoint(x: at, y: plot.maxY) : CGPoint(x: plot.maxX, y: at))
                context.strokePath()
            }
            if horizontal {
                drawText(labels[index], in: CGRect(x: at - 40, y: plot.maxY + fontSize * 0.2, width: 80, height: fontSize * 1.4),
                         size: fontSize, alignment: .center, context: context, measureOnly: false)
            } else {
                drawText(labels[index], in: CGRect(x: area.minX, y: at - fontSize * 0.7, width: labelWidth - fontSize * 0.4, height: fontSize * 1.4),
                         size: fontSize, alignment: .right, context: context, measureOnly: false)
            }
        }

        let count = max(chart.categories.count, 1)
        let band = (horizontal ? plot.height : plot.width) / CGFloat(count)
        // Category labels, skipping some where they would collide.
        let widest = chart.categories.map { measure($0, size: fontSize).width }.max() ?? 0
        let every = horizontal ? 1 : max(Int(ceil((widest + fontSize) / max(band, 1))), 1)
        for (index, name) in chart.categories.enumerated() where index % every == 0 {
            // Bars list their categories from the bottom up, as PowerPoint does.
            let center = horizontal ? plot.maxY - band * (CGFloat(index) + 0.5) : plot.minX + band * (CGFloat(index) + 0.5)
            if horizontal {
                drawText(name, in: CGRect(x: area.minX, y: center - fontSize * 0.7, width: plot.minX - area.minX - fontSize * 0.3, height: fontSize * 1.4),
                         size: fontSize, alignment: .right, context: context, measureOnly: false)
            } else {
                drawText(name, in: CGRect(x: center - band * CGFloat(every) / 2, y: plot.maxY + fontSize * 0.2, width: band * CGFloat(every), height: fontSize * 1.4),
                         size: fontSize, alignment: .center, context: context, measureOnly: false)
            }
        }

        var seriesIndex = 0
        for plotData in chart.plots {
            switch plotData.kind {
            case .column, .bar:
                drawBars(plotData, firstIndex: seriesIndex, band: band, plot: plot, horizontal: horizontal, position: position, context: context)
            case .line:
                drawLines(plotData, firstIndex: seriesIndex, band: band, plot: plot, area: false, position: position, context: context)
            case .area:
                drawLines(plotData, firstIndex: seriesIndex, band: band, plot: plot, area: true, position: position, context: context)
            default:
                break
            }
            seriesIndex += plotData.series.count
        }

        // The axis line along the categories, at zero.
        context.setStrokeColor(gridColor.applying(.init(name: "lumMod", value: 75_000)).cgColor)
        context.setLineWidth(1)
        let zero = position(max(min(0, scale.maximum), scale.minimum))
        context.move(to: horizontal ? CGPoint(x: zero, y: plot.minY) : CGPoint(x: plot.minX, y: zero))
        context.addLine(to: horizontal ? CGPoint(x: zero, y: plot.maxY) : CGPoint(x: plot.maxX, y: zero))
        context.strokePath()
    }

    /// The value a series shows at a category: itself, or for a stacked
    /// plot, where its segment runs from and to.
    private func stackedRange(_ plot: Chart.Plot, series: Int, category: Int) -> (from: Double, to: Double)? {
        func value(_ series: Chart.Series) -> Double? {
            series.values.indices.contains(category) ? series.values[category] : nil
        }
        guard let own = value(plot.series[series]) else { return nil }
        guard plot.grouping != .standard else { return (0, own) }
        let below = plot.series[..<series].compactMap(value).filter { ($0 >= 0) == (own >= 0) }.reduce(0, +)
        var range = (from: below, to: below + own)
        if plot.grouping == .percentStacked {
            let total = plot.series.compactMap(value).map(abs).reduce(0, +)
            if total > 0 { range = (range.from / total, range.to / total) }
        }
        return range
    }

    private func drawBars(
        _ plot: Chart.Plot, firstIndex: Int, band: CGFloat, plot rect: CGRect, horizontal: Bool,
        position: (Double) -> CGFloat, context: CGContext
    ) {
        let stacked = plot.grouping != .standard
        let slots = stacked ? 1 : max(plot.series.count, 1)
        // PowerPoint's default gap: one and a half bars' width between groups.
        let barWidth = band / (CGFloat(slots) + 1.5)
        for category in 0..<chart.categories.count {
            let start = horizontal
                ? rect.maxY - band * CGFloat(category + 1) + barWidth * 0.75
                : rect.minX + band * CGFloat(category) + barWidth * 0.75
            for (index, series) in plot.series.enumerated() {
                guard let range = stackedRange(plot, series: index, category: category) else { continue }
                // Within a category too, the first series is lowest.
                let slot = stacked ? 0 : (horizontal ? slots - 1 - index : index)
                let from = position(range.from)
                let to = position(range.to)
                let bar = horizontal
                    ? CGRect(x: min(from, to), y: start + barWidth * CGFloat(slot), width: abs(to - from), height: barWidth)
                    : CGRect(x: start + barWidth * CGFloat(slot), y: min(from, to), width: barWidth, height: abs(to - from))
                context.setFillColor((series.pointColors[category].map { style.color($0) } ?? seriesColor(series, index: firstIndex + index)).cgColor)
                context.fill(bar)
                if chart.showsValueLabels, let value = series.values[category] {
                    let label = format(value, percent: false)
                    let labelRect = horizontal
                        ? CGRect(x: bar.maxX + 2, y: bar.midY - fontSize * 0.6, width: 80, height: fontSize * 1.2)
                        : CGRect(x: bar.midX - 40, y: bar.minY - fontSize * 1.3, width: 80, height: fontSize * 1.2)
                    drawText(label, in: labelRect, size: fontSize * 0.85, alignment: horizontal ? .left : .center, context: context, measureOnly: false)
                }
            }
        }
    }

    private func drawLines(
        _ plot: Chart.Plot, firstIndex: Int, band: CGFloat, plot rect: CGRect, area: Bool,
        position: (Double) -> CGFloat, context: CGContext
    ) {
        for index in plot.series.indices {
            let series = plot.series[index]
            let color = seriesColor(series, index: firstIndex + index)
            var points: [(CGPoint, Double)] = []
            var baseline: [CGPoint] = []
            for category in 0..<chart.categories.count {
                guard let range = stackedRange(plot, series: index, category: category) else { continue }
                let x = rect.minX + band * (CGFloat(category) + 0.5)
                points.append((CGPoint(x: x, y: position(range.to)), series.values[category] ?? 0))
                baseline.append(CGPoint(x: x, y: position(range.from)))
            }
            guard !points.isEmpty else { continue }
            if area {
                context.move(to: points[0].0)
                for point in points.dropFirst() { context.addLine(to: point.0) }
                for point in baseline.reversed() { context.addLine(to: point) }
                context.closePath()
                context.setFillColor(color.cgColor)
                context.fillPath()
            } else {
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(max(fontSize * 0.19, 1.5))
                context.setLineJoin(.round)
                context.setLineCap(.round)
                context.move(to: points[0].0)
                for point in points.dropFirst() { context.addLine(to: point.0) }
                context.strokePath()
                context.setFillColor(color.cgColor)
                let marker = fontSize * 0.42
                for point in points {
                    context.fillEllipse(in: CGRect(x: point.0.x - marker / 2, y: point.0.y - marker / 2, width: marker, height: marker))
                }
            }
            if chart.showsValueLabels {
                for point in points {
                    drawText(format(point.1, percent: false), in: CGRect(x: point.0.x - 40, y: point.0.y - fontSize * 1.5, width: 80, height: fontSize * 1.2),
                             size: fontSize * 0.85, alignment: .center, context: context, measureOnly: false)
                }
            }
        }
    }

    // MARK: - Pies

    private func drawPie(in area: CGRect, context: CGContext) {
        guard let plot = chart.plots.first, let series = plot.series.first else { return }
        let values = series.values.map { max($0 ?? 0, 0) }
        let total = values.reduce(0, +)
        guard total > 0 else { return }
        let radius = min(area.width, area.height) / 2 * 0.92
        let hole = plot.kind == .doughnut ? radius * CGFloat(min(max(plot.holeSize, 10), 90)) / 100 : 0
        let center = CGPoint(x: area.midX, y: area.midY)
        var angle = -CGFloat.pi / 2
        for (index, value) in values.enumerated() where value > 0 {
            let sweep = CGFloat(value / total) * .pi * 2
            // A slice, or for a doughnut, a piece of the ring.
            let slice = CGMutablePath()
            if hole > 0 {
                slice.addArc(center: center, radius: radius, startAngle: angle, endAngle: angle + sweep, clockwise: false)
                slice.addArc(center: center, radius: hole, startAngle: angle + sweep, endAngle: angle, clockwise: true)
            } else {
                slice.move(to: center)
                slice.addArc(center: center, radius: radius, startAngle: angle, endAngle: angle + sweep, clockwise: false)
            }
            slice.closeSubpath()
            context.addPath(slice)
            context.setFillColor((series.pointColors[index].map { style.color($0) } ?? color(at: index)).cgColor)
            context.fillPath()
            // A thin line of the background between slices.
            context.addPath(slice)
            context.setStrokeColor(style.color(.scheme("bg1")).cgColor)
            context.setLineWidth(1)
            context.strokePath()
            if chart.showsValueLabels {
                let middle = angle + sweep / 2
                let distance = hole > 0 ? (radius + hole) / 2 : radius * 0.65
                let at = CGPoint(x: center.x + cos(middle) * distance, y: center.y + sin(middle) * distance)
                drawText(format(value, percent: false), in: CGRect(x: at.x - 40, y: at.y - fontSize * 0.6, width: 80, height: fontSize * 1.2),
                         size: fontSize * 0.9, alignment: .center, context: context, measureOnly: false, color: .white)
            }
            angle += sweep
        }
    }

    // MARK: - Scatter

    private func drawScatter(in area: CGRect, context: CGContext) {
        let series = chart.allSeries
        let xs = series.flatMap { $0.xValues.isEmpty ? $0.values.indices.map { Double($0 + 1) } : $0.xValues.compactMap(\.self) }
        let ys = series.flatMap { $0.values.compactMap(\.self) }
        let xScale = Scale.nice(low: xs.min() ?? 0, high: xs.max() ?? 1)
        let yScale = Scale.nice(low: ys.min() ?? 0, high: ys.max() ?? 1, fixedMinimum: chart.minimum, fixedMaximum: chart.maximum)
        let labelWidth = (yScale.ticks.map { measure(format($0, percent: false), size: fontSize).width }.max() ?? 0) + fontSize * 0.5
        var plot = area
        plot.origin.x += labelWidth
        plot.size.width -= labelWidth
        plot.size.height -= fontSize * 1.6
        guard plot.width > 4, plot.height > 4 else { return }
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(
                x: plot.minX + plot.width * (x - xScale.minimum) / (xScale.maximum - xScale.minimum),
                y: plot.maxY - plot.height * (y - yScale.minimum) / (yScale.maximum - yScale.minimum)
            )
        }
        context.setLineWidth(0.75)
        context.setStrokeColor(gridColor.cgColor)
        for tick in yScale.ticks {
            let at = point(xScale.minimum, tick).y
            if chart.showsGridlines {
                context.move(to: CGPoint(x: plot.minX, y: at))
                context.addLine(to: CGPoint(x: plot.maxX, y: at))
                context.strokePath()
            }
            drawText(format(tick, percent: false), in: CGRect(x: area.minX, y: at - fontSize * 0.7, width: labelWidth - fontSize * 0.4, height: fontSize * 1.4),
                     size: fontSize, alignment: .right, context: context, measureOnly: false)
        }
        for tick in xScale.ticks {
            let at = point(tick, yScale.minimum).x
            drawText(format(tick, percent: false), in: CGRect(x: at - 40, y: plot.maxY + fontSize * 0.2, width: 80, height: fontSize * 1.4),
                     size: fontSize, alignment: .center, context: context, measureOnly: false)
        }
        let marker = fontSize * 0.5
        for (index, series) in series.enumerated() {
            context.setFillColor(seriesColor(series, index: index).cgColor)
            for (pointIndex, value) in series.values.enumerated() {
                guard let value else { continue }
                let x = series.xValues.isEmpty ? Double(pointIndex + 1)
                    : (series.xValues.indices.contains(pointIndex) ? series.xValues[pointIndex] ?? 0 : 0)
                let at = point(x, value)
                context.fillEllipse(in: CGRect(x: at.x - marker / 2, y: at.y - marker / 2, width: marker, height: marker))
            }
        }
    }

    // MARK: - Text

    private func format(_ value: Double, percent: Bool) -> String {
        if percent { return (value * 100).formatted(.number.precision(.fractionLength(0))) + "%" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func font(size: CGFloat) -> CTFont {
        FontResolver.shared.font(
            family: style.theme.minorFont, size: size, bold: false, italic: false, embedded: style.resources.embeddedFonts
        )
    }

    private func measure(_ text: String, size: CGFloat) -> CGSize {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: size),
        ]))
        return CTLineGetBoundsWithOptions(line, .useOpticalBounds).size
    }

    /// Draws one line of text in `rect`, vertically centred, giving back its height.
    @discardableResult
    private func drawText(
        _ text: String, in rect: CGRect, size: CGFloat, alignment: CTTextAlignment, context: CGContext,
        measureOnly: Bool, color: RGBAColor? = nil
    ) -> CGFloat {
        let font = font(size: size)
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): (color ?? textColor).cgColor,
        ])
        let line = CTLineCreateWithAttributedString(string)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let height = CTFontGetAscent(font) + CTFontGetDescent(font)
        guard !measureOnly else { return height }
        let x: CGFloat = switch alignment {
        case .center: rect.midX - bounds.width / 2
        case .right: rect.maxX - bounds.width
        default: rect.minX
        }
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: rect.midY + (CTFontGetAscent(font) - CTFontGetDescent(font)) / 2)
        CTLineDraw(line, context)
        context.restoreGState()
        return height
    }
}
