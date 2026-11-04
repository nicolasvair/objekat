import SwiftUI

/// The meter of a MIDI input's rectangle (docs/plan_retours_2026-11-04.md, L10). A MIDI input carries notes, not a
/// level, so the bar the card's inputs use would claim something it does not measure:
///
/// - WITHOUT an instrument (`level == nil`) there is nothing to measure but the activity itself: the pale track of the
///   other meters, and at its left a few pixels of blue while notes arrive. Never a bar that fills up.
/// - WITH an instrument (`level` is its output, 0...1 on `VUScale`, already smoothed) the bar is the instrument's
///   output, and the same blue mark sits ABOVE it, so one reads both the notes coming in and the sound going out.
///
/// The blue is `Color.accentColor`, the colour of the computer keyboard's button. Total height 5 pt in both cases
/// (the slot `InputStrip` gives its meter), whatever the instrument's presence: the rectangle does not change size
/// when an instrument is dropped on it.
struct MidiActivityMeter: View {
    /// Notes arrived a moment ago (the caller holds the flag for a few ticks so a single note stays visible).
    let activity: Bool
    /// The instrument's output level, nil when the input has no instrument (or is not heard).
    let level: Double?

    /// The width of the blue mark: a few pixels, which is the whole point.
    static let markWidth: CGFloat = 6

    var body: some View {
        if let level {
            VStack(alignment: .leading, spacing: 0) {
                mark(height: 2)
                VULevelBar(level: level, height: 3)
            }
        } else {
            Capsule()
                .fill(Color.secondary.opacity(0.2))
                .frame(height: 3)
                .overlay(alignment: .leading) { mark(height: 3) }
        }
    }

    /// The blue mark, laid at the left while there is activity; an empty space of the same height otherwise (so the
    /// instrument's bar does not move when the mark comes and goes).
    private func mark(height: CGFloat) -> some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: Self.markWidth, height: height)
            .opacity(activity ? 1 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
