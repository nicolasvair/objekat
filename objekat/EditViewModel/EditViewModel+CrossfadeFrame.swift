import Foundation

// MARK: - One frame of a crossfade drag — worked out on COPIES, written once, on release
//
// A crossfade drag used to write the model on every frame: two trims, two fades, two curves per
// zone, six writes of `items` whose `didSet` rebuilds the lane entries in O(N) and drops five
// caches — and invalidates the whole `plainBlocksCanvas` and the sound list. That is the lag read
// on screen on 2 October 2026 ("it lags WHILE I drag a crossfade"), at 12–20 fps with 160 clips,
// where the crop and the plain fade (which only ever preview, and write on release) stayed fluid.
//
// It now does what they do. The frame is worked out — by the SAME arithmetic, line for line — on a
// gesture-private copy of the objects it touches (`CrossfadeShadow`); the timeline draws that copy
// through the existing preview path (`BlockPreviewGeometry`); the model is written ONCE, on release,
// behind ONE undo point. Nothing of `items` moves while the hand is down, so there is nothing to
// rebuild, and Esc / a cancelled gesture leaves no trace at all.
//
// WHY A COPY OF THE OBJECTS AND NOT A RECOMPUTATION FROM THE START. A frame is not a function of
// the zone as the hand found it alone: `openCrossfade` reads the CURRENT objects (the fades that
// the previous frames clamped, the source offsets they shifted by `delta × speed`, in floating
// point). Replaying the same sequence of operations on a copy is what keeps the final state byte
// for byte the one the live laying produced — `tools/canvas_nested_cases/c13_crossfade_drag_batch_api.py`
// checks it on random layouts against the live path, which stays here under `#if DEBUG` for that
// one purpose (`driveCrossfadeFrameLive`).

/// The zone a frame obtained: the two ids (in their roles) and its width — all the gesture reads of
/// the `CrossfadeZone` the model would have answered.
struct CrossfadeFrameZone {
    let leftID: UUID
    let rightID: UUID
    let width: Double
}

/// Where a frame lays its operations: the gesture's copies (`CrossfadeShadow`) — or, in a DEBUG
/// build and for the comparison only, the model itself. The frame's logic is written ONCE against
/// this, which is what makes "the copy and the model can never be two arithmetics" true by
/// construction rather than by discipline.
@MainActor
protocol CrossfadeFrameStore: AnyObject {
    func frameObject(_ id: UUID) -> SoundObject?
    func frameOpen(leftID: UUID, rightID: UUID, width: Double, idealStart: Double?,
                   pin: EditViewModel.ZonePin?)
        -> Result<CrossfadeFrameZone?, EditViewModel.SeamRefusal>
    func frameTrim(id: UUID, newStart: Double, newDuration: Double)
    func frameDuration(id: UUID, duration: Double)
    func frameFadeIn(id: UUID, fadeIn: Double)
    func frameFadeOut(id: UUID, fadeOut: Double)
    func frameCurve(id: UUID, fadeIn: FadeCurve?, fadeOut: FadeCurve?)
}

/// The objects of a crossfade drag, as the frames have left them — never written to the model until
/// the release (@see `EditViewModel.commitCrossfadeDrag`). A reference type on purpose: it is the
/// gesture's working memory, mutated in place frame after frame (a dictionary of a few hundred
/// objects copied on every frame, were it a value held by the `@State` struct, would be a cost for
/// nothing), and read by the timeline's preview helpers.
@MainActor
final class CrossfadeShadow: CrossfadeFrameStore {
    /// The objects as they now stand under the gesture, by id.
    private(set) var objects: [UUID: SoundObject] = [:]
    /// The ids, in the order they were taken (the zones' order, left then right): the order the
    /// release writes them in.
    private(set) var order: [UUID] = []
    /// The container each object sits in — `nil` = the top level. Fixed for the whole gesture: no
    /// frame re-parents anything, which is why it is read once.
    private let parents: [UUID: UUID]
    private let vm: EditViewModel

    init(vm: EditViewModel, ids: [UUID]) {
        self.vm = vm
        var parents: [UUID: UUID] = [:]
        for id in ids where objects[id] == nil {
            guard let o = vm.find(id: id) else { continue }
            objects[id] = o
            order.append(id)
            if let p = vm.parentGroup(for: id) { parents[id] = p.id }
        }
        self.parents = parents
    }

