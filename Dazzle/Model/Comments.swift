import CoreGraphics
import Foundation

/// A comment on a slide, with its replies.
///
/// PowerPoint has written comments two ways. The older, in ECMA-376, lists
/// a slide's comments by author number and index, threading replies in an
/// extension. The newer, PowerPoint 365's, gives each comment and author an
/// id, holds replies inside their comment, and can mark a thread resolved.
/// Both are read. A slide's comments are written back the way they came;
/// a slide with none yet gets the older kind, which every app reads.
struct SlideComment: Identifiable, Equatable, Hashable, Sendable {
    enum Format: Equatable, Hashable, Sendable {
        case legacy
        case modern
    }

    var id: String
    var author: String
    var initials: String
    var date: Date?
    var text: String
    /// Where it is pinned on the slide, in points.
    var position: CGPoint?
    var replies: [SlideComment] = []
    var isResolved = false
    var format: Format
    /// The modern comment's XML as read, so what Dazzle does not model —
    /// where in the slide it is anchored — survives.
    var source: String?
}

/// Someone who has commented, in the older format's list.
struct CommentAuthor: Equatable, Hashable, Sendable {
    var id: Int
    var name: String
    var initials: String
    /// The highest comment index this author has used.
    var lastIndex: Int
    var colorIndex: Int
}

/// Someone who has commented, in the newer format's list.
struct ModernCommentAuthor: Equatable, Hashable, Sendable {
    var id: String
    var name: String
    var initials: String
    var userID: String
    var providerID: String
}

enum CommentXML {
    static let modernNamespace = "http://schemas.microsoft.com/office/powerpoint/2018/8/main"
    static let threadingNamespace = "http://schemas.microsoft.com/office/powerpoint/2012/main"
    static let threadingExtension = "{C676402C-5697-4E1C-873F-D02D1690AC5C}"
    static let legacyContentType = "application/vnd.openxmlformats-officedocument.presentationml.comments+xml"
    static let legacyAuthorsContentType = "application/vnd.openxmlformats-officedocument.presentationml.commentAuthors+xml"
    static let modernContentType = "application/vnd.ms-powerpoint.comments+xml"
    static let modernAuthorsContentType = "application/vnd.ms-powerpoint.authors+xml"
    /// Older comments are positioned in eighths of a point.
    static let legacyUnitsPerPoint = 8.0

    private static let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Dates as comments write them: without a time zone, taken as UTC.
    static func date(_ text: String?) -> Date? {
        guard var text, !text.isEmpty else { return nil }
        if !text.hasSuffix("Z"), !text.contains("+") { text += "Z" }
        if !text.contains(".") { text = text.replacingOccurrences(of: "Z", with: ".000Z") }
        return try? dateFormat.parse(text)
    }

    static func string(_ date: Date?) -> String {
        (date ?? Date()).formatted(dateFormat).replacingOccurrences(of: "Z", with: "")
    }

    static func newID() -> String { "{\(UUID().uuidString)}" }

    // MARK: - Reading

    static func authors(_ data: Data?) -> [CommentAuthor] {
        guard let data, let root = try? XMLLite.parse(data) else { return [] }
        return root.children(named: "cmAuthor").compactMap { element in
            guard let id = element.attribute("id").flatMap(Int.init) else { return nil }
            return CommentAuthor(
                id: id, name: element.attribute("name") ?? "", initials: element.attribute("initials") ?? "",
                lastIndex: element.attribute("lastIdx").flatMap(Int.init) ?? 0,
                colorIndex: element.attribute("clrIdx").flatMap(Int.init) ?? 0
            )
        }
    }

    static func modernAuthors(_ data: Data?) -> [ModernCommentAuthor] {
        guard let data, let root = try? XMLLite.parse(data) else { return [] }
        return root.children(named: "author").compactMap { element in
            guard let id = element.attribute("id") else { return nil }
            return ModernCommentAuthor(
                id: id, name: element.attribute("name") ?? "", initials: element.attribute("initials") ?? "",
                userID: element.attribute("userId") ?? "", providerID: element.attribute("providerId") ?? "None"
            )
        }
    }

