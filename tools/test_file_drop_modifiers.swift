// What the modifiers say about a file drop (`Shared/FileDropModifiers.swift`), asserted with no screen.
//
//     swiftc -parse-as-library ../objekat/Shared/FileDropModifiers.swift test_file_drop_modifiers.swift \
//         -o /tmp/filedropmods && /tmp/filedropmods
//
// Exit: 0 if every assertion passes, 1 otherwise.

import AppKit

var fails: [String] = []
var total = 0
func check(_ label: String, _ ok: Bool) {
    total += 1
    if ok { print("ok    " + label) } else { fails.append(label); print("FAIL  " + label) }
}

@main struct Runner { static func main() {
    typealias F = FileDropModifiers
    check("snap on, no modifier: snaps", F.fileDropSnapOn(snapEnabled: true, flags: []))
    check("snap off, no modifier: does not snap", !F.fileDropSnapOn(snapEnabled: false, flags: []))
    check("snap on, ⌘: does not snap", !F.fileDropSnapOn(snapEnabled: true, flags: .command))
    check("snap off, ⌘: snaps", F.fileDropSnapOn(snapEnabled: false, flags: .command))
    check("⌥ alone does not touch the snap (on)", F.fileDropSnapOn(snapEnabled: true, flags: .option))
    check("⌥ alone does not touch the snap (off)", !F.fileDropSnapOn(snapEnabled: false, flags: .option))
    check("⌘⌥ inverts like ⌘ (on)", !F.fileDropSnapOn(snapEnabled: true, flags: [.command, .option]))
    check("⌘⇧ inverts like ⌘ (off)", F.fileDropSnapOn(snapEnabled: false, flags: [.command, .shift]))

    print("\n\(total - fails.count)/\(total) ok")
    exit(fails.isEmpty ? 0 : 1)
} }
