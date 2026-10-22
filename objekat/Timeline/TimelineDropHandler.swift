import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - What a drag carries, read off the provider
//
// What a drag carries is read off the types EACH `NSItemProvider` declares, never off
// `DropInfo`'s filter: `itemProviders(for:)` does not sort reliably on macOS, and a plugin drag
// — which only registers `public.plain-text` — came out of a request for `.fileURL`. It then
// opened the file drop's band and preview rectangles while a plugin was being moved from one
// object to another.
//
// The two tests are exclusive by construction: a file drag — from the Finder or the browser —
// ALSO exposes text (NSURL registers `public.utf8-plain-text` alongside the URL), so the
// presence of a fileURL settles it in the file's favour.

/// True if this provider carries a file to lay down. The browser's drag goes through here just
/// like the Finder's: it too emits real file URLs (@see FileDragSource).
fileprivate func dragCarriesFile(_ p: NSItemProvider) -> Bool {
    p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
}

// Text and not a file = an internal plugin payload. One definition for every door it can come
// in by (@see PluginDrop.carries); this name is what the band's delegate reads it under.
fileprivate func dragCarriesPlugin(_ p: NSItemProvider) -> Bool { PluginDrop.carries(p) }

// The timeline's drop delegate: it drives the cursor's badge live (a plugin drag with no
// modifier = .move (no badge); with ⌥ = .copy (a '+' badge).
// For files (fileURL): .copy by default. The real drop goes through handleDrop.
struct TimelineDropDelegate: DropDelegate {
    let types: [UTType]
    let onPerform: ([NSItemProvider], CGPoint) -> Bool
    /// Files being hovered: a 'how these files will land' band plus a ghost preview.
    /// It receives the providers (to read names and lengths, once only) and the cursor's
    /// position, which places the rectangles. Called again on every movement so as to follow the
    /// cursor; tracking ⌘, on the other hand, is autonomous on the view-model's side —
    let onFileHint: ([NSItemProvider], CGPoint) -> Void
    /// `dropUpdated` only speaks on movement.
    let onFileHintEnd: () -> Void
    /// Closing the band: leaving the hover, the drop being made, or the drag abandoned.
    /// A drop session under way over the timeline (true on entry and on every movement, false on
    /// leaving / on the drop). It serves the decorations refreshed only by ORDINARY mouse
    var onDropHover: ((Bool) -> Void)? = nil
    /// What releasing the plugin drag in flight HERE would do, for the cursor and the band (the
    /// resolver, @see EditViewModel.pluginDropOutcome): the drag's payload comes from
    /// `PluginDragSession` — a drop target gets only an `NSItemProvider` whose payload loads
    /// asynchronously, too late to refuse in time. nil = not known (no session): the old answer.
    var pluginOutcome: ((CGPoint, NSEvent.ModifierFlags) -> PluginDropOutcome?)? = nil

    /// movements, which are absent during a system drag. `nil` = nothing to warn.
    private func fileProviders(in info: DropInfo) -> [NSItemProvider] {
        info.itemProviders(for: types).filter(dragCarriesFile)
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: types) }

    func dropEntered(info: DropInfo) {
        onDropHover?(true)
        let files = fileProviders(in: info)
        if !files.isEmpty { onFileHint(files, info.location) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onDropHover?(true)
        let providers = info.itemProviders(for: types)
        if providers.contains(where: dragCarriesPlugin) {
            let f = NSEvent.modifierFlags
            // The resolver's verdict when it is known: a refusal is `.forbidden` (and no band).
            if let outcome = pluginOutcome?(info.location, f) {
                if let ctx = outcome.hintContext() {
                    PluginDropHint.shared.present("timeline", context: ctx)
                } else {
                    PluginDropHint.shared.leave("timeline")
                }
                return DropProposal(operation: outcome.operation)
            }
            PluginDropHint.shared.present("timeline", context: .host)
            return DropProposal(operation: PluginDrop.operation(for: f))
        }
        // The files the band really concerns (empty = an internal drag: a plugin).
        // Called again on every movement: that is what makes the preview rectangles follow. It
        // also serves as a net if `dropEntered` did not open the band (the providers not being
        let files = providers.filter(dragCarriesFile)
        if !files.isEmpty { onFileHint(files, info.location) }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        onDropHover?(false)
        PluginDropHint.shared.leave("timeline")
        onFileHintEnd()
    }

    func performDrop(info: DropInfo) -> Bool {
        onDropHover?(false)
        PluginDropHint.shared.leave("timeline")
        // resolved yet on entry, which happens depending on the drag's source).
        // The mode is read BEFORE the band closes, in handleDrop: here we merely hand over, and
        return onPerform(info.itemProviders(for: types), info.location)
    }
}

