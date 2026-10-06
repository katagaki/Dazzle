import Foundation

/// The package a new presentation starts as: a 16:9 deck with the Office
/// theme, five common layouts and one title slide.
///
/// Built here rather than shipped as a file so every part is readable in
/// review, and read back through `PPTXReader` like any other file.
enum PresentationTemplate {
    static func parts() -> [String: Data] {
        var parts: [String: String] = [
            "[Content_Types].xml": contentTypes,
            "_rels/.rels": rootRelationships,
            "ppt/presentation.xml": presentation,
            "ppt/_rels/presentation.xml.rels": presentationRelationships,
            "ppt/presProps.xml": presentationProperties,
            "ppt/viewProps.xml": viewProperties,
            "ppt/tableStyles.xml": tableStyles,
            "ppt/theme/theme1.xml": theme,
            "ppt/slideMasters/slideMaster1.xml": master,
            "ppt/slideMasters/_rels/slideMaster1.xml.rels": masterRelationships,
            "ppt/slides/slide1.xml": firstSlide,
            "ppt/slides/_rels/slide1.xml.rels": relationships([(layout, "../slideLayouts/slideLayout1.xml")]),
        ]
        for (index, layout) in layouts.enumerated() {
            parts["ppt/slideLayouts/slideLayout\(index + 1).xml"] = layout
            parts["ppt/slideLayouts/_rels/slideLayout\(index + 1).xml.rels"] =
                relationships([(masterType, "../slideMasters/slideMaster1.xml")])
        }
        return parts.mapValues { Data((PackagePath.declaration + $0).utf8) }
    }

    // MARK: - Package

    private static let namespaces = """
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
        """

    private static let layout = OOXML.RelationshipType.slideLayout
    private static let masterType = OOXML.RelationshipType.slideMaster

    private static func relationships(_ entries: [(type: String, target: String)]) -> String {
        let items = entries.enumerated().map { index, entry in
            "<Relationship Id=\"rId\(index + 1)\" Type=\"\(entry.type)\" Target=\"\(entry.target)\"/>"
        }
        return "<Relationships xmlns=\"\(OOXML.packageRelationships)\">\(items.joined())</Relationships>"
    }

    private static var contentTypes: String {
        let presentationML = "application/vnd.openxmlformats-officedocument.presentationml."
        var overrides = [
            ("/ppt/presentation.xml", presentationML + "presentation.main+xml"),
            ("/ppt/presProps.xml", presentationML + "presProps+xml"),
            ("/ppt/viewProps.xml", presentationML + "viewProps+xml"),
            ("/ppt/tableStyles.xml", presentationML + "tableStyles+xml"),
            ("/ppt/theme/theme1.xml", OOXML.ContentType.theme),
            ("/ppt/slideMasters/slideMaster1.xml", presentationML + "slideMaster+xml"),
            ("/ppt/slides/slide1.xml", OOXML.ContentType.slide),
        ]
        for index in layouts.indices {
            overrides.append(("/ppt/slideLayouts/slideLayout\(index + 1).xml", presentationML + "slideLayout+xml"))
        }
        let entries = overrides.map { "<Override PartName=\"\($0.0)\" ContentType=\"\($0.1)\"/>" }.joined()
        return """
            <Types xmlns="\(OOXML.contentTypesNS)">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Default Extension="png" ContentType="image/png"/>\
            <Default Extension="jpeg" ContentType="image/jpeg"/>\
            \(entries)</Types>
            """
    }

    private static let rootRelationships = relationships([
        (OOXML.RelationshipType.officeDocument, "ppt/presentation.xml"),
    ])

    private static let presentationRelationships = relationships([
        (masterType, "slideMasters/slideMaster1.xml"),
        (OOXML.RelationshipType.slide, "slides/slide1.xml"),
        (OOXML.RelationshipType.theme, "theme/theme1.xml"),
        ("http://schemas.openxmlformats.org/officeDocument/2006/relationships/presProps", "presProps.xml"),
        ("http://schemas.openxmlformats.org/officeDocument/2006/relationships/viewProps", "viewProps.xml"),
        ("http://schemas.openxmlformats.org/officeDocument/2006/relationships/tableStyles", "tableStyles.xml"),
    ])

