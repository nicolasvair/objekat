import SwiftUI

// The export progress bar — a FULL-WIDTH strip under the transport bar.
//
// It started life as a small badge tucked to the right of the transport bar: invisible as soon
// as the window narrowed (the stem mixer has layout priority there), and absent during the most
// worrying phase — the one where the interface really is frozen. A strip that pushes the rest
// down can be neither clipped nor missed.
//
// IT IS THE FALLBACK, not the main show. A render one WATCHES stays in the export panel, which
// keeps its settings, grows its waveform and lets you listen to what has come out. The strip
// takes over whenever a job exists with NO panel to show it in — a background render (the panel
// closes by itself) or a direct one whose panel was closed by hand. Hence its one line: it says
// WHICH render is running and how far it has got, and nothing else.
//
// Three states, and the first one counts as much as the others:
//   • Preparing — an indeterminate bar: the engine clones the Edit and instantiates the plugins
//     on the main thread, and the app DOES NOT RESPOND during that time. The bar is shown before
//     that freeze begins (@see EditViewModel.runExport), which is all we can offer.
//   • Rendering / Encoding — numbered progress, a Cancel button; the app is usable again.
//   • Done / Failed — the strip stays a few seconds, with access to the file.

struct ExportProgressBar: View {
    @Bindable var viewModel: EditViewModel

    var body: some View {
        if let job = viewModel.exportJob, !viewModel.exportPanelPresented {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 10) {
                    icon(for: job)

                    // WHICH render. With the panel closed, nothing else on screen says what is
                    // being made — and a session is exported several times over an afternoon.
                    Text(L("export.strip.title", viewModel.projectName))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)

                    Text(job.statusLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    // A direct render: playback is suspended for the length of the export. Saying so here
                    // saves you looking for why the transport has stopped answering.
                    if job.isRunning && !job.settings.renderInBackground {
                        Text(L("export.playbackSuspended"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }

                    if job.isRunning {
                        progressBar(for: job)
                        if !job.isIndeterminate {
                            Text(verbatim: "\(Int(job.progress * 100)) %")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .trailing)
                        }
                    } else {
                        Text(job.resultDetail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if job.isRunning {
                        Button(L("common.cancel")) { viewModel.cancelExport() }
                            .controlSize(.small)
                            // While preparing, the engine has no render to interrupt yet — and the click
                            // would not arrive anyway, the app being frozen. The button only appears once
                            // the render has started.
                            .disabled(job.isIndeterminate)
                    } else {
                        if case .finished = job.phase {
                            Button(L("export.reveal")) { viewModel.revealExportedFileInFinder() }
                                .controlSize(.small)
                        }
                        Button {
                            viewModel.dismissExportStatus()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(background(for: job))
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func progressBar(for job: ExportJob) -> some View {
        if job.isIndeterminate {
            ProgressView()
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity)
        } else {
            ProgressView(value: job.progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func icon(for job: ExportJob) -> some View {
        switch job.phase {
        case .preparing, .rendering, .encoding:
            // `waveform` and not the Share glyph that was here: `square.and.arrow.up` is macOS's
            // word for 'hand this over to another app', which is not what a render is. The three
            // bars say the one thing that is true — sound is being made — and they are the same
            // family as the waveform growing in the export panel.
            Image(systemName: "waveform")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        }
    }

    private func background(for job: ExportJob) -> Color {
        switch job.phase {
        case .finished: return Color.green.opacity(0.10)
        case .failed:   return Color.orange.opacity(0.12)
        default:        return Color.accentColor.opacity(0.08)
        }
    }
}
