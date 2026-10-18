import Foundation

// MARK: - Channel width along a chain (mono / mono→stereo / stereo)
//
// What the signal view says about width, as PURE arithmetic: no model, no engine, no view. The numbers it
// reasons on are the ones the engine's graph builder reads (`createNodeForPlugin`, tracktion):
//
//   • a plugin's `inputs` is its MAIN bus's channel count, its `outputs` that bus's output count (at
//     least 1);
//   • on a clip's chain the plugin node runs at E = max(inputs, outputs) channels;
//   • a signal NARROWER than `inputs` is widened first (mono → stereo duplicates the channel);
//   • a signal WIDER than E is not touched beyond E: the extra channels pass THROUGH UNPROCESSED (a
//     stereo signal through a 1→1 plugin leaves the left channel processed and the right one dry);
//   • a signal as wide as E, through a plugin with ONE input, is read on its first channel only.
//
// So the width after a plugin is E for a mono signal and max(width, E) otherwise, and a stereo signal
// meeting a plugin that has a single input or a single output is the case worth a warning: part of the
// stereo image is either dropped or left unprocessed.
//
// A bypassed plugin is transparent (nothing to say), and so is anything the engine does not report
// channels for (gain stages, built-ins, an instance still loading): the signal passes at its width.

/// The three ways a plugin's main bus can be set, named by what it takes in and what it puts out.
enum ChannelVariant: String, CaseIterable, Equatable, Sendable {
    case mono                       // 1 → 1
    case monoStereo = "mono_stereo" // 1 → 2
    case stereo                     // 2 → 2

    var inputs: Int { self == .stereo ? 2 : 1 }
    var outputs: Int { self == .mono ? 1 : 2 }

    init?(inputs: Int, outputs: Int) {
        guard let v = Self.allCases.first(where: { $0.inputs == inputs && $0.outputs == outputs })
        else { return nil }
        self = v
    }
}

/// A plugin's main bus, as the engine reports it.
struct PluginChannels: Equatable, Sendable {
    var inputs: Int
    var outputs: Int

    /// nil when the bus is in none of the three variants (a surround plugin, say).
    var variant: ChannelVariant? { ChannelVariant(inputs: inputs, outputs: outputs) }

    /// The card's badge: "1" (mono), "1→2", "2" (stereo); any other bus reads "n→m" ("n" when equal).
    /// Glyphs and numbers only — never a translated word.
    var badge: String {
        inputs == outputs ? "\(inputs)" : "\(inputs)→\(outputs)"
    }
}

/// The widths of a whole chain. Computed once per chain change, never per frame.
struct SynopticWidthFlow: Equatable {
    /// The width of the signal ENTERING / LEAVING each plugin card.
    var inputOf: [UUID: Int] = [:]
    var outputOf: [UUID: Int] = [:]
    /// The plugins that crush a stereo signal: it reaches them 2 wide (or more) and they take in or put
    /// out fewer channels than that.
    var crushed: Set<UUID> = []
    /// The width the chain ends with.
    var trunkOut: Int = 2

    // MARK: One plugin

    /// The channel count the plugin's node runs at on a clip's chain.
    static func nodeWidth(_ p: PluginChannels) -> Int { max(p.inputs, max(1, p.outputs)) }

    /// The width after a plugin that is ON, given the width it is fed.
    static func output(incoming w: Int, through p: PluginChannels) -> Int {
        let e = nodeWidth(p)
        return w <= 1 ? e : max(w, e)
    }

    /// True when a signal of width `w` loses part of its stereo image in `p`.
    static func crushesStereo(incoming w: Int, through p: PluginChannels) -> Bool {
        w >= 2 && (p.inputs < 2 || p.outputs < 2)
    }

    // MARK: The source

    /// The width a chain is fed with, from what its source is: an audio file's channel count (a mono file
    /// stays 1 wide, two channels or more come out as a stereo pair), nil/unknown = stereo. A group, an aux
    /// or a consolidated instance is a stereo bus.
    static func sourceWidth(fileChannels: Int?) -> Int {
        guard let n = fileChannels, n >= 1 else { return 2 }
        return min(2, n)
    }

    // MARK: A chain

    /// Walks `root` from a source of width `sourceWidth`. `channels` holds the plugins the engine reports
    /// a main bus for (external, loaded); every other card is transparent. A bypassed plugin is
    /// transparent; a bin that is OFF makes its whole series transparent.
    static func compute(root: SynopticNode, sourceWidth: Int,
                        channels: [UUID: PluginChannels]) -> SynopticWidthFlow {
        var flow = SynopticWidthFlow()
        flow.trunkOut = walk(root, incoming: sourceWidth, channels: channels, transparent: false, into: &flow)
        return flow
    }

    private static func walk(_ node: SynopticNode, incoming w: Int, channels: [UUID: PluginChannels],
                             transparent: Bool, into flow: inout SynopticWidthFlow) -> Int {
        switch node.kind {
        case .plugin(let p):
            flow.inputOf[p.id] = w
            var out = w
            if !transparent, p.isEnabled, !p.greyedByBlock, let ch = channels[p.id], ch.inputs > 0 {
                out = output(incoming: w, through: ch)
                if crushesStereo(incoming: w, through: ch) { flow.crushed.insert(p.id) }
            }
            flow.outputOf[p.id] = out
            return out

        case .series(let nodes):
            // A bin that is switched off lets the signal through whatever its members are.
            let off = transparent || (node.fxLink.map { !$0.isEnabled } ?? false)
            var cur = w
            for n in nodes { cur = walk(n, incoming: cur, channels: channels, transparent: off, into: &flow) }
            return cur

        case .parallel(let branches):
            // Every branch is fed the same signal; the sum is as wide as the widest branch.
            guard !branches.isEmpty else { return w }
            return branches
                .map { walk($0, incoming: w, channels: channels, transparent: transparent, into: &flow) }
                .max() ?? w
        }
    }
}
