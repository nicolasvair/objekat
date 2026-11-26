// The video resolver (plan-video §4.3): "at timeline time t, which pictures, and which instant of
// its file?" — asserted with no screen, no engine and no model. `Shared/VideoTimeMap.swift` is a pure
// function over a small index, which is why it can be compiled and run alone.
//
// What it pins: a group's WINDOW (nested ones included), the LOOP fold of a group (IN negative too,
// the right half of a cut looped group), speed and offset, a negative start, an infinite group, the
// picture's own loop, the front-most-lane order on the PATH of lanes (not on a display lane), the
// cap of two layers applied AFTER the window filtering, and the fact that V1 ignores `isMuted`.
//
// From `tools/`:
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/VideoTimeMap.swift ../objekat/Shared/WaveformShaping.swift \
//         ../objekat/SoundObject/FadeCurve.swift test_video_time_map.swift \
//         -o /tmp/vtm && /tmp/vtm
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

func near(_ a: Double?, _ b: Double, _ eps: Double = 1e-9) -> Bool {
    guard let a else { return false }
    return abs(a - b) < eps
}

func pic(_ n: Int, lane: Int = 0, start: Double = 0, duration: Double = 10, offset: Double = 0,
         speed: Double = 1, fileDuration: Double = 100, loop: VideoLoopRange? = nil,
         muted: Bool = false, ancestors: [VideoGroupWindow] = []) -> VideoPictureEntry {
    VideoPictureEntry(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
                      filePath: "/v\(n).mov", lane: lane, start: start, duration: duration,
                      sourceOffset: offset, speedRatio: speed, fileDuration: fileDuration,
                      loop: loop, nominalFPS: 30, isMuted: muted, ancestors: ancestors)
}

func ids(_ ls: [VideoLayer]) -> [String] { ls.map { $0.filePath } }

