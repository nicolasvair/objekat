import Foundation
import SwiftUI

// MARK: - An available plugin (the catalogue, not persisted)

struct AvailablePlugin: Identifiable {
    let id = UUID()
    let name: String
    let manufacturer: String
    let identifier: String
    let formatName: String
    /// True if the plugin is an instrument (AU MusicDevice / VSTi). Used by the 'virtual
    /// instruments' area of MIDI clips. NB: VST3s are currently all reported `false` (detecting the
    /// VSTi category is a later step).
    var isInstrument: Bool = false

    var displayName: String { name }
    var isBuiltIn: Bool { formatName == "TracktionInternal" }
    var formatLabel: String { ObjectPlugin.label(for: formatName) }
}

// MARK: - Stem

enum StemFormat: String, Codable, Equatable {
    case mono, stereo
}

/// `Equatable`: undo compares the live state to the snapshot so as to rebuild on the engine
/// side only what really changed (@see EditViewModel+UndoRedo).
struct Stem: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var colorIndex: Int
    var format: StemFormat
    /// The bus level in dB (mixer). Optional = backwards compatibility with earlier projects (nil ⇒ 0 dB).
    var gainDb: Float? = nil

    // The bus's FX chain (INC 2): the same fields as a SoundObject. The bus (the stem's FolderTrack,
    // or getMasterPluginList() for the Main) hosts a user rack through the same signal pipeline.
    var plugins: [ObjectPlugin] = []
    var chainInGainDb: Float = 0
    var chainOutGainDb: Float = 0

    /// Routing of the bus's output to the Main (master). true = the stem is summed into the main
    /// mix (the default and historical behaviour); false = the bus is detached from the master (the
    /// FolderTrack no longer contributes to the Main, and its VU stays readable). Not applicable to the Main.
    var routeToMain: Bool = true

    /// Bus mute: cuts the output of the stem's FolderTrack (all of its objects at once), without
    /// touching the items' `isMuted` or the gain. The Main is not mutable (always false).
    var muted: Bool = false

    /// The bus's identity colour: taken from the palette dedicated to stems
    /// (`ObjekatPalette.stems`), distinct from the palette of custom object colours — a stem and a
    /// recoloured object are never confused.
    var color: Color { ObjekatPalette.stem(colorIndex) }

    /// The same meaning as `SoundObject.needsChainCompile`: the bus's FX chain has to be compiled
    /// if it carries plugins OR only trim gains.
    var needsChainCompile: Bool { !plugins.isEmpty || chainInGainDb != 0 || chainOutGainDb != 0 }

    init(id: UUID, name: String, colorIndex: Int, format: StemFormat,
         gainDb: Float? = nil, plugins: [ObjectPlugin] = [],
         chainInGainDb: Float = 0, chainOutGainDb: Float = 0,
         routeToMain: Bool = true, muted: Bool = false) {
        self.id = id; self.name = name; self.colorIndex = colorIndex; self.format = format
        self.gainDb = gainDb; self.plugins = plugins
        self.chainInGainDb = chainInGainDb; self.chainOutGainDb = chainOutGainDb
        self.routeToMain = routeToMain; self.muted = muted
    }

    // Backwards-compatible decoding: absent FX fields (projects earlier than INC 2) ⇒ neutral values.
    enum CodingKeys: String, CodingKey {
        case id, name, colorIndex, format, gainDb, plugins, chainInGainDb, chainOutGainDb, routeToMain, muted
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(UUID.self, forKey: .id)
        name          = try c.decode(String.self, forKey: .name)
        colorIndex    = try c.decode(Int.self, forKey: .colorIndex)
        format        = try c.decode(StemFormat.self, forKey: .format)
        gainDb        = try c.decodeIfPresent(Float.self, forKey: .gainDb)
        plugins       = try c.decodeIfPresent([ObjectPlugin].self, forKey: .plugins) ?? []
        chainInGainDb = try c.decodeIfPresent(Float.self, forKey: .chainInGainDb) ?? 0
        chainOutGainDb = try c.decodeIfPresent(Float.self, forKey: .chainOutGainDb) ?? 0
        routeToMain   = try c.decodeIfPresent(Bool.self, forKey: .routeToMain) ?? true
        muted         = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
    }
}

// MARK: - An object's custom colour

/// A custom object colour: 16 deep hues, distinct from the stems' palette
/// (`ObjekatPalette.stems`) so that a recoloured object and the stem carrying it are never
/// visually confused. @see ObjekatPalette
enum ObjectColorPalette {
    static let count = 16
    static var palette: [Color] { ObjekatPalette.objects }
    static func color(at index: Int) -> Color {
        palette[((index % count) + count) % count]
    }
}

// MARK: - A plugin in an object's rack

