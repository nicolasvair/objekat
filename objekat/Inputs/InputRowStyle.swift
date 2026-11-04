import SwiftUI

/// The measures of the Inputs tab's content, in one place: the input rectangles (@see InputStrip, `StripStyle` for their
/// look) and the greyed rows of the chains whose input is not there. The rectangles are the stems' strips; what is shared
/// here is the leading column (so that the name starts at the same x on every one — « 13-14 » is the longest key a 16-channel
/// card makes, and the computer keyboard's octave selector has to fit it too) and the fonts.
enum InputRowStyle {
    /// The list's margin: the rectangles sit this far from the panel's edges.
    static let horizontalPadding: CGFloat = 8
    /// Between two rectangles.
    static let stripSpacing: CGFloat = 4
    /// Between the controls line and the meter line inside a rectangle.
    static let lineSpacing: CGFloat = 3
    /// Between the controls of the first line.
    static let controlSpacing: CGFloat = 6
    /// The leading column: the input's number, the keys glyph, or the computer keyboard's button with its octave
    /// under it. ONE width for every strip so the names stay aligned.
    static let leadingWidth: CGFloat = 56

    /// The name: the lists' size, regular weight.
    static let nameFont: Font = .system(size: 11)
    /// The number: large enough to read at a glance, monospaced, quiet.
    static let numberFont: Font = .system(size: 13, weight: .semibold, design: .monospaced)
}
