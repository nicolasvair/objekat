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
// The panel has NO frame and NO title bar (2026-11-26): it is the picture and nothing else. The hand
// moves it by dragging the picture, resizes it by any of its four edges or corners, and a double click
// fills the screen it is on (a second double click gives the old frame back). Closing goes through the
// Window menu's entry, as showing it does.
//
// Opening goes through ONE function, `show`, guarded by `hasInterface`'s condition: `--headless`
// opens no window, verifiable with `CGWindowListCopyWindowInfo` on the headless pid. The controller's
// auto-show reaches the window only through `showRequest`, installed here.

/// The panel itself: a type of its own so that the key monitor's scroll and pinch branches can tell it.
/// Borderless, so it never becomes key: the project window keeps the keyboard.
final class VideoPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A view whose layer IS the Metal layer the display link draws into, and which carries the panel's
/// gestures since the panel has no frame: drag = move, an edge or a corner = resize, double click =
/// full screen.
final class VideoMetalView: NSView {
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    /// Asked on a double click: fills the screen, or gives the previous frame back.
    var onToggleFullScreen: (() -> Void)?
    /// While the picture fills the screen nothing moves or resizes it.
    var isFullScreen = false { didSet { window?.invalidateCursorRects(for: self) } }

    /// How far in from the border an edge can be taken (points), and a corner (along each side).
    static let edge: CGFloat = 8
    static let corner: CGFloat = 18
    static let minSize = NSSize(width: 160, height: 90)

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
    /// The panel is never key: without this the first click would only be spent on reaching it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

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

    // MARK: Gestures

    /// Which borders a point (view coordinates, origin bottom left) takes hold of. Empty = the picture.
    struct Grip: OptionSet {
        let rawValue: Int
        static let left = Grip(rawValue: 1), right = Grip(rawValue: 2)
        static let bottom = Grip(rawValue: 4), top = Grip(rawValue: 8)
    }

    func grip(at p: NSPoint) -> Grip {
        let b = bounds, e = Self.edge, c = Self.corner
        var g: Grip = []
        let nearLeft = p.x < b.minX + e, nearRight = p.x > b.maxX - e
        let nearBottom = p.y < b.minY + e, nearTop = p.y > b.maxY - e
        if nearLeft { g.insert(.left) } else if nearRight { g.insert(.right) }
        if nearBottom { g.insert(.bottom) } else if nearTop { g.insert(.top) }
        // A corner is taken a little further along each side than the edge is thick.
        if g == [.left] || g == [.right] {
            if p.y < b.minY + c { g.insert(.bottom) } else if p.y > b.maxY - c { g.insert(.top) }
        } else if g == [.bottom] || g == [.top] {
            if p.x < b.minX + c { g.insert(.left) } else if p.x > b.maxX - c { g.insert(.right) }
        }
        return g
    }

    override func resetCursorRects() {
        guard !isFullScreen else { return }
        let b = bounds, e = Self.edge, c = Self.corner
        addCursorRect(NSRect(x: b.minX, y: b.minY + c, width: e, height: b.height - 2 * c), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: b.maxX - e, y: b.minY + c, width: e, height: b.height - 2 * c), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: b.minX + c, y: b.minY, width: b.width - 2 * c, height: e), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: b.minX + c, y: b.maxY - e, width: b.width - 2 * c, height: e), cursor: .resizeUpDown)
        for (x, y, nwse) in [(b.minX, b.minY, false), (b.maxX - c, b.maxY - c, false),
                             (b.minX, b.maxY - c, true), (b.maxX - c, b.minY, true)] {
            addCursorRect(NSRect(x: x, y: y, width: c, height: c), cursor: Self.cornerCursor(nwse: nwse))
        }
    }

    /// The diagonal resize cursor where the system has one (macOS 15), the crosshair before it.
    private static func cornerCursor(nwse: Bool) -> NSCursor {
        if #available(macOS 15, *) {
            return NSCursor.frameResize(position: nwse ? .topLeft : .topRight, directions: .all)
        }
        return .crosshair
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onToggleFullScreen?(); return }
        guard !isFullScreen, let window else { return }
        let g = grip(at: convert(event.locationInWindow, from: nil))
        if g.isEmpty {
            window.performDrag(with: event)       // the system's own move: snapping to edges, Spaces
            return
        }
        resize(window, grip: g, from: event)
    }

    /// Follows the hand until the button is released: the far edges stay where they are.
    private func resize(_ window: NSWindow, grip g: Grip, from down: NSEvent) {
        let start = window.frame
        let origin = NSEvent.mouseLocation
        let minW = Self.minSize.width, minH = Self.minSize.height
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            let m = NSEvent.mouseLocation
            let dx = m.x - origin.x, dy = m.y - origin.y
            var f = start
            if g.contains(.right) { f.size.width = max(minW, start.width + dx) }
            if g.contains(.left) {
                f.size.width = max(minW, start.width - dx)
                f.origin.x = start.maxX - f.width
            }
            if g.contains(.top) { f.size.height = max(minH, start.height + dy) }
            if g.contains(.bottom) {
                f.size.height = max(minH, start.height - dy)
                f.origin.y = start.maxY - f.height
            }
            window.setFrame(f, display: true)
        }
        window.saveFrame(usingName: VideoPreviewWindow.autosaveName)
    }
}