struct ObjectPlugin: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var manufacturer: String
    var identifier: String
    var formatName: String
    var isEnabled: Bool = true
    /// The plugin's full state (built-in params + an external binary state) serialised
    /// to XML by Tracktion. nil for projects earlier than v9.
    var stateXML: String? = nil
    /// The identity of the 'link' group: every `ObjectPlugin` sharing this same
    /// `linkGroupID` has its parameters synced. nil = an independent instance.
    var linkGroupID: UUID? = nil
    /// A link group LEFT, but rejoinable. Unlinking no longer loses the group's identity: we
    /// record it here. The link icon then stays shown, muted, and a click rejoins — the plugin
    /// adopting the group's settings (@see EditViewModel.relinkPlugin).
    /// Mutually exclusive with `linkGroupID`: a plugin is linked, detached, or neither.
    var detachedLinkGroupID: UUID? = nil
    /// Non-nil ⇒ this entry is NOT a plugin but a PARALLEL BLOCK (a rack).
    /// On the engine side it compiles into ONE `RackInstance` + `RackType` whose graph
    /// encodes all the internal nesting (tracktion racks do not nest:
    /// `RackInstance::canBeAddedToRack()==false`). See [[synoptic-plugin-view-design]].
    var rack: PluginRack? = nil
    /// THIS instance's identity colour, drawn at random on creation (an index into
    /// `ObjekatPalette.plugins`). It serves to recognise at a glance which card in the signal
    /// view goes with which plugin — its on/off, halo and link badge all derive from it
    /// (@see SynopticMapping.leaf). A LINKED copy (⌘) or a move inherits its source's colour
    /// (the same identity); an independent copy (⌥) or a fresh addition draws a new one at
    /// random.
    var colorIndex: Int = Int.random(in: 0..<ObjekatPalette.plugins.count)

    init(id: UUID, name: String, manufacturer: String, identifier: String, formatName: String,
         isEnabled: Bool = true, stateXML: String? = nil,
         linkGroupID: UUID? = nil, detachedLinkGroupID: UUID? = nil,
         rack: PluginRack? = nil,
         colorIndex: Int = Int.random(in: 0..<ObjekatPalette.plugins.count)) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.identifier = identifier
        self.formatName = formatName
        self.isEnabled = isEnabled
        self.stateXML = stateXML
        self.linkGroupID = linkGroupID
        self.detachedLinkGroupID = detachedLinkGroupID
        self.rack = rack
        self.colorIndex = colorIndex
    }

    /// True if this entry represents a parallel block (and not a plain plugin).
    var isRack: Bool { rack != nil }

    var isLinked: Bool { linkGroupID != nil }
    /// Out of its group but able to come back. @see detachedLinkGroupID
    var isLinkDetached: Bool { linkGroupID == nil && detachedLinkGroupID != nil }
    /// The group this plugin belongs to, whether it is active in it or merely able to rejoin.
    var effectiveLinkGroupID: UUID? { linkGroupID ?? detachedLinkGroupID }
    var isBuiltIn: Bool { formatName == "TracktionInternal" }
    var formatLabel: String { Self.label(for: formatName) }
    var color: Color { ObjekatPalette.plugin(colorIndex) }

    static func label(for formatName: String) -> String {
        switch formatName {
        case "TracktionInternal": return "TE"
        case "AudioUnit":         return "AU"
        case "VST3":              return "VST3"
        default:                  return formatName
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, manufacturer, identifier, formatName, isEnabled, stateXML,
             linkGroupID, detachedLinkGroupID, rack, colorIndex
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        manufacturer = try c.decode(String.self, forKey: .manufacturer)
        identifier = try c.decode(String.self, forKey: .identifier)
        formatName = try c.decode(String.self, forKey: .formatName)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        stateXML = try c.decodeIfPresent(String.self, forKey: .stateXML)
        linkGroupID = try c.decodeIfPresent(UUID.self, forKey: .linkGroupID)
        detachedLinkGroupID = try c.decodeIfPresent(UUID.self, forKey: .detachedLinkGroupID)
        rack = try c.decodeIfPresent(PluginRack.self, forKey: .rack)
        // Backwards compatibility: projects earlier than this identity colour → a random value,
        // stable from the first save that follows.
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex)
                        ?? Int.random(in: 0..<ObjekatPalette.plugins.count)
    }
}

// MARK: - Parallel block (rack)

/// The dB gain `ObjGainPlugin` treats as EXACT silence: it is the bottom of its range, and there
/// it outputs a zero rather than a very quiet −96 dB. The value pushed to the engine for a muted
/// branch — any lower value would be brought back here by its clamp, so we may as well say it.
let objGainSilenceDb: Float = -96.0

/// A persisted parallel block, carried by an `ObjectPlugin` (the `rack` field). Each branch is
/// a recursive SERIES chain: a branch can itself hold a rack entry (nesting), flattened into a
/// single `RackType` on the engine side. The recursion does not blow the value's size up
/// because it goes through an array (heap indirection).
struct PluginRack: Codable, Equatable {
    /// N series chains in parallel (split → branch → summed merge). N is free.
    var voices: [[ObjectPlugin]]
    /// The wet level per branch in dB (0 = unity). nil or short ⇒ 0 dB by default.
    /// Reserved for a later step (an ObjGain at the head of the branch on the engine side).
    var wetDb: [Float]? = nil
    /// Mute per branch: silences a branch without losing its gain. nil/short ⇒ not muted.
    var voiceMutes: [Bool]? = nil

    init(voices: [[ObjectPlugin]], wetDb: [Float]? = nil, voiceMutes: [Bool]? = nil) {
        self.voices = voices
        self.wetDb  = wetDb
        self.voiceMutes = voiceMutes
    }
}

// MARK: - A send towards an aux

/// The send level considered to be -∞ (a silent send). At or below it, the send is
/// treated as off on the UI side and is not wired to the engine.
let sendMinDb: Float = -60.0
/// A send's gain ceiling (dB).
let sendMaxDb: Float = 6.0

/// A POST-FADER send from an object (clip or group) towards an AUX object, by its id.
/// The level is in dB. Routing and time gating are handled on the aux's side (its in/out window).
/// `enabled` = the user's intent (the inspector's toggle); the level is remembered even when
/// off. The send is only audible/wired if `enabled && levelDb > sendMinDb`.
struct AuxSend: Codable, Equatable, Identifiable {
    var auxID: UUID
    var levelDb: Float = 0.0
    var enabled: Bool = true
    var id: UUID { auxID }

    /// True if the level is -∞ (≤ sendMinDb).
    var isSilent: Bool { levelDb <= sendMinDb }
    /// True if the send really has to be routed to the engine.
    var isRouted: Bool { enabled && !isSilent }

    init(auxID: UUID, levelDb: Float = 0.0, enabled: Bool = true) {
        self.auxID = auxID
        self.levelDb = levelDb
        self.enabled = enabled
    }

    // Backwards-compatible decoding: `enabled` absent (old projects) ⇒ true.
    enum CodingKeys: String, CodingKey { case auxID, levelDb, enabled }
    init(from decoder: Decoder) throws {
        let c   = try decoder.container(keyedBy: CodingKeys.self)
        auxID   = try c.decode(UUID.self, forKey: .auxID)
        levelDb = try c.decodeIfPresent(Float.self, forKey: .levelDb) ?? 0.0
        enabled = try c.decodeIfPresent(Bool.self,  forKey: .enabled) ?? true
    }
}

// MARK: - MIDI note

/// One note of a MIDI clip. Timing in BEATS relative to the start of the clip (Tracktion's
/// `MidiList` is beats-based; the beats↔seconds conversion happens at the current tempo).
/// `pitch`/`velocity` over 0…127 (MIDI conventions).
struct MidiNote: Identifiable, Codable, Equatable {
    var id = UUID()
    var pitch: Int            // 0…127 (60 = middle C / C3)
    var startBeat: Double     // start, in beats from the start of the clip
    var lengthBeats: Double   // length, in beats
    var velocity: Int = 100   // 0…127

    enum CodingKeys: String, CodingKey { case id, pitch, startBeat, lengthBeats, velocity }
    init(id: UUID = UUID(), pitch: Int, startBeat: Double, lengthBeats: Double, velocity: Int = 100) {
        self.id = id; self.pitch = pitch; self.startBeat = startBeat
        self.lengthBeats = lengthBeats; self.velocity = velocity
    }
    init(from decoder: Decoder) throws {
        let c       = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decodeIfPresent(UUID.self,   forKey: .id) ?? UUID()
        pitch       = try c.decode(Int.self,    forKey: .pitch)
        startBeat   = try c.decode(Double.self, forKey: .startBeat)
        lengthBeats = try c.decode(Double.self, forKey: .lengthBeats)
        velocity    = try c.decodeIfPresent(Int.self, forKey: .velocity) ?? 100
    }
}

