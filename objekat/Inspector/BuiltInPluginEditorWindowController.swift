import AppKit
import SwiftUI

/// A standalone window for the editor of a Tracktion built-in plugin (EQ, Reverb, Compressor…).
/// The counterpart of `OBJPluginEditorWindow` on the JUCE side (@see OBJEngineCore.mm) for
/// external plugins: here the UI is 100% SwiftUI, so a real NSWindow rather than a sheet. A
/// standard native title bar (the attempt at a custom tinted bar ran into liberties AppKit takes
/// with the safe area of a hand-planted NSHostingView — abandoned), plus a thin border taking the
/// plugin's identity colour around the content.
final class BuiltInPluginEditorWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(plug: ObjectPlugin, viewModel: EditViewModel, onClose: @escaping () -> Void) {
        self.onClose = onClose

        let content = BuiltInPluginEditorView(viewModel: viewModel, plug: plug)
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(plug.color, lineWidth: 2)
            )

        // A fixed size rather than hosting.fittingSize: at that instant the SwiftUI view has not
        // laid out yet (onAppear, which loads the params, has not happened) — measuring it now
        // captures the empty state and squashes the real content once it is loaded.
        let initialFrame = NSRect(x: 0, y: 0, width: 344, height: 480)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = initialFrame

        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = plug.name
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.setContentSize(initialFrame.size)
        window.contentMinSize = NSSize(width: 300, height: 200)

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
