import Foundation

/// Writes a chart's data, type, title and legend back into its part, and
/// its data into the workbook PowerPoint opens to edit it.
///
/// The chart part is patched rather than rewritten: a plot whose kind did
/// not change keeps its own XML, and each series its formatting, with only
/// names, categories and values replaced. Everything outside the plot area,
/// title and legend is kept as it was.
enum ChartWriter {
    static let namespaces: [String: String] = [
        "c": "http://schemas.openxmlformats.org/drawingml/2006/chart",
        "a": OOXML.drawingML,
        "r": OOXML.relationshipsNS,
    ]

    static let contentType = "application/vnd.openxmlformats-officedocument.drawingml.chart+xml"

    private static func fragment(_ xml: String) -> XMLElement? {
        XMLLite.fragment(xml, namespaces: namespaces)
    }

    // MARK: - Chart part

    /// The chart part's XML with `chart` laid over `original`, or a new part
    /// if there is no original. `workbookRelationship` is the id of the
    /// relationship to an embedded workbook, for a new part.
    static func data(for chart: Chart, original: Data?, workbookRelationship: String? = nil) -> Data? {
        let root = original.flatMap { try? XMLLite.parse($0) } ?? fragment(skeleton(workbookRelationship: workbookRelationship))
        guard let root, let chartElement = root.firstChild(named: "chart"),
              let area = chartElement.firstChild(named: "plotArea") else { return nil }

        writeTitle(chart.title, into: chartElement)
        writePlots(chart, into: area)
        writeLegend(chart, into: chartElement)

        guard let xml = XMLLite.serialize(root) else { return nil }
        return Data((PackagePath.declaration + xml).utf8)
    }

    private static func skeleton(workbookRelationship: String?) -> String {
        let external = workbookRelationship.map { "<c:externalData r:id=\"\($0)\"><c:autoUpdate val=\"0\"/></c:externalData>" } ?? ""
        return """
            <c:chartSpace xmlns:c="\(namespaces["c"]!)" xmlns:a="\(OOXML.drawingML)" xmlns:r="\(OOXML.relationshipsNS)">\
            <c:date1904 val="0"/><c:roundedCorners val="0"/><c:chart><c:autoTitleDeleted val="1"/><c:plotArea><c:layout/>\
            </c:plotArea><c:plotVisOnly val="1"/><c:dispBlanksAs val="gap"/></c:chart><c:spPr><a:noFill/><a:ln><a:noFill/>\
            </a:ln></c:spPr><c:txPr><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr/></a:pPr><a:endParaRPr lang="en-US"/>\
            </a:p></c:txPr>\(external)</c:chartSpace>
            """
    }

    /// Where a child of `c:chart` goes among its siblings.
    private static func chartChildOrder(_ name: String) -> Int {
        ["title", "autoTitleDeleted", "pivotFmts", "view3D", "floor", "sideWall", "backWall", "plotArea", "legend",
         "plotVisOnly", "dispBlanksAs", "showDLblsOverMax", "extLst"].firstIndex(of: name) ?? 99
    }

    private static func insert(_ child: XMLElement, into parent: XMLElement, order: (String) -> Int) {
        let before = parent.children.firstIndex { order($0.name) > order(child.name) }
        parent.insertChild(child, at: before ?? parent.children.count)
    }

    // MARK: - Title and legend

