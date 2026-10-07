import CoreText
import Foundation
import Synchronization

/// The fonts a presentation carries inside it, by the typeface names its
/// text uses. PowerPoint usually embeds only the characters a deck needs,
/// so these stay with their deck rather than being installed for every one.
final class EmbeddedFonts: Sendable {
    struct Face: Hashable, Sendable {
        var isBold: Bool
        var isItalic: Bool
    }

    static let none = EmbeddedFonts(files: [:])

    /// Tells one deck's fonts from another's in caches; unlike an object
    /// identifier, never reused.
    let id = UUID()
    /// Typeface names as the file spells them.
    let typefaces: [String]
    /// Each typeface's font files, by lowercased name, as stored in the package.
    private let files: [String: [Face: Data]]
    /// Decoded faces, nil where a file would not decode. Decoding takes a few
    /// milliseconds a face, so it waits until text asks for one.
    private let decoded = Mutex<[String: [Face: CTFontDescriptor?]]>([:])

    init(files: [String: [Face: Data]]) {
        typefaces = files.keys.sorted()
        self.files = Dictionary(files.map { ($0.key.lowercased(), $0.value) }) { first, second in first.merging(second) { a, _ in a } }
    }

    var isEmpty: Bool { files.isEmpty }

    /// The face of `family` closest to the style asked for, or nil when the
    /// presentation does not carry that typeface.
    func descriptor(family: String, bold: Bool, italic: Bool) -> CTFontDescriptor? {
        let name = family.lowercased()
        guard let faces = files[name] else { return nil }
        let preferred = [
            Face(isBold: bold, isItalic: italic), Face(isBold: bold, isItalic: false),
            Face(isBold: false, isItalic: italic), Face(isBold: false, isItalic: false),
        ]
        for face in preferred + Array(faces.keys) {
            guard let file = faces[face] else { continue }
            if let descriptor = decode(file, name: name, face: face) { return descriptor }
        }
        return nil
    }

    private func decode(_ file: Data, name: String, face: Face) -> CTFontDescriptor? {
        decoded.withLock { decoded -> CTFontDescriptor? in
            if let known = decoded[name]?[face] { return known }
            let descriptor = EmbeddedFontDecoder.sfnt(from: file).flatMap {
                CTFontManagerCreateFontDescriptorFromData($0 as CFData)
            }
            decoded[name, default: [:]][face] = .some(descriptor)
            return descriptor
        }
    }
}
