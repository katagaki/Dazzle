import Foundation

/// A chart, as much of it as Dazzle draws and edits: its plots and their
/// series, its categories, its title and legend. Everything else in the
/// chart's part is kept as it was.
struct Chart: Equatable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case column
        case bar
        case line
        case area
        case pie
        case doughnut
        case scatter

        /// Whether the plot has axes: everything but a pie.
        var hasAxes: Bool { self != .pie && self != .doughnut }
        /// Whether its points are coloured one by one rather than series by series.
        var colorsByPoint: Bool { self == .pie || self == .doughnut }
    }

    enum Grouping: String, CaseIterable, Sendable {
        /// Side by side, or for lines and areas, each from zero.
        case standard
        case stacked
        case percentStacked
    }

    struct Series: Equatable, Hashable, Sendable {
        var name: String
        /// One per category; `nil` where there is no value.
        var values: [Double?]
        /// For a scatter chart, where each value sits along the x axis.
        var xValues: [Double?] = []
        var color: DrawingColor?
        /// Colours given to single points, by index: a pie's slices.
        var pointColors: [Int: DrawingColor] = [:]
        /// The series' `c:ser` as the file wrote it.
        var source: String?
    }

    struct Plot: Equatable, Hashable, Sendable {
        var kind: Kind
        var grouping: Grouping = .standard
        var series: [Series]
        /// The plot's element — `c:barChart` and the like — as the file wrote it.
        var source: String?
        /// A doughnut's hole, as a percentage of its size.
        var holeSize = 50
    }

    /// The chart's part in the package.
    var path: String
    var plots: [Plot]
    var categories: [String]
    var title: String?
    var hasLegend = true
    /// `r`, `b`, `t`, `l` or `tr`.
    var legendPosition = "r"
    var showsGridlines = true
    var showsValueLabels = false
    /// The value axis's limits, where the file fixes them.
    var minimum: Double?
    var maximum: Double?
    /// The sheet the chart's data comes from, as its formulas name it.
    var sheetName = "Sheet1"
    /// Text size, in hundredths of a point, from the chart's text properties.
    var fontSize: Int?

    var kind: Kind { plots.first?.kind ?? .column }

    /// Every series, in plot order.
    var allSeries: [Series] { plots.flatMap(\.series) }
}

extension Chart {
    /// Reads a chart part, `c:chartSpace`.
    init?(path: String, data: Data?) {
        guard let data, let root = try? XMLLite.parse(data), let chart = root.firstChild(named: "chart"),
              let area = chart.firstChild(named: "plotArea") else { return nil }
        self.path = path
        plots = area.children.compactMap(Self.plot)
        categories = []
        guard !plots.isEmpty else { return nil }

        // Categories are given per series; the first that has any speaks for all.
        for element in area.children {
            for series in element.children(named: "ser") {
                let labels = Self.labels(in: series.firstChild(named: "cat"))
                if !labels.isEmpty, categories.isEmpty { categories = labels }
                if let formula = Self.formulas(in: series).first, let sheet = Self.sheetName(in: formula) {
                    sheetName = sheet
                }
            }
        }
        let count = max(categories.count, allSeries.map(\.values.count).max() ?? 0)
        if categories.count < count {
            categories += (categories.count..<count).map { String($0 + 1) }
        }

        if let titleElement = chart.firstChild(named: "title") {
            let text = Self.richText(in: titleElement)
            title = text.isEmpty ? Self.cachedText(in: titleElement.firstChild(named: "tx")) : text
            if title?.isEmpty ?? true {
                // A title with no text of its own shows the series' name, as PowerPoint does for one series.
                title = allSeries.count == 1 ? allSeries[0].name : nil
            }
        }
        if chart.firstChild(named: "autoTitleDeleted")?.attribute("val") == "1", chart.firstChild(named: "title") == nil {
            title = nil
        }
        if let legend = chart.firstChild(named: "legend") {
            hasLegend = true
            legendPosition = legend.firstChild(named: "legendPos")?.attribute("val") ?? "r"
        } else {
            hasLegend = false
        }
        let valueAxis = area.firstChild(named: "valAx")
        showsGridlines = valueAxis?.firstChild(named: "majorGridlines") != nil
        minimum = valueAxis?.firstChild(named: "scaling")?.firstChild(named: "min")?.attribute("val").flatMap(Double.init)
        maximum = valueAxis?.firstChild(named: "scaling")?.firstChild(named: "max")?.attribute("val").flatMap(Double.init)
        showsValueLabels = area.children.contains { plot in
            plot.firstChild(named: "dLbls")?.firstChild(named: "showVal")?.attribute("val") == "1"
        }
        fontSize = root.firstChild(named: "txPr")?.firstDescendant(atPath: "p/pPr/defRPr")?.attribute("sz").flatMap(Int.init)
    }

