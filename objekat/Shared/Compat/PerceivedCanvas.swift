//
//  PerceivedCanvas.swift
//  objekat
//
//  A `Canvas` whose renderer may read `@Perceptible` state on macOS 12 and 13.
//
//  On macOS 14+ SwiftUI's own Observation tracks what a `Canvas` renderer reads and redraws it
//  when that changes. Before that there is no such thing, and `WithPerceptionTracking` cannot wrap
//  a renderer (it is not a view builder). So the legacy path tracks the renderer itself, the way
//  `WithPerceptionTracking` tracks a body: the reads of one draw are observed with
//  `withPerceptionTracking`, and the first change of any of them bumps a `@State` counter read by
//  this view's body, which re-creates the `Canvas` and so redraws it.
//
//  On macOS 14+ this is a plain `Canvas`, with no extra state: the behaviour there is exactly what
//  it was before the port.
//

import SwiftUI
import Perception

struct PerceivedCanvas: View {
    let renderer: (inout GraphicsContext, CGSize) -> Void

    init(_ renderer: @escaping (inout GraphicsContext, CGSize) -> Void) {
        self.renderer = renderer
    }

    var body: some View {
        if #available(macOS 14, *) {
            Canvas(renderer: renderer)
        } else {
            PerceivedCanvasLegacy(renderer: renderer)
        }
    }
}

/// The macOS 12/13 path of `PerceivedCanvas`.
private struct PerceivedCanvasLegacy: View {
    let renderer: (inout GraphicsContext, CGSize) -> Void
    @State private var tick = 0

    /// `State` is only a reference to its storage, and the change handler of a perception
    /// tracking is `@Sendable`: the library wraps it the same way for its own views.
    private struct Box: @unchecked Sendable { let tick: State<Int> }

    var body: some View {
        let _ = tick
        let box = Box(tick: _tick)
        let renderer = self.renderer
        return Canvas { context, size in
            withPerceptionTracking {
                #if DEBUG
                _PerceptionLocals.$isInPerceptionTracking.withValue(true) {
                    renderer(&context, size)
                }
                #else
                renderer(&context, size)
                #endif
            } onChange: {
                box.tick.wrappedValue &+= 1
            }
        }
    }
}
