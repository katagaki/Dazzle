import CoreGraphics
import Foundation
import Testing
@testable import Dazzle

@Suite("Animations")
struct AnimationTests {
    private func reread(_ presentation: Presentation) throws -> Presentation {
        try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
    }

    /// The main sequence PowerPoint writes for: title fades in on a click,
    /// then the body's second and third paragraphs fly in from the left after it.
    private static let powerPointTiming = """
        <p:timing xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:tnLst><p:par>\
        <p:cTn id="1" dur="indefinite" restart="never" nodeType="tmRoot"><p:childTnLst>\
        <p:seq concurrent="1" nextAc="seek"><p:cTn id="2" dur="indefinite" nodeType="mainSeq"><p:childTnLst>\
        <p:par><p:cTn id="3" fill="hold"><p:stCondLst><p:cond delay="indefinite"/></p:stCondLst><p:childTnLst>\
        <p:par><p:cTn id="4" fill="hold"><p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>\
        <p:par><p:cTn id="5" presetID="10" presetClass="entr" presetSubtype="0" fill="hold" grpId="0" nodeType="clickEffect">\
        <p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>\
        <p:set><p:cBhvr><p:cTn id="6" dur="1" fill="hold"><p:stCondLst><p:cond delay="0"/></p:stCondLst></p:cTn>\
        <p:tgtEl><p:spTgt spid="2"/></p:tgtEl><p:attrNameLst><p:attrName>style.visibility</p:attrName></p:attrNameLst></p:cBhvr>\
        <p:to><p:strVal val="visible"/></p:to></p:set>\
        <p:animEffect transition="in" filter="fade"><p:cBhvr><p:cTn id="7" dur="750"/><p:tgtEl><p:spTgt spid="2"/></p:tgtEl></p:cBhvr></p:animEffect>\
        </p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn></p:par>\
        <p:par><p:cTn id="8" fill="hold"><p:stCondLst><p:cond delay="750"/></p:stCondLst><p:childTnLst>\
        <p:par><p:cTn id="9" presetID="2" presetClass="entr" presetSubtype="8" fill="hold" grpId="0" nodeType="afterEffect">\
        <p:stCondLst><p:cond delay="250"/></p:stCondLst><p:childTnLst>\
        <p:set><p:cBhvr><p:cTn id="10" dur="1" fill="hold"><p:stCondLst><p:cond delay="0"/></p:stCondLst></p:cTn>\
        <p:tgtEl><p:spTgt spid="3"><p:txEl><p:pRg st="1" end="2"/></p:txEl></p:spTgt></p:tgtEl>\
        <p:attrNameLst><p:attrName>style.visibility</p:attrName></p:attrNameLst></p:cBhvr><p:to><p:strVal val="visible"/></p:to></p:set>\
        <p:anim calcmode="lin" valueType="num"><p:cBhvr additive="base"><p:cTn id="11" dur="500" fill="hold"/>\
        <p:tgtEl><p:spTgt spid="3"><p:txEl><p:pRg st="1" end="2"/></p:txEl></p:spTgt></p:tgtEl>\
        <p:attrNameLst><p:attrName>ppt_x</p:attrName></p:attrNameLst></p:cBhvr><p:tavLst>\
        <p:tav tm="0"><p:val><p:strVal val="0-#ppt_w/2"/></p:val></p:tav><p:tav tm="100000"><p:val><p:strVal val="#ppt_x"/></p:val></p:tav>\
        </p:tavLst></p:anim></p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn></p:par>\
        </p:childTnLst></p:cTn></p:par>\
        </p:childTnLst></p:cTn><p:prevCondLst><p:cond evt="onPrev" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:prevCondLst>\
        <p:nextCondLst><p:cond evt="onNext" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:nextCondLst></p:seq>\
        </p:childTnLst></p:cTn></p:par></p:tnLst>\
        <p:bldLst><p:bldP spid="2" grpId="0"/><p:bldP spid="3" grpId="0" build="p"/></p:bldLst></p:timing>
        """

    @Test("PowerPoint's main sequence reads as effects, triggers and timings")
    func readsMainSequence() throws {
        let timing = try XMLLite.parse(Data(Self.powerPointTiming.utf8))
        let animations = AnimationXML.animations(in: timing)
        #expect(animations.count == 2)
        let fade = animations[0]
        #expect(fade.shapeID == 2)
        #expect(fade.category == .entrance)
        #expect(fade.effect == .fade)
        #expect(fade.trigger == .onClick)
        #expect(abs(fade.duration - 0.75) < 0.001)
        #expect(fade.paragraphs == nil)
        let fly = animations[1]
        #expect(fly.shapeID == 3)
        #expect(fly.effect == .fly(.left))
        #expect(fly.trigger == .afterPrevious)
        #expect(abs(fly.delay - 0.25) < 0.001)
        #expect(abs(fly.duration - 0.5) < 0.001)
        #expect(fly.paragraphs == 1...2)
        #expect(fly.source != nil)
    }

