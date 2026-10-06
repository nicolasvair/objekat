import Foundation
import SwiftUI

// MARK: - FX link: a shared bin of plugins (the "bac")
//
// An FX link is a NAMED group of plugins that several hosts (objects, or buses) share. The design,
// decided on 29 September 2026 and to be read before touching anything here:
//
//  • MIRROR INSTANCES. Every host keeps its OWN engine instances of the plugins — the bin is not
//    one processor fed by many objects, it is a DEFINITION that the members' instances mirror. The
//    parameters travel through the existing link machinery (`OBJParamMirror`, paired by index): an
//    instance of a bin's plugin carries `linkGroupID == <the definition plugin's id>`, so the engine
//    side needed no new synchronisation at all.
//  • A BLOCK IN THE CHAIN. In a host's chain the bin is ONE entry (`ObjectPlugin.fxBlock`), placed
//    anywhere between the trims and reorderable with the host's other plugins, exactly as a
//    parallel block (`rack`) is. The entry carries the host's own instances, in the definition's
//    order.
//  • THE DEFINITION IS THE REGISTRY'S (`FXLink`, `ProjectDocument.fxLinks`): order, membership,
//    on/off of each plugin, the bin's common on/off, and its OUTPUT SECTION (volume, pan, mute) —
//    an end-of-series gain stage, after the model of a parallel branch's gain (`wetDb`,
//    `voiceMutes`). Editing any of it edits every member.
//  • DETACHING is per host and works like the legacy plugin link's: the block stays where it is
//    but stops following (`isDetached`); the host keeps an INDEPENDENT copy of the chain with the
//    settings of the moment (and of the output section, `local`). Reattaching realigns the host on
//    the bin — it adopts the bin's settings, never the reverse.
//  • Manual ⌘-links (`linkGroupID` on a plain plugin) are untouched and live beside the bins.
//  • DRAGGING (@see EditViewModel+PluginDrop, one resolver for the cursor, the band and the drop):
//    the block moves by its header — the target joins the bin and the source loses its block (⌥ / ⌘: it
//    keeps it; every copy of a bin stays on the bin; a detached block travels as it is). A plain plugin
//    let go inside a bin JOINS its definition (⌥: an independent copy is added); an instance let go
//    outside its bin LEAVES it for every member and stays here as a plain plugin (⌥: a copy; ⌘ is
//    refused). An instance never moves to another host on its own: ⌘ makes that host join the bin.

/// The output section of a bin, as a detached block keeps its own copy of it.
struct FXLinkOutput: Codable, Equatable {
    var isEnabled: Bool = true
    var gainDb: Float = 0
    var pan: Float = 0
    var muted: Bool = false

    /// The gain actually heard: exact silence when muted (the same convention as a branch's mute).
    var effectiveGainDb: Float { muted ? objGainSilenceDb : gainDb }

    init(isEnabled: Bool = true, gainDb: Float = 0, pan: Float = 0, muted: Bool = false) {
        self.isEnabled = isEnabled; self.gainDb = gainDb; self.pan = pan; self.muted = muted
    }

    enum CodingKeys: String, CodingKey { case isEnabled, gainDb, pan, muted }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        gainDb    = try c.decodeIfPresent(Float.self, forKey: .gainDb) ?? 0
        pan       = try c.decodeIfPresent(Float.self, forKey: .pan) ?? 0
        muted     = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
    }
}

