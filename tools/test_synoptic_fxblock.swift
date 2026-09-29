import SwiftUI

// Standalone geometry test of an FX link's block in the signal view layout (step 5).
// swiftc -o /tmp/t_fxblock ../objekat/Inspector/Synoptic/SynopticGraph.swift ../objekat/Inspector/Synoptic/SynopticLayout.swift test_synoptic_fxblock.swift

func L(_ key: String, _ args: CVarArg...) -> String { key }

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

@main struct T {
    static func main() {
        func card(_ n: String) -> SynopticNode {
            SynopticNode(id: UUID(), kind: .plugin(SynopticPlugin(name: n, category: .eq)))
        }
        let a = card("EQ"), b = card("Compressor")
        let fx = SynopticFXLink(blockID: UUID(), name: "Bin", color: .red, isDetached: false,
                                isEnabled: true, gainDb: 0, pan: 0, muted: false, memberCount: 2)
        var block = SynopticNode(id: fx.blockID, kind: .series([a, b]))
        block.fxLink = fx
        let before = card("Before"), after = card("After")
        let root = SynopticNode(id: UUID(), kind: .series([before, block, after]))

        let size = SynopticLayout.measure(block)
        var bare = block; bare.fxLink = nil
        let inner = SynopticLayout.measure(bare)
        check(abs(size.height - (inner.height + SynopticLayout.fxHeaderH + SynopticLayout.fxFooterH)) < 0.001,
              "block height = inner + header + footer")
        check(size.width >= SynopticLayout.fxMinW, "block at least fxMinW wide")
        check(size.width >= inner.width + 2 * SynopticLayout.fxPad - 0.001, "block wider than its series by the padding")

        let pl = SynopticLayout.place(root, at: .zero)
        check(pl.fxBlocks.count == 1, "one frame laid")
        guard let f = pl.fxBlocks.first else { print("failures: \(failures)"); exit(1) }
        check(abs(f.rect.width - size.width) < 0.001 && abs(f.rect.height - size.height) < 0.001, "frame = measured size")
        for c in pl.cards where c.plugin.name == "EQ" || c.plugin.name == "Compressor" {
            check(f.rect.contains(c.frame), "\(c.plugin.name) inside the frame")
            check(c.frame.minY >= f.rect.minY + SynopticLayout.fxHeaderH - 0.001, "\(c.plugin.name) under the header")
            check(c.frame.maxY <= f.rect.maxY - SynopticLayout.fxFooterH + 0.001, "\(c.plugin.name) above the footer")
        }
        for c in pl.cards where c.plugin.name == "Before" || c.plugin.name == "After" {
            check(!f.rect.intersects(c.frame), "\(c.plugin.name) outside the frame")
        }
        check(pl.cards.count == 4, "four cards")
        check(f.headerCenter.y < f.footerCenter.y, "header above footer")
        check(abs(f.headerCenter.x - f.rect.midX) < 0.001, "controls centred on the wire")
        // The whole diagram still fits.
        check(pl.size.height >= f.rect.maxY - 0.001, "the diagram holds the frame")
        // Empty block: header and footer alone plus the '+' of the series.
        var empty = SynopticNode(id: UUID(), kind: .series([]))
        empty.fxLink = fx
        let es = SynopticLayout.measure(empty)
        check(es.height > SynopticLayout.fxHeaderH + SynopticLayout.fxFooterH, "an empty block still holds its '+'")
        print(failures == 0 ? "ALL PASS" : "failures: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
