import SwiftUI

/// Finding text on every slide, in tables and in the speaker notes, and
/// replacing it.
struct FindPanel: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState

    @State private var query = FindQuery(text: "")
    @State private var replacement = ""
    @FocusState private var isSearching: Bool

    private var matches: [FindMatch] { presentation.matches(for: query) }

    var body: some View {
        let matches = matches
        Form {
            Section {
                TextField("Find.Placeholder", text: $query.text)
                    .focused($isSearching)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("findText")
                TextField("Find.ReplacePlaceholder", text: $replacement)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("replaceText")
                Toggle("Find.MatchCase", isOn: $query.matchesCase)
                Toggle("Find.WholeWords", isOn: $query.matchesWholeWords)
            } footer: {
                if !query.text.isEmpty {
                    Text(String.localizedStringWithFormat(String(localized: "Find.Count"), matches.count))
                }
            }

            if !matches.isEmpty {
                Section {
                    Button("Find.ReplaceAll", systemImage: "arrow.2.squarepath") {
                        presentation.replace(matches, with: replacement)
                    }
                    .accessibilityIdentifier("replaceAll")
                }
                Section("Find.Section.Results") {
                    ForEach(matches) { match in
                        result(match)
                    }
                }
            }
        }
        .onAppear { isSearching = true }
    }

    private func result(_ match: FindMatch) -> some View {
        Button {
            show(match)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(location(of: match))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(highlighted(match))
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
        }
        .swipeActions {
            Button("Find.Replace") {
                presentation.replace([match], with: replacement)
            }
            .tint(.accentColor)
        }
    }

    /// The excerpt with the match in bold.
    private func highlighted(_ match: FindMatch) -> AttributedString {
        let excerpt = match.excerpt as NSString
        var result = AttributedString(excerpt.substring(to: match.excerptRange.location))
        var found = AttributedString(excerpt.substring(with: match.excerptRange))
        found.font = .callout.bold()
        found.foregroundColor = .accentColor
        result += found
        result += AttributedString(excerpt.substring(from: match.excerptRange.location + match.excerptRange.length))
        return result
    }

    private func location(of match: FindMatch) -> String {
        let number = (presentation.index(of: match.slideID) ?? 0) + 1
        let slide = String(format: String(localized: "Find.Slide"), number)
        switch match.place {
        case .notes: return slide + " · " + String(localized: "Find.Notes")
        case .cell: return slide + " · " + String(localized: "Find.Table")
        case .shape: return slide
        }
    }

    /// Goes to the slide a match is on, and picks out the shape it is in.
    private func show(_ match: FindMatch) {
        state.selectSlide(match.slideID)
        switch match.place {
        case .shape(let id):
            state.selectedShapeID = id
        case .cell(let id, let position):
            state.selectedShapeID = id
            state.selectCell(position)
        case .notes:
            break
        }
    }
}
