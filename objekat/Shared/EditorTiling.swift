import CoreGraphics
import Foundation

/// Lays several plugin editor windows opened TOGETHER (a double click on a multiple selection)
/// within a screen area. Pure geometry, AppKit coordinates (bottom-left origin); an origin is a
/// window frame's origin.
///
/// The choice is made over the WHOLE batch, in chain order:
/// - **rows** — side by side from the TOP-LEFT corner, `gap` apart, when every window fits
///   without overlapping;
/// - **corners** — otherwise: window 1 in the top-left corner, 2 top-right, 3 bottom-left,
///   4 bottom-right, edges against the area's edges (big windows overlap in the middle, each
///   keeps its corner). Past 4, piles: window i goes back to corner i % 4, shifted `stackStep`
///   towards the centre per depth (i / 4). Always clamped so that the title bar never leaves the
///   area, and no window leaves it more than its size imposes (one bigger than the area keeps
///   its title bar on screen, anchored top-left).
///
/// The sizes of AU/VST editors are only known once their window exists, so the batch is laid
/// again over the windows already there each time one appears (`layout` is prefix-stable: an
/// arrival never moves the earlier ones, except when it flips the whole batch to corners).
struct EditorTiling {
    enum Mode: Equatable { case rows, corners }

    struct Layout {
        var mode: Mode
        /// One origin per size, same order.
        var origins: [CGPoint]
        /// Indices from the back to the front (corners only — rows never overlap): the higher a
        /// window's top edge, the further back, so that no window covers a title bar sitting
        /// higher than its own top. Top corners: the deeper one (lower) comes in front — the
        /// classic cascade; bottom corners: the deeper one (higher) goes behind.
        var backToFront: [Int]
    }

    // MARK: Batch state (the placement under way)

    let area: CGRect
    /// The batch in chain order — window 1 = the first plugin of the chain.
    let order: [UUID]
    /// The ones whose window has not appeared yet.
    var pending: Set<UUID>
    var startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime

    init(area: CGRect, order: [UUID]) {
        self.area = area
        self.order = order
        self.pending = Set(order)
    }

    /// The batch members whose window has appeared, in chain order.
    var arrived: [UUID] { order.filter { !pending.contains($0) } }

    // MARK: Pure geometry

    static let defaultGap: CGFloat = 8
    static let defaultStackStep: CGFloat = 28

    static func layout(sizes: [CGSize], in area: CGRect,
                       gap: CGFloat = defaultGap, stackStep: CGFloat = defaultStackStep) -> Layout {
        if let origins = rows(sizes: sizes, in: area, gap: gap) {
            return Layout(mode: .rows, origins: origins, backToFront: Array(sizes.indices))
        }
        let origins = sizes.enumerated().map { i, s in
            corner(index: i, size: s, in: area, stackStep: stackStep)
        }
        let tops = zip(origins, sizes).map { $0.y + $1.height }
        let backToFront = sizes.indices.sorted { a, b in
            tops[a] != tops[b] ? tops[a] > tops[b] : a < b
        }
        return Layout(mode: .corners, origins: origins, backToFront: backToFront)
    }

    /// Rows from the top-left corner, or nil as soon as one window does not fit.
    static func rows(sizes: [CGSize], in area: CGRect, gap: CGFloat) -> [CGPoint]? {
        var x = area.minX, top = area.maxY, rowHeight: CGFloat = 0
        var origins: [CGPoint] = []
        for size in sizes {
            if x > area.minX, x + size.width > area.maxX {   // the next row
                top -= rowHeight + gap
                x = area.minX
                rowHeight = 0
            }
            guard x + size.width <= area.maxX, top - size.height >= area.minY else { return nil }
            origins.append(CGPoint(x: x, y: top - size.height))
            x += size.width + gap
            rowHeight = max(rowHeight, size.height)
        }
        return origins
    }

    /// Corner `index % 4` (TL, TR, BL, BR), shifted `stackStep × index / 4` towards the centre.
    static func corner(index: Int, size: CGSize, in area: CGRect, stackStep: CGFloat) -> CGPoint {
        let off = stackStep * CGFloat(index / 4)
        let left = index % 2 == 0
        let top = (index % 4) < 2
        let rawX = left ? area.minX + off : area.maxX - size.width - off
        let rawY = top ? area.maxY - size.height - off : area.minY + off
        return clamped(CGPoint(x: rawX, y: rawY), size: size, in: area)
    }

    /// Inside the area when it fits; otherwise anchored top-left (title bar on screen).
    static func clamped(_ p: CGPoint, size: CGSize, in area: CGRect) -> CGPoint {
        let xHi = area.maxX - size.width
        let yHi = area.maxY - size.height
        let x = xHi < area.minX ? area.minX : min(max(p.x, area.minX), xHi)
        let y = yHi < area.minY ? yHi : min(max(p.y, area.minY), yHi)
        return CGPoint(x: x, y: y)
    }
}
