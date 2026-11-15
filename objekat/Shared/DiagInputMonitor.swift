//
//  DiagInputMonitor.swift
//  objekat
//
//  Les entrées de la main pour le journal de diagnostic : raccourcis, clics, molette, pincement,
//  entrées de menu. Rien de tout cela ne modifie le comportement : les moniteurs LOCAUX rendent
//  l'évènement tel quel, et ne font de travail que si le journal est allumé.
//
//  Ce que chaque ligne dit (de quoi remonter un crash à ce que la main faisait) :
//    KEY    ⌘⇧Z  → <classe de la première vue qui reçoit>   ou « (saisie texte) » : jamais le
//           texte tapé dans un champ.
//    MOUSE  down/up gauche/droit, position dans la fenêtre, classe de la vue touchée ; au
//           relâchement : sélection, nombre d'objets, modifié ou non.
//    MOUSE  scroll / magnify : UN début et UNE fin avec le cumul, jamais une ligne par évènement.
//    MENU   le titre de l'entrée et celui de son menu (NSMenu.didSendActionNotification).
//
//  ⚠️ L'ordre d'appel entre moniteurs locaux n'est pas garanti par AppKit : le moniteur de touches
//  du timeline (TimelineKeyHandler) avale des lettres (il rend nil) ; s'il passe AVANT celui-ci,
//  la touche avalée n'est pas journalisée. Non vérifié à l'écran.
//

import AppKit

@MainActor
enum DiagInputMonitor {

    private static var installed = false
    private static var monitors: [Any] = []
    private static var menuObserver: NSObjectProtocol?

    /// Idempotent. Appelé quand le journal s'allume ; les gestionnaires testent `Diag.isEnabled`.
    static func installIfNeeded() {
        guard !installed, !Diag.isHeadless else { return }
        installed = true
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown,
                                           .rightMouseUp, .scrollWheel, .magnify]
        let monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            if Diag.isEnabled { MainActor.assumeIsolated { handle(event) } }
            return event
        }
        if let monitor { monitors.append(monitor) }
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didSendActionNotification, object: nil, queue: .main) { note in
            guard Diag.isEnabled else { return }
            let item = note.userInfo?["MenuItem"] as? NSMenuItem
            MainActor.assumeIsolated { logMenu(item) }
        }
    }

    // MARK: - Évènements

    private static func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            logKey(event)
        case .leftMouseDown, .rightMouseDown:
            flushGesture()
            logMouse(event, "down")
        case .leftMouseUp, .rightMouseUp:
            logMouse(event, "up")
        case .scrollWheel:
            accumulate(kind: "scroll", dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                       ended: event.phase.contains(.ended) || event.phase.contains(.cancelled)
                           || event.momentumPhase.contains(.ended))
        case .magnify:
            accumulate(kind: "magnify", dx: 0, dy: event.magnification,
                       ended: event.phase.contains(.ended) || event.phase.contains(.cancelled))
        default:
            break
        }
    }

    private static func modifierString(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch event.keyCode {
        case 36, 76: return "⏎"
        case 48: return "⇥"
        case 49: return "espace"
        case 51: return "⌫"
        case 117: return "⌦"
        case 53: return "esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 115: return "début"
        case 119: return "fin"
        default:
            let chars = event.charactersIgnoringModifiers ?? ""
            return chars.isEmpty ? "code\(event.keyCode)" : chars.uppercased()
        }
    }

    private static func className(_ object: AnyObject?) -> String {
        guard let object else { return "-" }
        return Diag.truncated(String(describing: type(of: object)), 60)
    }

    private static func isTextEditing(_ responder: NSResponder?) -> Bool {
        responder is NSText || responder is NSTextField || responder is NSTextView
    }

    private static func logKey(_ event: NSEvent) {
        let responder = event.window?.firstResponder
        let combo = modifierString(event.modifierFlags) + keyName(event)
        let hasCommand = !event.modifierFlags.intersection([.command, .control]).isEmpty
        if isTextEditing(responder) && !hasCommand {
            Diag.log(.key, "(saisie texte) → \(className(responder))")
        } else {
            Diag.log(.key, "\(combo)\(event.isARepeat ? " (répétée)" : "") → \(className(responder))")
        }
    }

    private static func hitView(_ event: NSEvent) -> NSView? {
        guard let content = event.window?.contentView else { return nil }
        let point = content.superview?.convert(event.locationInWindow, from: nil)
            ?? event.locationInWindow
        return content.hitTest(point)
    }

    private static func logMouse(_ event: NSEvent, _ phase: String) {
        let side = (event.type == .rightMouseDown || event.type == .rightMouseUp) ? "droit" : "gauche"
        let p = event.locationInWindow
        var line = "\(phase) \(side) (\(Int(p.x)),\(Int(p.y)))"
        if phase == "down" {
            line += " clics=\(event.clickCount) \(modifierString(event.modifierFlags)) → \(className(hitView(event)))"
        } else if let vm = CommandContext.shared.viewModel {
            line += " sélection=\(vm.selectedIDs.count) objets=\(vm.items.count) modifié=\(vm.isDirty ? 1 : 0)"
        }
        Diag.log(.mouse, line)
    }

    private static func logMenu(_ item: NSMenuItem?) {
        guard let item else { return }
        let menu = item.menu?.title ?? ""
        let key = item.keyEquivalent.isEmpty ? ""
            : " [\(modifierString(item.keyEquivalentModifierMask))\(item.keyEquivalent.uppercased())]"
        Diag.log(.menu, "\(menu.isEmpty ? "" : menu + " ▸ ")\(item.title)\(key)")
    }

    // MARK: - Molette et pincement : un début, une fin, un cumul

    private static var gestureKind: String?
    private static var gestureStart = Date.distantPast
    private static var gestureEvents = 0
    private static var gestureDX = 0.0
    private static var gestureDY = 0.0
    private static var idleTimer: Timer?

    private static func accumulate(kind: String, dx: Double, dy: Double, ended: Bool) {
        if gestureKind != nil, gestureKind != kind { flushGesture() }
        if gestureKind == nil {
            gestureKind = kind
            gestureStart = Date()
            gestureEvents = 0
            gestureDX = 0
            gestureDY = 0
            Diag.log(.mouse, "\(kind) début")
        }
        gestureEvents += 1
        gestureDX += dx
        gestureDY += dy
        idleTimer?.invalidate()
        if ended {
            flushGesture()
        } else {
            // Sans trackpad (molette de souris) il n'y a pas de phase : le silence clôt le geste.
            idleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                MainActor.assumeIsolated { flushGesture() }
            }
        }
    }

    private static func flushGesture() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard let kind = gestureKind else { return }
        gestureKind = nil
        let duration = Date().timeIntervalSince(gestureStart)
        let cumul = kind == "magnify"
            ? String(format: "Σ=%.3f", gestureDY)
            : String(format: "Σx=%.0f Σy=%.0f", gestureDX, gestureDY)
        Diag.log(.mouse, String(format: "%@ fin %@ évènements=%d durée=%.2fs", kind, cumul,
                                gestureEvents, duration))
    }
}