    private static func writeTitle(_ title: String?, into chart: XMLElement) {
        let existing = chart.firstChild(named: "title")
        let deleted = chart.firstChild(named: "autoTitleDeleted")
        guard let title, !title.isEmpty else {
            existing.map(chart.removeChild)
            if let deleted { deleted.setAttribute("val", "1") } else if let mark = fragment("<c:autoTitleDeleted val=\"1\"/>") {
                insert(mark, into: chart, order: chartChildOrder)
            }
            return
        }
        deleted?.setAttribute("val", "0")
        let runs = title.components(separatedBy: "\n").map { line in
            "<a:p><a:pPr><a:defRPr/></a:pPr><a:r><a:rPr lang=\"en-US\"/><a:t>\(XMLLite.escape(line))</a:t></a:r></a:p>"
        }.joined()
        // A title the file formatted keeps its formatting: only its text changes.
        if let rich = existing?.firstChild(named: "tx")?.firstChild(named: "rich") {
            let template = rich.children(named: "p").first
            for paragraph in rich.children(named: "p") { rich.removeChild(paragraph) }
            for line in title.components(separatedBy: "\n") {
                guard let paragraph = template.flatMap({ XMLLite.serialize($0) }).flatMap(fragment) ?? fragment("<a:p/>") else { continue }
                let runProperties = paragraph.children.first { $0.name == "r" }?.firstChild(named: "rPr")
                for child in paragraph.children where ["r", "fld", "br"].contains(child.name) { paragraph.removeChild(child) }
                let properties = runProperties.flatMap { XMLLite.serialize($0) } ?? "<a:rPr lang=\"en-US\"/>"
                if let run = fragment("<a:r>\(properties)<a:t>\(XMLLite.escape(line))</a:t></a:r>") {
                    let before = paragraph.children.firstIndex { $0.name == "endParaRPr" }
                    paragraph.insertChild(run, at: before ?? paragraph.children.count)
                }
                rich.insertChild(paragraph, at: rich.children.count)
            }
            return
        }
        existing.map(chart.removeChild)
        guard let element = fragment("""
            <c:title><c:tx><c:rich><a:bodyPr rot="0" spcFirstLastPara="1" vertOverflow="ellipsis" vert="horz" wrap="square" \
            anchor="ctr" anchorCtr="1"/><a:lstStyle/>\(runs)</c:rich></c:tx><c:overlay val="0"/></c:title>
            """) else { return }
        insert(element, into: chart, order: chartChildOrder)
    }

    private static func writeLegend(_ chart: Chart, into element: XMLElement) {
        let existing = element.firstChild(named: "legend")
        guard chart.hasLegend else {
            existing.map(element.removeChild)
            return
        }
        if let existing {
            existing.firstChild(named: "legendPos")?.setAttribute("val", chart.legendPosition)
            return
        }
        if let legend = fragment("<c:legend><c:legendPos val=\"\(chart.legendPosition)\"/><c:overlay val=\"0\"/></c:legend>") {
            insert(legend, into: element, order: chartChildOrder)
        }
    }

    // MARK: - Plots

    private static let plotNames: Set<String> = [
        "barChart", "bar3DChart", "lineChart", "line3DChart", "areaChart", "area3DChart", "pieChart", "pie3DChart",
        "ofPieChart", "doughnutChart", "scatterChart", "bubbleChart", "radarChart", "stockChart", "surfaceChart", "surface3DChart",
    ]
    private static let axisNames: Set<String> = ["catAx", "valAx", "dateAx", "serAx"]

    private static func elementName(for kind: Chart.Kind) -> String {
        switch kind {
        case .column, .bar: "barChart"
        case .line: "lineChart"
        case .area: "areaChart"
        case .pie: "pieChart"
        case .doughnut: "doughnutChart"
        case .scatter: "scatterChart"
        }
    }

    private static func writePlots(_ chart: Chart, into area: XMLElement) {
        let firstPlot = area.children.firstIndex { plotNames.contains($0.name) } ?? (area.firstChild(named: "layout") != nil ? 1 : 0)
        for child in area.children where plotNames.contains(child.name) { area.removeChild(child) }

        // Axes: kept if the plots still use the kind they are, made if not.
        let needsAxes = chart.plots.contains { $0.kind.hasAxes }
        let isScatter = chart.plots.contains { $0.kind == .scatter }
        let horizontal = chart.plots.first?.kind == .bar
        var axes = area.children.filter { axisNames.contains($0.name) }
        let hasCategoryAxis = axes.contains { $0.name == "catAx" || $0.name == "dateAx" }
        let valueAxes = axes.filter { $0.name == "valAx" }.count
        let fits = isScatter ? (valueAxes >= 2 && !hasCategoryAxis) : (hasCategoryAxis && valueAxes >= 1)
        if !needsAxes || !fits {
            for axis in axes { area.removeChild(axis) }
            axes = []
        }
        if needsAxes, axes.isEmpty {
            axes = newAxes(scatter: isScatter, horizontal: horizontal)
            let after = area.children.lastIndex { $0.name == "layout" } ?? -1
            for (offset, axis) in axes.enumerated() { area.insertChild(axis, at: after + 1 + offset) }
        }
        let axisIDs = axes.compactMap { $0.firstChild(named: "axId")?.attribute("val") }
        // Bars run along whichever side their category axis sits on.
        for axis in axes {
            let isCategory = axis.name == "catAx" || axis.name == "dateAx"
            if !isScatter {
                axis.firstChild(named: "axPos")?.setAttribute("val", isCategory == horizontal ? "l" : "b")
            }
            if axis.name == "valAx", !isScatter || axis === axes.last {
                writeValueAxis(axis, chart: chart)
            }
        }

        var column = 1
        for (index, plot) in chart.plots.enumerated() {
            guard let element = plotElement(plot, chart: chart, firstColumn: column, axisIDs: axisIDs) else { continue }
            area.insertChild(element, at: firstPlot + index)
            column += plot.series.count
        }
    }

