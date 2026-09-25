import Foundation
import AVFoundation
import Accelerate
import Observation

// A mipmap of audio peaks at several resolutions, defined in peaks per second
// (and not in peaks per file) so that the visual detail stays constant whatever
// the file's length. Rendering picks the coarsest level whose density exceeds
// the current pixelsPerSecond.

@MainActor
@Observable
final class WaveformCache {

    // Target densities (peaks per second of file), from coarse to fine.
    // A ×10 log scale: covers browsing → editing → close zoom.
    // The finest level (10 000/s) is GONE: it weighed 90% of a mipmap to cover a zoom band
    // (3 000-30 000 px/s) the samples mode — PCM read straight off disk, costing nothing to
    // store — already served, and which was almost never the one actually open (@see
    // PLAN-WAVEFORM.md, section C1b). `sampleModeThreshold` and `loadFromDisk`'s own comparison
    // against `effectiveDensitiesPerSecond` follow this array with no other change required
    // (@see C1b0, the prerequisite that keeps the samples mode correct at the lower threshold
    // this now opens at). REPLI documented if the eye refuses it: `[100, 1000, 3000]` (threshold
    // 9 000 px/s), the same array shape — a partial revert, not a redesign.
    nonisolated static let baseDensitiesPerSecond: [Double] = [100, 1000]

    // Global detail multiplier. 1.0 = the default densities.
    // 0.5 → half as many peaks (lighter on memory), 2.0 → twice as fine.
    nonisolated(unsafe) static var finenessMultiplier: Double = 1.0

    nonisolated static var effectiveDensitiesPerSecond: [Double] {
        baseDensitiesPerSecond.map { $0 * finenessMultiplier }
    }

    /// Above this many pixels per second, a pixel covers FEWER samples than a peak block does —
    /// the finest mipmap level starts under-resolving, and `WaveformDrawing` switches to reading
    /// decoded samples directly. One definition, read by both drawing paths
    /// (`WaveformDrawing.swift`) and by `perf.waveforms`: two copies of a threshold is two
    /// thresholds the day one of them drifts.
    nonisolated static var sampleModeThreshold: Double {
        (effectiveDensitiesPerSecond.last ?? 10000) * 3
    }

    // `PeakPair` moved to `WaveformPeaks.swift`: a plain value type with no model behind it,
    // compiled and asserted standalone (`tools/test_waveform_peaks.swift`).

    struct Entry {
        /// One `PeakLanes` per level: `peaks[level][lane][block]`. Every level has the same number
        /// of lanes — one, or two for a stereo source (@see `WaveformPeaks.laneCount`).
        var peaks: [PeakLanes]
        var densities: [Double]      // the effective peaks/second of each level (a snapshot at build time)
        var duration: Double
        var sampleRate: Double

        /// How many stacked waveforms this file is drawn in. `nonisolated`: read by the detached
        /// load and by the `.wfc` writer, both off the main actor by design.
        nonisolated var laneCount: Int { max(1, peaks.first?.count ?? 1) }
    }

    // A region of samples decoded on demand (deep zoom), ONE ARRAY PER LANE, in step with the
    // peaks: a stereo file's two channels as they are, anything else in a single lane holding,
    // per sample, the value of the channel with the LARGEST MAGNITUDE, sign kept (@see
    // decodeRegion — not a mono mixdown, which a pair in phase opposition can silence outright).
    // We NEVER keep the whole PCM in RAM: only a small window around the view,
    // evicted when zooming out or looking at another file.
    struct SampleRegion {
        var startTime: Double        // file time (s) of the 1st sample of each lane
        var endTime: Double          // file time (s) covered (exclusive)
        var lanes: [[Float]]         // one array per lane, all the same length
        var sampleRate: Double
        /// Index into a lane for a given file time (may fall outside the bounds).
        func index(forFileTime t: Double) -> Int { Int((t - startTime) * sampleRate) }
        /// What the region holds in RAM — the unit `regionByteCap` is counted in. A stereo region
        /// weighs twice a mono one of the same span, and the cap is deliberately NOT doubled with
        /// it: it is a memory bound, so a viewport full of stereo files simply keeps half the
        /// seconds resident (the need measured at 40 lanes and 10 000 px/s, before lanes existed,
        /// was 15 MB against 48 — still inside the cap at twice that).
        var byteCount: Int { lanes.reduce(0) { $0 + $1.count } * MemoryLayout<Float>.stride }
    }

    private var cache: [String: Entry] = [:]

    /// Coarser levels DERIVED in memory from the coarsest stored one (10/s and 1/s out of 100/s),
    /// never written: the `.wfc` format and `loadFromDisk`'s density check stay exactly as they
    /// are. They exist because the drawing takes the UNION of every block a pixel covers (@see
    /// `WaveformPeaks.peakEnvelope`) — at 1 px/s the 100/s level is 100 blocks per pixel per lane
    /// per frame, where point sampling used to read one. A tenth of a level's weight, computed
    /// once per file. Ordered coarse → fine, like `Entry.densities`.
    private var overviewLevels: [String: [(density: Double, peaks: PeakLanes)]] = [:]

