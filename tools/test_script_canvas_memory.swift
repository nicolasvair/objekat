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

        print("\(total - fails.count)/\(total) passed")
        exit(fails.isEmpty ? 0 : 1)
    }
}