    // MARK: Reading

    func frameObject(_ id: UUID) -> SoundObject? { objects[id] }

    /// The crossfade these two form AS THE COPIES HOLD THEM — `EditViewModel.crossfadeZone(leftID:
    /// rightID:)`'s answer on the copies: nil when they no longer form one.
    func zone(_ a: UUID, _ b: UUID) -> CrossfadeFrameZone? {
        guard let x = objects[a], let y = objects[b], vm.isCrossfadePair(x, y) else { return nil }
        let (l, r) = x.startTime <= y.startTime ? (x, y) : (y, x)
        return CrossfadeFrameZone(leftID: l.id, rightID: r.id,
                                  width: (l.startTime + l.duration) - r.startTime)
    }

    // MARK: Writing — the copies' own

    func frameTrim(id: UUID, newStart: Double, newDuration: Double) {
        guard objects[id] != nil else { return }
        vm.applyTrim(to: &objects[id]!, newStart: newStart, newDuration: newDuration)
    }

    func frameDuration(id: UUID, duration: Double) {
        guard objects[id] != nil else { return }
        vm.applyDuration(to: &objects[id]!, duration: duration)
    }

    func frameFadeIn(id: UUID, fadeIn: Double) {
        guard objects[id] != nil else { return }
        vm.applyFadeIn(to: &objects[id]!, fadeIn: fadeIn)
    }

    func frameFadeOut(id: UUID, fadeOut: Double) {
        guard objects[id] != nil else { return }
        vm.applyFadeOut(to: &objects[id]!, fadeOut: fadeOut)
    }

    func frameCurve(id: UUID, fadeIn: FadeCurve?, fadeOut: FadeCurve?) {
        guard fadeIn != nil || fadeOut != nil, objects[id] != nil else { return }
        vm.applyFadeCurve(to: &objects[id]!, fadeIn: fadeIn, fadeOut: fadeOut)
    }

    /// `EditViewModel.openCrossfade`, on the copies: the same plan (`seamHem` / `plannedCrossfade`
    /// are the model's own, fed the copies), the same four operations in the same order.
    func frameOpen(leftID: UUID, rightID: UUID, width: Double, idealStart: Double?,
                   pin: EditViewModel.ZonePin?)
        -> Result<CrossfadeFrameZone?, EditViewModel.SeamRefusal> {
        guard let l = objects[leftID], let r = objects[rightID] else { return .failure(.notSiblings) }
        let hem: EditViewModel.SeamHem
        switch vm.seamHem(left: l, right: r, leftParent: parents[leftID], rightParent: parents[rightID]) {
        case .failure(let why): return .failure(why)
        case .success(let h):   hem = h
        }
        switch vm.plannedCrossfade(hem: hem, width: width, idealStart: idealStart, pin: pin) {
        case .failure(let why): return .failure(why)
        case .success(let plan):
            // The two edges travel, and nothing else does — then the fades LAST (@see openCrossfade).
            frameTrim(id: plan.rightID, newStart: plan.start, newDuration: plan.rightEnd - plan.start)
            frameTrim(id: plan.leftID, newStart: plan.leftStart,
                      newDuration: (plan.start + plan.width) - plan.leftStart)
            frameFadeOut(id: plan.leftID, fadeOut: plan.width)
            frameFadeIn(id: plan.rightID, fadeIn: plan.width)
            return .success(plan.width > EditViewModel.seamEpsilon
                            ? zone(plan.leftID, plan.rightID) : nil)
        }
    }
}

extension SoundObject {
    /// What a crossfade frame can change on an object — and nothing else: the window (start,
    /// length), the two fades and their shapes, what an edge move rebases (the automation and the
    /// markers, the clip's source offset, a MIDI clip's notes). Taken from the gesture's copy on
    /// release; everything else about the object stays what the model holds NOW.
    mutating func adoptCrossfadeGeometry(from o: SoundObject) {
        startTime = o.startTime
        duration = o.duration
        fadeIn = o.fadeIn
        fadeOut = o.fadeOut
        fadeInCurve = o.fadeInCurve
        fadeOutCurve = o.fadeOutCurve
        automation = o.automation
        markers = o.markers
        switch (kind, o.kind) {
        case (.clip, .clip), (.midiClip, .midiClip): kind = o.kind
        default: break   // a group's children (and an aux) are not touched by an edge move
        }
    }
}