    private static func writeValueAxis(_ axis: XMLElement, chart: Chart) {
        let gridlines = axis.firstChild(named: "majorGridlines")
        if chart.showsGridlines, gridlines == nil, let new = fragment("<c:majorGridlines/>") {
            // After axId, scaling, delete and axPos.
            let before = axis.children.firstIndex { !["axId", "scaling", "delete", "axPos"].contains($0.name) }
            axis.insertChild(new, at: before ?? axis.children.count)
        } else if !chart.showsGridlines, let gridlines {
            axis.removeChild(gridlines)
        }
    }

    private static func newAxes(scatter: Bool, horizontal: Bool) -> [XMLElement] {
        let tail = """
            <c:numFmt formatCode="General" sourceLinked="1"/><c:majorTickMark val="none"/><c:minorTickMark val="none"/>\
            <c:tickLblPos val="nextTo"/>
            """
        let first = scatter
            ? "<c:valAx><c:axId val=\"500000001\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/>"
                + "<c:axPos val=\"b\"/>\(tail)<c:crossAx val=\"500000002\"/><c:crosses val=\"autoZero\"/>"
                + "<c:crossBetween val=\"midCat\"/></c:valAx>"
            : "<c:catAx><c:axId val=\"500000001\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/>"
                + "<c:axPos val=\"\(horizontal ? "l" : "b")\"/>\(tail)<c:crossAx val=\"500000002\"/><c:crosses val=\"autoZero\"/>"
                + "<c:auto val=\"1\"/><c:lblAlgn val=\"ctr\"/><c:lblOffset val=\"100\"/><c:noMultiLvlLbl val=\"0\"/></c:catAx>"
        let second = "<c:valAx><c:axId val=\"500000002\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling>"
            + "<c:delete val=\"0\"/><c:axPos val=\"\(horizontal ? "b" : "l")\"/><c:majorGridlines/>\(tail)"
            + "<c:crossAx val=\"500000001\"/><c:crosses val=\"autoZero\"/><c:crossBetween val=\"\(scatter ? "midCat" : "between")\"/></c:valAx>"
        return [first, second].compactMap(fragment)
    }

    /// Children of a plot element that follow its series.
    private static let afterSeries: Set<String> = [
        "dLbls", "gapWidth", "overlap", "serLines", "axId", "dropLines", "hiLowLines", "upDownBars", "marker", "smooth",
        "firstSliceAng", "holeSize", "extLst", "bubbleScale", "showNegBubbles",
    ]

