import SwiftUI

/// The stem the 'assign stem' tool is aiming at, in the form a block needs in order to
/// announce it. Resolved once by `TimelineView` (the block stays pure presentation).
struct StemAssignTarget: Equatable {
    /// A 1-based index, that of the held key — it is SAID, because it is what one aims with.
    let number: Int
    let name: String
    let color: Color
}

/// The hover veil of the Stem tool, on the model of `ToolVolumeLayer`: the hovered block covers
/// itself and announces what the click will do, in so many words and in the stem's colour.
///
/// Not a tooltip: that arrives late, sits next to the cursor and vanishes at the slightest
/// movement. Here the assignment reads on the object itself, the instant it becomes the target.
struct ToolStemLayer: View {
    let target: StemAssignTarget
    /// The hover is resolved by the canvas (`toolHoveredID`) — the block does not detect it itself.
    var forceShow: Bool = false
    /// The block's visible sub-window (in LOCAL coordinates), so that the text stays readable when
    /// the block overflows the viewport. nil = the whole block.
    var span: (x: Double, width: Double)? = nil
    var cornerRadius: Double = 4

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .overlay {
                if forceShow {
                    ZStack {
                        Color.black.opacity(0.72)
                        GeometryReader { geo in
                            let sx = span?.x ?? 0
                            let sw = span?.width ?? geo.size.width
                            HStack(spacing: 5) {
                                Circle().fill(target.color).frame(width: 8, height: 8)
                                Text(L("tool.stem.assignTo", target.number, target.name))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                            .padding(.horizontal, 4)
                            .frame(width: sw, height: geo.size.height)
                            .offset(x: sx)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .allowsHitTesting(false)
                }
            }
    }
}