    /// The one door onto `cache`: the overview levels follow every entry stored.
    private func store(_ entry: Entry, for filePath: String) {
        cache[filePath] = entry
        overviewLevels[filePath] = Self.overviews(of: entry)
    }

    private nonisolated static func overviews(of entry: Entry) -> [(density: Double, peaks: PeakLanes)] {
        guard let base = entry.peaks.first, let lane0 = base.first, !lane0.isEmpty,
              let d0 = entry.densities.first, d0 > 0 else { return [] }
        return [100, 10].compactMap { ratio -> (density: Double, peaks: PeakLanes)? in
            guard lane0.count / ratio >= 2 else { return nil }
            // Each lane folded on its own: the lanes share one block grid, so they stay in step.
            return (d0 / Double(ratio), base.map { WaveformPeaks.decimate($0, ratio: ratio) })
        }
    }
    private var inFlight: Set<String> = []

    /// A decoded region's key. Keying on the PATH alone was enough while the samples mode only
    /// opened past 30 000 px/s: the viewport then held 0.05 s of timeline, so two windows of one
    /// file could not both be on screen. At 3 000 px/s (@see C1b) they can — a chopped take laid
    /// twice at distant source offsets — and one region per path made them evict each other on
    /// EVERY frame, each redecoding what the other had just replaced.
    private struct RegionKey: Hashable { let path: String; let slot: Int }
    /// File seconds per slot — the unit `RegionKey.slot` buckets a request into.
    private static let regionSlotSpan: Double = 2.0
    private static func slot(for fileTime: Double) -> Int { Int((fileTime / regionSlotSpan).rounded(.down)) }

    // An LRU cache of sample regions.
    private var sampleRegions: [RegionKey: SampleRegion] = [:]
    private var regionRecency: [RegionKey] = []          // most recent at the head
    private var regionInFlight: [RegionKey: ClosedRange<Double>] = [:]  // the target currently being decoded
    /// Capped in BYTES and not in count: the regions no longer have one size (@see
    /// `regionMinSpan`), so a fixed count is either too tight at the floor or too loose at the
    /// ceiling. 48 MB ≈ 250 s of mono float32 at 48 kHz — enough for every file a tall viewport
    /// can show at once, at the widest span this cache ever decodes.
    private static let regionByteCap = 48 << 20
    private var regionBytesTotal = 0

    /// Wider windows in the middle band: near the samples-mode threshold the viewport shows
    /// about half a second of file (@see PLAN-WAVEFORM.md section A3 — `viewportWidth /
    /// pixelsPerSecond` at 3 000 px/s), and a 2 s region is spent after one second of scrolling —
    /// this widens it there, so a few scroll-widths land inside one region instead of one. Deep
    /// in the zoom `requestSpan` itself shrinks towards a fraction of a millisecond — a region is
    /// aimed at a POINT there, not a passage, so the 2 s floor already outlives minutes of real
    /// scrolling. The ceiling exists so a long LOOP's own period (which `requestSpan` can equal,
    /// @see `WaveformDrawing.draw`'s `winStart`/`winEnd` under a loop) cannot inflate one region
    /// past a sane share of `regionByteCap` on its own.
    private static func regionMinSpan(requestSpan: Double) -> Double {
        min(max(2.0, requestSpan * 8), 6.0)
    }

    // The project's `waveforms/` folder, where the `.wfc` caches are written and read back.
    // nil while the project is unsaved → computed in memory only. `private(set)`: the only door
    // onto it is `setWaveformsDirectory`, which is what flushes the peaks already computed —
    // an ordinary assignment here would skip that flush entirely.
    private(set) var waveformsDirectory: URL?

    /// Says whether the CURRENT project names this file. The cache must not know what a project
    /// is, and the view model must not know what a `.wfc` is — so the rule crosses as a closure,
    /// exactly as the zoom does (@see `EditViewModel.applyHorizontalZoom`). nil (nothing wired
    /// yet) reads as "names nothing", which is the safe answer: nothing is written until this is
    /// set.
    var referencedPaths: (() -> Set<String>)?