extension EditViewModel {

    /// What one frame asks of one zone. Worked out for EVERY zone of the gesture before any of them
    /// is applied, because whether the hand has asked for something at all — and so whether the
    /// undo point is due — is a question about all of them.
    struct CrossfadeFrame {
        let rawWidth: Double
        let width: Double
        let idealStart: Double
        let pin: EditViewModel.ZonePin?
        /// Past the shut seam from the fade triangle: a plain fade on the held side.
        let spill: Double
        /// Past the shut seam from the crop band: the crop goes on.
        let overCrop: Double
        let moved: Bool
    }

    func crossfadeFrame(for t: CrossfadePairTrack, part: CrossfadeDragState.Part,
                                viaEdgeBand: Bool, shift: Double) -> CrossfadeFrame {
        // `rawWidth` may go NEGATIVE — that is the gesture asking for more than the zone has to
        // give, and what is past zero becomes a plain fade.
        let target = CrossfadeGrab.target(part: part, anchorStart: t.anchorStart,
                                          anchorEnd: t.anchorEnd, shift: shift)
        let width = max(0, target.rawWidth)
        // The OPPOSITE edge is PINNED, and the seam is TOLD so. Given only a width it gives what it
        // can and takes the rest out of whichever side still has it — right when one is opening a
        // seam, and quite wrong under a hand holding an edge: pushed past what the held side had
        // left, the zone went on growing BACKWARDS while the hand pulled forwards. Named, the pin
        // lowers the ceiling instead, and the gesture stops (@see ZonePin).
        let pin: EditViewModel.ZonePin?
        switch part {
        case .sideStart: pin = .end(t.anchorEnd)
        case .sideEnd:   pin = .start(t.anchorStart)
        case .move, .both: pin = nil
        }
        // Past the shut seam, the travel that is left is a PLAIN fade on the object whose edge the
        // hand holds. The two objects stay stuck together: a gesture that was making a crossfade
        // never opens a gap.
        //
        // Only from the FADE triangle. Taken by the crop band underneath, the same edge is being
        // CROPPED, and a crop grows no fade anywhere else in OBJEKAT — it goes on cropping, and it
        // opens the gap a crop opens (see `overCrop` below).
        let spill = (part == .move || viaEdgeBand) ? 0 : max(0, -target.rawWidth)
        let overCrop = viaEdgeBand ? max(0, -target.rawWidth) : 0
        let moved = abs(width - t.anchorWidth) > 1e-9 || spill > 0 || overCrop > 0
                 || abs(target.idealStart - t.anchorStart) > 1e-9
        return CrossfadeFrame(rawWidth: target.rawWidth, width: width, idealStart: target.idealStart,
                              pin: pin, spill: spill, overCrop: overCrop, moved: moved)
    }

