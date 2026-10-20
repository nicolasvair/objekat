import CoreGraphics
import Foundation

// MARK: - The FX tool's mini signal view: what it shows, and where
//
// Under the FX tool (F) the hovered object shows its chain INSIDE its own block, over its darkened
// content: small boxes left to right in the order the signal goes through them, joined by wires; a
// parallel block splits the wire into one ROW per branch, its plugins stacked vertically, and joins
// it again after them. A reading of the signal view with the plugins only: no VU, no sends, no mixer.
//
// It degrades with the room the block leaves it, in this order: boxes with a power button and a
// truncated name → dots with no text (the branches still stacked) → dots with each parallel block
// folded into one dot → a bare "n FX" → nothing.
//
// This file is the half with nothing behind it — no view, no model, no engine — so that it can be
// compiled alone and asserted (`tools/test_fx_strip_layout.swift`), for the reason `SendColumns`
// and `SynopticMarquee` are units: what is drawn and what answers the hand read ONE definition
// (the overlay draws `layout(_:in:)`, the canvas's hover and tap hit-test the same result).

/// One plugin of the chain (or the carrier of a parallel block).
struct FXStripEntry: Equatable {
    enum Kind: Equatable {
        /// A MIDI object's instrument, shown first (it is the head of the chain).
        case instrument
        /// A plain plugin of the chain (of a branch, or of an FX link's block).
        case plugin
        /// A gain stage: a box with no power button (it has no bypass of its own).
        case gainStage
        /// A parallel block's CARRIER: drawn as the split and the join of its branches, or as ONE
        /// box when there is no room for the branches. No power button (the rack itself has no
        /// bypass — its leaves do).
        case rack(branches: Int)
    }
    let id: UUID
    let kind: Kind
    let name: String
    let isEnabled: Bool
    /// The FX link block it sits in (an index into `FXStripModel.bins`), nil on the trunk.
    let bin: Int?
    /// For a rack: the names of its plugins, branch by branch (its tooltip once folded).
    var detail: [String] = []
    /// For a plugin inside a parallel block: the carrier's index in `entries`, and its branch.
    var rack: Int? = nil
    var branch: Int? = nil

    var hasToggle: Bool { kind == .instrument || kind == .plugin }
    /// A box whose double click opens a plugin window (a rack has none of its own).
    var opensEditor: Bool { kind == .instrument || kind == .plugin }
    var isRack: Bool { if case .rack = kind { return true }; return false }
}

/// One FX link block: a frame around its boxes.
struct FXStripBin: Equatable {
    let id: UUID
    let name: String
    let isDetached: Bool
}

/// The chain as a tree: a series of nodes, a parallel block holding one series per branch.
indirect enum FXStripNode: Equatable {
    case leaf(Int)
    case rack(Int, [[FXStripNode]])
}

/// The chain of one object.
struct FXStripModel: Equatable {
    var entries: [FXStripEntry] = []
    var bins: [FXStripBin] = []
    /// The top-level series (indices into `entries`).
    var root: [FXStripNode] = []
    var isEmpty: Bool { root.isEmpty }

    /// What the bare count says: every box but a rack's carrier.
    var plugInCount: Int { entries.filter { !$0.isRack }.count }
}

enum FXStripLayout {

    /// How much of the chain the room allows.
    enum Detail: Equatable {
        /// Boxes with a power button and a (truncated) name, branches stacked.
        case labeled
        /// Dots with no text, branches stacked.
        case dots
        /// Dots, every parallel block folded into ONE dot.
        case foldedDots
        /// "n FX".
        case count
        /// No plugin at all: the "no plugins" line.
        case empty
        /// Not even that fits.
        case none
    }

    /// One box. `folded` = a rack's carrier drawn as one box; `power` = its power button's zone.
    struct Box: Equatable {
        let entry: Int
        let rect: CGRect
        var power: CGRect? = nil
        var folded: Bool = false
    }
    struct BinFrame: Equatable {
        let bin: Int
        let rect: CGRect
    }
    struct Result: Equatable {
        var detail: Detail = .none
        var boxes: [Box] = []
        /// The wires, as polylines.
        var wires: [[CGPoint]] = []
        var bins: [BinFrame] = []
        /// Where the "n FX" or the "no plugins" text goes.
        var textRect: CGRect? = nil
        /// The bounding box of what is drawn.
        var bounds: CGRect = .zero
    }

    /// What the hand is on.
    struct Hit: Equatable {
        let entry: Int
        let onPower: Bool
    }

    // MARK: - Metrics