    private static func plotElement(_ plot: Chart.Plot, chart: Chart, firstColumn: Int, axisIDs: [String]) -> XMLElement? {
        let name = elementName(for: plot.kind)
        let kept = plot.source.flatMap(fragment).flatMap { $0.name == name ? $0 : nil }
        let element = kept ?? fragment(plotSkeleton(plot.kind, axisIDs: axisIDs))
        guard let element else { return nil }
        if plot.kind == .column || plot.kind == .bar {
            element.firstChild(named: "barDir")?.setAttribute("val", plot.kind == .bar ? "bar" : "col")
        }
        if let grouping = element.firstChild(named: "grouping") {
            let value = switch (plot.kind, plot.grouping) {
            case (.column, .standard), (.bar, .standard): "clustered"
            case (_, .standard): "standard"
            case (_, .stacked): "stacked"
            case (_, .percentStacked): "percentStacked"
            }
            grouping.setAttribute("val", value)
            // Stacked bars sit on one another, side by side ones apart.
            if plot.kind == .column || plot.kind == .bar {
                let overlap = element.firstChild(named: "overlap")
                if plot.grouping == .standard {
                    overlap?.setAttribute("val", "-27")
                } else if let overlap {
                    overlap.setAttribute("val", "100")
                } else if let new = fragment("<c:overlap val=\"100\"/>") {
                    let before = element.children.firstIndex { ["serLines", "axId", "extLst"].contains($0.name) }
                    element.insertChild(new, at: before ?? element.children.count)
                }
            }
        }
        if plot.kind == .doughnut { element.firstChild(named: "holeSize")?.setAttribute("val", String(plot.holeSize)) }
        writeValueLabels(chart.showsValueLabels, into: element)
        // The plot's axes, which a plot that was made fresh names already.
        if kept != nil, plot.kind.hasAxes {
            for axis in element.children(named: "axId") { element.removeChild(axis) }
            let before = element.children.firstIndex { $0.name == "extLst" }
            for (offset, id) in axisIDs.prefix(2).enumerated() {
                if let axis = fragment("<c:axId val=\"\(id)\"/>") { element.insertChild(axis, at: (before ?? element.children.count) + offset) }
            }
        }

        for series in element.children(named: "ser") { element.removeChild(series) }
        let insertion = element.children.firstIndex { afterSeries.contains($0.name) } ?? element.children.count
        for (offset, series) in plot.series.enumerated() {
            let index = firstColumn - 1 + offset
            guard let seriesElement = seriesElement(series, kind: plot.kind, index: index, column: firstColumn + offset, chart: chart) else {
                continue
            }
            element.insertChild(seriesElement, at: insertion + offset)
        }
        return element
    }

    private static func plotSkeleton(_ kind: Chart.Kind, axisIDs: [String]) -> String {
        let axes = axisIDs.prefix(2).map { "<c:axId val=\"\($0)\"/>" }.joined()
        let labels = "<c:dLbls><c:showLegendKey val=\"0\"/><c:showVal val=\"0\"/><c:showCatName val=\"0\"/>"
            + "<c:showSerName val=\"0\"/><c:showPercent val=\"0\"/><c:showBubbleSize val=\"0\"/></c:dLbls>"
        switch kind {
        case .column, .bar:
            return "<c:barChart><c:barDir val=\"col\"/><c:grouping val=\"clustered\"/><c:varyColors val=\"0\"/>\(labels)"
                + "<c:gapWidth val=\"219\"/><c:overlap val=\"-27\"/>\(axes)</c:barChart>"
        case .line:
            return "<c:lineChart><c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>\(labels)<c:marker val=\"1\"/>\(axes)</c:lineChart>"
        case .area:
            return "<c:areaChart><c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>\(labels)\(axes)</c:areaChart>"
        case .pie:
            return "<c:pieChart><c:varyColors val=\"1\"/>\(labels)<c:firstSliceAng val=\"0\"/></c:pieChart>"
        case .doughnut:
            return "<c:doughnutChart><c:varyColors val=\"1\"/>\(labels)<c:firstSliceAng val=\"0\"/><c:holeSize val=\"50\"/></c:doughnutChart>"
        case .scatter:
            return "<c:scatterChart><c:scatterStyle val=\"lineMarker\"/><c:varyColors val=\"0\"/>\(labels)\(axes)</c:scatterChart>"
        }
    }

    private static func writeValueLabels(_ isOn: Bool, into plot: XMLElement) {
        if let labels = plot.firstChild(named: "dLbls") {
            if let value = labels.firstChild(named: "showVal") {
                value.setAttribute("val", isOn ? "1" : "0")
            } else if isOn, let value = fragment("<c:showVal val=\"1\"/>") {
                let before = labels.children.firstIndex { ["showCatName", "showSerName", "showPercent", "showBubbleSize", "separator", "showLeaderLines", "extLst"].contains($0.name) }
                labels.insertChild(value, at: before ?? labels.children.count)
            }
        }
    }

    // MARK: - Series