    /// Points the disk cache at a project's waveforms/ folder. Becoming non-nil flushes the
    /// peaks already computed — which is why this exists at all: a file dropped into a project
    /// that has never been saved has its peaks computed with nowhere to put them, and losing
    /// them on the first Save As would mean recomputing a whole session's work.
    /// What it no longer does is flush the WHOLE cache. The memory cache is shared between
    /// projects on purpose (reopening a file already seen is instant, and that is a benefit), so
    /// the snapshot it held at a Save As was largely somebody ELSE'S project — and every one of
    /// those `.wfc` used to land in the folder that was becoming current regardless. Measured: a
    /// new project with ZERO objects, saved into a virgin folder, received a 92 MB `.wfc` of a
    /// file it had never heard of. Filtered through `referencedPaths` now: only an entry the
    /// INCOMING project actually names is written.
    func setWaveformsDirectory(_ dir: URL?) {
        guard dir != waveformsDirectory else { return }
        waveformsDirectory = dir
        guard let dir else { return }
        let referenced = referencedPaths?() ?? []
        let snapshot = cache
        // Deliberately `.utility`, unlike `load`'s own task: nobody is waiting on this
        // write, a Save As having already returned before it finishes. Real background work.
        Task.detached(priority: .utility) {
            for (path, entry) in snapshot where referenced.contains(path) && Self.isUsable(entry) {
                Self.writeToDisk(entry, path: path, dir: dir)
            }
        }
    }

    /// The folder this path's `.wfc` may be written into: the current project's, and only while
    /// the current project still names that file. nil = keep it in memory only. ONE rule, read
    /// by the flush above and by `load`'s own write — a second copy of "does this project name
    /// this file?" is a second copy that can say something different.
    private func writeTarget(for filePath: String) -> URL? {
        guard let dir = waveformsDirectory, referencedPaths?().contains(filePath) == true else { return nil }
        return dir
    }

    // Returns the peaks of the level best suited to the current zoom, one array per lane.
    // pixelsPerSecond: pixels shown per second on screen.
    func peaks(for filePath: String, pixelsPerSecond: Double) -> PeakLanes? {
        guard let entry = cache[filePath], entry.duration > 0 else { return nil }
        // Zoomed far out: a derived overview level (@see `overviewLevels`).
        if let overviews = overviewLevels[filePath] {
            for level in overviews where level.density >= pixelsPerSecond { return level.peaks }
        }
        // The first level whose density (peaks/sec) covers the requested PPS
        for (i, density) in entry.densities.enumerated() {
            if density >= pixelsPerSecond || i == entry.densities.count - 1 {
                return entry.peaks[i]
            }
        }
        return entry.peaks.last
    }

    func duration(for filePath: String) -> Double? { cache[filePath]?.duration }
    func sampleRate(for filePath: String) -> Double? { cache[filePath]?.sampleRate }
    /// How many stacked waveforms this file is drawn in — 1 while it is not analysed yet, so
    /// nothing splits a block before there is anything to put in a second lane.
    func laneCount(for filePath: String) -> Int { cache[filePath]?.laneCount ?? 1 }

    /// The region of samples covering [fileStart, fileEnd] if it is already decoded.
    /// Otherwise starts the windowed decode in the background and returns nil
    /// (rendering falls back on the peaks until the region is ready).
    func samplesRegion(for filePath: String, fileStart: Double, fileEnd: Double) -> SampleRegion? {
        guard let duration = cache[filePath]?.duration, duration > 0 else { return nil }
        // A PURELY read-only synchronous path (called while the Canvas renders):
        // a hit returns the region, a miss schedules the decode without mutating state here.
        if let region = existingRegion(filePath, fileStart: fileStart, fileEnd: fileEnd) {
            return region
        }
        requestRegion(filePath, fileStart: fileStart, fileEnd: fileEnd, duration: duration)
        return nil
    }

    /// Looks at the request's own slot AND ITS TWO NEIGHBOURS: a request straddling a slot
    /// boundary may have been decoded under the slot next door, its widened window having
    /// started (or ended) on the other side of the line (@see `RegionKey`).
    private func existingRegion(_ filePath: String, fileStart: Double, fileEnd: Double) -> SampleRegion? {
        let centerSlot = Self.slot(for: fileStart)
        for s in (centerSlot - 1)...(centerSlot + 1) {
            if let region = sampleRegions[RegionKey(path: filePath, slot: s)],
               region.startTime <= fileStart, region.endTime >= fileEnd {
                return region
            }
        }
        return nil
    }

    private func inFlightCovers(_ filePath: String, fileStart: Double, fileEnd: Double) -> Bool {
        let centerSlot = Self.slot(for: fileStart)
        for s in (centerSlot - 1)...(centerSlot + 1) {
            if let t = regionInFlight[RegionKey(path: filePath, slot: s)],
               t.contains(fileStart), t.contains(fileEnd) {
                return true
            }
        }
        return false
    }