    /// The older format's comments, with replies gathered under the
    /// comments they answer.
    static func legacyComments(_ data: Data?, authors: [CommentAuthor]) -> [SlideComment] {
        guard let data, let root = try? XMLLite.parse(data) else { return [] }
        var threads: [SlideComment] = []
        var replies: [(parent: String, comment: SlideComment)] = []
        for element in root.children(named: "cm") {
            let authorID = element.attribute("authorId").flatMap(Int.init) ?? 0
            let index = element.attribute("idx").flatMap(Int.init) ?? 0
            let author = authors.first { $0.id == authorID }
            var comment = SlideComment(
                id: "\(authorID)-\(index)", author: author?.name ?? "", initials: author?.initials ?? "",
                date: date(element.attribute("dt")), text: element.firstChild(named: "text")?.text ?? "", format: .legacy
            )
            if let position = element.firstChild(named: "pos"),
               let x = position.attribute("x").flatMap(Double.init), let y = position.attribute("y").flatMap(Double.init) {
                comment.position = CGPoint(x: x / legacyUnitsPerPoint, y: y / legacyUnitsPerPoint)
            }
            let parent = element.firstDescendant(atPath: "extLst/ext/threadingInfo/parentCm")
            if let parent, let parentAuthor = parent.attribute("authorId"), let parentIndex = parent.attribute("idx") {
                replies.append(("\(parentAuthor)-\(parentIndex)", comment))
            } else {
                threads.append(comment)
            }
        }
        for reply in replies {
            if let index = threads.firstIndex(where: { $0.id == reply.parent }) {
                threads[index].replies.append(reply.comment)
            } else {
                threads.append(reply.comment)
            }
        }
        return threads
    }

    static func modernComments(_ data: Data?, authors: [ModernCommentAuthor]) -> [SlideComment] {
        guard let data, let root = try? XMLLite.parse(data) else { return [] }
        func comment(_ element: XMLElement) -> SlideComment {
            let author = authors.first { $0.id == element.attribute("authorId") }
            var comment = SlideComment(
                id: element.attribute("id") ?? newID(), author: author?.name ?? "", initials: author?.initials ?? "",
                date: date(element.attribute("created")), text: bodyText(element.firstChild(named: "txBody")), format: .modern
            )
            comment.isResolved = ["resolved", "closed"].contains(element.attribute("status") ?? "")
            if let position = element.firstChild(named: "pos"),
               let x = position.attribute("x").flatMap(Int.init), let y = position.attribute("y").flatMap(Int.init) {
                comment.position = CGPoint(x: EMU.points(x), y: EMU.points(y))
            }
            return comment
        }
        return root.children(named: "cm").map { element in
            var thread = comment(element)
            thread.replies = element.firstChild(named: "replyLst")?.children(named: "reply").map(comment) ?? []
            thread.source = XMLLite.serialize(element)
            return thread
        }
    }

    private static func bodyText(_ body: XMLElement?) -> String {
        guard let body else { return "" }
        return body.children(named: "p").map { paragraph in
            paragraph.children.compactMap { child in
                child.name == "br" ? "\n" : child.firstChild(named: "t")?.text
            }.joined()
        }.joined(separator: "\n")
    }

    // MARK: - Writing

    /// A slide's comments in the older format. Each author's comments are
    /// numbered on from the highest number that author has used.
    static func legacyXML(_ comments: [SlideComment], authors: inout [CommentAuthor]) -> String {
        var entries: [String] = []
        func author(named name: String, initials: String) -> Int {
            if let existing = authors.first(where: { $0.name == name }) { return existing.id }
            let id = (authors.map(\.id).max() ?? -1) + 1
            authors.append(CommentAuthor(
                id: id, name: name, initials: initials, lastIndex: 0, colorIndex: (authors.map(\.colorIndex).max() ?? -1) + 1
            ))
            return id
        }
        func entry(_ comment: SlideComment, parent: (author: Int, index: Int)?) -> (author: Int, index: Int) {
            let authorID = author(named: comment.author, initials: comment.initials)
            let position = authors.firstIndex { $0.id == authorID } ?? 0
            authors[position].lastIndex += 1
            let index = authors[position].lastIndex
            let point = comment.position ?? .zero
            var xml = "<p:cm authorId=\"\(authorID)\" dt=\"\(string(comment.date))\" idx=\"\(index)\">"
                + "<p:pos x=\"\(Int(point.x * legacyUnitsPerPoint))\" y=\"\(Int(point.y * legacyUnitsPerPoint))\"/>"
                + "<p:text>\(XMLLite.escape(comment.text))</p:text>"
            if let parent {
                xml += "<p:extLst><p:ext uri=\"\(threadingExtension)\"><p15:threadingInfo xmlns:p15=\"\(threadingNamespace)\" "
                    + "timeZoneBias=\"0\"><p15:parentCm authorId=\"\(parent.author)\" idx=\"\(parent.index)\"/>"
                    + "</p15:threadingInfo></p:ext></p:extLst>"
            }
            entries.append(xml + "</p:cm>")
            return (authorID, index)
        }
        for thread in comments {
            let parent = entry(thread, parent: nil)
            for reply in thread.replies { _ = entry(reply, parent: parent) }
        }
        return "<p:cmLst xmlns:a=\"\(OOXML.drawingML)\" xmlns:r=\"\(OOXML.relationshipsNS)\" xmlns:p=\"\(OOXML.presentationML)\">"
            + entries.joined() + "</p:cmLst>"
    }

