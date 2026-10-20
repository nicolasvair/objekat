import SwiftUI
// `MemberImportVisibility` is on for this target: NSWorkspace is named here, so AppKit is imported here.
import AppKit

/// The discreet line at the bottom of the sound list: what the project folder weighs and how much
/// of it nothing reads any more ("1,2 GB · 340 MB unused"), and, behind a click, the popover that
/// cleans it.
///
/// The figures are `EditViewModel.diskUsage` (@see `EditViewModel+DiskUsage`): computed in the
/// background after a load, after a save and when the popover opens — never continuously, so this
/// line never costs anything while one works. A project that was never saved has no folder and
/// therefore no line at all.
///
/// Everything the popover does goes through `cleanUnusedFiles`, the function the API's
/// `project.clean_unused` calls: the same recomputation right before, the same refusals, and the
/// Trash — nothing here ever deletes.
struct DiskUsageFooterView: View {
    @Bindable var viewModel: EditViewModel
    @State private var isOpen = false

    var body: some View {
        if viewModel.projectFolder != nil, viewModel.projectURL != nil {
            Button {
                isOpen.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "paintbrush.pointed")
                        .font(.system(size: 10))
                    Text(footerText)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("diskUsage.help"))
            .popover(isPresented: $isOpen, arrowEdge: .top) {
                DiskUsagePopoverView(viewModel: viewModel)
            }
            .onChange(of: isOpen) { _, open in
                // The popover opens on FRESH figures: the line may be minutes old.
                if open { viewModel.refreshDiskUsage() }
            }
            .task(id: viewModel.projectURL) {
                if viewModel.diskUsage == nil && !viewModel.isComputingDiskUsage { viewModel.refreshDiskUsage() }
            }
        }
    }

    private var footerText: String {
        // A conversion under way speaks first: the popover may be closed while it runs.
        if let p = viewModel.flacArchiveProgress {
            return L(p.dryRun ? "flacArchive.footer.check" : "flacArchive.footer.convert", p.done, p.total)
        }
        guard let usage = viewModel.diskUsage else {
            return viewModel.isComputingDiskUsage ? L("diskUsage.footer.computing") : L("diskUsage.footer.unknown")
        }
        let total = DiskUsageFormat.bytes(usage.totalBytes)
        let unused = usage.report.unusedBytes
        return unused > 0 ? L("diskUsage.footer", total, DiskUsageFormat.bytes(unused))
                          : L("diskUsage.footer.clean", total)
    }
}

enum DiskUsageFormat {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

// MARK: - The popover

struct DiskUsagePopoverView: View {
    @Bindable var viewModel: EditViewModel
    @State private var scope: DiskCleanScope = .session
    /// What the user UNTICKED among the orphans (nobody reads them): they are ticked until said
    /// otherwise, so a list that is recomputed under the pointer never loses or invents a choice.
    @State private var unticked: Set<String> = []
    /// What the user TICKED among the files another version still reads: the opposite default,
    /// they stay unticked until the user opts in.
    @State private var optedIn: Set<String> = []
    @State private var isCleaning = false
    /// The WAV → FLAC conversion is under way (its look at the files first, then the writing).
    @State private var isConverting = false

