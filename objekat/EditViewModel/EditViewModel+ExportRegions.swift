import AppKit

// EXPORT, `regions` SCOPE — one file per ticked region of the marker band.
//
// The third value of the span selector, beside "whole project" and "IN–OUT". Each ticked region is
// rendered exactly as the IN–OUT scope renders its range — the same engine path, the same format,
// depth, dither and rate, the MASTER bus — over [region.time, region.endTime], into a file named
// after the region, in the chosen FOLDER.
//
// It is a BATCH, and the design choice worth knowing is that it is not a second export machinery:
// every region is an ordinary `runExport` with an imposed span (`ExportSettings.explicitRange`, the
// API's own way of saying "this range, and leave the IN/OUT markers alone"). The batch only sits
// above: it picks the next region when one ends (`exportBatchRegionDidEnd`, called from the two
// places where a render ends), keeps the results, and answers for the whole. So the progress, the
// waveform, the listening, the cancel and the MP3 path are the existing ones, unchanged.
//
// Sequential by construction: the next region starts only once the previous render has ended —
// "never modify the Edit during an export" — and the batch PINS the active document for its whole
// length (`exportPinsActiveDocument`), even a render on a copy: every region clones the live Edit
// afresh, and a tab switch between two of them would clone the wrong project.
//
// WHICH regions. A region is a `Marker` with a duration, on a ROW of the marker band. Rows that are
// HIDDEN count too (hiding a row is a display choice, not a deletion) and the picker flags them;
// the marks an object carries are not regions for this purpose — they live in the object's frame
// and follow it, they are not the project's own sections. The selection is kept as the set of
// UNTICKED ones (`exportRegionsDeselected`): all ticked the first time, a region laid later is
// ticked too, and the set is transient (not in the session file, emptied on every load).
//
// NAMES. @see RegionExportNaming. Collisions are resolved among the TICKED regions only, in
// start-time order: a file that will not be written cannot collide. The price is that ticking a
// region can rename another one's file — the picker shows every file name live, so it is seen.

// MARK: - What the picker lists

/// A region as the export picker sees it.
struct ExportRegionEntry: Identifiable, Equatable {
    var id: UUID
    var laneID: UUID
    var laneName: String
    var laneColorIndex: Int
    var laneVisible: Bool
    var name: String
    /// The region's own hue, or nil when it takes its row's.
    var colorIndex: Int?
    var start: Double
    var end: Double
    /// 1-based place among ALL the project's regions in start-time order — the number a fallback
    /// name ("Region 3") carries, so that it does not change when another region is ticked.
    var number: Int
    var duration: Double { end - start }
}

/// The regions of one row, for the picker's sections.
struct ExportRegionGroup: Identifiable, Equatable {
    var id: UUID { laneID }
    var laneID: UUID
    var laneName: String
    var laneColorIndex: Int
    var laneVisible: Bool
    var entries: [ExportRegionEntry]
}

/// What is worth a warning on a row. The raw values are the API's (`export.regions.warnings`).
enum ExportRegionWarning: String {
    /// No usable name: the file takes the fallback ("Region 3").
    case emptyName = "empty_name"
    /// The same file name as another ticked region: it carries a " (2)" suffix.
    case duplicateName = "duplicate_name"
    /// A file of that name is already in the folder and will be replaced.
    case fileExists = "file_exists"
}

extension EditViewModel {

    // MARK: - Listing

    /// EVERY region of the project, in start-time order (a total order: start, then end, then the
    /// row's place, then the id — two regions at the same instant must not swap between two
    /// recomputations, or a duplicate's " (2)" would wander from one to the other).
    var exportRegions: [ExportRegionEntry] {
        var raw: [(marker: Marker, lane: MarkerLane, laneIndex: Int)] = []
        for (li, lane) in markerLanes.enumerated() {
            for m in lane.markers where m.isRegion { raw.append((m, lane, li)) }
        }
        raw.sort {
            if $0.marker.time != $1.marker.time { return $0.marker.time < $1.marker.time }
            if $0.marker.endTime != $1.marker.endTime { return $0.marker.endTime < $1.marker.endTime }
            if $0.laneIndex != $1.laneIndex { return $0.laneIndex < $1.laneIndex }
            return $0.marker.id.uuidString < $1.marker.id.uuidString
        }
        return raw.enumerated().map { i, r in
            ExportRegionEntry(id: r.marker.id, laneID: r.lane.id, laneName: r.lane.name,
                              laneColorIndex: r.lane.colorIndex, laneVisible: r.lane.isVisible,
                              name: r.marker.name, colorIndex: r.marker.colorIndex,
                              start: r.marker.time, end: r.marker.endTime, number: i + 1)
        }
    }

