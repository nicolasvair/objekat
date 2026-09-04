import AppKit
import UniformTypeIdentifiers

// EXPORT — rendering the full mix into a file (File ▸ Export…, ⌘E).
//
// The window closes as soon as the render starts and a full-width banner under the transport
// shows the progress and allows cancelling. Two regimes, chosen in the window:
//
//   • DIRECT (the default) — the engine renders the live project, with its plugins already loaded: the
//     render starts straight away. Playback is suspended for the length of the render and the project
//     must not be modified during that time.
//   • BACKGROUND — the engine renders a COPY: you can go on playing and editing, but the
//     copy instantiates every AU in the project BEFORE starting, with the main thread blocked (the
//     banner's "Preparing" phase, [PERF] milestones on the engine side). That is what can take time.
//
// Two output paths:
//   • WAV  — the engine writes directly at the depth asked for (16/24 bits, dithering below 32);
//   • MP3  — the engine writes a temporary floating-point wave at the final rate, which libmp3lame
//            then converts (@see Mp3Encoder: macOS cannot encode MP3).
//
// In both cases the render goes to a TEMPORARY file laid in the destination folder, and
// it is only put in place once the render has succeeded: a cancelled or failed export cannot
// leave a truncated file in place of the one it was overwriting.

extension EditViewModel {

    // MARK: - Preference keys

    private static let exportFormatKey     = "export.format"
    private static let exportSampleRateKey = "export.sampleRate"
    private static let exportBitDepthKey   = "export.bitDepth"
    private static let exportDitheringKey  = "export.dithering"
    private static let exportTimeFieldKey  = "export.timeFieldMode"
    private static let exportBackgroundKey = "export.renderInBackground"

    // MARK: - Opening the window

    /// The end of the content: the last instant when something sounds at the top level. The children
    /// of a group that would overrun its window are already silent — this really is the AUDIBLE span.
    var projectContentEnd: Double {
        items.map { $0.startTime + $0.duration }.max() ?? 0
    }

    func openExportPanel() {
        if exportJob?.isRunning == true {
            exportAlert(L("export.error.alreadyRunning.title"), L("export.error.alreadyRunning.info"))
            return
        }
        guard projectContentEnd > 0 else {
            exportAlert(L("export.error.nothing.title"), L("export.error.noObjects.info"))
            return
        }
        var s = makeExportSettings()
        s.clampToFormat()
        exportSettings = s
        exportPanelPresented = true
        revealExportRange(s)
    }

    /// The initial settings: the format kept from the last export, the project's folder and name.
    private func makeExportSettings() -> ExportSettings {
        let d = UserDefaults.standard
        let format = ExportSettings.FileFormat(rawValue: d.string(forKey: Self.exportFormatKey) ?? "")
            ?? .mp3
        let rate = d.double(forKey: Self.exportSampleRateKey)
        let depth = d.integer(forKey: Self.exportBitDepthKey)
        // The unit of the IN/OUT fields: the last export choice if there was one, otherwise the timeline's
        // grid mode — the one the user already reads their project in.
        let timeField = GridMode(rawValue: d.string(forKey: Self.exportTimeFieldKey) ?? "")
            ?? gridMode
        // `bool(forKey:)` is false when the key does not exist: without this existence test,
        // dithering would be unchecked on the first export instead of following its default (on).
        let dithering = d.object(forKey: Self.exportDitheringKey) as? Bool ?? true
        // The project's folder is the expected destination ("it saves into the folder with the
        // same name"); with no saved project, the desktop rather than an arbitrary folder.
        let folder = projectFolder
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let name = (projectName == L("project.untitled") || projectName.isEmpty) ? L("export.defaultName") : projectName
        return ExportSettings(rangeMode: loopRegion != nil ? .inOut : .wholeProject,
                              timeFieldMode: timeField,
                              renderInBackground: d.bool(forKey: Self.exportBackgroundKey),
                              format: format,
                              sampleRate: rate > 0 ? rate : 44100,
                              bitDepth: depth > 0 ? depth : 24,
                              dithering: dithering,
                              folder: folder,
                              name: name)
    }

