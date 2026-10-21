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
//   • a signal as wide as E, through a plugin with ONE input, is read on its first channel only — unless
//     the plugin's `MonoFold` says right or sum (the app lays a service plugin before it, @see
//     OBJMonoFoldPlugin.h). A plugin whose fold was CHOSEN (any key in the file, `left` included) has its
//     output replace the pair (the app lays a service plugin after a 1 → 1 one): its output is ONE wire
//     for a 1 → 1 plugin, two for a 1 → 2. Only a plugin with NO key (written before the choice existed)
//     keeps the legacy graph: through a 1 → 1 the right channel passes round it dry.
//
// So the width after a plugin is E for a mono signal, the plugin's own output for a stereo signal into a
// one-input plugin whose fold was chosen, and max(width, E) otherwise. The signal view draws a mono signal
// as ONE wire and a stereo one as TWO, well apart; where a plugin's input is not the width it is fed, the
// wire into it merges (stereo into a mono input: the two wires JOIN into one, or the channel not taken
// stops short with a cross) or splits (mono into a stereo input), in orange (@see WireLook.Shape). A 1 → 2
// plugin fed mono is not a warning: one wire in, two out.
//
// The audio file's own channel choice (`ChannelMode`, LR / L / R / C, request of 20 October 2026) is drawn
// the same way on the wire that leaves the source, and chosen there by a right click (@see
// SourceChannelChoice).
//
// What a one-input plugin is fed from a stereo signal is the plugin's own choice (@see MonoFold).
//
// A bypassed plugin is transparent (nothing to say), and so is anything the engine does not report
// channels for (gain stages, built-ins, an instance still loading): the signal passes at its width.

/// A point on a cable: a series (@see SynopticMapping.build for the ids) and the VISIBLE index of the
/// card it stands before — `0` = the head of the series, `n` = its tail (n = the series' card count).
struct CablePoint: Hashable, Sendable {
    var seriesID: UUID
    var index: Int
}

/// What a cable can be told, as a person names it: Stereo (the cable as it is, no pick), Left, Right or
/// Sum. `fold` is the bridge to the model's `MonoFold` (Stereo has none).
enum CableChoice: String, CaseIterable, Sendable {
    case stereo, left, right, sum

    init(_ fold: MonoFold?) {
        switch fold {
        case nil:      self = .stereo
        case .left?:   self = .left
        case .right?:  self = .right
        case .sum?:    self = .sum
        }
    }

    var fold: MonoFold? {
        switch self {
        case .stereo: return nil
        case .left:   return .left
        case .right:  return .right
        case .sum:    return .sum
        }
    }
}

/// The menu a cable offers on a right click: the choice in force and the choices a hand may make. A mono
/// cable has none (nothing to choose on one wire); a cable that enters a one-input plugin offers Left /
/// Right / Sum only (it cannot receive a pair).
struct CableMenu: Equatable, Sendable {
    var current: CableChoice
    var offered: [CableChoice]
}

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

/// What a plugin with ONE input is fed when the signal reaching it is stereo — the choice the orange merging
/// wire offers on a right click (request of 20 October 2026). Stored per plugin (`ObjectPlugin.monoFold`).
///
///   • `left`  — the plugin reads the left channel;
///   • `right` — the plugin reads the right channel;
///   • `sum`   — the plugin reads (L + R) / 2: half of each, so a centred (mono-compatible) sound keeps its
///               level exactly and two full-scale channels cannot clip. The default of a plugin made by
///               this build.
///   Whichever is chosen, what the plugin puts out REPLACES the stereo pair: a 1 → 1 plugin's output is ONE
///   wire (mono), copied back to both channels where the chain goes on stereo (drawn as a wire splitting in
///   two); the channel not taken is CUT (drawn stopping short with a cross). A plugin saved before the choice
///   existed has NO key (`monoFold == nil`): it plays `whenUnset` — the sum (decision of 21 October 2026).
enum MonoFold: String, CaseIterable, Codable, Equatable, Sendable {
    case left, right, sum

