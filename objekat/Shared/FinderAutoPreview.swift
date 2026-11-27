import Foundation

/// The rules of the Finder tab's AUTOMATIC preview — what plays when the ↑ / ↓ arrows walk the list —
/// kept apart from the view model so that they can be compiled and run alone
/// (`tools/test_finder_auto_preview.swift`).
///
/// THE MODE. The arrows play nothing by themselves: the automatic preview is a MODE that a hand turns
/// on by launching a preview (the second click on a file, or the play button) and that stays on while
/// the hand walks the list — even when the sound it started has ended by itself ("locked"). Every file
/// the cursor then lands on plays, after a short pause. What ends the mode is a stop the hand (or the
/// view) asked for: a stop button or a click that stops the sound, leaving the folder, leaving the tab.
/// What does NOT end it is a stop the preview made by itself: the end of the file, or the change of
/// file the arrows themselves cause. The mode is NOT a preference: it is never saved, and starts off.
///
/// The preview is a plain `AVAudioPlayer`, stopped by a timer at point O. Three more things had to be
/// settled once the arrows start it by themselves:
/// - the arrows can go faster than the ear: the start waits a short DEBOUNCE, and is dropped when
///   the cursor has moved on (or onto a folder) by the time it elapses;
/// - the stop timer of a preview that has been stopped meanwhile must NOT cut the next one: every
///   stop bumps a GENERATION, and a timer only acts on the generation it was armed in;
/// - a click or a scrub in the mini player's waveform can place the head ANYWHERE, inside I–O or
///   not: the sound then ends at point O if the head is before it, at the end of the file otherwise,
///   and that end is RE-ARMED at every move of the head (a stop timer armed for the old position
///   would cut the sound at the wrong instant);
/// - the file's length may not be known yet (the mini player's `pointO` is 0 until the media has
///   loaded): the end then comes from the player itself, never "now".
enum FinderAutoPreview {

    /// The pause after the last arrow press before a file starts to play, in seconds.
    static let debounce: TimeInterval = 0.12

    /// How a preview came to an end. `explicit`: asked for (a stop, a click that stops the sound, a folder
    /// left, a tab left) — the mode goes off. `automatic`: the end of the file, or one file giving way to
    /// the next — the mode stays.
    enum Stop { case explicit, automatic }

    /// The mode itself: a flag and the only ways to move it.
    struct Mode: Equatable {
        private(set) var isOn = false

        /// A preview was started. Only a START BY THE HAND turns the mode on; a start the mode made itself
        /// (an arrow) leaves it as it is.
        mutating func started(byHand: Bool) {
            if byHand { isOn = true }
        }

        /// A preview was stopped, or was going to be replaced.
        mutating func stopped(_ stop: Stop) {
            if stop == .explicit { isOn = false }
        }

        /// Whether an arrow that has landed on a row plans a start at all: the mode is on and the row is
        /// a FILE (a folder plays nothing, and the mode goes on past it).
        func shouldSchedule(isDirectory: Bool) -> Bool { isOn && !isDirectory }

        /// Whether the start that was planned for `nodeID` may go ahead once the debounce has elapsed.
        /// Everything must still be true: the mode is on, the wait was not cancelled, the cursor is
        /// still on that row, and the row is a FILE.
        func shouldStart(cancelled: Bool, cursorID: UUID?, nodeID: UUID, isDirectory: Bool) -> Bool {
            isOn && !cancelled && !isDirectory && cursorID == nodeID
        }
    }

    /// Whether a stop timer armed in generation `armed` still applies now (`current` being the
    /// generation of the preview that is up, bumped by every stop).
    static func timerApplies(armed: Int, current: Int) -> Bool { armed == current }

    /// Where a preview that STARTS (or whose head is placed) at `start` ends, in seconds of the file:
    /// point O when it lies after `start`, otherwise the end of the file as the player reports it.
    /// That one rule covers the play button (`start` = point I), a click inside I–O (up to O), a click
    /// before I (up to O) and a click past O (to the end of the file).
    static func endPoint(from start: Double, pointO: Double, playerDuration: Double) -> Double {
        pointO > start ? pointO : playerDuration
    }

    /// How long the stop timer waits: from `start` to the end. Never negative.
    static func remaining(from start: Double, pointO: Double, playerDuration: Double) -> Double {
        max(0, endPoint(from: start, pointO: pointO, playerDuration: playerDuration) - start)
    }

    /// The same, for a preview that starts at point I.
    static func endPoint(pointI: Double, pointO: Double, playerDuration: Double) -> Double {
        endPoint(from: pointI, pointO: pointO, playerDuration: playerDuration)
    }

    static func remaining(pointI: Double, pointO: Double, playerDuration: Double) -> Double {
        remaining(from: pointI, pointO: pointO, playerDuration: playerDuration)
    }

    /// The instant of the file a point of the waveform stands for: `x` px from its left edge, the
    /// waveform being `width` px wide for `duration` seconds. Clamped to the file.
    static func headTime(x: Double, width: Double, duration: Double) -> Double {
        guard width > 0, duration > 0, x.isFinite else { return 0 }
        return min(max(x / width, 0), 1) * duration
    }

    /// The row the previous / next button goes to: the nearest FILE from `current` in the direction
    /// of `step` (+1 / −1), folders passed over (never entered, never stopped on). nil at either end
    /// of the list, or when `current` is not a row.
    static func adjacentFileIndex(isDirectory: [Bool], from current: Int, step: Int) -> Int? {
        guard step != 0, isDirectory.indices.contains(current) else { return nil }
        var i = current + (step > 0 ? 1 : -1)
        while isDirectory.indices.contains(i) {
            if !isDirectory[i] { return i }
            i += step > 0 ? 1 : -1
        }
        return nil
    }
}
