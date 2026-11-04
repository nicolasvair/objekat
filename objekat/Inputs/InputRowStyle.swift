import SwiftUI

/// The measures of the Inputs tab's content, in one place: the input rectangles (@see InputStrip, `StripStyle` for their
/// look) and the greyed rows of the chains whose input is not there. The rectangles are the stems' strips; what is shared
/// here is the number column (so that the name starts at the same x on every one — « 13-14 » is the longest key a 16-channel
/// card makes) and the fonts.
enum InputRowStyle {
    /// The list's margin: the rectangles sit this far from the panel's edges.
    static let horizontalPadding: CGFloat = 8
    /// Between two rectangles.
    static let stripSpacing: CGFloat = 4
    /// Between the controls line and the meter line inside a rectangle.
    static let lineSpacing: CGFloat = 3
    /// Between the controls of the first line.
    static let controlSpacing: CGFloat = 6
    /// The input's number (or the keys glyph): a fixed column.
    static let numberWidth: CGFloat = 30
    /// Where the second line starts: under the name.
    static var meterLeading: CGFloat { numberWidth + controlSpacing }

    /// The name: the lists' size, regular weight.
    static let nameFont: Font = .system(size: 11)
    /// The number: small, monospaced, quiet.
    static let numberFont: Font = .system(size: 10, design: .monospaced)
}
