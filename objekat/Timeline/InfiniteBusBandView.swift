//
//  InfiniteBusBandView.swift
//  objekat
//
//  The band of an INFINITE bus (an aux or a group with no start/end) in the timeline.
//  Unlike a clip, it has no time edges: it is set on the VISIBLE WINDOW, so that its rounded
//  corners always stay at the left and right of the screen instead of going off with the start
//  of the project. The rest of the visual language is that of the matching block (a pale
//  stem-tinted background, a big radius, and for an aux the 'receives' mesh of
//  GlyphTilePattern), so that an infinite bus stays recognisable as an aux or a group.
//

import SwiftUI

struct InfiniteBusBandView: View {
    let item: SoundObject
    /// The stem colour (or a custom colour) carried by the bus.
    let color: Color
    let isSelected: Bool
    let isMuted: Bool
    let blockHeight: Double
    /// The y of the band's top in the canvas.
    let yPos: Double
    /// EXACT horizontal scrolling. The band being set on the visible window, it has to follow to
    /// the pixel: so it goes through the observable object rather than through the parent's notched
    /// culling window, which would make it lag by half a screen. Read here and not in the timeline's
    /// body, this dependency invalidates that band alone. @see TimelineScrollAnchor
    var scrollAnchor: TimelineScrollAnchor
    let viewportWidth: CGFloat

    private var scrollOffsetX: CGFloat { scrollAnchor.x }
    /// Rendering the composite of the children for an infinite GROUP (an aux has no content).
    var waveformCache: WaveformCache
    let pixelsPerSecond: Double
    let waveformDisplayDB: Double
    var isRenaming: Bool = false
    var onRename: (String?) -> Void = { _ in }

    @State private var editLabel: String = ""
    @FocusState private var renameFocused: Bool

    /// The same radius as the aux / group blocks (see SoundBlockView.cornerRadius).
    private let cornerRadius: Double = 20
    /// The margin between the band and the viewport's edges, so that the radius can be seen.
    private let inset: Double = 3

    private var bandWidth: Double { max(80, Double(viewportWidth) - 2 * inset) }

    /// The instant (s) of the band's left edge: it is set on the viewport, not on time 0.
    /// It serves as the reference for the composite of the children, which carry ABSOLUTE startTimes.
    private var bandStartTime: Double {
        pixelsPerSecond > 0 ? (Double(scrollOffsetX) + inset) / pixelsPerSecond : 0
    }

    /// The bus's own modifier: gain alone. An infinite bus has NEITHER a window NOR fades — so the
    /// composite must be neither bounded nor faded at the edges (fadeIn/Out = 0 ⇒ no gate).
    private var rootMod: WaveformShaping.Modifier {
        WaveformShaping.Modifier(absStart: 0, duration: 0, fadeIn: 0, fadeOut: 0,
                                 gain: WaveformShaping.linearGain(dB: item.volume))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.white)
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(color.opacity(isSelected ? 0.55 : 0.30))
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(isSelected ? Color.accentColor : color.opacity(0.5),
                              lineWidth: isSelected ? 2 : 1.5)

            // An infinite group: one sees what is INSIDE. The same composite as the group block
            // (GroupWaveformView), simply reset on the band — which starts at the viewport's left edge
            // and not at time 0, hence the `bandStartTime` reference. So it scrolls with the content
            // while the band itself stays full screen.
            if case .group(let children, _) = item.kind {
                GroupWaveformView(
                    waveformCache: waveformCache,
                    children: children,
                    groupStartTime: bandStartTime,
                    pixelsPerSecond: pixelsPerSecond,
                    stemColor: color,
                    blockXPos: Double(scrollOffsetX) + inset,
                    scrollOffsetX: scrollOffsetX,
                    viewportWidth: viewportWidth,
                    rootMod: rootMod,
                    rootMuted: item.isMuted,
                    waveformDisplayDB: waveformDisplayDB
                )
                .frame(width: bandWidth, height: blockHeight)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            }

            // An aux carries no file: it keeps its 'receives' mesh, infinite or not.
            if item.isAux {
                GlyphTilePattern(color: color.opacity(0.7), tile: 30, glyphSize: 17,
                              iconName: "arrow.down.right.circle")
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .allowsHitTesting(false)
            }

            if isMuted {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.black.opacity(0.38))
                    .allowsHitTesting(false)
            }

            HStack(spacing: 5) {
                Image(systemName: "infinity")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color.opacity(0.9))
                if !item.isAux {
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(color.opacity(0.85))
                }
                if isRenaming {
                    TextField(noLabel, text: $editLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.black)
                        .textFieldStyle(.plain)
                        .focused($renameFocused)
                        .onSubmit { onRename(editLabel) }
                        .onExitCommand { onRename(nil) }
                        .onAppear { beginRename() }
                } else {
                    Text(item.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                if item.isMuted {
                    Text(L("common.muteBadge"))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
        .frame(width: bandWidth, height: blockHeight, alignment: .topLeading)
        // Set on the viewport: the band follows the scrolling, and both its ends stay visible.
        .offset(x: Double(scrollOffsetX) + inset, y: yPos)
        // Like the other blocks: selection and dragging are resolved by the parent canvas.
        // Only the renaming field needs the events.
        .allowsHitTesting(isRenaming)
        // See SoundBlockView: `renameFocused` stays true when the field goes away, and the
        // next rename of the same bus would never get focus.
        .onChange(of: isRenaming) { _, now in
            if now { beginRename() } else { renameFocused = false }
        }
    }

    /// Starts typing a name: the initial text, then focus on the next runloop turn.
    private func beginRename() {
        editLabel = item.label ?? ""
        DispatchQueue.main.async { renameFocused = true }
    }
}
