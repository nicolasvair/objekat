import Foundation
import SwiftUI

// MARK: - Project document

struct ProjectDocument: Codable {
    /// The format notice, written at the head of the file. Under the `_readme` key: the keys are
    /// sorted on encoding and '_' comes before every lowercase letter, so it places itself FIRST —
    /// a reader (human or model) meets it before anything else. Optional on decoding: a file that
    /// hasn't got it reads as before. See `SessionSchema`.
    var schemaNote: [String]? = nil
    /// Derived from `SessionSchema`: bumping the format forces you to open the file that carries
    /// the notice, and therefore to see the text you are making obsolete.
    var version: Int = SessionSchema.formatVersion
    var items: [SoundObject]
    var stems: [Stem]?
    var tempo: Double?
    var timeSigNumerator: Int?
    var timeSigDenominator: Int?
    var gridMode: GridMode?
    /// The registry of the sound objects referenced by `SoundObject.definitionID` in
    /// `items`. nil/absent ⇒ none.
    var objectDefinitions: [ObjectDefinition]?
    /// The state of the timeline view at the time of saving (H zoom = px/s, V zoom = block
    /// height, scroll position). All optional: an earlier project leaves them at nil and the
    /// view keeps its default values. See `ViewportState`.
    var viewport: ViewportState?

    enum CodingKeys: String, CodingKey {
        case schemaNote = "_readme"
        case version, items, stems, tempo, timeSigNumerator, timeSigDenominator
        case gridMode, objectDefinitions, viewport
    }

    init(items: [SoundObject], stems: [Stem]?,
         tempo: Double? = nil,
         timeSigNumerator: Int? = nil,
         timeSigDenominator: Int? = nil,
         gridMode: GridMode? = nil,
         objectDefinitions: [ObjectDefinition]? = nil,
         viewport: ViewportState? = nil) {
        self.schemaNote = SessionSchema.note
        self.items = items
        self.stems = stems
        self.tempo = tempo
        self.timeSigNumerator = timeSigNumerator
        self.timeSigDenominator = timeSigDenominator
        self.gridMode = gridMode
        self.objectDefinitions = objectDefinitions
        self.viewport = viewport
    }
}

/// The timeline's zoom and visible area, saved with the project: reopening a project finds it
/// framed as it was left. Purely visual (no effect on the audio render) — changing it therefore
/// does not mark the project "modified".
struct ViewportState: Codable, Equatable {
    var pixelsPerSecond: Double
    var blockHeight: Double
    var scrollX: Double
    var scrollY: Double
}

// MARK: - Snapshot for undo/redo

struct EditSnapshot {
    let items: [SoundObject]
    // INC 2: a bus's FX chain lives on Stem.plugins → included in the undo. Optional = the
    // snapshots from before this field (none in practice, in-memory) restore the current stems.
    var stems: [Stem]? = nil
    // The sound-object registry: without it, undoing the creation of a sound object, a
    // closing (with the revision bumped) or a volume/pan/mute propagation left the registry
    // out of step with the restored instances.
    var objectDefinitions: [UUID: ObjectDefinition]? = nil
    // Tempo / time signature: without them, undoing a tempo change in BPM mode restored the
    // positions from BEFORE the remap while leaving the new tempo — model and grid out of tune.
    var tempo: Double? = nil
    var timeSigNumerator: Int? = nil
    var timeSigDenominator: Int? = nil
}

// MARK: - Common types

enum ActiveTool: Equatable {
    case toolSelection
    case toolCut
    case toolVolume
    case toolPan
    /// The "Aux" tool: sets an object's send levels towards the aux buses.
    /// (Formerly "Send" — renamed to lift the ambiguity with the notion of a send.)
    case toolAux
    /// Assigning a stem "on the fly": the target stem is carried by `stemAssignIndex`.
    /// Armed by holding a digit (held) or with ⇧ (locked), like the other tools.
    case toolStemAssign
}

// MARK: - The Send tool

/// The send currently "brought forward" by the Send tool (a drag or a knob hover):
/// its knob and its line towards the aux are accented (bright red + glow).
struct SendFocus: Equatable {
    let objectID: UUID
    let auxID: UUID
}

/// The data of one send-knob row (one aux), for the overlay on the clip.
/// The rows are ordered by the aux's lane (top → bottom).
struct SendRow: Identifiable {
    let auxID: UUID
    let label: String
    let level: Float       // dB; -∞ = sendMinDb
    let enabled: Bool
    let focused: Bool
    var id: UUID { auxID }
}

enum GridMode: String, CaseIterable, Codable {
    case time = "Time"
    case bpm  = "BPM"
}

let bpmGridThresholdPx: Double = 24.0
/// The minimum spacing of a MAJOR level: a more marked line, and the one that carries the
/// ruler's labels. Twice the normal threshold → the labels never touch.
let gridMajorThresholdPx: Double = 48.0
/// The minimum spacing of a GHOST marker: the individual bars when the anchor has
/// moved on to a multiple (4, 8, 16…). Deliberately lower than the normal threshold — just
/// enough to stay legible, so that the density does not jump by a factor of 4 at a change of
/// step (the bar fades out gradually instead of vanishing all at once).
let barGhostThresholdPx: Double = 10.0

struct GridLevel {
    enum Kind {
        case bar, halfBar, beat, halfBeat, quarterBeat
        /// A group of bars (4, 8, 16…): the marker that takes over from the bar when zooming out.
        case barGroup
        case major, fine
    }
    let interval: Double
    let opacity: Double
    let kind: Kind
}

/// The scale of the musical markers FROM the bar upwards: 1, then phrase lengths
/// (4, 8, 16, 32, 64 bars). Without it the bar stayed the widest marker whatever the
/// zoom: zoomed out, a line every 2 px instead of an adaptive grid.
/// The musical counterpart of `TimeLadder`.
enum BarLadder {
    static let multiples: [Double] = [1, 4, 8, 16, 32, 64]

    /// The smallest multiple whose spacing reaches `minPx`. Past the last step we
    /// keep 64 bars: a wide grid is better than falling back to the bar, which would
    /// hatch the screen (that was exactly the bug).
    static func anchor(barWidthPx: Double, minPx: Double) -> Double {
        multiples.first { $0 * barWidthPx >= minPx } ?? multiples.last!
    }
}

/// The scale of the time grid's intervals (in seconds). The SINGLE source: the canvas's grid,
/// the snap and the ruler's graduations all draw on it — otherwise the three diverge.
enum TimeLadder {
    static let intervals: [Double] = [0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 30, 60,
                                      120, 300, 600, 1800, 3600]

    /// The smallest interval whose spacing reaches `minPx`. The last step serves as a
    /// floor — never a fallback onto a fixed value, which would tighten the grid when zooming out.
    static func interval(pixelsPerSecond pps: Double, minPx: Double) -> Double {
        intervals.first { $0 * pps >= minPx } ?? intervals.last!
    }
}

// MARK: - Time selection

struct TimeSelection: Equatable {
    var timeRange: ClosedRange<Double>
    var lanes: Set<Int>
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - A flat list of display positions

struct LaneEntry: Identifiable {
    var id: UUID { item.id }
    let displayLane: Int
    let item:        SoundObject
    let absStart:    Double
    let depth:       Int
    let parentID:    UUID?
}
