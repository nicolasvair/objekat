// "Importing a folder as a group, hierarchy kept" — the rules, asserted with no disk and no app.
// `FolderImport` (`Shared/FolderImport.swift`) has no model, no view and no engine behind it, which
// is why it can be compiled and run alone, like `LaneCompaction` / `ComposedName`. The listing of
// a folder is INJECTED, so everything below runs against a fake disk.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/FolderImport.swift test_folder_import.swift \
//         -o /tmp/folderimport && /tmp/folderimport
//
// What is pinned: the scan (audio only, hidden and packages and symlinks ignored, empty and
// no-audio folders pruned, Finder order, depth and count bounds) and the plan (stacked: one lane
// per file and per sub-folder; end to end: one lane; a group's bounds are the UNION of its
// children, never infinite).
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

typealias FI = FolderImport

/// A fake disk: folder path → its entries. `nil` for a path that is not a folder.
struct FakeDisk {
    var folders: [String: [FI.DirEntry]] = [:]

    mutating func folder(_ path: String, _ entries: [FI.DirEntry]) { folders[path] = entries }

    func list(_ url: URL) -> [FI.DirEntry]? { folders[url.path] }

    func scan(_ root: String) -> FI.ScanResult {
        FI.scan(root: URL(fileURLWithPath: root), list: { list($0) },
                isAudio: { ["wav", "aif", "mp3"].contains($0) })
    }
}

func file(_ path: String, hidden: Bool = false) -> FI.DirEntry {
    FI.DirEntry(url: URL(fileURLWithPath: path), isDirectory: false, isHidden: hidden)
}
func dir(_ path: String, hidden: Bool = false, package: Bool = false, link: Bool = false) -> FI.DirEntry {
    FI.DirEntry(url: URL(fileURLWithPath: path), isDirectory: true, isHidden: hidden,
                isPackage: package, isSymbolicLink: link)
}

/// The tree with every file lasting `seconds` (the loader fills this in between scan and plan).
func timed(_ node: FI.Node, _ seconds: (String) -> Double) -> FI.Node {
    var n = node
    n.files = n.files.map { FI.FileEntry(url: $0.url, duration: seconds($0.name), size: nil) }
    n.subfolders = n.subfolders.map { timed($0, seconds) }
    return n
}

/// "files | sub-folders" of one level, names only.
func shape(_ n: FI.Node) -> String {
    n.files.map(\.name).joined(separator: ",") + " | " + n.subfolders.map(\.name).joined(separator: ",")
}

func names(_ g: FI.PlannedGroup) -> [String] {
    g.items.map { item in
        switch item {
        case .file(let f):  return f.entry.name
        case .group(let s): return "[" + s.name + "]"
        }
    }
}

