import SwiftUI

// MARK: - The signal graph model (PHASE A — UI only, independent of the engine)
//
// An abstract representation of a clip's/group's plugin chain as a graph combining
// SERIES and PARALLEL, recursively (nesting). This model knows NEITHER `ObjectPlugin`
// NOR tracktion: it only drives the signal view on made-up data, for as long as it
// takes to validate the ergonomics. Wiring it to the engine (phase B) will be done
// through a `SoundObject.plugins <-> SynopticNode` adapter.
//
// The invariants the mutations hold:
//  - the trunk (the root) is always a `.series`,
//  - the direct children of a `.parallel` (the 'branches') are always `.series`.
// Those invariants guarantee that an end-of-chain '+' exists everywhere a plugin can
// be added in series.

enum PluginCategory: String, CaseIterable, Codable {
    case eq, dynamics, distortion, space, modulation, utility

    var color: Color {
        switch self {
        case .eq:         return .blue
        case .dynamics:   return .green
        case .distortion: return .orange
        case .space:      return .purple
        case .modulation: return .pink
        case .utility:    return .gray
        }
    }

    var label: String {
        switch self {
        case .eq:         return L("plugins.category.eq")
        case .dynamics:   return L("plugins.category.dynamics")
        case .distortion: return L("plugins.category.distortion")
        case .space:      return L("plugins.category.space")
        case .modulation: return L("plugins.category.modulation")
        case .utility:    return L("plugins.category.utility")
        }
    }
}

struct SynopticPlugin: Identifiable, Equatable {
    let id: UUID
    var name: String
    var category: PluginCategory
    var isEnabled: Bool          // false = bypass
    var vu: Double               // 0...1 — the VU meter's level (made up in phase A)

    // Static information carried over from the chips (see ObjectPlugin), purely for display.
    var isBuiltIn: Bool = false
    var formatLabel: String = ""     // "VST3" / "AU" / "Built-in"
    var isLinked: Bool = false
    /// Out of its group but able to come back: the icon stays, muted, and the click links
    /// instead of unlinking. @see ObjectPlugin.detachedLinkGroupID
    var isLinkDetached: Bool = false
    /// The instance's identity colour (@see ObjectPlugin.color): its on/off, the card's
    /// halo/border and the link badge all derive from it, so that a glance is enough to tie
    /// a card in the signal view to its plugin.
    var color: Color = .gray

    init(id: UUID = UUID(), name: String, category: PluginCategory,
         isEnabled: Bool = true, vu: Double = 0,
         isBuiltIn: Bool = false, formatLabel: String = "",
         isLinked: Bool = false, isLinkDetached: Bool = false, color: Color = .gray) {
        self.id = id
        self.name = name
        self.category = category
        self.isEnabled = isEnabled
        self.vu = vu
        self.isBuiltIn = isBuiltIn
        self.formatLabel = formatLabel
        self.isLinked = isLinked
        self.isLinkDetached = isLinkDetached
        self.color = color
    }

    /// A generic plugin inserted by a '+' in phase A (in phase B, the '+' will open
    /// the real plugin picker).
    static func placeholder() -> SynopticPlugin {
        SynopticPlugin(name: "FX", category: .utility, isEnabled: true, vu: 0.0)
    }
}

struct SynopticNode: Identifiable, Equatable {
    let id: UUID
    var kind: Kind
    /// Filled in when this node is a BRANCH of a parallel block: the dB gain at the branch's end.
    var voiceGainDb: Float? = nil
    /// The branch's mute (a parallel block): the sound is cut, the gain is kept.
    var voiceMuted: Bool = false

    indirect enum Kind: Equatable {
        case plugin(SynopticPlugin)
        case series([SynopticNode])
        case parallel([SynopticNode])
    }

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    // Handy constructors
    static func plugin(_ p: SynopticPlugin) -> SynopticNode { .init(kind: .plugin(p)) }
    static func series(_ nodes: [SynopticNode]) -> SynopticNode { .init(kind: .series(nodes)) }
    static func parallel(_ voies: [SynopticNode]) -> SynopticNode { .init(kind: .parallel(voies)) }
}

// MARK: - Made-up demonstration data

extension SynopticNode {
    /// An example combining series + parallel + a nested parallel (2 levels), matching the
    /// approved mock-up: Source → EQ → [ (Comp → [Delay | Reverb]) | (Sat → Drive) ] → Limiter → Out
    static var demo: SynopticNode {
        .series([
            .plugin(.init(name: "EQ", category: .eq, vu: 0.62)),
            .parallel([
                .series([
                    .plugin(.init(name: "Comp", category: .dynamics, vu: 0.7)),
                    .parallel([
                        .series([ .plugin(.init(name: "Delay", category: .modulation, vu: 0.45)) ]),
                        .series([ .plugin(.init(name: "Reverb", category: .space,
                                               isEnabled: false, vu: 0.0)) ])
                    ])
                ]),
                .series([
                    .plugin(.init(name: "Sat", category: .distortion, vu: 0.55)),
                    .plugin(.init(name: "Drive", category: .distortion, vu: 0.4))
                ])
            ]),
            .plugin(.init(name: "Limiter", category: .utility, vu: 0.8))
        ])
    }
}