    /// ⚠️ THE ONE SWITCH for a plugin saved before the choice existed (no `monoFold` key in the file): what
    /// it is PLAYED and DRAWN as. `.sum` since 21 October 2026 (the user's decision: an old project's mono
    /// plugins on a stereo signal now SUM, their sound changes on purpose). `nil` would put back the legacy
    /// graph (the left channel read, the right one passing round a 1 → 1 dry; drawn as two orange wires,
    /// nothing ticked in the menu). No migration either way: the model keeps no key, the engine spec
    /// (`EditViewModel.monoFolds`, the rack spec) and the signal view both read it through `played(_:)`.
    static let whenUnset: MonoFold? = .sum

    /// The fold a plugin is played and drawn with, from what its record stores (nil = no key).
    static func played(_ stored: MonoFold?) -> MonoFold? { stored ?? whenUnset }
}

/// The audio file's channel choice as the signal view reads it (`ChannelMode` mirrored here, so this file stays
/// pure): both channels as they are, the left one alone, the right one alone, or their sum (L + R) / 2. Any
/// choice but `both` makes the rest of the chain MONO (the engine lays the chosen channel on both sides).
enum SourceChannelChoice: Equatable, Sendable {
    case both, left, right, sum
}

/// One side of a stereo pair.
enum WireSide: Equatable, Sendable {
    case left, right
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
    /// A stereo signal into a plugin with ONE input. `fold` = what the plugin is fed (@see MonoFold); nil = the
    /// plugin carries no choice (a file written before it existed): it reads the left channel, and
    /// `rightPassesDry` says whether the right one goes round it unprocessed (a 1 → 1 plugin) or is not heard
    /// after it (1 → 2). Always false once a fold is chosen: the plugin's output replaces the pair.
    case merge(fold: MonoFold?, rightPassesDry: Bool)
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
    /// The chain's source as the chain is fed: after the audio file's channel choice (a bus's input, the
    /// ARA source's output).
    case source
    /// The audio FILE itself, before anything (the wire into an ARA source's card): its own channel count.
    case file
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
        /// Two wires (L, R) that JOIN into one before the wire's end: the sum (L + R) / 2.
        case sum
        /// Two wires of which only `keep` goes on, as one wire, to the wire's end; the other STOPS short with
        /// a small cross (the channel not taken).
        case pick(WireSide)
        /// One wire splitting in two before the wire's end: @see WireAdaptation.split.
        case split
    }
    /// 1 = mono (one wire), 2 = stereo (two). For a sum / pick / split, the count at the wire's START.
    var count: Int
    var shape: Shape = .parallel
    /// The plugin's adaptation at its input (a fold menu on a merge); nil = an ordinary wire.
    var adaptation: WireAdaptation? = nil
    /// The wire that leaves an audio FILE whose channels can be chosen: its current choice (right click =
    /// LR / L / R / Sum). nil anywhere else.
    var sourceChoice: SourceChannelChoice? = nil
    /// A choice written on the cable (`sum` / `pick`) AND a plugin that takes a pair right after it: the one
    /// wire the choice leaves splits in two again before the wire's end (@see SynopticWidthFlow.look(_:pick:)).
    var splitsAfter = false

    /// Drawn in orange: a sum, a channel left out, a mono signal copied to stereo, or a legacy plugin reading
    /// the left channel only.
    var isOrange: Bool { shape != .parallel || adaptation != nil }

    /// How a merge into a one-input plugin is drawn.
    static func merge(_ a: WireAdaptation) -> WireLook {
        switch a {
        case .merge(.sum?, _):   return WireLook(count: 2, shape: .sum, adaptation: a)
        case .merge(.right?, _): return WireLook(count: 2, shape: .pick(.right), adaptation: a)
        case .merge(.left?, _):  return WireLook(count: 2, shape: .pick(.left), adaptation: a)
        // No choice made (an old file): the plugin reads the left channel; through a 1 → 1 the right one
        // passes round it dry, so both wires go on (orange: not what a mono plugin is expected to get).
        case .merge(nil, let dry): return dry ? WireLook(count: 2, shape: .parallel, adaptation: a)
                                              : WireLook(count: 2, shape: .pick(.left), adaptation: a)
        case .split:             return WireLook(count: 1, shape: .split, adaptation: a)
        }
    }
}

