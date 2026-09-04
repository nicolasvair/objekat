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

    // An asymmetric envelope per block: negative extremum (lo) and positive one (hi),
    // raw values in [-1, 1] (no normalisation, we show the real amplitude).
    struct PeakPair {
        var lo: Float  // typically <= 0
        var hi: Float  // typically >= 0
    }

    struct Entry {
        var peaks: [[PeakPair]]      // one array per level
        var densities: [Double]      // the effective peaks/second of each level (a snapshot at build time)
        var duration: Double
        var sampleRate: Double
    }

    // A region of samples decoded on demand (deep zoom), a raw signed mono mixdown.
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

            let region = await Task.detached(priority: .userInitiated) {
                Self.decodeRegion(path: filePath, startTime: lo, endTime: hi, sampleRate: sr)
            }.value

            regionInFlight[filePath] = nil
            guard let region else { return }
            sampleRegions[filePath] = region
            regionRecency.removeAll { $0 == filePath }
            regionRecency.insert(filePath, at: 0)
            evictRegionsIfNeeded()
        }
    }

    private func evictRegionsIfNeeded() {
        while regionRecency.count > Self.regionCap {
            let victim = regionRecency.removeLast()
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
        guard (try? file.read(into: buffer, frameCount: frames)) != nil,
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        let n = Int(buffer.frameLength)
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n { samples[i] = channel[i] }
        return SampleRegion(startTime: Double(startFrame) / format.sampleRate,
                            endTime: Double(startFrame + AVAudioFramePosition(n)) / format.sampleRate,
                            samples: samples, sampleRate: format.sampleRate)
    }

    func load(filePath: String) {
        guard !inFlight.contains(filePath), cache[filePath] == nil else { return }
        inFlight.insert(filePath)
        let dir = waveformsDirectory
        Task.detached(priority: .utility) {
            // 1) Try the `.wfc` disk cache (instant peaks, no decoding).
            if let dir, let cached = Self.loadFromDisk(path: filePath, dir: dir) {
                await MainActor.run {
                    self.cache[filePath] = cached
                    self.inFlight.remove(filePath)
                }
                return
            }
            // 2) Otherwise compute, then persist if a project folder is known.
            let result = Self.computeMipmap(path: filePath)
            if let dir { Self.writeToDisk(result, path: filePath, dir: dir) }
            await MainActor.run {
                self.cache[filePath] = result
                self.inFlight.remove(filePath)
            }
        }
    }

    private nonisolated static func computeMipmap(path: String) -> Entry {
        let densities = effectiveDensitiesPerSecond
        let url = URL(fileURLWithPath: path)
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            return Entry(peaks: densities.map { _ in [] }, densities: densities,
                         duration: 0, sampleRate: 0)
        }
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        let duration = Double(audioFile.length) / format.sampleRate
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              (try? audioFile.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0]
        else {
            return Entry(peaks: densities.map { _ in [] }, densities: densities,
                         duration: duration, sampleRate: format.sampleRate)
        }
        let total = Int(buffer.frameLength)

        // For each level: an asymmetric envelope (negative lo, positive hi) per block.
        // RAW values, no normalisation — the real amplitude.
        var allPeaks: [[PeakPair]] = []
        for density in densities {
            let count = max(1, Int((density * duration).rounded()))
            var peaks = [PeakPair](repeating: PeakPair(lo: 0, hi: 0), count: count)
            let step = Double(total) / Double(count)
            for i in 0..<count {
                let start = Int(Double(i) * step)
                let end   = min(Int(Double(i + 1) * step), total)
                var lo: Float = 0
                var hi: Float = 0
                for j in start..<end {
                    let v = channel[j]
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                }
                peaks[i] = PeakPair(lo: lo, hi: hi)
            }
            allPeaks.append(peaks)
        }
        return Entry(peaks: allPeaks, densities: densities, duration: duration,
                     sampleRate: format.sampleRate)
    }

    // MARK: - The .wfc disk cache

    // A file named after the source: '<sourceFileName>.wfc' (e.g. kick.wav.wfc),
    // readable in waveforms/. The identity (size + mtime) is stored IN the header
    // so as to invalidate it if the source changes (since the name no longer encodes it).
    // Binary format (little-endian):
    //   "WFC1" | version u32 | sampleRate f64 | duration f64
    //   | fileSize u64 | mtime f64 | levelCount u32
    //   per level: density f64 | count u32
    //   then, per level: count × PeakPair(lo f32, hi f32) as a raw dump
    // We do NOT persist `samples` (regenerable, enormous) — see the roadmap.

    private nonisolated static let magic = Array("WFC1".utf8)
    private nonisolated static let formatVersion: UInt32 = 2

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
        for level in entry.peaks {
            level.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(cacheFileName(path: path)), options: .atomic)
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

        var peaks: [[PeakPair]] = []
        for c in counts {
            let byteCount = c * MemoryLayout<PeakPair>.stride
            guard let d = readBytes(byteCount) else { return nil }
            var arr = [PeakPair](repeating: PeakPair(lo: 0, hi: 0), count: c)
            if c > 0 {
                _ = arr.withUnsafeMutableBytes { dst in
                    d.copyBytes(to: dst.bindMemory(to: UInt8.self))
                }
            }
            peaks.append(arr)
        }
        let entry = Entry(peaks: peaks, densities: densities, duration: duration,
                          sampleRate: sampleRate)
        // A net for the failure caches written by earlier versions: we ignore them,
        // which restarts a clean computation and rewrites them correctly.
        return isUsable(entry) ? entry : nil
    }
}
