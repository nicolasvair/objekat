import SwiftUI
import AppKit

// The export panel (File ▸ Export…). A compact sheet: it leaves the timeline visible underneath,
// which matters — setting IN and OUT here MOVES the ruler's markers, and the view reframes
// itself on the exported range at every change. @see EditViewModel+Export
//
// The IN/OUT fields take seconds or bar:beat:tick, as you like: the setting does NOT touch the
// timeline's grid mode, it concerns this panel alone (and it is kept from one export to the
// next).

struct ExportPanelView: View {
    @Bindable var viewModel: EditViewModel

    @State private var inText: String = ""
    @State private var outText: String = ""
    @FocusState private var focusedField: Field?

    private enum Field { case inPoint, outPoint, name }

    private var settings: ExportSettings { viewModel.exportSettings }

    /// The unit of the IN/OUT fields (seconds or bars) — the export's own.
    private var timeFieldMode: GridMode { settings.timeFieldMode }

    /// The range that will be rendered, as the view-model computes it (the single source of truth).
    private var range: ClosedRange<Double>? { viewModel.exportTimeRange(for: settings) }

    private var durationLabel: String {
        guard let r = range else { return "—" }
        return ExportTimecode.string(r.upperBound - r.lowerBound)
    }

    /// The length in bars, alongside the time when one thinks musically. It is a LENGTH, not an
    /// instant: it counts from zero, hence the direct computation rather than going through
    /// `MusicalTimecode` (which numbers the first bar '1').
    private var durationInBars: String? {
        guard timeFieldMode == .bpm, let r = range else { return nil }
        let beats = (r.upperBound - r.lowerBound) * viewModel.tempo / 60
        let bars = beats / Double(max(1, viewModel.timeSigNumerator))
        return String(format: bars < 10 ? L("export.duration.barsFine") : L("export.duration.bars"), bars)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("export.panel.title"))
                .font(.system(size: 15, weight: .semibold))

            timeRangeSection
            Divider()
            formatSection
            Divider()
            destinationSection
            Divider()
            renderModeSection

