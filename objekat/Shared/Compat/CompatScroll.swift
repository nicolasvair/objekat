//
//  CompatScroll.swift
//  objekat
//
//  A scroll view the app DRIVES (`scrollTo(x:y:)`, `scrollTo(edge:)`) and OBSERVES (offset, size,
//  phase) is macOS 15 in SwiftUI (`ScrollPosition`, `onScrollGeometryChange`,
//  `onScrollPhaseChange`). Nothing before it offers an equivalent.
//
//  - macOS 15+ : the native modifiers, exactly as the call sites used them.
//  - below     : a bridge to the `NSScrollView` that SwiftUI's `ScrollView` is built on. A tiny view
//                laid in the scroll view's CONTENT finds its `enclosingScrollView`, reads the clip
//                view's bounds (offset), its document's frame (content size) and the live-scroll
//                notifications (phase), and carries out the scrolls requested through
//                `ScrollPositionCompat`.
//
//  Usage: build ONE `ScrollDriverCompat`, put `.scrollBridgeCompat(driver)` on the scroll view's
//  CONTENT (it does nothing on 15+), and `.scrollDriverCompat(driver)` on the `ScrollView` itself
//  (it does nothing below 15).
//
//  The handlers given to the driver are refreshed at every update of the bridge (a closure captured
//  once would freeze the props of the struct that built it).
//
//  Known degradation below 15: a programmatic scroll is instantaneous (`withAnimation` around
//  `scrollTo` does not animate it).
//
//  To delete when the deployment target is >= 15.
//

import SwiftUI
import AppKit

// MARK: - Values

/// What `onScrollGeometryChange` hands over, reduced to what the app reads. `contentOffset` has its
/// origin at the top left, as SwiftUI's.
struct ScrollGeometryCompat: Equatable, Sendable {
    var contentOffset: CGPoint = .zero
    var contentSize: CGSize = .zero
    var containerSize: CGSize = .zero
}

enum ScrollPhaseCompat: Sendable {
    case idle
    case active
}

/// The position of a scroll view, held in a `@State` like `ScrollPosition`. On 15+ it carries a
/// native `ScrollPosition` (the scroll view writes into it as the user scrolls, as before); below,
/// it carries the last REQUEST, which the bridge carries out when its `seq` changes.
struct ScrollPositionCompat {
    struct Request {
        var x: CGFloat?
        var y: CGFloat?
        var edge: Edge?
        var seq: Int = 0
    }

    private var storage: Any?
    private(set) var request = Request()

    init() {
        if #available(macOS 15, *), !CompatPolicy.forceLegacy {
            storage = ScrollPosition()
        }
    }

    @available(macOS 15, *)
    var native: ScrollPosition {
        get { (storage as? ScrollPosition) ?? ScrollPosition() }
        set { storage = newValue }
    }

    mutating func scrollTo(x: CGFloat, y: CGFloat) {
        if #available(macOS 15, *), !CompatPolicy.forceLegacy {
            var p = native
            p.scrollTo(x: x, y: y)
            native = p
        } else {
            request = Request(x: x, y: y, edge: nil, seq: request.seq &+ 1)
        }
    }

    mutating func scrollTo(edge: Edge) {
        if #available(macOS 15, *), !CompatPolicy.forceLegacy {
            var p = native
            p.scrollTo(edge: edge)
            native = p
        } else {
            request = Request(x: nil, y: nil, edge: edge, seq: request.seq &+ 1)
        }
    }
}

/// Everything a scroll view needs to be driven and observed, in one value passed to both modifiers.
struct ScrollDriverCompat {
    var position: Binding<ScrollPositionCompat>
    /// Called when the horizontal offset changes.
    var onX: ((CGFloat) -> Void)?
    /// Called when the vertical offset changes.
    var onY: ((CGFloat) -> Void)?
    /// Called when the geometry (offset, content size or container size) changes.
    var onGeometry: ((ScrollGeometryCompat) -> Void)?
    var onPhase: ((ScrollPhaseCompat) -> Void)?