@main
enum FolderImportTest {
  static func main() {

    // MARK: - Flat folder

    var flat = FakeDisk()
    flat.folder("/in/drums", [file("/in/drums/take 10.wav"), file("/in/drums/take 2.wav"),
                              file("/in/drums/take 1.wav"), file("/in/drums/notes.txt"),
                              file("/in/drums/Cover.JPG")])
    let r1 = flat.scan("/in/drums")
    check("flat: scanned", r1.root != nil && r1.failure == nil)
    check("flat: audio files only (txt and jpg left out)", r1.root?.files.count == 3)
    check("flat: Finder order (take 2 before take 10)",
          r1.root?.files.map(\.name) == ["take 1", "take 2", "take 10"], "\(r1.root?.files.map(\.name) ?? [])")
    check("flat: the group takes the folder's name", r1.root?.name == "drums")

    let flatPlan = FI.plan(timed(r1.root!, { _ in 2.0 }), start: 5, lane: 3, mode: .stacked)!
    check("flat/stacked: one lane per file", flatPlan.items.map(\.lane) == [0, 1, 2])
    check("flat/stacked: same start", flatPlan.items.allSatisfy { $0.start == 5 })
    check("flat/stacked: the group starts at the drop and lands on the caller's lane",
          flatPlan.start == 5 && flatPlan.lane == 3)
    check("flat/stacked: duration = the longest", flatPlan.duration == 2.0)
    check("flat: counts", flatPlan.fileCount == 3 && flatPlan.groupCount == 1 && flatPlan.laneCount == 3)

    // MARK: - Two levels

    var two = FakeDisk()
    two.folder("/in/kit", [file("/in/kit/a.wav"), dir("/in/kit/room"), dir("/in/kit/close")])
    two.folder("/in/kit/room", [file("/in/kit/room/r1.wav"), file("/in/kit/room/r2.wav")])
    two.folder("/in/kit/close", [file("/in/kit/close/c1.wav"), dir("/in/kit/close/deep")])
    two.folder("/in/kit/close/deep", [file("/in/kit/close/deep/d1.aif")])
    let r2 = two.scan("/in/kit")
    check("two levels: files first, then sub-folders sorted by name",
          r2.root.map { shape($0) } == "a | close,room")
    check("two levels: nesting kept", r2.root?.subfolders.first?.subfolders.first?.name == "deep")
    check("two levels: file count over the whole tree", r2.fileCount == 5)

    let dur: (String) -> Double = { ["a": 4, "r1": 2, "r2": 3, "c1": 1, "d1": 6][$0] ?? 1 }
    let g2 = FI.plan(timed(r2.root!, dur), start: 10, lane: 0, mode: .stacked)!
    check("two levels/stacked: lanes 0..2 (the file, then each sub-folder)",
          names(g2) == ["a", "[close]", "[room]"] && g2.items.map(\.lane) == [0, 1, 2], "\(names(g2))")
    check("two levels/stacked: sub-groups start with the others", g2.items.allSatisfy { $0.start == 10 })
    if case .group(let close) = g2.items[1], case .group(let room) = g2.items[2] {
        check("two levels: a sub-group's lanes are relative to itself",
              room.items.map(\.lane) == [0, 1] && close.items.map(\.lane) == [0, 1])
        check("two levels/stacked: a sub-group lasts its longest child (room 3 s)", room.duration == 3)
        if case .group(let deep) = close.items[1] {
            check("three levels: the deepest group lasts its file (6 s)", deep.duration == 6 && deep.start == 10)
            check("three levels: the parent is the UNION (max of c1=1, deep=6)", close.duration == 6)
        } else { check("three levels: deep is a group", false) }
        check("two levels: root duration = the longest entry (close, 6 s)", g2.duration == 6)
    } else { check("two levels: sub-groups are groups", false) }
    check("two levels: counts", g2.fileCount == 5 && g2.groupCount == 4)

    // MARK: - Pruning

    var pr = FakeDisk()
    pr.folder("/in/mix", [file("/in/mix/a.wav"), dir("/in/mix/empty"), dir("/in/mix/docs"),
                          dir("/in/mix/nested")])
    pr.folder("/in/mix/empty", [])
    pr.folder("/in/mix/docs", [file("/in/mix/docs/readme.txt"), file("/in/mix/docs/pic.png")])
    pr.folder("/in/mix/nested", [dir("/in/mix/nested/hollow")])
    pr.folder("/in/mix/nested/hollow", [])
    let r3 = pr.scan("/in/mix")
    check("pruning: empty, no-audio and hollow folders leave nothing behind",
          r3.root?.subfolders.isEmpty == true && r3.root?.files.count == 1)

    var none = FakeDisk()
    none.folder("/in/silence", [file("/in/silence/a.txt"), dir("/in/silence/sub")])
    none.folder("/in/silence/sub", [file("/in/silence/sub/b.pdf")])
    let r4 = none.scan("/in/silence")
    check("no audio at all: nothing is created", r4.root == nil && r4.failure == .noAudio)
    var emptyDisk = FakeDisk()
    emptyDisk.folder("/in/void", [])
    check("empty folder: nothing is created", emptyDisk.scan("/in/void").failure == .noAudio)
    check("not a folder: refused", flat.scan("/in/nowhere").failure == .notAFolder)

    // MARK: - Hidden, packages, links

    var hid = FakeDisk()
    hid.folder("/in/h", [file("/in/h/.DS_Store"), file("/in/h/._a.wav", hidden: true),
                         file("/in/h/ok.wav"), dir("/in/h/.cache", hidden: true),
                         dir("/in/h/Session.logicx", package: true), dir("/in/h/loop", link: true),
                         dir("/in/h/real")])
    hid.folder("/in/h/.cache", [file("/in/h/.cache/x.wav")])
    hid.folder("/in/h/Session.logicx", [file("/in/h/Session.logicx/y.wav")])
    hid.folder("/in/h/loop", [file("/in/h/loop/z.wav")])
    hid.folder("/in/h/real", [file("/in/h/real/w.wav")])
    let r5 = hid.scan("/in/h")
    check("hidden files and folders ignored", r5.root?.files.map(\.name) == ["ok"], "\(r5.root?.files.map(\.name) ?? [])")
    check("packages ignored (a .logicx is a file for the Finder)",
          r5.root?.subfolders.map(\.name) == ["real"], "\(r5.root?.subfolders.map(\.name) ?? [])")
    check("symlinked folders not followed (a loop)", r5.fileCount == 2)

    // MARK: - Stable order

    var shuffledA = FakeDisk(), shuffledB = FakeDisk()
    let entriesA = [file("/in/o/b.wav"), file("/in/o/a.wav"), dir("/in/o/y"), dir("/in/o/x"), file("/in/o/c.wav")]
    shuffledA.folder("/in/o", entriesA)
    shuffledB.folder("/in/o", Array(entriesA.reversed()))
    for d in [0, 1] {
        for s in ["x", "y"] {
            let path = "/in/o/\(s)"
            let content = [file("\(path)/2.wav"), file("\(path)/1.wav")]
            if d == 0 { shuffledA.folder(path, content) } else { shuffledB.folder(path, Array(content.reversed())) }
        }
    }
    check("stable order: the listing order does not matter",
          shuffledA.scan("/in/o").root == shuffledB.scan("/in/o").root)
    check("stable order: files a, b, c then x, y",
          shuffledA.scan("/in/o").root.map { shape($0) } == "a,b,c | x,y")

    // MARK: - Bounds: union, never infinite

    let g6 = FI.plan(timed(r2.root!, dur), start: 0, lane: 0, mode: .stacked)!
    check("bounds: finite", g6.duration.isFinite && g6.duration > 0)
    // Sequential: a=4, then close (c1=1 then deep=6 → 7), then room (r1=2, r2=3 → 5): total 16.
    let seq = FI.plan(timed(r2.root!, dur), start: 100, lane: 2, mode: .sequential)!
    check("end to end: one lane for everything at this level", seq.items.allSatisfy { $0.lane == 0 })
    check("end to end: order kept, each starts where the previous ends",
          seq.items.map(\.start) == [100, 104, 111], "\(seq.items.map(\.start))")
    check("end to end: the group lasts the sum (4 + 7 + 5 = 16)", seq.duration == 16, "\(seq.duration)")
    check("end to end: the group starts at the drop", seq.start == 100 && seq.lane == 2)
    if case .group(let close) = seq.items[1] {
        check("end to end: inside a sub-folder too (c1 at 104, deep at 105)",
              close.items.map(\.start) == [104, 105], "\(close.items.map(\.start))")
        check("end to end: a sub-group is laid on one lane", close.items.allSatisfy { $0.lane == 0 })
        check("end to end: its span = the union (104 → 111)", close.start == 104 && close.duration == 7)
    } else { check("end to end: close is a group", false) }
    check("duration(of:) agrees with plan", FI.duration(of: timed(r2.root!, dur), mode: .sequential) == 16
          && FI.duration(of: timed(r2.root!, dur), mode: .stacked) == 6)

    // MARK: - Mixed files / folders in ONE folder (stacked, lanes continue)

    var mix = FakeDisk()
    mix.folder("/in/m", [dir("/in/m/z"), file("/in/m/b.wav"), file("/in/m/a.wav")])
    mix.folder("/in/m/z", [file("/in/m/z/q.wav")])
    let g7 = FI.plan(timed(mix.scan("/in/m").root!, { _ in 3 }), start: 0, lane: 0, mode: .stacked)!
    check("mixed: files then the sub-folder, one lane each", names(g7) == ["a", "b", "[z]"] && g7.items.map(\.lane) == [0, 1, 2])

    // MARK: - moved(to:)

    let moved = g2.moved(to: 50, lane: 7)
    check("moved: the group lands on the new start and lane", moved.start == 50 && moved.lane == 7)
    check("moved: every descendant shifted by the same amount",
          moved.items.allSatisfy { $0.start == 50 } && moved.duration == g2.duration)
    if case .group(let sub) = moved.items[1], case .group(let deep) = sub.items[1] {
        check("moved: the deepest group followed", sub.start == 50 && deep.start == 50)
    } else { check("moved: structure kept", false) }
    check("moved: lanes of the children untouched", moved.items.map(\.lane) == g2.items.map(\.lane))

    // MARK: - Measures: order of fileURLs / filling

    let tree = timed(r2.root!, dur)
    let urls = FI.fileURLs(of: tree).map { $0.lastPathComponent }
    check("fileURLs: files then sub-folders, depth first", urls == ["a.wav", "c1.wav", "d1.aif", "r1.wav", "r2.wav"], "\(urls)")
    let filled = FI.filling(r2.root!, with: [(1, 10), (2, 20), (3, 30), (4, 40), (5, 50)])
    check("filling: each measure lands on its file",
          FI.fileURLs(of: filled).count == 5
          && filled.files[0].duration == 1 && filled.files[0].size == 10
          && filled.subfolders[0].files[0].duration == 2
          && filled.subfolders[0].subfolders[0].files[0].duration == 3
          && filled.subfolders[1].files.map(\.duration) == [4, 5])

    // MARK: - Depth cap

    var chain = FakeDisk()
    for level in 0...11 {
        let path = "/in/c" + (0..<level).map { "/d\($0 + 1)" }.joined()
        var entries = [file(path + "/f\(level).wav")]
        if level < 11 { entries.append(dir(path + "/d\(level + 1)")) }
        chain.folder(path, entries)
    }
    let r8 = chain.scan("/in/c")
    func depthOf(_ n: FI.Node) -> Int { 1 + (n.subfolders.map(depthOf).max() ?? 0) }
    check("depth cap: the root plus 8 levels are read (9 nested folders)",
          depthOf(r8.root!) == FI.maxDepth + 1, "depth \(depthOf(r8.root!))")
    check("depth cap: what lies below is counted as omitted", r8.omittedDeepFolders == 1, "\(r8.omittedDeepFolders)")
    check("depth cap: the import is not refused", r8.failure == nil && r8.fileCount == FI.maxDepth + 1)
    var shallow = FakeDisk()
    shallow.folder("/in/s", [file("/in/s/a.wav"), dir("/in/s/b")])
    shallow.folder("/in/s/b", [file("/in/s/b/x.wav")])
    check("depth cap: nothing omitted when nothing is deep", shallow.scan("/in/s").omittedDeepFolders == 0)

    // MARK: - File cap

    func bigDisk(_ n: Int, spread: Bool) -> FakeDisk {
        var d = FakeDisk()
        if spread {
            var root: [FI.DirEntry] = []
            for k in 0..<4 {
                root.append(dir("/in/big/s\(k)"))
                d.folder("/in/big/s\(k)", (0..<(n / 4)).map { file("/in/big/s\(k)/\($0).wav") })
            }
            d.folder("/in/big", root)
        } else {
            d.folder("/in/big", (0..<n).map { file("/in/big/\($0).wav") })
        }
        return d
    }
    check("file cap: exactly 2000 files are accepted", bigDisk(FI.maxFiles, spread: false).scan("/in/big").fileCount == 2000)
    let over = bigDisk(FI.maxFiles + 1, spread: false).scan("/in/big")
    check("file cap: 2001 files refuse the whole import", over.root == nil && over.failure == .tooManyFiles(2001), "\(String(describing: over.failure))")
    let overSpread = bigDisk(2400, spread: true).scan("/in/big")
    if case .tooManyFiles? = overSpread.failure { check("file cap: counted across sub-folders too", overSpread.root == nil) }
    else { check("file cap: counted across sub-folders too", false, "\(String(describing: overSpread.failure))") }
    check("thresholds: confirmation at 200, bounds 8 levels / 2000 files",
          FI.confirmThreshold == 200 && FI.maxDepth == 8 && FI.maxFiles == 2000)

    // MARK: - A single file still yields a group

    var one = FakeDisk()
    one.folder("/in/solo", [file("/in/solo/only.wav")])
    let g9 = FI.plan(timed(one.scan("/in/solo").root!, { _ in 1.5 }), start: 0, lane: 0, mode: .stacked)
    check("one file: the folder still yields a group", g9?.name == "solo" && g9?.fileCount == 1 && g9?.duration == 1.5)

    print("\n\(total) assertions, \(fails.count) failed")
    exit(fails.isEmpty ? 0 : 1)
  }
}