    /// Lays one frame down on one zone, in `store`. Every zone gets the SAME travel
    /// (@see CrossfadeGrab.target) and the same bend, and keeps its own width, place and curves.
    func applyCrossfadeFrame(_ f: CrossfadeFrame, to t: inout CrossfadePairTrack,
                             state: CrossfadeDragState, store: some CrossfadeFrameStore) {
        // Coming back INTO the zone after a frame that cropped past the joint: the gap that
        // frame opened has to be closed again first, or the seam has nothing to open.
        if t.didOverCrop, f.overCrop == 0, let ha = t.heldAnchor {
            let held = state.part == .sideStart ? t.rightID : t.leftID
            store.frameTrim(id: held, newStart: ha.start, newDuration: ha.duration)
            t.didOverCrop = false
        }
        let result = store.frameOpen(leftID: t.leftID, rightID: t.rightID,
                                     width: f.width, idealStart: f.idealStart, pin: f.pin)
        // The width the HAND asked for, not the one the pinned edge allowed: the HUD's job is
        // to say that the gesture stopped and why, and a pre-clamped figure would agree with
        // itself for ever.
        t.requestedWidth = max(0, f.rawWidth)
        // A zone shut to nothing stops being a crossfade, so the ids would no longer resolve
        // to one: the gesture keeps its own two ids and can reopen the seam on the way back.
        if case .success(let zone) = result {
            t.obtainedWidth = zone?.width ?? 0
            if let zone {
                t.leftID = zone.leftID
                t.rightID = zone.rightID
            }
        }
        let curves = state.curves(for: t)
        store.frameCurve(id: t.leftID,  fadeIn: nil, fadeOut: curves.left)
        store.frameCurve(id: t.rightID, fadeIn: curves.right, fadeOut: nil)

        // The plain fade past the joint, on the held side only. Bounded by that object's own
        // length, which is the only stop a fade has ever had.
        //
        // ONLY once there IS something past the joint, and that guard is the whole of it: run
        // unconditionally, this wrote a fade of 0 over the one `openCrossfade` had just set
        // three lines above, and a crossfade IS the two fades being equal to the overlap
        // (@see isCrossfadePair) — so one side at 0 dissolved the pair on the first frame and
        // the two side gestures looked as though they turned the crossfade off. Nothing else
        // is needed on the way back either: `openCrossfade` sets both fades every frame, so
        // returning inside the zone restores them by itself.
        t.spilloverFade = f.spill
        if f.spill > 0 {
            if state.part == .sideStart, let o = store.frameObject(t.rightID) {
                store.frameFadeIn(id: o.id, fadeIn: min(f.spill, o.duration))
            } else if state.part == .sideEnd, let o = store.frameObject(t.leftID) {
                store.frameFadeOut(id: o.id, fadeOut: min(f.spill, o.duration))
            }
        }

        // Past the shut seam, from the CROP band: the crop simply carries on, and a crop that
        // carries on opens a gap. Stopping the edge dead at the joint was the band claiming a
        // limit no crop has ever had — the zone had ended, and what was left under the hand was
        // an ordinary edge that had every right to keep travelling. Bounded only by the object
        // keeping a length, which is a trim's own floor.
        if f.overCrop > 0 {
            t.didOverCrop = true
            let floor = 0.01
            if state.part == .sideStart, let o = store.frameObject(t.rightID) {
                let end = o.startTime + o.duration
                let newStart = min(t.anchorEnd + f.overCrop, end - floor)
                store.frameTrim(id: o.id, newStart: newStart, newDuration: end - newStart)
            } else if state.part == .sideEnd, let o = store.frameObject(t.leftID) {
                let newEnd = max(t.anchorStart - f.overCrop, o.startTime + floor)
                store.frameDuration(id: o.id, duration: newEnd - o.startTime)
            }
        }
    }

    /// The first frame that asks for something, for the undo point and the "did anything change"
    /// flag: worked out for ALL zones first.
    private func crossfadeFrames(_ state: CrossfadeDragState, shift: Double) -> [CrossfadeFrame] {
        state.tracks.map {
            crossfadeFrame(for: $0, part: state.part, viaEdgeBand: state.viaEdgeBand, shift: shift)
        }
    }

    /// One frame of the gesture, every zone: worked out for ALL of them first, then laid down on the
    /// gesture's COPIES of the objects (`state.shadow`, taken from the model on the first frame).
    /// The model is not touched — nor is the engine, nor the undo stack: a gesture that asks for
    /// nothing leaves no trace, and one that is abandoned leaves none either. What the hand has made
    /// is written by `commitCrossfadeDrag`, once, on release.
    func driveCrossfadeFrame(_ state: inout CrossfadeDragState, shift: Double) {
        let frames = crossfadeFrames(state, shift: shift)
        if (frames.contains { $0.moved } || state.overshootY != 0), !state.didChange {
            // The first frame that actually asks for something. (The undo point is pushed on
            // release, BEFORE the first write of the model — the convention — and only if this
            // happened.)
            state.didChange = true
        }
        guard state.didChange else { return }

        let shadow: CrossfadeShadow
        if let existing = state.shadow { shadow = existing } else {
            // Taken now, on the first frame that needs it: the model has not been touched since the
            // hand came down, so these are the objects the gesture found.
            shadow = CrossfadeShadow(vm: self, ids: state.tracks.flatMap { [$0.leftID, $0.rightID] })
            state.shadow = shadow
        }
        for i in state.tracks.indices {
            var t = state.tracks[i]
            applyCrossfadeFrame(frames[i], to: &t, state: state, store: shadow)
            state.tracks[i] = t
        }
    }

