import Foundation

// MARK: - Channel choice of a stereo clip (LR / L / R / C)
//
// A stereo clip can be heard through its left channel alone, its right alone, or their mono sum —
// on both sides, per clip, the file never touched. The model keeps it in `SoundObject.channelMode`
// (LR = the key absent from the session); the engine carries it as a small service plugin at the
// HEAD of the clip's chain (@see OBJChannelModePlugin.h), which exists only while the mode is not
// LR. Export and consolidation follow for free: they render the engine's graph.
//
// The eligibility rule is ONE function, `channelModeRefusal`, read by every door — the inspector
// (to show the selector at all), the API (to refuse) and the setter itself — so the three can
// never disagree about what a stereo clip is.

extension EditViewModel {

    /// Why `obj` cannot take a channel choice, or nil if it can. Written as a REASON and not a
    /// Bool because the API answers with it, and a refusal that does not say why is a refusal
    /// nobody can act on.
    ///
    /// - only a `.clip` has a file with channels;
    /// - a consolidated INSTANCE reads a wave that the app itself baked: its content is what it is,
    ///   and the choice belongs to the clips that were baked into it;
    /// - EXACTLY two channels: a mono file has no second channel to choose, and three or more are
    ///   not a pair (the waveform folds them into one lane for the same reason,
    ///   @see WaveformPeaks.laneCount).
    func channelModeRefusal(for obj: SoundObject) -> String? {
        guard case .clip(let path, _, _, _, _) = obj.kind else { return "not an audio clip" }
        if obj.isConsolidateInstance { return "a consolidated instance has no channel choice of its own" }
        guard let n = ClipChannels.count(atPath: path) else { return "the source file cannot be read" }
        if n != 2 { return "not a stereo clip (\(n) channel\(n == 1 ? "" : "s"))" }
        return nil
    }

    /// True if the selector applies to `obj`: a stereo audio clip.
    func canChooseChannelMode(_ obj: SoundObject) -> Bool { channelModeRefusal(for: obj) == nil }

    /// Sets the channel choice of every clip of `ids` that can take it, in ONE undo point, and
    /// returns the ones that actually changed. Nothing changed = no undo point.
    ///
    /// LR is always accepted on a clip that is not LR: a clip whose source was relinked onto a mono
    /// file must be able to come back to the default even though it can no longer take a choice.
    @discardableResult
    func setChannelMode(ids: [UUID], mode: ChannelMode) -> [UUID] {
        let changing = ids.filter { id in
            guard let o = find(id: id), o.isClip, o.channelMode != mode else { return false }
            return mode == .lr || channelModeRefusal(for: o) == nil
        }
        guard !changing.isEmpty else { return [] }
        pushUndo()
        for id in changing {
            update(id: id) { $0.channelMode = mode }
            engine?.updateChannelMode(mode.engineCode, forID: id.uuidString)
        }
        isDirty = true
        return changing
    }

    /// One clip. @see `setChannelMode(ids:mode:)`.
    @discardableResult
    func setChannelMode(id: UUID, mode: ChannelMode) -> Bool {
        !setChannelMode(ids: [id], mode: mode).isEmpty
    }

    /// What the ENGINE is playing for `id` (0 = LR, when it carries no plugin) — read back by the
    /// API so a script can assert the model and the engine agree.
    func engineChannelMode(for id: UUID) -> Int {
        Int(engine?.channelMode(forID: id.uuidString) ?? 0)
    }
}