    init(position: Binding<ScrollPositionCompat>,
         onX: ((CGFloat) -> Void)? = nil,
         onY: ((CGFloat) -> Void)? = nil,
         onGeometry: ((ScrollGeometryCompat) -> Void)? = nil,
         onPhase: ((ScrollPhaseCompat) -> Void)? = nil) {
        self.position = position
        self.onX = onX
        self.onY = onY
        self.onGeometry = onGeometry
        self.onPhase = onPhase
    }
}

extension View {
    /// On the `ScrollView` itself. Native modifiers on 15+, nothing below.
    @ViewBuilder
    func scrollDriverCompat(_ driver: ScrollDriverCompat) -> some View {
        if #available(macOS 15, *), !CompatPolicy.forceLegacy {
            modifier(NativeScrollDriver(driver: driver))
        } else {
            self
        }
    }

    /// On the scroll view's CONTENT. The bridge below 15, nothing on 15+.
    @ViewBuilder
    func scrollBridgeCompat(_ driver: ScrollDriverCompat) -> some View {
        if #available(macOS 15, *), !CompatPolicy.forceLegacy {
            self
        } else {
            background(ScrollBridge(driver: driver))
        }
    }

    @ViewBuilder
    fileprivate func applyingScrollHandler<T, Result: View>(
        _ handler: T?, _ transform: (Self, T) -> Result
    ) -> some View {
        if let handler { transform(self, handler) } else { self }
    }
}

// MARK: - macOS 15+: the native modifiers

@available(macOS 15, *)
private struct NativeScrollDriver: ViewModifier {
    let driver: ScrollDriverCompat

    func body(content: Content) -> some View {
        let position = driver.position
        content
            .scrollPosition(Binding(get: { position.wrappedValue.native },
                                    set: { position.wrappedValue.native = $0 }))
            .applyingScrollHandler(driver.onX) { view, handler in
                view.onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x },
                                            action: { _, x in handler(x) })
            }
            .applyingScrollHandler(driver.onY) { view, handler in
                view.onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y },
                                            action: { _, y in handler(y) })
            }
            .applyingScrollHandler(driver.onGeometry) { view, handler in
                view.onScrollGeometryChange(for: ScrollGeometryCompat.self, of: { geometry in
                    ScrollGeometryCompat(contentOffset: geometry.contentOffset,
                                         contentSize: geometry.contentSize,
                                         containerSize: geometry.containerSize)
                }, action: { _, value in handler(value) })
            }
            .applyingScrollHandler(driver.onPhase) { view, handler in
                view.onScrollPhaseChange { _, newPhase in
                    handler(newPhase == .idle ? .idle : .active)
                }
            }
    }
}

// MARK: - Below 15: the bridge to the NSScrollView

private struct ScrollBridge: NSViewRepresentable {
    let driver: ScrollDriverCompat

    func makeNSView(context: Context) -> ScrollBridgeView { ScrollBridgeView() }

    func updateNSView(_ view: ScrollBridgeView, context: Context) {
        view.driver = driver
        view.consume(driver.position.wrappedValue.request)
    }

    static func dismantleNSView(_ view: ScrollBridgeView, coordinator: ()) {
        view.detach()
    }
}