    private static func plot(_ element: XMLElement) -> Plot? {
        let kind: Kind
        switch element.name {
        case "barChart", "bar3DChart":
            kind = element.firstChild(named: "barDir")?.attribute("val") == "bar" ? .bar : .column
        case "lineChart", "line3DChart", "stockChart", "radarChart": kind = .line
        case "areaChart", "area3DChart": kind = .area
        case "pieChart", "pie3DChart", "ofPieChart": kind = .pie
        case "doughnutChart": kind = .doughnut
        case "scatterChart", "bubbleChart": kind = .scatter
        default: return nil
        }
        let grouping: Grouping = switch element.firstChild(named: "grouping")?.attribute("val") {
        case "stacked": .stacked
        case "percentStacked": .percentStacked
        default: .standard
        }
        var plot = Plot(kind: kind, grouping: grouping, series: element.children(named: "ser").map { Self.series($0, kind: kind) })
        plot.source = XMLLite.serialize(element)
        plot.holeSize = element.firstChild(named: "holeSize")?.attribute("val").flatMap(Int.init) ?? 50
        return plot
    }

    private static func series(_ element: XMLElement, kind: Kind) -> Series {
        let name = cachedText(in: element.firstChild(named: "tx")) ?? ""
        let values = numbers(in: element.firstChild(named: kind == .scatter ? "yVal" : "val"))
        var series = Series(name: name, values: values)
        if kind == .scatter { series.xValues = numbers(in: element.firstChild(named: "xVal")) }
        series.color = color(in: element.firstChild(named: "spPr"), kind: kind)
        for point in element.children(named: "dPt") {
            if let index = point.firstChild(named: "idx")?.attribute("val").flatMap(Int.init),
               let color = color(in: point.firstChild(named: "spPr"), kind: kind) {
                series.pointColors[index] = color
            }
        }
        series.source = XMLLite.serialize(element)
        return series
    }

    /// A series' colour: its fill, or for a line, its outline.
    private static func color(in properties: XMLElement?, kind: Kind) -> DrawingColor? {
        guard let properties else { return nil }
        if kind == .line || kind == .scatter, let line = properties.firstChild(named: "ln"),
           let color = DrawingColor.first(in: line.firstChild(named: "solidFill")) {
            return color
        }
        return DrawingColor.first(in: properties.firstChild(named: "solidFill"))
            ?? DrawingColor.first(in: properties.firstChild(named: "gradFill")?.firstChild(named: "gsLst")?.firstChild(named: "gs"))
    }

    /// The cached values of a `c:val`, `c:xVal` or `c:yVal`, by point index.
    private static func numbers(in element: XMLElement?) -> [Double?] {
        guard let element else { return [] }
        let cache = element.firstChild(named: "numRef")?.firstChild(named: "numCache") ?? element.firstChild(named: "numLit")
            ?? element.firstChild(named: "strRef")?.firstChild(named: "strCache")
        guard let cache else { return [] }
        let count = cache.firstChild(named: "ptCount")?.attribute("val").flatMap(Int.init) ?? 0
        var values = [Double?](repeating: nil, count: count)
        for point in cache.children(named: "pt") {
            guard let index = point.attribute("idx").flatMap(Int.init) else { continue }
            if index >= values.count { values += [Double?](repeating: nil, count: index - values.count + 1) }
            values[index] = point.firstChild(named: "v").flatMap { Double($0.text.trimmed) }
        }
        return values
    }

