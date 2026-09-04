import SwiftUI

/// The insertion caret: the line that says where editing begins — and where playback will resume.
///
/// It goes ABOVE everything (z 3.1: the band background, the blocks, the waveforms), so a single
/// colour cannot hold — solid black, it disappeared on the dark background of the dark
/// appearance. Its colour therefore follows what it COVERS: black as soon as it falls on an
/// object (blocks are light and coloured in both appearances), otherwise the band background's
/// ink — white in the dark appearance, black in the light one.
struct InsertionCaret: View {

    let height: Double
    /// True if a block covers the WHOLE line (computed by the timeline, which alone knows how the
    /// display lanes are flattened). Laid exactly on a block's start — the commonest position, the
    /// one where snapping drops the caret — the line straddles: it then keeps the background's ink,
    /// which reads better there.
    let overObject: Bool

    static let width: Double = 1.5
    /// The offset to apply so as to centre the line on the instant aimed at.
    static var halfWidth: Double { width / 2 }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(overObject || colorScheme != .dark ? Color.black : .white)
            .frame(width: Self.width, height: height)
            .allowsHitTesting(false)
    }
}