// MARK: - A sound object's attribute links

/// The mix attributes of a sound object instance (`definitionID`) that have been switched to
/// INDEPENDENT, that is, detached from the shared value the definition carries. Empty (the
/// default) = all synced: changing the attribute on one instance propagates it to every other.
/// Not applicable to an unlinked object. See EditViewModel+Objects (`propagateLinkedAttr`/`setAttrSynced`).
struct ObjectAttrLinks: OptionSet, Codable {
    let rawValue: Int
    static let volume = ObjectAttrLinks(rawValue: 1 << 0)
    static let pan    = ObjectAttrLinks(rawValue: 1 << 1)
    static let mute   = ObjectAttrLinks(rawValue: 1 << 2)
}

// MARK: - SoundObject

/// `Equatable` (synthesised, RECURSIVE over `kind.group(children:)`): undo uses it to leave
/// untouched on the engine side any subtree identical between the live state and the snapshot.
/// Equality therefore has to cover EVERYTHING that gets pushed to the engine — which holds as
/// long as each field stays stored here (including `plugins[].stateXML`, captured on both sides
/// by `currentSnapshot()`). @see EditViewModel+UndoRedo.
struct SoundObject: Identifiable, Codable, Equatable {
    var id: UUID
    var startTime: Double
    var duration: Double
    var lane: Int
    var volume: Float
    var pan: Float
    var fadeIn: Double
    var fadeOut: Double
    var isMuted: Bool
    var stemID: UUID?
    var plugins: [ObjectPlugin]
    /// A MIDI clip's virtual instruments (AU/VSTi), at the HEAD of the chain (before the `plugins`
    /// FX). Empty for audio clips / groups / auxes. Step A: 0 or 1 instrument (slot index 0 of the
    /// engine track, outside the RackType). An array from now on so as to prepare for several
    /// instruments in parallel (an instrument rack with MIDI fan-out), not implemented engine-side in step A.
    var instruments: [ObjectPlugin] = []
    /// The dB gain at the START and END of the plugin chain (input / output trim), independent of
    /// the fader. Always present in the signal view, even without a parallel block. 0 = unity.
    var chainInGainDb: Float = 0
    var chainOutGainDb: Float = 0
    var label: String?
    /// A custom colour (an index into `ObjectColorPalette.palette`), independent of the stem —
    /// assignable through the context menu on a clip / MIDI clip / group / aux. `nil` = no colour
    /// of its own, and the object keeps only its stem's colour. See `customColor` below.
    var colorIndex: Int?
    /// Post-fader sends towards AUX objects (clips and groups can send;
    /// an aux carries no sends, it only receives).
    var sends: [AuxSend]
    var baseBPM: Double?
    /// A MIDI clip whose editing piano roll is unfolded INLINE (it reserves a band of sub-lanes
    /// under the clip, like an expanded group). False for everything else. Pure UI (no engine
    /// effect) but persisted so as to reopen the project in the same state.
    var pianoRollOpen: Bool = false
    /// THIS object's automation curves, one per parameter. The invariant 'no point = no
    /// automation': an entry with no point is never stored (@see AutomationLane). The points' times
    /// are RELATIVE to the start of the object (@see AutomationPoint).
    var automation: [AutomationLane] = []
    /// The parameters RECENTLY TOUCHED on this object, the most recent at the head — the memory the
    /// 'future automation' row comes out of (@see pendingAutomationParam). 'Touching' = setting the
    /// parameter's value, by any path: the timeline's or the signal view's fader/pan, a chain trim,
    /// a send level, a knob in a plugin's editor (built-in or AU/VST).
    ///
    /// PERSISTED, and that is a choice: keeping it in the model leaves `automationRows` /
    /// `automationSpan` as PURE MODEL computed properties, so that all the layout that reads them
    /// (`expandedSpan`, `laneEntries`, `automationBandRect`, the wheel monitor) knows nothing of
    /// this tracking's existence. Holding it on the view-model's side would mean passing the
    /// pending parameter into every one of those sites. It is also the same class of decision as
    /// `automationOpen`, already persisted: reopening a project must reopen the same band.
    ///
    /// Bounded by `automationTouchMemory`: it is a 'what I have just done', not a history.
    var automationTouchOrder: [ParamRef] = []
    /// An object whose AUTOMATION band is unfolded inline (it reserves a band of sub-lanes, like an
    /// expanded group or a piano roll). For a GROUP, that band REPLACES the display of the children
    /// while it is open — a design decision: you look either at the content or at the curves, never
    /// at both tangled together. Pure UI (no engine effect) but persisted so as to reopen the
    /// project in the same state.
    var automationOpen: Bool = false
    var kind: Kind
    /// Non-nil ⇒ this placement is an INSTANCE of a sound object: its `kind` reads the current wave
    /// of the definition `EditViewModel.objectDefinitions[definitionID]`. Everything else (position,
    /// fades, gain/pan, the plugins belonging to THIS placement) stays independent — only the deep
    /// content is shared by every instance. See EditViewModel+Objects.
    var definitionID: UUID? = nil
    /// Mix attributes (volume/pan/mute) detached from the definition for THIS instance only.
    /// Empty = all synced (the default). No effect if `definitionID == nil`.
    var independentAttrs: ObjectAttrLinks = []
    /// An AUX or GROUP marked 'infinite': no more start/end, it spans the WHOLE project and becomes
    /// a 'normal' processing bus (a reverb live from the start to the end, say). Not applicable to
    /// clips/MIDI (always false). One infinite per lane (see EditViewModel).
    var isInfinite: Bool = false
    /// True ⇒ the CONTENT (a clip's source range, the span of a group's children) repeats for as
    /// long as the object's window goes beyond that natural content, instead of leaving silence.
    /// Not applicable to an aux (it has no content of its own). @see [[loop-item-plan]]
    var loopEnabled: Bool = false
    /// The IN/OUT bounds of the repeating pattern, in SECONDS LOCAL TO THE OBJECT (0 = its own
    /// `startTime`, the same reference as `duration`) — NOT the file/beats reference the engine
    /// expects, the conversion happening at sync time (@see EditViewModel.syncLoopRange). `nil`
    /// while the loop has never been turned on: they are set once, on turning it on, to the size the
    /// object had THEN (`[0, duration]`) — and then FROZEN: resizing the object afterwards does not
    /// move them again (otherwise stretching would reshape the pattern instead of repeating it).
    /// Adjustable afterwards through the IN/OUT markers (dragged inside the block) or
    /// `object.set_loop_range`. For an AUDIO CLIP only, they may go beyond `[0, duration]` — a
    /// 'sampler-style' loop point, past what is visible. @see [[loop-item-plan]]
    var loopRangeStart: Double? = nil
    var loopRangeEnd: Double? = nil

