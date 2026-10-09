#!/usr/bin/env swift

import AppKit

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let languages = ["en", "ja"]

/// Captures live in `Raw/<device>/<lang>/` and are written to `<device>/<lang>/`.
enum Device: String {
    case iPhone
    case iPad

    /// 6.5" iPhone and 13" iPad.
    var canvasSize: NSSize {
        switch self {
        case .iPhone: NSSize(width: 1242, height: 2688)
        case .iPad: NSSize(width: 2064, height: 2752)
        }
    }

    /// Text and margins are laid out for the iPhone canvas and scaled up by width.
    var scale: CGFloat { canvasSize.width / Device.iPhone.canvasSize.width }

    func rawDir(_ language: String) -> URL {
        scriptDir.appendingPathComponent("Raw").appendingPathComponent(rawValue)
            .appendingPathComponent(language)
    }

    func outDir(_ language: String) -> URL {
        scriptDir.appendingPathComponent(rawValue).appendingPathComponent(language)
    }
}

struct Copy {
    let header: String
    let caption: String
}

struct Screenshot {
    let name: String
    /// Keyed by language code. A language without copy is skipped.
    let copy: [String: Copy]
}

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

// Every screenshot sits on the app icon's orange.
let gradientTop = color(0xFF9A5C)
let gradientBottom = color(0xE0502A)

let formatCopy = [
    "en": Copy(header: "Style every shape", caption: "Fills, gradients, lines, and shadows"),
    "ja": Copy(header: "図形を思いどおりに", caption: "塗り・グラデーション・線・影"),
]
let chartCopy = [
    "en": Copy(header: "Charts you can edit", caption: "Change the numbers and watch it redraw"),
    "ja": Copy(header: "グラフもそのまま編集", caption: "数字を変えれば、すぐに描き直し"),
]
let animationsCopy = [
    "en": Copy(header: "Bring slides to life", caption: "Fade and fly in, one tap at a time"),
    "ja": Copy(header: "スライドに動きを", caption: "フェードやスライドインを、タップごとに"),
]
let darkCopy = [
    "en": Copy(header: "Made for Dark Mode", caption: "Easy on the eyes, late into the night"),
    "ja": Copy(header: "ダークモードに対応", caption: "夜遅くの作業も目にやさしく"),
]

let iPhoneScreenshots = [
    Screenshot(
        name: "01-deck",
        copy: [
            "en": Copy(header: "Presentations, anywhere", caption: "Open and edit PowerPoint files"),
            "ja": Copy(header: "プレゼンを、どこでも", caption: "PowerPointファイルをそのまま開いて編集"),
        ]
    ),
    Screenshot(name: "02-format", copy: formatCopy),
    Screenshot(name: "03-chart", copy: chartCopy),
    Screenshot(name: "04-animations", copy: animationsCopy),
    Screenshot(name: "05-dark", copy: darkCopy),
]

let iPadScreenshots = [
    Screenshot(
        name: "01-deck",
        copy: [
            "en": Copy(header: "Big slides, on a big screen", caption: "Every slide in view as you edit"),
            "ja": Copy(header: "大きな画面で、のびのび編集", caption: "全スライドを見渡しながら"),
        ]
    ),
    Screenshot(name: "02-chart", copy: chartCopy),
    Screenshot(name: "03-format", copy: formatCopy),
    Screenshot(name: "04-animations", copy: animationsCopy),
    Screenshot(
        name: "05-notes",
        copy: [
            "en": Copy(header: "Notes for every slide", caption: "Remember what to say, slide by slide"),
            "ja": Copy(header: "スライドごとにメモ", caption: "話す内容を、スライドごとに"),
        ]
    ),
    Screenshot(name: "06-dark", copy: darkCopy),
]

// MARK: - Text

/// SF Pro Rounded. It has no Japanese, so that falls back to Tsukushi A Round
/// Gothic, which unlike Hiragino Maru Gothic comes in a bold to match the header.
func roundedFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let system = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
    let japanese = weight >= .semibold ? "TsukuARdGothic-Bold" : "TsukuARdGothic-Regular"
    let rounded = (system.withDesign(.rounded) ?? system).addingAttributes([
        .cascadeList: [NSFontDescriptor(name: japanese, size: size)],
    ])
    return NSFont(descriptor: rounded, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
}

/// One line of text at the largest size up to `size` that fits `maxWidth`.
struct Line {
    let text: String
    let attributes: [NSAttributedString.Key: Any]
    let font: NSFont
    let size: NSSize

