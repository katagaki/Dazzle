import Foundation

/// Reads a slide's animations from its `p:timing`, and writes them back.
///
/// PowerPoint keeps the animations a slide plays as it is clicked through in
/// its main sequence: a group per click, in each a group per run of effects
/// that start together, and in those the effects. Everything else in the
/// timing — effects a shape's click sets off, the nodes that play media — is
/// left as it was, but for whatever pointed at a shape that is gone.
enum AnimationXML {
    // MARK: - Reading

    /// The effects in a slide's main sequence, in the order they play.
    static func animations(in timing: XMLElement) -> [ShapeAnimation] {
        guard let sequence = mainSequence(in: timing),
              let groups = sequence.firstDescendant(atPath: "cTn/childTnLst")?.children(named: "par") else { return [] }
        var result: [ShapeAnimation] = []
        for (groupIndex, group) in groups.enumerated() {
            let groupNode = group.firstChild(named: "cTn")
            // The first group starts with the slide when it waits on the sequence beginning, not a click.
            let startsWithSlide = groupIndex == 0 && (groupNode?.firstChild(named: "stCondLst")?.children(named: "cond")
                .contains { $0.attribute("evt") == "onBegin" } ?? false)
            let runs = groupNode?.firstChild(named: "childTnLst")?.children(named: "par") ?? []
            for (runIndex, run) in runs.enumerated() {
                let effects = run.firstDescendant(atPath: "cTn/childTnLst")?.children(named: "par") ?? []
                for (effectIndex, effect) in effects.enumerated() {
                    let trigger: ShapeAnimation.Trigger = if effectIndex > 0 {
                        .withPrevious
                    } else if runIndex > 0 {
                        .afterPrevious
                    } else if startsWithSlide {
                        // Either way it starts with the slide; the file says which it was chosen as.
                        effect.firstChild(named: "cTn")?.attribute("nodeType") == "afterEffect" ? .afterPrevious : .withPrevious
                    } else {
                        .onClick
                    }
                    if let animation = animation(from: effect, trigger: trigger) { result.append(animation) }
                }
            }
        }
        return result
    }

    private static func animation(from par: XMLElement, trigger: ShapeAnimation.Trigger) -> ShapeAnimation? {
        guard let node = par.firstChild(named: "cTn"),
              let target = firstElement(named: "spTgt", in: node),
              let shapeID = target.attribute("spid").flatMap(Int.init) else { return nil }
        var paragraphs: ClosedRange<Int>?
        if let range = target.firstDescendant(atPath: "txEl/pRg"),
           let start = range.attribute("st").flatMap(Int.init), let end = range.attribute("end").flatMap(Int.init) {
            paragraphs = min(start, end)...max(start, end)
        }
        let category = ShapeAnimation.Category(presetClass: node.attribute("presetClass"))
        let presetID = node.attribute("presetID").flatMap(Int.init) ?? 0
        let subtype = node.attribute("presetSubtype").flatMap(Int.init) ?? 0
        var effect = Self.effect(category: category, presetID: presetID, subtype: subtype)
        if category == .motionPath, let path = firstElement(named: "animMotion", in: node)?.attribute("path") {
            effect = .path(MotionPath(path: path))
        }
        return ShapeAnimation(
            shapeID: shapeID, paragraphs: paragraphs, category: category, effect: effect, trigger: trigger,
            duration: duration(of: node), delay: milliseconds(delay(of: node)) ?? 0,
            source: XMLLite.serialize(par)
        )
    }

    private static func effect(category: ShapeAnimation.Category, presetID: Int, subtype: Int) -> ShapeAnimation.Effect {
        let direction = ShapeAnimation.Direction(rawValue: subtype) ?? .bottom
        switch (category, presetID) {
        case (.entrance, 1), (.exit, 1): return .appear
        case (.entrance, 2), (.exit, 2): return .fly(direction)
        case (.entrance, 10), (.exit, 10): return .fade
        case (.entrance, 22), (.exit, 22): return .wipe(direction)
        case (.entrance, 42), (.exit, 42): return .float
        case (.entrance, 53), (.exit, 53): return .zoom
        case (.emphasis, 6): return .growShrink
        case (.emphasis, 8): return .spin
        case (.emphasis, 26): return .pulse
        case (.emphasis, 32): return .teeter
        default: return .preset(id: presetID, subtype: subtype)
        }
    }