    private static var presentation: String {
        let levels = (1...9).map { level in
            """
            <a:lvl\(level)pPr marL="\((level - 1) * 457_200)" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" \
            latinLnBrk="0" hangingPunct="1"><a:defRPr sz="1800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/>\
            </a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/>\
            </a:defRPr></a:lvl\(level)pPr>
            """
        }.joined()
        return """
            <p:presentation \(namespaces) saveSubsetFonts="1">\
            <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
            <p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst>\
            <p:sldSz cx="\(EMUSize.widescreen.width)" cy="\(EMUSize.widescreen.height)"/>\
            <p:notesSz cx="6858000" cy="9144000"/>\
            <p:defaultTextStyle><a:defPPr><a:defRPr lang="en-US"/></a:defPPr>\(levels)</p:defaultTextStyle>\
            </p:presentation>
            """
    }

    private static let presentationProperties = "<p:presentationPr \(namespaces)/>"

    private static let viewProperties = """
        <p:viewPr \(namespaces)><p:normalViewPr><p:restoredLeft sz="15620"/><p:restoredTop sz="94660"/>\
        </p:normalViewPr><p:gridSpacing cx="76200" cy="76200"/></p:viewPr>
        """

    private static let tableStyles = """
        <a:tblStyleLst xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        def="{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"/>
        """

    // MARK: - Theme

    private static let theme = """
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme">\
        <a:themeElements><a:clrScheme name="Office">\
        <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>\
        <a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>\
        <a:dk2><a:srgbClr val="0E2841"/></a:dk2><a:lt2><a:srgbClr val="E8E8E8"/></a:lt2>\
        <a:accent1><a:srgbClr val="156082"/></a:accent1><a:accent2><a:srgbClr val="E97132"/></a:accent2>\
        <a:accent3><a:srgbClr val="196B24"/></a:accent3><a:accent4><a:srgbClr val="0F9ED5"/></a:accent4>\
        <a:accent5><a:srgbClr val="A02B93"/></a:accent5><a:accent6><a:srgbClr val="4EA72E"/></a:accent6>\
        <a:hlink><a:srgbClr val="467886"/></a:hlink><a:folHlink><a:srgbClr val="96607D"/></a:folHlink>\
        </a:clrScheme>\
        <a:fontScheme name="Office"><a:majorFont><a:latin typeface="Aptos Display"/><a:ea typeface=""/>\
        <a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Aptos"/><a:ea typeface=""/>\
        <a:cs typeface=""/></a:minorFont></a:fontScheme>\
        <a:fmtScheme name="Office"><a:fillStyleLst>\
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
        <a:gradFill rotWithShape="1"><a:gsLst><a:gs pos="0"><a:schemeClr val="phClr"><a:lumMod val="110000"/>\
        <a:satMod val="105000"/><a:tint val="67000"/></a:schemeClr></a:gs><a:gs pos="100000">\
        <a:schemeClr val="phClr"><a:lumMod val="105000"/><a:satMod val="109000"/><a:tint val="81000"/>\
        </a:schemeClr></a:gs></a:gsLst><a:lin ang="5400000" scaled="0"/></a:gradFill>\
        <a:gradFill rotWithShape="1"><a:gsLst><a:gs pos="0"><a:schemeClr val="phClr"><a:satMod val="103000"/>\
        <a:lumMod val="102000"/><a:tint val="94000"/></a:schemeClr></a:gs><a:gs pos="100000">\
        <a:schemeClr val="phClr"><a:lumMod val="99000"/><a:satMod val="120000"/><a:shade val="78000"/>\
        </a:schemeClr></a:gs></a:gsLst><a:lin ang="5400000" scaled="0"/></a:gradFill>\
        </a:fillStyleLst><a:lnStyleLst>\
        <a:ln w="12700" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
        <a:prstDash val="solid"/><a:miter lim="800000"/></a:ln>\
        <a:ln w="19050" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
        <a:prstDash val="solid"/><a:miter lim="800000"/></a:ln>\
        <a:ln w="25400" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
        <a:prstDash val="solid"/><a:miter lim="800000"/></a:ln>\
        </a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle>\
        <a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst><a:outerShdw blurRad="57150" \
        dist="19050" dir="5400000" algn="ctr" rotWithShape="0"><a:srgbClr val="000000"><a:alpha val="63000"/>\
        </a:srgbClr></a:outerShdw></a:effectLst></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst>\
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
        <a:solidFill><a:schemeClr val="phClr"><a:tint val="95000"/><a:satMod val="170000"/></a:schemeClr></a:solidFill>\
        <a:gradFill rotWithShape="1"><a:gsLst><a:gs pos="0"><a:schemeClr val="phClr"><a:tint val="93000"/>\
        <a:satMod val="150000"/><a:shade val="98000"/><a:lumMod val="102000"/></a:schemeClr></a:gs>\
        <a:gs pos="100000"><a:schemeClr val="phClr"><a:shade val="63000"/><a:satMod val="120000"/></a:schemeClr>\
        </a:gs></a:gsLst><a:lin ang="5400000" scaled="0"/></a:gradFill>\
        </a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>
        """