    /// Schedules (outside the view update) the windowed decode of a missing region.
    private func requestRegion(_ filePath: String, fileStart: Double, fileEnd: Double, duration: Double) {
        Task { @MainActor in
            // De-duplication: the region may have arrived, or a decode may already cover it.
            if existingRegion(filePath, fileStart: fileStart, fileEnd: fileEnd) != nil { return }
            if inFlightCovers(filePath, fileStart: fileStart, fileEnd: fileEnd) { return }
            guard let sr = cache[filePath]?.sampleRate, sr > 0 else { return }

            // The target: the requested window widened (≥ regionMinSpan), bounded by the file.
            let requestKey = RegionKey(path: filePath, slot: Self.slot(for: fileStart))
            let span = Self.regionMinSpan(requestSpan: fileEnd - fileStart)
            let center = (fileStart + fileEnd) * 0.5
            let half = max((fileEnd - fileStart) * 1.5, span * 0.5)
            let lo = max(0, center - half)
            let hi = min(duration, center + half)
            regionInFlight[requestKey] = lo...hi

            let decodeStart = CFAbsoluteTimeGetCurrent()
            let region = await Task.detached(priority: .userInitiated) {
                Self.decodeRegion(path: filePath, startTime: lo, endTime: hi, sampleRate: sr)
            }.value

            regionInFlight[requestKey] = nil
            guard let region else { return }
            let bytes = region.byteCount
            WaveformCacheMeter.record { stats in
                stats.regionsDecoded += 1
                stats.regionDecodeSeconds += CFAbsoluteTimeGetCurrent() - decodeStart
                stats.regionBytesInMemory += bytes
            }
            // Keyed by where the DECODED region actually starts, not the request: widening can
            // pull `lo` back into the slot before the one the request itself fell in.
            let storeKey = RegionKey(path: filePath, slot: Self.slot(for: region.startTime))
            // A key ALREADY HOLDING a region is the ordinary case, not the exception: a region is
            // about as wide as the slot it is filed under, so two requests a scroll apart land in
            // the same slot and the second replaces the first. That replacement frees the first
            // one's memory — and the byte count has to hear about it. Left out, `regionBytesTotal`
            // only ever grows, crosses `regionByteCap` on memory nothing is holding, and from then
            // on `evictRegionsIfNeeded` throws away every region it is handed, including the one
            // just decoded: a self-feeding loop whose signature is an eviction for every decode
            // (measured before this line existed: 18 705 of each at 10 000 px/s, where the regions
            // actually resident came to 15 MB against a 48 MB cap).
            if let replaced = sampleRegions[storeKey] {
                let freed = replaced.byteCount
                regionBytesTotal -= freed
                WaveformCacheMeter.record { $0.regionBytesInMemory -= freed }
            }
            sampleRegions[storeKey] = region
            regionBytesTotal += bytes
            regionRecency.removeAll { $0 == storeKey }
            regionRecency.insert(storeKey, at: 0)
            evictRegionsIfNeeded()
        }
    }

    private func evictRegionsIfNeeded() {
        while regionBytesTotal > Self.regionByteCap, let victim = regionRecency.popLast() {
            if let region = sampleRegions[victim] {
                let bytes = region.byteCount
                WaveformCacheMeter.record { stats in
                    stats.regionsEvicted += 1
                    stats.regionBytesInMemory -= bytes
                }
                regionBytesTotal -= bytes
            }
            sampleRegions[victim] = nil
        }
    }

    /// Decodes ONLY the [startTime, endTime] window of the file, one array per lane.
    private nonisolated static func decodeRegion(path: String, startTime: Double,
                                                 endTime: Double, sampleRate sr: Double) -> SampleRegion? {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let total = file.length
        let startFrame = max(0, AVAudioFramePosition(startTime * format.sampleRate))
        let endFrame = min(total, AVAudioFramePosition(endTime * format.sampleRate))
        let frames = AVAudioFrameCount(max(0, endFrame - startFrame))
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        file.framePosition = startFrame
        // `processingFormat` is always non-interleaved float32: `floatChannelData[c]` is its own
        // pointer, stride 1 — never assume interleaving on an AVAudioPCMBuffer.
        guard (try? file.read(into: buffer, frameCount: frames)) != nil,
              let channels = buffer.floatChannelData
        else { return nil }
        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { return nil }
        let n = Int(buffer.frameLength)
        let laneCount = WaveformPeaks.laneCount(channelCount: channelCount)
        var lanes: [[Float]] = []
        lanes.reserveCapacity(laneCount)
        if laneCount == channelCount {
            // One lane per channel (mono, stereo): each channel as it is — the same split the
            // peaks were computed with (@see decodeChunked), so the two paths agree either side
            // of the samples-mode threshold, lane by lane.
            for c in 0..<channelCount {
                lanes.append(Array(UnsafeBufferPointer(start: channels[c], count: n)))
            }
        } else {
            // Several channels in ONE lane (@see `WaveformPeaks.laneCount` for why): the channel
            // of LARGEST MAGNITUDE speaks for each sample, SIGN KEPT — a max would rectify the
            // shape. Its min/max per pixel is exactly the union `decodeChunked` folds into that
            // same single lane for the peaks levels.
            var samples = [Float](repeating: 0, count: n)
            for i in 0..<n {
                var best = channels[0][i]
                var bestMag = abs(best)
                for c in 1..<channelCount {
                    let v = channels[c][i]
                    let mag = abs(v)
                    if mag > bestMag { best = v; bestMag = mag }
                }
                samples[i] = best
            }
            lanes.append(samples)
        }
        return SampleRegion(startTime: Double(startFrame) / format.sampleRate,
                            endTime: Double(startFrame + AVAudioFramePosition(n)) / format.sampleRate,
                            lanes: lanes, sampleRate: format.sampleRate)
    }