    /// How long an effect runs, in seconds: until its last behaviour ends.
    private static func duration(of node: XMLElement) -> Double {
        var end = 0.0
        func visit(_ element: XMLElement) {
            if element.name == "cBhvr", let timing = element.firstChild(named: "cTn") {
                let length = milliseconds(timing.attribute("dur")) ?? 0
                // Repeats are counted in thousandths.
                let repeats = milliseconds(timing.attribute("repeatCount")) ?? 1
                let reverses = timing.attribute("autoRev") == "1" ? 2.0 : 1
                end = max(end, (milliseconds(delay(of: timing)) ?? 0) + length * repeats * reverses)
            }
            element.children.forEach(visit)
        }
        visit(node)
        // A behaviour a millisecond long, such as becoming visible, is instant.
        return end < 0.01 ? 0 : end
    }

    private static func delay(of node: XMLElement) -> String? {
        node.firstChild(named: "stCondLst")?.children(named: "cond").first { $0.attribute("evt") == nil }?.attribute("delay")
    }

    /// A time attribute in seconds; `nil` for one that never comes, such as `indefinite`.
    private static func milliseconds(_ value: String?) -> Double? {
        value.flatMap(Double.init).map { $0 / 1_000 }
    }

    private static func mainSequence(in timing: XMLElement) -> XMLElement? {
        firstElement(named: "seq", in: timing) { $0.firstChild(named: "cTn")?.attribute("nodeType") == "mainSeq" }
    }

    private static func firstElement(
        named name: String, in element: XMLElement, where matches: (XMLElement) -> Bool = { _ in true }
    ) -> XMLElement? {
        for child in element.children {
            if child.name == name, matches(child) { return child }
            if let found = firstElement(named: name, in: child, where: matches) { return found }
        }
        return nil
    }

    // MARK: - Writing

    /// Puts `animations` in the slide's main sequence, making a timing for
    /// it if there is none and removing one left with nothing to do. Effects
    /// on shapes no longer on the slide are left out, and so is anything else
    /// in the timing that pointed at one.
    static func write(_ animations: [ShapeAnimation], shapes: [SlideShape], into root: XMLElement) {
        let shapeIDs = Set(shapes.map(\.shapeID))
        let animations = animations.filter { shapeIDs.contains($0.shapeID) }
        var timing = root.firstChild(named: "timing")
        if timing == nil {
            guard !animations.isEmpty, let created = XMLLite.fragment(Self.emptyTiming, namespaces: OOXML.namespaces) else { return }
            // After the slide's transition; before its extensions.
            let after = root.children.lastIndex { ["cSld", "clrMapOvr", "transition", "AlternateContent"].contains($0.name) }
            root.insertChild(created, at: (after ?? 0) + 1)
            timing = created
        }
        guard let timing, let rootList = timing.firstDescendant(atPath: "tnLst/par/cTn/childTnLst") else { return }

        // Whatever else the timing does, it cannot do to a shape that is gone.
        for child in rootList.children where !isMainSequence(child) && !targets(of: child).isSubset(of: shapeIDs) {
            rootList.removeChild(child)
        }

        var nextID = (allNodeIDs(in: timing).max() ?? 2) + 1
        let existing = rootList.children.first(where: isMainSequence)
        if animations.isEmpty {
            if let existing { rootList.removeChild(existing) }
        } else {
            let sequence = existing ?? {
                let created = XMLLite.fragment(sequenceXML(id: nextID), namespaces: OOXML.namespaces)
                nextID += 1
                if let created { rootList.insertChild(created, at: 0) }
                return created
            }()
            if let sequence, let node = sequence.firstChild(named: "cTn") {
                let sequenceID = node.attribute("id") ?? "2"
                node.firstChild(named: "childTnLst").map(node.removeChild)
                let groups = groupsXML(animations, sequenceID: sequenceID, nextID: &nextID)
                if let list = XMLLite.fragment("<p:childTnLst>\(groups)</p:childTnLst>", namespaces: OOXML.namespaces) {
                    let after = node.children.lastIndex { ["stCondLst", "endCondLst", "endSync", "iterate"].contains($0.name) }
                    node.insertChild(list, at: (after ?? -1) + 1)
                }
            }
        }

        if rootList.children.isEmpty {
            root.removeChild(timing)
            return
        }
        writeBuilds(for: animations, shapes: shapes, into: timing)
    }