@main
enum VideoTimeMapTest {
  static func main() {

    // MARK: - A picture at the root

    let a = pic(1, start: 5, duration: 10, offset: 2)
    check("before the window: nothing", VideoResolver.layer(of: a, at: 4.999) == nil)
    check("the first instant of the window shows the offset",
          near(VideoResolver.layer(of: a, at: 5)?.sourceTime, 2))
    check("inside: offset + local time", near(VideoResolver.layer(of: a, at: 8)?.sourceTime, 5))
    check("the end is EXCLUDED", VideoResolver.layer(of: a, at: 15) == nil)
    check("opacity is 1 in V1", VideoResolver.layer(of: a, at: 8)?.opacity == 1)

    // MARK: - Speed, offset in SOURCE seconds

    let fast = pic(2, start: 0, duration: 5, offset: 10, speed: 2)
    check("speed 2: one timeline second reads two source seconds",
          near(VideoResolver.layer(of: fast, at: 3)?.sourceTime, 16))
    check("speed 2: the layer carries the rate", VideoResolver.layer(of: fast, at: 3)?.rate == 2)
    let slow = pic(3, start: 4, duration: 10, offset: 1, speed: 0.5)
    check("speed 0.5", near(VideoResolver.layer(of: slow, at: 8)?.sourceTime, 3))

    // MARK: - Negative start (an object may begin before 0)

    let neg = pic(4, start: -2, duration: 6, offset: 7)
    check("negative start: t = 0 is 2 s into the picture",
          near(VideoResolver.layer(of: neg, at: 0)?.sourceTime, 9))
    check("negative start: still the end exclusive", VideoResolver.layer(of: neg, at: 4) == nil)

    // MARK: - Past the end of the file there is no picture

    let short = pic(5, start: 0, duration: 20, fileDuration: 8)
    check("inside the file", near(VideoResolver.layer(of: short, at: 7.5)?.sourceTime, 7.5))
    check("past the file's end: nothing, never a frozen last frame",
          VideoResolver.layer(of: short, at: 8) == nil)

    // MARK: - A group's window

    let g = VideoGroupWindow(lane: 0, start: 10, duration: 5)
    let inG = pic(6, start: 8, duration: 20, ancestors: [g])
    check("child before the group's window: nothing", VideoResolver.layer(of: inG, at: 9) == nil)
    check("child inside the group's window: shown", VideoResolver.layer(of: inG, at: 12) != nil)
    check("the child overflows the window: cut at the window's end",
          VideoResolver.layer(of: inG, at: 15) == nil)

    // Two nested windows intersect.
    let outer = VideoGroupWindow(lane: 0, start: 0, duration: 20)
    let inner = VideoGroupWindow(lane: 1, start: 5, duration: 20)   // ends at 25, the outer at 20
    let nested = pic(7, start: 0, duration: 100, ancestors: [outer, inner])
    check("nested windows: before the inner one", VideoResolver.layer(of: nested, at: 4) == nil)
    check("nested windows: inside both", VideoResolver.layer(of: nested, at: 10) != nil)
    check("nested windows: past the OUTER one although inside the inner",
          VideoResolver.layer(of: nested, at: 22) == nil)

    // MARK: - A looping group

    // Group at 10, 30 s long, loop [0, 5[: the first 5 s of the group repeat.
    let loopG = VideoGroupWindow(lane: 0, start: 10, duration: 30, loop: VideoLoopRange(start: 0, end: 5))
    let inLoop = pic(8, start: 10, duration: 5, ancestors: [loopG])
    check("looping group: first period unchanged", near(VideoResolver.layer(of: inLoop, at: 12)?.sourceTime, 2))
    check("looping group: second period folds back",
          near(VideoResolver.layer(of: inLoop, at: 17)?.sourceTime, 2))
    check("looping group: the third period", near(VideoResolver.layer(of: inLoop, at: 31)?.sourceTime, 1))
    check("looping group: the window still ends the loop", VideoResolver.layer(of: inLoop, at: 40) == nil)

    // IN positive: the material at IN lands at the start of each period (group at 0, slice [2, 5[).
    let g2 = VideoGroupWindow(lane: 0, start: 0, duration: 30, loop: VideoLoopRange(start: 2, end: 5))
    let p2 = pic(9, start: 0, duration: 30, ancestors: [g2])
    check("IN positive: the left edge plays the part of the IN point",
          near(VideoResolver.layer(of: p2, at: 0)?.sourceTime, 2))
    check("IN positive: t = 1 reads IN + 1", near(VideoResolver.layer(of: p2, at: 1)?.sourceTime, 3))
    check("IN positive: next period starts on IN again", near(VideoResolver.layer(of: p2, at: 3)?.sourceTime, 2))

    // IN NEGATIVE (the right half of a cut looped group): the grid of repeats starts at start + IN,
    // which preserves the phase across the cut. Group at 20, slice [-3, 4[ (7 s).
    let g3 = VideoGroupWindow(lane: 0, start: 20, duration: 30, loop: VideoLoopRange(start: -3, end: 4))
    let p3 = pic(10, start: 0, duration: 100, ancestors: [g3])
    check("IN negative: t = start reads (start + IN) + (start - origin) = start",
          near(VideoResolver.layer(of: p3, at: 20)?.sourceTime, 20))
    check("IN negative: one period after the grid origin comes back to IN",
          near(VideoResolver.layer(of: p3, at: 24)?.sourceTime, 17))
    check("IN negative: the phase carries on", near(VideoResolver.layer(of: p3, at: 26)?.sourceTime, 19))

    // A slice shorter than the floor is not a loop.
    let tiny = VideoGroupWindow(lane: 0, start: 0, duration: 10, loop: VideoLoopRange(start: 0, end: 0.01))
    check("a degenerate slice does not fold",
          near(VideoResolver.layer(of: pic(11, start: 0, duration: 10, ancestors: [tiny]), at: 4)?.sourceTime, 4))

    // A looping group inside a windowed one: the inner folds, the outer cuts.
    let nl = pic(12, start: 0, duration: 100,
                 ancestors: [VideoGroupWindow(lane: 0, start: 0, duration: 12),
                             VideoGroupWindow(lane: 0, start: 0, duration: 100, loop: VideoLoopRange(start: 0, end: 5))])
    check("loop inside a window: folds", near(VideoResolver.layer(of: nl, at: 7)?.sourceTime, 2))
    check("loop inside a window: and the window cuts", VideoResolver.layer(of: nl, at: 12) == nil)

    // MARK: - An infinite group has no window

    let inf = VideoGroupWindow(lane: 0, start: 100, duration: 1, isInfinite: true)
    let pi = pic(13, start: 0, duration: 50, ancestors: [inf])
    check("infinite group: no window, the picture keeps its own extent",
          near(VideoResolver.layer(of: pi, at: 20)?.sourceTime, 20))
    check("infinite group: the picture's own window still applies", VideoResolver.layer(of: pi, at: 50) == nil)

    // MARK: - The picture's own loop

    let ownLoop = pic(14, start: 0, duration: 30, offset: 10, loop: VideoLoopRange(start: 1, end: 4))
    check("own loop: first read at IN", near(VideoResolver.layer(of: ownLoop, at: 0)?.sourceTime, 11))
    check("own loop: folds", near(VideoResolver.layer(of: ownLoop, at: 4)?.sourceTime, 12))
    let ownLoopFast = pic(15, start: 0, duration: 30, offset: 0, speed: 2, loop: VideoLoopRange(start: 0, end: 3))
    check("own loop at speed 2 folds the LOCAL time, then reads at speed",
          near(VideoResolver.layer(of: ownLoopFast, at: 4)?.sourceTime, 2))

    // MARK: - Mute is ignored in V1 (Q7), opacity is 1 (Q6)

    let mutedG = VideoGroupWindow(lane: 0, start: 0, duration: 10, isMuted: true)
    let mutedP = pic(16, start: 0, duration: 10, muted: true, ancestors: [mutedG])
    check("a muted picture in a muted group is still resolved (V1)",
          VideoResolver.layer(of: mutedP, at: 5) != nil)

    // MARK: - Order: front-most first on the PATH of lanes, bottom-first in the answer

    let low = pic(20, lane: 3, start: 0, duration: 10)
    let high = pic(21, lane: 1, start: 0, duration: 10)
    let mid = pic(22, lane: 2, start: 0, duration: 10)
    var idx = VideoObjectIndex(entries: [low, high, mid])
    let got = VideoResolver.layers(at: 5, in: idx)
    check("two layers at most", got.count == 2)
    check("the two front-most are kept (lanes 1 and 2), the front one LAST",
          ids(got) == ["/v22.mov", "/v21.mov"], "\(ids(got))")

    // The path, not the display lane: a group on lane 3 holding a picture on lane 0, against a root
    // picture on lane 2 — the root picture is in front, however the groups are opened.
    let grp = VideoGroupWindow(lane: 3, start: 0, duration: 10)
    let child = pic(23, lane: 0, start: 0, duration: 10, ancestors: [grp])
    let rootPic = pic(24, lane: 2, start: 0, duration: 10)
    idx = VideoObjectIndex(entries: [child, rootPic])
    check("path comparison: [2] is in front of [3, 0]", ids(VideoResolver.layers(at: 1, in: idx)) == ["/v23.mov", "/v24.mov"])
    // And inside a group, the child lane decides: two children of one group.
    let c0 = pic(25, lane: 0, start: 0, duration: 10, ancestors: [grp])
    let c1 = pic(26, lane: 1, start: 0, duration: 10, ancestors: [grp])
    idx = VideoObjectIndex(entries: [c1, c0])
    check("inside a group the child lane decides", ids(VideoResolver.layers(at: 1, in: idx)) == ["/v26.mov", "/v25.mov"])

    // MARK: - The cap is applied AFTER the window filtering

    // Three pictures on lanes 0, 1, 2; the FRONT one (lane 0) lives in a group whose window is
    // elsewhere. Capping before filtering would keep lanes 0 and 1 and show only lane 1.
    let farG = VideoGroupWindow(lane: 0, start: 100, duration: 5)
    let hidden = pic(30, lane: 0, start: 0, duration: 200, ancestors: [farG])
    let p1 = pic(31, lane: 1, start: 0, duration: 10)
    let p2b = pic(32, lane: 2, start: 0, duration: 10)
    idx = VideoObjectIndex(entries: [hidden, p1, p2b])
    check("the cap counts only what is visible: both remaining pictures are kept",
          ids(VideoResolver.layers(at: 5, in: idx)) == ["/v32.mov", "/v31.mov"])

    // MARK: - Same path, deterministic

    let t1 = pic(40, lane: 0, start: 0, duration: 10)
    let t2 = pic(41, lane: 0, start: 0, duration: 10)
    let t3 = pic(42, lane: 0, start: 0, duration: 10)
    idx = VideoObjectIndex(entries: [t1, t2, t3])
    check("a tie falls back on the index order", ids(VideoResolver.layers(at: 1, in: idx)) == ["/v41.mov", "/v40.mov"])

    check("an empty index answers nothing", VideoResolver.layers(at: 1, in: VideoObjectIndex()).isEmpty)

    print("\n\(total - fails.count)/\(total) passed")
    if !fails.isEmpty {
        print("FAILURES:")
        for f in fails { print(" - \(f)") }
        exit(1)
    }
  }
}