    func load(filePath: String) {
        guard !inFlight.contains(filePath), cache[filePath] == nil else { return }
        inFlight.insert(filePath)
        let dir = waveformsDirectory
        WaveformCacheMeter.record { stats in
            stats.inFlight += 1
            stats.peakConcurrency = max(stats.peakConcurrency, stats.inFlight)
        }
        // .userInitiated, not .utility: measured ×3.2 on this machine, because `.utility` is
        // routed onto the two EFFICIENCY cores and nothing else. Someone who just opened their
        // project is WAITING for these peaks to appear — this is not background housekeeping,
        // unlike the flush below (@see `setWaveformsDirectory`), which nobody is watching
        // for and MUST stay on `.utility`: do not "harmonise" the two.
        Task.detached(priority: .userInitiated) {
            // 1) Try the `.wfc` disk cache (instant peaks, no decoding). Reading is effectively
            // instant, so the folder captured at this call's own start is fine here: a folder
            // that has since gone stale just MISSES (the file is not there, or fails the
            // identity check) and falls through to a fresh compute below — never a wrong answer,
            // unlike the write this function ends with (@see step 2's own note).
            let diskStart = CFAbsoluteTimeGetCurrent()
            if let dir, let cached = Self.loadFromDisk(path: filePath, dir: dir) {
                WaveformCacheMeter.record { stats in
                    stats.mipmapsReadFromDisk += 1
                    stats.diskReadSeconds += CFAbsoluteTimeGetCurrent() - diskStart
                    stats.peakBytesInMemory += Self.peakByteSize(cached)
                    if cached.laneCount > 1 { stats.stereoMipmaps += 1 }
                }
                await MainActor.run {
                    self.store(cached, for: filePath)
                    self.inFlight.remove(filePath)
                    WaveformCacheMeter.record { $0.inFlight -= 1 }
                }
                return
            }
            // 2) Otherwise compute, then persist into whatever the CURRENT project names AT THE
            // MOMENT THE COMPUTE FINISHES — not the one that was current when it started. A large
            // file's decode runs past a second (@see `chunkFrames`), and a second is enough for a
            // close, a new project or a Save As to have already retargeted `waveformsDirectory`
            // out from under it; re-reading `writeTarget` here, on the MainActor, right before the
            // write, is what keeps a slow decode from landing in the folder it started in rather
            // than the one open when it finished.
            let computeStart = CFAbsoluteTimeGetCurrent()
            let result = await Self.computeMipmap(path: filePath)
            WaveformCacheMeter.record { stats in
                stats.mipmapsComputed += 1
                stats.mipmapComputeSeconds += CFAbsoluteTimeGetCurrent() - computeStart
                stats.peakBytesInMemory += Self.peakByteSize(result)
                if result.laneCount > 1 { stats.stereoMipmaps += 1 }
            }
            let target = await MainActor.run { self.writeTarget(for: filePath) }
            if let target { Self.writeToDisk(result, path: filePath, dir: target) }
            await MainActor.run {
                self.store(result, for: filePath)
                self.inFlight.remove(filePath)
                WaveformCacheMeter.record { $0.inFlight -= 1 }
            }
        }
    }

    /// The memory footprint of one entry's peaks — a gauge for `perf.waveforms`, never on the
    /// drawing path. Computed once per file at load, not tracked per mutation: the mipmap cache
    /// is never evicted (@see `setWaveformsDirectory`, C3 — the memory cache stays shared across
    /// projects on purpose), so this only ever grows, which is exactly what a resident-set gauge
    /// should do.
    /// Deliberately `MemoryLayout<PeakPair>` (Float), not `QuantisedPeakPair`: this gauges what
    /// sits in RAM, and only the `.wfc` on disk is quantised — the entry this walks was just
    /// decoded BACK to Float by `loadFromDisk`, or was never quantised at all (`computeMipmap`).
    /// Every lane counts: a stereo file weighs twice a mono one of the same length.
    private nonisolated static func peakByteSize(_ entry: Entry) -> Int {
        entry.peaks.reduce(0) { total, level in
            level.reduce(total) { $0 + $1.count * MemoryLayout<PeakPair>.stride }
        }
    }