    private func persistExportPreferences(_ s: ExportSettings) {
        let d = UserDefaults.standard
        d.set(s.format.rawValue, forKey: Self.exportFormatKey)
        d.set(s.sampleRate, forKey: Self.exportSampleRateKey)
        d.set(s.bitDepth, forKey: Self.exportBitDepthKey)
        d.set(s.dithering, forKey: Self.exportDitheringKey)
        d.set(s.timeFieldMode.rawValue, forKey: Self.exportTimeFieldKey)
        d.set(s.renderInBackground, forKey: Self.exportBackgroundKey)
    }

    /// Keeps the unit of the IN/OUT fields as soon as it changes, without waiting for an export: switching
    /// Time ↔ BPM then giving up on exporting is still a choice, and it is found again on reopening.
    func persistExportTimeFieldMode(_ mode: GridMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: Self.exportTimeFieldKey)
    }

    // MARK: - The time span

    /// The range to render for these settings, or nil if it is empty (no IN-OUT laid down, an empty project).
    func exportTimeRange(for settings: ExportSettings) -> ClosedRange<Double>? {
        // An imposed span wins over the mode: that is the API's path, which does not touch
        // the I/O markers. @see ExportSettings.explicitRange
        if let forced = settings.explicitRange, forced.upperBound > forced.lowerBound {
            return forced
        }
        switch settings.rangeMode {
        case .wholeProject:
            let end = projectContentEnd
            return end > 0 ? 0...end : nil
        case .inOut:
            guard let r = loopRegion, r.upperBound > r.lowerBound else { return nil }
            return r
        }
    }

    /// Guarantees an IN-OUT zone when switching to this mode: the time selection if it
    /// exists, otherwise the whole project. The I/O markers then appear on the ruler.
    func ensureExportInOutRange() {
        if loopRegion == nil {
            if let ts = timeSelection, ts.timeRange.upperBound > ts.timeRange.lowerBound {
                loopRegion = ts.timeRange
            } else {
                loopRegion = 0...max(1, projectContentEnd)
            }
        }
        revealExportRange()
    }

    /// Changes the span mode and reframes the view onto it (the window's selector switching).
    func setExportRangeMode(_ mode: ExportSettings.TimeRangeMode) {
        exportSettings.rangeMode = mode
        if mode == .inOut { ensureExportInOutRange() } else { revealExportRange() }
    }

    /// Moves the IN marker. The bound stays before the OUT (a 50 ms guard, as when dragging the
    /// flags on the ruler) and the view realigns to show the whole zone.
    func setExportInPoint(_ t: Double) {
        guard let r = loopRegion else { return }
        let lo = min(max(0, t), r.upperBound - 0.05)
        loopRegion = lo...r.upperBound
        revealExportRange()
    }

    /// Moves the OUT marker (see `setExportInPoint`).
    func setExportOutPoint(_ t: Double) {
        guard let r = loopRegion else { return }
        let hi = max(t, r.lowerBound + 0.05)
        loopRegion = r.lowerBound...hi
        revealExportRange()
    }

    /// Asks the timeline to show the whole IN-OUT zone (zoom + scroll). Called when
    /// the window opens and on every change of bounds or of mode: the view follows the
    /// setting by itself, there is nothing to click for that.
    ///
    /// ONLY in IN-OUT mode: there, bounds that need to be seen are being set. Reframing on
    /// "the whole project" too would lose the user their zoom to show them nothing they
    /// do not already know.
    /// @see TimelineView, which consumes `pendingRangeReveal`.
    func revealExportRange(_ settings: ExportSettings? = nil) {
        let s = settings ?? exportSettings
        guard s.rangeMode == .inOut, let r = exportTimeRange(for: s) else { return }
        pendingRangeReveal = r
    }

    // MARK: - Launching

    /// Validates the settings, confirms any overwrite, then launches the background render.
    /// - Parameter persistingPreferences: keep this format/rate as the WINDOW's next
    ///   default. True for an export launched by hand — that is how the window
    ///   remembers. False for an export driven by the API: a script rendering a check MP3
    ///   has no business changing what the window will offer next. The API already READS no
    ///   preference; it would be inconsistent for it to WRITE one.
    func runExport(_ settings: ExportSettings, persistingPreferences: Bool = true) {
        guard let engine else { return }
        guard exportJob?.isRunning != true else { return }
        guard let range = exportTimeRange(for: settings) else {
            exportAlert(L("export.error.emptyRange.title"),
                        settings.rangeMode == .inOut
                        ? L("export.error.emptyRange.info")
                        : L("export.error.noObjects.info"))
            return
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: settings.folder.path, isDirectory: &isDir), isDir.boolValue,
              fm.isWritableFile(atPath: settings.folder.path) else {
            exportAlert(L("export.error.folder.title"), L("export.error.folder.info", settings.folder.lastPathComponent))
            return
        }

        let destination = settings.destinationURL
        if fm.fileExists(atPath: destination.path), !confirmOverwrite(destination) { return }

        // Working files in the destination folder: the same volume, so the final
        // putting in place is a simple (atomic) rename, with no copying.
        let stem = ".objekat-export-\(UUID().uuidString.prefix(8))"
        let renderTarget = settings.folder.appendingPathComponent(stem + ".wav")

        if persistingPreferences { persistExportPreferences(settings) }
        exportPanelPresented = false
        // A direct render: the engine is going to suspend playback (it renders the live project). It is
        // asked of the view BEFORE, so that the interface's transport agrees with what
        // the engine is about to do.
        if !settings.renderInBackground { pendingPlaybackStop = true }
        exportCancelFlag = ExportCancelFlag()
        exportStatusClearWork?.cancel()
        exportStatusClearWork = nil
        exportJob = ExportJob(phase: .preparing, progress: 0,
                              destination: destination, settings: settings)
        startExportProgressPolling()

        // MP3 goes through a FLOATING-POINT wave (32 bits): it is an intermediate, no reason
        // to quantise it before encoding it.
        let renderBitDepth = settings.format == .wav ? settings.bitDepth : 32

        // WHY THIS DEFERRAL: in a render on a copy, `exportMixToFileAsync` only returns
        // after cloning the Edit, which INSTANTIATES every plugin in the project on the main
        // thread — several seconds when there are AUs. Called straight away, that freeze
        // would land BEFORE SwiftUI had drawn the progress bar: the app would look frozen
        // with nothing shown, which was precisely the symptom. So one frame is let
        // through (long enough for the bar to be on screen, in the "Preparing" phase), and then it launches.
        // In a direct render there is nothing to instantiate: the "Preparing" phase lasts only that
        // one frame, and that is exactly the point of the setting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, let engine = self.engine, self.exportJob?.phase == .preparing else { return }
            engine.exportMix(toFileAsync: renderTarget.path,
                             start: range.lowerBound, end: range.upperBound,
                             sampleRate: settings.sampleRate,
                             bitDepth: renderBitDepth,
                             dithering: settings.format == .wav && settings.dithering,
                             onEditCopy: settings.renderInBackground) { [weak self] ok, errorMessage in
                guard let self else { return }
                self.stopExportProgressPolling()
                guard ok else {
                    try? FileManager.default.removeItem(at: renderTarget)
                    self.finishExportWithFailure(errorMessage ?? L("export.error.renderFailed"))
                    return
                }
                switch settings.format {
                case .wav:
                    self.placeExportResult(from: renderTarget, to: destination)
                case .mp3:
                    self.encodeExportToMp3(renderedWave: renderTarget,
                                           destination: destination,
                                           settings: settings)
                }
            }
            // The call has returned: the clone is made, the render is running on its own thread.
            // (Except on an immediate failure, which has already set the `failed` phase — hence the guard.)
            if self.exportJob?.phase == .preparing { self.exportJob?.phase = .rendering }
        }
    }

    /// Cancels the export under way: the engine stops at the next block, the MP3 encoder at the next
    /// packet. The cleaning up is done in the common failure path.
    func cancelExport() {
        exportCancelFlag?.cancel()
        engine?.cancelExport()
    }

    // MARK: - The MP3 phase

    private func encodeExportToMp3(renderedWave: URL, destination: URL, settings: ExportSettings) {
        exportJob?.phase = .encoding
        exportJob?.progress = Self.renderShareOfMp3Export
        let mp3Target = renderedWave.deletingPathExtension().appendingPathExtension("mp3")
        let flag = exportCancelFlag ?? ExportCancelFlag()
        let bitrate = ExportSettings.mp3BitrateKbps

        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String? = nil
            do {
                try Mp3Encoder.encode(source: renderedWave, destination: mp3Target,
                                      bitrateKbps: bitrate,
                                      progress: { p in
                                          DispatchQueue.main.async { [weak self] in
                                              guard let self, self.exportJob?.phase == .encoding else { return }
                                              self.exportJob?.progress = Self.renderShareOfMp3Export
                                                  + p * (1 - Self.renderShareOfMp3Export)
                                          }
                                      },
                                      isCancelled: { flag.isCancelled })
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            let fm = FileManager.default
            try? fm.removeItem(at: renderedWave)   // the intermediate never survives the encoding

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let failure {
                    try? fm.removeItem(at: mp3Target)
                    self.finishExportWithFailure(failure)
                } else {
                    self.placeExportResult(from: mp3Target, to: destination)
                }
            }
        }
    }

    /// The share of the progress bar taken by the render when an MP3 encoding follows.
    private static let renderShareOfMp3Export = 0.8

    // MARK: - The end

    /// Puts the working file in place, replacing the destination if it exists
    /// (the overwrite was confirmed before launching).
    private func placeExportResult(from temp: URL, to destination: URL) {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temp, to: destination)
        } catch {
            try? fm.removeItem(at: temp)
            finishExportWithFailure(L("export.error.move", error.localizedDescription))
            return
        }
        exportJob?.phase = .finished
        exportJob?.progress = 1
        exportCancelFlag = nil
        scheduleExportStatusClear(after: 20)
    }

    private func finishExportWithFailure(_ message: String) {
        let wasCancelled = exportCancelFlag?.isCancelled == true || message == "Cancelled"
        exportCancelFlag = nil
        exportJob?.phase = .failed(wasCancelled ? L("export.error.cancelledShort") : message)
        exportJob?.progress = 0
        scheduleExportStatusClear(after: wasCancelled ? 4 : 12)
        // A cancellation is the user's decision: the banner is enough, no modal.
        if !wasCancelled { exportAlert(L("export.phase.failed"), message) }
    }

    /// Clears the banner afterwards (it stays a while so the result can be read and the
    /// file revealed).
    private func scheduleExportStatusClear(after seconds: Double) {
        exportStatusClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.exportJob?.isRunning != true else { return }
            self.exportJob = nil
        }
        exportStatusClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Closes the banner at once (the ✕ button after an export has finished or failed).
    func dismissExportStatus() {
        guard exportJob?.isRunning != true else { return }
        exportStatusClearWork?.cancel()
        exportStatusClearWork = nil
        exportJob = nil
    }

    func revealExportedFileInFinder() {
        guard let url = exportJob?.destination,
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Progress

    private func startExportProgressPolling() {
        exportProgressTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let engine = self.engine, self.exportJob?.phase == .rendering else { return }
                let p = Double(engine.exportProgress())
                let share = self.exportJob?.settings.format == .mp3 ? Self.renderShareOfMp3Export : 1
                self.exportJob?.progress = min(1, max(0, p)) * share
            }
        }
        exportProgressTimer = timer
        RunLoop.main.add(timer, forMode: .common)   // goes on beating while a menu is open
    }

    private func stopExportProgressPolling() {
        exportProgressTimer?.invalidate()
        exportProgressTimer = nil
    }

    // MARK: - Dialogues

    /// Overwrite an existing file? Goes through `confirm`: from the interface the modal
    /// shows as before, but an export driven by the API decides according to `dialogPolicy` instead
    /// of freezing the process on an invisible alert. See EditViewModel+Dialogs.
    private func confirmOverwrite(_ url: URL) -> Bool {
        confirm(L("export.overwrite.title", url.lastPathComponent),
                L("export.overwrite.info", url.deletingLastPathComponent().lastPathComponent),
                yes: L("export.overwrite.replace"), no: L("common.cancel"))
    }

    /// The same reason as `confirmOverwrite`: the message must survive the absence of a window.
    func exportAlert(_ title: String, _ info: String) {
        notify(title, info)
    }

    /// The destination folder picker (the name itself is typed in the export window).
    func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.title = L("export.chooseFolder.title")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = exportSettings.folder
        if panel.runModal() == .OK, let url = panel.url {
            exportSettings.folder = url
        }
    }
}