    /// The effects, grouped by the click that starts them and the runs
    /// that start together, as PowerPoint nests them.
    private static func groupsXML(_ animations: [ShapeAnimation], sequenceID: String, nextID: inout Int) -> String {
        let timeline = AnimationTimeline(animations: animations)
        var xml = ""
        for (stepIndex, step) in timeline.steps.enumerated() {
            var runs: [(start: Double, entries: [AnimationTimeline.Entry])] = []
            for entry in step {
                if runs.isEmpty || entry.animation.trigger == .afterPrevious {
                    runs.append((entry.start - entry.animation.delay, []))
                }
                runs[runs.count - 1].entries.append(entry)
            }
            let startsWithSlide = stepIndex == 0 && timeline.startsAutomatically
            let condition = startsWithSlide
                ? "<p:cond delay=\"indefinite\"/><p:cond evt=\"onBegin\" delay=\"0\"><p:tn val=\"\(sequenceID)\"/></p:cond>"
                : "<p:cond delay=\"indefinite\"/>"
            xml += "<p:par><p:cTn id=\"\(take(&nextID))\" fill=\"hold\"><p:stCondLst>\(condition)</p:stCondLst><p:childTnLst>"
            for run in runs {
                xml += "<p:par><p:cTn id=\"\(take(&nextID))\" fill=\"hold\"><p:stCondLst><p:cond delay=\"\(ms(run.start))\"/></p:stCondLst><p:childTnLst>"
                for entry in run.entries {
                    xml += effectXML(entry.animation, nodeType: nodeType(of: entry.animation), nextID: &nextID)
                }
                xml += "</p:childTnLst></p:cTn></p:par>"
            }
            xml += "</p:childTnLst></p:cTn></p:par>"
        }
        return xml
    }

    private static func nodeType(of animation: ShapeAnimation) -> String {
        switch animation.trigger {
        case .onClick: "clickEffect"
        case .withPrevious: "withEffect"
        case .afterPrevious: "afterEffect"
        }
    }

    /// One effect's `p:par`: as read, retimed, if it has not changed; made
    /// anew if it has.
    private static func effectXML(_ animation: ShapeAnimation, nodeType: String, nextID: inout Int) -> String {
        if let source = animation.source, let par = XMLLite.fragment(source, namespaces: OOXML.namespaces),
           let node = par.firstChild(named: "cTn") {
            node.setAttribute("nodeType", nodeType)
            if let condition = node.firstChild(named: "stCondLst")?.children(named: "cond").first(where: { $0.attribute("evt") == nil }) {
                condition.setAttribute("delay", ms(animation.delay))
            }
            if let xml = XMLLite.serialize(par, inheritedNamespaces: OOXML.namespaces) { return xml }
        }
        let category = animation.category
        let id = take(&nextID)
        let behaviours = behavioursXML(animation, nextID: &nextID)
        return """
            <p:par><p:cTn id="\(id)" presetID="\(animation.effect.presetID)" presetClass="\(category.presetClass)" \
            presetSubtype="\(animation.effect.presetSubtype)" fill="hold" grpId="0" \
            nodeType="\(nodeType)"><p:stCondLst><p:cond delay="\(ms(animation.delay))"/></p:stCondLst>\
            <p:childTnLst>\(behaviours)</p:childTnLst></p:cTn></p:par>
            """
    }