    /// True if this object is an instance of a sound object (baked, tied to a definition).
    var isObjectInstance: Bool { definitionID != nil }
    /// True if the object CAN be made infinite (an aux or a group only).
    var canBeInfinite: Bool { isAux || isGroup }
    /// True if the object CAN be looped: an audio clip NOT reversed, a group NOT infinite (an
    /// infinite one has no window left — nothing to go beyond), or a MIDI clip. Reverse is ruled out
    /// for a clip: its anchor (`sourceOffset`, a FIXED point when the right edge is extended) is
    /// recomputed from `duration`, which becomes unbounded precisely when looping — the period
    /// degenerates (see OBJEngineCore.mm, updatePosition). @see [[loop-item-plan]]
    var canLoop: Bool {
        if isClip { return !isReversed }
        if isGroup { return !isInfinite }
        return isMIDI
    }

    /// The natural span (in timeline seconds) of a group's content: the envelope of its direct
    /// children, from the start of the earliest to the end of the latest. `nil` if not a group or
    /// with no child. It is the period of its loop, exactly as `fileDuration - sourceOffset` is for
    /// a clip — the engine computes the same envelope in C++ (@see refreshContainerSpanForKey).
    /// The loop's IN/OUT bounds in seconds LOCAL TO THE BLOCK (0 = `startTime`, the same reference
    /// as `duration`) — what display and interaction (markers, dragging) want, block pixels
    /// obliging. It is ALSO the storage reference, for EVERY kind: the conversion to the engine's
    /// reference (the file for a clip, beats for MIDI, edit seconds for a group) happens at sync
    /// time only (@see EditViewModel.clipLoopFileBounds, syncMidiLoop, syncGroupWindow). For a
    /// while this getter converted file→local for clips while the rest of the code already stored
    /// local: the markers landed off (and a round trip through dragging shifted the loop by one
    /// `sourceOffset` each time). `nil` if the loop is not active or has no bounds set.
    /// @see [[loop-item-plan]]
    var loopMarkerLocalRange: (start: Double, end: Double)? {
        guard loopEnabled, let s = loopRangeStart, let e = loopRangeEnd, e > s else { return nil }
        return (s, e)
    }

    /// The inverse of `loopMarkerLocalRange` — the identity since storage IS local, kept as a single
    /// point of passage should a kind ever store things differently.
    /// @see [[loop-item-plan]]
    func loopRangeFromLocal(start: Double, end: Double) -> (start: Double, end: Double) {
        (start, end)
    }

    var groupContentSpan: Double? {
        guard case .group(let children, _) = kind, !children.isEmpty else { return nil }
        let start = children.map(\.startTime).min()!
        let end = children.map { $0.startTime + $0.duration }.max()!
        return end > start ? end - start : nil
    }
    /// True if the object really is an infinite bus (the flag set AND a compatible type).
    var isInfiniteBus: Bool { isInfinite && canBeInfinite }
    var customColor: Color? { colorIndex.map(ObjectColorPalette.color(at:)) }
    /// True if the object's FX chain has something to compile on the engine side: plugins, OR only
    /// start/end trim gains (the rack then has to be materialised anyway — chain ObjGains do not
    /// exist without a compile), OR an AUTOMATION of those gains: a trim curve laid on an object
    /// whose static trim stayed at 0 dB would otherwise have no plugin to write itself into, and
    /// would never be heard.
    var needsChainCompile: Bool {
        !plugins.isEmpty || chainInGainDb != 0 || chainOutGainDb != 0
            || automation.contains { ($0.param == .chainInGain || $0.param == .chainOutGain)
                                     && !$0.points.isEmpty }
    }

    // MARK: Kind

    indirect enum Kind: Codable, Equatable {
        case clip(filePath: String, sourceOffset: Double, fileDuration: Double,
                  speedRatio: Double, isReversed: Bool)
        case group(children: [SoundObject], isExpanded: Bool)
        /// AUX = a 'receive-only' object: no file, it receives sends, and has a window
        /// (start/end) plus fades and plugins (reverb/delay) like a clip.
        case aux
        /// MIDI CLIP: no audio file; it hosts a virtual instrument (SoundObject's `instruments`
        /// field) at the head of the chain and carries notes (in beats). `lengthBeats` = the clip's
        /// musical length (its timeline length in seconds stays `duration`, at the current tempo).
        case midiClip(notes: [MidiNote], lengthBeats: Double)

        private enum CodingKeys: String, CodingKey {
            case type, filePath, sourceOffset, fileDuration, speedRatio, isReversed
            case children, isExpanded
            case notes, lengthBeats
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .clip(let fp, let so, let fd, let sr, let rev):
                try c.encode("clip", forKey: .type)
                try c.encode(fp,  forKey: .filePath)
                try c.encode(so,  forKey: .sourceOffset)
                try c.encode(fd,  forKey: .fileDuration)
                try c.encode(sr,  forKey: .speedRatio)
                try c.encode(rev, forKey: .isReversed)
            case .group(let children, let isExpanded):
                try c.encode("group", forKey: .type)
                try c.encode(children,   forKey: .children)
                try c.encode(isExpanded, forKey: .isExpanded)
            case .aux:
                try c.encode("aux", forKey: .type)
            case .midiClip(let notes, let lengthBeats):
                try c.encode("midiClip", forKey: .type)
                try c.encode(notes,       forKey: .notes)
                try c.encode(lengthBeats, forKey: .lengthBeats)
            }
        }