    /// Bounds how many mipmaps are computed AT ONCE. Not a thread count — the cooperative pool
    /// already caps that — but a MEMORY bound and a scheduling one: `ensureWaveformsLoaded`
    /// (`TimelineView`) asks for every visible entry in one go, and 200 files each holding a
    /// decode buffer is how the resident set reached 3.76 GB on a 16 GB machine with the engine
    /// and the plugins running beside it. An actor rather than a `DispatchSemaphore`: the wait
    /// has to be `async`, or every caller would block a cooperative-pool thread while it queues.
    private actor ComputeGate {
        private let limit: Int
        private var running = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(limit: Int) { self.limit = limit }

        func acquire() async {
            if running < limit { running += 1; return }
            await withCheckedContinuation { waiters.append($0) }
            // No `running += 1` here: `release()` hands its slot straight to the next waiter
            // instead of freeing it and letting a THIRD task race to reclaim it.
        }

        func release() {
            if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
        }
    }
    private nonisolated static let computeGate = ComputeGate(limit: 8)

    /// Frames per chunk: ~1 MB of float32 per channel, one buffer allocated ONCE and reused for
    /// every read of a file — a 317 MB source no longer needs a 423 MB decode buffer to draw its
    /// waveform, it needs this one, however long the file is.
    private nonisolated static let chunkFrames = 1 << 18

    private nonisolated static func computeMipmap(path: String) async -> Entry {
        let densities = effectiveDensitiesPerSecond
        let url = URL(fileURLWithPath: path)
        // A failure entry keeps the SHAPE of a real one — one level per density, one (empty) lane
        // per level — so `laneCount` and every reader below see a well-formed entry that simply
        // holds nothing (@see isUsable).
        guard let audioFile = try? AVAudioFile(forReading: url), let finestDensity = densities.last else {
            return Entry(peaks: densities.map { _ in [[]] }, densities: densities,
                         duration: 0, sampleRate: 0)
        }
        let format = audioFile.processingFormat
        let total = Int(audioFile.length)
        let duration = Double(audioFile.length) / format.sampleRate
        guard total > 0 else {
            return Entry(peaks: densities.map { _ in [[]] }, densities: densities,
                         duration: duration, sampleRate: format.sampleRate)
        }

        await computeGate.acquire()
        let finest = decodeChunked(audioFile: audioFile, total: total, channelCount: Int(format.channelCount),
                                   duration: duration, density: finestDensity)
        await computeGate.release()

        guard let finest else {
            return Entry(peaks: densities.map { _ in [[]] }, densities: densities,
                         duration: duration, sampleRate: format.sampleRate)
        }

        // Every coarser level is a FOLD of the one just finer than it, ratio 10 between
        // neighbours — never a fresh scan of the raw samples. Three full passes over the buffer
        // (one per density) became one decode plus two cheap folds over an already-reduced array
        // (×2.4 measured on the peak stage; @see WaveformPeaks.decimate for the invariant that
        // makes the cascade exact: folding by 10 twice lands on the same blocks as folding by
        // 100 once). Each lane folds on its own, over the one block grid they all share.
        var levels: [PeakLanes] = [finest]
        for i in stride(from: densities.count - 2, through: 0, by: -1) {
            let ratio = WaveformPeaks.foldRatio(fine: densities[i + 1], coarse: densities[i])
            levels.append(levels[levels.count - 1].map { WaveformPeaks.decimate($0, ratio: ratio) })
        }
        levels.reverse()   // back to coarse → fine, matching `densities`' own order

        return Entry(peaks: levels, densities: densities, duration: duration, sampleRate: format.sampleRate)
    }

    /// The finest level's blocks, one array per LANE (@see `PeakLaneAccumulator`, which does the
    /// folding and is asserted on its own). A STEREO file keeps its two channels apart, one lane
    /// each, drawn as two stacked waveforms. Any other file has ONE lane holding the UNION of every
    /// channel's own envelope (lo = the lowest minimum, hi = the highest maximum, each end taking
    /// whichever channel reaches furthest on ITS side), never a mixdown: summing channels can halve
    /// matter that sits on one of them alone, and in phase opposition can cancel it outright —
    /// drawing silence over real signal (@see `WaveformPeaks.laneCount` for why three channels and
    /// more are not split). @see decodeRegion for the samples-mode twin of this rule. RAW values,
    /// no normalisation.
    ///
    /// Only the FINEST level is decoded from the raw file (@see computeMipmap for why). nil on a
    /// read failure partway through — a partial mipmap would be indistinguishable from a
    /// complete one once written to disk.
    private nonisolated static func decodeChunked(audioFile: AVAudioFile, total: Int, channelCount: Int,
                                                   duration: Double, density: Double) -> PeakLanes? {
        guard channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                            frameCapacity: AVAudioFrameCount(chunkFrames))
        else { return nil }
        var level = PeakLaneAccumulator(density: density, duration: duration, total: total,
                                        laneCount: WaveformPeaks.laneCount(channelCount: channelCount))