    /// The release of a crossfade drag: ONE undo point (pushed BEFORE the first write, as the
    /// convention has it) and ONE write of the model, in one batch — the result of the last frame,
    /// object by object. A gesture that never asked for anything leaves no trace, not even an empty
    /// undo step.
    ///
    /// The engine is brought up to date here and nowhere else: what the old per-frame laying left in
    /// it at the end of the gesture is a function of the final objects alone (position, source
    /// offset, the two fades and their shapes, the automation, a MIDI clip's notes), and that is
    /// what is pushed — the very calls `updateTrim` / `updateFade…` end with.
    func commitCrossfadeDrag(_ state: CrossfadeDragState) {
        guard state.didChange, let shadow = state.shadow else { return }
        pushUndo()
        batchItemsMutation {
            for id in shadow.order {
                guard let copy = shadow.objects[id] else { continue }
                update(id: id) { $0.adoptCrossfadeGeometry(from: copy) }
            }
        }
        for id in shadow.order {
            guard let o = find(id: id) else { continue }
            syncPosition(o)
            if o.isClip || o.isMIDI {   // the same ObjWindowFade chain on the engine side
                engine?.updateFade(in: o.fadeIn, fadeOut: o.fadeOut, forID: id.uuidString)
            }
            if o.isMIDI { syncMidiNotes(o) }
        }
        isDirty = true
    }

    #if DEBUG
    /// The model as a frame store: every operation is the one the live laying always made (the
    /// `update…` doors, which write `items` and push the engine). DEBUG only, and only so that
    /// `debug.crossfade_drag` can still lay a drag down the way it was laid before — the reference
    /// the equivalence test compares the copies' result with.
    @MainActor
    private final class ModelFrameStore: CrossfadeFrameStore {
        let vm: EditViewModel
        init(_ vm: EditViewModel) { self.vm = vm }
        func frameObject(_ id: UUID) -> SoundObject? { vm.find(id: id) }
        func frameOpen(leftID: UUID, rightID: UUID, width: Double, idealStart: Double?,
                       pin: EditViewModel.ZonePin?)
            -> Result<CrossfadeFrameZone?, EditViewModel.SeamRefusal> {
            switch vm.openCrossfade(leftID: leftID, rightID: rightID, width: width,
                                    idealStart: idealStart, pin: pin) {
            case .failure(let why): return .failure(why)
            case .success(let z):
                return .success(z.map { CrossfadeFrameZone(leftID: $0.leftID, rightID: $0.rightID,
                                                           width: $0.width) })
            }
        }
        func frameTrim(id: UUID, newStart: Double, newDuration: Double) {
            vm.updateTrim(id: id, newStart: newStart, newDuration: newDuration)
        }
        func frameDuration(id: UUID, duration: Double) { vm.updateDuration(id: id, duration: duration) }
        func frameFadeIn(id: UUID, fadeIn: Double) { vm.updateFadeIn(id: id, fadeIn: fadeIn) }
        func frameFadeOut(id: UUID, fadeOut: Double) { vm.updateFadeOut(id: id, fadeOut: fadeOut) }
        func frameCurve(id: UUID, fadeIn: FadeCurve?, fadeOut: FadeCurve?) {
            vm.updateFadeCurve(id: id, fadeIn: fadeIn, fadeOut: fadeOut)
        }
    }

    /// The frame as it was laid before the copies: on the MODEL, the undo point pushed on the first
    /// frame that asks for anything, every write live — in ONE batch (`batched`) or one at a time.
    /// Kept for `debug.crossfade_drag { legacy: true }`, i.e. for the equivalence test.
    func driveCrossfadeFrameLive(_ state: inout CrossfadeDragState, shift: Double, batched: Bool = true) {
        let frames = crossfadeFrames(state, shift: shift)
        if (frames.contains { $0.moved } || state.overshootY != 0), !state.didChange {
            pushUndo()
            state.didChange = true
        }
        guard state.didChange else { return }
        let store = ModelFrameStore(self)
        func layDown() {
            for i in state.tracks.indices {
                var t = state.tracks[i]
                applyCrossfadeFrame(frames[i], to: &t, state: state, store: store)
                state.tracks[i] = t
            }
        }
        if batched { batchItemsMutation { layDown() } } else { layDown() }
    }
    #endif
}
