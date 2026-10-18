import SwiftUI

// MARK: - The capsule of a tab (plugin browser, Finder slots)

extension View {
    /// The look of one tab of a capsule bar, in ONE place: the plugin browser's tab bar and the
    /// Finder tab's colour slots both wear it, so the two read as the same control. An 11 pt label
    /// (semibold when `active`), 10 pt of side padding, 20 pt tall, the active one on a capsule of
    /// the selection colour. The caller adds the gesture, the help and the accessibility trait:
    /// content + `onTapGesture` rather than a `Button` (the project tabs' choice) — no focus ring.
    func capsuleTab(active: Bool) -> some View {
        self
            .font(.system(size: 11, weight: active ? .semibold : .regular))
            .padding(.horizontal, 10)
            .frame(height: 20)
            .background(
                Capsule().fill(active ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25)
                                      : Color.clear)
            )
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .contentShape(Capsule())
    }
}
