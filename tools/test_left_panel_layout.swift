// The left panel's width and tab rules — `LeftPanelLayout` / `LeftPanelState`
// (`Shared/LeftPanelLayout.swift`), Foundation only, asserted with no screen.
//
//     swiftc -parse-as-library ../objekat/Shared/LeftPanelLayout.swift \
//         test_left_panel_layout.swift -o /tmp/lpl && /tmp/lpl
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

typealias L = LeftPanelLayout

func decode(_ json: String) -> LeftPanelState? {
    try? JSONDecoder().decode(LeftPanelState.self, from: Data(json.utf8))
}

@main
enum LeftPanelLayoutTest {
  static func main() {

    // MARK: - clampedWidth

    check("in range: unchanged", L.clampedWidth(400) == 400)
    check("under the minimum → 250", L.clampedWidth(100) == 250)
    check("over the maximum → 720", L.clampedWidth(5000) == 720)
    check("the bounds themselves are kept", L.clampedWidth(250) == 250 && L.clampedWidth(720) == 720)
    check("NaN → the default", L.clampedWidth(.nan) == L.defaultWidth)
    check("infinity → the default", L.clampedWidth(.infinity) == L.defaultWidth)
    check("negative → 250", L.clampedWidth(-30) == 250)

    // The container lowers the ceiling so the timeline keeps 420 (+ the 5 pt handle).
    check("wide window: the cap stays 720", L.clampedWidth(700, containerWidth: 2000) == 700)
    check("1000 pt window: at most 1000 − 420 − 5 = 575",
          L.clampedWidth(700, containerWidth: 1000) == 575)
    check("700 pt window (the minimum): at most 275", L.clampedWidth(700, containerWidth: 700) == 275)
    check("a window too narrow for the minimum keeps the minimum",
          L.clampedWidth(300, containerWidth: 500) == 250)
    check("an unknown container (0) is not a constraint", L.clampedWidth(600, containerWidth: 0) == 600)

    // MARK: - draggedWidth

    check("drag right by 50", L.draggedWidth(startWidth: 300, travelX: 50, containerWidth: 2000) == 350)
    check("drag left by 100", L.draggedWidth(startWidth: 300, travelX: -100, containerWidth: 2000) == 250)
    check("drag far right stops at the cap", L.draggedWidth(startWidth: 300, travelX: 9999, containerWidth: 2000) == 720)
    check("drag far right in a 1000 pt window stops at 575",
          L.draggedWidth(startWidth: 300, travelX: 9999, containerWidth: 1000) == 575)
    check("no travel, no change", L.draggedWidth(startWidth: 333, travelX: 0, containerWidth: 2000) == 333)

    // MARK: - resolved: the state a document starts from

    let saved = LeftPanelState(width: 480, tab: .sons)
    check("a saved state is used, whatever the app remembers",
          L.resolved(saved: saved, appWidth: 300) == saved)
    check("a saved width out of range is brought in range",
          L.resolved(saved: LeftPanelState(width: 9000, tab: .objet), appWidth: nil)
            == LeftPanelState(width: 720, tab: .objet))
    check("no saved state: the app's last width, the default tab",
          L.resolved(saved: nil, appWidth: 410) == LeftPanelState(width: 410, tab: .liste))
    check("no saved state, no preference: the default width and tab",
          L.resolved(saved: nil, appWidth: nil) == LeftPanelState(width: 300, tab: .liste))
    check("no saved state, a silly preference is brought in range",
          L.resolved(saved: nil, appWidth: 50) == LeftPanelState(width: 250, tab: .liste))
    check("every tab survives resolving",
          LeftPanelTabID.allCases.allSatisfy {
              L.resolved(saved: LeftPanelState(width: 300, tab: $0), appWidth: nil).tab == $0
          })

    // MARK: - Codable (the project file)

    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    let json = String(data: try! enc.encode(LeftPanelState(width: 412.5, tab: .entrees)), encoding: .utf8)!
    check("encodes as {tab, width} with the tab's raw name", json == #"{"tab":"entrees","width":412.5}"#, json)
    check("round trip", decode(json) == LeftPanelState(width: 412.5, tab: .entrees))
    check("an unknown tab name falls back on the default tab, keeps the width",
          decode(#"{"width":333,"tab":"mixer"}"#) == LeftPanelState(width: 333, tab: .liste))
    check("a missing width falls back on the default width, keeps the tab",
          decode(#"{"tab":"objet"}"#) == LeftPanelState(width: 300, tab: .objet))
    check("a garbled width (a string) falls back on the default width",
          decode(#"{"width":"wide","tab":"sons"}"#) == LeftPanelState(width: 300, tab: .sons))
    check("an empty object is the defaults", decode("{}") == LeftPanelState(width: 300, tab: .liste))

    print("\n\(total - fails.count)/\(total) passed")
    exit(fails.isEmpty ? 0 : 1)
  }
}