/// the closing happens once the layout has been captured.
/// A preview of the drop: one rectangle per file, laid where the clip will land — the same lane,
/// the same instant, the same width, computed by the layout shared with the real placement
/// (`EditViewModel.fileDropLayout`). Deliberately bare — no waveform, no clip colour: it is the
/// LAYOUT that has to read at a glance, and it flips under ⌘ at the same time as the band at the
/// bottom. While a file's length is unread, its rectangle takes the waiting width and keeps a
/// dotted outline, then resets itself — so the preview appears at once rather than waiting for
/// the files to be read.
/// A view separate from `TimelineView` on purpose: it is the only one reading `fileDropHint`,
/// whose position changes on every mouse movement. Inside the timeline's body, that tracking
/// would have invalidated the whole canvas on every pixel.
struct FileDropGhostOverlay: View {
    let viewModel: EditViewModel
    let pixelsPerSecond: Double
    let rulerHeight: Double
    let laneStep: Double
    let blockHeight: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let hint = viewModel.fileDropHint, let loc = hint.location {
                let baseLane  = max(0, Int((loc.y - rulerHeight) / laneStep))
                let baseStart = max(0, viewModel.snappedTimePure(loc.x / pixelsPerSecond))
                let slots = EditViewModel.fileDropLayout(durations: hint.previewDurations,
                                                         mode: hint.mode,
                                                         baseLane: baseLane, baseStart: baseStart)
                ForEach(slots) { slot in
                    let preview = slot.index < hint.previews.count ? hint.previews[slot.index] : nil
                    let w = max(3, slot.duration * pixelsPerSecond)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.accentColor.opacity(0.85),
                                              style: StrokeStyle(lineWidth: 1.5,
                                                                 // Dotted = a width still
                                                                 // provisional (the length unread).
                                                                 dash: preview?.duration == nil ? [4, 3] : []))
                        )
                        .overlay(alignment: .leading) {
                            if w > 46, let name = preview?.name, !name.isEmpty {
                                // A folder says what it will become: its name and how many files.
                                Text(preview?.isFolder == true
                                     ? (preview?.fileCount).map { Ln("drop.folder.label", $0, name, $0) } ?? name
                                     : name)
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.primary.opacity(0.75))
                                    .padding(.horizontal, 5)
                            }
                        }
                        .frame(width: w, height: blockHeight)
                        .offset(x: slot.startTime * pixelsPerSecond,
                                y: rulerHeight + Double(slot.lane) * laneStep)
                        .animation(.easeOut(duration: 0.12), value: hint.mode)
                }
            }
        }
    }
}

extension TimelineView {

    func handleDrop(providers: [NSItemProvider], location: CGPoint) -> Bool {
        NSLog("🔵 [handleDrop] %d provider(s) @ (%.0f, %.0f) — types: %@", providers.count,
              location.x, location.y,
              providers.map { $0.registeredTypeIdentifiers.joined(separator: "+") }.joined(separator: " || "))
        // The layout kept = the one the band was showing at the instant of the drop. Read here,
        // before closing the band, otherwise `endFileDropHint` would already have wiped it.
        let dropMode = viewModel.fileDropMode
        viewModel.endFileDropHint()

        // The files are no longer handled provider by provider: laid down each on its own at the
        // same instant and on the same lane, they chased each other away through
        // `resolveOverlaps` and only the last survived. So they are collected here then placed
        // as a batch, in order, according to `dropMode`.
        var fileProviders: [NSItemProvider] = []

        for provider in providers {
            // A plugin payload (dragged from a chip's handle): carried in public.plain-text,
            // confirmed by decoding successfully. nothing=move ⌥=copy.
            // No `continue`: the decoding is asynchronous, so nothing says here yet that this
            // text IS a plugin payload — we let the following branches try their luck on the
            // same provider (they will disqualify themselves if there is no fileURL).
            if dragCarriesPlugin(provider) {
                // What a dropped payload DOES is the same wherever it is let go of — a timeline
                // object here, a bus's strip in the toolbar — so the timeline only says WHERE:
                // the host under the cursor, resolved at the drop and not before.
                // @see PluginDrop.receive
                PluginDrop.receive(provider, in: viewModel) { objectID(at: location) }
            }
            // Files: the Finder's and the browser's alike, the same path from end to end.
            guard dragCarriesFile(provider) else { continue }
            fileProviders.append(provider)
        }

        guard !fileProviders.isEmpty else { return true }
        Task { @MainActor in
            let urls = await Self.loadDroppedURLs(from: fileProviders).compactMap { $0 }
            // Files are measured, folders are read down to their leaves (off the main thread, the
            // lengths a few at a time): both come back in the order they were dropped.
            let load = await EditViewModel.loadDropEntries(from: urls)
            placeDroppedEntries(load, at: location, mode: dropMode)
        }
        return true
    }

