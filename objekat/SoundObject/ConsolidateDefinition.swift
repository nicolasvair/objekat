import Foundation

// MARK: - A dependency on a consolidated object definition

/// A definition captured in a bake (that of another definition), at the revision in force at the
/// time of capture. See `ConsolidateDefinition.dependsOn` and `EditViewModel.isStale`.
struct ConsolidateDependency: Codable, Equatable {
    var consolidateID: UUID
    var revision: Int

    // Codable was synthesised (no explicit CodingKeys) before this struct's Swift identifier was
    // "consolidated" — an explicit mapping is now required, otherwise the synthesised key would
    // follow the property and silently start writing "consolidateID" instead of the
    // "definitionID" every dependsOn[] entry on disk already carries (cas E7).
    enum CodingKeys: String, CodingKey {
        case consolidateID = "definitionID", revision
    }
}

// MARK: - Consolidated object definition

/// The content shared by a 'consolidated object': a group reused at N places on the timeline
/// (`SoundObject.consolidateID`), where changing the content in one place updates it everywhere.
/// Each instance stays a normal, independent `SoundObject` (its own position, fades, gain/pan/mute,
/// plugins, sends, stem) — only the deep content referenced here is shared. The definition holds NO
/// mix of its own (format 26): the volume/pan/mute of an instance are that instance's.
///
/// The original editable subtree (internal children/plugins for a group, or simply the clip for
/// simple content) lives in a `<wave-without-ext>_objectstate.json` sidecar, next to the wave.
/// `revision` is bumped on every re-bake and drives the freshness detection of the definitions
/// that depend on it (see EditViewModel+Consolidate).
struct ConsolidateDefinition: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var wave: String       // file name of the current baked wave, in samples/objects/
    var revision: Int      // bumped on every re-bake (open -> close)
    var wasGroup: Bool     // the definition is a group (visual rendering: rounded corners)
    /// True ⇒ the sidecar's ROOT is entirely CONTENT: its fader, its window (trim), its fades and
    /// its loop are the content's own, baked into the wave and shared; it carries no send. False
    /// (absent: every definition written before format 26) ⇒ the sidecar still holds the root as the
    /// old build made it, with the instance's fader / fades / sends on it: the content-root
    /// normalisation neutralises them when it reads the sidecar. Written `true` by every NEW bake.
    var rootIsContent: Bool = false
    /// Other definitions captured in THIS bake, at their revision in force at bake time.
    /// Used to detect the staleness of a 'group' definition that itself holds a consolidated object
    /// (`EditViewModel.isStale`).
    var dependsOn: [ConsolidateDependency] = []

    init(id: UUID, name: String, wave: String, revision: Int = 0, wasGroup: Bool = false,
         rootIsContent: Bool = false,
         dependsOn: [ConsolidateDependency] = []) {
        self.id = id
        self.name = name
        self.wave = wave
        self.revision = revision
        self.wasGroup = wasGroup
        self.rootIsContent = rootIsContent
        self.dependsOn = dependsOn
    }

    // Tolerant decoding: absent fields ⇒ neutral values. The keys `volume`, `pan` and `isMuted`
    // that a definition written before format 26 carries are NOT in the list: they are ignored
    // (and dropped at the next save). Nothing is rewritten — an instance already holds its own
    // volume/pan/mute, which the old synchronisation kept equal to them.
    enum CodingKeys: String, CodingKey {
        case id, name, wave, revision, wasGroup, rootIsContent, dependsOn
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(UUID.self, forKey: .id)
        name      = try c.decode(String.self, forKey: .name)
        wave      = try c.decode(String.self, forKey: .wave)
        revision  = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        wasGroup  = try c.decodeIfPresent(Bool.self, forKey: .wasGroup) ?? false
        rootIsContent = try c.decodeIfPresent(Bool.self, forKey: .rootIsContent) ?? false
        dependsOn = try c.decodeIfPresent([ConsolidateDependency].self, forKey: .dependsOn) ?? []
    }
}