    // MARK: - Master and layouts

    private static let groupProperties = """
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm>\
        <a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        """

    /// A placeholder as a layout or master declares it.
    private static func placeholder(
        id: Int, name: String, type: String?, index: Int? = nil, frame: EMURect?,
        bodyProperties: String = "<a:bodyPr/>", listStyle: String = "<a:lstStyle/>", prompt: String
    ) -> String {
        let typeAttribute = type.map { " type=\"\($0)\"" } ?? ""
        let indexAttribute = index.map { " idx=\"\($0)\"" } ?? ""
        let transform = frame.map {
            "<a:xfrm><a:off x=\"\($0.x)\" y=\"\($0.y)\"/><a:ext cx=\"\($0.width)\" cy=\"\($0.height)\"/></a:xfrm>"
        } ?? ""
        let geometry = frame == nil ? "" : "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>"
        return """
            <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="\(name)"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>\
            <p:nvPr><p:ph\(typeAttribute)\(indexAttribute)/></p:nvPr></p:nvSpPr><p:spPr>\(transform)\(geometry)</p:spPr>\
            <p:txBody>\(bodyProperties)\(listStyle)<a:p><a:r><a:rPr lang="en-US"/><a:t>\(prompt)</a:t></a:r>\
            <a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp>
            """
    }

