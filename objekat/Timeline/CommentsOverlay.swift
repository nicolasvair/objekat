import SwiftUI

// MARK: - The comments laid on the timeline

/// The comments, drawn as ONE layer over the lanes.
///
/// A comment is NOT a sound object: it has no engine object behind it, it carries no matter, and
/// nothing plays it. It is a note left on the surface, over a passage, for whoever opens the
/// project next. The accepted cost of that choice is written above `TimelineComment`: a comment
/// inherits nothing from the gestures — a ripple does not slide it, a cut does not split it. It
/// stays where it was put until somebody moves it.
///
/// Real views rather than a `Canvas`, unlike the markers, and for one reason: the text is
/// MARKDOWN, and it is edited in place. `AttributedString(markdown:)` gives the bold, the italic
/// and the code spans for free through `Text`, and a `Canvas` can draw a `Text` but cannot hold a
/// `TextEditor`. There are few comments, so the ZStack costs nothing here (the rule of thumb that
/// asks for a Canvas past ~100 items is about the BLOCKS).
struct CommentsOverlay: View {
    let comments: [TimelineComment]
    let pixelsPerSecond: Double
    let rulerHeight: Double
    let laneStep: Double
    let blockHeight: Double
    var selected: AnnotationSel? = nil
    /// The comment being edited, if any (compared against `EditViewModel.renamingID`).
    var editingID: UUID? = nil
    /// nil = cancelled (Esc). Otherwise the new text.
    let onCommit: (UUID, String?) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(comments) { c in
                let w = max(24, c.duration * pixelsPerSecond)
                let tint = ObjectColorPalette.color(at: c.colorIndex)
                Group {
                    if editingID == c.id {
                        CommentEditor(initial: c.text) { onCommit(c.id, $0) }
                    } else {
                        rendered(c)
                    }
                }
                .frame(width: w, height: blockHeight, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.16)))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(selected == .comment(c.id) ? Color.accentColor : tint.opacity(0.7),
                                lineWidth: selected == .comment(c.id) ? 1.5 : 0.75)
                )
                // A comment must not stand in front of the object it talks about: it only takes the
                // mouse while it is being EDITED. Selecting it is the canvas's job, geometrically
                // (@see TimelineView.commentHit), like everything else here.
                .allowsHitTesting(editingID == c.id)
                .offset(x: c.startTime * pixelsPerSecond,
                        y: rulerHeight + Double(c.lane) * laneStep)
            }
        }
    }

    @ViewBuilder
    private func rendered(_ c: TimelineComment) -> some View {
        // Markdown that fails to parse is not an error to report: it is text somebody typed. It is
        // shown as it stands, which is also what any editor does with a stray asterisk.
        let attributed = (try? AttributedString(
            markdown: c.text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(c.text)
        Text(attributed)
            .font(.system(size: 10))
            .foregroundStyle(Color.primary.opacity(0.85))
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
    }
}

// MARK: - Editing a comment

/// The editor a double click opens over the comment. Same shape as `MarkerRenameField` — a
/// `@FocusState` cannot be handed around, so the field lives in the view that owns it — but a
/// `TextEditor` rather than a `TextField`, because a comment has several lines and a marker's name
/// has one.
private struct CommentEditor: View {
    let initial: String
    let onCommit: (String?) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 10))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(.regularMaterial))
            .focused($focused)
            // A TextEditor takes Return for itself — a comment has lines — so the commit is on ⌘Return
            // and on losing the focus, and Esc gives up. Same three ways out as anywhere else.
            .onExitCommand { onCommit(nil) }
            .onChange(of: focused) { _, now in if !now { onCommit(text) } }
            .onAppear {
                text = initial
                DispatchQueue.main.async { focused = true }
            }
            .overlay(alignment: .bottomTrailing) {
                Button { onCommit(text) } label: {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .padding(2)
            }
    }
}