/// The widths of a whole chain. Computed once per chain change, never per frame.
struct SynopticWidthFlow: Equatable {
    /// The width of the signal ENTERING / LEAVING each node: plugin cards, series, parallels, bins.
    var inputOf: [UUID: Int] = [:]
    var outputOf: [UUID: Int] = [:]
    /// The plugins whose input bus is not the width they are fed (@see WireAdaptation).
    var adaptations: [UUID: WireAdaptation] = [:]
    /// For each id `adaptations` holds a MERGE under (a card's node or its plugin): the plugin's own id,
    /// the one a fold is set on.
    var mergePlugin: [UUID: UUID] = [:]
    /// The width of the audio file (or of a bus's input), the file's channel choice when it can take one
    /// (a stereo audio file), and the width the chain ends with.
    var sourceWidth: Int = 2
    var sourceChoice: SourceChannelChoice? = nil
    var trunkOut: Int = 2
    /// The width of the signal ARRIVING at each cable point, BEFORE the choice written there (a stereo
    /// cable is 2 wide, one that a pick or a mono plugin made mono is 1). Every point of every series.
    var widthAt: [CablePoint: Int] = [:]
    /// The choice written on each cable point that carries one and whose pick IS in force (a pick inside a
    /// bin that is switched off is not; a pick on a cable that is already mono changes nothing but is listed).
    var pickAt: [CablePoint: MonoFold] = [:]
    /// What a right click offers on each cable point whose signal is stereo (a mono cable has none): the
    /// choice in force and the choices a hand may make. The head of a stereo audio clip's chain is NOT here:
    /// its choice is the file's own (@see fileLevelPoint).
    var menuAt: [CablePoint: CableMenu] = [:]
    /// The root series' id (the host's), to name the head of the chain.
    var rootID: UUID? = nil

    /// The width the chain is FED with: a stereo file played other than LR is one channel.
    var chainInput: Int {
        guard sourceWidth >= 2, let c = sourceChoice, c != .both else { return sourceWidth }
        return 1
    }

    /// The head of a stereo audio clip's chain, where the choice is the file's own channel mode (one menu, the
    /// one of the wire that leaves the file). nil when the chain's source takes no choice (a mono file, a
    /// bus, a MIDI clip).
    var fileLevelPoint: CablePoint? {
        guard sourceChoice != nil, let id = rootID else { return nil }
        return CablePoint(seriesID: id, index: 0)
    }

    /// Nothing computed (the demo): every wire keeps the neutral single line.
    var isEmpty: Bool { inputOf.isEmpty && outputOf.isEmpty }

    // MARK: One plugin

    /// The channel count the plugin's node runs at on a clip's chain.
    static func nodeWidth(_ p: PluginChannels) -> Int { max(p.inputs, max(1, p.outputs)) }

    /// The width after a plugin that is ON, given the width it is fed and its fold (nil = none chosen).
    static func output(incoming w: Int, through p: PluginChannels, fold: MonoFold? = nil) -> Int {
        let e = nodeWidth(p)
        if w <= 1 { return e }
        // A stereo signal into ONE input: once a fold is chosen the plugin's output replaces the pair (one wire
        // out of a 1 → 1, two out of a 1 → 2). With none, a 1 → 1 lets the right channel pass round it.
        if p.inputs == 1, fold != nil { return max(1, p.outputs) }
        return max(w, e)
    }