        init(from decoder: Decoder) throws {
            let c    = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "clip":
                self = .clip(
                    filePath:     try c.decode(String.self, forKey: .filePath),
                    sourceOffset: try c.decodeIfPresent(Double.self, forKey: .sourceOffset) ?? 0.0,
                    fileDuration: try c.decodeIfPresent(Double.self, forKey: .fileDuration) ?? 0.0,
                    speedRatio:   try c.decodeIfPresent(Double.self, forKey: .speedRatio)   ?? 1.0,
                    isReversed:   try c.decodeIfPresent(Bool.self,   forKey: .isReversed)   ?? false
                )
            case "group":
                self = .group(
                    children:   try c.decodeIfPresent([SoundObject].self, forKey: .children) ?? [],
                    isExpanded: try c.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? false
                )
            case "aux":
                self = .aux
            case "midiClip":
                self = .midiClip(
                    notes:       try c.decodeIfPresent([MidiNote].self, forKey: .notes) ?? [],
                    lengthBeats: try c.decodeIfPresent(Double.self, forKey: .lengthBeats) ?? 4.0
                )
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                    debugDescription: "Unknown type: \(type)")
            }
        }
    }

    // MARK: Computed

    var displayName: String {
        if let l = label { return l }
        switch kind {
        case .clip(let fp, _, _, _, _):
            return URL(fileURLWithPath: fp).lastPathComponent
        case .group:
            return L("object.kind.group")
        case .aux:
            return L("object.kind.aux")
        case .midiClip:
            return L("object.kind.midi")
        }
    }

    var isAux: Bool { if case .aux = kind { return true }; return false }
    var isGroup: Bool { if case .group = kind { return true }; return false }
    var isMIDI: Bool { if case .midiClip = kind { return true }; return false }
    var isClip: Bool { if case .clip = kind { return true }; return false }

    /// The roundness of the block's corners in the timeline. Defined here, on the model, because
    /// three places depend on it and have to agree: rendering (`SoundBlockView`, `GroupBlockView`),
    /// the hovered editing zones, and the link halos — a halo drawn at a different radius from its
    /// block is seen immediately (clipped corners).
    var blockCornerRadius: Double {
        if isAux || isGroup { return 20 }
        return 4
    }

    /// The MIDI clip's notes (empty for the other types). The setter only applies to a `.midiClip`.
    var midiNotes: [MidiNote] {
        get { if case .midiClip(let n, _) = kind { return n }; return [] }
        set { if case .midiClip(_, let len) = kind { kind = .midiClip(notes: newValue, lengthBeats: len) } }
    }
    /// The MIDI clip's musical length (beats); 0 for the other types.
    var midiLengthBeats: Double {
        get { if case .midiClip(_, let len) = kind { return len }; return 0 }
        set { if case .midiClip(let n, _) = kind { kind = .midiClip(notes: n, lengthBeats: newValue) } }
    }

    /// A compact volume / pan / speed summary shown next to the name on the timeline.
    /// Only what differs from the default (0 dB, centre, ×1) is shown, so as to avoid noise;
    /// speed means nothing for a group. The same conventions as the inspector.
    var timelineMetaSummary: String {
        var parts: [String] = []
        if volume <= -96 { parts.append("-∞ dB") }
        else if abs(volume) >= 0.5 { parts.append("\(Int(volume.rounded())) dB") }
        if abs(pan) >= 0.01 {
            parts.append(pan < 0 ? "L\(Int((-pan * 100).rounded()))" : "R\(Int((pan * 100).rounded()))")
        }
        if case .clip = kind, abs(speedRatio - 1.0) >= 0.01 {
            parts.append(String(format: "×%.2f", speedRatio))
        }
        return parts.joined(separator: " · ")
    }

    // Clip accessors (used by SoundBlockView without changing that view)
    var filePath: String {
        guard case .clip(let fp, _, _, _, _) = kind else { return "" }
        return fp
    }
    var sourceOffset: Double {
        get { guard case .clip(_, let so, _, _, _) = kind else { return 0 }; return so }
        set {
            guard case .clip(let fp, _, let fd, let sr, let rev) = kind else { return }
            kind = .clip(filePath: fp, sourceOffset: newValue, fileDuration: fd, speedRatio: sr, isReversed: rev)
        }
    }
    var fileDuration: Double {
        guard case .clip(_, _, let fd, _, _) = kind else { return 0 }
        return fd
    }
    var fileName: String {
        switch kind {
        case .clip(let fp, _, _, _, _): return URL(fileURLWithPath: fp).lastPathComponent
        case .group: return "Groupe"
        case .aux: return "Aux"
        case .midiClip: return "MIDI"
        }
    }
    var speedRatio: Double {
        guard case .clip(_, _, _, let sr, _) = kind else { return 1.0 }
        return sr
    }
    var isReversed: Bool {
        guard case .clip(_, _, _, _, let rev) = kind else { return false }
        return rev
    }

    /// Source content still available BEFORE the window's left edge, in TIMELINE seconds (so
    /// already divided by the speed): how much room there is to open the edge leftwards.
    /// `.infinity` for anything with no source file (a group, an aux, MIDI) or no known length.
    /// In reverse, the window runs back up the source range: what bounds the opening on the left
    /// is then the material located AFTER the range (@see WaveformShaping.retrimmedSourceOffset).
    var contentRoomBefore: Double {
        guard case .clip(_, let so, let fd, let sr, let rev) = kind, fd > 0 else { return .infinity }
        let sp = max(sr, 0.0001)
        return max(0, rev ? (fd - so - duration * sp) : so) / sp
    }

    /// The right-hand counterpart of `contentRoomBefore`: material available AFTER the right edge,
    /// in timeline seconds. The two margins swap when the clip is reversed.
    /// `loopEnabled`: no more edge — the material repeats endlessly (@see [[loop-item-plan]]).
    var contentRoomAfter: Double {
        guard case .clip(_, let so, let fd, let sr, let rev) = kind, fd > 0 else { return .infinity }
        if loopEnabled { return .infinity }
        let sp = max(sr, 0.0001)
        return max(0, rev ? so : (fd - so - duration * sp)) / sp
    }

    // Group accessors
    var childLaneCount: Int {
        guard case .group(let children, let isExpanded) = kind else { return 0 }
        let base = max(1, SoundObject.occupiedLanes(children))
        return isExpanded ? base + 1 : base
    }

    /// How many sub-lanes an unfolded MIDI clip's piano roll takes (≈ 2 octaves).
    static let pianoRollLaneSpan = 2

    /// How many display lanes are reserved UNDER this object by an area unfolded inline:
    /// an expanded group's children, OR the piano-roll band of an open MIDI clip.
    /// Generalises the old 'group + childLaneCount' logic, to which MIDI adds itself.
    var expandedSpan: Int {
        if automationOpen { return automationSpan }
        if case .group = kind, isExpanded { return childLaneCount }
        if showsPianoRollInline { return Self.pianoRollLaneSpan }
        return 0
    }

    /// True if this MIDI clip really is showing its piano roll INLINE. The exact counterpart of
    /// `showsChildrenInline` for MIDI: opening the automation band hides the piano roll without
    /// folding it — the two cannot occupy the same band.
    var showsPianoRollInline: Bool { isMIDI && pianoRollOpen && !automationOpen }

    /// True if this group really is showing its children INLINE. Distinct from `isExpanded`: an
    /// expanded group switched to automation mode keeps its `isExpanded` (it will find it again on
    /// closing the band) but no longer shows its children — its band is taken by the curves. Every
    /// LAYOUT site (display lanes, band background, the target group of a drop) has to test this
    /// and not `isExpanded`, otherwise they name children that are no longer on screen.
    var showsChildrenInline: Bool {
        if case .group(_, let expanded) = kind { return expanded && !automationOpen }
        return false
    }

    /// The rows of the automation band, in display order: one per parameter actually automated,
    /// plus ONE 'future automation' row — the parameter one is about to automate, still without a
    /// point. So a band is almost never empty: it always offers somewhere to lay the first point,
    /// as long as one free parameter remains.
    var automationRows: [ParamRef] {
        var rows: [ParamRef] = []
        for lane in automation where !lane.points.isEmpty {
            if !rows.contains(lane.param) { rows.append(lane.param) }
        }
        if let pending = pendingAutomationParam, !rows.contains(pending) { rows.append(pending) }
        return rows
    }

    /// The parameter of the 'future automation' row: THE LAST parameter touched on this object,
    /// and it alone — the head of `automationTouchOrder`, never the next one.
    ///
    /// That is the whole rule, and it holds in three beats: you touch a parameter, its row opens;
    /// you lay a point on it, it becomes an automation and NOTHING more is offered; you touch
    /// another parameter, a new row opens. Going down the touch memory to offer at once a parameter
    /// set earlier gave the impression that the application was choosing a target on our behalf.
    ///
    /// Falling back on the fader only plays on a BLANK band (no curve, no touch remembered): a
    /// freshly opened band does have to offer something.
    ///
    /// nil as soon as there is nothing to offer — and that is a normal state, not a lack: the band
    /// then shows real curves only.
    var pendingAutomationParam: ParamRef? {
        if let touched = automationTouchOrder.first {
            guard resolvesAutomationTarget(touched), !hasAutomationPoints(touched) else { return nil }
            return touched
        }
        guard automation.isEmpty else { return nil }
        return Self.fallbackAutomationOrder(self).first { resolvesAutomationTarget($0) }
    }

    /// The fallback order for a BLANK band (a reopened project, a new object): the fader first — it
    /// is the parameter one automates nine times out of ten.
    private static func fallbackAutomationOrder(_ obj: SoundObject) -> [ParamRef] {
        [.volume, .pan, .chainInGain, .chainOutGain] + obj.sends.map { .send(auxID: $0.auxID) }
    }

    /// True if this parameter carries at least one point on this object.
    func hasAutomationPoints(_ ref: ParamRef) -> Bool {
        automation.contains { $0.param == ref && !$0.points.isEmpty }
    }

    /// True if the named target STILL exists on this object. A touch memory outlives what it names:
    /// you remove a plugin, you cut a send, and its `ParamRef` stays in `automationTouchOrder`.
    /// Offering a row for a plugin that has gone would display 'plugin ?'.
    func resolvesAutomationTarget(_ ref: ParamRef) -> Bool {
        switch ref {
        case .volume, .pan, .chainInGain, .chainOutGain:
            return true
        case .send(let auxID):
            return sends.contains { $0.auxID == auxID }
        case .plugin(let pluginKey, _):
            return Self.containsPlugin(pluginKey, in: plugins)
                || Self.containsPlugin(pluginKey, in: instruments)
        }
    }

    /// True if this automation target, carried by the ROOT of this subtree, is BAKED IN when the
    /// object is rendered to a wave — that is, if its carrier goes into the render.
    ///
    /// It is not a choice but an observation about the engine: the render bypasses the TAIL of the
    /// target object's chain — fader, pan, trims, window and fades — precisely because they stay
    /// live on the baked clip (@see renderObjectToFileAsync, `bypassTail`), and it does not catch
    /// the sends (the aux lives outside the rendered submix), hence their being carried over to the
    /// placement. What is left is the root's USER FX: those really are rendered into the file, and a
    /// curve driving them has finished its work — it is heard in the wave.
    ///
    /// `resolvesAutomationTarget` sorts it out on its own for a `.plugin`: a curve aiming at a
    /// plugin ABSENT from this subtree cannot be baked into it. That is exactly the case of a curve
    /// laid on a plugin BELONGING to the instance (added over the baked content) while its content
    /// is open for editing — it belongs to the instance and has to follow it.
    func automationTargetIsBakedIntoRender(_ ref: ParamRef) -> Bool {
        guard case .plugin = ref else { return false }
        return resolvesAutomationTarget(ref)
    }

    /// The subtree as it is written into a shared object's sidecar — that is, the DEFINITION, what
    /// is common to every instance.
    ///
    /// The rule, in one sentence: an automation laid on an object INSIDE the group is part of the
    /// definition (shared by every instance, baked into the wave at bake time); an automation laid
    /// on the GROUP ITSELF belongs to THAT instance alone and applies ON TOP of the bake. The root
    /// is precisely the layer the render leaves live: that is where an instance has a life of its
    /// own, as it has its gain, its pan and its sends.
    ///
    /// Hence SHARING and not amputation: the root's curves the render carries away (its user FX's
    /// parameters) stay in the sidecar, otherwise reopening the object to edit it would find the FX
    /// but no longer their curves, and the re-bake would produce a different sound. The others leave
    /// with the instance (@see automationSurvivingBake) — the two pieces are glued back together on
    /// opening (@see EditViewModel.restoredSubtree).
    ///
    /// The invariant that follows, and which has to be preserved: re-editing then re-baking a
    /// definition does not wipe out a rendered instance's own automation.
    var asObjectDefinition: SoundObject {
        guard !automation.isEmpty || !automationTouchOrder.isEmpty else { return self }
        var copy = self
        copy.automation = automation.filter { automationTargetIsBakedIntoRender($0.param) }
        // The 'last parameter touched' memory: pure interface convenience, and belonging to whoever
        // touched it. It has no business in a shared definition.
        copy.automationTouchOrder = []
        return copy
    }

    /// The root's curves that survive being rendered to a wave: those whose carrier stays live on
    /// the baked clip. The exact complement of what `asObjectDefinition` keeps — the same boundary,
    /// read from the other side.
    var automationSurvivingBake: [AutomationLane] {
        automation.filter { !$0.points.isEmpty && !automationTargetIsBakedIntoRender($0.param) }
    }

    /// Looks a plugin up by id, the branches of parallel blocks included.
    static func containsPlugin(_ key: UUID, in plugins: [ObjectPlugin]) -> Bool {
        for p in plugins {
            if let rack = p.rack {
                if rack.voices.contains(where: { containsPlugin(key, in: $0) }) { return true }
            } else if p.id == key {
                return true
            }
        }
        return false
    }

    /// Remembers a touch: the parameter moves to the head of `automationTouchOrder`. A no-op if it
    /// is already there — by far the most frequent case (dragging a fader calls this on every
    /// frame) and it must cost nothing and not mark the project as modified.
    /// Returns true if the order moved.
    @discardableResult
    mutating func recordAutomationTouch(_ ref: ParamRef) -> Bool {
        if automationTouchOrder.first == ref { return false }
        automationTouchOrder.removeAll { $0 == ref }
        automationTouchOrder.insert(ref, at: 0)
        if automationTouchOrder.count > Self.automationTouchMemory {
            automationTouchOrder.removeLast(automationTouchOrder.count - Self.automationTouchMemory)
        }
        return true
    }

    /// The depth of the touch memory. Enough that promoting a few rows in a row goes on offering
    /// the parameters touched before; little enough to stay a 'recently' and not a log.
    static let automationTouchMemory = 8

    /// The height of the automation band, in display lanes: one row = one lane.
    var automationSpan: Int { max(1, automationRows.count) }

    /// How many display lanes a list of children takes (excluding the drop lane),
    /// allowing for expanded subgroups that take several rows.
    /// Consistent with `EditViewModel.buildLaneEntries`'s `extraAbove`.
    static func occupiedLanes(_ children: [SoundObject]) -> Int {
        var maxBottom = 0
        for child in children {
            let extraAbove = children
                .filter { $0.lane < child.lane }
                .reduce(0) { acc, g in acc + g.expandedSpan }
            let top    = child.lane + extraAbove
            let height = 1 + child.expandedSpan
            maxBottom  = max(maxBottom, top + height)
        }
        return maxBottom
    }
    var isExpanded: Bool {
        guard case .group(_, let e) = kind else { return false }
        return e
    }

    // MARK: Init

    init(id: UUID = UUID(), startTime: Double, duration: Double, lane: Int,
         volume: Float = 0.0, pan: Float = 0.0,
         fadeIn: Double = 0.0, fadeOut: Double = 0.0,
         isMuted: Bool = false, stemID: UUID? = nil,
         plugins: [ObjectPlugin] = [], instruments: [ObjectPlugin] = [],
         label: String? = nil, colorIndex: Int? = nil,
         sends: [AuxSend] = [], baseBPM: Double? = nil,
         definitionID: UUID? = nil,
         independentAttrs: ObjectAttrLinks = [],
         chainInGainDb: Float = 0, chainOutGainDb: Float = 0,
         pianoRollOpen: Bool = false,
         automation: [AutomationLane] = [],
         automationTouchOrder: [ParamRef] = [],
         isInfinite: Bool = false,
         loopEnabled: Bool = false,
         loopRangeStart: Double? = nil,
         loopRangeEnd: Double? = nil,
         kind: Kind) {
        self.id         = id
        self.startTime  = startTime
        self.duration   = duration
        self.lane       = lane
        self.volume     = volume
        self.pan        = pan
        self.fadeIn     = fadeIn
        self.fadeOut    = fadeOut
        self.isMuted    = isMuted
        self.stemID     = stemID
        self.plugins    = plugins
        self.instruments = instruments
        self.label      = label
        self.colorIndex = colorIndex
        self.sends      = sends
        self.baseBPM    = baseBPM
        self.definitionID = definitionID
        self.independentAttrs = independentAttrs
        self.chainInGainDb  = chainInGainDb
        self.chainOutGainDb = chainOutGainDb
        self.pianoRollOpen  = pianoRollOpen
        self.automation     = automation
        self.automationTouchOrder = automationTouchOrder
        self.isInfinite     = isInfinite
        self.loopEnabled    = loopEnabled
        self.loopRangeStart = loopRangeStart
        self.loopRangeEnd   = loopRangeEnd
        self.kind       = kind
    }

    // MARK: Derived copy

    /// A 'derived' copy: a new object inheriting ALL of `self`'s mix / routing / identity
    /// attributes (volume, pan, mute, stem, label, colour, sends, baseBPM, chain gains, sound
    /// object link, detached attributes), with geometry / fades / kind supplied by the caller. A
    /// SINGLE point for the copying sites (split, fragment, overlap, paste…): a new field added
    /// here is inherited everywhere, instead of being forgotten site by site.
    /// `plugins`/`instruments` stay explicit: depending on the site one needs clones
    /// (`copiedPlugins`/`copiedInstruments`) or the original list (an object keeping its id).
    /// `pianoRollOpen` / `automationOpen` are NOT inherited (a copy is born folded).
    /// `automation` is, on the other hand: a copy/duplication/paste keeps its curves, and since
    /// the points are RELATIVE to the object's start, an identical geometry leaves them right.
    /// justes.
    ///
    /// The sites that change the start or cut the object (split, a time selection fragment,
    /// overlap) pass their own curves through the `automation` parameter — already shifted or
    /// cut with the model's primitives (@see AutomationLane.shifted / .split). They still go
    /// through the plugin remapping below: it is precisely so that a cutting site does not have to
    /// redo it by hand that it goes through this parameter rather than writing
    /// `copy.automation = …` afterwards.
    ///
    /// PLUGIN PARAMETER curves need one more care: most copying sites pass CLONED plugins, whose
    /// id is necessarily new (the engine's `_pluginMap` key is `ObjectPlugin.id` — reusing the id
    /// would make every copy point at the same instance). A `ParamRef.plugin` inherited as it is
    /// would therefore name a plugin that is not in this copy. We remap it, pairing up the leaves
    /// of the two flattened lists in the same order; whatever does not pair up is DROPPED rather
    /// than left dangling (a curve with no carrier is worse than a missing curve).
    func derivedCopy(id: UUID = UUID(), startTime: Double, duration: Double, lane: Int,
                     fadeIn: Double, fadeOut: Double,
                     plugins: [ObjectPlugin], instruments: [ObjectPlugin] = [],
                     automation: [AutomationLane]? = nil,
                     kind: Kind) -> SoundObject {
        var remap = Self.pluginIDRemap(from: self.plugins,     to: plugins)
        remap.merge(Self.pluginIDRemap(from: self.instruments, to: instruments)) { a, _ in a }
        let inherited = automation ?? self.automation
        return SoundObject(id: id, startTime: startTime, duration: duration, lane: lane,
                    volume: volume, pan: pan, fadeIn: fadeIn, fadeOut: fadeOut,
                    isMuted: isMuted, stemID: stemID,
                    plugins: plugins, instruments: instruments,
                    label: label, colorIndex: colorIndex,
                    sends: sends, baseBPM: baseBPM,
                    definitionID: definitionID,
                    independentAttrs: independentAttrs,
                    chainInGainDb: chainInGainDb, chainOutGainDb: chainOutGainDb,
                    automation: inherited.compactMap { lane in
                        guard let ref = Self.remapping(lane.param, with: remap) else { return nil }
                        return AutomationLane(param: ref, points: lane.points)
                    },
                    automationTouchOrder: automationTouchOrder.compactMap {
                        Self.remapping($0, with: remap)
                    },
                    isInfinite: isInfinite,
                    loopEnabled: loopEnabled,
                    loopRangeStart: loopRangeStart,
                    loopRangeEnd: loopRangeEnd,
                    kind: kind)
    }

    /// A chain's plugin leaves, the branches of parallel blocks flattened in series order.
    static func pluginLeaves(_ plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.flatMap { p -> [ObjectPlugin] in
            if let rack = p.rack { return rack.voices.flatMap { pluginLeaves($0) } }
            return [p]
        }
    }

    /// A table of old id → new id, by POSITIONAL pairing of the leaves. That is legitimate because
    /// cloning (`copiedPlugins` / `copiedInstruments`) preserves the structure: it only reshuffles
    /// the ids. A copy that keeps its plugins as they are yields the identity.
    static func pluginIDRemap(from old: [ObjectPlugin], to new: [ObjectPlugin]) -> [UUID: UUID] {
        let a = pluginLeaves(old), b = pluginLeaves(new)
        guard a.count == b.count else { return [:] }   // different structures: we invent nothing
        return Dictionary(uniqueKeysWithValues: zip(a.map(\.id), b.map(\.id)))
    }

    /// The `ParamRef` transposed into the copy. nil = a lost target (a plugin with no counterpart in
    /// the new chain). A copy that keeps its plugins as they are gets the IDENTITY table, so it
    /// goes down the same path without changing anything.
    static func remapping(_ ref: ParamRef, with remap: [UUID: UUID]) -> ParamRef? {
        guard case .plugin(let key, let paramID) = ref else { return ref }
        guard let newKey = remap[key] else { return nil }
        return .plugin(pluginKey: newKey, paramID: paramID)
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case id, startTime, duration, lane, volume, pan, fadeIn, fadeOut
        case isMuted, stemID, plugins, instruments, label, colorIndex, sends, baseBPM, kind
        case chainInGainDb, chainOutGainDb, pianoRollOpen, definitionID, independentAttrs
        case isInfinite, automation, automationOpen, automationTouch, loopEnabled
        case loopRangeStart, loopRangeEnd
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(duration,  forKey: .duration)
        try c.encode(lane,      forKey: .lane)
        try c.encode(volume,    forKey: .volume)
        try c.encode(pan,       forKey: .pan)
        try c.encode(fadeIn,    forKey: .fadeIn)
        try c.encode(fadeOut,   forKey: .fadeOut)
        try c.encode(isMuted,   forKey: .isMuted)
        try c.encodeIfPresent(stemID,     forKey: .stemID)
        try c.encode(plugins,   forKey: .plugins)
        if !instruments.isEmpty { try c.encode(instruments, forKey: .instruments) }
        try c.encodeIfPresent(label,      forKey: .label)
        try c.encodeIfPresent(colorIndex, forKey: .colorIndex)
        if !sends.isEmpty { try c.encode(sends, forKey: .sends) }
        try c.encodeIfPresent(baseBPM, forKey: .baseBPM)
        try c.encodeIfPresent(definitionID, forKey: .definitionID)
        if !independentAttrs.isEmpty { try c.encode(independentAttrs, forKey: .independentAttrs) }
        if chainInGainDb  != 0 { try c.encode(chainInGainDb,  forKey: .chainInGainDb) }
        if chainOutGainDb != 0 { try c.encode(chainOutGainDb, forKey: .chainOutGainDb) }
        if pianoRollOpen { try c.encode(true, forKey: .pianoRollOpen) }
        // 'No point = no automation': empty rows are not written.
        let curves = automation.filter { !$0.points.isEmpty }
        if !curves.isEmpty { try c.encode(curves, forKey: .automation) }
        if automationOpen { try c.encode(true, forKey: .automationOpen) }
        // The memory of touched parameters: only write what still names something, so that a project
        // does not drag dead targets along from session to session.
        let touched = automationTouchOrder.filter { resolvesAutomationTarget($0) }
        if !touched.isEmpty { try c.encode(touched, forKey: .automationTouch) }
        if isInfinite { try c.encode(true, forKey: .isInfinite) }
        if loopEnabled { try c.encode(true, forKey: .loopEnabled) }
        try c.encodeIfPresent(loopRangeStart, forKey: .loopRangeStart)
        try c.encodeIfPresent(loopRangeEnd,   forKey: .loopRangeEnd)
        try c.encode(kind, forKey: .kind)
    }

    init(from decoder: Decoder) throws {
        let c      = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decode(UUID.self,   forKey: .id)
        startTime  = try c.decode(Double.self, forKey: .startTime)
        duration   = try c.decode(Double.self, forKey: .duration)
        lane       = try c.decode(Int.self,    forKey: .lane)
        volume     = try c.decode(Float.self,  forKey: .volume)
        pan        = try c.decode(Float.self,  forKey: .pan)
        fadeIn     = try c.decodeIfPresent(Double.self, forKey: .fadeIn)  ?? 0.0
        fadeOut    = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0.0
        isMuted    = try c.decodeIfPresent(Bool.self,   forKey: .isMuted) ?? false
        stemID     = try c.decodeIfPresent(UUID.self,   forKey: .stemID)
        plugins    = try c.decodeIfPresent([ObjectPlugin].self, forKey: .plugins) ?? []
        instruments = try c.decodeIfPresent([ObjectPlugin].self, forKey: .instruments) ?? []
        label      = try c.decodeIfPresent(String.self, forKey: .label)
        colorIndex = try c.decodeIfPresent(Int.self,    forKey: .colorIndex)
        sends      = try c.decodeIfPresent([AuxSend].self, forKey: .sends) ?? []
        baseBPM    = try c.decodeIfPresent(Double.self, forKey: .baseBPM)
        definitionID = try c.decodeIfPresent(UUID.self, forKey: .definitionID)
        independentAttrs = try c.decodeIfPresent(ObjectAttrLinks.self, forKey: .independentAttrs) ?? []
        chainInGainDb  = try c.decodeIfPresent(Float.self, forKey: .chainInGainDb)  ?? 0
        chainOutGainDb = try c.decodeIfPresent(Float.self, forKey: .chainOutGainDb) ?? 0
        pianoRollOpen  = try c.decodeIfPresent(Bool.self, forKey: .pianoRollOpen) ?? false
        automation     = try c.decodeIfPresent([AutomationLane].self, forKey: .automation) ?? []
        automationOpen = try c.decodeIfPresent(Bool.self, forKey: .automationOpen) ?? false
        automationTouchOrder = try c.decodeIfPresent([ParamRef].self, forKey: .automationTouch) ?? []
        isInfinite     = try c.decodeIfPresent(Bool.self, forKey: .isInfinite) ?? false
        loopEnabled    = try c.decodeIfPresent(Bool.self, forKey: .loopEnabled) ?? false
        loopRangeStart = try c.decodeIfPresent(Double.self, forKey: .loopRangeStart)
        loopRangeEnd   = try c.decodeIfPresent(Double.self, forKey: .loopRangeEnd)
        kind       = try c.decode(Kind.self, forKey: .kind)
    }
}
