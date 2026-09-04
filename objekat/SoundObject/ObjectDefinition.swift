import Foundation

// MARK: - A dependency on a sound object definition

/// A definition captured in a bake (that of another definition), at the revision in force at the
/// time of capture. See `ObjectDefinition.dependsOn` and `EditViewModel.isStale`.
struct ObjectDependency: Codable, Equatable {
    var definitionID: UUID
    var revision: Int
}

// MARK: - Sound object definition

/// The content shared by a 'sound object': a group reused at N places on the timeline
/// (`SoundObject.definitionID`), where changing the content in one place updates it everywhere.
/// Each instance stays a normal, independent `SoundObject` (its own position, fades, gain/pan,
/// plugins) — only the deep content referenced here is shared.
///
/// The original editable subtree (internal children/plugins for a group, or simply the clip for
/// simple content) lives in a `<wave-without-ext>_objectstate.json` sidecar, next to the wave.
/// `revision` is bumped on every re-bake and drives the freshness detection of the definitions
/// that depend on it (see EditViewModel+Objects).
struct ObjectDefinition: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var wave: String       // file name of the current baked wave, in samples/objects/
    var revision: Int      // bumped on every re-bake (open -> close)
    var wasGroup: Bool     // the definition is a group (visual rendering: rounded corners)
    /// Mix values SHARED by every synced instance (the source of truth). An instance that switches
    /// an attribute to 'independent' (`SoundObject.independentAttrs`) stops following these values.
    /// See EditViewModel+Objects (`propagateLinkedAttr`).
    var volume: Float = 0  // dB
    var pan: Float = 0
    var isMuted: Bool = false
    /// Other definitions captured in THIS bake, at their revision in force at bake time.
    /// Used to detect the staleness of a 'group' definition that itself holds a sound object
    /// (`EditViewModel.isStale`).
    var dependsOn: [ObjectDependency] = []

    init(id: UUID, name: String, wave: String, revision: Int = 0, wasGroup: Bool = false,
         volume: Float = 0, pan: Float = 0, isMuted: Bool = false,
         dependsOn: [ObjectDependency] = []) {
        self.id = id
        self.name = name
        self.wave = wave
        self.revision = revision
        self.wasGroup = wasGroup
        self.volume = volume
        self.pan = pan
        self.isMuted = isMuted
        self.dependsOn = dependsOn
    }

    // Tolerant decoding: absent fields ⇒ neutral values.
    enum CodingKeys: String, CodingKey {
        case id, name, wave, revision, wasGroup, volume, pan, isMuted, dependsOn
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(UUID.self, forKey: .id)
        name      = try c.decode(String.self, forKey: .name)
        wave      = try c.decode(String.self, forKey: .wave)
        revision  = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        wasGroup  = try c.decodeIfPresent(Bool.self, forKey: .wasGroup) ?? false
        volume    = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 0
        pan       = try c.decodeIfPresent(Float.self, forKey: .pan) ?? 0
        isMuted   = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        dependsOn = try c.decodeIfPresent([ObjectDependency].self, forKey: .dependsOn) ?? []
    }
}
