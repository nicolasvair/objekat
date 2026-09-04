import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - AppKit drag source (a batch of files)

/// The drag source of a file row in the browser.
///
/// Written in AppKit because SwiftUI cannot do it: `.onDrag` returns ONE `NSItemProvider`, hence
/// a single element, whatever the selection — a confirmed Apple limitation, only a native `List`
/// can emit a batch, and the browser is a hand-made `LazyVStack`.
/// `beginDraggingSession(with:)` takes N `NSDraggingItem`s, each carrying a real file URL: the
/// drop then receives exactly what the Finder sends it — the same types, the same number of
/// providers — and therefore takes the SAME path, with no 'sound library' branch.
///
/// It is also what settled 'only one sound imported': the batch used to travel in a home-made
/// type that SwiftUI threw away at the drop, and the gesture fell back on the Finder branch with
/// the first file's URL alone.
struct FileDragSource: NSViewRepresentable {
    /// The batch, evaluated when the gesture starts (so up to date with the multiple selection).
    let urls: () -> [URL]
    /// A click without a drag: the selection remains the SwiftUI view's business.
    let onClick: () -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.urls = urls
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.urls = urls
        view.onClick = onClick
    }

    final class DragView: NSView, NSDraggingSource {
        var urls: () -> [URL] = { [] }
        var onClick: () -> Void = {}

        private var pressOrigin: NSPoint?
        private var dragging = false

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            pressOrigin = event.locationInWindow
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragging, let origin = pressOrigin else { return }
            let dx = event.locationInWindow.x - origin.x
            let dy = event.locationInWindow.y - origin.y
            guard dx * dx + dy * dy > 16 else { return }   // a 4 pt threshold, like the Finder
            dragging = true
            beginDrag(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            defer { pressOrigin = nil }
            guard !dragging else { return }
            onClick()   // `selectRow` rereads the modifiers: ⇧ and ⌘ keep working
        }

        private func beginDrag(with event: NSEvent) {
            let files = urls()
            guard !files.isEmpty else { return }
            let point = convert(event.locationInWindow, from: nil)
            let items: [NSDraggingItem] = files.map { url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 32, height: 32)
                item.setDraggingFrame(
                    NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32),
                    contents: icon
                )
                return item
            }
            let session = beginDraggingSession(with: items, event: event, source: self)
            session.draggingFormation = .stack
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }
    }
}

// MARK: - Browser focus (shared with the timeline's keyboard monitor)

@MainActor
final class ExplorerFocus {
    static let shared = ExplorerFocus()
    var active = false
    private init() {}
}

// MARK: - Tree node (a folder or an audio file)