@MainActor
final class VideoPreviewWindow: NSObject, NSWindowDelegate {

    static let shared = VideoPreviewWindow()

    static let autosaveName = "objekat.videoPreview"

    private var panel: VideoPreviewPanel?
    private weak var controller: VideoPreviewController?
    /// The panel's frame before it filled the screen; nil while it does not.
    private var frameBeforeFullScreen: NSRect?
    var isFullScreen: Bool { frameBeforeFullScreen != nil }

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
            followScreen()
        }
    }

    /// Tells the legacy display link which screen the panel is on (it paces itself on that screen).
    private func followScreen() {
        guard let id = panel?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return }
        controller?.setDisplayID(CGDirectDisplayID(id.uint32Value))
    }

    func windowDidChangeScreen(_ notification: Notification) { followScreen() }

    func close() {
        panel?.close()
    }

    /// Fills the screen the panel is on, above the menu bar and the Dock, or gives the previous frame
    /// back. Not macOS's own full screen (a Space of its own): the panel stays a floating window over
    /// the project, so the transport keys keep reaching the project window.
    func toggleFullScreen() {
        guard let p = panel, let view = p.contentView as? VideoMetalView else { return }
        if frameBeforeFullScreen != nil {
            leaveFullScreen(display: true)
        } else {
            guard let screen = p.screen ?? NSScreen.main else { return }
            frameBeforeFullScreen = p.frame
            p.setFrameAutosaveName("")            // the screen's frame is not the one to remember
            p.level = .screenSaver
            p.hasShadow = false
            p.setFrame(screen.frame, display: true)
            view.isFullScreen = true
        }
    }

    private func leaveFullScreen(display: Bool) {
        guard let p = panel, let back = frameBeforeFullScreen else { return }
        frameBeforeFullScreen = nil
        p.level = .floating
        p.hasShadow = true
        p.setFrame(back, display: display)
        p.setFrameAutosaveName(Self.autosaveName)
        (p.contentView as? VideoMetalView)?.isFullScreen = false
    }

    private func makePanel() -> VideoPreviewPanel {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        let p = VideoPreviewPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        p.title = L("videopreview.title")          // no title bar, but the Window menu and Mission Control read it
        let view = VideoMetalView(frame: frame)
        view.autoresizingMask = [.width, .height]
        view.onToggleFullScreen = { [weak self] in self?.toggleFullScreen() }
        p.contentView = view
        p.minSize = VideoMetalView.minSize
        p.hasShadow = true
        p.isMovable = true
        p.isFloatingPanel = true
        p.hidesOnDeactivate = true
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.backgroundColor = .black
        if !p.setFrameUsingName(Self.autosaveName) {
            if let main = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && !($0 is NSPanel) && $0.isVisible }) {
                p.setFrameOrigin(NSPoint(x: main.frame.maxX - frame.width - 24,
                                         y: main.frame.maxY - frame.height - 80))
            } else {
                p.center()
            }
        }
        p.setFrameAutosaveName(Self.autosaveName)
        return p
    }

    func windowWillClose(_ notification: Notification) {
        leaveFullScreen(display: false)                     // closed while full screen: reopen at the old frame
        controller?.detach()
    }
}
