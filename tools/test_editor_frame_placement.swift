import CoreGraphics
import Foundation

// Standalone test of where a plugin editor window reopens (`Shared/EditorFramePlacement.swift`).
// From `tools/`:
//
//     swiftc -parse-as-library -o /tmp/t_efp ../objekat/Shared/EditorFramePlacement.swift \
//         test_editor_frame_placement.swift && /tmp/t_efp

var failures = 0, total = 0
func check(_ ok: Bool, _ what: String) { total += 1; if !ok { failures += 1; print("FAIL: \(what)") } }

typealias P = EditorFramePlacement

@main
struct Main {
    static func main() {
        // AppKit coordinates, y up. A main screen 0…1440 × 0…900 (menu bar already out: top at 875) and a
        // second one to its right, 1440…3360 × -100…980.
        let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let right = CGRect(x: 1440, y: -100, width: 1920, height: 1080)
        let size = CGSize(width: 400, height: 300)

        // A window that is where it was: untouched. The corner remembered is the TOP-left.
        let o1 = P.origin(topLeft: CGPoint(x: 100, y: 700), size: size, visibleFrames: [main, right])
        check(o1 == CGPoint(x: 100, y: 400), "a window on screen reopens where it was (origin = top - height)")

        // The same top-left with a bigger window: the top-left corner stays, the window grows downwards.
        let o2 = P.origin(topLeft: CGPoint(x: 100, y: 700), size: CGSize(width: 500, height: 600), visibleFrames: [main, right])
        check(o2 == CGPoint(x: 100, y: 100), "a bigger editor keeps its top-left corner")

        // On the second screen.
        let o3 = P.origin(topLeft: CGPoint(x: 2000, y: 500), size: size, visibleFrames: [main, right])
        check(o3 == CGPoint(x: 2000, y: 200), "a window on the second screen stays on it")

        // The second screen is gone: the window comes back onto the one left, fully visible.
        let o4 = P.origin(topLeft: CGPoint(x: 2000, y: 500), size: size, visibleFrames: [main])
        check(o4 == CGPoint(x: 1040, y: 200), "its screen unplugged, the window is pulled back inside the screen left (right edge)")
        let o5 = P.origin(topLeft: CGPoint(x: -3000, y: 500), size: size, visibleFrames: [main])
        check(o5 == CGPoint(x: 0, y: 200), "left of every screen: against the left edge")
        let o6 = P.origin(topLeft: CGPoint(x: 100, y: 5000), size: size, visibleFrames: [main])
        check(o6 == CGPoint(x: 100, y: 575), "above every screen: the title bar is at the top of the visible area")
        let o7 = P.origin(topLeft: CGPoint(x: 100, y: -4000), size: size, visibleFrames: [main])
        check(o7 == CGPoint(x: 100, y: 0), "below every screen: the window rests on the bottom edge")

        // Straddling two screens: the one it overlaps most wins and the window is brought inside it.
        let straddle = P.origin(topLeft: CGPoint(x: 1300, y: 500), size: size, visibleFrames: [main, right])
        check(straddle == CGPoint(x: 1440, y: 200), "straddling: the screen with the larger overlap (260 px on the right vs 140 px on the main one) wins")

        // A window bigger than the screen keeps its title bar and its left edge.
        let big = P.origin(topLeft: CGPoint(x: 300, y: 600), size: CGSize(width: 2000, height: 1200), visibleFrames: [main])
        check(big == CGPoint(x: 0, y: -600), "taller and wider than the screen: left edge pulled in, title bar (top 600, inside the area) kept")
        let bigHigh = P.origin(topLeft: CGPoint(x: 300, y: 2000), size: CGSize(width: 2000, height: 1200), visibleFrames: [main])
        check(bigHigh == CGPoint(x: 0, y: -325), "taller than the screen and above it: title bar at the top of the area")

        // No screen known: the corner as it was.
        check(P.origin(topLeft: CGPoint(x: 10, y: 20), size: size, visibleFrames: []) == CGPoint(x: 10, y: -280), "no screen: untouched")

        // Nearest screen when it overlaps none; the first of the list wins a tie.
        let a = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let b = CGRect(x: 3000, y: 0, width: 1000, height: 800)
        check(P.area(for: CGRect(x: 1500, y: 100, width: 100, height: 100), in: [a, b]) == a, "nearer to the first")
        check(P.area(for: CGRect(x: 2800, y: 100, width: 100, height: 100), in: [a, b]) == b, "nearer to the second")
        check(P.area(for: CGRect(x: 1950, y: 100, width: 100, height: 100), in: [a, b]) == a, "equidistant: the first of the list")
        check(P.area(for: CGRect(x: 0, y: 0, width: 10, height: 10), in: []) == nil, "no frame, no area")

        print("\(total - failures)/\(total) editor frame placement checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
