import SwiftUI

// MARK: - The glyph that says what an object IS
//
// Read beside `MissingFileLabel`, and for the same reason: a block's name is drawn in FOUR places
// (`SoundBlockView`, `GroupBlockView`, `InfiniteBusBandView`, and the batched `Canvas` of
// `TimelineView`), and the sound list's rows make the same statement about the same object on the
// other side of the window. That is FIVE readers. A glyph chosen at each of them is five chances
// for a consolidated object to read as a folder in one view and as a sound in another — which is exactly
// what the icon exists to prevent, since its whole job is to tie the left-hand list to the
// timeline at a glance.
//
// The one subtlety, and it is the reason this takes a parameter instead of reading `kind` alone:
// **an OPEN consolidated object is still a consolidated object.** Opening one for editing materialises its
// content, so its `kind` really does become `.group` and its `consolidateID` really is cleared
// (@see `EditViewModel.openConsolidate` and `restoredSubtree`, which sets `consolidateID = nil` on
// purpose — while open, the content is edited as ordinary matter). Nothing in the object itself
// can therefore tell it from a plain group, and an icon keyed on `kind` alone turns into a folder
// on the double click and back into a consolidated object on closing. What one edited was a consolidated object
// the whole time, so the caller passes `isOpenConsolidate` — the view model knows it, through
// `isInConsolidateEditStack`, and it is the only thing that does.
enum ObjectKindIcon {

    /// The SF Symbol for an object, for every view that draws one.
    ///
    /// The order of the tests is the meaning: being an open consolidated object beats looking like a
    /// group, because it IS one. After that a group is a folder, an aux its own arrow, a MIDI clip
    /// its keys, and a consolidated object a waveform in a circle — the circle being what tells it from
    /// an ordinary sound, which is the bare waveform.
    static func name(for object: SoundObject, isOpenConsolidate: Bool = false) -> String {
        if isOpenConsolidate || object.consolidateID != nil { return "waveform.circle" }
        if object.isGroup { return "folder" }
        if object.isAux   { return "arrow.down.right.circle" }
        if object.isMIDI  { return "pianokeys" }
        return "waveform"
    }

    /// The size the `Canvas` draws it at — and ONLY the `Canvas`.
    ///
    /// The three rich views deliberately keep the size and the spacing their band was laid out
    /// around (`TimelineLabelMetrics.groupIconSize` = 12 pt in `GroupBlockView`,
    /// `TimelineLabelMetrics.clipIconSize` = 13 pt bold in `SoundBlockView`,
    /// `TimelineLabelMetrics.infiniteBusIconSize` = 12 pt in `InfiniteBusBandView`, each with its
    /// own padding), because those were tuned against the band and not against each other. What is
    /// shared between the five readers is the SYMBOL and the COLOUR — the two things that would
    /// make an object read as one kind here and another kind there. A size is a matter of layout,
    /// and layout is local; a glyph is a matter of meaning, and meaning is not.
    /// Bumped 9 → 11 on 24 September 2026, along with the rich views' own icon sizes
    /// (@see `TimelineLabelMetrics`) — +2 pt everywhere, a user decision.
    static let canvasSize: CGFloat = 11
}

extension View {
    /// The glyph's COLOUR, and nothing else — no font, so every site keeps the size its band was
    /// built for. The name's own colour, so a missing file takes the icon red along with the word
    /// and the white halo that makes red legible on a red stem band (@see `MissingFileLabel`).
    func blockIconStyle(missingFile: Bool) -> some View {
        self
            .foregroundStyle(missingFile ? MissingFileLabel.color : Color.black)
            .shadow(color: missingFile ? MissingFileLabel.haloColor : .clear,
                    radius: missingFile ? MissingFileLabel.haloRadius : 0)
    }
}