    /// The order of a series' children, for each kind of plot.
    private static func seriesChildOrder(_ kind: Chart.Kind) -> [String] {
        switch kind {
        case .column, .bar:
            ["idx", "order", "tx", "spPr", "invertIfNegative", "pictureOptions", "dPt", "dLbls", "trendline", "errBars", "cat", "val", "shape", "extLst"]
        case .line:
            ["idx", "order", "tx", "spPr", "marker", "dPt", "dLbls", "trendline", "errBars", "cat", "val", "smooth", "extLst"]
        case .area:
            ["idx", "order", "tx", "spPr", "pictureOptions", "dPt", "dLbls", "trendline", "errBars", "cat", "val", "extLst"]
        case .pie, .doughnut:
            ["idx", "order", "tx", "spPr", "explosion", "dPt", "dLbls", "cat", "val", "extLst"]
        case .scatter:
            ["idx", "order", "tx", "spPr", "marker", "dPt", "dLbls", "trendline", "errBars", "xVal", "yVal", "smooth", "extLst"]
        }
    }

    private static func seriesElement(_ series: Chart.Series, kind: Chart.Kind, index: Int, column: Int, chart: Chart) -> XMLElement? {
        let order = seriesChildOrder(kind)
        // A series keeps its formatting if it is still in a plot of the kind it was.
        let kept = series.source.flatMap(fragment).flatMap { element -> XMLElement? in
            element.children.allSatisfy { order.contains($0.name) } ? element : nil
        }
        guard let element = kept ?? fragment("<c:ser/>") else { return nil }
        for child in element.children where ["idx", "order", "tx", "cat", "val", "xVal", "yVal"].contains(child.name) {
            element.removeChild(child)
        }
        let sheet = quotedSheet(chart.sheetName)
        let letter = columnLetter(column)
        let count = chart.categories.count
        let last = count + 1
        var parts = [
            "<c:idx val=\"\(index)\"/>", "<c:order val=\"\(index)\"/>",
            "<c:tx><c:strRef><c:f>\(sheet)!$\(letter)$1</c:f><c:strCache><c:ptCount val=\"1\"/><c:pt idx=\"0\">"
                + "<c:v>\(XMLLite.escape(series.name))</c:v></c:pt></c:strCache></c:strRef></c:tx>",
        ]
        let values = (0..<count).map { series.values.indices.contains($0) ? series.values[$0] : nil }
        if kind == .scatter {
            parts.append("<c:xVal>" + numberReference("\(sheet)!$A$2:$A$\(last)", chart.categories.map { Double($0) }) + "</c:xVal>")
            parts.append("<c:yVal>" + numberReference("\(sheet)!$\(letter)$2:$\(letter)$\(last)", values) + "</c:yVal>")
        } else {
            let points = chart.categories.enumerated().map { "<c:pt idx=\"\($0)\"><c:v>\(XMLLite.escape($1))</c:v></c:pt>" }.joined()
            parts.append("<c:cat><c:strRef><c:f>\(sheet)!$A$2:$A$\(last)</c:f><c:strCache><c:ptCount val=\"\(count)\"/>"
                + "\(points)</c:strCache></c:strRef></c:cat>")
            parts.append("<c:val>" + numberReference("\(sheet)!$\(letter)$2:$\(letter)$\(last)", values) + "</c:val>")
        }
        if kept == nil, let color = series.color {
            let properties = kind == .line || kind == .scatter
                ? "<c:spPr><a:ln w=\"28575\" cap=\"rnd\"><a:solidFill>\(color.xml)</a:solidFill><a:round/></a:ln></c:spPr>"
                : "<c:spPr><a:solidFill>\(color.xml)</a:solidFill></c:spPr>"
            parts.append(properties)
        }
        if kept == nil, kind == .line || kind == .scatter {
            parts.append("<c:marker><c:symbol val=\"circle\"/><c:size val=\"5\"/></c:marker>")
        }
        if kept == nil, kind == .column || kind == .bar {
            parts.append("<c:invertIfNegative val=\"0\"/>")
        }
        for xml in parts {
            guard let child = fragment(xml) else { continue }
            let rank = order.firstIndex(of: child.name) ?? order.count
            let before = element.children.firstIndex { (order.firstIndex(of: $0.name) ?? order.count) > rank }
            element.insertChild(child, at: before ?? element.children.count)
        }
        return element
    }

