import Foundation
import AVFoundation
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
    nonisolated static let baseDensitiesPerSecond: [Double] = [100, 1000, 10000]

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
        var peaks: [[PeakPair]]      // one array per level
        var densities: [Double]      // the effective peaks/second of each level (a snapshot at build time)
        var duration: Double
        var sampleRate: Double
    }

    // A region of samples decoded on demand (deep zoom): per sample, the value of the channel
    // with the LARGEST MAGNITUDE, sign kept (@see decodeRegion — not a mono mixdown, which a
    // stereo pair in phase opposition can silence outright).
    // We NEVER keep the whole PCM in RAM: only a small window around the view,
    // evicted when zooming out or looking at another file.
    struct SampleRegion {
        var startTime: Double        // file time (s) of the 1st sample of `samples`
        var endTime: Double          // file time (s) covered (exclusive)
        var samples: [Float]
        var sampleRate: Double
        /// Index into `samples` for a given file time (may fall outside the bounds).
        func index(forFileTime t: Double) -> Int { Int((t - startTime) * sampleRate) }
    }

    private var cache: [String: Entry] = [:]
    private var inFlight: Set<String> = []

    // An LRU cache of sample regions (the cap is deliberately low: ~260 kB/region).
    private var sampleRegions: [String: SampleRegion] = [:]
    private var regionRecency: [String] = []          // most recent at the head
    private var regionInFlight: [String: ClosedRange<Double>] = [:]  // the target currently being decoded
    private static let regionCap = 8
    private static let regionMinSpan: Double = 2.0    // at least 2 s decoded per region

    // The project's `waveforms/` folder, where the `.wfc` caches are written and read back.
    // nil while the project is unsaved → computed in memory only.
    // When it becomes non-nil (the 1st Save As), the entries already computed are flushed.
    var waveformsDirectory: URL? {
        didSet {
            guard let dir = waveformsDirectory, dir != oldValue else { return }
            let snapshot = cache
            // Deliberately `.utility`, unlike `load`'s own task: nobody is waiting on this
            // write, a Save As having already returned before it finishes. Real background work.
            Task.detached(priority: .utility) {
                for (path, entry) in snapshot where Self.isUsable(entry) {
                    Self.writeToDisk(entry, path: path, dir: dir)
                }
            }
        }
    }

    // Returns the peaks of the level best suited to the current zoom.
    // pixelsPerSecond: pixels shown per second on screen.
    func peaks(for filePath: String, pixelsPerSecond: Double) -> [PeakPair]? {
        guard let entry = cache[filePath], entry.duration > 0 else { return nil }
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

    /// The region of samples covering [fileStart, fileEnd] if it is already decoded.
    /// Otherwise starts the windowed decode in the background and returns nil
    /// (rendering falls back on the peaks until the region is ready).
    func samplesRegion(for filePath: String, fileStart: Double, fileEnd: Double) -> SampleRegion? {
        guard let duration = cache[filePath]?.duration, duration > 0 else { return nil }
        // A PURELY read-only synchronous path (called while the Canvas renders):
        // a hit returns the region, a miss schedules the decode without mutating state here.
        if let region = sampleRegions[filePath],
           region.startTime <= fileStart, region.endTime >= fileEnd {
            return region
        }
        requestRegion(filePath, fileStart: fileStart, fileEnd: fileEnd, duration: duration)
        return nil
    }

    /// Schedules (outside the view update) the windowed decode of a missing region.
    private func requestRegion(_ filePath: String, fileStart: Double, fileEnd: Double, duration: Double) {
        Task { @MainActor in
            // De-duplication: the region may have arrived, or a decode may already cover it.
            if let r = sampleRegions[filePath], r.startTime <= fileStart, r.endTime >= fileEnd { return }
            if let t = regionInFlight[filePath], t.contains(fileStart), t.contains(fileEnd) { return }
            guard let sr = cache[filePath]?.sampleRate, sr > 0 else { return }

            // The target: the requested window widened (≥ regionMinSpan), bounded by the file.
            let center = (fileStart + fileEnd) * 0.5
            let half = max((fileEnd - fileStart) * 1.5, Self.regionMinSpan * 0.5)
            let lo = max(0, center - half)
            let hi = min(duration, center + half)
            regionInFlight[filePath] = lo...hi

            let decodeStart = CFAbsoluteTimeGetCurrent()
            let region = await Task.detached(priority: .userInitiated) {
                Self.decodeRegion(path: filePath, startTime: lo, endTime: hi, sampleRate: sr)
            }.value

            regionInFlight[filePath] = nil
            guard let region else { return }
            WaveformCacheMeter.record { stats in
                stats.regionsDecoded += 1
                stats.regionDecodeSeconds += CFAbsoluteTimeGetCurrent() - decodeStart
                stats.regionBytesInMemory += region.samples.count * MemoryLayout<Float>.stride
            }
            sampleRegions[filePath] = region
            regionRecency.removeAll { $0 == filePath }
            regionRecency.insert(filePath, at: 0)
            evictRegionsIfNeeded()
        }
    }

    private func evictRegionsIfNeeded() {
        while regionRecency.count > Self.regionCap {
            let victim = regionRecency.removeLast()
            if let region = sampleRegions[victim] {
                WaveformCacheMeter.record { stats in
                    stats.regionsEvicted += 1
                    stats.regionBytesInMemory -= region.samples.count * MemoryLayout<Float>.stride
                }
            }
            sampleRegions[victim] = nil
        }
    }

    /// Decodes ONLY the [startTime, endTime] window of the file (a mono mixdown).
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
        let n = Int(buffer.frameLength)
        var samples = [Float](repeating: 0, count: n)
        // The channel of LARGEST MAGNITUDE speaks for each sample, SIGN KEPT: a max would
        // rectify the shape, and it is always the loudest channel that should be heard here —
        // its min/max per pixel is exactly the union `computeMipmap` draws for the peaks levels,
        // so the two paths agree either side of the samples-mode threshold.
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
        return SampleRegion(startTime: Double(startFrame) / format.sampleRate,
                            endTime: Double(startFrame + AVAudioFramePosition(n)) / format.sampleRate,
                            samples: samples, sampleRate: format.sampleRate)
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
        // unlike the flush below (@see `waveformsDirectory.didSet`), which nobody is watching
        // for and MUST stay on `.utility`: do not "harmonise" the two.
        Task.detached(priority: .userInitiated) {
            // 1) Try the `.wfc` disk cache (instant peaks, no decoding).
            let diskStart = CFAbsoluteTimeGetCurrent()
            if let dir, let cached = Self.loadFromDisk(path: filePath, dir: dir) {
                WaveformCacheMeter.record { stats in
                    stats.mipmapsReadFromDisk += 1
                    stats.diskReadSeconds += CFAbsoluteTimeGetCurrent() - diskStart
                    stats.peakBytesInMemory += Self.peakByteSize(cached)
                }
                await MainActor.run {
                    self.cache[filePath] = cached
                    self.inFlight.remove(filePath)
                    WaveformCacheMeter.record { $0.inFlight -= 1 }
                }
                return
            }
            // 2) Otherwise compute, then persist if a project folder is known.
            let computeStart = CFAbsoluteTimeGetCurrent()
            let result = await Self.computeMipmap(path: filePath)
            WaveformCacheMeter.record { stats in
                stats.mipmapsComputed += 1
                stats.mipmapComputeSeconds += CFAbsoluteTimeGetCurrent() - computeStart
                stats.peakBytesInMemory += Self.peakByteSize(result)
            }
            if let dir { Self.writeToDisk(result, path: filePath, dir: dir) }
            await MainActor.run {
                self.cache[filePath] = result
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
    private nonisolated static func peakByteSize(_ entry: Entry) -> Int {
        entry.peaks.reduce(0) { $0 + $1.count * MemoryLayout<PeakPair>.stride }
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
        guard let audioFile = try? AVAudioFile(forReading: url), let finestDensity = densities.last else {
            return Entry(peaks: densities.map { _ in [] }, densities: densities,
                         duration: 0, sampleRate: 0)
        }
        let format = audioFile.processingFormat
        let total = Int(audioFile.length)
        let duration = Double(audioFile.length) / format.sampleRate
        guard total > 0 else {
            return Entry(peaks: densities.map { _ in [] }, densities: densities,
                         duration: duration, sampleRate: format.sampleRate)
        }

        await computeGate.acquire()
        let finest = decodeChunked(audioFile: audioFile, total: total, channelCount: Int(format.channelCount),
                                   duration: duration, density: finestDensity)
        await computeGate.release()

        guard let finest else {
            return Entry(peaks: densities.map { _ in [] }, densities: densities,
                         duration: duration, sampleRate: format.sampleRate)
        }

        // Every coarser level is a FOLD of the one just finer than it, ratio 10 between
        // neighbours — never a fresh scan of the raw samples. Three full passes over the buffer
        // (one per density) became one decode plus two cheap folds over an already-reduced array
        // (×2.4 measured on the peak stage; @see WaveformPeaks.decimate for the invariant that
        // makes the cascade exact: folding by 10 twice lands on the same blocks as folding by
        // 100 once).
        var levels = [finest]
        for i in stride(from: densities.count - 2, through: 0, by: -1) {
            let ratio = WaveformPeaks.foldRatio(fine: densities[i + 1], coarse: densities[i])
            levels.append(WaveformPeaks.decimate(levels[levels.count - 1], ratio: ratio))
        }
        levels.reverse()   // back to coarse → fine, matching `densities`' own order

        return Entry(peaks: levels, densities: densities, duration: duration, sampleRate: format.sampleRate)
    }

    /// The finest level's blocks, filled while the file streams past in chunks. Keeps the
    /// in-progress block's (lo, hi) across chunk boundaries — a block is almost always far
    /// narrower than `chunkFrames` (4.8 frames at 10 000 peaks/s and 48 kHz), so it WILL straddle
    /// a boundary, at most one block per boundary. Skipping that carry would draw a false notch
    /// every `chunkFrames` worth of file — about once every 5.5 s.
    private nonisolated struct LevelAccumulator {
        let count: Int
        private let step: Double
        private let total: Int
        private var peaks: [PeakPair]
        private var blockIndex = 0
        private var blockEnd: Int
        private var lo: Float = 0
        private var hi: Float = 0

        init(density: Double, duration: Double, total: Int) {
            count = max(1, Int((density * duration).rounded()))
            step = Double(total) / Double(count)
            self.total = total
            peaks = [PeakPair](repeating: PeakPair(lo: 0, hi: 0), count: count)
            blockEnd = min(Int(step), total)
        }

        /// `absoluteFrame` must arrive in strictly increasing order across the whole file — the
        /// one assumption that turns this into a single streaming pass instead of a second scan.
        mutating func add(absoluteFrame: Int, lo v0: Float, hi v1: Float) {
            while absoluteFrame >= blockEnd, blockIndex < count {
                peaks[blockIndex] = PeakPair(lo: lo, hi: hi)
                blockIndex += 1
                lo = 0; hi = 0
                blockEnd = blockIndex < count ? min(Int(Double(blockIndex + 1) * step), total) : blockEnd
            }
            guard blockIndex < count else { return }
            if v0 < lo { lo = v0 }
            if v1 > hi { hi = v1 }
        }

        /// Closes whatever block is still open once the last chunk has been folded in — nothing
        /// past the final frame ever reaches `blockEnd`, since the last block's end is the file's
        /// own end.
        mutating func finish() -> [PeakPair] {
            while blockIndex < count {
                peaks[blockIndex] = PeakPair(lo: lo, hi: hi)
                blockIndex += 1
                lo = 0; hi = 0
            }
            return peaks
        }
    }

    /// The UNION of every channel's own envelope (lo = the lowest minimum, hi = the highest
    /// maximum, each end taking whichever channel reaches furthest on ITS side), never a
    /// mixdown. The envelope must show what comes out LOUDEST: summing channels can halve matter
    /// that sits on one of them alone, and in phase opposition can cancel it outright — drawing
    /// silence over real signal. @see decodeRegion for the samples-mode twin of this rule (its
    /// min/max per pixel is exactly this union). RAW values, no normalisation.
    ///
    /// Only the FINEST level is decoded from the raw file (@see computeMipmap for why). nil on a
    /// read failure partway through — a partial mipmap would be indistinguishable from a
    /// complete one once written to disk.
    private nonisolated static func decodeChunked(audioFile: AVAudioFile, total: Int, channelCount: Int,
                                                   duration: Double, density: Double) -> [PeakPair]? {
        guard channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                            frameCapacity: AVAudioFrameCount(chunkFrames))
        else { return nil }
        var level = LevelAccumulator(density: density, duration: duration, total: total)

        var framesRead = 0
        while framesRead < total {
            // `processingFormat` is always non-interleaved float32: `floatChannelData[c]` is its
            // own pointer, stride 1 — never assume interleaving on an AVAudioPCMBuffer.
            guard (try? audioFile.read(into: buffer, frameCount: AVAudioFrameCount(chunkFrames))) != nil,
                  let channels = buffer.floatChannelData
            else { return nil }
            let n = Int(buffer.frameLength)
            guard n > 0 else { break }
            for j in 0..<n {
                var frameLo = channels[0][j]
                var frameHi = frameLo
                for c in 1..<channelCount {
                    let v = channels[c][j]
                    if v < frameLo { frameLo = v }
                    if v > frameHi { frameHi = v }
                }
                level.add(absoluteFrame: framesRead + j, lo: frameLo, hi: frameHi)
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
    //   | fileSize u64 | mtime f64 | levelCount u32
    //   per level: density f64 | count u32
    //   then, per level: count × QuantisedPeakPair(lo i16, hi i16) as a raw dump
    // We do NOT persist `samples` (regenerable, enormous) — see the roadmap.

    private nonisolated static let magic = Array("WFC1".utf8)
    // Not `private`: `perf.waveforms` reports it, so a script can tell a stale `.wfc` on disk
    // from a fresh one without parsing the binary header itself.
    // 2 → 3: the peak dump quantises to signed 16-bit (@see PeakQuantisation) instead of raw
    // float32 — a v2 file fails the version check below and is silently recomputed (@see
    // `loadFromDisk`'s own note: a cache's only obligation is to never lie, not to migrate).
    nonisolated static let formatVersion: UInt32 = 3

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
    /// (it has one element per level), the only reliable measure is the length.
    private nonisolated static func isUsable(_ entry: Entry) -> Bool {
        entry.duration > 0 && entry.peaks.contains { !$0.isEmpty }
    }

    private nonisolated static func writeToDisk(_ entry: Entry, path: String, dir: URL) {
        // A decoding failure is NEVER written to disk: it would be read back as a valid cache
        // (the source's identity does match) and the clip would stay without a waveform for ever
        // — while playback, which goes through the engine and not through AVFoundation, keeps
        // working. So a failure stays in memory only, and the next session tries again.
        guard isUsable(entry), let id = fileIdentity(path: path) else { return }
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
        appendU32(UInt32(entry.peaks.count))
        for (i, level) in entry.peaks.enumerated() {
            appendF64(entry.densities[i])
            appendU32(UInt32(level.count))
        }
        // Quantised to signed 16-bit on the way to disk ONLY (@see QuantisedPeakPair) — the
        // in-memory `entry.peaks` handed to the caller stays Float throughout, untouched here.
        // Same little-endian assumption as the header above, now explicit: `Int16`'s own byte
        // layout on every platform this project builds for.
        for level in entry.peaks {
            let quantised = level.map(PeakQuantisation.encode)
            quantised.withUnsafeBytes { data.append(contentsOf: $0) }
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
              let levelCount = readU32()
        else { return nil }

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
        var peaks: [[PeakPair]] = []
        for c in counts {
            let byteCount = c * MemoryLayout<QuantisedPeakPair>.stride
            guard let d = readBytes(byteCount) else { return nil }
            var quantised = [QuantisedPeakPair](repeating: QuantisedPeakPair(lo: 0, hi: 0), count: c)
            if c > 0 {
                _ = quantised.withUnsafeMutableBytes { dst in
                    d.copyBytes(to: dst.bindMemory(to: UInt8.self))
                }
            }
            peaks.append(quantised.map(PeakQuantisation.decode))
        }
        let entry = Entry(peaks: peaks, densities: densities, duration: duration,
                          sampleRate: sampleRate)
        // A net for the failure caches written by earlier versions: we ignore them,
        // which restarts a clean computation and rewrites them correctly.
        return isUsable(entry) ? entry : nil
    }
}
