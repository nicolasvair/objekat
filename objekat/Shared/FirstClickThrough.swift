//
//  FirstClickThrough.swift
//  objekat
//
//  The click that comes BACK from a plugin's window, and that used to be spent on nothing.
//

import AppKit

/// Gives back the first click made in one of our windows after a plugin's window held the key.
///
/// THE TRAP. A plugin editor is a window of its own — JUCE's for an AU/VST (@see
/// OBJPluginEditorWindow), an NSWindow of ours for a built-in one (@see
/// BuiltInPluginEditorWindowController) — so touching a knob takes the key away from the main
/// window. AppKit then treats the next click down there as a FIRST MOUSE: it makes the window key
/// and, unless the view under the point says otherwise (`acceptsFirstMouse`, false by default and
/// false for every SwiftUI view), it THROWS THE EVENT AWAY. The gesture one had just made — a
/// block selected, an edge pulled — never happened, and one has to make it twice. Working with a
/// plugin open is exactly that, all day.
///
/// THE RULE. While this app is ACTIVE, a click in one of its own windows does what it says,
/// whatever window held the key a moment ago. Nothing here handles the click: the window is merely
/// made key BEFORE the event is dispatched — a local monitor runs inside `NSApp.sendEvent`, ahead
/// of the window's own `sendEvent:` — so by the time AppKit asks the first-mouse question there is
/// no longer one to ask, and the event travels on to whoever was going to receive it. Hence the
/// `return event`: we add a step, we consume nothing.
///
/// WHAT IT LEAVES ALONE. The click that ACTIVATES the app when it was in the background: that one
/// is a system convention, the user is coming from another app and may well be aiming at the
/// window rather than at what is in it. And panels (popovers, menus, tool windows) choose their own
/// key policy — forcing it would be deciding for them.
///
/// A JUCE editor window is not a special case here and needs none: its views accept the first
/// mouse already, so making it key a step early changes nothing for it.
enum FirstClickThrough {

    /// Installs the monitor. The caller keeps the token and gives it back to `remove` — a monitor
    /// left behind outlives the view that asked for it (a permanent point of the project).
    @MainActor
    static func install() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard NSApp.isActive,
                  NSApp.modalWindow == nil,
                  let window = event.window,
                  !window.isKeyWindow,
                  window.canBecomeKey,
                  !(window is NSPanel),
                  window.attachedSheet == nil
            else { return event }
            window.makeKeyAndOrderFront(nil)
            return event
        }
    }

    @MainActor
    static func remove(_ token: inout Any?) {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}
