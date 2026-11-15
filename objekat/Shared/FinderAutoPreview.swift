import Foundation

/// The rules of the Finder tab's AUTOMATIC preview — what plays when the ↑ / ↓ arrows walk the list —
/// kept apart from the view model so that they can be compiled and run alone
/// (`tools/test_finder_auto_preview.swift`).
///
/// The preview is a plain `AVAudioPlayer`, stopped by a timer at point O. Three things had to be
/// settled once the arrows start it by themselves:
/// - the arrows can go faster than the ear: the start waits a short DEBOUNCE, and is dropped when
///   the cursor has moved on (or onto a folder) by the time it elapses;
/// - the stop timer of a preview that has been stopped meanwhile must NOT cut the next one: every
///   stop bumps a GENERATION, and a timer only acts on the generation it was armed in;
/// - the file's length may not be known yet (the mini player's `pointO` is 0 until the media has
///   loaded): the end then comes from the player itself, never "now".
enum FinderAutoPreview {

    /// The pause after the last arrow press before a file starts to play, in seconds.
    static let debounce: TimeInterval = 0.12

    /// Whether the start that was scheduled for `nodeID` may go ahead once the debounce has elapsed.
    /// Everything must still be true: the feature is on, the wait was not cancelled, the cursor is
    /// still on that row, and the row is a FILE.
    static func shouldStart(enabled: Bool, cancelled: Bool,
                            cursorID: UUID?, nodeID: UUID, isDirectory: Bool) -> Bool {
        enabled && !cancelled && !isDirectory && cursorID == nodeID
    }

    /// Whether a stop timer armed in generation `armed` still applies now (`current` being the
    /// generation of the preview that is up, bumped by every stop).
    static func timerApplies(armed: Int, current: Int) -> Bool { armed == current }

    /// Where the preview ends, in seconds of the file: point O when the hand (or the file's length)
    /// has set one after point I, otherwise the end of the file as the player reports it.
    static func endPoint(pointI: Double, pointO: Double, playerDuration: Double) -> Double {
        pointO > pointI ? pointO : playerDuration
    }

    /// How long the stop timer waits: from point I to the end. Never negative.
    static func remaining(pointI: Double, pointO: Double, playerDuration: Double) -> Double {
        max(0, endPoint(pointI: pointI, pointO: pointO, playerDuration: playerDuration) - pointI)
    }
}
