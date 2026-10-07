// What a remembering canvas keeps besides its values (the mode and the active tool), asserted with no
// screen. `CanvasRememberedState` depends on Foundation alone — the whole reason it is a unit of its own.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/ScriptCanvasMemory.swift test_script_canvas_memory.swift \
//         -o /tmp/scm && /tmp/scm
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { print("FAIL  " + label + (detail.isEmpty ? "" : "  [" + detail + "]")); fails.append(label) }
}

@main struct Test {
    static func main() {
        let tools = ["rect", "brush"]
        func restored(_ mode: String?, _ tool: String?, modes: Bool = true, ids: [String] = tools) -> CanvasRememberedState {
            CanvasRememberedState.restored(CanvasRememberedState(mode: mode, tool: tool), modesEnabled: modes, toolIDs: ids)
        }

        check("a fitting mode and tool come back", restored("select", "brush") == CanvasRememberedState(mode: "select", tool: "brush"))
        check("instant comes back too", restored("instant", "rect").mode == "instant")
        check("nothing remembered, nothing restored", restored(nil, nil) == CanvasRememberedState(mode: nil, tool: nil))
        check("a mode is ignored when the canvas has no modes", restored("select", "rect", modes: false).mode == nil)
        check("the tool is kept when the canvas has no modes", restored("select", "rect", modes: false).tool == "rect")
        check("an unknown mode name is ignored", restored("zoom", "rect").mode == nil)
        check("a tool that no longer exists is ignored", restored("select", "eraser").tool == nil)
        check("a tool with no tool declared is ignored", restored("select", "rect", ids: []).tool == nil)
        check("the mode survives a stale tool", restored("select", "eraser").mode == "select")
        check("the tool survives a stale mode", restored("zoom", "brush").tool == "brush")
        check("ids are compared exactly (no case folding)", restored(nil, "Brush").tool == nil)

        // The project's own settings (revision 5): the monitoring level.
        typealias P = CanvasProjectSettings
        check("the range is -20...+20 dB", P.monitorRange == -20...20)
        check("a level inside the range is kept", P.clampedMonitor(6.5) == 6.5 && P.clampedMonitor(-12) == -12)
        check("a level outside is clamped", P.clampedMonitor(35) == 20 && P.clampedMonitor(-99) == -20)
        check("a level is rounded to 0.1 dB", P.clampedMonitor(3.14159) == 3.1 && P.clampedMonitor(-0.04) == 0)
        check("nothing stored opens at 0 dB", P.monitor(of: nil) == 0 && P.monitor(of: P()) == 0)
        check("a stored level opens as it was", P.monitor(of: P(monitorDB: -7.5)) == -7.5)
        check("a stored level out of range (a hand-edited file) is clamped", P.monitor(of: P(monitorDB: 99)) == 20)
        check("a stored NaN opens at 0 dB", P.monitor(of: P(monitorDB: .nan)) == 0)
        var reg: [String: P] = [:]
        reg = P.updating(reg, key: "spectral-editor", monitorDB: 4)
        check("setting a level writes the entry", reg["spectral-editor"] == P(monitorDB: 4))
        reg = P.updating(reg, key: "other", monitorDB: -3)
        check("another key has an entry of its own", reg.count == 2 && reg["other"]?.monitorDB == -3)
        reg = P.updating(reg, key: "spectral-editor", monitorDB: 0)
        check("back to 0 dB writes nothing (the entry goes)", reg["spectral-editor"] == nil && reg.count == 1)
        check("0 dB on an empty registry stays empty", P.updating([:], key: "k", monitorDB: 0).isEmpty)
        let data = try! JSONEncoder().encode(["spectral-editor": P(monitorDB: 6)])
        let back = try! JSONDecoder().decode([String: P].self, from: data)
        check("it round-trips through JSON", back["spectral-editor"] == P(monitorDB: 6))
        check("an entry with no level decodes (a future key is ignored)",
              (try? JSONDecoder().decode(P.self, from: Data("{\"somethingElse\": 1}".utf8)))?.monitorDB == nil)

        check("a level of the wrong type is ignored, not a decode error (a hand-edited project still opens)",
              (try? JSONDecoder().decode(P.self, from: Data("{\"monitorDB\": \"loud\"}".utf8))) == P())
        check("a whole registry survives one bad entry",
              (try? JSONDecoder().decode([String: P].self, from: Data("{\"a\": {\"monitorDB\": 3}, \"b\": {\"monitorDB\": [1]}}".utf8)))
              == ["a": P(monitorDB: 3), "b": P()])

        print("\(total - fails.count)/\(total) passed")
        exit(fails.isEmpty ? 0 : 1)
    }
}
