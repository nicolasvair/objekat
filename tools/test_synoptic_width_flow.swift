import SwiftUI

// Standalone test of the channel-width arithmetic of the signal view (Synoptic/SynopticWidthFlow.swift):
// what width a chain carries from its source to its end, which plugin crushes a stereo signal, what the
// three variants (mono, mono→stereo, stereo) and their badge are.
//
//     swiftc -parse-as-library -o /tmp/t_wf \
//         ../objekat/Inspector/Synoptic/SynopticGraph.swift \
//         ../objekat/Inspector/Synoptic/SynopticWidthFlow.swift test_synoptic_width_flow.swift \
//         && /tmp/t_wf

func L(_ key: String, _ args: CVarArg...) -> String { key }

var failures = 0
var total = 0
func check(_ ok: Bool, _ what: String) {
    total += 1
    if !ok { failures += 1; print("FAIL: \(what)") }
}

func plugin(_ name: String, enabled: Bool = true, greyed: Bool = false) -> SynopticPlugin {
    SynopticPlugin(name: name, category: .utility, isEnabled: enabled, greyedByBlock: greyed)
}

let mono = PluginChannels(inputs: 1, outputs: 1)
let monoStereo = PluginChannels(inputs: 1, outputs: 2)
let stereo = PluginChannels(inputs: 2, outputs: 2)
let fold = PluginChannels(inputs: 2, outputs: 1)

