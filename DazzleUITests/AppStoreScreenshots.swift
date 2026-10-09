import XCTest

/// Stages and captures the App Store screenshots.
///
/// Driven by `Assets/App Store/capture.sh`, which seeds the presentation these
/// open and says where to write through `SCREENSHOT_DIR` and which language to
/// use through `SCREENSHOT_LANGUAGE`. Without them the tests skip, so they stay
/// out of the way of an ordinary test run. `SCREENSHOT_ONLY`, a comma-separated
/// list of names, retakes just those.
final class AppStoreScreenshots: XCTestCase {
    /// A shape on the slide, as a fraction of the slide's width and height.
    private struct Point {
        let x: CGFloat
        let y: CGFloat
    }

    private struct Shot {
        let name: String
        /// Counted from 1, as the slide navigator numbers them.
        let slide: Int
        /// The action bar button that opens a panel, by accessibility identifier.
        var panel: String?
        /// The shape to select. Picked after a panel that does not need it is
        /// up, since on iPhone the slide moves to make room for the panel.
        var shape: Point?
        var isDark = false
    }

    // Where the sample deck's shapes sit; see samples.py.
    private static let card = Point(x: 0.57, y: 0.44)
    private static let chart = Point(x: 0.49, y: 0.63)
    private static let firstStage = Point(x: 0.17, y: 0.43)

    private static let iPhoneShots = [
        Shot(name: "01-deck", slide: 1),
        Shot(name: "02-format", slide: 2, panel: "format", shape: card),
        Shot(name: "03-chart", slide: 3, panel: "chartData", shape: chart),
        Shot(name: "04-animations", slide: 4, panel: "animations", shape: firstStage),
        Shot(name: "05-dark", slide: 5, isDark: true),
    ]

    private static let iPadShots = [
        Shot(name: "01-deck", slide: 1),
        Shot(name: "02-chart", slide: 3, panel: "chartData", shape: chart),
        Shot(name: "03-format", slide: 2, panel: "format", shape: card),
        Shot(name: "04-animations", slide: 4, panel: "animations", shape: firstStage),
        Shot(name: "05-notes", slide: 2, panel: "notes"),
        Shot(name: "06-dark", slide: 5, isDark: true),
    ]

    private static let document = ["en": "Festival Proposal", "ja": "合同祭のご提案"]

    private var directory: URL!
    private var language = "en"
    private var only: Set<String> = []
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("run through Assets/App Store/capture.sh")
        }
        directory = URL(fileURLWithPath: path)
        language = environment["SCREENSHOT_LANGUAGE"] ?? "en"
        only = Set((environment["SCREENSHOT_ONLY"] ?? "").split(separator: ",").map(String.init))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @MainActor
    func testScreens() throws {
        defer { XCUIDevice.shared.appearance = .light }
        try capture(shots)
    }

    @MainActor
    private var shots: [Shot] {
        UIDevice.current.userInterfaceIdiom == .pad ? Self.iPadShots : Self.iPhoneShots
    }

    @MainActor
    private func capture(_ shots: [Shot]) throws {
        for shot in shots where only.isEmpty || only.contains(shot.name) {
            XCUIDevice.shared.appearance = shot.isDark ? .dark : .light
            launch()
            open(try XCTUnwrap(Self.document[language]))
            select(slide: shot.slide)
            // A panel that acts on a shape only appears once the shape is selected.
            let needsShape = shot.panel == "chartData"
            if let shape = shot.shape, needsShape {
                tap(shape)
            }
            if let panel = shot.panel {
                let button = app.buttons[panel].firstMatch
                XCTAssertTrue(button.waitForExistence(timeout: 5), "missing \(panel) button")
                // On iPhone the action bar is wider than the screen and scrolls.
                reveal(button, swiping: app.buttons["edit"].firstMatch)
                button.tap()
                // Let the sheet settle before the slide is touched beneath it.
                Thread.sleep(forTimeInterval: 1)
            }
            if let shape = shot.shape, !needsShape {
                tap(shape)
            }
            // Let the selection and any panel finish animating in.
            Thread.sleep(forTimeInterval: 2)
            let file = directory.appendingPathComponent("\(shot.name).png")
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: file)
        }
    }

    // MARK: - Steps

    @MainActor
    private func launch() {
        app = XCUIApplication()
        let locale = language == "ja" ? "ja_JP" : "en_US"
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
    }

    @MainActor
    private var canvas: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "slideCanvas").firstMatch
    }

    /// Opens a presentation from the app's folder in the document browser.
    @MainActor
    private func open(_ name: String) {
        let browse = app.buttons[language == "ja" ? "ブラウズ" : "Browse"].firstMatch
        if browse.waitForExistence(timeout: 15), !browse.isSelected {
            browse.tap()
        }

        // The cell, not its name: a tap on the name label does not open the file.
        let file = app.collectionViews.cells.containing(.staticText, identifier: name).firstMatch
        // A freshly booted simulator takes a while to list the folder.
        XCTAssertTrue(file.waitForExistence(timeout: 30), "\(name) is not in the browser")
        // On iPhone the browser starts as a sheet that only shows its first row.
        if !file.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        file.tap()

        XCTAssertTrue(canvas.waitForExistence(timeout: 20), "\(name) never opened")
        // The canvas is up a moment before the scene takes input.
        Thread.sleep(forTimeInterval: 1.5)
    }

    @MainActor
    private func select(slide number: Int) {
        let thumbnail = app.descendants(matching: .any).matching(identifier: "slideThumbnail.\(number)").firstMatch
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 5), "missing slide \(number)")
        // On iPhone the slide strip runs off the screen.
        reveal(thumbnail, swiping: app.descendants(matching: .any).matching(identifier: "slideThumbnail.1").firstMatch)
        thumbnail.tap()
        Thread.sleep(forTimeInterval: 1)
    }

    /// Scrolls a sideways scroll view by swiping across `handle`, one of its
    /// visible elements, until `element` is fully on screen.
    @MainActor
    private func reveal(_ element: XCUIElement, swiping handle: XCUIElement) {
        let screen = app.windows.firstMatch.frame
        for _ in 0..<4 where element.frame.maxX > screen.maxX - 8 {
            handle.swipeLeft()
        }
    }

    /// Taps the slide being edited at a point given as fractions of its size,
    /// until the shape there is selected. The action bar offers Delete only
    /// with a selection; a tap that lands while the slide is still moving is lost.
    @MainActor
    private func tap(_ point: Point) {
        let delete = app.buttons["deleteShape"]
        for _ in 0..<4 where !delete.exists {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: point.x, dy: point.y)).tap()
            _ = delete.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(delete.exists, "nothing was selected")
    }
}