    /// What happens at the input of a plugin that is ON, fed `w` channels; nil = the widths agree.
    static func adaptation(incoming w: Int, through p: PluginChannels, fold: MonoFold? = nil) -> WireAdaptation? {
        guard p.inputs > 0 else { return nil }
        if w >= 2 && p.inputs == 1 {
            return .merge(fold: fold, rightPassesDry: fold == nil && nodeWidth(p) < w)
        }
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
            if let a = adaptations[id] { return WireLook.merge(a) }
            return WireLook(count: count(w))
        case .after(let id):
            guard let w = outputOf[id] else { return nil }
            return WireLook(count: count(w))
        case .file: return WireLook(count: count(sourceWidth))
        case .source:
            guard sourceWidth >= 2, let c = sourceChoice else { return WireLook(count: count(sourceWidth)) }
            switch c {
            case .both:  return WireLook(count: 2, sourceChoice: c)
            case .sum:   return WireLook(count: 2, shape: .sum, sourceChoice: c)
            case .left:  return WireLook(count: 2, shape: .pick(.left), sourceChoice: c)
            case .right: return WireLook(count: 2, shape: .pick(.right), sourceChoice: c)
            }
        case .trunk:
            // A STEREO source made mono along the chain (a channel choice, a mono plugin) goes back to a stereo
            // pair at the mixer: that copy is drawn, one wire splitting in two (request of 20 October 2026). A
            // mono FILE stays the plain single wire it always was.
            if trunkOut <= 1 && sourceWidth >= 2 { return WireLook(count: 1, shape: .split) }
            return WireLook(count: count(trunkOut))
        case .bus:    return WireLook(count: 2)
        }
    }

    /// The look of the cable segment that carries `source` AND ends at the cable point `point`, where the pick
    /// of the point is drawn: a pick in force on a stereo cable makes the wire bend into one (the sum: the two
    /// wires JOIN, a dot where they meet; Left / Right: the other channel STOPS short with a cross), in
    /// orange. When the plugin right after takes a pair, the single wire splits in two again (`splitsAfter`).
    /// With no pick in force (or on a cable that is already mono) it is `look(source)`.
    func look(_ source: WireSource?, pick point: CablePoint?) -> WireLook? {
        guard var base = look(source) else { return nil }
        guard let point, let mode = pickAt[point], (widthAt[point] ?? 1) >= 2 else { return base }
        base.count = 2
        base.splitsAfter = base.shape == .split
        base.shape = mode == .sum ? .sum : .pick(mode == .left ? .left : .right)
        base.sourceChoice = nil
        return base
    }

    // MARK: A chain

    /// Walks `root` from a source of width `sourceWidth` (`sourceChoice` = the audio file's channel choice when
    /// it can take one; a choice other than `both` feeds the chain one channel). `channels` holds the plugins
    /// the engine reports a main bus for (external, loaded); every other card is transparent. A bypassed
    /// plugin is transparent; a bin that is OFF makes its whole series transparent. `folds` = each plugin's
    /// CHOSEN `MonoFold` (absent = none chosen: the legacy left channel, @see output).
    static func compute(root: SynopticNode, sourceWidth: Int, sourceChoice: SourceChannelChoice? = nil,
                        channels: [UUID: PluginChannels],
                        folds: [UUID: MonoFold] = [:]) -> SynopticWidthFlow {
        var flow = SynopticWidthFlow()
        flow.sourceWidth = sourceWidth
        flow.sourceChoice = sourceWidth >= 2 ? sourceChoice : nil
        flow.rootID = root.id
        flow.trunkOut = walk(root, incoming: flow.chainInput, channels: channels, folds: folds,
                             transparent: false, into: &flow)
        return flow
    }

    /// A cable point of the series `node`: records the width arriving there and, when a pick stands on it,
    /// applies it — the engine writes the chosen channel on both sides, so the signal after it is MONO (it
    /// stays 1 if it already was; a pick inside a bin switched off is inert).
    private static func cross(_ node: SynopticNode, index i: Int, width w: Int, off: Bool,
                              into flow: inout SynopticWidthFlow) -> Int {
        let point = CablePoint(seriesID: node.id, index: i)
        flow.widthAt[point] = w
        guard let mode = node.cablePicks[i] else { return w }
        if off { return w }
        flow.pickAt[point] = mode
        return min(w, 1)
    }

    /// What a right click offers on the cable point (`node`, `index`), whose signal arrives `w` wide: nothing on
    /// a mono cable, Left / Right / Sum into a one-input plugin (the choice in force being the pick, else that
    /// plugin's inherited fold), the four choices elsewhere. The head of a stereo audio clip's chain is the
    /// file's: its menu is the wire that leaves the file's.
    private static func menu(_ node: SynopticNode, index i: Int, width w: Int, before next: SynopticNode?,
                             channels: [UUID: PluginChannels], folds: [UUID: MonoFold],
                             into flow: inout SynopticWidthFlow) {
        guard w >= 2 else { return }
        let point = CablePoint(seriesID: node.id, index: i)
        if point == flow.fileLevelPoint { return }
        var oneInput = false
        var inherited: MonoFold? = nil
        if let next, case .plugin(let p) = next.kind, channels[p.id]?.inputs == 1 {
            oneInput = true
            inherited = folds[p.id]
        }
        let current: CableChoice = node.cablePicks[i].map { CableChoice($0) }
            ?? (oneInput ? CableChoice(inherited) : .stereo)
        flow.menuAt[point] = CableMenu(current: current,
                                       offered: oneInput ? [.left, .right, .sum] : CableChoice.allCases)
    }

    private static func walk(_ node: SynopticNode, incoming w: Int, channels: [UUID: PluginChannels],
                             folds: [UUID: MonoFold],
                             transparent: Bool, into flow: inout SynopticWidthFlow) -> Int {
        flow.inputOf[node.id] = w
        var out = w
        switch node.kind {
        case .plugin(let p):
            // Recorded under the PLUGIN's id too (the cards are keyed by it; a node built with
            // `.plugin(_:)` has an id of its own).
            flow.inputOf[p.id] = w
            if !transparent, p.isEnabled, !p.greyedByBlock, let ch = channels[p.id], ch.inputs > 0 {
                out = output(incoming: w, through: ch, fold: folds[p.id])
                if let a = adaptation(incoming: w, through: ch, fold: folds[p.id]) {
                    flow.adaptations[p.id] = a
                    flow.adaptations[node.id] = a
                    if case .merge = a {
                        flow.mergePlugin[p.id] = p.id
                        flow.mergePlugin[node.id] = p.id
                    }
                }
            }
            flow.outputOf[p.id] = out

        case .series(let nodes):
            // A bin that is switched off lets the signal through whatever its members are.
            let off = transparent || (node.fxLink.map { !$0.isEnabled } ?? false)
            for (i, n) in nodes.enumerated() {
                menu(node, index: i, width: out, before: n, channels: channels, folds: folds, into: &flow)
                out = cross(node, index: i, width: out, off: off, into: &flow)
                out = walk(n, incoming: out, channels: channels, folds: folds, transparent: off, into: &flow)
            }
            menu(node, index: nodes.count, width: out, before: nil, channels: channels, folds: folds, into: &flow)
            out = cross(node, index: nodes.count, width: out, off: off, into: &flow)

        case .parallel(let branches):
            // Every branch is fed the same signal; the sum is as wide as the widest branch.
            if !branches.isEmpty {
                out = branches
                    .map { walk($0, incoming: w, channels: channels, folds: folds, transparent: transparent, into: &flow) }
                    .max() ?? w
            }
        }
        flow.outputOf[node.id] = out
        return out
    }
}
