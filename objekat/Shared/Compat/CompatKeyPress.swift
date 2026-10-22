//
//  CompatKeyPress.swift
//  objekat
//
//  `onKeyPress` and `KeyPress` are macOS 14, and `KeyEquivalent` is only `Equatable` / `Hashable`
//  from 14 on: on macOS 12 `press.key == .upArrow` or a `Set<KeyEquivalent>` has no conformance
//  to rely on at run time. So the app has its OWN key type (`KeyCompat`, compared by character)
//  and its own modifier (`onKeyPressCompat`):
//
//  - macOS 14+ : the native `onKeyPress`, the result converted back. `focused` is ignored.
//  - below      : the key is delivered by the timeline's EXISTING keyboard monitor, on the path
//                 where it lets an event through (@see `KeyPressFallbackHub`, called from
//                 `TimelineKeyHandler`). That monitor runs ahead of the responder chain (cf.
//                 `KeyboardClaim`): it is exactly where a native `.onKeyPress` would "receive"
//                 what the monitor leaves alone. A second, independent monitor would have an
//                 undocumented order of calls. The handler only answers while its view is FOCUSED
//                 (`focused:`) and the event is for the view's own window.
//
//  To delete when the deployment target is >= 14.
//

import SwiftUI
import AppKit

/// A key, compared by the character it names (not by `KeyEquivalent`, which is not `Equatable`
/// before macOS 14).
struct KeyCompat: Hashable, Sendable {
    let character: Character

    init(_ character: Character) { self.character = character }
    init(_ key: KeyEquivalent) { self.character = key.character }

    static let upArrow = KeyCompat(KeyEquivalent.upArrow)
    static let downArrow = KeyCompat(KeyEquivalent.downArrow)
    static let leftArrow = KeyCompat(KeyEquivalent.leftArrow)
    static let rightArrow = KeyCompat(KeyEquivalent.rightArrow)
    static let delete = KeyCompat(KeyEquivalent.delete)
    static let deleteForward = KeyCompat(KeyEquivalent.deleteForward)
}

/// What a key press handler is given (the part of `KeyPress` the app reads).
struct KeyPressCompat {
    struct Phases: OptionSet, Sendable {
        let rawValue: Int
        static let down = Phases(rawValue: 1)
        static let `repeat` = Phases(rawValue: 2)
        static let up = Phases(rawValue: 4)
        static let all: Phases = [.down, .repeat, .up]
    }

    enum Result { case handled, ignored }

    let key: KeyCompat
    let characters: String
    let modifiers: EventModifiers
    let phase: Phases
}

// MARK: - The fallback hub (macOS < 14)

/// Dispatches the key events the timeline's monitor lets through to the handlers whose view is
/// focused. Never called on macOS 14+.
@MainActor
final class KeyPressFallbackHub {
    static let shared = KeyPressFallbackHub()

    struct Handler {
        weak var anchor: NSView?
        var focused: Bool
        var keys: Set<KeyCompat>?
        var phases: KeyPressCompat.Phases
        var action: (KeyPressCompat) -> KeyPressCompat.Result
    }

    private var ids: [ObjectIdentifier] = []
    private var handlers: [ObjectIdentifier: Handler] = [:]

    func register(_ id: ObjectIdentifier, _ handler: Handler) {
        if handlers[id] == nil { ids.append(id) }
        handlers[id] = handler
    }

    func unregister(_ id: ObjectIdentifier) {
        handlers[id] = nil
        ids.removeAll { $0 == id }
    }

    /// The press a `NSEvent` stands for (`flagsChanged` is not a key press).
    static func press(from event: NSEvent) -> KeyPressCompat? {
        let phase: KeyPressCompat.Phases
        switch event.type {
        case .keyDown: phase = event.isARepeat ? .repeat : .down
        case .keyUp:   phase = .up
        default:       return nil
        }
        let chars = event.charactersIgnoringModifiers ?? ""
        var mods: EventModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command)  { mods.insert(.command) }
        if flags.contains(.shift)    { mods.insert(.shift) }
        if flags.contains(.option)   { mods.insert(.option) }
        if flags.contains(.control)  { mods.insert(.control) }
        if flags.contains(.capsLock) { mods.insert(.capsLock) }
        if flags.contains(.numericPad) { mods.insert(.numericPad) }
        return KeyPressCompat(key: KeyCompat(chars.first ?? "\0"),
                              characters: chars, modifiers: mods, phase: phase)
    }

    /// True when a handler took the event (the caller then swallows it).
    func dispatch(_ event: NSEvent) -> Bool {
        guard let press = Self.press(from: event) else { return false }
        for id in ids {
            guard let h = handlers[id], h.focused,
                  let anchor = h.anchor, let window = anchor.window, window === event.window,
                  h.phases.contains(press.phase) else { continue }
            if let keys = h.keys, !keys.contains(press.key) { continue }
            if h.action(press) == .handled { return true }
        }
        return false
    }
}