@main
struct WidthFlowTest {
    static func main() {

        // --- variants and badge ----------------------------------------------------------------
        check(ChannelVariant(inputs: 1, outputs: 1) == .mono, "1->1 is mono")
        check(ChannelVariant(inputs: 1, outputs: 2) == .monoStereo, "1->2 is mono_stereo")
        check(ChannelVariant(inputs: 2, outputs: 2) == .stereo, "2->2 is stereo")
        check(ChannelVariant(inputs: 2, outputs: 1) == nil, "2->1 is none of the three")
        check(ChannelVariant(inputs: 6, outputs: 6) == nil, "surround is none of the three")
        check(ChannelVariant.mono.rawValue == "mono" && ChannelVariant.monoStereo.rawValue == "mono_stereo"
              && ChannelVariant.stereo.rawValue == "stereo", "raw values are the API's ids")
        check(ChannelVariant.allCases.count == 3, "three variants")
        for v in ChannelVariant.allCases {
            check(ChannelVariant(inputs: v.inputs, outputs: v.outputs) == v, "\(v) round-trips through its counts")
        }
        check(mono.badge == "1", "mono badge")
        check(monoStereo.badge == "1→2", "mono->stereo badge")
        check(stereo.badge == "2", "stereo badge")
        check(fold.badge == "2→1", "2->1 badge")
        check(PluginChannels(inputs: 6, outputs: 6).badge == "6", "surround badge")
        check(mono.variant == .mono && fold.variant == nil, "variant accessor")

        // --- one plugin: the width after it ----------------------------------------------------
        check(SynopticWidthFlow.nodeWidth(mono) == 1, "node width of a mono plugin")
        check(SynopticWidthFlow.nodeWidth(monoStereo) == 2, "node width of a mono->stereo plugin")
        check(SynopticWidthFlow.nodeWidth(stereo) == 2, "node width of a stereo plugin")
        check(SynopticWidthFlow.nodeWidth(fold) == 2, "node width of a 2->1 plugin")
        // mono signal
        check(SynopticWidthFlow.output(incoming: 1, through: mono) == 1, "mono through mono stays mono")
        check(SynopticWidthFlow.output(incoming: 1, through: monoStereo) == 2, "mono through 1->2 becomes stereo")
        check(SynopticWidthFlow.output(incoming: 1, through: stereo) == 2, "mono through stereo is widened")
        // stereo signal
        check(SynopticWidthFlow.output(incoming: 2, through: mono) == 2, "stereo through mono stays 2 wide (right goes dry)")
        check(SynopticWidthFlow.output(incoming: 2, through: monoStereo) == 2, "stereo through 1->2 is 2 wide")
        check(SynopticWidthFlow.output(incoming: 2, through: stereo) == 2, "stereo through stereo")

        // --- the warning ------------------------------------------------------------------------
        check(!SynopticWidthFlow.crushesStereo(incoming: 1, through: mono), "mono into mono: nothing to say")
        check(!SynopticWidthFlow.crushesStereo(incoming: 1, through: monoStereo), "mono into 1->2: nothing to say")
        check(!SynopticWidthFlow.crushesStereo(incoming: 2, through: stereo), "stereo into stereo: nothing to say")
        check(SynopticWidthFlow.crushesStereo(incoming: 2, through: mono), "stereo into mono: warning")
        check(SynopticWidthFlow.crushesStereo(incoming: 2, through: monoStereo), "stereo into a mono input: warning")
        check(SynopticWidthFlow.crushesStereo(incoming: 2, through: fold), "stereo into 2->1: warning")

        // --- the source ---------------------------------------------------------------------------
        check(SynopticWidthFlow.sourceWidth(fileChannels: 1) == 1, "mono file")
        check(SynopticWidthFlow.sourceWidth(fileChannels: 2) == 2, "stereo file")
        check(SynopticWidthFlow.sourceWidth(fileChannels: 6) == 2, "multichannel file is a stereo pair")
        check(SynopticWidthFlow.sourceWidth(fileChannels: nil) == 2, "unknown source is stereo")
        check(SynopticWidthFlow.sourceWidth(fileChannels: 0) == 2, "unreadable source is stereo")

        // --- a chain ---------------------------------------------------------------------------------
        do {
            let a = plugin("a"), b = plugin("b"), c = plugin("c")
            let root = SynopticNode.series([.plugin(a), .plugin(b), .plugin(c)])
            // mono file -> mono, 1->2, stereo : 1, 1, 2 ; ends stereo
            let f = SynopticWidthFlow.compute(root: root, sourceWidth: 1,
                                              channels: [a.id: mono, b.id: monoStereo, c.id: stereo])
            check(f.inputOf[a.id] == 1 && f.outputOf[a.id] == 1, "mono chain: a is 1 -> 1")
            check(f.inputOf[b.id] == 1 && f.outputOf[b.id] == 2, "mono chain: b widens to 2")
            check(f.inputOf[c.id] == 2 && f.outputOf[c.id] == 2, "mono chain: c is fed 2")
            check(f.crushed.isEmpty, "mono chain: nothing crushed")
            check(f.trunkOut == 2, "mono chain ends stereo")

            // stereo file through a mono plugin in the middle
            let g = SynopticWidthFlow.compute(root: root, sourceWidth: 2,
                                              channels: [a.id: stereo, b.id: mono, c.id: monoStereo])
            check(g.crushed == [b.id, c.id], "stereo chain: the mono plugin and the mono input are flagged")
            check(g.trunkOut == 2, "stereo chain ends stereo")

            // an all-mono chain on a mono file stays mono to its end
            let h = SynopticWidthFlow.compute(root: root, sourceWidth: 1,
                                              channels: [a.id: mono, b.id: mono, c.id: mono])
            check(h.trunkOut == 1 && h.crushed.isEmpty, "all-mono chain stays mono")

            // plugins the engine reports nothing for are transparent
            let t = SynopticWidthFlow.compute(root: root, sourceWidth: 1, channels: [:])
            check(t.trunkOut == 1 && t.crushed.isEmpty, "no channels reported: transparent")
            check(t.inputOf[b.id] == 1 && t.outputOf[b.id] == 1, "a transparent plugin passes the width through")
        }

        // --- bypass, grey, bin off -------------------------------------------------------------
        do {
            let a = plugin("a", enabled: false), b = plugin("b", greyed: true), c = plugin("c")
            let root = SynopticNode.series([.plugin(a), .plugin(b), .plugin(c)])
            let f = SynopticWidthFlow.compute(root: root, sourceWidth: 2,
                                              channels: [a.id: mono, b.id: mono, c.id: stereo])
            check(f.crushed.isEmpty, "a bypassed or greyed plugin crushes nothing")
            check(f.trunkOut == 2, "bypassed plugins are transparent")
            let m = SynopticWidthFlow.compute(root: root, sourceWidth: 1,
                                              channels: [a.id: monoStereo, b.id: monoStereo, c.id: mono])
            check(m.outputOf[a.id] == 1 && m.outputOf[b.id] == 1, "bypassed 1->2 does not widen")
            check(m.trunkOut == 1, "mono stays mono through bypassed widenings and a mono plugin")
        }
        do {
            let a = plugin("a"), b = plugin("b")
            var block = SynopticNode.series([.plugin(a)])
            block.fxLink = SynopticFXLink(blockID: UUID(), name: "bin", color: .red, isDetached: false,
                                          isEnabled: false, memberCount: 2)
            let root = SynopticNode.series([block, .plugin(b)])
            let f = SynopticWidthFlow.compute(root: root, sourceWidth: 2, channels: [a.id: mono, b.id: stereo])
            check(f.crushed.isEmpty && f.trunkOut == 2, "a bin that is OFF lets the signal through")
            block.fxLink?.isEnabled = true
            let g = SynopticWidthFlow.compute(root: .series([block, .plugin(b)]), sourceWidth: 2,
                                              channels: [a.id: mono, b.id: stereo])
            check(g.crushed == [a.id], "the same bin ON flags its mono plugin")
        }

        // --- parallel -----------------------------------------------------------------------------
        do {
            let a = plugin("a"), b = plugin("b"), tail = plugin("t")
            let root = SynopticNode.series([
                .parallel([.series([.plugin(a)]), .series([.plugin(b)])]),
                .plugin(tail),
            ])
            let f = SynopticWidthFlow.compute(root: root, sourceWidth: 1,
                                              channels: [a.id: mono, b.id: monoStereo, tail.id: stereo])
            check(f.inputOf[a.id] == 1 && f.inputOf[b.id] == 1, "both branches are fed the same width")
            check(f.inputOf[tail.id] == 2, "the sum is as wide as the widest branch")
            let g = SynopticWidthFlow.compute(root: root, sourceWidth: 1,
                                              channels: [a.id: mono, b.id: mono, tail.id: mono])
            check(g.inputOf[tail.id] == 1, "two mono branches sum to mono")
            let empty = SynopticWidthFlow.compute(root: .parallel([]), sourceWidth: 2, channels: [:])
            check(empty.trunkOut == 2, "an empty parallel is the identity")
        }

        print(failures == 0 ? "ALL PASS (\(total) assertions)" : "\(failures) FAILED of \(total)")
        exit(failures == 0 ? 0 : 1)
    }
}
