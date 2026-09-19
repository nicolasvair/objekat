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

    /// The size a block's name band can carry. The band is 20 % of a block's height and the name
    /// beside it is 10 pt (@see `MissingFileLabel.size`), so the glyph matches the text rather
    /// than leading it: an icon larger than the word it introduces reads as a button.
    static let size: CGFloat = 9
    /// The gap between the glyph and the name, in the timeline. Narrow on purpose — the two are
    /// one statement, not two.
    static let gap: CGFloat = 3
}

extension View {
    /// The glyph as the three rich views draw it: the name's own colour, so that a missing file
    /// takes the icon red with the word. The `Canvas` resolves its own image and reads the
    /// constants above instead — same values, one definition.
    func blockIconStyle(missingFile: Bool) -> some View {
        self
            .font(.system(size: ObjectKindIcon.size,
                          weight: missingFile ? MissingFileLabel.weight
                                              : MissingFileLabel.normalWeight))
            .foregroundStyle(missingFile ? MissingFileLabel.color : Color.black)
            .shadow(color: missingFile ? MissingFileLabel.haloColor : .clear,
                    radius: missingFile ? MissingFileLabel.haloRadius : 0)
    }
}
