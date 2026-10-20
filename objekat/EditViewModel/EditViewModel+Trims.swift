import Foundation

// MARK: - Trims and gain match: a gain before a plugin, a gain after it
//
// Two numbers per plugin, `ObjectPlugin.inputTrimDb` / `outputTrimDb`, applied by the probe engine
// patch 0045 puts around the plugin (@see OBJPluginProbe.h): live and in a render, bypassed with
// the plugin, ramped over one block. The editor bar moves them two ways, and only those two:
//
//   • the COUPLED gesture — +n dB in, −n dB out: drive the plugin harder (or softer) without the
//     level that leaves it moving, which is what one wants from a saturation or a compressor;
//   • the GAIN MATCH — the output only, set so that what leaves the plugin (after its output trim)
//     is as loud, K-weighted, as what entered it (before its input trim), over the last seconds
//     PLAYED. The coupled gesture made afterwards adds to it.
//
// Not automatable. Carried like the rest of a plugin's identity: undo (patched, never a rebuild),
// the session file (format 29), a copy, a link (a gesture on a linked plugin moves every instance
// ACTIVELY linked to it, as a preset load does), a render.

extension EditViewModel {

    static let trimRangeDb: ClosedRange<Float> = -24...24

    /// How much playing the gain match reads, and how much of it must be above the gate.
    nonisolated static let gainMatchWindowSeconds: Double = 5
    static let gainMatchMinimumBlocks = 10          // 1 s of signal (sub-blocks of 100 ms)

    enum TrimError: Error, Equatable {
        case unknownPlugin
        case notPlaying
        /// Too little signal above the gate in the window read (`blocks` of the minimum).
        case notEnoughSignal(blocks: Int)
    }

    func pluginTrims(_ pluginID: UUID) -> (input: Float, output: Float)? {
        presetTarget(pluginID)?.plugin.trims
    }

    // MARK: Writing

    /// Sets both trims (clamped to ±24 dB) on the plugin and on every instance actively linked to
    /// it. `undo` false for the frames of a gesture that pushed its point at its start.
    func setPluginTrims(pluginID: UUID, input: Float, output: Float, undo: Bool = true) throws {
        guard let t = presetTarget(pluginID) else { throw TrimError.unknownPlugin }
        let i = Self.clampTrim(input), o = Self.clampTrim(output)
        if t.plugin.trims == (i, o) { return }
        if undo { pushUndo() }
        for target in [(t.hostID, t.plugin)] + activeLinkedInstances(of: pluginID) {
            writeTrims(i, o, on: target.1.id, host: chainHost(holding: target.1.id, on: target.0))
        }
        isDirty = true
    }

    /// The coupled gesture: +delta in, −delta out, the delta cut so that neither trim leaves ±24 dB.
    func nudgeCoupledTrims(pluginID: UUID, deltaDb: Float, undo: Bool = true) throws {
        guard let cur = pluginTrims(pluginID) else { throw TrimError.unknownPlugin }
        let t = Self.coupledTrims(from: cur, delta: deltaDb)
        try setPluginTrims(pluginID: pluginID, input: t.input, output: t.output, undo: undo)
    }

    /// `anchor` moved by the coupled gesture: +delta in, −delta out, the delta cut so that neither
    /// leaves ±24 dB. Pure: the bar's drag reads it from the anchor it froze at its start.
    static func coupledTrims(from anchor: (input: Float, output: Float), delta: Float) -> (input: Float, output: Float) {
        let r = trimRangeDb
        let d = min(max(delta, r.lowerBound - anchor.input, anchor.output - r.upperBound),
                    r.upperBound - anchor.input, anchor.output - r.lowerBound)
        return (anchor.input + d, anchor.output - d)
    }

    /// The gain match: the OUTPUT trim that makes the plugin's output as loud as its input over the
    /// last seconds played. Answers the trim laid. The input trim is left as it is.
    @discardableResult
    func gainMatch(pluginID: UUID) throws -> Float {
        guard let cur = pluginTrims(pluginID) else { throw TrimError.unknownPlugin }
        guard isTransportRunning else { throw TrimError.notPlaying }
        let r = engine?.pluginLoudnessReading(pluginID.uuidString, seconds: Self.gainMatchWindowSeconds)
        let blocks = r?["blocks"]?.intValue ?? 0
        guard blocks >= Self.gainMatchMinimumBlocks,
              let lin = r?["input_lufs"]?.doubleValue, let lout = r?["output_lufs"]?.doubleValue,
              lin.isFinite, lout.isFinite else { throw TrimError.notEnoughSignal(blocks: blocks) }
        let out = Self.clampTrim(Float(lin - lout))
        try setPluginTrims(pluginID: pluginID, input: cur.input, output: out)
        return out
    }

    /// The bar asks for the measurement while it is shown (it costs a K-weighting per block).
    func setGainMatchMeasuring(pluginID: UUID, _ on: Bool) {
        engine?.setPluginLoudnessMeasuring(pluginID.uuidString, enabled: on)
    }

    /// What the probe has read lately (`seconds` of it): nil when nothing was measured.
    func pluginLoudness(pluginID: UUID, seconds: Double = gainMatchWindowSeconds)
        -> (input: Double, output: Double, blocks: Int)? {
        guard let r = engine?.pluginLoudnessReading(pluginID.uuidString, seconds: seconds) else { return nil }
        return (r["input_lufs"]?.doubleValue ?? -.infinity, r["output_lufs"]?.doubleValue ?? -.infinity,
                r["blocks"]?.intValue ?? 0)
    }

    private static func clampTrim(_ v: Float) -> Float {
        let c = min(max(v, trimRangeDb.lowerBound), trimRangeDb.upperBound)
        return (c * 100).rounded() / 100          // a hundredth of a dB: no 1e-7 noise in the file
    }

    private func writeTrims(_ input: Float, _ output: Float, on pluginID: UUID, host: UUID) {
        let i: Float? = input == 0 ? nil : input
        let o: Float? = output == 0 ? nil : output
        func set(_ list: [ObjectPlugin]) -> [ObjectPlugin] {
            list.map { p in
                if p.id == pluginID { var q = p; q.inputTrimDb = i; q.outputTrimDb = o; return q }
                if p.isContainer { return p.mappingChildSeries { set($0) } }
                return p
            }
        }
        if isInstrument(pluginID, of: host) {
            update(id: host) { $0.instruments = set($0.instruments) }
        } else {
            _ = updateChainPlugins(host) { $0 = set($0) }
        }
        engine?.setPluginTrims(pluginID.uuidString, inputDb: Double(input), outputDb: Double(output))
    }

    // MARK: Engine

    /// Pushes every plugin's trims to the engine. Cheap (a map lookup per plugin, the engine keeps
    /// nothing for a plugin never trimmed), so it is laid where an instance can have been (re)made
    /// or the model rewound: the end of `rewireLinkGroups` and of `applySnapshot`.
    func syncAllPluginTrims() {
        guard let engine else { return }
        var all = allPluginRefs().map(\.plugin)
        for s in stems { all += Self.flattenLeaves(s.plugins) }
        for p in all {
            let t = p.trims
            engine.setPluginTrims(p.id.uuidString, inputDb: Double(t.input), outputDb: Double(t.output))
        }
    }
}
