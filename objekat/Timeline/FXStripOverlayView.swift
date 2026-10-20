import AppKit
import SwiftUI

/// The FX tool's hover: WHICH object shows its strip, and where. A store of its own, written by
/// the canvas's hover handler and read by the strip alone — so a hover under the FX tool redraws
/// one small view, never the timeline (@see TimelineHoverStore for the same reasoning).
@MainActor @Observable
final class FXStripHoverStore {
    struct Shown: Equatable {
        let objectID: UUID
        /// The block's rectangle, content coordinates.
        var block: CGRect
        /// Where the pointer came onto the block: the strip is centred there.
        let anchorX: CGFloat
        /// The strip's rectangle, content coordinates (@see FXStripLayout.placement).
        var frame: CGRect
    }
    private(set) var shown: Shown?

    func set(_ s: Shown?) { if shown != s { shown = s } }

    /// The strip's rectangle while it is up, for the canvas's guards.
    func contains(_ p: CGPoint) -> Bool { shown.map { $0.frame.contains(p) } ?? false }
}

/// The strip itself: one row of boxes, left to right in the chain's order (@see FXStripLayout).
/// Laid in the canvas at `store.shown.frame`; it owns its clicks — the canvas steps aside over it.
struct FXStripOverlayView: View {
    let viewModel: EditViewModel
    let store: FXStripHoverStore

    var body: some View {
        if viewModel.activeTool == .toolFX, let s = store.shown {
            let model = viewModel.fxStripModel(objectID: s.objectID)
            let lay = FXStripLayout.layout(model)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                if model.isEmpty {
                    Text(L("fx.strip.empty"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: lay.size.width, height: lay.size.height)
                }
                ForEach(lay.bins, id: \.bin) { f in
                    binFrame(model.bins[f.bin], rect: f.rect)
                }
                ForEach(lay.boxes, id: \.entry) { b in
                    FXStripBoxView(entry: model.entries[b.entry],
                                   onToggle: { viewModel.toggleFXStripEntry(objectID: s.objectID, entry: $0) },
                                   onOpen: { viewModel.openFXStripEditor(objectID: s.objectID, entryID: $0) })
                        .frame(width: b.rect.width, height: b.rect.height)
                        .offset(x: b.rect.minX, y: b.rect.minY)
                }
            }
            .frame(width: lay.size.width, height: lay.size.height, alignment: .topLeading)
            .offset(x: s.frame.minX, y: s.frame.minY)
        }
    }

    private func binFrame(_ bin: FXStripBin, rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor.opacity(0.7),
                              style: StrokeStyle(lineWidth: 1, dash: bin.isDetached ? [3, 2] : []))
            Text(verbatim: bin.name)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 4)
                .padding(.top, 1)
                .frame(width: rect.width, alignment: .leading)
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .offset(x: rect.minX, y: rect.minY)
        .allowsHitTesting(false)
    }
}

/// One box: the plugin's name, a power button (a plugin and an instrument only), the double click
/// that opens its window. No VU, no ✕: removing a plugin stays the signal view's gesture.
private struct FXStripBoxView: View {
    let entry: FXStripEntry
    let onToggle: (FXStripEntry) -> Void
    let onOpen: (UUID) -> Void

    var body: some View {
        let dim = entry.hasToggle && !entry.isEnabled
        HStack(spacing: 3) {
            if entry.hasToggle {
                Button { onToggle(entry) } label: {
                    Image(systemName: "power")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(entry.isEnabled ? Color.green : Color.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("synoptic.bypass"))
            } else if case .rack(let n) = entry.kind {
                Text(verbatim: "∥ \(n)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "dial.low")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            Text(verbatim: entry.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(dim ? Color.secondary : Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(dim ? 0.04 : 0.10))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if entry.opensEditor { onOpen(entry.id) } }
        .help(helpText)
    }

    private var helpText: String {
        switch entry.kind {
        case .instrument, .plugin: return L("fx.strip.openEditor.help")
        case .gainStage:           return L("fx.strip.gainStage.help")
        case .rack:                return ([L("fx.strip.rack.help")] + entry.detail).joined(separator: "\n")
        }
    }
}
