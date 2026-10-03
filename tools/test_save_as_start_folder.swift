// Where the Save As panel opens (`Shared/SaveAsStartFolder.swift`), asserted with no screen.
//
//     swiftc -parse-as-library ../objekat/Shared/SaveAsStartFolder.swift test_save_as_start_folder.swift -o /tmp/saveasstart && /tmp/saveasstart
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) } else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

@main struct Runner { static func main() {
    let everything: (URL) -> Bool = { _ in true }
    let nothing: (URL) -> Bool = { _ in false }
    let file = URL(fileURLWithPath: "/Music/Song/Song V1.objekat")
    let last = URL(fileURLWithPath: "/Music/Other")

    check("a saved project: its own folder",
          SaveAsStartFolder.resolve(projectURL: file, lastProjectFolder: nil, isUsableFolder: everything)?.path == "/Music/Song")
    check("a saved project wins over the last folder seen",
          SaveAsStartFolder.resolve(projectURL: file, lastProjectFolder: last, isUsableFolder: everything)?.path == "/Music/Song")
    check("untitled: the PARENT of the last project folder (a sibling, never inside it)",
          SaveAsStartFolder.resolve(projectURL: nil, lastProjectFolder: last, isUsableFolder: everything)?.path == "/Music")
    check("untitled, nothing seen yet: no opinion",
          SaveAsStartFolder.resolve(projectURL: nil, lastProjectFolder: nil, isUsableFolder: everything) == nil)
    check("a vanished project folder falls back on the last folder's parent",
          SaveAsStartFolder.resolve(projectURL: file, lastProjectFolder: last,
                                    isUsableFolder: { $0.path != "/Music/Song" })?.path == "/Music")
    check("nothing usable: no opinion",
          SaveAsStartFolder.resolve(projectURL: file, lastProjectFolder: last, isUsableFolder: nothing) == nil)
    check("a legacy .json is read the same way",
          SaveAsStartFolder.resolve(projectURL: URL(fileURLWithPath: "/A/B/p.json"), lastProjectFolder: nil,
                                    isUsableFolder: everything)?.path == "/A/B")

    // The real disk check.
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("saveas-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let f = tmp.appendingPathComponent("x.objekat")
    check("real folder: used", SaveAsStartFolder.resolve(projectURL: f, lastProjectFolder: nil)?.path == tmp.path)
    try? FileManager.default.removeItem(at: tmp)
    check("real folder, deleted: no opinion", SaveAsStartFolder.resolve(projectURL: f, lastProjectFolder: nil) == nil)

    print("\n\(total) assertions, \(fails.count) failed")
    if !fails.isEmpty { exit(1) }
    print("ALL PASS")
} }