// MARK: - Typable time

/// The seconds ↔ "m:ss,cc" conversion for the export window's IN/OUT fields. The input is
/// tolerant: "90", "1:30", "1:30,5" and "1:30.50" all mean 90 s.
enum ExportTimecode {

    static func string(_ seconds: Double) -> String {
        let t = max(0, seconds)
        let m = Int(t) / 60
        let s = Int(t) % 60
        let cs = Int((t - t.rounded(.down)) * 100 + 0.5) % 100
        return String(format: "%d:%02d,%02d", m, s, cs)
    }

    static func seconds(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        let parts = cleaned.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return Double(parts[0])
        case 2:
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            return m * 60 + s
        case 3:   // h:m:s, in case a long session is shown that way elsewhere
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2])
            else { return nil }
            return h * 3600 + m * 60 + s
        default:
            return nil
        }
    }
}

// MARK: - Musical time

/// The seconds ↔ "bar:beat:tick" conversion for the IN/OUT fields when the export is set
/// to musical units. Bars and beats are numbered from 1 (like the ruler, which
/// labels its first bar "1") and ticks from 0.
///
/// A bar is `timeSigNumerator` crotchets: that is the convention already applied by the timeline's grid
/// and ruler, which ignore the denominator. Staying consistent with what is seen
/// on screen takes precedence here over theoretical rigour.
enum MusicalTimecode {