    struct Metrics: Equatable {
        let minRow: CGFloat, maxRow: CGFloat
        let minBox: CGFloat, maxBox: CGFloat
        let gap: CGFloat, rowGap: CGFloat
        let binPad: CGFloat
        /// A box's width as a function of its row height (a dot), or nil (a free width).
        let dotAspect: CGFloat?
    }
    static let labeledMetrics = Metrics(minRow: 13, maxRow: 18, minBox: 44, maxBox: 120,
                                        gap: 9, rowGap: 3, binPad: 3, dotAspect: nil)
    static let dotMetrics = Metrics(minRow: 5, maxRow: 11, minBox: 5, maxBox: 20,
                                    gap: 6, rowGap: 2, binPad: 2, dotAspect: 1.6)
    /// The room around the drawing, inside the area.
    static let padding: CGFloat = 3
    /// The smallest area the "n FX" / "no plugins" text is written in.
    static let minTextHeight: CGFloat = 9
    static let minTextWidth: CGFloat = 22

    // MARK: - Layout

    /// The boxes, wires and frames of `model` in `area` (whatever coordinates `area` is in): the
    /// richest detail that fits, centred in it.
    static func layout(_ model: FXStripModel, in area: CGRect) -> Result {
        let inner = area.insetBy(dx: padding, dy: padding)
        guard inner.width > 0, inner.height > 0 else { return Result() }
        if model.isEmpty {
            return textResult(.empty, area: inner)
        }
        if let r = fit(model.root, metrics: labeledMetrics, detail: .labeled, model: model, in: inner) { return r }
        if let r = fit(model.root, metrics: dotMetrics, detail: .dots, model: model, in: inner) { return r }
        let folded = fold(model.root)
        if folded != model.root,
           let r = fit(folded, metrics: dotMetrics, detail: .foldedDots, model: model, in: inner) { return r }
        return textResult(.count, area: inner)
    }

    /// The size the labeled detail needs at its smallest (the API's `size`).
    static func labeledSize(_ model: FXStripModel) -> CGSize {
        guard !model.isEmpty else { return CGSize(width: minTextWidth + 2 * padding, height: minTextHeight + 2 * padding) }
        let m = labeledMetrics
        return CGSize(width: seriesWidth(model.root, box: m.minBox, m: m) + 2 * padding,
                      height: seriesHeight(model.root, row: m.minRow, m: m) + 2 * padding)
    }

    /// What lies under `p`: a box, and whether on its power button.
    static func hit(_ p: CGPoint, in r: Result) -> Hit? {
        guard let b = r.boxes.first(where: { $0.rect.insetBy(dx: -1, dy: -1).contains(p) }) else { return nil }
        return Hit(entry: b.entry, onPower: b.power?.insetBy(dx: -1, dy: -1).contains(p) ?? false)
    }

    // MARK: - Internals

    private static func textResult(_ d: Detail, area: CGRect) -> Result {
        guard area.height >= minTextHeight, area.width >= minTextWidth else { return Result() }
        var r = Result(detail: d)
        r.textRect = area
        r.bounds = area
        return r
    }

    /// Every parallel block folded into one leaf (its carrier).
    static func fold(_ s: [FXStripNode]) -> [FXStripNode] {
        s.map { n in
            if case .rack(let c, _) = n { return .leaf(c) }
            return n
        }
    }

    private static func boxWidth(row: CGFloat, free: CGFloat, m: Metrics) -> CGFloat {
        if let a = m.dotAspect { return min(m.maxBox, max(m.minBox, (row * a).rounded())) }
        return free
    }

    /// A series' width: a wire before each node and one after the last.
    static func seriesWidth(_ s: [FXStripNode], box: CGFloat, m: Metrics) -> CGFloat {
        m.gap + s.reduce(0) { $0 + nodeWidth($1, box: box, m: m) + m.gap }
    }
    static func nodeWidth(_ n: FXStripNode, box: CGFloat, m: Metrics) -> CGFloat {
        switch n {
        case .leaf: return box
        case .rack(_, let branches):
            return branches.map { seriesWidth($0, box: box, m: m) }.max() ?? m.gap
        }
    }
    static func seriesHeight(_ s: [FXStripNode], row: CGFloat, m: Metrics) -> CGFloat {
        s.map { nodeHeight($0, row: row, m: m) }.max() ?? row
    }
    static func nodeHeight(_ n: FXStripNode, row: CGFloat, m: Metrics) -> CGFloat {
        switch n {
        case .leaf: return row
        case .rack(_, let branches):
            guard !branches.isEmpty else { return row }
            return branches.reduce(0) { $0 + seriesHeight($1, row: row, m: m) }
                + CGFloat(branches.count - 1) * m.rowGap
        }
    }

    /// The largest value in `lo…hi` for which `fits` holds (`fits` monotonic, true at `lo`).
    private static func largest(_ lo: CGFloat, _ hi: CGFloat, _ fits: (CGFloat) -> Bool) -> CGFloat {
        if fits(hi) { return hi }
        var a = lo, b = hi
        for _ in 0..<24 { let mid = (a + b) / 2; if fits(mid) { a = mid } else { b = mid } }
        return a.rounded(.down)
    }