    /// The same regions, sectioned by row (in the band's order), each section in start-time order.
    var exportRegionGroups: [ExportRegionGroup] {
        let all = exportRegions
        return markerLanes.compactMap { lane in
            let mine = all.filter { $0.laneID == lane.id }
            guard !mine.isEmpty else { return nil }
            return ExportRegionGroup(laneID: lane.id, laneName: lane.name,
                                     laneColorIndex: lane.colorIndex, laneVisible: lane.isVisible,
                                     entries: mine)
        }
    }

    // MARK: - Selection

    func isExportRegionSelected(_ id: UUID) -> Bool { !exportRegionsDeselected.contains(id) }

    /// The regions that would be exported now, in start-time order.
    var selectedExportRegions: [ExportRegionEntry] {
        exportRegions.filter { isExportRegionSelected($0.id) }
    }

    func setExportRegion(_ id: UUID, selected: Bool) {
        if selected { exportRegionsDeselected.remove(id) } else { exportRegionsDeselected.insert(id) }
    }

    func toggleExportRegion(_ id: UUID) {
        setExportRegion(id, selected: !isExportRegionSelected(id))
    }

    func selectAllExportRegions() { exportRegionsDeselected = [] }

    func selectNoExportRegions() { exportRegionsDeselected = Set(exportRegions.map(\.id)) }

    func invertExportRegions() {
        let all = Set(exportRegions.map(\.id))
        exportRegionsDeselected = all.subtracting(exportRegionsDeselected)
    }

    // MARK: - Names

    /// The file name each of these regions would get, for the given ones in start-time order.
    private func exportRegionNames(for entries: [ExportRegionEntry])
        -> [UUID: RegionExportNaming.Assigned] {
        let assigned = RegionExportNaming.assign(
            names: entries.map(\.name), numbers: entries.map(\.number),
            fallback: { L("export.regions.fallbackName", $0) })
        var out: [UUID: RegionExportNaming.Assigned] = [:]
        for (e, a) in zip(entries, assigned) { out[e.id] = a }
        return out
    }

    /// The file name (without extension) of every TICKED region, as it would be written now.
    var exportRegionFileNames: [UUID: RegionExportNaming.Assigned] {
        exportRegionNames(for: selectedExportRegions)
    }

    /// The warnings of the ticked regions. The "file exists" one reads the disk, so it is only
    /// asked for by the panel and the API — never by anything drawn every frame.
    func exportRegionWarnings(names: [UUID: RegionExportNaming.Assigned],
                              settings: ExportSettings) -> [UUID: [ExportRegionWarning]] {
        let fm = FileManager.default
        var out: [UUID: [ExportRegionWarning]] = [:]
        for (id, a) in names {
            var w: [ExportRegionWarning] = []
            if a.usedFallback { w.append(.emptyName) }
            if a.wasDeduplicated { w.append(.duplicateName) }
            let url = settings.folder.appendingPathComponent(a.base)
                .appendingPathExtension(settings.format.fileExtension)
            if fm.fileExists(atPath: url.path) { w.append(.fileExists) }
            if !w.isEmpty { out[id] = w }
        }
        return out
    }

    /// The renders a launch would make: the ids given (API) or else the ticked regions, frozen
    /// with their file names. An id that is not a region is left out — the caller checks.
    func exportRegionTargets(ids: [UUID]?) -> [ExportBatch.Target] {
        let chosen: [ExportRegionEntry]
        if let ids {
            let wanted = Set(ids)
            chosen = exportRegions.filter { wanted.contains($0.id) }
        } else {
            chosen = selectedExportRegions
        }
        let names = exportRegionNames(for: chosen)
        return chosen.map { e in
            ExportBatch.Target(id: e.id, regionName: e.name,
                               fileBase: names[e.id]?.base ?? "Region \(e.number)",
                               start: e.start, end: e.end)
        }
    }

    /// "Region 3 of 5 — Verse", or nil when no batch is under way.
    var exportBatchProgressLabel: String? {
        guard let b = exportBatch, let t = b.currentTarget else { return nil }
        let name = t.regionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return L("export.regions.progress", b.current + 1, b.total, name.isEmpty ? t.fileBase : name)
    }

    // MARK: - Launching