    init(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, maxWidth: CGFloat) {
        var fontSize = size
        var font = roundedFont(ofSize: fontSize, weight: weight)
        var attributes: [NSAttributedString.Key: Any] = [:]
        var lineSize = NSSize.zero
        while fontSize > 10 {
            font = roundedFont(ofSize: fontSize, weight: weight)
            attributes = [.font: font, .foregroundColor: color]
            lineSize = (text as NSString).size(withAttributes: attributes)
            if lineSize.width <= maxWidth { break }
            fontSize -= 2
        }
        self.text = text
        self.attributes = attributes
        self.font = font
        self.size = lineSize
        (inkTop, inkBottom) = Line.inkInsets(of: text, attributes: attributes, size: lineSize)
    }

    /// How far below the top of the line box the glyphs actually start and end.
    let inkTop: CGFloat
    let inkBottom: CGFloat

    /// Centering by font metrics leaves the text looking off, since the line box carries
    /// space above the capitals and below the baseline. So the line is rendered once and
    /// the rows its glyphs cover are measured.
    private static func inkInsets(
        of text: String, attributes: [NSAttributedString.Key: Any], size: NSSize
    ) -> (CGFloat, CGFloat) {
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        guard width > 0, height > 0, let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return (0, size.height) }
        bitmap.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        var opaque = attributes
        opaque[.foregroundColor] = NSColor.black
        (text as NSString).draw(at: .zero, withAttributes: opaque)
        NSGraphicsContext.restoreGraphicsState()

        // Bitmap rows run top to bottom.
        let inked = (0..<height).filter { y in
            (0..<width).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 }
        }
        guard let first = inked.first, let last = inked.last else { return (0, size.height) }
        return (CGFloat(first), CGFloat(last + 1))
    }

    /// Draws the line centered across `canvasWidth`, with the top of its line box at `top`.
    func draw(top: CGFloat, canvasWidth: CGFloat) {
        (text as NSString).draw(
            at: NSPoint(x: (canvasWidth - size.width) / 2, y: top - size.height),
            withAttributes: attributes
        )
    }
}

// MARK: - Device frames

