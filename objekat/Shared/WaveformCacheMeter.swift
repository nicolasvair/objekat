import Foundation

// The waveform cache's counters, watched from OUTSIDE the cache rather than guessed at with a
// stopwatch on the UI. Every mutation below is written from `WaveformCache`'s `nonisolated
// static` contexts — the decode and disk work happen off the main actor, on whichever thread the
// cooperative pool hands them, so a plain stored property would have been a data race. A lock
// instead of an actor: these are counters, not state a caller awaits on, and `perf.waveforms`
// (`CommandAPI/Commands+Runtime.swift`) reads them synchronously from the MainActor with no
// `await` in its way.
//
// THE ONE RULE THAT MAKES THIS FREE: every write is PER FILE or PER REGION, never per sample or
// per pixel. A mipmap is computed once, a region decoded once, in a run that already pays for a
// file read or a decode — the counter add is noise beside it. Nothing here is on the drawing
// path (`WaveformDrawing.swift`), which is read every frame and must stay lock-free.

/// A snapshot of the counters — see the file header for what each one costs to keep.
/// `nonisolated`: a plain value type with no isolation of its own, so a `nonisolated` context
/// (@see `WaveformCacheMeter` below) can construct and copy it with no actor hop.
nonisolated struct WaveformCacheStats: Sendable {
    var mipmapsComputed = 0
    var mipmapComputeSeconds = 0.0
    var mipmapsReadFromDisk = 0
    var diskReadSeconds = 0.0
    var mipmapsWritten = 0
    var bytesWritten = 0
    var regionsDecoded = 0
    var regionDecodeSeconds = 0.0
    var regionsEvicted = 0
    var peakBytesInMemory = 0
    var regionBytesInMemory = 0
    var inFlight = 0
    var peakConcurrency = 0
}

// `nonisolated`, like `WaveformCache.finenessMultiplier` right beside the callers of this type:
// the project defaults every declaration to `@MainActor`, but `computeMipmap` / `decodeRegion` /
// `writeToDisk` run detached, off the main actor by design — a plain (implicitly MainActor)
// `static func` here would make every one of those sites `await` a hop to the main actor just to
// take a lock, which defeats moving the decode off it in the first place. The lock, not the
// actor, is what makes this safe to call from anywhere.
enum WaveformCacheMeter {
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var stats = WaveformCacheStats()

    nonisolated static func snapshot() -> WaveformCacheStats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    /// Zeroes every counter. For a bench's own protocol (@see `tools/bench_waveform_cache.py`):
    /// a cold measurement starts from a known zero rather than carrying the previous point's count.
    nonisolated static func reset() {
        lock.lock(); defer { lock.unlock() }
        stats = WaveformCacheStats()
    }

    /// The one door onto a mutation, so every caller takes the same lock the same way — a second
    /// entry point reading `stats` outside it would race the writers above.
    nonisolated static func record(_ mutate: (inout WaveformCacheStats) -> Void) {
        lock.lock(); defer { lock.unlock() }
        mutate(&stats)
    }
}
