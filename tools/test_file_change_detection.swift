// "A source file changed on disk" — the decision behind the silent reload, asserted with no
// screen. `FileChangeDetection` (`Shared/FileChangeDetection.swift`) has no model, no engine and
// no view behind it, which is why it can be compiled and run alone, like `CutSelection` /
// `PathRelink` / `SendColumns` before it.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/FileChangeDetection.swift test_file_change_detection.swift \
//         -o /tmp/fcd && /tmp/fcd
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

func id(_ size: Int64, _ mtime: Double?) -> SourceFileIdentity { SourceFileIdentity(size: size, mtime: mtime) }

@main
enum FileChangeDetectionTest {
  static func main() {

    // MARK: - differs(from:)

    check("same size, same time: not different", !id(100, 5).differs(from: id(100, 5)))
    check("mtime only: different", id(100, 6).differs(from: id(100, 5)))
    check("size only: different", id(101, 5).differs(from: id(100, 5)))
    check("size and time: different", id(101, 6).differs(from: id(100, 5)))
    check("sub-second mtime is a difference", id(100, 5.25).differs(from: id(100, 5.0)))
    check("a size-only baseline, same size: not different", !id(100, 5).differs(from: id(100, nil)))
    check("a size-only baseline, other size: different", id(101, 5).differs(from: id(100, nil)))
    check("a size-only baseline on the other side behaves the same",
          !id(100, nil).differs(from: id(100, 5)) && id(99, nil).differs(from: id(100, 5)))

    // MARK: - changedPaths

    let a = "/p/a.wav", b = "/p/b.wav", c = "/p/c.wav"
    let known: [String: SourceFileIdentity] = [a: id(100, 5), b: id(200, 5), c: id(300, 5)]

    // Nothing changed.
    check("nothing changed: nothing out",
          FileChangeDetection.changedPaths(objectPaths: [a, b, c], before: known,
                                           after: [a: id(100, 5), b: id(200, 5), c: id(300, 5)]).isEmpty)

    // mtime only.
    check("mtime only: the path comes out",
          FileChangeDetection.changedPaths(objectPaths: [a, b, c], before: known,
                                           after: [a: id(100, 5), b: id(200, 9), c: id(300, 5)]) == [b])

    // size only.
    check("size only: the path comes out",
          FileChangeDetection.changedPaths(objectPaths: [a, b, c], before: known,
                                           after: [a: id(101, 5), b: id(200, 5), c: id(300, 5)]) == [a])

    // several at once keep the project's order.
    check("several changed: first-seen order",
          FileChangeDetection.changedPaths(objectPaths: [c, a, b], before: known,
                                           after: [a: id(1, 5), b: id(2, 5), c: id(3, 5)]) == [c, a, b])

    // vanished: not a change (that is MissingFiles' business).
    let gone: [String: SourceFileIdentity?] = [a: nil, b: id(200, 5), c: id(300, 5)]
    check("a vanished file is not 'changed'",
          FileChangeDetection.changedPaths(objectPaths: [a, b, c], before: known, after: gone).isEmpty)

    // a path missing from `after` altogether (never asked) is not a change either.
    check("a path absent from the answer is not 'changed'",
          FileChangeDetection.changedPaths(objectPaths: [a], before: known, after: [:]).isEmpty)

    // unknown path: learned, not reloaded on a guess.
    check("a path with no earlier identity is not 'changed'",
          FileChangeDetection.changedPaths(objectPaths: [a, "/p/new.wav"], before: known,
                                           after: [a: id(100, 5), "/p/new.wav": id(1, 1)]).isEmpty)

    // several objects on one path → ONE reload.
    check("four objects on one path: the path comes out once",
          FileChangeDetection.changedPaths(objectPaths: [a, a, b, a, a], before: known,
                                           after: [a: id(999, 5), b: id(200, 5)]) == [a])
    check("two objects on one UNCHANGED path: nothing",
          FileChangeDetection.changedPaths(objectPaths: [a, a], before: known,
                                           after: [a: id(100, 5)]).isEmpty)

    // empty paths ignored.
    check("an empty path is ignored",
          FileChangeDetection.changedPaths(objectPaths: ["", a], before: ["": id(1, 1), a: id(100, 5)],
                                           after: ["": id(2, 2), a: id(101, 5)]) == [a])

    // size-only baseline from the model (open): size equal → nothing, size different → changed.
    let baseline: [String: SourceFileIdentity] = [a: id(100, nil), b: id(200, nil)]
    check("open baseline: same size → nothing",
          FileChangeDetection.changedPaths(objectPaths: [a, b], before: baseline,
                                           after: [a: id(100, 77), b: id(200, 77)]).isEmpty)
    check("open baseline: other size → the path",
          FileChangeDetection.changedPaths(objectPaths: [a, b], before: baseline,
                                           after: [a: id(100, 77), b: id(201, 77)]) == [b])

    // MARK: - isAppWritten / scanPaths

    let folders = ["/proj/samples/consolidate", "/proj/samples/objects", "/proj/samples/sources"]
    check("a file under samples/consolidate is app-written",
          FileChangeDetection.isAppWritten("/proj/samples/consolidate/x_v2.wav", under: folders))
    check("a file under samples/objects is app-written",
          FileChangeDetection.isAppWritten("/proj/samples/objects/x.wav", under: folders))
    check("a file under samples/sources is app-written",
          FileChangeDetection.isAppWritten("/proj/samples/sources/take.wav", under: folders))
    check("a sibling folder with the same prefix is NOT app-written (whole components)",
          !FileChangeDetection.isAppWritten("/proj/samples/consolidate-old/x.wav", under: folders))
    check("a user sample is not app-written",
          !FileChangeDetection.isAppWritten("/Users/me/Sons/kick.wav", under: folders))
    check("the folder itself (no file) is not matched as a file under it",
          !FileChangeDetection.isAppWritten("/proj/samples/consolidate", under: folders))
    check("trailing slash on a folder is tolerated",
          FileChangeDetection.isAppWritten("/proj/samples/objects/x.wav", under: ["/proj/samples/objects/"]))
    check("no folders: nothing is app-written",
          !FileChangeDetection.isAppWritten("/proj/samples/objects/x.wav", under: []))

    let scanned = FileChangeDetection.scanPaths(
        objectPaths: ["/s/a.wav", "", "/s/b.wav", "/s/a.wav", "/proj/samples/objects/x.wav", "/s/b.wav"],
        appWrittenFolders: folders)
    check("scanPaths: distinct, non-empty, not app-written, first-seen order",
          scanned == ["/s/a.wav", "/s/b.wav"], "\(scanned)")

    // MARK: - identity(ofFileAt:) against the real disk

    let dir = NSTemporaryDirectory() + "fcd-test-\(getpid())/"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let f = dir + "one.wav"
    FileManager.default.createFile(atPath: f, contents: Data(repeating: 1, count: 1000))
    let first = FileChangeDetection.identity(ofFileAt: f)
    check("identity: an existing file answers its size", first?.size == 1000, "\(String(describing: first))")
    check("identity: an existing file answers a time", first?.mtime != nil)
    check("identity: a missing file answers nil", FileChangeDetection.identity(ofFileAt: dir + "nope.wav") == nil)
    check("identity: a directory answers nil (not a file)", FileChangeDetection.identity(ofFileAt: dir) == nil)

    // mtime only, same size
    try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 3600)], ofItemAtPath: f)
    let touched = FileChangeDetection.identity(ofFileAt: f)
    check("identity: touching changes the time and not the size",
          touched?.size == 1000 && touched?.mtime != first?.mtime)
    check("identity: ... which differs() sees", touched.map { $0.differs(from: first!) } == true)

    // size only (restore the time)
    try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: first!.mtime!)], ofItemAtPath: f)
    try? Data(repeating: 2, count: 1500).write(to: URL(fileURLWithPath: f))
    try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: first!.mtime!)], ofItemAtPath: f)
    let grown = FileChangeDetection.identity(ofFileAt: f)
    check("identity: a rewrite to another size is seen", grown?.size == 1500 && grown!.differs(from: first!))

    // end to end on disk: stat twice, one file touched, one not.
    let g = dir + "two.wav"
    FileManager.default.createFile(atPath: g, contents: Data(repeating: 3, count: 10))
    let beforeDisk = FileChangeDetection.identities(ofFilesAt: [f, g]).compactMapValues { $0 }
    try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 7200)], ofItemAtPath: g)
    let afterDisk = FileChangeDetection.identities(ofFilesAt: [f, g])
    check("on disk: only the touched file comes out",
          FileChangeDetection.changedPaths(objectPaths: [f, g, g], before: beforeDisk, after: afterDisk) == [g])
    try? FileManager.default.removeItem(atPath: g)
    check("on disk: the removed file is not 'changed'",
          FileChangeDetection.changedPaths(objectPaths: [f, g], before: beforeDisk,
                                           after: FileChangeDetection.identities(ofFilesAt: [f, g])).isEmpty)

    print("\n\(total - fails.count)/\(total) passed")
    if !fails.isEmpty {
        print("FAILURES:")
        for f in fails { print(" - \(f)") }
        exit(1)
    }
  }
}
