// The video resolver (plan-video §4.3): "at timeline time t, which pictures, and which instant of
// its file?" — asserted with no screen, no engine and no model. `Shared/VideoTimeMap.swift` is a pure
// function over a small index, which is why it can be compiled and run alone.
//
// What it pins: a group's WINDOW (nested ones included), the LOOP fold of a group (IN negative too,
// the right half of a cut looped group), speed and offset, a negative start, an infinite group, the
// picture's own loop, the front-most-lane order on the PATH of lanes (not on a display lane), the
// cap of two layers applied AFTER the window filtering, and the silence (`isMuted`: the picture's own
// or any ancestor's, at any depth) that hides a picture before it counts in the cap.
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
         muted: Bool = false, fadeIn: Double = 0, fadeOut: Double = 0,
         curveIn: FadeCurve = .linear, curveOut: FadeCurve = .linear, reversed: Bool = false,
         ancestors: [VideoGroupWindow] = []) -> VideoPictureEntry {
    VideoPictureEntry(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
                      filePath: "/v\(n).mov", lane: lane, start: start, duration: duration,
                      sourceOffset: offset, speedRatio: speed, isReversed: reversed, fileDuration: fileDuration,
                      loop: loop, nominalFPS: 30, isMuted: muted, fadeIn: fadeIn, fadeOut: fadeOut,
                      fadeInCurve: curveIn, fadeOutCurve: curveOut, ancestors: ancestors)
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
    check("opacity is 1 without any fade", VideoResolver.layer(of: a, at: 8)?.opacity == 1)

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

    // MARK: - Silence hides the picture (Q7): the object's own, any ancestor's, at any depth

    let okG = VideoGroupWindow(lane: 0, start: 0, duration: 10)
    let mutedG = VideoGroupWindow(lane: 0, start: 0, duration: 10, isMuted: true)
    check("a picture with nothing muted is shown", VideoResolver.layer(of: pic(16, ancestors: [okG]), at: 5) != nil)
    check("a muted picture shows nothing", VideoResolver.layer(of: pic(16, muted: true), at: 5) == nil)
    check("a muted picture at the root shows nothing, whatever the instant",
          VideoResolver.layer(of: pic(16, start: 0, duration: 10, muted: true), at: 0) == nil)
    check("a picture under a muted parent shows nothing",
          VideoResolver.layer(of: pic(17, ancestors: [mutedG]), at: 5) == nil)
    check("a muted ROOT group hides a picture two levels down",
          VideoResolver.layer(of: pic(18, ancestors: [mutedG, okG]), at: 5) == nil)
    check("a muted MIDDLE group hides it too",
          VideoResolver.layer(of: pic(18, ancestors: [okG, mutedG, okG]), at: 5) == nil)
    let mutedInf = VideoGroupWindow(lane: 0, start: 0, duration: 0, isInfinite: true, isMuted: true)
    check("a muted INFINITE group hides its picture", VideoResolver.layer(of: pic(19, ancestors: [mutedInf]), at: 5) == nil)
    check("the same infinite group, not muted, shows it",
          VideoResolver.layer(of: pic(19, ancestors: [VideoGroupWindow(lane: 0, start: 0, duration: 0, isInfinite: true)]), at: 5) != nil)
    check("a muted picture in a muted group shows nothing",
          VideoResolver.layer(of: pic(16, muted: true, ancestors: [mutedG]), at: 5) == nil)

    // A silenced picture does not take a place among the two layers (Q-F8): the filtering comes first.
    let front = pic(50, lane: 0, muted: true)
    let secondP = pic(51, lane: 1)
    let thirdP = pic(52, lane: 2)
    let capped = VideoResolver.layers(at: 5, in: VideoObjectIndex(entries: [front, secondP, thirdP]))
    check("a silenced front picture is filtered BEFORE the cap of two: the other two are kept",
          ids(capped) == ["/v52.mov", "/v51.mov"], "\(ids(capped))")

    // MARK: - Fades are opacity (Q6): the sound's own curve, the gain IS the opacity

    func op(_ e: VideoPictureEntry, _ t: Double) -> Double? { VideoResolver.layer(of: e, at: t)?.opacity }
    let fin = pic(60, start: 10, duration: 10, fadeIn: 1)
    check("fade-in: 0 at the very start", near(op(fin, 10), 0))
    check("fade-in 1 s linear, half-way: 0.5", near(op(fin, 10.5), 0.5))
    check("fade-in: 1 once over", near(op(fin, 11), 1) && near(op(fin, 15), 1))
    let fout = pic(61, start: 10, duration: 10, fadeOut: 2)
    check("fade-out 2 s linear, 1 s before the end: 0.5", near(op(fout, 19), 0.5))
    check("fade-out: untouched before it begins", near(op(fout, 17.9), 1))
    let convex = FadeCurve(shape: .convex, amount: 1)
    let sCurve = FadeCurve(shape: .sCurve, amount: 1)
    let shaped = pic(62, start: 0, duration: 10, fadeIn: 2, fadeOut: 2, curveIn: convex, curveOut: sCurve)
    check("a convex fade-in is FadeCurve.gain, to the digit", near(op(shaped, 0.5), convex.gain(0.25), 1e-12))
    check("an S fade-out reads the PROGRESS of the edge, as the sound does", near(op(shaped, 9), sCurve.gain(0.5), 1e-12))
    check("the picture's curve equals WaveformShaping.fadeEnvelope (one definition)",
          near(op(shaped, 1.3), WaveformShaping.fadeEnvelope(localTime: 1.3, duration: 10, fadeIn: 2, fadeOut: 2,
                                                              curveIn: convex, curveOut: sCurve), 1e-12))
    let rev = pic(63, start: 0, duration: 10, offset: 0, fileDuration: 100, fadeIn: 2, reversed: true)
    check("a reversed picture still fades in at the entry of its window", near(op(rev, 1), 0.5))
    let loopedPic = pic(64, start: 0, duration: 30, loop: VideoLoopRange(start: 1, end: 4), fadeIn: 2)
    check("an own loop does not replay the fade-in at each turn", near(op(loopedPic, 4.5), 1) && near(op(loopedPic, 7.2), 1))
    let negFade = pic(65, start: -2, duration: 6, fadeIn: 2)
    check("a negative start: the fade runs from the object's own start", near(op(negFade, -1), 0.5) && near(op(negFade, 0), 1))

    // The groups' fades multiply into the opacity, root to object.
    let gHalf = VideoGroupWindow(lane: 0, start: 0, duration: 20, fadeIn: 2)
    let pHalf = pic(66, start: 0, duration: 20, fadeIn: 2, ancestors: [gHalf])
    check("group fade 0.5 x object fade 0.5 = 0.25", near(op(pHalf, 1), 0.25))
    let gOnly = pic(67, start: 0, duration: 20, ancestors: [gHalf])
    check("a group fade alone dims the picture below it", near(op(gOnly, 1), 0.5))
    let gOut = VideoGroupWindow(lane: 0, start: 0, duration: 20, fadeOut: 4)
    check("a group fade-out reads the group's end", near(op(pic(68, start: 0, duration: 20, ancestors: [gOut]), 18), 0.5))
    let gLoop = VideoGroupWindow(lane: 0, start: 0, duration: 30, loop: VideoLoopRange(start: 0, end: 5), fadeIn: 4)
    let pLoop = pic(69, start: 0, duration: 5, ancestors: [gLoop])
    check("a looping group fades in once (first turn)", near(op(pLoop, 2), 0.5))
    check("...and does not replay it at the second turn", near(op(pLoop, 7), 1))
    let gInf = VideoGroupWindow(lane: 0, start: 0, duration: 0, isInfinite: true, fadeIn: 4, fadeOut: 4)
    check("an infinite group has no window: its fades are ignored",
          near(op(pic(70, start: 0, duration: 20, ancestors: [gInf]), 1), 1))
    let gMid = VideoGroupWindow(lane: 0, start: 0, duration: 20, fadeIn: 2)
    let gTop = VideoGroupWindow(lane: 0, start: 0, duration: 20, fadeIn: 4)
    check("nested groups multiply: 0.25 x 0.5 = 0.125",
          near(op(pic(71, start: 0, duration: 20, ancestors: [gTop, gMid]), 1), 0.125))

    // A transparent picture is not drawn and takes no place among the two layers (Q-F8).
    let invisibleFront = pic(72, lane: 0, start: 0, duration: 10, fadeIn: 5)
    let vis1 = pic(73, lane: 1, start: 0, duration: 10), vis2 = pic(74, lane: 2, start: 0, duration: 10)
    let atZero = VideoResolver.layers(at: 0, in: VideoObjectIndex(entries: [invisibleFront, vis1, vis2]))
    check("a picture at opacity 0 is filtered BEFORE the cap: the two others are drawn",
          ids(atZero) == ["/v74.mov", "/v73.mov"], "\(ids(atZero))")
    let atTick = VideoResolver.layers(at: 0.5 / 255 * 5, in: VideoObjectIndex(entries: [invisibleFront, vis1, vis2]))
    check("below 1/255 still counts as invisible", ids(atTick) == ["/v74.mov", "/v73.mov"], "\(ids(atTick))")
    let atOne = VideoResolver.layers(at: 1, in: VideoObjectIndex(entries: [invisibleFront, vis1, vis2]))
    check("once visible it takes its place in front (and the rearmost is dropped)",
          ids(atOne) == ["/v73.mov", "/v72.mov"], "\(ids(atOne))")

    // A crossfade: two pictures of one lane overlapping, linear fades over the overlap.
    let cfA = pic(80, lane: 0, start: 0, duration: 10, fadeOut: 2)
    let cfB = pic(81, lane: 0, start: 8, duration: 10, fadeIn: 2)
    var allSum = true
    var seen = 0
    var t = 8.0
    while t < 9.95 {
        let ls = VideoResolver.layers(at: t, in: VideoObjectIndex(entries: [cfA, cfB]))
        if ls.count == 2 { seen += 1; if abs(ls.map(\.opacity).reduce(0, +) - 1) > 1e-9 { allSum = false } }
        else if t > 8.0 + 1e-9 { allSum = false }
        t += 0.1
    }
    check("a crossfade: the opacities of the two pictures sum to 1 over the whole overlap", allSum && seen > 15, "seen \(seen)")

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