    private static func fit(_ root: [FXStripNode], metrics m: Metrics, detail: Detail,
                            model: FXStripModel, in area: CGRect) -> Result? {
        guard seriesHeight(root, row: m.minRow, m: m) <= area.height else { return nil }
        let row = largest(m.minRow, m.maxRow) { seriesHeight(root, row: $0, m: m) <= area.height }
        let box: CGFloat
        if m.dotAspect != nil {
            box = boxWidth(row: row, free: 0, m: m)
            guard seriesWidth(root, box: box, m: m) <= area.width else {
                // A dot narrower than its aspect, down to its minimum.
                guard seriesWidth(root, box: m.minBox, m: m) <= area.width else { return nil }
                let b = largest(m.minBox, box) { seriesWidth(root, box: $0, m: m) <= area.width }
                return place(root, row: row, box: b, m: m, detail: detail, model: model, area: area)
            }
        } else {
            guard seriesWidth(root, box: m.minBox, m: m) <= area.width else { return nil }
            box = largest(m.minBox, m.maxBox) { seriesWidth(root, box: $0, m: m) <= area.width }
        }
        return place(root, row: row, box: box, m: m, detail: detail, model: model, area: area)
    }

    private static func place(_ root: [FXStripNode], row: CGFloat, box: CGFloat, m: Metrics,
                              detail: Detail, model: FXStripModel, area: CGRect) -> Result {
        var r = Result(detail: detail)
        let w = seriesWidth(root, box: box, m: m)
        let h = seriesHeight(root, row: row, m: m)
        let x0 = (area.minX + (area.width - w) / 2).rounded()
        let yc = area.midY.rounded() + 0.5
        r.bounds = CGRect(x: x0, y: yc - h / 2, width: w, height: h)

        func placeSeries(_ s: [FXStripNode], x: CGFloat, yc: CGFloat, topLevel: Bool) -> CGFloat {
            var x = x
            for n in s {
                r.wires.append([CGPoint(x: x, y: yc), CGPoint(x: x + m.gap, y: yc)])
                x += m.gap
                switch n {
                case .leaf(let i):
                    let rect = CGRect(x: x, y: yc - row / 2, width: box, height: row)
                    let e = model.entries[i]
                    var b = Box(entry: i, rect: rect, folded: e.isRack)
                    if detail == .labeled, e.hasToggle {
                        b.power = CGRect(x: x, y: rect.minY, width: min(row, box / 2), height: row)
                    }
                    r.boxes.append(b)
                    x += box
                case .rack(_, let branches):
                    let rw = nodeWidth(n, box: box, m: m)
                    let rh = nodeHeight(n, row: row, m: m)
                    var top = yc - rh / 2
                    var centres: [CGFloat] = []
                    for br in branches {
                        let bh = seriesHeight(br, row: row, m: m)
                        let byc = top + bh / 2
                        centres.append(byc)
                        let end = placeSeries(br, x: x, yc: byc, topLevel: false)
                        if end < x + rw { r.wires.append([CGPoint(x: end, y: byc), CGPoint(x: x + rw, y: byc)]) }
                        top += bh + m.rowGap
                    }
                    let lo = min(centres.min() ?? yc, yc), hi = max(centres.max() ?? yc, yc)
                    r.wires.append([CGPoint(x: x, y: lo), CGPoint(x: x, y: hi)])
                    r.wires.append([CGPoint(x: x + rw, y: lo), CGPoint(x: x + rw, y: hi)])
                    x += rw
                }
            }
            if topLevel || !s.isEmpty {
                r.wires.append([CGPoint(x: x, y: yc), CGPoint(x: x + m.gap, y: yc)])
                x += m.gap
            }
            return x
        }
        _ = placeSeries(root, x: x0, yc: yc, topLevel: true)

        // The FX link blocks: one frame per run of consecutive boxes of one bin.
        var run: (bin: Int, rect: CGRect)? = nil
        for b in r.boxes {
            let bin = model.entries[b.entry].bin
            if let cur = run, cur.bin == bin {
                run = (cur.bin, cur.rect.union(b.rect))
            } else {
                if let cur = run { r.bins.append(BinFrame(bin: cur.bin, rect: cur.rect.insetBy(dx: -m.binPad, dy: -m.binPad))) }
                run = bin.map { ($0, b.rect) }
            }
        }
        if let cur = run { r.bins.append(BinFrame(bin: cur.bin, rect: cur.rect.insetBy(dx: -m.binPad, dy: -m.binPad))) }
        return r
    }
}
