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
//    anywhere in the chain and reorderable with the host's other plugins, exactly as a
//    parallel block (`rack`) is. The entry carries the host's own instances, in the definition's
//    order.
//  • THE DEFINITION IS THE REGISTRY'S (`FXLink`, `ProjectDocument.fxLinks`): order, membership,
//    on/off of each plugin and the bin's common on/off. Editing any of it edits every member. A bin
//    has NO output section any more (format 25, plan_synoptic_rework D1): a level, pan or mute on a
//    bin is a GAIN STAGE among its plugins (`objGainPanMute`, @see GainStage.swift) — the old
//    `gainDb / pan / muted` are decoded only, for `LegacyGainMigration`.
//  • DETACHING is per host and works like the legacy plugin link's: the block stays where it is
//    but stops following (`isDetached`); the host keeps an INDEPENDENT copy of the chain with the
//    settings of the moment (and of the common on/off, `local`). Reattaching realigns the host on
//    the bin — it adopts the bin's settings, never the reverse.
//  • Manual ⌘-links (`linkGroupID` on a plain plugin) are untouched and live beside the bins.
//  • DRAGGING (@see EditViewModel+PluginDrop, one resolver for the cursor, the band and the drop):
//    the block moves by its header — the target joins the bin and the source loses its block (⌥ / ⌘: it
//    keeps it; every copy of a bin stays on the bin; a detached block travels as it is). A plain plugin
//    let go inside a bin JOINS its definition (⌥: an independent copy is added); an instance let go
//    outside its bin LEAVES it for every member and stays here as a plain plugin (⌥: a copy; ⌘ is
//    refused). An instance never moves to another host on its own: ⌘ makes that host join the bin.

/// What a detached block keeps of its bin's rules: the common on/off. Until format 24 it was the bin's
/// whole OUTPUT SECTION (volume, pan, mute); those three are now decoded only — `legacy…`, never
/// encoded, read by `LegacyGainMigration` alone, which turns a non-neutral one into a gain stage.
struct FXLinkOutput: Codable, Equatable {
    var isEnabled: Bool = true
    var legacyGainDb: Float = 0
    var legacyPan: Float = 0
    var legacyMuted: Bool = false

    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    /// True when the legacy output section carried something audible (the migration's test).
    var hasLegacyOutput: Bool { legacyGainDb != 0 || legacyPan != 0 || legacyMuted }

    enum CodingKeys: String, CodingKey { case isEnabled, gainDb, pan, muted }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled    = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        legacyGainDb = try c.decodeIfPresent(Float.self, forKey: .gainDb) ?? 0
        legacyPan    = try c.decodeIfPresent(Float.self, forKey: .pan) ?? 0
        legacyMuted  = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEnabled, forKey: .isEnabled)
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
    /// The bin's common on/off: off = every member's block is bypassed.
    var isEnabled: Bool = true
    /// DECODE-ONLY: the output section of a file written before format 25 (@see FXLinkOutput).
    var legacyGainDb: Float = 0
    var legacyPan: Float = 0
    var legacyMuted: Bool = false
    /// The object whose name the bin FOLLOWS (B.0.6 of plan_synoptic_rework): set when a bin is
    /// created from an object, cleared once the user names the bin. nil = follows nobody.
    var nameSourceID: UUID? = nil
    /// True once the user has named the bin by hand: its name then never follows an object again.
    var userNamed: Bool = false

    /// The bin's rules as a detached block copies them (its common on/off).
    var output: FXLinkOutput {
        get { FXLinkOutput(isEnabled: isEnabled) }
        set { isEnabled = newValue.isEnabled }
    }

    /// True when the legacy output section carried something audible (the migration's test).
    var hasLegacyOutput: Bool { legacyGainDb != 0 || legacyPan != 0 || legacyMuted }

    init(id: UUID = UUID(), name: String, colorIndex: Int? = nil, plugins: [ObjectPlugin],
         isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex ?? Int.random(in: 0..<ObjekatPalette.plugins.count)
        self.plugins = plugins
        self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey {
        case id, name, colorIndex, plugins, isEnabled, gainDb, pan, muted, nameSourceID, userNamed
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decode(UUID.self, forKey: .id)
        name       = try c.decode(String.self, forKey: .name)
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        plugins    = try c.decodeIfPresent([ObjectPlugin].self, forKey: .plugins) ?? []
        isEnabled  = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        legacyGainDb = try c.decodeIfPresent(Float.self, forKey: .gainDb) ?? 0
        legacyPan    = try c.decodeIfPresent(Float.self, forKey: .pan) ?? 0
        legacyMuted  = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        nameSourceID = try c.decodeIfPresent(UUID.self, forKey: .nameSourceID)
        userNamed  = try c.decodeIfPresent(Bool.self, forKey: .userNamed) ?? false
    }

    /// The legacy output section is never written (format 25: it is a gain stage, @see
    /// LegacyGainMigration).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(colorIndex, forKey: .colorIndex)
        try c.encode(plugins, forKey: .plugins)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encodeIfPresent(nameSourceID, forKey: .nameSourceID)
        if userNamed   { try c.encode(true, forKey: .userNamed) }
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
                                colorIndex: d.colorIndex, sidechain: d.sidechain,
                                monoFold: d.monoFold).withTrims(of: d)
        }
    }

    /// The entry a host's chain carries for this bin: a block holding `instances`.
    static func blockEntry(linkID: UUID, name: String, instances: [ObjectPlugin],
                           id: UUID = UUID()) -> ObjectPlugin {
        ObjectPlugin(id: id, name: name, manufacturer: "", identifier: "", formatName: "",
                     fxBlock: FXLinkBlock(linkID: linkID, plugins: instances), monoFold: nil)
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
    /// The bin's rules as this host keeps them while DETACHED — the common on/off (format 25; until
    /// format 24 the output section too, decoded only); nil while attached (the bin's rules).
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

    /// True for the entries that are not a plugin: a parallel block (`rack`) and a bin's block
    /// (`fxBlock`), which hold a chain of their own, a send's marker (`sendMarker`) and a channel choice
    /// on a cable (`channelPick`), which hold none. A marker or a pick answers "container" so that every
    /// walk that skips leaves skips it too, and `childSeries` is empty so that no walk descends into it.
    var isContainer: Bool { rack != nil || fxBlock != nil || sendMarker != nil || channelPick != nil }

    /// True if this entry is the place of a send on the trunk (@see SendMarker).
    var isSendMarker: Bool { sendMarker != nil }

    /// The same marker with an id of its own (a copy of the object that holds it).
    func copiedSendMarker() -> ObjectPlugin {
        var q = self
        q.id = UUID()
        return q
    }

    /// A marker for the send towards `auxID`: no plugin identity, a fresh id of its own (the engine's
    /// key for the send stays `sender|aux`, never this id).
    static func makeSendMarker(for auxID: UUID, id: UUID = UUID()) -> ObjectPlugin {
        ObjectPlugin(id: id, name: "", manufacturer: "", identifier: "", formatName: "",
                     colorIndex: 0, sendMarker: SendMarker(auxID: auxID), monoFold: nil)
    }

    /// True if this entry is a bin's block.
    var isFXBlock: Bool { fxBlock != nil }

    /// The series a container holds: a rack's branches, or a block's single series. Empty for a
    /// plain plugin and for a send's marker. EVERY traversal that descends into a chain goes through this, so that a new
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
