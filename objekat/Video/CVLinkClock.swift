import Foundation
import CoreVideo

// MARK: - A CVDisplayLink timestamp, in the clock the picture's anchor speaks (plan-video §4.4)
//
// `CVTimeStamp.hostTime` counts `mach_absolute_time` ticks. `CACurrentMediaTime()` — the clock of
// `VideoClockAnchor` — is that same counter in seconds, so the conversion is the mach timebase and
// nothing else: the output time of a refresh of the legacy link (below macOS 14) is the instant the
// frame will be on the glass, exactly what `CAMetalDisplayLink`'s `targetPresentationTimestamp` is.
// Alone in its file so that the bench `tools/test_video_cvlink.swift` compiles it without the app.

nonisolated enum CVLinkClock {

    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    /// `hostTime` (mach ticks) in seconds, the base of `CACurrentMediaTime()`.
    static func seconds(hostTime: UInt64) -> Double {
        Double(hostTime) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}