private final class ScrollBridgeView: NSView {
    var driver: ScrollDriverCompat?

    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    private var lastX: CGFloat?
    private var lastY: CGFloat?
    private var lastGeometry: ScrollGeometryCompat?
    private var lastSeq = 0
    /// A request that the document was not yet big enough to honour: re-applied when its frame
    /// changes, until it is reached or the hand takes over.
    private var pending: ScrollPositionCompat.Request?
    private var pendingSince = Date.distantPast

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        attachIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachIfNeeded()
        if scrollView == nil {
            // The hierarchy is sometimes completed one turn after the view lands in its window.
            DispatchQueue.main.async { [weak self] in self?.attachIfNeeded() }
        }
    }

    deinit { detach() }

    func detach() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        scrollView = nil
    }

    private func attachIfNeeded() {
        guard let found = enclosingScrollView, found !== scrollView else { return }
        detach()
        scrollView = found
        let clip = found.contentView
        clip.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportGeometry() }
        })
        if let doc = found.documentView {
            doc.postsFrameChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: doc,
                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reapplyPending()
                    self?.reportGeometry()
                }
            })
        }
        observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: found,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pending = nil
                self?.driver?.onPhase?(.active)
            }
        })
        observers.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: found,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.driver?.onPhase?(.idle) }
        })
        reportGeometry()
    }

    // MARK: Observing

    /// The offset in SwiftUI's frame (origin at the top left, whatever the document's flipping).
    private func currentGeometry() -> ScrollGeometryCompat? {
        guard let scrollView, let doc = scrollView.documentView else { return nil }
        let clip = scrollView.contentView
        let bounds = clip.bounds
        let top = doc.isFlipped ? bounds.origin.y : doc.frame.height - bounds.maxY
        return ScrollGeometryCompat(contentOffset: CGPoint(x: bounds.origin.x, y: top),
                                    contentSize: doc.frame.size,
                                    containerSize: bounds.size)
    }

    private func reportGeometry() {
        guard let g = currentGeometry(), let driver else { return }
        if g.contentOffset.x != lastX {
            lastX = g.contentOffset.x
            driver.onX?(g.contentOffset.x)
        }
        if g.contentOffset.y != lastY {
            lastY = g.contentOffset.y
            driver.onY?(g.contentOffset.y)
        }
        if g != lastGeometry {
            lastGeometry = g
            driver.onGeometry?(g)
        }
    }

    // MARK: Driving

    /// Called at every update of the representable. A scroll is carried out on the NEXT turn of the
    /// run loop: the update runs inside SwiftUI's own pass, where the document may not have its new
    /// size yet and where the notifications a scroll posts would modify state mid-update.
    func consume(_ request: ScrollPositionCompat.Request) {
        guard request.seq != lastSeq else { return }
        lastSeq = request.seq
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.attachIfNeeded()
            self.apply(request, keepPendingIfClamped: true)
        }
    }

    private func reapplyPending() {
        guard let pending else { return }
        // Half a second is the most a layout takes to catch up; past it the target is abandoned
        // rather than fighting a hand that has scrolled elsewhere since.
        guard Date().timeIntervalSince(pendingSince) < 0.5 else { self.pending = nil; return }
        apply(pending, keepPendingIfClamped: true)
    }

    private func apply(_ request: ScrollPositionCompat.Request, keepPendingIfClamped: Bool) {
        guard let scrollView, let doc = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxX = max(0, doc.frame.width - clip.bounds.width)
        let maxY = max(0, doc.frame.height - clip.bounds.height)

        var wantX: CGFloat? = request.x
        var wantY: CGFloat? = request.y
        switch request.edge {
        case .leading?: wantX = 0
        case .trailing?: wantX = maxX
        case .top?: wantY = 0
        case .bottom?: wantY = maxY
        case nil: break
        }

        var origin = clip.bounds.origin
        var clamped = false
        if let x = wantX {
            let c = min(max(0, x), maxX)
            clamped = clamped || c != x
            origin.x = c
        }
        if let y = wantY {
            let c = min(max(0, y), maxY)
            clamped = clamped || c != y
            origin.y = doc.isFlipped ? c : doc.frame.height - clip.bounds.height - c
        }

        // A target beyond the document as it stands may simply be waiting for the layout that
        // enlarges it: keep it, and re-apply when the document's frame moves.
        if clamped && keepPendingIfClamped && request.edge == nil {
            if pending == nil { pendingSince = Date() }
            pending = request
        } else {
            pending = nil
        }

        if origin != clip.bounds.origin {
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        }
    }
}