@MainActor
@Observable
final class SoundLibraryNode: Identifiable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
    let depth: Int

    // Audio file
    var duration: Double = 0
    var peaks: [Float] = []

    // Folder
    var isExpanded: Bool = false
    var children: [SoundLibraryNode] = []
    var didLoadChildren: Bool = false

    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }

    init(url: URL, isDirectory: Bool, depth: Int) {
        self.url = url
        self.isDirectory = isDirectory
        self.depth = depth
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class SoundLibraryViewModel {
    // The folder chosen initially: the upper bound of navigation (⌘↑ never climbs above it)
    private(set) var baseURL: URL? = nil
    // The current folder shown
    private(set) var currentURL: URL? = nil

    var searchText: String = "" {
        didSet { applySearch() }
    }

    // The current folder's tree (with an empty search)
    var rootNodes: [SoundLibraryNode] = []
    // Flat recursive results (with a non-empty search)
    var searchResults: [SoundLibraryNode] = []

    var isSearching: Bool { !searchText.isEmpty }

    var selectedID: UUID? = nil
    private(set) var selectedNode: SoundLibraryNode? = nil

    // Multiple selection (⇧ = a range, ⌘ = add/remove) — it only covers FILES, and serves the
    // grouped drag towards the timeline. `selectedID`/`selectedNode` remain the "active"
    // selection (the mini player): the last file clicked, even in a multiple selection.
    var multiSelectedIDs: Set<UUID> = []
    private var rangeAnchorID: UUID? = nil

    // Keyboard cursor (it can point at a folder or a file)
    var cursorID: UUID? = nil

    // I/O/S for the selected file
    var pointI: Double = 0
    var pointO: Double = 0
    var pointS: Double = 0
    private var selectedDuration: Double = 0

    // Preview player
    private var player: AVAudioPlayer? = nil
    var isPlaying: Bool = false

    // Length and peak caches (the key being the path), shared for the whole session
    private var peaksCache: [String: [Float]] = [:]
    private var durationCache: [String: Double] = [:]
    private var inFlight: Set<String> = []

    nonisolated static let audioExts: Set<String> = ["wav","aif","aiff","mp3","m4a","flac","caf","ogg"]
    nonisolated static let miniPeakCount = 60

    // MARK: Navigation

    var canGoUp: Bool {
        guard let base = baseURL, let cur = currentURL else { return false }
        return cur.standardizedFileURL != base.standardizedFileURL
    }

    /// The breadcrumb from the base folder down to the current one.
    var breadcrumb: String {
        guard let base = baseURL, let cur = currentURL else { return "" }
        let baseComps = base.standardizedFileURL.pathComponents
        let curComps = cur.standardizedFileURL.pathComponents
        if curComps.count >= baseComps.count,
           Array(curComps.prefix(baseComps.count)) == baseComps {
            let tail = curComps.suffix(curComps.count - baseComps.count + 1) // includes the base folder
            return tail.joined(separator: " / ")
        }
        return cur.lastPathComponent
    }

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("common.chooseShort")
        if panel.runModal() == .OK, let url = panel.url {
            ObjekatPreferences.shared.soundLibraryFolder = url.path
            baseURL = url
            navigate(to: url)
        }
    }

    func restoreFolder() {
        let path = ObjekatPreferences.shared.soundLibraryFolder
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        baseURL = url
        navigate(to: url)
    }

    /// Goes down into a folder (double click).
    func enterFolder(_ node: SoundLibraryNode) {
        guard node.isDirectory else { return }
        searchText = ""
        navigate(to: node.url)
    }

    /// Goes up one level (⌘↑), bounded by the base folder.
    func goUp() {
        guard canGoUp, let cur = currentURL else { return }
        searchText = ""
        navigate(to: cur.deletingLastPathComponent())
    }

    private func navigate(to url: URL) {
        stopPreview()
        selectedID = nil
        selectedNode = nil
        multiSelectedIDs = []
        rangeAnchorID = nil
        cursorID = nil
        currentURL = url
        rootNodes = makeNodes(for: url, depth: 0)
        applySearch()
        ensureMedia(for: rootNodes)
    }

    // MARK: Keyboard navigation (arrows, Finder-style)

    /// A flat list of the rows currently shown (allowing for the search and for what is unfolded).
    var displayedRows: [SoundLibraryNode] {
        isSearching ? searchResults : visibleNodes
    }

    var cursorNode: SoundLibraryNode? {
        guard let id = cursorID else { return nil }
        return displayedRows.first { $0.id == id }
    }

    /// ↑ / ↓: moves the cursor by one row.
    func moveCursor(_ delta: Int) {
        let list = displayedRows
        guard !list.isEmpty else { return }
        let idx: Int
        if let id = cursorID, let i = list.firstIndex(where: { $0.id == id }) {
            idx = min(max(i + delta, 0), list.count - 1)
        } else {
            idx = delta >= 0 ? 0 : list.count - 1
        }
        focusCursor(on: list[idx])
    }

    /// →: unfolds a folded folder, otherwise goes down onto the first child.
    func expandOrEnter() {
        guard let node = cursorNode, node.isDirectory else { return }
        if !node.isExpanded {
            toggleExpand(node)
        } else if let first = node.children.first {
            focusCursor(on: first)
        }
    }

    /// ←: folds an unfolded folder, otherwise moves the cursor up to the parent folder.
    func collapseOrParent() {
        guard let node = cursorNode else { return }
        if node.isDirectory && node.isExpanded {
            toggleExpand(node)
        } else if let parent = parentNode(of: node) {
            focusCursor(on: parent)
        }
    }

    /// Places the keyboard cursor on a row; a file becomes selected (the mini player), a folder does not.
    func focusCursor(on node: SoundLibraryNode) {
        cursorID = node.id
        if node.isDirectory {
            if selectedNode != nil { stopPreview(); selectedID = nil; selectedNode = nil }
        } else {
            stopPreview()
            selectedID = node.id
            selectedNode = node
            resetIOSForDuration(node.duration)
        }
    }

    /// A node's visible parent folder (the previous row of the immediately shallower depth).
    private func parentNode(of node: SoundLibraryNode) -> SoundLibraryNode? {
        let list = visibleNodes
        guard let i = list.firstIndex(where: { $0.id == node.id }) else { return nil }
        var j = i - 1
        while j >= 0 {
            if list[j].depth == node.depth - 1 && list[j].isDirectory { return list[j] }
            j -= 1
        }
        return nil
    }

    // MARK: Building the tree

    /// A folder's immediate content: subfolders first, then audio files, sorted.
    private func makeNodes(for url: URL, depth: Int) -> [SoundLibraryNode] {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        var dirs: [URL] = []
        var files: [URL] = []
        for child in contents {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                dirs.append(child)
            } else if Self.audioExts.contains(child.pathExtension.lowercased()) {
                files.append(child)
            }
        }
        let cmp: (URL, URL) -> Bool = {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
        dirs.sort(by: cmp)
        files.sort(by: cmp)

        let dirNodes = dirs.map { SoundLibraryNode(url: $0, isDirectory: true, depth: depth) }
        let fileNodes = files.map { u -> SoundLibraryNode in
            let n = SoundLibraryNode(url: u, isDirectory: false, depth: depth)
            if let d = durationCache[u.path] { n.duration = d }
            if let p = peaksCache[u.path] { n.peaks = p }
            return n
        }
        return dirNodes + fileNodes
    }

    /// Unfolds/folds a folder (a click on the chevron), loading the children lazily.
    func toggleExpand(_ node: SoundLibraryNode) {
        guard node.isDirectory else { return }
        if !node.didLoadChildren {
            node.children = makeNodes(for: node.url, depth: node.depth + 1)
            node.didLoadChildren = true
            ensureMedia(for: node.children)
        }
        node.isExpanded.toggle()
    }

    /// A flat list of the visible nodes (allowing for the unfolded folders).
    var visibleNodes: [SoundLibraryNode] {
        var out: [SoundLibraryNode] = []
        func walk(_ nodes: [SoundLibraryNode]) {
            for n in nodes {
                out.append(n)
                if n.isDirectory && n.isExpanded { walk(n.children) }
            }
        }
        walk(rootNodes)
        return out
    }

    // MARK: Search

    private func applySearch() {
        guard isSearching, let url = currentURL else {
            searchResults = []
            return
        }
        let needle = searchText
        Task.detached(priority: .userInitiated) {
            let matches = Self.searchAudioFiles(in: url, matching: needle)
            await MainActor.run {
                // The search may have changed in the meantime
                guard self.searchText == needle else { return }
                let nodes = matches.map { u -> SoundLibraryNode in
                    let n = SoundLibraryNode(url: u, isDirectory: false, depth: 0)
                    if let d = self.durationCache[u.path] { n.duration = d }
                    if let p = self.peaksCache[u.path] { n.peaks = p }
                    return n
                }
                self.searchResults = nodes
                self.ensureMedia(for: nodes)
            }
        }
    }

    private nonisolated static func searchAudioFiles(in root: URL, matching needle: String) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let u as URL in en {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard !isDir, audioExts.contains(u.pathExtension.lowercased()) else { continue }
            if u.lastPathComponent.localizedCaseInsensitiveContains(needle) { out.append(u) }
        }
        return out.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Lengths and peaks

    private func ensureMedia(for nodes: [SoundLibraryNode]) {
        for node in nodes where !node.isDirectory {
            let path = node.url.path
            if node.duration > 0 && !node.peaks.isEmpty { continue }
            guard !inFlight.contains(path) else { continue }
            let url = node.url
            inFlight.insert(path)
            Task.detached(priority: .utility) {
                let dur = await Self.loadDuration(url: url)
                let pk  = Self.computePeaks(path: path, count: Self.miniPeakCount)
                await MainActor.run {
                    self.applyMedia(path: path, duration: dur, peaks: pk)
                }
            }
        }
    }

    private func applyMedia(path: String, duration: Double, peaks: [Float]) {
        inFlight.remove(path)
        durationCache[path] = duration
        peaksCache[path] = peaks
        for node in allLoadedFileNodes() where node.url.path == path {
            node.duration = duration
            node.peaks = peaks
        }
        if let sel = selectedNode, sel.url.path == path {
            resetIOSForDuration(duration)
        }
    }

    /// Every file node currently instantiated (the tree plus the search results).
    private func allLoadedFileNodes() -> [SoundLibraryNode] {
        var out: [SoundLibraryNode] = []
        func walk(_ nodes: [SoundLibraryNode]) {
            for n in nodes {
                if n.isDirectory { if n.didLoadChildren { walk(n.children) } }
                else { out.append(n) }
            }
        }
        walk(rootNodes)
        out.append(contentsOf: searchResults)
        return out
    }

    private nonisolated static func loadDuration(url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        do {
            let d = try await asset.load(.duration)
            let s = CMTimeGetSeconds(d)
            return (s.isNaN || s <= 0) ? 0 : s
        } catch { return 0 }
    }

    private nonisolated static func computePeaks(path: String, count: Int) -> [Float] {
        let url = URL(fileURLWithPath: path)
        guard let f = try? AVAudioFile(forReading: url) else { return [] }
        let fmt = f.processingFormat
        let fc = AVAudioFrameCount(f.length)
        guard fc > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: fc) else { return [] }
        guard (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData?[0] else { return [] }
        let total = Int(buf.frameLength)
        guard total > 0 else { return [] }
        var peaks = [Float](repeating: 0, count: count)
        let step = Double(total) / Double(count)
        for i in 0..<count {
            let s = Int(Double(i) * step), e = min(Int(Double(i+1) * step), total)
            var p: Float = 0
            for j in s..<e { p = max(p, abs(ch[j])) }
            peaks[i] = p
        }
        let mx = peaks.max() ?? 1
        if mx > 0 { for i in peaks.indices { peaks[i] /= mx } }
        return peaks
    }

    // MARK: Selection

    /// A plain click with no modifier: the active selection alone (the mini player). It clears the
    /// multiple selection UNLESS the file clicked is already part of it (Finder behaviour):
    /// `.onTapGesture` fires on mouse-down, BEFORE `.onDrag` — without that guard, clicking and
    /// then dragging a file that is already multi-selected would collapse the selection just before
    /// the drag captured its batch, and a single file would leave instead of all of them.
    /// A second click on the same file = play/stop.
    func select(_ node: SoundLibraryNode) {
        guard !node.isDirectory else { return }
        cursorID = node.id
        rangeAnchorID = node.id
        if !multiSelectedIDs.contains(node.id) { multiSelectedIDs = [] }
        stopPreview()
        if selectedID == node.id {
            // second click = play/stop
            togglePreview(node: node)
            return
        }
        selectedID = node.id
        selectedNode = node
        resetIOSForDuration(node.duration)
    }

    /// ⌘-click: adds/removes this file from the multiple selection, without touching the mini
    /// player (which stays on the last file explicitly selected by a plain click).
    func toggleMultiSelect(_ node: SoundLibraryNode) {
        guard !node.isDirectory else { return }
        cursorID = node.id
        rangeAnchorID = node.id
        // The first ⌘ press after a plain click: the active selection is part of it too.
        if multiSelectedIDs.isEmpty, let sel = selectedID { multiSelectedIDs = [sel] }
        if multiSelectedIDs.contains(node.id) {
            multiSelectedIDs.remove(node.id)
        } else {
            multiSelectedIDs.insert(node.id)
        }
    }

    /// ⇧-click: a range of files between the current anchor and this node, within the shown rows.
    func rangeSelect(to node: SoundLibraryNode) {
        guard !node.isDirectory else { return }
        cursorID = node.id
        let list = displayedRows
        let anchor = rangeAnchorID.flatMap { id in list.first { $0.id == id } } ?? node
        guard let ai = list.firstIndex(where: { $0.id == anchor.id }),
              let bi = list.firstIndex(where: { $0.id == node.id }) else {
            select(node)
            return
        }
        let range = ai <= bi ? ai...bi : bi...ai
        multiSelectedIDs = Set(list[range].filter { !$0.isDirectory }.map(\.id))
    }

    private func resetIOSForDuration(_ dur: Double) {
        selectedDuration = dur
        pointI = 0
        pointO = dur
        pointS = 0
    }

    // MARK: I/O/S

    func clampedI(_ v: Double) -> Double { max(0, min(v, pointO - 0.01)) }
    func clampedO(_ v: Double) -> Double { max(pointI + 0.01, min(v, selectedDuration)) }
    func clampedS(_ v: Double) -> Double { max(0, min(v, pointO - pointI)) }

    func setI(_ v: Double) { pointI = clampedI(v); if pointS < 0 { pointS = 0 } }
    func setO(_ v: Double) { pointO = clampedO(v); if pointS > pointO - pointI { pointS = pointO - pointI } }
    func setS(_ v: Double) { pointS = clampedS(v) }

    // MARK: Preview

    func togglePreview(node: SoundLibraryNode) {
        if isPlaying { stopPreview() } else { startPreview(node: node) }
    }

    private func startPreview(node: SoundLibraryNode) {
        stopPreview()
        guard let p = try? AVAudioPlayer(contentsOf: node.url) else { return }
        // Plays out of the SAME audio device as the engine (the toolbar choice) — without this,
        // AVAudioPlayer plays on the default system device. nil (not found) ⇒ the system default.
        if let uid = AudioOutputDevice.shared.uid { p.currentDevice = uid }
        p.currentTime = pointI
        p.play()
        player = p
        isPlaying = true
        // an automatic stop at point O
        let remaining = pointO - pointI
        Task {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            await MainActor.run { if self.isPlaying { self.stopPreview() } }
        }
    }

    func stopPreview() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    // MARK: The batch for the drag

    /// The URLs the drag started on `node` carries: the whole multiple selection if `node` is part
    /// of it (in the order of the shown rows), otherwise that one file — which is what allows
    /// importing several sounds in a single gesture.
    func dragURLs(for node: SoundLibraryNode) -> [URL] {
        guard multiSelectedIDs.count > 1, multiSelectedIDs.contains(node.id) else {
            return [node.url]
        }
        let ordered = displayedRows.filter { multiSelectedIDs.contains($0.id) && !$0.isDirectory }
        return ordered.isEmpty ? [node.url] : ordered.map(\.url)
    }
}

