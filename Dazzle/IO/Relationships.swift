import Foundation

/// Namespace and relationship-type URIs a presentation package uses.
enum OOXML {
    static let presentationML = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let drawingML = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let relationshipsNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let packageRelationships = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let contentTypesNS = "http://schemas.openxmlformats.org/package/2006/content-types"

    /// The prefixes Dazzle writes new XML with.
    static let namespaces = ["a": drawingML, "r": relationshipsNS, "p": presentationML]

    enum RelationshipType {
        private static let base = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        static let officeDocument = base + "officeDocument"
        static let slide = base + "slide"
        static let slideLayout = base + "slideLayout"
        static let slideMaster = base + "slideMaster"
        static let notesSlide = base + "notesSlide"
        static let notesMaster = base + "notesMaster"
        static let theme = base + "theme"
        static let image = base + "image"
        static let comments = base + "comments"
        static let diagramDrawing = "http://schemas.microsoft.com/office/2007/relationships/diagramDrawing"
        static let vbaProject = "http://schemas.microsoft.com/office/2006/relationships/vbaProject"
    }

    enum ContentType {
        private static let base = "application/vnd.openxmlformats-officedocument.presentationml."
        static let slide = base + "slide+xml"
        static let notesSlide = base + "notesSlide+xml"
        static let notesMaster = base + "notesMaster+xml"
        static let theme = "application/vnd.openxmlformats-officedocument.theme+xml"
    }
}

/// One entry in a part's `.rels`.
struct Relationship: Equatable, Hashable, Sendable {
    var id: String
    var type: String
    var target: String
    var isExternal = false

    /// Reads a `.rels` part.
    static func parse(_ data: Data?) -> [Relationship] {
        guard let data, let root = try? XMLLite.parse(data) else { return [] }
        return root.children(named: "Relationship").compactMap { element in
            guard let id = element.attribute("Id"), let type = element.attribute("Type"),
                  let target = element.attribute("Target") else { return nil }
            return Relationship(id: id, type: type, target: target, isExternal: element.attribute("TargetMode") == "External")
        }
    }

    static func xml(_ relationships: [Relationship]) -> Data {
        let entries = relationships.map { relationship in
            let mode = relationship.isExternal ? " TargetMode=\"External\"" : ""
            return "<Relationship Id=\"\(XMLLite.escape(relationship.id))\" Type=\"\(XMLLite.escape(relationship.type))\" "
                + "Target=\"\(XMLLite.escape(relationship.target))\"\(mode)/>"
        }
        return Data((PackagePath.declaration
            + "<Relationships xmlns=\"\(OOXML.packageRelationships)\">\(entries.joined())</Relationships>").utf8)
    }

    /// The first id of the form `rIdN` that none of `relationships` uses.
    static func unusedID(in relationships: [Relationship]) -> String {
        let used = Set(relationships.map(\.id))
        var number = relationships.count + 1
        while used.contains("rId\(number)") { number += 1 }
        return "rId\(number)"
    }
}

/// Paths inside a package.
enum PackagePath {
    static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    /// Where the relationships of `part` live: `ppt/slides/slide1.xml` →
    /// `ppt/slides/_rels/slide1.xml.rels`.
    static func relationships(of part: String) -> String {
        let directory = (part as NSString).deletingLastPathComponent
        let file = (part as NSString).lastPathComponent
        return directory.isEmpty ? "_rels/\(file).rels" : "\(directory)/_rels/\(file).rels"
    }

    /// Resolves a relationship target against the part that holds it.
    static func resolve(_ target: String, from part: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var components = (part as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for component in target.split(separator: "/") {
            switch component {
            case "..": if !components.isEmpty { components.removeLast() }
            case ".": continue
            default: components.append(String(component))
            }
        }
        return components.joined(separator: "/")
    }

    /// The target that reaches `path` from `part`.
    static func relativeTarget(to path: String, from part: String) -> String {
        let from = (part as NSString).deletingLastPathComponent.split(separator: "/")
        let to = path.split(separator: "/")
        var shared = 0
        while shared < from.count, shared < to.count - 1, from[shared] == to[shared] { shared += 1 }
        let ups = Array(repeating: "..", count: from.count - shared)
        return (ups + to[shared...].map(String.init)).joined(separator: "/")
    }

    /// The first path `prefix{n}.suffix` that is not in `taken`.
    static func unused(prefix: String, suffix: String, taken: Set<String>) -> String {
        var number = 1
        while taken.contains("\(prefix)\(number)\(suffix)") { number += 1 }
        return "\(prefix)\(number)\(suffix)"
    }
}

extension XMLElement {
    /// `r:id`. Stripping prefixes folds it into the plain `id` that list
    /// entries such as `p:sldId` also carry, so it is looked up by its
    /// qualified name instead.
    var relationshipID: String? {
        qualifiedAttributes.first { $0.key.hasSuffix(":id") && !$0.key.hasPrefix("xmlns") }?.value
    }
}
