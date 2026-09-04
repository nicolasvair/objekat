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

/// True if this provider carries a plugin payload (JSON under `public.plain-text`).
fileprivate func dragCarriesPlugin(_ p: NSItemProvider) -> Bool {
    p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        && !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
}

// The timeline's drop delegate: it drives the cursor's badge live (a plugin drag with no
// modifier = .move (no badge); with ⌥ or ⌘ = .copy (a '+' badge).
// For files (fileURL): .copy by default. The real drop goes through handleDrop.
struct TimelineDropDelegate: DropDelegate {
    let types: [UTType]
    let onPerform: ([NSItemProvider], CGPoint) -> Bool
    // A live 'link' hint: the cursor's position while ⌘ is held over a plugin drag, nil
    // otherwise. Called continuously by dropUpdated → the overlay answers ⌘ live.
    let onLinkIndicator: (CGPoint?) -> Void
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
            onLinkIndicator(f.contains(.command) ? info.location : nil)
            return DropProposal(operation: (f.contains(.option) || f.contains(.command)) ? .copy : .move)
        }
        onLinkIndicator(nil)
        // The files the band really concerns (empty = an internal drag: a plugin).
        // Called again on every movement: that is what makes the preview rectangles follow. It
        // also serves as a net if `dropEntered` did not open the band (the providers not being
        let files = providers.filter(dragCarriesFile)
        if !files.isEmpty { onFileHint(files, info.location) }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        onDropHover?(false)
        onLinkIndicator(nil)
        onFileHintEnd()
    }

    func performDrop(info: DropInfo) -> Bool {
        onDropHover?(false)
        onLinkIndicator(nil)
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
                                Text(name)
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
            // confirmed by decoding successfully. nothing=move ⌥=copy ⌘=copy+link.
            // No `continue`: the decoding is asynchronous, so nothing says here yet that this
            // text IS a plugin payload — we let the following branches try their luck on the
            // same provider (they will disqualify themselves if there is no fileURL).
            if dragCarriesPlugin(provider) {
                let flags = NSEvent.modifierFlags
                provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                    guard let data,
                          let payload = try? JSONDecoder().decode(PluginDragPayload.self, from: data)
                    else { return }
                    Task { @MainActor in
                        guard let targetID = objectID(at: location) else { return }
                        // AN INSTRUMENT (the MIDI zone): it does not join the target's FX chain —
                        // it needs MIDI at its input — but its instrument SLOT. The same three
                        // gestures as for an FX: nothing = move, ⌥ = copy, ⌘ = copy AND
                        // LINK (the two instances are set together).
                        // @see EditViewModel.transferInstrument
                        if viewModel.isInstrument(payload.pluginID, of: payload.sourceObjectID) {
                            viewModel.transferInstrument(
                                sourceObjectID: payload.sourceObjectID,
                                pluginID: payload.pluginID,
                                targetObjectID: targetID,
                                copy: flags.contains(.option) || flags.contains(.command),
                                linked: flags.contains(.command))
                            return
                        }
                        if flags.contains(.command) {
                            guard payload.sourceObjectID != targetID else { return }
                            viewModel.linkAcrossObjects(sourceObjectID: payload.sourceObjectID,
                                                        sourcePluginID: payload.pluginID, targetObjectID: targetID)
                        } else if flags.contains(.option) {
                            viewModel.copyPlugin(sourceObjectID: payload.sourceObjectID,
                                                 pluginID: payload.pluginID, targetObjectID: targetID)
                        } else {
                            guard payload.sourceObjectID != targetID else { return }
                            viewModel.movePlugin(sourceObjectID: payload.sourceObjectID,
                                                 pluginID: payload.pluginID, targetObjectID: targetID)
                        }
                    }
                }
            }
            // Files: the Finder's and the browser's alike, the same path from end to end.
            guard dragCarriesFile(provider) else { continue }
            fileProviders.append(provider)
        }

        guard !fileProviders.isEmpty else { return true }
        Task { @MainActor in
            let files = await Self.loadDroppedFiles(from: fileProviders)
            placeDroppedFiles(files, at: location, mode: dropMode)
        }
        return true
    }

    /// One dropped file, resolved: its URL and its length. Both are read together because both
    /// are read asynchronously and no placement is possible without both.
    struct DroppedFile: Sendable {
        let url: URL
        let duration: Double
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

    /// The URL plus the length of each dropped file, in order, the lengths read in parallel (in
    /// series, a handful of files would have meant waiting for one read after another).
    private static func loadDroppedFiles(from providers: [NSItemProvider]) async -> [DroppedFile] {
        let urls = await loadDroppedURLs(from: providers)
        return await withTaskGroup(of: (Int, DroppedFile).self) { group in
            for (index, url) in urls.enumerated() {
                guard let url else { continue }
                group.addTask { (index, DroppedFile(url: url, duration: await Self.audioDuration(url: url))) }
            }
            var resolved: [(Int, DroppedFile)] = []
            for await pair in group { resolved.append(pair) }
            // (no `\.1` key path here: Swift does not accept one on a tuple element)
            return resolved.sorted { $0.0 < $1.0 }.map { $0.1 }
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
            var previews = urls.map {
                EditViewModel.FileDropPreview(name: $0?.deletingPathExtension().lastPathComponent ?? "",
                                              duration: nil)
            }
            vm.setFileDropPreviews(previews)
            await withTaskGroup(of: (Int, Double).self) { group in
                for (index, url) in urls.enumerated() {
                    guard let url else { continue }
                    group.addTask { (index, await Self.audioDuration(url: url)) }
                }
                for await (index, duration) in group {
                    // The hover is over (dropped, left, cancelled): nothing left to reset.
                    guard vm.fileDropHint != nil else { break }
                    previews[index].duration = duration
                    vm.setFileDropPreviews(previews)
                }
            }
        }
    }

    /// Lays the batch of files down in a single gesture: one `pushUndo` (the import is undone in
    /// one go), one snapshot of `laneEntries` (the display lanes are the ones the user was seeing
    /// at the moment of the drop, not the ones after the first additions).
    @MainActor
    private func placeDroppedFiles(_ files: [DroppedFile], at location: CGPoint,
                                   mode: EditViewModel.FileDropMode) {
        guard !files.isEmpty else { return }
        let baseLane  = max(0, Int((location.y - rulerHeight) / laneStep))
        let baseStart = max(0, viewModel.snappedTimePure(location.x / pixelsPerSecond))

        let snapshot = viewModel.laneEntries
        viewModel.pushUndo()

        // The same layout computation as the hover's ghost preview (`fileDropLayout`): what is laid
        // down has to be exactly what was shown under the cursor.
        let slots = EditViewModel.fileDropLayout(durations: files.map(\.duration), mode: mode,
                                                 baseLane: baseLane, baseStart: baseStart)
        // A SINGLE display → base round trip, on the first item's lane; the following ones are
        // derived in the coordinates of the container it landed in (top level, or the inside of an
        // open group). `baseLaneForDisplay` is not injective: under an unfolded area that is not a
        // group — an open automation band, an open piano roll — several consecutive display lanes
        // fall back onto the SAME base lane. Converted one by one, two pieces of the batch landed at
        // the same instant on the same row and chased each other away through `resolveOverlaps`.
        var containerID: UUID? = nil
        var firstBaseLane = 0
        for (index, (slot, file)) in zip(slots, files).enumerated() {
            var obj = SoundObject(
                id: UUID(),
                startTime: slot.startTime,
                duration: slot.duration,
                lane: slot.lane,
                volume: 0.0,
                pan: 0.0,
                kind: .clip(
                    filePath: file.url.path,
                    sourceOffset: 0,
                    fileDuration: slot.duration,
                    speedRatio: 1.0,
                    isReversed: false
                )
            )
            if index == 0 {
                obj = viewModel.placeClip(obj, snapshot: snapshot)
                containerID   = viewModel.parentGroup(for: obj.id)?.id
                firstBaseLane = obj.lane
            } else {
                obj.lane = firstBaseLane + (slot.lane - slots[0].lane)
                if let containerID {
                    viewModel.addChild(obj, toGroupID: containerID)
                } else {
                    viewModel.add(obj)
                }
            }
            viewModel.resolveOverlaps(for: obj.id)
        }
    }

    private static func audioDuration(url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        do {
            let d = try await asset.load(.duration)
            let s = CMTimeGetSeconds(d)
            return (s.isNaN || s <= 0) ? 5.0 : s
        } catch {
            return 5.0
        }
    }
}