    private static let master: String = {
        let bullet = "<a:buFont typeface=\"Arial\" panose=\"020B0604020202020204\"/><a:buChar char=\"•\"/>"
        let bodyLevels = [(2800, 228_600), (2400, 685_800), (2000, 1_143_000), (1800, 1_600_200), (1800, 2_057_400)]
            .enumerated().map { index, level in
                """
                <a:lvl\(index + 1)pPr marL="\(level.1)" indent="-228600" algn="l" defTabSz="914400" rtl="0" \
                eaLnBrk="1" latinLnBrk="0" hangingPunct="1"><a:lnSpc><a:spcPct val="90000"/></a:lnSpc>\
                <a:spcBef><a:spcPts val="\(index == 0 ? 1000 : 500)"/></a:spcBef>\(bullet)\
                <a:defRPr sz="\(level.0)" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>\
                <a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl\(index + 1)pPr>
                """
            }.joined()
        let footer = "<a:bodyPr vert=\"horz\" lIns=\"91440\" tIns=\"45720\" rIns=\"91440\" bIns=\"45720\" rtlCol=\"0\" anchor=\"ctr\"/>"
        func footerStyle(_ alignment: String) -> String {
            "<a:lstStyle><a:lvl1pPr algn=\"\(alignment)\"><a:defRPr sz=\"1200\"><a:solidFill><a:schemeClr val=\"tx1\">"
                + "<a:tint val=\"82000\"/></a:schemeClr></a:solidFill></a:defRPr></a:lvl1pPr></a:lstStyle>"
        }
        let shapes = [
            placeholder(
                id: 2, name: "Title Placeholder 1", type: "title",
                frame: EMURect(x: 838_200, y: 365_125, width: 10_515_600, height: 1_325_563),
                bodyProperties: "<a:bodyPr vert=\"horz\" lIns=\"91440\" tIns=\"45720\" rIns=\"91440\" bIns=\"45720\" rtlCol=\"0\" anchor=\"ctr\"><a:normAutofit/></a:bodyPr>",
                prompt: "Click to edit Master title style"
            ),
            placeholder(
                id: 3, name: "Text Placeholder 2", type: "body", index: 1,
                frame: EMURect(x: 838_200, y: 1_825_625, width: 10_515_600, height: 4_351_338),
                bodyProperties: "<a:bodyPr vert=\"horz\" lIns=\"91440\" tIns=\"45720\" rIns=\"91440\" bIns=\"45720\" rtlCol=\"0\"><a:normAutofit/></a:bodyPr>",
                prompt: "Click to edit Master text styles"
            ),
            placeholder(
                id: 4, name: "Date Placeholder 3", type: "dt", index: 2,
                frame: EMURect(x: 838_200, y: 6_356_350, width: 2_743_200, height: 365_125),
                bodyProperties: footer, listStyle: footerStyle("l"), prompt: ""
            ),
            placeholder(
                id: 5, name: "Footer Placeholder 4", type: "ftr", index: 3,
                frame: EMURect(x: 4_038_600, y: 6_356_350, width: 4_114_800, height: 365_125),
                bodyProperties: footer, listStyle: footerStyle("ctr"), prompt: ""
            ),
            placeholder(
                id: 6, name: "Slide Number Placeholder 5", type: "sldNum", index: 4,
                frame: EMURect(x: 8_610_600, y: 6_356_350, width: 2_743_200, height: 365_125),
                bodyProperties: footer, listStyle: footerStyle("r"), prompt: ""
            ),
        ].joined()
        let layoutIDs = layouts.indices.map {
            "<p:sldLayoutId id=\"\(2_147_483_649 + $0)\" r:id=\"rId\($0 + 1)\"/>"
        }.joined()
        return """
            <p:sldMaster \(namespaces)><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>\
            <p:spTree>\(groupProperties)\(shapes)</p:spTree></p:cSld>\
            <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" \
            accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
            <p:sldLayoutIdLst>\(layoutIDs)</p:sldLayoutIdLst>\
            <p:txStyles><p:titleStyle><a:lvl1pPr algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" \
            hangingPunct="1"><a:lnSpc><a:spcPct val="90000"/></a:lnSpc><a:spcBef><a:spcPct val="0"/></a:spcBef>\
            <a:buNone/><a:defRPr sz="4400" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>\
            <a:latin typeface="+mj-lt"/><a:ea typeface="+mj-ea"/><a:cs typeface="+mj-cs"/></a:defRPr></a:lvl1pPr>\
            </p:titleStyle><p:bodyStyle>\(bodyLevels)</p:bodyStyle><p:otherStyle><a:defPPr><a:defRPr lang="en-US"/>\
            </a:defPPr><a:lvl1pPr marL="0" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" \
            hangingPunct="1"><a:defRPr sz="1800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>\
            <a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl1pPr>\
            </p:otherStyle></p:txStyles></p:sldMaster>
            """
    }()

    private static var masterRelationships: String {
        relationships(
            layouts.indices.map { (layout, "../slideLayouts/slideLayout\($0 + 1).xml") }
                + [(OOXML.RelationshipType.theme, "../theme/theme1.xml")]
        )
    }

