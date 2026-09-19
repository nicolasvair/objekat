import SwiftUI

// MARK: - The glyph that says what an object IS
//
// Read beside `MissingFileLabel`, and for the same reason: a block's name is drawn in FOUR places
// (`SoundBlockView`, `GroupBlockView`, `InfiniteBusBandView`, and the batched `Canvas` of
// `TimelineView`), and the sound list's rows make the same statement about the same object on the
// other side of the window. That is FIVE readers. A glyph chosen at each of them is five chances
// for a sound object to read as a folder in one view and as a sound in another — which is exactly
// what the icon exists to prevent, since its whole job is to tie the left-hand list to the
// timeline at a glance.
//
// The one subtlety, and it is the reason this takes a parameter instead of reading `kind` alone:
// **an OPEN sound object is still a sound object.** Opening one for editing materialises its
// content, so its `kind` really does become `.group` and its `definitionID` really is cleared
// (@see `EditViewModel.openObject` and `restoredSubtree`, which sets `definitionID = nil` on
// purpose — while open, the content is edited as ordinary matter). Nothing in the object itself
// can therefore tell it from a plain group, and an icon keyed on `kind` alone turns into a folder
// on the double click and back into a sound object on closing. What one edited was a sound object
// the whole time, so the caller passes `isOpenObject` — the view model knows it, through
// `isInObjectEditStack`, and it is the only thing that does.
enum ObjectKindIcon {

    /// The SF Symbol for an object, for every view that draws one.
    ///
    /// The order of the tests is the meaning: being an open sound object beats looking like a
    /// group, because it IS one. After that a group is a folder, an aux its own arrow, a MIDI clip
    /// its keys, and a sound object a waveform in a circle — the circle being what tells it from
    /// an ordinary sound, which is the bare waveform.
    static func name(for object: SoundObject, isOpenObject: Bool = false) -> String {
        if isOpenObject || object.definitionID != nil { return "waveform.circle" }
        if object.isGroup { return "folder" }
        if object.isAux   { return "arrow.down.right.circle" }
        if object.isMIDI  { return "pianokeys" }
        return "waveform"
    }

    /// The size the `Canvas` draws it at — and ONLY the `Canvas`.
    ///
    /// The three rich views deliberately keep the size and the spacing their band was laid out
    /// around (10 pt in `GroupBlockView`, 11 pt bold in `SoundBlockView`, each with its own
    /// padding), because those were tuned against the band and not against each other. What is
    /// shared between the five readers is the SYMBOL and the COLOUR — the two things that would
    /// make an object read as one kind here and another kind there. A size is a matter of layout,
    /// and layout is local; a glyph is a matter of meaning, and meaning is not.
    static let canvasSize: CGFloat = 9
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