            HStack {
                Text(estimatedSizeLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(L("common.cancel")) { viewModel.exportPanelPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(L("export.panel.run")) { viewModel.runExport(viewModel.exportSettings) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(range == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: syncTimeFields)
        .onChange(of: viewModel.loopRegion) { _, _ in syncTimeFields() }
        // Changing unit does not touch the bounds: we show the same instants differently.
        .onChange(of: settings.timeFieldMode) { _, _ in syncTimeFields() }
    }

    // MARK: - Time selection

    @ViewBuilder
    private var timeRangeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker(noLabel, selection: Binding(
                    get: { settings.rangeMode },
                    set: { mode in
                        // The view-model sets the range if needed and reframes the view: the panel
                        // has nothing left to do but redisplay the fields.
                        viewModel.setExportRangeMode(mode)
                        syncTimeFields()
                    })) {
                    ForEach(ExportSettings.TimeRangeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if settings.rangeMode == .inOut { timeFieldModePicker }
            }

            if settings.rangeMode == .inOut {
                HStack(spacing: 10) {
                    timeField("IN", text: $inText, field: .inPoint) { t in
                        viewModel.setExportInPoint(t)
                    }
                    timeField("OUT", text: $outText, field: .outPoint) { t in
                        viewModel.setExportOutPoint(t)
                    }
                    Spacer()
                }
            }

            HStack(spacing: 6) {
                Text(L("export.field.duration"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(durationLabel)
                    .font(.system(size: 11, design: .monospaced))
                if let bars = durationInBars {
                    Text(verbatim: "(\(bars))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if range == nil {
                    Text(L("export.range.empty"))
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// The unit the bounds are typed in. The same labels as the transport bar's grid selector
    /// (Time / BPM), so that one recognises what one is choosing — but a separate setting:
    /// it changes nothing in the project's display.
    @ViewBuilder
    private var timeFieldModePicker: some View {
        Picker(noLabel, selection: Binding(
            get: { settings.timeFieldMode },
            set: { mode in
                viewModel.exportSettings.timeFieldMode = mode
                viewModel.persistExportTimeFieldMode(mode)
            })) {
            Text(L("transport.grid.time")).tag(GridMode.time)
            Text(L("transport.grid.bpm")).tag(GridMode.bpm)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 92)
        .controlSize(.small)
        .help(L("export.timeField.help"))
    }

    /// A bound field, in the current unit ('m:ss,cc' or 'bar:beat:tick'). Like the transport bar's
    /// BPM field: we commit on Return AND on losing focus, and redisplay the value the model kept
    /// (so, bounded) rather than what was typed.
    @ViewBuilder
    private func timeField(_ label: String,
                           text: Binding<String>,
                           field: Field,
                           commit: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField(noLabel, text: text)
                .frame(width: 84)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 11, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: field)
                .onSubmit {
                    if let t = parseTime(text.wrappedValue) { commit(t) }
                    syncTimeFields()
                }
                .onChange(of: focusedField) { _, now in
                    guard now != field else { return }
                    if let t = parseTime(text.wrappedValue) { commit(t) }
                    syncTimeFields()
                }
        }
    }

    /// Reading a bound in the current unit. The model itself knows only seconds: that is what
    /// allows switching unit without recomputing anything on the project's side.
    private func parseTime(_ text: String) -> Double? {
        timeFieldMode == .bpm
            ? MusicalTimecode.seconds(text, tempo: viewModel.tempo,
                                      beatsPerBar: viewModel.timeSigNumerator)
            : ExportTimecode.seconds(text)
    }

    private func formatTime(_ seconds: Double) -> String {
        timeFieldMode == .bpm
            ? MusicalTimecode.string(seconds, tempo: viewModel.tempo,
                                     beatsPerBar: viewModel.timeSigNumerator)
            : ExportTimecode.string(seconds)
    }

    private func syncTimeFields() {
        guard let r = viewModel.loopRegion else { inText = ""; outText = ""; return }
        if focusedField != .inPoint  { inText  = formatTime(r.lowerBound) }
        if focusedField != .outPoint { outText = formatTime(r.upperBound) }
    }

    // MARK: - Format

    @ViewBuilder
    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker(noLabel, selection: Binding(
                    get: { settings.format },
                    set: { f in
                        viewModel.exportSettings.format = f
                        viewModel.exportSettings.clampToFormat()
                    })) {
                    ForEach(ExportSettings.FileFormat.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
                Text(settings.format == .wav ? L("export.format.pcmStereo") : L("export.format.mp3Stereo", ExportSettings.mp3BitrateKbps))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            HStack(spacing: 12) {
                Picker(noLabel, selection: $viewModel.exportSettings.sampleRate) {
                    ForEach(settings.format.sampleRates, id: \.self) { hz in
                        Text(ExportSettings.sampleRateLabel(hz)).tag(hz)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                .help(L("audio.menu.sampleRate"))

                if settings.format == .wav {
                    // The 'Resolution' label has gone: the picker already says '16 bit' and
                    // '24 bit', and the explanation fits in the tooltip.
                    Picker(noLabel, selection: $viewModel.exportSettings.bitDepth) {
                        Text(L("export.bitDepth.16")).tag(16)
                        Text(L("export.bitDepth.24")).tag(24)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                }
                Spacer()
            }

            if settings.format == .wav {
                Toggle(isOn: $viewModel.exportSettings.dithering) {
                    Text(L("export.dithering"))
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    // MARK: - Destination

    @ViewBuilder
    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(L("export.field.folder"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)
                Text(settings.folder.path.replacingOccurrences(
                        of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L("common.choose")) { viewModel.chooseExportFolder() }
                    .controlSize(.small)
            }

            HStack(spacing: 12) {
                Text(L("export.field.name"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)
                TextField(noLabel, text: $viewModel.exportSettings.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .focused($focusedField, equals: .name)
                Text(verbatim: ".\(settings.format.fileExtension)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if FileManager.default.fileExists(atPath: settings.destinationURL.path) {
                Label(L("export.file.exists"), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Render mode

    /// Direct or in the background. The trade-off is real in both directions, hence a sentence that
    /// changes with the setting rather than a mute checkbox. @see OBJEngineCore
    @ViewBuilder
    private var renderModeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $viewModel.exportSettings.renderInBackground) {
                Text(L("export.renderInBackground"))
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)

            if settings.renderInBackground {
                Text(L("export.renderInBackground.note"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The file's approximate size: useful for an MP3 as for a 96 kHz/24-bit WAV, where the order
    /// of magnitude surprises. A constant bitrate on the MP3 side, exact arithmetic on the PCM side.
    private var estimatedSizeLabel: String {
        guard let r = range else { return "" }
        // The prefix is carried by the label itself: the line stays empty when the range is.
        let seconds = r.upperBound - r.lowerBound
        let bytes: Double = settings.format == .mp3
            ? seconds * Double(ExportSettings.mp3BitrateKbps) * 1000 / 8
            : seconds * settings.sampleRate * Double(settings.bitDepth) / 8 * 2
        let mo = bytes / (1024 * 1024)
        let size = mo < 1 ? L("export.size.kilobytes", Int(bytes / 1024))
                          : L("export.size.megabytes", mo)
        return L("export.size.estimated", size)
    }
}
