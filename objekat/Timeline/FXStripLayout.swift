import CoreGraphics
import Foundation

// MARK: - The FX tool's strip: what it shows, and where
//
// Under the FX tool (F) hovering an object shows its chain as ONE row of small boxes, left to
// right in the order the signal goes through them — a reading of the signal view with the plugins
// only: no VU, no sends, no mixer. Each box answers two gestures, the power button and the double
// click that opens the plugin's window, both through the signal view's own functions.
//
// This file is the half with nothing behind it — no view, no model, no engine — so that it can be
// compiled alone and asserted (`tools/test_fx_strip_layout.swift`), for the reason `SendColumns`
// and `SynopticMarquee` are units: what is drawn and what answers the hand read ONE definition.

/// One box of the strip.
struct FXStripEntry: Equatable {
    enum Kind: Equatable {
        /// A MIDI object's instrument, shown first (it is the head of the chain).
        case instrument
        /// A plain plugin of the chain (or of an FX link's block).
        case plugin
        /// A gain stage: a box with no power button (it has no bypass of its own).
        case gainStage
        /// A parallel block, drawn as ONE box carrying its branch count; no power button (the
        /// rack itself has no bypass — its leaves do, in the signal view).
        case rack(branches: Int)
    }
    let id: UUID
    let kind: Kind
    let name: String
    let isEnabled: Bool
    /// The FX link block it sits in (an index into `FXStripModel.bins`), nil on the trunk.
    let bin: Int?
    /// For a rack: the names of its plugins, branch by branch (its tooltip).
    var detail: [String] = []

    var hasToggle: Bool { kind == .instrument || kind == .plugin }
    /// A box whose double click opens a plugin window (a rack has none of its own).
    var opensEditor: Bool { kind == .instrument || kind == .plugin }
}

/// One FX link block of the strip: a framed group of boxes, with the bin's name.
struct FXStripBin: Equatable {
    let id: UUID
    let name: String
    let isDetached: Bool
}

/// The strip of one object.
struct FXStripModel: Equatable {
    var entries: [FXStripEntry] = []
    var bins: [FXStripBin] = []
    var isEmpty: Bool { entries.isEmpty }
}

enum FXStripLayout {

    static let boxWidth: CGFloat = 92
    static let boxHeight: CGFloat = 24
    static let gap: CGFloat = 4
    /// The strip's inner margin.
    static let padding: CGFloat = 5
    /// A bin's frame: inner margin and the band its name is written in, above the boxes.
    static let binPad: CGFloat = 3
    static let binHeader: CGFloat = 11
    /// How far the strip comes down over the block's top edge (or up over its bottom edge): the
    /// two touch, so the pointer can travel from one to the other without leaving both.
    static let overlap: CGFloat = 6
    /// The margin around the strip inside which the pointer still counts as on it.
    static let keepMargin: CGFloat = 4
    /// The empty strip ("no plugin"): one box's room.
    static let emptyWidth: CGFloat = boxWidth

    struct Box: Equatable {
        let entry: Int
        let rect: CGRect
    }
    struct BinFrame: Equatable {
        let bin: Int
        let rect: CGRect
    }
    struct Result: Equatable {
        var boxes: [Box] = []
        var bins: [BinFrame] = []
        var size: CGSize = .zero
    }

    /// The boxes and the bins' frames in the strip's own coordinates (origin top-left), and the
    /// strip's size. Consecutive entries of one bin share ONE frame; a box enters a frame by
    /// `binPad` on each side.
    static func layout(_ model: FXStripModel) -> Result {
        guard !model.entries.isEmpty else {
            return Result(size: CGSize(width: emptyWidth + 2 * padding, height: boxHeight + 2 * padding))
        }
        let hasBins = model.entries.contains { $0.bin != nil }
        let top = padding + (hasBins ? binHeader + binPad : 0)
        var out = Result()
        var x = padding
        var frameStart: (bin: Int, x: CGFloat)? = nil
        func closeFrame() {
            guard let f = frameStart else { return }
            let r = CGRect(x: f.x, y: padding, width: x + binPad - f.x,
                           height: top + boxHeight + binPad - padding)
            out.bins.append(BinFrame(bin: f.bin, rect: r))
            x += binPad
            frameStart = nil
        }
        for (i, e) in model.entries.enumerated() {
            let opensFrame: Bool
            if i > 0 {
                let changes = model.entries[i - 1].bin != e.bin
                if changes { closeFrame() }
                x += gap
                opensFrame = changes
            } else {
                opensFrame = true
            }
            if opensFrame, let b = e.bin {
                frameStart = (b, x)
                x += binPad
            }
            out.boxes.append(Box(entry: i, rect: CGRect(x: x, y: top, width: boxWidth, height: boxHeight)))
            x += boxWidth
        }
        closeFrame()
        x += padding
        out.size = CGSize(width: x, height: top + boxHeight + (hasBins ? binPad : 0) + padding)
        return out
    }

    /// Where the strip goes, in CONTENT coordinates: ABOVE the block, coming down `overlap` over
    /// its top edge; BELOW it (coming up over its bottom edge) when there is no room above inside
    /// `visible`. Horizontally centred on `anchorX` (where the pointer came onto the block), kept
    /// inside the block as far as it is wide enough, then inside `visible`.
    static func placement(size: CGSize, block: CGRect, anchorX: CGFloat, visible: CGRect) -> CGRect {
        var x = anchorX - size.width / 2
        x = min(max(x, block.minX), max(block.minX, block.maxX - size.width))
        x = min(max(x, visible.minX), max(visible.minX, visible.maxX - size.width))
        let above = block.minY + overlap - size.height
        let y = above >= visible.minY ? above : block.maxY - overlap
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Whether the strip stays up with the pointer at `p`: on the strip (within `keepMargin`) or on
    /// its block. The two touch (@see overlap), so going from one to the other never leaves both.
    static func keeps(_ p: CGPoint, overlay: CGRect, block: CGRect) -> Bool {
        overlay.insetBy(dx: -keepMargin, dy: -keepMargin).contains(p) || block.contains(p)
    }

    /// The box under `p` (strip coordinates), if any.
    static func box(at p: CGPoint, in result: Result) -> Box? {
        result.boxes.first { $0.rect.contains(p) }
    }
}
