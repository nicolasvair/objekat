import SwiftUI

// The region picker of the export window (the `regions` scope): every region of the project, a
// checkbox on each, and — the point of the thing — no doubt about which ones will be written.
//
// How "clear" is obtained, in three layers that say the same thing:
//   • a ticked row is lit (accent-tinted ground, full ink) and shows the FILE it will write;
//     an unticked row is dimmed and says it is not exported;
//   • one summary line counts them ("5 of 14 regions will be exported"), orange at zero;
//   • warnings sit on the row they concern: an empty name (the file takes "Region n"), a name
//     another ticked region already has (the file takes " (2)"), a file that will be replaced.
//
// Rows are grouped by ROW of the marker band — the lane's colour dot and name, a slashed eye for a
// hidden one (its regions still count: hiding a row is a display choice). Everything is read live
// from the view-model, so a region added, renamed or removed while the window is open shows at
// once. While a batch runs the list is frozen on the regions it was launched with and each row
// reports its own outcome. @see EditViewModel+ExportRegions

struct ExportRegionPicker: View {
    @Bindable var viewModel: EditViewModel
    /// The settings the window is showing (the running job's own while a render runs).
    let settings: ExportSettings
    /// Formats an instant in the export's time unit (seconds or bar:beat:tick).
    let formatTime: (Double) -> String

    private var batch: ExportBatch? { viewModel.exportBatch }
    private var frozen: Bool { batch?.isActive == true }

    var body: some View {
        let groups = viewModel.exportRegionGroups
        let total = groups.reduce(0) { $0 + $1.entries.count }
        let names = viewModel.exportRegionFileNames
        let warnings: [UUID: [ExportRegionWarning]] = frozen
            ? [:] : viewModel.exportRegionWarnings(names: names, settings: settings)

        VStack(alignment: .leading, spacing: 8) {
            if total == 0 {
                Text(L("export.regions.none"))
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                toolbar(total: total)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups) { group in
                            header(group)
                            ForEach(group.entries) { entry in
                                row(entry, names: names, warnings: warnings[entry.id] ?? [])
                            }
                        }
                    }
                    .padding(4)
                }
                .frame(minHeight: 70, maxHeight: 210)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
            }
        }
    }

    // MARK: - Summary and bulk buttons

    private func selectedCount(total: Int) -> Int {
        if let b = batch, frozen { return b.total }
        return viewModel.selectedExportRegions.count
    }

    @ViewBuilder
    private func toolbar(total: Int) -> some View {
        let n = selectedCount(total: total)
        HStack(spacing: 8) {
            Text(Ln("export.regions.summary", n, n, total))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(n == 0 ? Color.orange : Color.primary)
            Spacer(minLength: 4)
            Button(L("export.regions.selectAll")) { viewModel.selectAllExportRegions() }
            Button(L("export.regions.selectNone")) { viewModel.selectNoExportRegions() }
            Button(L("export.regions.invert")) { viewModel.invertExportRegions() }
        }
        .controlSize(.small)
        .disabled(frozen)
    }

    // MARK: - A row of the marker band

    private func header(_ group: ExportRegionGroup) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ObjectColorPalette.color(at: group.laneColorIndex))
                .frame(width: 8, height: 8)
            Text(group.laneName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !group.laneVisible {
                Image(systemName: "eye.slash")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help(L("export.regions.laneHidden"))
            }
            Spacer()
        }
        .padding(.top, 4)
        .padding(.horizontal, 4)
    }

    // MARK: - A region

    private func isTicked(_ id: UUID) -> Bool {
        if let b = batch, frozen { return b.targets.contains { $0.id == id } }
        return viewModel.isExportRegionSelected(id)
    }

    @ViewBuilder
    private func row(_ e: ExportRegionEntry,
                     names: [UUID: RegionExportNaming.Assigned],
                     warnings: [ExportRegionWarning]) -> some View {
        let ticked = isTicked(e.id)
        let ext = settings.format.fileExtension
        // While a batch runs the names are the ones it was launched with, not today's.
        let fileName: String? = {
            if frozen, let t = batch?.targets.first(where: { $0.id == e.id }) {
                return t.fileBase + "." + ext
            }
            return names[e.id].map { $0.base + "." + ext }
        }()
        let displayName = e.name.trimmingCharacters(in: .whitespacesAndNewlines)

        HStack(alignment: .top, spacing: 8) {
            Toggle(isOn: Binding(get: { ticked },
                                 set: { viewModel.setExportRegion(e.id, selected: $0) })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(frozen)

            Circle()
                .fill(ObjectColorPalette.color(at: e.colorIndex ?? e.laneColorIndex))
                .frame(width: 8, height: 8)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName.isEmpty ? L("export.regions.unnamed") : displayName)
                    .font(.system(size: 11, weight: .medium))
                    .italic(displayName.isEmpty)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if ticked, let fileName {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8))
                        Text(verbatim: fileName)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ForEach(warnings, id: \.rawValue) { w in
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .help(warningHelp(w))
                        }
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Text(L("export.regions.notExported"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: "\(formatTime(e.start)) – \(formatTime(e.end))")
                    .font(.system(size: 10, design: .monospaced))
                Text(verbatim: ExportTimecode.string(e.duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .lineLimit(1)
            .fixedSize()

            outcomeIcon(e.id)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(ticked ? Color.accentColor.opacity(0.12) : Color.clear))
        // An unticked region is DIMMED, not merely unchecked: at a glance the lit rows are the files.
        .opacity(ticked ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture { if !frozen { viewModel.toggleExportRegion(e.id) } }
    }

    private func warningHelp(_ w: ExportRegionWarning) -> String {
        switch w {
        case .emptyName:     return L("export.regions.warn.empty")
        case .duplicateName: return L("export.regions.warn.duplicate")
        case .fileExists:    return L("export.file.exists")
        }
    }

    /// What became of a region in the batch that ran (or is running) — nothing before any batch.
    @ViewBuilder
    private func outcomeIcon(_ id: UUID) -> some View {
        if let b = batch, let i = b.targets.firstIndex(where: { $0.id == id }) {
            switch b.outcomes[i] {
            case .pending:
                EmptyView()
            case .running:
                ProgressView().controlSize(.mini).frame(width: 12)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.green)
            case .failed(let message):
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 11)).foregroundStyle(.red)
                    .help(message)
            case .cancelled:
                Image(systemName: "slash.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