    private var result: DiskUsageResult? { viewModel.diskUsage }
    private var cleanable: [ProjectFileUsage.Candidate]? { result?.cleanable(in: scope) }
    /// The files another version reads, which `scope` lets the user tick (`session`) or only shows.
    private var elsewhereIDs: Set<String> { Set((result?.report.usedElsewhere ?? []).map(\.id)) }
    private func isTicked(_ unit: ProjectFileUsage.Candidate) -> Bool {
        elsewhereIDs.contains(unit.id) ? optedIn.contains(unit.id) : !unticked.contains(unit.id)
    }
    private var ticked: [ProjectFileUsage.Candidate] { (cleanable ?? []).filter(isTicked) }
    private var tickedBytes: Int64 { ticked.reduce(0) { $0 + $1.size } }
    /// The ticked files another version reads, and the versions that read them.
    private var tickedElsewhere: [ProjectFileUsage.UsedElsewhere] {
        (result?.report.usedElsewhere ?? []).filter { scope == .session && optedIn.contains($0.id) }
    }
    private var blockedKey: String? { viewModel.diskUsageBlockedKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $scope) {
                Text(L("diskUsage.scope.session")).tag(DiskCleanScope.session)
                Text(L("diskUsage.scope.folder")).tag(DiskCleanScope.folder)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let blockedKey {
                note(L(blockedKey), systemImage: "hourglass")
            }

            if let result {
                content(result)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("diskUsage.footer.computing")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            Divider()
            // For filing or sending the project: its WAVs become FLACs, with no loss.
            HStack(spacing: 6) {
                Button(L("flacArchive.button")) { convertToFlac() }
                    .disabled(blockedKey != nil || isCleaning || converting || viewModel.isComputingDiskUsage)
                    .help(L("flacArchive.help"))
                if converting && viewModel.flacArchiveProgress == nil { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
            if let p = viewModel.flacArchiveProgress { flacProgress(p) }
            HStack {
                Button(L("export.reveal")) { reveal() }
                    .disabled(result == nil)
                Spacer()
                Button(trashTitle) { moveToTrash() }
                    .disabled(ticked.isEmpty || blockedKey != nil || isCleaning || converting
                              || viewModel.isComputingDiskUsage)
            }
        }
        .padding(12)
        .frame(width: 380)
    }

    /// The conversion runs in the view model, so a popover reopened mid-way still knows.
    private var converting: Bool { isConverting || viewModel.isArchivingToFlac }

    /// The conversion's bar: files done out of the total, and the one being read.
    private func flacProgress(_ p: FlacArchiveProgress) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                .progressViewStyle(.linear)
            HStack(spacing: 6) {
                Text(L(p.dryRun ? "flacArchive.progress.check" : "flacArchive.progress.convert", p.done, p.total))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                // The file name takes what is left, cut in its MIDDLE (its start and its extension
                // are what tell two files apart), never more: a long path must not push the line.
                Text(verbatim: p.current ?? "")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .help(p.current ?? "")
            }
        }
    }

    // MARK: Content

