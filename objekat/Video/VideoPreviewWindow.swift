import AppKit
import QuartzCore

// MARK: - The preview window (plan-video §4.4, V1)
//
// A separate floating panel, modelled on `ScriptPanelWindows`: the project window stays the active
// one, so the transport keys keep working while the picture is up. Space, the arrows and the rest are
// the key monitor's (`TimelineKeyHandler`), which is local and app-wide — it sees a key pressed while
// this panel is key just as it sees one in the main window, and the panel has no text field to claim
// them. The wheel and the pinch are NOT forwarded to it (they would zoom the timeline from a stale
// hover position): the two monitors skip `VideoPreviewPanel`, as they skip a script canvas.
//
// Opening goes through ONE function, `show`, guarded by `hasInterface`'s condition: `--headless`
// opens no window, verifiable with `CGWindowListCopyWindowInfo` on the headless pid. The controller's
// auto-show reaches the window only through `showRequest`, installed here.

/// The panel itself: a type of its own so that the key monitor's scroll and pinch branches can tell it.
final class VideoPreviewPanel: NSPanel {}

/// A view whose layer IS the Metal layer the display link draws into.
final class VideoMetalView: NSView {
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.backgroundColor = NSColor.black.cgColor
        return l
    }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// Drawable size follows the view, in device pixels.
    private func syncDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let w = max(1, (bounds.width * scale).rounded()), h = max(1, (bounds.height * scale).rounded())
        if metalLayer.drawableSize != CGSize(width: w, height: h) {
            metalLayer.drawableSize = CGSize(width: w, height: h)
        }
    }
    override func layout() { super.layout(); syncDrawableSize() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); syncDrawableSize() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); syncDrawableSize() }
}

@MainActor
final class VideoPreviewWindow: NSObject, NSWindowDelegate {

    static let shared = VideoPreviewWindow()

    private var panel: VideoPreviewPanel?
    private weak var controller: VideoPreviewController?

    /// Connects the controller's auto-show to this window. Called once, with the session's start.
    func install(for controller: VideoPreviewController) {
        self.controller = controller
        controller.showRequest = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.show(controller)
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(_ controller: VideoPreviewController) {
        if isVisible { close() } else { show(controller) }
    }

    func show(_ controller: VideoPreviewController) {
        guard !LaunchArguments.process.headless else { return }   // = EditViewModel.hasInterface
        if let p = panel, p.isVisible { return }
        let p = panel ?? makePanel()
        panel = p
        p.orderFrontRegardless()
        if let view = p.contentView as? VideoMetalView {
            view.layoutSubtreeIfNeeded()
            controller.attach(layer: view.metalLayer)
        }
    }

    func close() {
        panel?.close()
    }

    private func makePanel() -> VideoPreviewPanel {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        let p = VideoPreviewPanel(contentRect: frame,
                                  styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        p.title = L("videopreview.title")
        let view = VideoMetalView(frame: frame)
        view.autoresizingMask = [.width, .height]
        p.contentView = view
        p.contentAspectRatio = NSSize(width: 16, height: 9)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = true
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.backgroundColor = .black
        if !p.setFrameUsingName("objekat.videoPreview") {
            if let main = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && !($0 is NSPanel) && $0.isVisible }) {
                p.setFrameOrigin(NSPoint(x: main.frame.maxX - frame.width - 24,
                                         y: main.frame.maxY - frame.height - 80))
            } else {
                p.center()
            }
        }
        p.setFrameAutosaveName("objekat.videoPreview")
        return p
    }

    func windowWillClose(_ notification: Notification) {
        controller?.detach()
    }
}
