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
// So the width after a plugin is E for a mono signal and max(width, E) otherwise. The signal view draws a
// mono signal as ONE wire and a stereo one as TWO; where a plugin's input is not the width it is fed, the
// wire into it merges (stereo into a mono input) or splits (mono into a stereo input), in orange, with a
// tooltip saying what the engine really does (@see WireAdaptation). A 1 → 2 plugin fed mono is not a
// warning: one wire in, two out.
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
}

/// What happens to the signal at a plugin's INPUT when its width and the bus's differ — the two cases the
/// signal view draws in orange (request of 20 October 2026). Measured on exports, not guessed (@see
/// tools/scenario_channel_width.py, "the SOUND").
enum WireAdaptation: Equatable, Sendable {
    /// A stereo signal into a plugin with ONE input: two wires meeting at its entry. The engine does NOT
    /// sum: the plugin reads the LEFT channel. `rightPassesDry` = the plugin's node is one channel wide (a
    /// 1 → 1 plugin), so the right channel goes round it unprocessed; false = the plugin puts out two
    /// channels of its own (1 → 2), so the right channel is not heard after it.
    case merge(rightPassesDry: Bool)
    /// A mono signal into a plugin with two inputs (or more): one wire splitting in two at its entry. The
    /// engine copies the channel onto both inputs.
    case split
}

/// What a wire of the signal view carries — the point of the chain its width is read at. The layout tags
/// each cable with one (@see SynopticLayout.Cable.carries); a cable with none (a send's column, the demo)
/// keeps the neutral single line.
enum WireSource: Equatable, Sendable {
    /// The signal ENTERING this node (a plugin card, a series, a parallel or a bin).
    case into(UUID)
    /// The signal LEAVING this node.
    case after(UUID)
    /// The chain's source (the file, the ARA source, a bus's input).
    case source
    /// The trunk's end (into the mixer).
    case trunk
    /// After the mixer: an object always leaves it as a stereo pair (a mono object is duplicated left →
    /// right at the end of its chain).
    case bus
}

/// How one wire is drawn.
struct WireLook: Equatable, Sendable {
    enum Shape: Equatable, Sendable {
        /// `count` parallel wires all along.
        case parallel
        /// Two wires meeting at the wire's END (the plugin's entry): @see WireAdaptation.merge.
        case merge
        /// One wire splitting in two at the wire's END: @see WireAdaptation.split.
        case split
    }
    /// 1 = mono (one wire), 2 = stereo (two). For a merge / split, the count at the wire's START.
    var count: Int
    var shape: Shape = .parallel
    /// What the adaptation is (orange, with a tooltip); nil = an ordinary wire.
    var adaptation: WireAdaptation? = nil

    var warns: Bool { adaptation != nil }
}

/// The widths of a whole chain. Computed once per chain change, never per frame.
struct SynopticWidthFlow: Equatable {
    /// The width of the signal ENTERING / LEAVING each node: plugin cards, series, parallels, bins.
    var inputOf: [UUID: Int] = [:]
    var outputOf: [UUID: Int] = [:]
    /// The plugins whose input bus is not the width they are fed (@see WireAdaptation).
    var adaptations: [UUID: WireAdaptation] = [:]
    /// The width the chain is fed with, and the one it ends with.
    var sourceWidth: Int = 2
    var trunkOut: Int = 2

    /// Nothing computed (the demo): every wire keeps the neutral single line.
    var isEmpty: Bool { inputOf.isEmpty && outputOf.isEmpty }

    // MARK: One plugin

    /// The channel count the plugin's node runs at on a clip's chain.
    static func nodeWidth(_ p: PluginChannels) -> Int { max(p.inputs, max(1, p.outputs)) }

    /// The width after a plugin that is ON, given the width it is fed.
    static func output(incoming w: Int, through p: PluginChannels) -> Int {
        let e = nodeWidth(p)
        return w <= 1 ? e : max(w, e)
    }