    /// ONE list, scrolled as a whole: the orphans, then the files another version reads, each under
    /// a header that stays pinned at the top while its rows go by. Two scroll areas stacked in one
    /// popover made two thumbs, two wheels and a second list that could be scrolled out of sight.
    @ViewBuilder
    private func content(_ result: DiskUsageResult) -> some View {
        let orphans = result.report.unused
        let elsewhere = result.report.usedElsewhere
        if let list = cleanable {
            if list.isEmpty {
                Text(L("diskUsage.empty")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } else {
            note(L("diskUsage.unreadable", result.unreadableVersions.joined(separator: ", ")),
                 systemImage: "exclamationmark.triangle")
        }
        let showOrphans = cleanable != nil && !orphans.isEmpty
        if showOrphans || !elsewhere.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3, pinnedViews: [.sectionHeaders]) {
                    if showOrphans {
                        Section {
                            ForEach(orphans) { unit in
                                row(unit.name, unit.folder, unit.size, nil, tick: tickBinding(unit.id))
                            }
                        } header: {
                            sectionHeader {
                                Toggle(isOn: allOrphansTicked) { Text(L("diskUsage.selectAll")).font(.system(size: 11)) }
                                    .toggleStyle(.checkbox)
                                Spacer(minLength: 6)
                                Text(Ln("diskUsage.count", orphans.count, orphans.count,
                                        DiskUsageFormat.bytes(result.report.unusedBytes)))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    if !elsewhere.isEmpty {
                        Section {
                            ForEach(elsewhere) { unit in
                                let detail = L("diskUsage.held.by", unit.usedBy.joined(separator: ", "))
                                if scope == .session {
                                    // OFFERED, but unticked: cleaning them makes the OTHER versions miss their files.
                                    row(unit.candidate.name, unit.candidate.folder, unit.candidate.size, detail,
                                        warn: true, tick: tickBinding(unit.id))
                                } else {
                                    row(unit.candidate.name, unit.candidate.folder, unit.candidate.size, detail,
                                        tick: nil)
                                        .opacity(0.55)
                                }
                            }
                        } header: {
                            sectionHeader {
                                if scope == .session {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                                            Text(L("diskUsage.elsewhere.title")).font(.system(size: 10, weight: .semibold))
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        .foregroundStyle(.orange)
                                        Toggle(isOn: allElsewhereTicked) { Text(L("diskUsage.selectAll")).font(.system(size: 11)) }
                                            .toggleStyle(.checkbox)
                                    }
                                } else {
                                    Text(L("diskUsage.held.title")).font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The two lists used to reach 440 + 220 pt together; one list keeps about that room.
            .frame(maxHeight: 560)
        }
        if result.report.protectedBytes > 0 {
            note(L("diskUsage.protected", DiskUsageFormat.bytes(result.report.protectedBytes)), systemImage: "lock")
        }
        if !result.unreadableVersions.isEmpty && scope == .session {
            note(L("diskUsage.unreadable.session", result.unreadableVersions.joined(separator: ", ")),
                 systemImage: "exclamationmark.triangle")
        }
        note(L("diskUsage.outside"), systemImage: "info.circle")
    }

    /// A section's header, opaque so the rows scrolling under it while it is pinned stay hidden.
    private func sectionHeader<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 6) { content() }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
    }

    /// One file. Three columns that a long name cannot push: the checkbox (or its empty place, so
    /// the rows of both sections line up), the name over its folder — each on ONE line, cut in the
    /// middle, taking only the width left — and the size, a fixed column on the right. The whole
    /// path is in the tooltip. The checkbox is no longer the row's LABEL: a macOS checkbox sizes
    /// itself on its label's full text, which is what pushed the size out of the popover.
    private func row(_ name: String, _ folder: String, _ size: Int64, _ detail: String?,
                     warn: Bool = false, tick: Binding<Bool>?) -> some View {
        let path = folder.isEmpty ? name : "\(folder)/\(name)"
        return HStack(alignment: .center, spacing: 6) {
            Group {
                if let tick {
                    Toggle(noLabel, isOn: tick).toggleStyle(.checkbox).labelsHidden()
                } else {
                    Color.clear
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: name).font(.system(size: 11))
                    .lineLimit(1).truncationMode(.middle)
                Text(verbatim: detail.map { "\(folder) · \($0)" } ?? folder)
                    .font(.system(size: 9)).foregroundStyle(warn ? Color.orange : .secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Text(verbatim: DiskUsageFormat.bytes(size)).font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 64, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { tick?.wrappedValue.toggle() }
        .help(detail.map { "\(path)\n\($0)" } ?? path)
    }

    private func note(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 9))
            Text(verbatim: text).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
    }

    // MARK: State

    private func tickBinding(_ id: String) -> Binding<Bool> {
        if elsewhereIDs.contains(id) {
            return Binding(get: { optedIn.contains(id) },
                           set: { on in if on { optedIn.insert(id) } else { optedIn.remove(id) } })
        }
        return Binding(get: { !unticked.contains(id) },
                       set: { on in if on { unticked.remove(id) } else { unticked.insert(id) } })
    }

    private var allOrphansTicked: Binding<Bool> {
        Binding(get: { (result?.report.unused ?? []).allSatisfy { !unticked.contains($0.id) } },
                set: { on in unticked = on ? [] : Set((result?.report.unused ?? []).map(\.id)) })
    }

    private var allElsewhereTicked: Binding<Bool> {
        Binding(get: { !elsewhereIDs.isEmpty && elsewhereIDs.isSubset(of: optedIn) },
                set: { on in optedIn = on ? elsewhereIDs : [] })
    }

    private var trashTitle: String {
        ticked.isEmpty ? L("diskUsage.trash")
                       : Ln("diskUsage.trash.count", ticked.count, ticked.count, DiskUsageFormat.bytes(tickedBytes))
    }

    // MARK: Actions

    /// The ticked files in the Finder, or the project folder when nothing is ticked.
    private func reveal() {
        guard let folder = viewModel.projectFolder else { return }
        let urls = ticked.compactMap { unit -> URL? in
            let url = folder.appendingPathComponent(unit.id)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [folder] : urls)
    }

    private func moveToTrash() {
        let chosen = Set(ticked.map(\.id))
        guard !chosen.isEmpty else { return }
        var info = L("diskUsage.confirm.info", DiskUsageFormat.bytes(tickedBytes))
        let elsewhere = tickedElsewhere
        if !elsewhere.isEmpty {
            // Said first and plainly: this one hurts OTHER versions of the folder.
            let versions = Array(Set(elsewhere.flatMap(\.usedBy))).sorted()
            var warning = Ln("diskUsage.confirm.elsewhere", elsewhere.count, elsewhere.count,
                             versions.joined(separator: ", "))
            if let unreadable = result?.unreadableVersions, !unreadable.isEmpty {
                warning += "\n" + L("diskUsage.confirm.unreadable", unreadable.joined(separator: ", "))
            }
            info = warning + "\n\n" + info
        } else if scope == .session, let unreadable = result?.unreadableVersions, !unreadable.isEmpty {
            info += "\n\n" + L("diskUsage.confirm.unreadable", unreadable.joined(separator: ", "))
        }
        let ok = viewModel.confirm(Ln("diskUsage.confirm.title", chosen.count, chosen.count), info,
                                   yes: L("diskUsage.confirm.yes"), no: L("common.cancel"))
        guard ok else { return }
        isCleaning = true
        let scope = self.scope
        Task { @MainActor in
            let outcome = await viewModel.cleanUnusedFiles(selection: chosen, scope: scope, dryRun: false)
            isCleaning = false
            report(outcome)
        }
    }

    /// Looks first (a dry run: nothing is written), asks with the figures, then converts. The
    /// project becomes modified; the original WAVs stay where they are until the clean-up.
    private func convertToFlac() {
        isConverting = true
        Task { @MainActor in
            defer { isConverting = false }
            let title = L("flacArchive.title")
            let plan = await viewModel.convertAudioToFlac(dryRun: true)
            if plan.refusal != nil { reportFlac(plan, title: title); return }
            guard !plan.converted.isEmpty else {
                viewModel.notify(title, plan.summaryText, style: .informational)
                return
            }
            var info = L("flacArchive.confirm.info", plan.converted.count, DiskUsageFormat.bytes(plan.bytesBefore))
            if !plan.kept.isEmpty { info += "\n\n" + L("flacArchive.confirm.kept", plan.kept.count) }
            guard viewModel.confirm(L("flacArchive.confirm.title"), info,
                                    yes: L("flacArchive.confirm.yes"), no: L("common.cancel"),
                                    style: .informational) else { return }
            let outcome = await viewModel.convertAudioToFlac(dryRun: false)
            if outcome.refusal != nil { reportFlac(outcome, title: title); return }
            viewModel.notify(title, outcome.summaryText, style: .informational)
        }
    }

    private func reportFlac(_ outcome: FlacArchiveOutcome, title: String) {
        switch outcome.refusal {
        case .busy(let key): viewModel.notify(title, L(key))
        case .projectChanged: viewModel.notify(title, L("flacArchive.changed"))
        case .unsaved, nil: break
        }
    }

    private func report(_ outcome: DiskCleanOutcome) {
        let title = L("diskUsage.failed.title")
        if let refusal = outcome.refusal {
            switch refusal {
            case .unsaved: break
            case .busy(let key): viewModel.notify(title, L(key))
            case .unreadableVersions(let names):
                viewModel.notify(title, L("diskUsage.unreadable", names.joined(separator: ", ")))
            case .scanFailed: viewModel.notify(title, L("diskUsage.failed.scan"))
            }
        } else if !outcome.failed.isEmpty {
            viewModel.notify(title, outcome.failed.map { "\($0.id): \($0.message)" }.joined(separator: "\n"))
        }
    }
}