    private static func numberReference(_ formula: String, _ values: [Double?]) -> String {
        let points = values.enumerated().compactMap { index, value in
            value.map { "<c:pt idx=\"\(index)\"><c:v>\(number($0))</c:v></c:pt>" }
        }.joined()
        return "<c:numRef><c:f>\(XMLLite.escape(formula))</c:f><c:numCache><c:formatCode>General</c:formatCode>"
            + "<c:ptCount val=\"\(values.count)\"/>\(points)</c:numCache></c:numRef>"
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    /// `A`, `B`… `Z`, `AA`… for a one-based column.
    static func columnLetter(_ column: Int) -> String {
        var number = column
        var letters = ""
        while number > 0 {
            let remainder = (number - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + remainder))) + letters
            number = (number - 1) / 26
        }
        return letters
    }

    private static func quotedSheet(_ name: String) -> String {
        let plain = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        return XMLLite.escape(plain ? name : "'" + name.replacingOccurrences(of: "'", with: "''") + "'")
    }

    // MARK: - Workbook

    /// The chart's data as a workbook: categories down the first column,
    /// each series down a column of its own, named in the first row.
    static func workbook(for chart: Chart) -> Data? {
        let sheet = XMLLite.escape(chart.sheetName)
        func cell(_ reference: String, text: String) -> String {
            "<c r=\"\(reference)\" t=\"inlineStr\"><is><t>\(XMLLite.escape(text))</t></is></c>"
        }
        func cell(_ reference: String, number value: Double?) -> String {
            value.map { "<c r=\"\(reference)\"><v>\(number($0))</v></c>" } ?? ""
        }
        let series = chart.allSeries
        var rows = ["<row r=\"1\">" + series.enumerated().map { cell("\(columnLetter($0 + 2))1", text: $1.name) }.joined() + "</row>"]
        for (index, category) in chart.categories.enumerated() {
            let row = index + 2
            let label = chart.kind == .scatter ? cell("A\(row)", number: Double(category)) : cell("A\(row)", text: category)
            let values = series.enumerated().map { column, series in
                cell("\(columnLetter(column + 2))\(row)", number: series.values.indices.contains(index) ? series.values[index] : nil)
            }.joined()
            rows.append("<row r=\"\(row)\">\(label)\(values)</row>")
        }
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let parts: [(path: String, data: Data)] = [
            ("[Content_Types].xml", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Types xmlns="\(OOXML.contentTypesNS)"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
                <Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" \
                ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override \
                PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
                <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
                """),
            ("_rels/.rels", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="\(OOXML.packageRelationships)"><Relationship Id="rId1" \
                Type="\(OOXML.RelationshipType.officeDocument)" Target="xl/workbook.xml"/></Relationships>
                """),
            ("xl/workbook.xml", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <workbook xmlns="\(main)" xmlns:r="\(OOXML.relationshipsNS)"><sheets><sheet name="\(sheet)" sheetId="1" r:id="rId1"/>\
                </sheets></workbook>
                """),
            ("xl/_rels/workbook.xml.rels", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="\(OOXML.packageRelationships)"><Relationship Id="rId1" \
                Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
                <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" \
                Target="styles.xml"/></Relationships>
                """),
            ("xl/worksheets/sheet1.xml", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <worksheet xmlns="\(main)"><sheetData>\(rows.joined())</sheetData></worksheet>
                """),
            ("xl/styles.xml", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <styleSheet xmlns="\(main)"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>\
                <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>\
                </fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs \
                count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" \
                fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs></styleSheet>
                """),
        ].map { ($0.0, Data($0.1.utf8)) }
        return try? ZipArchive.archive(entries: parts)
    }

    /// Where the chart's embedded workbook is, if it has one Dazzle can rewrite.
    static func workbookPath(of chart: Chart, in presentation: Presentation) -> String? {
        guard let data = presentation.data(at: chart.path), let root = try? XMLLite.parse(data),
              let id = root.firstChild(named: "externalData")?.relationshipID else { return nil }
        let relationships = Relationship.parse(presentation.data(at: PackagePath.relationships(of: chart.path)))
        guard let relationship = relationships.first(where: { $0.id == id }), !relationship.isExternal else { return nil }
        let path = PackagePath.resolve(relationship.target, from: chart.path)
        return path.lowercased().hasSuffix(".xlsx") ? path : nil
    }
}