    /// What happens at the input of a plugin that is ON, fed `w` channels; nil = the widths agree.
    static func adaptation(incoming w: Int, through p: PluginChannels) -> WireAdaptation? {
        guard p.inputs > 0 else { return nil }
        if w >= 2 && p.inputs == 1 { return .merge(rightPassesDry: nodeWidth(p) < w) }
        if w == 1 && p.inputs >= 2 { return .split }
        return nil
    }

    // MARK: The source

    /// The width a chain is fed with, from what its source is: an audio file's channel count (a mono file
    /// stays 1 wide, two channels or more come out as a stereo pair), nil/unknown = stereo. A group, an aux
    /// or a consolidated instance is a stereo bus.
    static func sourceWidth(fileChannels: Int?) -> Int {
        guard let n = fileChannels, n >= 1 else { return 2 }
        return min(2, n)
    }

    // MARK: A wire

    /// How a wire carrying `source` is drawn; nil = nothing known (the neutral single line).
    func look(_ source: WireSource?) -> WireLook? {
        guard let source, !isEmpty else { return nil }
        func count(_ n: Int) -> Int { n >= 2 ? 2 : 1 }
        switch source {
        case .into(let id):
            guard let w = inputOf[id] else { return nil }
            switch adaptations[id] {
            case .merge?: return WireLook(count: 2, shape: .merge, adaptation: adaptations[id])
            case .split?: return WireLook(count: 1, shape: .split, adaptation: .split)
            case nil:     return WireLook(count: count(w))
            }
        case .after(let id):
            guard let w = outputOf[id] else { return nil }
            return WireLook(count: count(w))
        case .source: return WireLook(count: count(sourceWidth))
        case .trunk:  return WireLook(count: count(trunkOut))
        case .bus:    return WireLook(count: 2)
        }
    }

    // MARK: A chain

    /// Walks `root` from a source of width `sourceWidth`. `channels` holds the plugins the engine reports
    /// a main bus for (external, loaded); every other card is transparent. A bypassed plugin is
    /// transparent; a bin that is OFF makes its whole series transparent.
    static func compute(root: SynopticNode, sourceWidth: Int,
                        channels: [UUID: PluginChannels]) -> SynopticWidthFlow {
        var flow = SynopticWidthFlow()
        flow.sourceWidth = sourceWidth
        flow.trunkOut = walk(root, incoming: sourceWidth, channels: channels, transparent: false, into: &flow)
        return flow
    }

    private static func walk(_ node: SynopticNode, incoming w: Int, channels: [UUID: PluginChannels],
                             transparent: Bool, into flow: inout SynopticWidthFlow) -> Int {
        flow.inputOf[node.id] = w
        var out = w
        switch node.kind {
        case .plugin(let p):
            // Recorded under the PLUGIN's id too (the cards are keyed by it; a node built with
            // `.plugin(_:)` has an id of its own).
            flow.inputOf[p.id] = w
            if !transparent, p.isEnabled, !p.greyedByBlock, let ch = channels[p.id], ch.inputs > 0 {
                out = output(incoming: w, through: ch)
                if let a = adaptation(incoming: w, through: ch) {
                    flow.adaptations[p.id] = a
                    flow.adaptations[node.id] = a
                }
            }
            flow.outputOf[p.id] = out

        case .series(let nodes):
            // A bin that is switched off lets the signal through whatever its members are.
            let off = transparent || (node.fxLink.map { !$0.isEnabled } ?? false)
            for n in nodes { out = walk(n, incoming: out, channels: channels, transparent: off, into: &flow) }

        case .parallel(let branches):
            // Every branch is fed the same signal; the sum is as wide as the widest branch.
            if !branches.isEmpty {
                out = branches
                    .map { walk($0, incoming: w, channels: channels, transparent: transparent, into: &flow) }
                    .max() ?? w
            }
        }
        flow.outputOf[node.id] = out
        return out
    }
}