    /// Ticks per beat. 960 is the resolution of the sequencers that show this format (Pro Tools,
    /// Logic): beyond it the tick is no longer legible; below it, a triplet semiquaver can no
    /// longer be pointed at without rounding.
    static let ticksPerBeat = 960

    static func string(_ seconds: Double, tempo: Double, beatsPerBar: Int) -> String {
        let bpb = max(1, beatsPerBar)
        let beatsTotal = max(0, seconds) * max(1, tempo) / 60
        var bar  = Int(beatsTotal) / bpb
        var beat = Int(beatsTotal) % bpb
        var tick = Int(((beatsTotal - beatsTotal.rounded(.down)) * Double(ticksPerBeat)).rounded())
        // The tick's rounding can carry over into the beat, and the beat's into the bar: without these carries
        // "3:4:960" would be shown instead of "4:1:000".
        if tick >= ticksPerBeat { tick = 0; beat += 1 }
        if beat >= bpb          { beat = 0; bar  += 1 }
        return String(format: "%d:%d:%03d", bar + 1, beat + 1, tick)
    }

    /// Tolerant input: "5" = bar 5 on its first beat, "5:3" = bar 5 beat 3,
    /// "5:3:480" = plus half a beat. Values out of bounds are accepted and carried over
    /// ("1:9" in 4/4 means "3:1") — that is more useful than refusing the keystroke.
    static func seconds(_ text: String, tempo: Double, beatsPerBar: Int) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        let numbers = parts.map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard let first = numbers[0], numbers.allSatisfy({ $0 != nil }) else { return nil }

        let bar  = first - 1
        let beat = parts.count > 1 ? (numbers[1] ?? 1) - 1 : 0
        let tick = parts.count > 2 ? (numbers[2] ?? 0) : 0
        let beats = bar * Double(max(1, beatsPerBar)) + beat + tick / Double(ticksPerBeat)
        return max(0, beats) * 60 / max(1, tempo)
    }
}
