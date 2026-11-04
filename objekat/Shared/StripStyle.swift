import SwiftUI

/// The look of a bus's STRIP — the stem's rounded rectangle in the toolbar, and the input's rectangle in the Inputs tab
/// (docs/plan_groupes_midi.md): one place for its radius, its padding, its translucent fill and its border, so that the
/// two never drift apart. A strip is tinted (a stem's colour; an input's is a neutral grey), fills a little more while its
/// popover is open, and its border says what the hand is doing with it: open, hovered by a drag that will drop on it, or
/// being dragged itself.
enum StripStyle {
    static let cornerRadius: CGFloat = 6
    /// The horizontal margin of the strip's content.
    static let hPadding: CGFloat = 7
    static let vPadding: CGFloat = 4
    /// The tint of a strip whose input is ABSENT (grey means gone). The live input strips take the Main's colour
    /// (`EditViewModel.mainStemColor`).
    static let inputTint = Color.gray

    /// Aligned on the background opacity of the timeline blocks (SoundBlockView): at the same level of
    /// translucency on a dark background, the colour no longer collapses towards black and stays recognisable.
    /// `isSelected` is the input strips' (a list selection, between the quiet strip and the open one); a stem has none.
    static func fillOpacity(isOpen: Bool, isSelected: Bool = false) -> Double {
        isOpen ? 0.55 : (isSelected ? 0.42 : 0.30)
    }

    static func borderColor(tint: Color, isOpen: Bool, isDropTarget: Bool, isBeingDragged: Bool,
                            isSelected: Bool = false) -> Color {
        if isBeingDragged || isDropTarget || isOpen || isSelected { return Color.accentColor }
        return tint.opacity(0.55)
    }

    static func borderWidth(isOpen: Bool, isDropTarget: Bool, isBeingDragged: Bool, isSelected: Bool = false) -> CGFloat {
        if isBeingDragged || isDropTarget { return 2 }
        return isOpen || isSelected ? 1.5 : 1
    }
}

extension View {
    /// The strip's padding, fill and border around the content. The type-checker is spared the ternaries (a border
    /// computed inline once pushed it over its time budget).
    func stripChrome(tint: Color, isOpen: Bool, isDropTarget: Bool = false, isBeingDragged: Bool = false,
                     isSelected: Bool = false) -> some View {
        self
            .padding(.horizontal, StripStyle.hPadding).padding(.vertical, StripStyle.vPadding)
            .background(RoundedRectangle(cornerRadius: StripStyle.cornerRadius)
                .fill(tint.opacity(StripStyle.fillOpacity(isOpen: isOpen, isSelected: isSelected))))
            .overlay(RoundedRectangle(cornerRadius: StripStyle.cornerRadius)
                .strokeBorder(StripStyle.borderColor(tint: tint, isOpen: isOpen,
                                                     isDropTarget: isDropTarget, isBeingDragged: isBeingDragged,
                                                     isSelected: isSelected),
                              lineWidth: StripStyle.borderWidth(isOpen: isOpen, isDropTarget: isDropTarget,
                                                                isBeingDragged: isBeingDragged, isSelected: isSelected)))
    }
}