// MARK: - Main view

struct SoundLibraryView: View {
    @State private var vm = SoundLibraryViewModel()
    @FocusState private var listFocused: Bool

    private var rows: [SoundLibraryNode] { vm.displayedRows }

    var body: some View {
        VStack(spacing: 0) {
            // Header: navigation and search
            VStack(spacing: 4) {
                if vm.baseURL == nil {
                    Button(action: vm.openFolderPanel) {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(L("library.chooseFolder"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(spacing: 4) {
                        Button(action: vm.goUp) {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(vm.canGoUp ? .primary : .tertiary)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .disabled(!vm.canGoUp)
                        .help(L("library.parentFolder"))

                        Text(vm.breadcrumb)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button(action: vm.openFolderPanel) {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .help(L("library.chooseAnotherFolder"))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 11))
                    TextField(L("common.search"), text: $vm.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .padding(8)

            Divider()

            if vm.baseURL == nil {
                Spacer()
                Text(L("library.noFolder"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            } else if rows.isEmpty {
                Spacer()
                Text(vm.isSearching ? L("library.noResult") : L("library.emptyFolder"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                fileList

                // Mini player (visible if a file is selected)
                if let node = vm.selectedNode {
                    Divider()
                    SoundLibraryMiniPlayerView(node: node, vm: vm)
                        .frame(height: 90)
                }
            }
        }
        .onAppear { vm.restoreFolder() }
        .onDisappear { ExplorerFocus.shared.active = false }
    }

    // MARK: List (tree plus keyboard navigation)

    private var fileList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { node in
                        row(for: node)
                            .id(node.id)
                        Divider()
                    }
                }
            }
            .focusable()
            .focused($listFocused)
            .onChange(of: listFocused) { _, f in ExplorerFocus.shared.active = f }
            .onChange(of: vm.cursorID) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id, anchor: nil) } }
            }
            .onKeyPress(keys: [.upArrow]) { press in
                if press.modifiers.contains(.command) { vm.goUp() } else { vm.moveCursor(-1) }
                return .handled
            }
            .onKeyPress(keys: [.downArrow]) { press in
                if press.modifiers.contains(.command), let n = vm.cursorNode { vm.enterFolder(n) }
                else { vm.moveCursor(1) }
                return .handled
            }
            .onKeyPress(.leftArrow) { vm.collapseOrParent(); return .handled }
            .onKeyPress(.rightArrow) { vm.expandOrEnter(); return .handled }
        }
    }

    private func row(for node: SoundLibraryNode) -> some View {
        SoundLibraryRowView(
            node: node,
            indented: !vm.isSearching,
            isSelected: vm.selectedID == node.id || vm.multiSelectedIDs.contains(node.id),
            isCursor: vm.cursorID == node.id,
            isPlaying: vm.isPlaying && vm.selectedID == node.id,
            onToggleExpand: { listFocused = true; vm.toggleExpand(node) },
            onEnter: { listFocused = true; vm.enterFolder(node) },
            onSelect: { listFocused = true; selectRow(node) },
            dragURLsProvider: node.isDirectory ? nil : { vm.dragURLs(for: node) }
        )
    }

    /// A plain click: a file selects itself (the mini player), a folder merely takes the cursor.
    /// ⌘ / ⇧ (files only): a multiple selection for the grouped drag towards the timeline.
    private func selectRow(_ node: SoundLibraryNode) {
        if node.isDirectory { vm.focusCursor(on: node); return }
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) { vm.rangeSelect(to: node) }
        else if flags.contains(.command) { vm.toggleMultiSelect(node) }
        else { vm.select(node) }
    }
}

// MARK: - Row (folder or file)

private struct SoundLibraryRowView: View {
    let node: SoundLibraryNode
    let indented: Bool
    let isSelected: Bool
    let isCursor: Bool
    let isPlaying: Bool
    let onToggleExpand: () -> Void
    let onEnter: () -> Void
    let onSelect: () -> Void
    /// The batch the drag carries, computed the instant the drag starts (it reflects the current
    /// multiple selection, not the one of the last render). `nil` for a folder.
    let dragURLsProvider: (() -> [URL])?

    private var indent: CGFloat { indented ? CGFloat(node.depth) * 12 : 0 }

    var body: some View {
        Group {
            if node.isDirectory { folderRow } else { fileRow }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background((isSelected || isCursor) ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        // Files hand click and drag over to AppKit: it is the only way to emit a batch of N
        // elements (@see FileDragSource). Folders keep their SwiftUI gestures.
        .overlay {
            if let dragURLsProvider {
                FileDragSource(urls: dragURLsProvider, onClick: onSelect)
            }
        }
    }

    // MARK: Folder

    private var folderRow: some View {
        HStack(spacing: 6) {
            if indent > 0 { Color.clear.frame(width: indent) }

            Button(action: onToggleExpand) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor.opacity(0.8))
                .frame(width: 16)

            Text(node.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)

            Spacer()
        }
        // Double click = go down into the folder; plain click = cursor/focus
        .onTapGesture(count: 2) { onEnter() }
        .onTapGesture { onSelect() }
    }

    // MARK: File

    private var fileRow: some View {
        HStack(spacing: 6) {
            if indent > 0 { Color.clear.frame(width: indent) }

            Image(systemName: isPlaying ? "waveform" : "doc.audio")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 16)

            Text(node.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? Color.primary : .secondary)

            Spacer()

            MiniWaveformView(peaks: node.peaks, width: 48, height: 18)
                .opacity(node.peaks.isEmpty ? 0 : 1)

            Text(formatDuration(node.duration))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private func formatDuration(_ d: Double) -> String {
        guard d > 0 else { return "—" }
        let s = Int(d)
        let ms = Int((d - Double(s)) * 10)
        let m = s / 60, sec = s % 60
        return m > 0 ? "\(m):\(String(format: "%02d", sec))" : "\(sec).\(ms)s"
    }
}

// MARK: - Thumbnail waveform (Canvas)

struct MiniWaveformView: View {
    let peaks: [Float]
    let width: Double
    let height: Double

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty else { return }
            let w = size.width, h = size.height
            let mid = h / 2
            let step = w / Double(peaks.count)
            for (i, peak) in peaks.enumerated() {
                let x = Double(i) * step + step / 2
                let amp = Double(peak) * mid * 0.9
                var p = Path()
                p.move(to: CGPoint(x: x, y: mid - amp))
                p.addLine(to: CGPoint(x: x, y: mid + amp))
                ctx.stroke(p, with: .color(.accentColor.opacity(0.7)), lineWidth: max(1, step - 0.5))
            }
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Mini player with I/O/S handles

private struct SoundLibraryMiniPlayerView: View {
    let node: SoundLibraryNode
    var vm: SoundLibraryViewModel

    // Drag states for the handles
    @State private var draggingI = false
    @State private var draggingO = false
    @State private var draggingS = false

    var body: some View {
        VStack(spacing: 0) {
            // Waveform with handles
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let dur = max(node.duration, 0.01)

                ZStack(alignment: .topLeading) {
                    // Full-width waveform background
                    Canvas { ctx, size in
                        // Outside I–O: darkened
                        let xi = vm.pointI / dur * Double(size.width)
                        let xo = vm.pointO / dur * Double(size.width)
                        ctx.fill(Path(CGRect(x: 0, y: 0, width: xi, height: size.height)),
                                 with: .color(.black.opacity(0.25)))
                        ctx.fill(Path(CGRect(x: xo, y: 0, width: size.width - xo, height: size.height)),
                                 with: .color(.black.opacity(0.25)))

                        // Waveform
                        let peaks = node.peaks
                        guard !peaks.isEmpty else { return }
                        let step = size.width / Double(peaks.count)
                        let mid = size.height / 2
                        for (i, peak) in peaks.enumerated() {
                            let x = Double(i) * step + step / 2
                            let amp = Double(peak) * mid * 0.85
                            let inRegion = (Double(i) / Double(peaks.count) * dur) >= vm.pointI
                                       && (Double(i) / Double(peaks.count) * dur) <= vm.pointO
                            var p = Path()
                            p.move(to: CGPoint(x: x, y: mid - amp))
                            p.addLine(to: CGPoint(x: x, y: mid + amp))
                            ctx.stroke(p, with: .color(inRegion ? .accentColor : .accentColor.opacity(0.3)),
                                       lineWidth: max(1, step - 0.5))
                        }
                    }

                    // Handle I (yellow, left)
                    handleLine(x: vm.pointI / dur * w, height: h, color: .yellow, label: "I")
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { v in vm.setI((v.location.x / w) * dur) }
                            .onEnded { v in vm.setI((v.location.x / w) * dur) })

                    // Handle O (yellow, right)
                    handleLine(x: vm.pointO / dur * w, height: h, color: .yellow, label: "O")
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { v in vm.setO((v.location.x / w) * dur) }
                            .onEnded { v in vm.setO((v.location.x / w) * dur) })

                    // Handle S (cyan, sync)
                    let sAbsolute = vm.pointI + vm.pointS
                    handleLine(x: sAbsolute / dur * w, height: h, color: .cyan, label: "S")
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { v in vm.setS((v.location.x / w) * dur - vm.pointI) }
                            .onEnded { v in vm.setS((v.location.x / w) * dur - vm.pointI) })
                }
            }
            .frame(height: 52)
            .background(Color(nsColor: .underPageBackgroundColor))
            .clipped()

            // Controls: play/stop plus the I/O/S values
            HStack(spacing: 8) {
                Button(action: { vm.togglePreview(node: node) }) {
                    Image(systemName: vm.isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)

                Spacer()

                Group {
                    iosLabel("I", time: vm.pointI, color: .yellow)
                    iosLabel("S", time: vm.pointI + vm.pointS, color: .cyan)
                    iosLabel("O", time: vm.pointO, color: .yellow)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    @ViewBuilder
    private func handleLine(x: Double, height: Double, color: Color, label: String) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(color.opacity(0.9))
                .frame(width: 1.5, height: height)
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .offset(x: 3, y: 2)
        }
        .frame(width: 16, height: height, alignment: .leading)
        .offset(x: x - 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func iosLabel(_ l: String, time: Double, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(l)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            Text(formatSecs(time))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func formatSecs(_ t: Double) -> String {
        String(format: "%.2fs", t)
    }
}