    private static func layoutPart(name: String, type: String, shapes: [String]) -> String {
        """
        <p:sldLayout \(namespaces) type="\(type)" preserve="1"><p:cSld name="\(name)"><p:spTree>\
        \(groupProperties)\(shapes.joined())</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>\
        </p:sldLayout>
        """
    }

    private static func centeredNoBullet(_ size: Int) -> String {
        "<a:lstStyle><a:lvl1pPr marL=\"0\" indent=\"0\" algn=\"ctr\"><a:buNone/><a:defRPr sz=\"\(size)\"/></a:lvl1pPr></a:lstStyle>"
    }

    private static let layouts: [String] = [
        layoutPart(name: "Title Slide", type: "title", shapes: [
            placeholder(
                id: 2, name: "Title 1", type: "ctrTitle",
                frame: EMURect(x: 1_524_000, y: 1_122_363, width: 9_144_000, height: 2_387_600),
                bodyProperties: "<a:bodyPr anchor=\"b\"/>",
                listStyle: "<a:lstStyle><a:lvl1pPr algn=\"ctr\"><a:defRPr sz=\"6000\"/></a:lvl1pPr></a:lstStyle>",
                prompt: "Click to edit Master title style"
            ),
            placeholder(
                id: 3, name: "Subtitle 2", type: "subTitle", index: 1,
                frame: EMURect(x: 1_524_000, y: 3_602_038, width: 9_144_000, height: 1_655_762),
                listStyle: centeredNoBullet(2400), prompt: "Click to edit Master subtitle style"
            ),
        ]),
        layoutPart(name: "Title and Content", type: "obj", shapes: [
            placeholder(id: 2, name: "Title 1", type: "title", frame: nil, prompt: "Click to edit Master title style"),
            placeholder(id: 3, name: "Content Placeholder 2", type: nil, index: 1, frame: nil, prompt: "Click to edit Master text styles"),
        ]),
        layoutPart(name: "Section Header", type: "secHead", shapes: [
            placeholder(
                id: 2, name: "Title 1", type: "title",
                frame: EMURect(x: 831_850, y: 1_709_738, width: 10_515_600, height: 2_852_737),
                bodyProperties: "<a:bodyPr anchor=\"b\"/>",
                listStyle: "<a:lstStyle><a:lvl1pPr><a:defRPr sz=\"6000\"/></a:lvl1pPr></a:lstStyle>",
                prompt: "Click to edit Master title style"
            ),
            placeholder(
                id: 3, name: "Text Placeholder 2", type: "body", index: 1,
                frame: EMURect(x: 831_850, y: 4_589_463, width: 10_515_600, height: 1_500_187),
                listStyle: "<a:lstStyle><a:lvl1pPr marL=\"0\" indent=\"0\"><a:buNone/><a:defRPr sz=\"2400\">"
                    + "<a:solidFill><a:schemeClr val=\"tx1\"><a:tint val=\"82000\"/></a:schemeClr></a:solidFill>"
                    + "</a:defRPr></a:lvl1pPr></a:lstStyle>",
                prompt: "Click to edit Master text styles"
            ),
        ]),
        layoutPart(name: "Title Only", type: "titleOnly", shapes: [
            placeholder(id: 2, name: "Title 1", type: "title", frame: nil, prompt: "Click to edit Master title style"),
        ]),
        layoutPart(name: "Blank", type: "blank", shapes: []),
    ]

    // MARK: - First slide

    private static let firstSlide = """
        <p:sld \(namespaces)><p:cSld><p:spTree>\(groupProperties)\
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>\
        <p:nvPr><p:ph type="ctrTitle"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>\
        <a:p><a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp>\
        <p:sp><p:nvSpPr><p:cNvPr id="3" name="Subtitle 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>\
        <p:nvPr><p:ph type="subTitle" idx="1"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>\
        <a:p><a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp>\
        </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
        """
}
