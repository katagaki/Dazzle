import SwiftUI

/// The slide's comment threads: read, replied to, resolved, deleted, and
/// started.
struct CommentsPanel: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState

    /// Who comments are written as. Asked for once, then remembered.
    @AppStorage("commentAuthorName") private var authorName = ""
    @State private var draft = ""
    @State private var replies: [String: String] = [:]

    private var comments: [SlideComment] { state.selectedSlide(in: presentation)?.comments ?? [] }

    var body: some View {
        Form {
            Section {
                LabeledContent("Comments.CommentAs") {
                    TextField("Comments.YourName", text: $authorName)
                        .textContentType(.name)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("commentAuthor")
                }
            } footer: {
                if authorName.trimmed.isEmpty { Text("Comments.YourName.Footer") }
            }

            if comments.isEmpty {
                Section {
                    Text("Comments.Empty")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(comments) { thread in
                Section {
                    CommentRow(comment: thread)
                    ForEach(thread.replies) { reply in
                        CommentRow(comment: reply)
                            .padding(.leading, 20)
                            .swipeActions {
                                Button("Comments.Delete", role: .destructive) {
                                    state.deleteComment(thread.id, replyID: reply.id, in: &presentation)
                                }
                            }
                    }
                    HStack {
                        TextField("Comments.Reply", text: Binding(
                            get: { replies[thread.id] ?? "" }, set: { replies[thread.id] = $0 }
                        ), axis: .vertical)
                        Button("Comments.Send", systemImage: "arrow.up.circle.fill") {
                            state.reply(to: thread.id, with: replies[thread.id] ?? "", author: author, in: &presentation)
                            replies[thread.id] = nil
                        }
                        .labelStyle(.iconOnly)
                        .disabled((replies[thread.id] ?? "").trimmed.isEmpty || authorName.trimmed.isEmpty)
                    }
                } header: {
                    HStack {
                        if thread.isResolved {
                            Label("Comments.Resolved", systemImage: "checkmark.circle.fill")
                        }
                        Spacer()
                        Menu {
                            if thread.format == .modern {
                                Button(thread.isResolved ? "Comments.Reopen" : "Comments.Resolve",
                                       systemImage: thread.isResolved ? "arrow.uturn.backward" : "checkmark.circle") {
                                    state.setCommentResolved(thread.id, !thread.isResolved, in: &presentation)
                                }
                            }
                            Button("Comments.DeleteThread", systemImage: "trash", role: .destructive) {
                                state.deleteComment(thread.id, in: &presentation)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Comments.Actions")
                    }
                }
            }

            Section("Comments.New") {
                TextField("Comments.Placeholder", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .accessibilityIdentifier("newComment")
                Button("Comments.Add", systemImage: "text.bubble") {
                    state.addComment(draft, author: author, in: &presentation)
                    draft = ""
                }
                .disabled(draft.trimmed.isEmpty || authorName.trimmed.isEmpty)
                .accessibilityIdentifier("addComment")
            }
        }
    }

    private var author: String { authorName.trimmed }
}

/// One comment: who wrote it, when, and what it says.
private struct CommentRow: View {
    let comment: SlideComment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CommentBadge(initials: comment.initials, name: comment.author)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(comment.author.nilIfEmpty ?? String(localized: "Comments.Unknown"))
                        .font(.subheadline.weight(.semibold))
                    if let date = comment.date {
                        Text(date, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(comment.text)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}

/// An author's initials in a circle of a colour of their own.
struct CommentBadge: View {
    let initials: String
    let name: String

    var body: some View {
        Text(initials.nilIfEmpty ?? "?")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Self.color(for: name), in: .circle)
    }

    static func color(for name: String) -> Color {
        let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return colors[hash % colors.count]
    }
}