    /// The cached labels of a `c:cat`, by point index.
    private static func labels(in element: XMLElement?) -> [String] {
        guard let element else { return [] }
        let cache = element.firstChild(named: "strRef")?.firstChild(named: "strCache")
            ?? element.firstChild(named: "numRef")?.firstChild(named: "numCache")
            ?? element.firstChild(named: "strLit") ?? element.firstChild(named: "numLit")
            ?? element.firstChild(named: "multiLvlStrRef")?.firstChild(named: "multiLvlStrCache")?.firstChild(named: "lvl")
        guard let cache else { return [] }
        let count = cache.firstChild(named: "ptCount")?.attribute("val").flatMap(Int.init) ?? 0
        var labels = [String](repeating: "", count: count)
        for point in cache.children(named: "pt") {
            guard let index = point.attribute("idx").flatMap(Int.init) else { continue }
            if index >= labels.count { labels += [String](repeating: "", count: index - labels.count + 1) }
            labels[index] = point.firstChild(named: "v")?.text ?? ""
        }
        return labels
    }

    private static func cachedText(in element: XMLElement?) -> String? {
        guard let element else { return nil }
        if let cache = element.firstChild(named: "strRef")?.firstChild(named: "strCache") {
            return cache.children(named: "pt").compactMap { $0.firstChild(named: "v")?.text }.joined(separator: " ")
        }
        if let value = element.firstChild(named: "v") { return value.text }
        let rich = richText(in: element)
        return rich.isEmpty ? nil : rich
    }

    /// The text of a title's rich text, paragraph by paragraph.
    private static func richText(in element: XMLElement) -> String {
        guard let rich = element.firstChild(named: "tx")?.firstChild(named: "rich") ?? element.firstChild(named: "rich") else { return "" }
        return rich.children(named: "p").map { paragraph in
            paragraph.children.filter { $0.name == "r" || $0.name == "fld" }.compactMap { $0.firstChild(named: "t")?.text }.joined()
        }.joined(separator: "\n")
    }

    static func formulas(in element: XMLElement) -> [String] {
        var result: [String] = []
        func visit(_ element: XMLElement) {
            if element.name == "f" { result.append(element.text) }
            element.children.forEach(visit)
        }
        visit(element)
        return result
    }

    /// `Sheet1` from `Sheet1!$B$1`, or `My Sheet` from `'My Sheet'!$B$1`.
    static func sheetName(in formula: String) -> String? {
        guard let bang = formula.lastIndex(of: "!") else { return nil }
        var name = String(formula[..<bang])
        if name.hasPrefix("'"), name.hasSuffix("'"), name.count >= 2 {
            name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return name.nilIfEmpty
    }
}

extension Chart {
    /// A new chart with the sample data PowerPoint starts one with.
    static func sample(_ kind: Kind, path: String) -> Chart {
        if kind.colorsByPoint {
            return Chart(
                path: path,
                plots: [Plot(kind: kind, series: [Series(name: String(localized: "Chart.Sample.Sales"), values: [8.2, 3.2, 1.4, 1.2])])],
                categories: (1...4).map { String(format: String(localized: "Chart.Sample.Quarter"), $0) },
                title: String(localized: "Chart.Sample.Sales"), legendPosition: "b"
            )
        }
        let values: [[Double?]] = [[4.3, 2.5, 3.5, 4.5], [2.4, 4.4, 1.8, 2.8], [2, 2, 3, 5]]
        let categories = kind == .scatter
            ? ["0.7", "1.8", "2.6", "3.4"]
            : (1...4).map { String(format: String(localized: "Chart.Sample.Category"), $0) }
        return Chart(
            path: path,
            plots: [Plot(kind: kind, series: values.enumerated().map { index, values in
                Series(name: String(format: String(localized: "Chart.Sample.Series"), index + 1), values: values)
            })],
            categories: categories, title: nil, legendPosition: "b"
        )
    }
}