    /// Validates, asks about overwriting ONCE, then renders the first region. The following ones
    /// are chained by `exportBatchRegionDidEnd`.
    func runRegionsExport(_ settings: ExportSettings, persistingPreferences: Bool) {
        guard engine != nil else { return }
        guard exportJob?.isRunning != true, exportBatch?.isActive != true else { return }

        if let ids = settings.regionIDs {
            let known = Set(exportRegions.map(\.id))
            if !Set(ids).isSubset(of: known) {
                exportAlert(L("export.error.noRegions.title"), L("export.error.noRegions.info"))
                return
            }
        }
        let targets = exportRegionTargets(ids: settings.regionIDs)
        guard !targets.isEmpty else {
            exportAlert(L("export.error.noRegions.title"), L("export.error.noRegions.info"))
            return
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: settings.folder.path, isDirectory: &isDir), isDir.boolValue,
              fm.isWritableFile(atPath: settings.folder.path) else {
            exportAlert(L("export.error.folder.title"),
                        L("export.error.folder.info", settings.folder.lastPathComponent))
            return
        }

        var batch = ExportBatch(targets: targets, settings: settings)
        let existing = targets.filter { fm.fileExists(atPath: batch.url(for: $0).path) }.count
        if existing > 0 {
            let ok = confirm(Ln("export.regions.overwrite.title", existing, existing),
                             L("export.regions.overwrite.info", settings.folder.lastPathComponent),
                             yes: L("export.overwrite.replace"), no: L("common.cancel"))
            if !ok { return }
        }

        if persistingPreferences { persistExportPreferences(settings) }
        batch.settings.regionIDs = nil
        exportBatch = batch
        launchNextBatchRegion()
    }

    /// Renders the region at `batch.current`, or closes the batch when there is none left. A region
    /// whose render is REFUSED before any work (no job is made) is recorded as failed and the loop
    /// moves on to the next, so one bad region never silently ends the batch.
    func launchNextBatchRegion() {
        guard var batch = exportBatch, batch.isActive else { return }
        while batch.isActive {
            if batch.cancelRequested {
                for i in batch.current..<batch.total { batch.outcomes[i] = .cancelled }
                batch.current = batch.total
                break
            }
            let i = batch.current
            let target = batch.targets[i]
            var s = batch.settings
            s.name = target.fileBase
            s.explicitRange = target.start...target.end
            s.regionIDs = nil
            batch.outcomes[i] = .running
            exportBatch = batch

            runExport(s, persistingPreferences: false, confirmedOverwrite: true)

            if exportJob?.isRunning == true, exportJob?.destination == s.destinationURL {
                return   // under way: `exportBatchRegionDidEnd` will come back here
            }
            // Refused before it started.
            batch = exportBatch ?? batch
            batch.outcomes[i] = .failed(L("export.error.renderFailed"))
            batch.current += 1
        }
        exportBatch = batch
        finishExportBatch()
    }

    /// Called by the two places where a render ends (`placeExportResult`, `finishExportWithFailure`).
    /// A no-op outside a batch.
    func exportBatchRegionDidEnd(failure: String?, cancelled: Bool) {
        guard var batch = exportBatch, batch.isActive else { return }
        let i = batch.current
        if let failure {
            batch.outcomes[i] = cancelled ? .cancelled : .failed(failure)
        } else {
            batch.outcomes[i] = .done
        }
        batch.current += 1
        if cancelled { batch.cancelRequested = true }
        if batch.cancelRequested {
            for k in batch.current..<batch.total { batch.outcomes[k] = .cancelled }
            batch.current = batch.total
        }
        exportBatch = batch
        if batch.isActive {
            // Not from inside the ending render's own callback: `runExport` is still finishing its
            // bookkeeping on the job it launched, and a new job made under its feet would be
            // mistaken for that one. The batch stays active meanwhile, so nothing reads it as over.
            DispatchQueue.main.async { [weak self] in self?.launchNextBatchRegion() }
        } else {
            finishExportBatch()
        }
    }

    /// The batch is over: one sentence for the whole, and the job takes its colour.
    private func finishExportBatch() {
        guard let batch = exportBatch else { return }
        let folderName = batch.settings.folder.lastPathComponent
        let done = batch.doneCount, failed = batch.failedCount
        let summary: String
        if batch.cancelRequested || batch.cancelledCount > 0 {
            summary = L("export.regions.result.cancelled", done, batch.total)
        } else if failed > 0 {
            let names = zip(batch.targets, batch.outcomes).compactMap { t, o -> String? in
                if case .failed = o { return t.fileBase } else { return nil }
            }.joined(separator: ", ")
            summary = L("export.regions.result.partial", done, failed, names)
        } else {
            summary = Ln("export.regions.result.ok", done, done, folderName)
        }
        if exportJob != nil {
            exportJob?.batchResult = summary
            if failed > 0 || batch.cancelledCount > 0 {
                exportJob?.phase = .failed(summary)
                exportJob?.progress = 0
            } else {
                exportJob?.phase = .finished
                exportJob?.progress = 1
            }
        }
        exportCancelFlag = nil
        scheduleExportStatusClear(after: failed > 0 ? 12 : 20)
        // A failure is reported ONCE, here, naming the regions; a cancellation is the hand's own
        // decision and needs no modal.
        if failed > 0 && !batch.cancelRequested {
            exportAlert(L("export.phase.failed"), summary)
        }
    }
}