    static func legacyAuthorsXML(_ authors: [CommentAuthor]) -> String {
        "<p:cmAuthorLst xmlns:a=\"\(OOXML.drawingML)\" xmlns:r=\"\(OOXML.relationshipsNS)\" xmlns:p=\"\(OOXML.presentationML)\">"
            + authors.map { author in
                "<p:cmAuthor id=\"\(author.id)\" name=\"\(XMLLite.escape(author.name))\" initials=\"\(XMLLite.escape(author.initials))\" "
                    + "lastIdx=\"\(author.lastIndex)\" clrIdx=\"\(author.colorIndex)\"/>"
            }.joined() + "</p:cmAuthorLst>"
    }

    /// A slide's comments in the newer format. A comment read from the file
    /// keeps its anchor; one added here is anchored as the others are.
    static func modernXML(_ comments: [SlideComment], authors: inout [ModernCommentAuthor]) -> String {
        let namespaces = ["p188": modernNamespace, "a": OOXML.drawingML, "r": OOXML.relationshipsNS]
        func authorID(_ comment: SlideComment) -> String {
            if let existing = authors.first(where: { $0.name == comment.author }) { return existing.id }
            let author = ModernCommentAuthor(
                id: newID(), name: comment.author, initials: comment.initials, userID: comment.author, providerID: "None"
            )
            authors.append(author)
            return author.id
        }
        func body(_ text: String) -> String {
            let paragraphs = text.components(separatedBy: "\n").map { line in
                line.isEmpty ? "<a:p><a:endParaRPr lang=\"en-US\"/></a:p>"
                    : "<a:p><a:r><a:rPr lang=\"en-US\"/><a:t>\(XMLLite.escape(line))</a:t></a:r></a:p>"
            }
            return "<p188:txBody><a:bodyPr/><a:lstStyle/>\(paragraphs.joined())</p188:txBody>"
        }
        // The anchor a new comment borrows: the slide's, from another comment.
        let anchor = comments.lazy.compactMap { $0.source.flatMap { XMLLite.fragment($0, namespaces: namespaces) } }
            .compactMap { $0.children.first { $0.name.hasSuffix("MkLst") } }.first.flatMap { XMLLite.serialize($0) } ?? ""

        let entries = comments.map { thread -> String in
            let element = thread.source.flatMap { XMLLite.fragment($0, namespaces: namespaces) }
            let kept = element?.children.filter { $0.name != "replyLst" && $0.name != "txBody" && $0.name != "pos" }
                .compactMap { XMLLite.serialize($0) } ?? []
            let marker = kept.first { $0.contains("MkLst") } ?? anchor
            let rest = kept.filter { !$0.contains("MkLst") }
            let status = thread.isResolved ? " status=\"resolved\"" : ""
            let position = thread.position.map { "<p188:pos x=\"\(EMU.from(points: $0.x))\" y=\"\(EMU.from(points: $0.y))\"/>" } ?? ""
            let replies = thread.replies.map { reply in
                "<p188:reply id=\"\(reply.id)\" authorId=\"\(authorID(reply))\" created=\"\(string(reply.date))\">"
                    + body(reply.text) + "</p188:reply>"
            }.joined()
            return "<p188:cm id=\"\(thread.id)\" authorId=\"\(authorID(thread))\" created=\"\(string(thread.date))\"\(status)>"
                + marker + position + (replies.isEmpty ? "" : "<p188:replyLst>\(replies)</p188:replyLst>")
                + body(thread.text) + rest.filter { $0.contains("extLst") }.joined() + "</p188:cm>"
        }
        return "<p188:cmLst xmlns:a=\"\(OOXML.drawingML)\" xmlns:r=\"\(OOXML.relationshipsNS)\" xmlns:p188=\"\(modernNamespace)\">"
            + entries.joined() + "</p188:cmLst>"
    }

    static func modernAuthorsXML(_ authors: [ModernCommentAuthor]) -> String {
        "<p188:authorLst xmlns:a=\"\(OOXML.drawingML)\" xmlns:r=\"\(OOXML.relationshipsNS)\" xmlns:p188=\"\(modernNamespace)\">"
            + authors.map { author in
                "<p188:author id=\"\(author.id)\" name=\"\(XMLLite.escape(author.name))\" initials=\"\(XMLLite.escape(author.initials))\" "
                    + "userId=\"\(XMLLite.escape(author.userID))\" providerId=\"\(XMLLite.escape(author.providerID))\"/>"
            }.joined() + "</p188:authorLst>"
    }
}