/// A tiny view, invisible to the hit test, whose only job is to keep a handler registered in the
/// hub with the CURRENT closure (refreshed at every `updateNSView`: a closure captured at
/// `makeNSView` would freeze the props of the struct).
private struct KeyPressRegistrar: NSViewRepresentable {
    let focused: Bool
    let keys: Set<KeyCompat>?
    let phases: KeyPressCompat.Phases
    let action: (KeyPressCompat) -> KeyPressCompat.Result

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        KeyPressFallbackHub.shared.register(
            ObjectIdentifier(nsView),
            .init(anchor: nsView, focused: focused, keys: keys, phases: phases, action: action))
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
        let id = ObjectIdentifier(nsView)
        MainActor.assumeIsolated { KeyPressFallbackHub.shared.unregister(id) }
    }
}

// MARK: - The modifiers

extension View {
    /// `onKeyPress(_:action:)` for one key.
    @ViewBuilder
    func onKeyPressCompat(_ key: KeyCompat, focused: Bool,
                          action: @escaping () -> KeyPressCompat.Result) -> some View {
        onKeyPressCompat(keys: [key], focused: focused) { _ in action() }
    }

    /// `onKeyPress(keys:phases:action:)`.
    @ViewBuilder
    func onKeyPressCompat(keys: Set<KeyCompat>, focused: Bool,
                          phases: KeyPressCompat.Phases = [.down, .repeat],
                          action: @escaping (KeyPressCompat) -> KeyPressCompat.Result) -> some View {
        if #available(macOS 14, *), !CompatPolicy.forceLegacy {
            onKeyPress(keys: Set(keys.map { KeyEquivalent($0.character) }),
                       phases: Self.nativePhases(phases)) { press in
                Self.nativeResult(action(Self.compatPress(press)))
            }
        } else {
            background(KeyPressRegistrar(focused: focused, keys: keys, phases: phases, action: action))
        }
    }

    /// `onKeyPress(phases:action:)`: every key.
    @ViewBuilder
    func onKeyPressCompat(phases: KeyPressCompat.Phases = [.down, .repeat], focused: Bool,
                          action: @escaping (KeyPressCompat) -> KeyPressCompat.Result) -> some View {
        if #available(macOS 14, *), !CompatPolicy.forceLegacy {
            onKeyPress(phases: Self.nativePhases(phases)) { press in
                Self.nativeResult(action(Self.compatPress(press)))
            }
        } else {
            background(KeyPressRegistrar(focused: focused, keys: nil, phases: phases, action: action))
        }
    }

    @available(macOS 14, *)
    private static func nativePhases(_ phases: KeyPressCompat.Phases) -> KeyPress.Phases {
        var p: KeyPress.Phases = []
        if phases.contains(.down) { p.insert(.down) }
        if phases.contains(.repeat) { p.insert(.repeat) }
        if phases.contains(.up) { p.insert(.up) }
        return p
    }

    @available(macOS 14, *)
    private static func nativeResult(_ r: KeyPressCompat.Result) -> KeyPress.Result {
        r == .handled ? .handled : .ignored
    }

    @available(macOS 14, *)
    private static func compatPress(_ press: KeyPress) -> KeyPressCompat {
        let phase: KeyPressCompat.Phases
        switch press.phase {
        case .repeat: phase = .repeat
        case .up:     phase = .up
        default:      phase = .down
        }
        return KeyPressCompat(key: KeyCompat(press.key), characters: press.characters,
                              modifiers: press.modifiers, phase: phase)
    }
}
