import SwiftUI

// Standalone test of the channel-width arithmetic of the signal view (Synoptic/SynopticWidthFlow.swift):
// what width a chain carries from its source to its end, where a wire merges (stereo into a mono input) or
// splits (mono into a stereo input), and how each wire of the view is drawn (one wire, two, orange or not).
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
        check(SynopticWidthFlow.output(incoming: 2, through: mono) == 2, "stereo through mono, no fold (legacy graph): 2 wide (right goes dry)")
        check(SynopticWidthFlow.output(incoming: 2, through: mono, fold: .sum) == 1, "stereo through mono summed: ONE wire out")
        check(SynopticWidthFlow.output(incoming: 2, through: mono, fold: .left) == 1, "stereo through mono, left chosen: ONE wire out")
        check(SynopticWidthFlow.output(incoming: 2, through: monoStereo, fold: .sum) == 2, "stereo through 1->2 summed: two wires out")
        check(SynopticWidthFlow.output(incoming: 2, through: monoStereo) == 2, "stereo through 1->2 is 2 wide")
        check(SynopticWidthFlow.output(incoming: 2, through: stereo) == 2, "stereo through stereo")

        // --- the adaptation at a plugin's input ------------------------------------------------
        check(SynopticWidthFlow.adaptation(incoming: 1, through: mono) == nil, "mono into mono: nothing to say")
        check(SynopticWidthFlow.adaptation(incoming: 1, through: monoStereo) == nil, "mono into 1->2: nothing to say")
        check(SynopticWidthFlow.adaptation(incoming: 2, through: stereo) == nil, "stereo into stereo: nothing to say")
        check(SynopticWidthFlow.adaptation(incoming: 2, through: mono) == .merge(fold: nil, rightPassesDry: true),
              "stereo into 1->1, no fold: merge, the right channel passes dry")
        check(SynopticWidthFlow.adaptation(incoming: 2, through: monoStereo) == .merge(fold: nil, rightPassesDry: false),
              "stereo into 1->2, no fold: merge, the right channel is not heard after it")
        check(SynopticWidthFlow.adaptation(incoming: 2, through: mono, fold: .left) == .merge(fold: .left, rightPassesDry: false),
              "stereo into 1->1, left chosen: the right channel is cut, not dry")
        check(SynopticWidthFlow.adaptation(incoming: 2, through: mono, fold: .sum) == .merge(fold: .sum, rightPassesDry: false),
              "stereo into 1->1 summed: nothing passes dry")
        check(SynopticWidthFlow.adaptation(incoming: 2, through: monoStereo, fold: .right) == .merge(fold: .right, rightPassesDry: false),
              "stereo into 1->2 on the right channel")
        check(SynopticWidthFlow.adaptation(incoming: 1, through: mono, fold: .sum) == nil, "mono into mono: the fold says nothing")
        check(SynopticWidthFlow.adaptation(incoming: 1, through: stereo, fold: .sum) == .split, "a fold does not touch a split")
        check(MonoFold(rawValue: "sum") == .sum && MonoFold.allCases.count == 3, "three folds, API ids")
        // THE switch for a plugin with no stored fold (decision of 21 October 2026: the sum).
        check(MonoFold.whenUnset == .sum, "a plugin saved before the choice plays the sum")
        check(MonoFold.played(nil) == .sum && MonoFold.played(.left) == .left && MonoFold.played(.right) == .right,
              "played: a stored fold wins, none = whenUnset")

        // --- how a merge is drawn ------------------------------------------------------------------
        check(WireLook.merge(.merge(fold: .sum, rightPassesDry: false)).shape == .sum, "sum: two wires joining")
        check(WireLook.merge(.merge(fold: .left, rightPassesDry: false)).shape == .pick(.left), "left: R stops with a cross")
        check(WireLook.merge(.merge(fold: .right, rightPassesDry: false)).shape == .pick(.right), "right: L stops with a cross")
        check(WireLook.merge(.merge(fold: nil, rightPassesDry: true)).shape == .parallel, "legacy 1->1: two wires on")
        check(WireLook.merge(.merge(fold: nil, rightPassesDry: false)).shape == .pick(.left), "legacy 1->2: R not heard")
        check(WireLook.merge(.split) == WireLook(count: 1, shape: .split, adaptation: .split), "split: one wire in two")
        for a in [WireAdaptation.merge(fold: .sum, rightPassesDry: false), .merge(fold: nil, rightPassesDry: true), .split] {
            check(WireLook.merge(a).isOrange, "every adaptation is orange: \(a)")
        }
        check(!WireLook(count: 2).isOrange && !WireLook(count: 1).isOrange, "plain wires are not orange")
        check(SynopticWidthFlow.adaptation(incoming: 1, through: stereo) == .split, "mono into stereo: split")
        check(SynopticWidthFlow.adaptation(incoming: 1, through: fold) == .split, "mono into 2->1: split")
        check(SynopticWidthFlow.adaptation(incoming: 2, through: fold) == nil, "stereo into 2->1: the input agrees")
        check(SynopticWidthFlow.adaptation(incoming: 1, through: PluginChannels(inputs: 0, outputs: 2)) == nil,
              "a plugin with no input (an instrument): nothing to say")

        // --- the source ---------------------------------------------------------------------------
        check(SynopticWidthFlow.sourceWidth(fileChannels: 1) == 1, "mono file")
        check(SynopticWidthFlow.sourceWidth(fileChannels: 2) == 2, "stereo file")
        check(SynopticWidthFlow.sourceWidth(fileChannels: 6) == 2, "multichannel file is a stereo pair")
        check(SynopticWidthFlow.sourceWidth(fileChannels: nil) == 2, "unknown source is stereo")
        check(SynopticWidthFlow.sourceWidth(fileChannels: 0) == 2, "unreadable source is stereo")

        // --- the look of a wire ------------------------------------------------------------------------
        do {
            let a = plugin("a"), b = plugin("b"), c = plugin("c")
            let na = SynopticNode.plugin(a), nb = SynopticNode.plugin(b), nc = SynopticNode.plugin(c)
            check(na.id != a.id, "a plugin node has an id of its own")
            let root = SynopticNode.series([na, nb, nc])
            // mono file -> 1->2 -> stereo -> mono : the 1->2 is NOT a warning, the mono after stereo merges
            let f = SynopticWidthFlow.compute(root: root, sourceWidth: 1,
                                              channels: [a.id: monoStereo, b.id: stereo, c.id: mono])
            check(f.look(.source) == WireLook(count: 1), "a mono source is one wire")
            check(f.look(.into(a.id)) == WireLook(count: 1), "into the 1->2: one wire, not orange")
            check(f.look(.after(a.id)) == WireLook(count: 2), "out of the 1->2: two wires")
            check(f.look(.into(b.id)) == WireLook(count: 2), "into the stereo plugin: two wires")
            check(f.look(.into(c.id)) == WireLook(count: 2, shape: .parallel, adaptation: .merge(fold: nil, rightPassesDry: true)),
                  "into the mono plugin with no fold: two wires, orange (the legacy graph)")
            check(f.look(.into(c.id))?.isOrange == true, "the merge is orange")
            check(f.look(.into(nc.id)) == f.look(.into(c.id)), "the node id and the plugin id read the same")
            check(f.look(.after(c.id)) == WireLook(count: 2), "after a 1->1 fed stereo: still two wires (R dry)")
            check(f.look(.trunk) == WireLook(count: 2), "the trunk ends stereo")
            check(f.look(.file) == WireLook(count: 1), "the file wire (into an ARA card) reads the file")
            check(f.look(.bus) == WireLook(count: 2), "after the mixer: a stereo pair")
            check(f.look(.after(root.id)) == WireLook(count: 2), "the series' output")
            check(f.look(.into(UUID())) == nil && f.look(.after(UUID())) == nil, "an unknown id: neutral")
            check(f.look(nil) == nil, "an untagged cable: neutral")
            check(f.adaptations.count == 2, "the merge is recorded under the plugin and its node")

            // mono source into a stereo plugin: one wire splitting, orange
            let g = SynopticWidthFlow.compute(root: .series([.plugin(b)]), sourceWidth: 1, channels: [b.id: stereo])
            check(g.look(.into(b.id)) == WireLook(count: 1, shape: .split, adaptation: .split),
                  "mono into stereo: one wire splitting, orange")
            check(g.look(.after(b.id)) == WireLook(count: 2), "then two wires")
            check(g.trunkOut == 2, "and the trunk is stereo")

            // stereo into a 1->2: merge, the right channel not heard after it
            let h = SynopticWidthFlow.compute(root: .series([.plugin(a)]), sourceWidth: 2, channels: [a.id: monoStereo])
            check(h.look(.into(a.id))?.adaptation == .merge(fold: nil, rightPassesDry: false), "stereo into 1->2: R not heard")

            // a fold is read per plugin id: a SUMMED mono plugin puts out ONE wire, which the stereo plugin
            // after it splits again (orange); no fold in the map = the legacy graph
            let k = SynopticWidthFlow.compute(root: .series([.plugin(c), .plugin(b)]), sourceWidth: 2,
                                              channels: [c.id: mono, b.id: stereo], folds: [c.id: .sum])
            check(k.look(.into(c.id)) == WireLook(count: 2, shape: .sum, adaptation: .merge(fold: .sum, rightPassesDry: false)),
                  "stereo into the summed mono plugin: a V, orange")
            check(k.look(.after(c.id)) == WireLook(count: 1), "out of it: ONE wire")
            check(k.look(.into(b.id)) == WireLook(count: 1, shape: .split, adaptation: .split),
                  "into the stereo plugin after it: the wire splits, orange")
            check(k.trunkOut == 2 && k.look(.trunk) == WireLook(count: 2), "the trunk is stereo again")
            check(k.mergePlugin[c.id] == c.id, "the merge names its plugin (the fold menu)")
            // a summed mono plugin LAST: the copy back to stereo is drawn at the mixer
            let m = SynopticWidthFlow.compute(root: .series([.plugin(c)]), sourceWidth: 2,
                                              channels: [c.id: mono], folds: [c.id: .left])
            check(m.look(.into(c.id))?.shape == .pick(.left), "left chosen: the right wire stops with a cross")
            check(m.trunkOut == 1 && m.look(.trunk) == WireLook(count: 1, shape: .split),
                  "a stereo source made mono: the trunk splits back into two, orange")
            check(m.look(.trunk)?.isOrange == true, "and that split is orange")
            // a mono FILE through a mono chain stays a plain single trunk
            let n = SynopticWidthFlow.compute(root: .series([.plugin(c)]), sourceWidth: 1, channels: [c.id: mono])
            check(n.look(.trunk) == WireLook(count: 1), "a mono file's mono trunk is not orange")

            // the demo / nothing computed
            let empty = SynopticWidthFlow()
            check(empty.isEmpty && empty.look(.source) == nil && empty.look(.bus) == nil, "an empty flow says nothing")
        }

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
            check(f.adaptations.isEmpty, "mono chain: no wire merges or splits")
            check(f.trunkOut == 2, "mono chain ends stereo")

            // stereo file through a mono plugin in the middle
            let g = SynopticWidthFlow.compute(root: root, sourceWidth: 2,
                                              channels: [a.id: stereo, b.id: mono, c.id: monoStereo])
            check(g.adaptations[b.id] == .merge(fold: nil, rightPassesDry: true) && g.adaptations[c.id] == .merge(fold: nil, rightPassesDry: false)
                  && g.adaptations[a.id] == nil, "stereo chain: the mono plugin and the mono input merge")
            check(g.trunkOut == 2, "stereo chain ends stereo")

            // an all-mono chain on a mono file stays mono to its end
            let h = SynopticWidthFlow.compute(root: root, sourceWidth: 1,
                                              channels: [a.id: mono, b.id: mono, c.id: mono])
            check(h.trunkOut == 1 && h.adaptations.isEmpty, "all-mono chain stays mono")
            check(h.look(.trunk) == WireLook(count: 1), "and its trunk is one wire")

            // plugins the engine reports nothing for are transparent
            let t = SynopticWidthFlow.compute(root: root, sourceWidth: 1, channels: [:])
            check(t.trunkOut == 1 && t.adaptations.isEmpty, "no channels reported: transparent")
            check(t.inputOf[b.id] == 1 && t.outputOf[b.id] == 1, "a transparent plugin passes the width through")
        }

        // --- bypass, grey, bin off -------------------------------------------------------------
        do {
            let a = plugin("a", enabled: false), b = plugin("b", greyed: true), c = plugin("c")
            let root = SynopticNode.series([.plugin(a), .plugin(b), .plugin(c)])
            let f = SynopticWidthFlow.compute(root: root, sourceWidth: 2,
                                              channels: [a.id: mono, b.id: mono, c.id: stereo])
            check(f.adaptations.isEmpty, "a bypassed or greyed plugin adapts nothing")
            check(f.look(.into(a.id)) == WireLook(count: 2), "into a bypassed mono plugin: two plain wires")
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
            check(f.adaptations.isEmpty && f.trunkOut == 2, "a bin that is OFF lets the signal through")
            block.fxLink?.isEnabled = true
            let g = SynopticWidthFlow.compute(root: .series([block, .plugin(b)]), sourceWidth: 2,
                                              channels: [a.id: mono, b.id: stereo])
            check(g.adaptations[a.id] == .merge(fold: nil, rightPassesDry: true) && g.adaptations[b.id] == nil,
                  "the same bin ON merges into its mono plugin")
            check(g.look(.into(block.id)) == WireLook(count: 2), "into the bin itself: two plain wires")
        }

        // --- the audio file's channel choice (on the wire that leaves it) --------------------------
        do {
            let s = plugin("s")
            let root = SynopticNode.series([.plugin(s)])
            let both = SynopticWidthFlow.compute(root: root, sourceWidth: 2, sourceChoice: .both, channels: [s.id: stereo])
            check(both.look(.source) == WireLook(count: 2, sourceChoice: .both), "both: two plain wires, the menu on them")
            check(both.look(.source)?.isOrange == false, "both is not orange")
            check(both.chainInput == 2 && both.adaptations.isEmpty, "both: the chain is fed stereo")
            let sum = SynopticWidthFlow.compute(root: root, sourceWidth: 2, sourceChoice: .sum, channels: [s.id: stereo])
            check(sum.look(.source) == WireLook(count: 2, shape: .sum, sourceChoice: .sum), "sum: the two wires join, orange")
            check(sum.chainInput == 1 && sum.adaptations[s.id] == .split, "then one wire, split again into the stereo plugin")
            let r = SynopticWidthFlow.compute(root: root, sourceWidth: 2, sourceChoice: .right, channels: [s.id: stereo])
            check(r.look(.source) == WireLook(count: 2, shape: .pick(.right), sourceChoice: .right), "right: L stops with a cross")
            let l = SynopticWidthFlow.compute(root: .series([]), sourceWidth: 2, sourceChoice: .left, channels: [:])
            check(l.look(.source)?.shape == .pick(.left) && l.trunkOut == 1 && l.look(.trunk)?.shape == .split,
                  "left on an empty chain: the trunk splits back at the mixer")
            check(l.look(.file) == WireLook(count: 2), "the file itself stays two wires")
            let monoFile = SynopticWidthFlow.compute(root: root, sourceWidth: 1, sourceChoice: .left, channels: [s.id: stereo])
            check(monoFile.sourceChoice == nil && monoFile.look(.source) == WireLook(count: 1), "a mono file has no choice")
        }

        // --- parallel -----------------------------------------------------------------------------
        do {
            let a = plugin("a"), b = plugin("b"), tail = plugin("t")
            let ba = SynopticNode.series([.plugin(a)]), bb = SynopticNode.series([.plugin(b)])
            let root = SynopticNode.series([.parallel([ba, bb]), .plugin(tail)])
            let f = SynopticWidthFlow.compute(root: root, sourceWidth: 1,
                                              channels: [a.id: mono, b.id: monoStereo, tail.id: stereo])
            check(f.inputOf[a.id] == 1 && f.inputOf[b.id] == 1, "both branches are fed the same width")
            check(f.inputOf[tail.id] == 2, "the sum is as wide as the widest branch")
            check(f.look(.into(ba.id)) == WireLook(count: 1) && f.look(.after(bb.id)) == WireLook(count: 2),
                  "a branch's wires read its own widths")
            check(f.look(.after(ba.id)) == WireLook(count: 1), "a mono branch merges back as one wire")
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