        var framesRead = 0
        while framesRead < total {
            // `processingFormat` is always non-interleaved float32: `floatChannelData[c]` is its
            // own pointer, stride 1 — never assume interleaving on an AVAudioPCMBuffer.
            guard (try? audioFile.read(into: buffer, frameCount: AVAudioFrameCount(chunkFrames))) != nil,
                  let channels = buffer.floatChannelData
            else { return nil }
            let n = Int(buffer.frameLength)
            guard n > 0 else { break }
            // The accumulator cuts the chunk at block boundaries and asks for each segment's
            // extrema, channel by channel: vDSP over a run of samples, where the loop this
            // replaced compared every sample of every channel by hand.
            level.add(startFrame: framesRead, frameCount: n, channelCount: channelCount) { c, from, count in
                var lo: Float = 0, hi: Float = 0
                let base = UnsafePointer<Float>(channels[c] + from)
                vDSP_minv(base, 1, &lo, vDSP_Length(count))
                vDSP_maxv(base, 1, &hi, vDSP_Length(count))
                return PeakPair(lo: lo, hi: hi)
            }
            framesRead += n
        }
        return level.finish()
    }

    // MARK: - The .wfc disk cache

    // A file named after the source: '<sourceFileName>.wfc' (e.g. kick.wav.wfc),
    // readable in waveforms/. The identity (size + mtime) is stored IN the header
    // so as to invalidate it if the source changes (since the name no longer encodes it).
    // Binary format (little-endian):
    //   "WFC1" | version u32 | sampleRate f64 | duration f64
    //   | fileSize u64 | mtime f64 | laneCount u32 | levelCount u32
    //   per level: density f64 | count u32            (every lane of a level has `count` blocks)
    //   then, per level, per lane (lane 0 = left first): count × QuantisedPeakPair(lo i16, hi i16)
    //   as a raw dump
    // We do NOT persist the sample regions (regenerable, enormous) — see the roadmap.

    private nonisolated static let magic = Array("WFC1".utf8)
    // Not `private`: `perf.waveforms` reports it, so a script can tell a stale `.wfc` on disk
    // from a fresh one without parsing the binary header itself.
    // 2 → 3: the peak dump quantises to signed 16-bit (@see PeakQuantisation) instead of raw
    // float32 — a v2 file fails the version check below and is silently recomputed (@see
    // `loadFromDisk`'s own note: a cache's only obligation is to never lie, not to migrate).
    // 3 → 4: a stereo source keeps its two channels as two LANES (@see `WaveformPeaks.laneCount`)
    // and the header says how many lanes follow. A v3 file holds the merged envelope of a stereo
    // file, which would draw ONE waveform where two are now expected: rejected by the same check
    // and recomputed once per project. A stereo `.wfc` weighs twice a mono one of the same length.
    // The lane POLICY is part of this format — changing `laneCount(channelCount:)` needs a bump
    // here too, or a file written under the old rule would be read under the new one.
    nonisolated static let formatVersion: UInt32 = 4

    /// The cache file name for a source: basename + '.wfc'.
    private nonisolated static func cacheFileName(path: String) -> String {
        "\((path as NSString).lastPathComponent).wfc"
    }

    /// The source's identity: (size, mtime). nil if the file cannot be reached.
    private nonisolated static func fileIdentity(path: String) -> (size: UInt64, mtime: Double)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, mtime)
    }

    /// True if the entry really carries a waveform. When the file could not be decoded,
    /// `computeMipmap` returns a FAILURE entry (length 0 and one empty level per density):
    /// it has the right shape but holds nothing. Since `peaks` is not empty in the array sense
    /// (it has one element per level, one lane per level), the only reliable measure is the
    /// length — of the blocks, inside the lanes.
    private nonisolated static func isUsable(_ entry: Entry) -> Bool {
        entry.duration > 0 && entry.peaks.contains { level in level.contains { !$0.isEmpty } }
    }

    /// Every level carries the same lanes, and every lane of a level the same number of blocks —
    /// what the header's single `count` per level promises. Always true of what `computeMipmap`
    /// builds; checked rather than assumed at the one place a broken promise would be persisted.
    private nonisolated static func lanesAreConsistent(_ entry: Entry) -> Bool {
        let lanes = entry.laneCount
        guard lanes <= WaveformPeaks.maxLanes else { return false }
        return entry.peaks.allSatisfy { level in
            level.count == lanes && level.allSatisfy { $0.count == level[0].count }
        }
    }

    private nonisolated static func writeToDisk(_ entry: Entry, path: String, dir: URL) {
        // A decoding failure is NEVER written to disk: it would be read back as a valid cache
        // (the source's identity does match) and the clip would stay without a waveform for ever
        // — while playback, which goes through the engine and not through AVFoundation, keeps
        // working. So a failure stays in memory only, and the next session tries again.
        guard isUsable(entry), lanesAreConsistent(entry), let id = fileIdentity(path: path) else { return }
        var data = Data()
        func appendU32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func appendU64(_ v: UInt64) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func appendF64(_ v: Double) { var x = v.bitPattern.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }

        data.append(contentsOf: magic)
        appendU32(formatVersion)
        appendF64(entry.sampleRate)
        appendF64(entry.duration)
        appendU64(id.size)
        appendF64(id.mtime)
        appendU32(UInt32(entry.laneCount))
        appendU32(UInt32(entry.peaks.count))
        for (i, level) in entry.peaks.enumerated() {
            appendF64(entry.densities[i])
            appendU32(UInt32(level.first?.count ?? 0))   // the lanes share it (@see lanesAreConsistent)
        }
        // Quantised to signed 16-bit on the way to disk ONLY (@see QuantisedPeakPair) — the
        // in-memory `entry.peaks` handed to the caller stays Float throughout, untouched here.
        // Same little-endian assumption as the header above, now explicit: `Int16`'s own byte
        // layout on every platform this project builds for.
        for level in entry.peaks {
            for lane in level {
                let quantised = lane.map(PeakQuantisation.encode)
                quantised.withUnsafeBytes { data.append(contentsOf: $0) }
            }
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(cacheFileName(path: path)), options: .atomic)
        WaveformCacheMeter.record { stats in
            stats.mipmapsWritten += 1
            stats.bytesWritten += data.count
        }
    }

    private nonisolated static func loadFromDisk(path: String, dir: URL) -> Entry? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(cacheFileName(path: path)))
        else { return nil }

        var offset = 0
        func readBytes(_ n: Int) -> Data? {
            guard n >= 0, offset + n <= data.count else { return nil }
            defer { offset += n }
            return data.subdata(in: offset..<offset + n)
        }
        func readU32() -> UInt32? {
            guard let d = readBytes(4) else { return nil }
            return UInt32(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        }
        func readU64() -> UInt64? {
            guard let d = readBytes(8) else { return nil }
            return UInt64(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
        }
        func readF64() -> Double? {
            guard let d = readBytes(8) else { return nil }
            let bits = UInt64(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
            return Double(bitPattern: bits)
        }

        guard readBytes(magic.count).map({ Array($0) }) == magic,
              readU32() == formatVersion,
              let sampleRate = readF64(),
              let duration = readF64(),
              let fileSize = readU64(),
              let mtime = readF64(),
              let laneCountU32 = readU32(),
              let levelCount = readU32()
        else { return nil }
        // A lane count nothing writes is a corrupt header, not a format to guess at.
        let laneCount = Int(laneCountU32)
        guard (1...WaveformPeaks.maxLanes).contains(laneCount) else { return nil }

        // Invalidation: has the source changed since the cache was written?
        guard let id = fileIdentity(path: path), id.size == fileSize, id.mtime == mtime
        else { return nil }

        var densities: [Double] = []
        var counts: [Int] = []
        for _ in 0..<levelCount {
            guard let dens = readF64(), let c = readU32() else { return nil }
            densities.append(dens)
            counts.append(Int(c))
        }
        // Revalidation: if the detail level (finenessMultiplier) has changed, the densities
        // no longer match → we ignore the cache and recompute.
        guard densities == effectiveDensitiesPerSecond else { return nil }

        // The dump on disk is `QuantisedPeakPair` (i16, i16); decoded back to `Float` HERE, once
        // per file at load — negligible next to the audio decode this cache exists to avoid
        // (@see PeakQuantisation, and `writeToDisk`'s own note on the write side).
        var peaks: [PeakLanes] = []
        for c in counts {
            var level: PeakLanes = []
            level.reserveCapacity(laneCount)
            for _ in 0..<laneCount {
                let byteCount = c * MemoryLayout<QuantisedPeakPair>.stride
                guard let d = readBytes(byteCount) else { return nil }
                var quantised = [QuantisedPeakPair](repeating: QuantisedPeakPair(lo: 0, hi: 0), count: c)
                if c > 0 {
                    _ = quantised.withUnsafeMutableBytes { dst in
                        d.copyBytes(to: dst.bindMemory(to: UInt8.self))
                    }
                }
                level.append(quantised.map(PeakQuantisation.decode))
            }
            peaks.append(level)
        }
        let entry = Entry(peaks: peaks, densities: densities, duration: duration,
                          sampleRate: sampleRate)
        // A net for the failure caches written by earlier versions: we ignore them,
        // which restarts a clean computation and rewrites them correctly.
        return isUsable(entry) ? entry : nil
    }
}