func cgImage(of image: NSImage) -> CGImage {
    image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

/// Draws `raw` aspect-filled into `rect`.
func drawFilled(_ raw: CGImage, in rect: CGRect, context: CGContext) {
    let rawSize = CGSize(width: raw.width, height: raw.height)
    let scale = max(rect.width / rawSize.width, rect.height / rawSize.height)
    let drawSize = CGSize(width: rawSize.width * scale, height: rawSize.height * scale)
    context.draw(raw, in: CGRect(
        x: rect.midX - drawSize.width / 2,
        y: rect.midY - drawSize.height / 2,
        width: drawSize.width,
        height: drawSize.height
    ))
}

let hardwareImage = NSImage(contentsOf: scriptDir.appendingPathComponent("Hardware@2x.png"))!
let displayImage = NSImage(contentsOf: scriptDir.appendingPathComponent("Display@2x.png"))!
let hardwareCG = cgImage(of: hardwareImage)
let displayCG = cgImage(of: displayImage)
let hardwarePixel = NSSize(width: hardwareCG.width, height: hardwareCG.height)
let displayPixel = NSSize(width: displayCG.width, height: displayCG.height)
// The display mask sits centered within the hardware frame.
let displayOrigin = NSPoint(
    x: (hardwarePixel.width - displayPixel.width) / 2,
    y: (hardwarePixel.height - displayPixel.height) / 2
)

/// The raw capture clipped by the display mask, on a hardware-sized canvas.
func maskedScreen(raw: NSImage) -> NSImage {
    let image = NSImage(size: hardwarePixel)
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let displayRect = CGRect(origin: displayOrigin, size: displayPixel)
    ctx.clip(to: displayRect, mask: displayCG)
    drawFilled(cgImage(of: raw), in: displayRect, context: ctx)
    image.unlockFocus()
    return image
}

/// The iPad bezel, as a fraction of the device's width.
let iPadBezel: CGFloat = 0.03
let iPadCornerRadius: CGFloat = 0.05
/// 13" iPad Pro screen, width over height.
let iPadScreenAspect: CGFloat = 2064 / 2752

func deviceAspect(_ device: Device) -> CGFloat {
    switch device {
    case .iPhone:
        return hardwarePixel.width / hardwarePixel.height
    case .iPad:
        let screenHeight = (1 - 2 * iPadBezel) / iPadScreenAspect
        return 1 / (screenHeight + 2 * iPadBezel)
    }
}

/// A plain iPad Pro in black, drawn rather than imaged, with the capture on its screen.
func drawiPad(raw: NSImage, in rect: NSRect) {
    let ctx = NSGraphicsContext.current!.cgContext
    let bezel = rect.width * iPadBezel
    let outerRadius = rect.width * iPadCornerRadius

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 60
    shadow.shadowOffset = NSSize(width: 0, height: -24)
    shadow.set()
    color(0x1C1C1E).setFill()
    NSBezierPath(roundedRect: rect, xRadius: outerRadius, yRadius: outerRadius).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // A lighter edge, as the aluminium band catches the light.
    let rim = NSBezierPath(
        roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: outerRadius - 2, yRadius: outerRadius - 2
    )
    rim.lineWidth = 4
    color(0x5A5A5E).setStroke()
    rim.stroke()

    let screenRect = rect.insetBy(dx: bezel, dy: bezel)
    let screenRadius = max(outerRadius - bezel * 0.8, 0)
    ctx.saveGState()
    NSBezierPath(roundedRect: screenRect, xRadius: screenRadius, yRadius: screenRadius).addClip()
    drawFilled(cgImage(of: raw), in: screenRect, context: ctx)
    ctx.restoreGState()
}

// MARK: - Composition

func compose(_ shot: Screenshot, language: String, device: Device) -> Bool {
    guard let copy = shot.copy[language] else { return true }
    let rawURL = device.rawDir(language).appendingPathComponent("\(shot.name).png")
    guard let raw = NSImage(contentsOf: rawURL) else {
        print("missing raw capture: \(rawURL.path)")
        return false
    }

    let canvasSize = device.canvasSize
    let s = device.scale
    let image = NSImage(size: canvasSize)
    image.lockFocus()

    NSGradient(starting: gradientTop, ending: gradientBottom)?
        .draw(in: NSRect(origin: .zero, size: canvasSize), angle: -90)

    // One-line header and caption. AppKit's origin is bottom-left.
    let textWidth = canvasSize.width - 96 * s
    let header = Line(copy.header, size: 84 * s, weight: .bold, color: .white, maxWidth: textWidth)
    let caption = Line(
        copy.caption, size: 44 * s, weight: .medium,
        color: NSColor.white.withAlphaComponent(0.92), maxWidth: textWidth
    )
    let captionGap = 4 * s
    // From the top of the header's ink to the bottom of the caption's.
    let inkHeight = header.size.height + captionGap + caption.inkBottom - header.inkTop

    let aspect = deviceAspect(device)
    var deviceSize: NSSize
    let deviceBottom: CGFloat
    let deviceTop: CGFloat
    switch device {
    case .iPhone:
        // The device fills what is left below a band that holds the text.
        let textPadding = 88 * s
        let deviceBottomMargin = 88 * s
        deviceTop = canvasSize.height - inkHeight - 2 * textPadding
        let availableHeight = deviceTop - deviceBottomMargin
        deviceSize = NSSize(width: availableHeight * aspect, height: availableHeight)
        if deviceSize.width > canvasSize.width - 120 * s {
            deviceSize.width = canvasSize.width - 120 * s
            deviceSize.height = deviceSize.width / aspect
        }
        deviceBottom = deviceTop - deviceSize.height
    case .iPad:
        // The iPad is drawn as wide as the margins allow and runs off the bottom of the
        // canvas, leaving a band above it for the text.
        deviceSize = NSSize(width: canvasSize.width - 140 * s, height: (canvasSize.width - 140 * s) / aspect)
        deviceTop = canvasSize.height - 300 * s
        deviceBottom = deviceTop - deviceSize.height
    }

    // The text's ink is centered in the band between the top of the canvas and the device.
    let inkTop = (canvasSize.height + deviceTop + inkHeight) / 2
    let headerTop = (inkTop + header.inkTop).rounded()
    header.draw(top: headerTop, canvasWidth: canvasSize.width)
    caption.draw(top: headerTop - header.size.height - captionGap, canvasWidth: canvasSize.width)

    let deviceRect = NSRect(
        x: ((canvasSize.width - deviceSize.width) / 2).rounded(),
        y: deviceBottom.rounded(),
        width: deviceSize.width,
        height: deviceSize.height
    )

    switch device {
    case .iPhone:
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 60
        shadow.shadowOffset = NSSize(width: 0, height: -24)
        shadow.set()
        hardwareImage.draw(in: deviceRect)
        NSGraphicsContext.current?.restoreGraphicsState()
        maskedScreen(raw: raw).draw(in: deviceRect)
    case .iPad:
        drawiPad(raw: raw, in: deviceRect)
    }

    image.unlockFocus()

    // Rasterize at exactly the canvas size in pixels.
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvasSize.width), pixelsHigh: Int(canvasSize.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return false }
    bitmap.size = canvasSize
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(origin: .zero, size: canvasSize))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
    let outDir = device.outDir(language)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let outURL = outDir.appendingPathComponent("\(shot.name).png")
    do {
        try png.write(to: outURL)
        print("wrote \(outURL.path.replacingOccurrences(of: scriptDir.path + "/", with: ""))")
        return true
    } catch {
        print("failed to write \(outURL.path): \(error)")
        return false
    }
}

var allOK = true
for language in languages {
    for shot in iPhoneScreenshots {
        allOK = compose(shot, language: language, device: .iPhone) && allOK
    }
    for shot in iPadScreenshots {
        allOK = compose(shot, language: language, device: .iPad) && allOK
    }
}
exit(allOK ? 0 : 1)
