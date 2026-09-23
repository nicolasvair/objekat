// Resolving a consolidated object's wave — the arithmetic, asserted with no screen.
//
// `ConsolidateFolders` depends on nothing at all, which is the whole reason it is a unit of its
// own (@see the header of ConsolidateFolders.swift): `fileExists` is injected, so every case below
// runs with no disk, no model and no project. Four things are pinned down: the priority order
// (consolidate before the legacy objects/ before the Q3 fallback), what happens when the wave is
// nowhere to be found, an absolute-path repli from one legacy folder name to the new one, and the
// candidate list itself for a relative and an absolute path alike.
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/ConsolidateFolders.swift test_consolidate_folders.swift \
//         -o /tmp/tcf && /tmp/tcf
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

@main
enum ConsolidateFoldersTest {
  static func main() {

    let project = URL(fileURLWithPath: "/Users/n/Projects/MyProject")
    let consolidateDir = ConsolidateFolders.consolidateFolder(projectFolder: project)
    let legacyDir       = ConsolidateFolders.legacyFolder(projectFolder: project)

    // MARK: - The folder names themselves

    check("the write folder is samples/consolidate",
          consolidateDir.path == "/Users/n/Projects/MyProject/samples/consolidate")
    check("the legacy folder is samples/objects",
          legacyDir.path == "/Users/n/Projects/MyProject/samples/objects")

    // MARK: - waveCandidates: the priority order

    check("candidates are consolidate, then objects, with no extra dir",
          ConsolidateFolders.waveCandidates(projectFolder: project) == [consolidateDir, legacyDir])

    let extra = URL(fileURLWithPath: "/Volumes/Other/AnotherProject/samples/consolidate")
    check("extraDirs (the Q3 fallback) come LAST",
          ConsolidateFolders.waveCandidates(projectFolder: project, extraDirs: [extra])
            == [consolidateDir, legacyDir, extra])

    // MARK: - resolve: consolidate wins when both are present (cas E18)

    check("both present → consolidate wins",
          ConsolidateFolders.resolve(wave: "bell_v1.wav", projectFolder: project,
                                     fileExists: { $0.deletingLastPathComponent() == consolidateDir
                                                     || $0.deletingLastPathComponent() == legacyDir })
            == consolidateDir)

    check("only the legacy folder has it → objects/ (cas E1, never migrated)",
          ConsolidateFolders.resolve(wave: "bell_v1.wav", projectFolder: project,
                                     fileExists: { $0.deletingLastPathComponent() == legacyDir })
            == legacyDir)

    check("only consolidate has it → consolidate",
          ConsolidateFolders.resolve(wave: "bell_v1.wav", projectFolder: project,
                                     fileExists: { $0.deletingLastPathComponent() == consolidateDir })
            == consolidateDir)

    // MARK: - resolve: the Q3 fallback (an existing instance's own folder — cas E5, Save As to a
    // new folder: the wave was never copied there, but an instance's absolute filePath still
    // points at the OLD folder, which does have it)

    check("neither of the two default folders has it, but the Q3 fallback does",
          ConsolidateFolders.resolve(wave: "bell_v1.wav", projectFolder: project, extraDirs: [extra],
                                     fileExists: { $0.path == extra.path + "/bell_v1.wav" })?.path
            == extra.path)

    check("nothing has it anywhere → nil (the caller falls back on the write folder)",
          ConsolidateFolders.resolve(wave: "bell_v1.wav", projectFolder: project, extraDirs: [extra],
                                     fileExists: { _ in false })
            == nil)

    check("several extraDirs are tried in the order given",
          ConsolidateFolders.resolve(wave: "bell_v1.wav", projectFolder: project,
                                     extraDirs: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")],
                                     fileExists: { $0.path == "/b/bell_v1.wav" })
            == URL(fileURLWithPath: "/b"))

    // MARK: - audioSubfolders: consolidate first, objects still there, sources untouched

    check("audioSubfolders lists consolidate before objects before sources",
          ConsolidateFolders.audioSubfolders == ["samples/consolidate", "samples/objects", "samples/sources"])

    // MARK: - swappedToConsolidate: ProjectPaths' own repli (cas E2/E16)

    check("samples/objects/x.wav swaps to samples/consolidate/x.wav",
          ConsolidateFolders.swappedToConsolidate("samples/objects/x.wav") == "samples/consolidate/x.wav")
    check("a nested path swaps in full",
          ConsolidateFolders.swappedToConsolidate("samples/objects/sub/dir/x.wav")
            == "samples/consolidate/sub/dir/x.wav")
    check("samples/sources/x.wav is untouched — not the legacy folder",
          ConsolidateFolders.swappedToConsolidate("samples/sources/x.wav") == nil)
    check("already samples/consolidate/x.wav is untouched",
          ConsolidateFolders.swappedToConsolidate("samples/consolidate/x.wav") == nil)
    check("a path with no samples/objects/ prefix at all is untouched",
          ConsolidateFolders.swappedToConsolidate("bell.wav") == nil)
    // A component boundary, not a raw prefix match — the same discipline as PathRelink: a
    // sibling folder that merely STARTS WITH "objects" must not be read as the legacy one.
    check("samples/objectsArchive/x.wav (no boundary) is untouched",
          ConsolidateFolders.swappedToConsolidate("samples/objectsArchive/x.wav") == nil)

    // MARK: - Summary

    print("\n\(total - fails.count)/\(total) passed")
    if !fails.isEmpty {
        print("\nFAILED:")
        fails.forEach { print("  - \($0)") }
        exit(1)
    }
    exit(0)
  }
}