    /// What the effect does, in the behaviours PowerPoint uses for it.
    private static func behavioursXML(_ animation: ShapeAnimation, nextID: inout Int) -> String {
        var target = "<p:spTgt spid=\"\(animation.shapeID)\"/>"
        if let paragraphs = animation.paragraphs {
            target = "<p:spTgt spid=\"\(animation.shapeID)\"><p:txEl><p:pRg st=\"\(paragraphs.lowerBound)\" end=\"\(paragraphs.upperBound)\"/></p:txEl></p:spTgt>"
        }
        let duration = max(animation.duration, 0.001)
        let isEntrance = animation.category == .entrance

        func behaviour(_ name: String, attributes: String = "", additive: String = "", dur: Double, delay: Double = 0,
                       extra: String = "", attribute: [String] = [], content: String = "") -> String {
            let condition = delay > 0 ? "<p:stCondLst><p:cond delay=\"\(ms(delay))\"/></p:stCondLst>" : ""
            let names = attribute.isEmpty ? "" : "<p:attrNameLst>" + attribute.map { "<p:attrName>\($0)</p:attrName>" }.joined() + "</p:attrNameLst>"
            let timing = condition.isEmpty
                ? "<p:cTn id=\"\(take(&nextID))\" dur=\"\(ms(dur))\"\(extra)/>"
                : "<p:cTn id=\"\(take(&nextID))\" dur=\"\(ms(dur))\"\(extra)>\(condition)</p:cTn>"
            return "<p:\(name)\(attributes)><p:cBhvr\(additive)>\(timing)<p:tgtEl>\(target)</p:tgtEl>\(names)</p:cBhvr>\(content)</p:\(name)>"
        }
        func visibility(_ value: String, at delay: Double = 0) -> String {
            behaviour("set", dur: 0.001, delay: delay, extra: " fill=\"hold\"", attribute: ["style.visibility"],
                      content: "<p:to><p:strVal val=\"\(value)\"/></p:to>")
        }
        func fade(_ transition: String, filter: String = "fade") -> String {
            behaviour("animEffect", attributes: " transition=\"\(transition)\" filter=\"\(filter)\"", dur: duration)
        }
        func move(_ attribute: String, from: String, to: String) -> String {
            behaviour(
                "anim", attributes: " calcmode=\"lin\" valueType=\"num\"", additive: " additive=\"base\"", dur: duration,
                extra: " fill=\"hold\"", attribute: [attribute],
                content: "<p:tavLst><p:tav tm=\"0\"><p:val><p:strVal val=\"\(from)\"/></p:val></p:tav>"
                    + "<p:tav tm=\"100000\"><p:val><p:strVal val=\"\(to)\"/></p:val></p:tav></p:tavLst>"
            )
        }
        func flight(_ direction: ShapeAnimation.Direction) -> String {
            let away = switch direction {
            case .top: ("ppt_y", "0-#ppt_h/2")
            case .bottom: ("ppt_y", "1+#ppt_h/2")
            case .left: ("ppt_x", "0-#ppt_w/2")
            case .right: ("ppt_x", "1+#ppt_w/2")
            }
            let still = away.0 == "ppt_x" ? "ppt_y" : "ppt_x"
            return isEntrance
                ? move(still, from: "#\(still)", to: "#\(still)") + move(away.0, from: away.1, to: "#\(away.0)")
                : move(still, from: "#\(still)", to: "#\(still)") + move(away.0, from: "#\(away.0)", to: away.1)
        }
        func wipeFilter(_ direction: ShapeAnimation.Direction) -> String {
            switch direction {
            case .top: "wipe(down)"
            case .bottom: "wipe(up)"
            case .left: "wipe(right)"
            case .right: "wipe(left)"
            }
        }
        func size(from: String, to: String) -> String {
            move("ppt_w", from: from, to: to) + move("ppt_h", from: from == "0" ? "0" : "#ppt_h", to: to == "0" ? "0" : "#ppt_h")
        }

        switch (animation.category, animation.effect) {
        case (.entrance, .appear):
            return visibility("visible")
        case (.entrance, .fade):
            return visibility("visible") + fade("in")
        case (.entrance, .fly(let direction)):
            return visibility("visible") + flight(direction)
        case (.entrance, .wipe(let direction)):
            return visibility("visible") + fade("in", filter: wipeFilter(direction))
        case (.entrance, .zoom):
            return visibility("visible") + size(from: "0", to: "#ppt_w") + fade("in")
        case (.entrance, .float):
            return visibility("visible") + fade("in") + move("ppt_x", from: "#ppt_x", to: "#ppt_x")
                + move("ppt_y", from: "#ppt_y+.1", to: "#ppt_y")
        case (.exit, .appear):
            return visibility("hidden")
        case (.exit, .fade):
            return fade("out") + visibility("hidden", at: duration - 0.001)
        case (.exit, .fly(let direction)):
            return flight(direction) + visibility("hidden", at: duration - 0.001)
        case (.exit, .wipe(let direction)):
            return fade("out", filter: wipeFilter(direction)) + visibility("hidden", at: duration - 0.001)
        case (.exit, .zoom):
            return size(from: "#ppt_w", to: "0") + fade("out") + visibility("hidden", at: duration - 0.001)
        case (.exit, .float):
            return fade("out") + move("ppt_x", from: "#ppt_x", to: "#ppt_x") + move("ppt_y", from: "#ppt_y", to: "#ppt_y-.1")
                + visibility("hidden", at: duration - 0.001)
        case (.emphasis, .pulse):
            return behaviour("animScale", dur: duration / 2, extra: " autoRev=\"1\" fill=\"hold\"",
                             content: "<p:by x=\"105000\" y=\"105000\"/>")
        case (.emphasis, .spin):
            return behaviour("animRot", attributes: " by=\"21600000\"", dur: duration, extra: " fill=\"hold\"", attribute: ["r"])
        case (.emphasis, .growShrink):
            return behaviour("animScale", dur: duration, extra: " fill=\"hold\"", content: "<p:by x=\"150000\" y=\"150000\"/>")
        case (.emphasis, .teeter):
            var start = 0.0
            return Teeter.swings.map { swing in
                defer { start += swing.share }
                return behaviour("animRot", attributes: " by=\"\(Int(swing.degrees * 60_000))\"", dur: duration * swing.share,
                                 delay: duration * start, extra: " fill=\"hold\"", attribute: ["r"])
            }.joined()
        case (.motionPath, .path(let path)):
            return behaviour(
                "animMotion", attributes: " origin=\"layout\" path=\"\(XMLLite.escape(path.path))\" pathEditMode=\"relative\" ptsTypes=\"\"",
                dur: duration, extra: " fill=\"hold\"", attribute: ["ppt_x", "ppt_y"]
            )
        default:
            // Nothing Dazzle makes; shown as it fades, so written as one.
            return animation.category == .exit ? fade("out") + visibility("hidden", at: duration - 0.001)
                : visibility("visible") + fade("in")
        }
    }