    @Test("Effects that start together, or one after another, share a tap")
    func timeline() {
        let animations = [
            ShapeAnimation(shapeID: 2, category: .entrance, effect: .fade, trigger: .withPrevious, duration: 1),
            ShapeAnimation(shapeID: 3, category: .entrance, effect: .appear, trigger: .onClick),
            ShapeAnimation(shapeID: 4, category: .entrance, effect: .fade, trigger: .withPrevious, duration: 0.5, delay: 0.25),
            ShapeAnimation(shapeID: 5, category: .exit, effect: .fade, trigger: .afterPrevious, duration: 1),
        ]
        let timeline = AnimationTimeline(animations: animations)
        #expect(timeline.startsAutomatically)
        #expect(timeline.steps.count == 2)
        #expect(timeline.tapCount == 1)
        #expect(timeline.tapNumber(of: animations[0].id) == nil)
        #expect(timeline.tapNumber(of: animations[3].id) == 1)
        // The exit waits for the fade before it, which ends at 0.75s.
        #expect(abs(timeline.duration(ofStep: 1) - 1.75) < 0.001)
    }

    @Test("Shapes coming in are hidden until their step, and gone after going out")
    func frames() {
        let shapes = [2, 3].map { SlideShape(shapeID: $0, name: "", kind: .shape, frame: EMURect(x: 0, y: 0, width: 127_000, height: 127_000)) }
        let animations = [
            ShapeAnimation(shapeID: 2, category: .entrance, effect: .fade, duration: 1),
            ShapeAnimation(shapeID: 3, category: .exit, effect: .appear),
        ]
        let timeline = AnimationTimeline(animations: animations)
        let size = CGSize(width: 960, height: 540)
        let before = timeline.frame(begun: 0, elapsed: 0, shapes: shapes, slideSize: size)
        #expect(before.shapes[2]?.opacity == 0)
        #expect(before.shapes[3] == nil)
        let midway = timeline.frame(begun: 1, elapsed: 0.5, shapes: shapes, slideSize: size)
        #expect(abs((midway.shapes[2]?.opacity ?? 0) - 0.5) < 0.001)
        let after = timeline.frame(begun: 2, elapsed: 10, shapes: shapes, slideSize: size)
        #expect(after.shapes[2] == nil)
        #expect(after.shapes[3]?.opacity == 0)
    }

    @Test("Added animations are written and read back")
    func roundTrip() throws {
        var presentation = Presentation.blank
        let title = presentation.slides[0].shapes[0].shapeID
        let subtitle = presentation.slides[0].shapes[1].shapeID
        presentation.slides[0].animations = [
            ShapeAnimation(shapeID: title, category: .entrance, effect: .wipe(.left), trigger: .withPrevious, duration: 0.75),
            ShapeAnimation(shapeID: subtitle, category: .emphasis, effect: .teeter, trigger: .onClick),
            ShapeAnimation(shapeID: subtitle, category: .exit, effect: .fly(.top), trigger: .afterPrevious, delay: 0.5),
        ]
        presentation.slides[0].areAnimationsModified = true
        presentation.slides[0].isModified = true
        let read = try reread(presentation).slides[0].animations
        #expect(read.map(\.shapeID) == [title, subtitle, subtitle])
        #expect(read.map(\.category) == [.entrance, .emphasis, .exit])
        #expect(read.map(\.effect) == [.wipe(.left), .teeter, .fly(.top)])
        #expect(read.map(\.trigger) == [.withPrevious, .onClick, .afterPrevious])
        #expect(read.map { ($0.duration * 1_000).rounded() } == [750, 1_000, 500])
        #expect(read.map { ($0.delay * 1_000).rounded() } == [0, 0, 500])
    }

    @Test("Effects read from a file keep their XML when only their start changes")
    func retimedSource() throws {
        var presentation = Presentation.blank
        presentation.slides[0].animations = [
            ShapeAnimation(shapeID: presentation.slides[0].shapes[0].shapeID, category: .entrance, effect: .preset(id: 37, subtype: 0)),
        ]
        presentation.slides[0].areAnimationsModified = true
        presentation.slides[0].isModified = true
        var copy = try reread(presentation)
        #expect(copy.slides[0].animations.first?.effect == .preset(id: 37, subtype: 0))
        copy.slides[0].animations[0].trigger = .afterPrevious
        copy.slides[0].animations[0].delay = 1
        copy.slides[0].areAnimationsModified = true
        copy.slides[0].isModified = true
        let final = try reread(copy).slides[0].animations
        #expect(final.first?.effect == .preset(id: 37, subtype: 0))
        #expect(final.first?.trigger == .afterPrevious)
        #expect(final.first?.delay == 1)
    }

    @Test("Deleting a shape takes its animations, and an empty timing, with it") @MainActor
    func deletedShape() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.reconcile(with: presentation)
        let shape = presentation.slides[0].shapes[0]
        state.selectedShapeID = shape.id
        state.addAnimation(.zoom, category: .entrance, in: &presentation)
        #expect(presentation.slides[0].animations.count == 1)
        state.deleteSelectedShape(in: &presentation)
        #expect(presentation.slides[0].animations.isEmpty)
        let data = try PPTXWriter.data(from: presentation)
        let parts = try ZipArchive.entries(in: data)
        let slide = String(decoding: parts["ppt/slides/slide1.xml"] ?? Data(), as: UTF8.self)
        #expect(!slide.contains("timing"))
    }

    @Test("Motion paths are followed at an even pace")
    func motionPath() {
        let path = MotionPath(path: "M 0 0 L 0.5 0 L 0.5 0.5 E")
        #expect(path.offset(at: 0) == .zero)
        #expect(path.offset(at: 0.5) == CGPoint(x: 0.5, y: 0))
        #expect(path.offset(at: 1) == CGPoint(x: 0.5, y: 0.5))
    }
}