/// A bin's definition. `plugins` holds LEAF plugins only (no parallel block), in the bin's order;
/// their ids are the DEFINITION ids, which the members' instances name through `linkGroupID`.
struct FXLink: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// An index into `ObjekatPalette.plugins`: the colour of the block's rounded rectangle.
    var colorIndex: Int
    var plugins: [ObjectPlugin]
    /// The bin's common on/off: off = every member's block is bypassed, output section included.
    var isEnabled: Bool = true
    var gainDb: Float = 0
    var pan: Float = 0
    var muted: Bool = false

    var output: FXLinkOutput {
        get { FXLinkOutput(isEnabled: isEnabled, gainDb: gainDb, pan: pan, muted: muted) }
        set { isEnabled = newValue.isEnabled; gainDb = newValue.gainDb; pan = newValue.pan; muted = newValue.muted }
    }

    init(id: UUID = UUID(), name: String, colorIndex: Int? = nil, plugins: [ObjectPlugin],
         isEnabled: Bool = true, gainDb: Float = 0, pan: Float = 0, muted: Bool = false) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex ?? Int.random(in: 0..<ObjekatPalette.plugins.count)
        self.plugins = plugins
        self.isEnabled = isEnabled
        self.gainDb = gainDb
        self.pan = pan
        self.muted = muted
    }

    enum CodingKeys: String, CodingKey {
        case id, name, colorIndex, plugins, isEnabled, gainDb, pan, muted
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decode(UUID.self, forKey: .id)
        name       = try c.decode(String.self, forKey: .name)
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        plugins    = try c.decodeIfPresent([ObjectPlugin].self, forKey: .plugins) ?? []
        isEnabled  = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        gainDb     = try c.decodeIfPresent(Float.self, forKey: .gainDb) ?? 0
        pan        = try c.decodeIfPresent(Float.self, forKey: .pan) ?? 0
        muted      = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
    }

    var color: Color { ObjekatPalette.plugin(colorIndex) }

    /// A host's instance series for this definition: one instance per definition plugin, in the
    /// definition's order. An `existing` instance answering to a definition plugin (through its
    /// `linkGroupID`, or its `detachedLinkGroupID`) is REUSED — same id, same state, same colour —
    /// which is what keeps a live AudioUnit, an open editor and the automation curves aimed at it
    /// through any edit of the definition. Whatever answers to no definition plugin is dropped;
    /// whatever has no instance yet is born from `stateForNew` (the live state of a sibling, or the
    /// definition's own).
    ///
    /// `attached`: the instances join the definition's groups (`linkGroupID`), and take its per-plugin
    /// on/off. Detached, they keep the memory of the group (`detachedLinkGroupID`) and their own on/off.
    func instanceSeries(reusing existing: [ObjectPlugin], attached: Bool,
                        stateForNew: (ObjectPlugin) -> String?) -> [ObjectPlugin] {
        plugins.map { d in
            if var old = existing.first(where: { $0.effectiveLinkGroupID == d.id }) {
                old.linkGroupID         = attached ? d.id : nil
                old.detachedLinkGroupID = attached ? nil : d.id
                if attached { old.isEnabled = d.isEnabled; old.sidechain = d.sidechain }
                return old
            }
            return ObjectPlugin(id: UUID(), name: d.name, manufacturer: d.manufacturer,
                                identifier: d.identifier, formatName: d.formatName,
                                isEnabled: d.isEnabled, stateXML: stateForNew(d),
                                linkGroupID: attached ? d.id : nil,
                                detachedLinkGroupID: attached ? nil : d.id,
                                colorIndex: d.colorIndex, sidechain: d.sidechain)
        }
    }

    /// The entry a host's chain carries for this bin: a block holding `instances`.
    static func blockEntry(linkID: UUID, name: String, instances: [ObjectPlugin],
                           id: UUID = UUID()) -> ObjectPlugin {
        ObjectPlugin(id: id, name: name, manufacturer: "", identifier: "", formatName: "",
                     fxBlock: FXLinkBlock(linkID: linkID, plugins: instances))
    }
}

/// What a host's chain entry carries when it IS a bin's block (`ObjectPlugin.fxBlock`).
struct FXLinkBlock: Codable, Equatable {
    var linkID: UUID
    /// Out of the bin, but able to come back: the block stays in place with its own copy of the chain.
    var isDetached: Bool = false
    /// THIS host's instances of the bin's plugins, in the definition's order (attached), or the
    /// host's own copy of the chain (detached).
    var plugins: [ObjectPlugin] = []
    /// The output section as this host keeps it while DETACHED; nil while attached (the bin's rules).
    var local: FXLinkOutput? = nil

    init(linkID: UUID, isDetached: Bool = false, plugins: [ObjectPlugin] = [], local: FXLinkOutput? = nil) {
        self.linkID = linkID; self.isDetached = isDetached; self.plugins = plugins; self.local = local
    }

    enum CodingKeys: String, CodingKey { case linkID, isDetached, plugins, local }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        linkID     = try c.decode(UUID.self, forKey: .linkID)
        isDetached = try c.decodeIfPresent(Bool.self, forKey: .isDetached) ?? false
        plugins    = try c.decodeIfPresent([ObjectPlugin].self, forKey: .plugins) ?? []
        local      = try c.decodeIfPresent(FXLinkOutput.self, forKey: .local)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(linkID, forKey: .linkID)
        if isDetached { try c.encode(true, forKey: .isDetached) }
        try c.encode(plugins, forKey: .plugins)
        try c.encodeIfPresent(local, forKey: .local)
    }
}

// MARK: - Containers in a chain: racks and bins' blocks

extension ObjectPlugin {

    /// True for the entries that are not a plugin but hold a chain of their own: a parallel block
    /// (`rack`) or a bin's block (`fxBlock`).
    var isContainer: Bool { rack != nil || fxBlock != nil }

    /// True if this entry is a bin's block.
    var isFXBlock: Bool { fxBlock != nil }

    /// The series a container holds: a rack's branches, or a block's single series. Empty for a
    /// plain plugin. EVERY traversal that descends into a chain goes through this, so that a new
    /// kind of container is one place to teach and not a dozen.
    var childSeries: [[ObjectPlugin]] {
        if let rack { return rack.voices }
        if let fxBlock { return [fxBlock.plugins] }
        return []
    }

    /// The same container with `transform` applied to each of its series. A plain plugin is returned
    /// as it is.
    func mappingChildSeries(_ transform: ([ObjectPlugin]) -> [ObjectPlugin]) -> ObjectPlugin {
        var np = self
        if let rack { np.rack?.voices = rack.voices.map(transform) }
        else if let fxBlock { np.fxBlock?.plugins = transform(fxBlock.plugins) }
        return np
    }
}
