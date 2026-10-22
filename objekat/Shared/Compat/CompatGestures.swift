//
//  CompatGestures.swift
//  objekat
//
//  Four SwiftUI gesture / measurement APIs the app uses arrived after macOS 12:
//
//  - `onTapGesture(count:coordinateSpace:perform:)` (a tap WITH its position) : macOS 14
//  - `SpatialTapGesture`                                                         : macOS 13
//  - `onContinuousHover`                                                         : macOS 13
//  - `onGeometryChange`                                                          : macOS 13
//
//  Each helper takes the native modifier when the system has it and a fallback otherwise:
//
//  - a tap with a position: a `DragGesture(minimumDistance: 0)` laid SIMULTANEOUSLY, which reports
//    its end point only if the pointer travelled under 3 pt. 3 pt is the threshold of the canvas's
//    own `DragGesture(minimumDistance: 3)`, so a press is either that drag or this tap, never both.
//    A multiple tap (`count` > 1) is not supported in the fallback (no site needs it with a position).
//  - the hover: an AppKit tracking area on a view that takes no click (`hitTest` -> nil), the
//    pattern `SynopticHoverTracker` and the timeline's `HoverTracker` already prove in this project.
//  - the geometry: a `GeometryReader` laid in the background.
//
//  To delete when the deployment target is >= 14.
//

import SwiftUI
import AppKit

// MARK: - A tap with its position

extension View {
    /// `onTapGesture(count:coordinateSpace:perform:)`.
    @ViewBuilder
    func onLocatedTapCompat(count: Int = 1,
                            coordinateSpace: CoordinateSpace = .local,
                            perform action: @escaping (CGPoint) -> Void) -> some View {
        if #available(macOS 14, *), !CompatPolicy.forceLegacy {
            onTapGesture(count: count, coordinateSpace: coordinateSpace, perform: action)
        } else {
            simultaneousGesture(Self.tapFallback(coordinateSpace: coordinateSpace, action: action))
        }
    }

    /// `.gesture(SpatialTapGesture().onEnded { action($0.location) })`.
    @ViewBuilder
    func spatialTapCompat(perform action: @escaping (CGPoint) -> Void) -> some View {
        if #available(macOS 13, *), !CompatPolicy.forceLegacy {
            gesture(SpatialTapGesture().onEnded { action($0.location) })
        } else {
            simultaneousGesture(Self.tapFallback(coordinateSpace: .local, action: action))
        }
    }

    private static func tapFallback(coordinateSpace: CoordinateSpace,
                                    action: @escaping (CGPoint) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: coordinateSpace)
            .onEnded { value in
                if hypot(value.translation.width, value.translation.height) < 3 {
                    action(value.location)
                }
            }
    }
}

// MARK: - Continuous hover

enum HoverPhaseCompat {
    case active(CGPoint)
    case ended
}

extension View {
    /// `onContinuousHover(perform:)`, with the position in the view's own coordinates.
    @ViewBuilder
    func onContinuousHoverCompat(perform action: @escaping (HoverPhaseCompat) -> Void) -> some View {
        if #available(macOS 13, *), !CompatPolicy.forceLegacy {
            onContinuousHover { phase in
                switch phase {
                case .active(let p): action(.active(p))
                case .ended:         action(.ended)
                }
            }
        } else {
            overlay(HoverTrackingBridge(onPhase: action))
        }
    }
}

private struct HoverTrackingBridge: NSViewRepresentable {
    var onPhase: (HoverPhaseCompat) -> Void

    func makeNSView(context: Context) -> TrackerView {
        let v = TrackerView()
        v.onPhase = onPhase
        return v
    }

    /// Refreshed at every update: a closure captured at `makeNSView` would freeze the props of the
    /// struct that built it.
    func updateNSView(_ nsView: TrackerView, context: Context) {
        nsView.onPhase = onPhase
    }

    final class TrackerView: NSView {
        var onPhase: ((HoverPhaseCompat) -> Void)?
        private var trackingArea: NSTrackingArea?

        override var isFlipped: Bool { true }   // SwiftUI's coordinates (origin top-left)
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.activeInActiveApp, .mouseMoved, .mouseEnteredAndExited,
                                                .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }

        override func mouseMoved(with event: NSEvent) {
            onPhase?(.active(convert(event.locationInWindow, from: nil)))
        }
        override func mouseEntered(with event: NSEvent) {
            onPhase?(.active(convert(event.locationInWindow, from: nil)))
        }
        override func mouseExited(with event: NSEvent) { onPhase?(.ended) }
    }
}

// MARK: - Geometry

extension View {
    /// `onGeometryChange(for:of:action:)`.
    @ViewBuilder
    func onGeometryChangeCompat<T: Equatable & Sendable>(
        for type: T.Type,
        of transform: @escaping @Sendable (GeometryProxy) -> T,
        action: @escaping (T) -> Void
    ) -> some View {
        if #available(macOS 13, *), !CompatPolicy.forceLegacy {
            onGeometryChange(for: type, of: transform, action: action)
        } else {
            background(GeometryReader { proxy in
                let value = transform(proxy)
                Color.clear
                    .onAppear { action(value) }
                    .onChange(of: value) { action($0) }
            })
        }
    }
}