    /// Resolves the providers' URLs **keeping the selection's order**, and in parallel:
    /// `loadItem`'s completions come back in any order, whereas it is the files' order that
    /// decides both the stacking (stacked) and the chaining (end to end) — hence the index
    /// carried through to the write into the array. A hole (`nil`) is kept so that the positions
    /// stay aligned with the providers'.
    private static func loadDroppedURLs(from providers: [NSItemProvider]) async -> [URL?] {
        await withTaskGroup(of: (Int, URL?).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    let url: URL? = await withCheckedContinuation { continuation in
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier,
                                          options: nil) { item, _ in
                            // Depending on the source, the item arrives as `Data` (a URL bookmark) or
                            // directly as a `URL` — both forms are accepted.
                            if let url = item as? URL {
                                continuation.resume(returning: url)
                            } else if let data = item as? Data {
                                continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                            } else {
                                continuation.resume(returning: nil)
                            }
                        }
                    }
                    return (index, url)
                }
            }
            var resolved = [URL?](repeating: nil, count: providers.count)
            for await (index, url) in group { resolved[index] = url }
            return resolved
        }
    }

    // MARK: - Preview during the hover

    /// Files being hovered: it opens/updates the band, makes the preview rectangles follow the
    /// cursor, and — once per hover only — resolves the files so that those rectangles take their
    /// real width. In two stages: the names first (resolving the URLs), then each length as it
    /// comes in. So the rectangles are there from the first instant, at the waiting width, and
    /// reset themselves as they go — no waveform reading here, it is a layout preview, not a clip
    /// rendering.
    @MainActor
    func beginFileDropPreview(providers: [NSItemProvider], location: CGPoint) {
        viewModel.beginFileDropHint(count: providers.count, location: location)
        guard viewModel.claimFileDropPreviewLoad() else { return }
        let vm = viewModel
        Task { @MainActor in
            let urls = await Self.loadDroppedURLs(from: providers)
            var previews = urls.map { url in
                EditViewModel.FileDropPreview(
                    name: url?.deletingPathExtension().lastPathComponent ?? "",
                    duration: nil,
                    // A folder keeps its full name (a dot in it is not an extension).
                    isFolder: url.map(EditViewModel.isDirectoryURL) ?? false)
            }
            for (i, url) in urls.enumerated() where previews[i].isFolder {
                previews[i].name = url?.lastPathComponent ?? ""
            }
            vm.setFileDropPreviews(previews)
            await withTaskGroup(of: (Int, EditViewModel.FolderPreviewMeasure).self) { group in
                for (index, url) in urls.enumerated() {
                    guard let url else { continue }
                    group.addTask { (index, await EditViewModel.measureForPreview(url)) }
                }
                for await (index, measure) in group {
                    // The hover is over (dropped, left, cancelled): nothing left to reset.
                    guard vm.fileDropHint != nil else { break }
                    previews[index].duration = measure.duration
                    previews[index].sequentialDuration = measure.sequentialDuration
                    previews[index].fileCount = measure.fileCount
                    vm.setFileDropPreviews(previews)
                }
            }
        }
    }

    /// Lays the batch down in a single gesture: one `pushUndo` (the import is undone in one go),
    /// one snapshot of `laneEntries` (the display lanes are the ones the user was seeing at the
    /// moment of the drop, not the ones after the first additions). A dropped FOLDER becomes one
    /// folded group named after it, the hierarchy kept (@see FolderImport); it takes one lane and
    /// one slot of the layout, like a file of the same length.
    @MainActor
    private func placeDroppedEntries(_ load: EditViewModel.DropLoad, at location: CGPoint,
                                     mode: EditViewModel.FileDropMode) {
        let vm = viewModel
        defer { vm.reportFolderImportIssues(load) }
        guard !load.entries.isEmpty else { return }
        // A big folder is a big decision (hundreds of tracks): ask before. A multiple drop of plain
        // files was never asked about and stays so.
        let hasFolder = load.entries.contains { if case .folder = $0 { return true } else { return false } }
        if hasFolder, load.fileCount > FolderImport.confirmThreshold {
            guard vm.confirm(L("import.folder.confirm.title"),
                             L("import.folder.confirm.info", load.fileCount),
                             yes: L("import.folder.confirm.yes"),
                             no: L("import.folder.confirm.no"),
                             style: .informational) else { return }
        }
        let baseLane  = max(0, Int((location.y - rulerHeight) / laneStep))
        let baseStart = max(0, vm.snappedTimePure(location.x / pixelsPerSecond))
        vm.pushUndo()
        // The same layout computation as the hover's ghost preview (`fileDropLayout`): what is laid
        // down has to be exactly what was shown under the cursor.
        vm.placeDropEntries(load.entries, baseLane: baseLane, baseStart: baseStart, mode: mode)
    }
}
