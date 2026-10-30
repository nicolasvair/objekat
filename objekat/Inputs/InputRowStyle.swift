import SwiftUI

/// The look of a row of the Inputs tab, in one place: the lists' own (the sound list's, the Finder's) — a
/// quiet row, a thin line under each, a faint accent for the selection — a little taller than the object
/// list's because a level meter lives on a second line. The constants and the chrome are shared so that a
/// sibling list (the MIDI inputs, later) wears exactly the same rows.
enum InputRowStyle {
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 6
    /// Between the row's controls line and its meter line.
    static let lineSpacing: CGFloat = 4
    static let minHeight: CGFloat = 34
    /// Between the controls of the first line.
    static let controlSpacing: CGFloat = 8
    /// The input's number: a fixed column, so that the name — and the meter under it — start at the same x
    /// on every row (« 13-14 » is the longest key a 16-channel card makes).
    static let numberWidth: CGFloat = 32

    /// The meter's width, as a fraction of the PANEL's width (not the row's).
    static let meterWidthFraction: CGFloat = 0.4
    /// The meter starts under the name: after the number and the gap.
    static var meterLeading: CGFloat { numberWidth + controlSpacing }

    /// The name: the lists' size, regular weight.
    static let nameFont: Font = .system(size: 11)
    /// The number: small, monospaced, quiet.
    static let numberFont: Font = .system(size: 10, design: .monospaced)

    /// The selected row's ground: the accent, faint.
    static let selectionFill = Color.accentColor.opacity(0.12)
}

extension View {
    /// The row's chrome: its padding, its minimum height, the selection ground, and the line under it.
    func inputRowChrome(isSelected: Bool) -> some View {
        VStack(spacing: 0) {
            self
                .padding(.horizontal, InputRowStyle.horizontalPadding)
                .padding(.vertical, InputRowStyle.verticalPadding)
                .frame(minHeight: InputRowStyle.minHeight)
                .background(isSelected ? InputRowStyle.selectionFill : Color.clear)
            Divider()
        }
    }
}