    /// The build list, which ties each text shape to its effects: one entry
    /// per animated shape with text, none for shapes no longer animated.
    private static func writeBuilds(for animations: [ShapeAnimation], shapes: [SlideShape], into timing: XMLElement) {
        let textShapes = Set(shapes.filter { $0.canHoldText && $0.text != nil }.map(\.shapeID))
        let animated = Set(animations.map(\.shapeID))
        let referenced = targets(of: timing.firstChild(named: "tnLst") ?? timing)
        let list = timing.firstChild(named: "bldLst")
        for build in list?.children ?? [] {
            if let id = build.attribute("spid").flatMap(Int.init), !referenced.contains(id) { list?.removeChild(build) }
        }
        let built = Set(list?.children.compactMap { $0.attribute("spid").flatMap(Int.init) } ?? [])
        let needed = shapes.map(\.shapeID).filter { animated.contains($0) && textShapes.contains($0) && !built.contains($0) }
        guard !needed.isEmpty else {
            if let list, list.children.isEmpty { timing.removeChild(list) }
            return
        }
        let target = list ?? {
            let created = XMLLite.fragment("<p:bldLst/>", namespaces: OOXML.namespaces)
            if let created { timing.insertChild(created, at: timing.children.count) }
            return created
        }()
        for id in needed {
            let byParagraph = animations.contains { $0.shapeID == id && $0.paragraphs != nil }
            let xml = byParagraph ? "<p:bldP spid=\"\(id)\" grpId=\"0\" build=\"p\"/>" : "<p:bldP spid=\"\(id)\" grpId=\"0\" animBg=\"1\"/>"
            if let build = XMLLite.fragment(xml, namespaces: OOXML.namespaces) {
                target?.insertChild(build, at: target?.children.count ?? 0)
            }
        }
    }

    // MARK: - Helpers

    private static let emptyTiming = """
        <p:timing><p:tnLst><p:par><p:cTn id="1" dur="indefinite" restart="never" nodeType="tmRoot"><p:childTnLst/>\
        </p:cTn></p:par></p:tnLst></p:timing>
        """

    private static func sequenceXML(id: Int) -> String {
        """
        <p:seq concurrent="1" nextAc="seek"><p:cTn id="\(id)" dur="indefinite" nodeType="mainSeq"/>\
        <p:prevCondLst><p:cond evt="onPrev" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:prevCondLst>\
        <p:nextCondLst><p:cond evt="onNext" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:nextCondLst></p:seq>
        """
    }

    private static func isMainSequence(_ element: XMLElement) -> Bool {
        element.name == "seq" && element.firstChild(named: "cTn")?.attribute("nodeType") == "mainSeq"
    }

    /// Every shape a part of the timing points at.
    private static func targets(of element: XMLElement) -> Set<Int> {
        var result: Set<Int> = []
        func visit(_ element: XMLElement) {
            if element.name == "spTgt", let id = element.attribute("spid").flatMap(Int.init) { result.insert(id) }
            element.children.forEach(visit)
        }
        visit(element)
        return result
    }

    private static func allNodeIDs(in element: XMLElement) -> [Int] {
        var result: [Int] = []
        func visit(_ element: XMLElement) {
            if element.name == "cTn", let id = element.attribute("id").flatMap(Int.init) { result.append(id) }
            element.children.forEach(visit)
        }
        visit(element)
        return result
    }

    private static func take(_ id: inout Int) -> Int {
        defer { id += 1 }
        return id
    }

    private static func ms(_ seconds: Double) -> String {
        String(max(Int((seconds * 1_000).rounded()), 0))
    }
}
