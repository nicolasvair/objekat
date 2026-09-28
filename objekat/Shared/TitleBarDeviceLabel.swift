//
//  TitleBarDeviceLabel.swift
//  objekat
//
//  The grey "— device — 48k — 512" that follows the project's name in the title bar.
//

import AppKit

/// A SECOND text field, laid by hand beside AppKit's own title field — because there is no way
/// to grey only half of `NSWindow.subtitle`.
///
/// WHY NOT `NSWindow.subtitle` (4a, the first approach). Measured with `debug.titlebar`
/// (@see plan_titlebar_audio_device.md §4a): AppKit composes the title and the subtitle onto
/// ONE `NSTextField`, on one line, joined by its own en-dash. One field, one colour — there is
/// no way to grey the device half and leave the project's name as AppKit draws it. Hence 4b:
/// `EditViewModel.updateWindowSubtitle` now sets `window.subtitle` to `""` and never anything
/// else, and this label carries the device text instead.
///
/// ONE OWNER, LAZILY DISCOVERED. `attach(to:)` finds AppKit's own title `NSTextField` in the
/// window's title-bar chrome — the SAME walk `debugTitlebarTextFields()` uses for measurement —
/// and adds a sibling field beside it: `secondaryLabelColor`, the title field's own font, not
/// selectable, no background. **If the title field cannot be found** (a macOS version whose
/// title-bar internals differ from the ones measured here), **nothing is created**: showing
/// nothing beats showing something misplaced over the project's own name.
///
/// RE-LAID, NEVER POLLED. `relayout()` is cheap (arithmetic on frames already in hand) and is
/// called from every place the window's title area can actually move or the text can change:
/// `setText` (from `AudioDeviceStatus`'s own on-change hook), the title field's own
/// `frameDidChangeNotification` (best-effort — AppKit's internal repositioning of a private view
/// is not documented to post it, so this is belt and braces, not the only mechanism) and the
/// window's own resize notification. A title or dirty-flag change, a tab switch and a Save As
/// all already call `updateWindowTitle()` → `updateWindowSubtitle()` → here, needing no
/// notification of their own. Entering or leaving full screen can replace the title-bar chrome
/// itself, not merely move it, so those two notifications run a full re-`attach` rather than a
/// plain relayout. Key / resign-key are wired too (belt and braces again — `secondaryLabelColor`
/// does not dim on its own the way AppKit's native title text does; the label is meant to stay
/// exactly as grey either way, so these two are cheap relayouts, not colour changes).
///
/// NEVER PAST THE TRAILING EDGE. The available width stops at the nearest sibling view to the
/// RIGHT of the title (a native tab-bar control, a full-screen button once shown — anything
/// AppKit or the app has put in that chrome) or, failing to find one, a fixed inset from the
/// chrome's own width. The label truncates with an ellipsis inside that space and hides itself
/// entirely below a floor width, rather than run under a control at the trailing edge. The
/// traffic lights need no guarding of their own: they sit at the LEADING edge, and this label
/// only ever starts at the title's own trailing edge, past them already.
@MainActor
final class TitleBarDeviceLabel {

    private weak var window: NSWindow?
    private weak var titleField: NSTextField?
    private weak var chrome: NSView?
    private weak var label: NSTextField?
    private var text: String = ""

    private var frameObserver: Any?
    private var windowObservers: [Any] = []

    /// Finds (or re-finds, after a full-screen transition) the title field and lays the grey
    /// field beside it. Cheap to call often: does nothing beyond a relayout when the window and
    /// the hierarchy it found last time are still the ones in hand.
    func attach(to window: NSWindow) {
        if self.window === window, let titleField, titleField.superview != nil,
           let label, label.superview != nil {
            relayout()
            return
        }
        rebuild(for: window)
    }

    /// The audio text, exactly as it should read (without the leading "— "). Re-lays out only
    /// when it actually changed — the project's own "write only on change" discipline.
    func setText(_ newText: String) {
        guard text != newText else { return }
        text = newText
        relayout()
    }

    /// What is ACTUALLY shown right now — `nil` when nothing is (no title field found, or the
    /// window is too narrow to fit even a truncated word of it). This is what a script must be
    /// told: never the text that was asked for, if the hand would see nothing of it.
    var displayedText: String? {
        guard let label, label.isHidden == false, !label.stringValue.isEmpty else { return nil }
        return label.stringValue
    }

    /// DEBUG/measurement only (@see `debug.titlebar`): the two fields' frames in WINDOW
    /// coordinates (the same conversion `debugTitlebarTextFields()` already uses), so a script
    /// can assert the grey field starts at or after the title's own trailing edge and shares its
    /// vertical centre — without which "beside the title" is merely asserted, not measured.
    struct DebugInfo {
        var titleFrame: CGRect?
        var labelFrame: CGRect?
        var labelHidden: Bool?
        var labelColor: String?
        var labelText: String?
    }

    func debugInfo() -> DebugInfo {
        DebugInfo(
            titleFrame: titleField.map { $0.convert($0.bounds, to: nil) },
            labelFrame: label.map { $0.convert($0.bounds, to: nil) },
            labelHidden: label?.isHidden,
            // The only colour this label is ever given — recorded as a name rather than
            // introspected from the `NSColor`, which is simpler and exactly as honest here.
            labelColor: label != nil ? "secondaryLabelColor" : nil,
            labelText: label?.stringValue
        )
    }

    func detach() {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        label?.removeFromSuperview()
        label = nil
        titleField = nil
        chrome = nil
        window = nil
    }

    // MARK: - Discovery

    private func rebuild(for window: NSWindow) {
        detach()
        guard let content = window.contentView, let chrome = content.superview,
              let title = Self.findTitleField(in: chrome, excluding: content)
        else { return }   // fail silent: AppKit's chrome is not the one this was measured against

        self.window = window
        self.chrome = chrome
        self.titleField = title

        let field = NSTextField(labelWithString: "")
        field.font = title.font
        field.textColor = .secondaryLabelColor
        field.isSelectable = false
        field.isEditable = false
        field.isBezeled = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.translatesAutoresizingMaskIntoConstraints = true
        field.isHidden = true
        chrome.addSubview(field)
        self.label = field

        title.postsFrameChangedNotifications = true
        // `queue: .main` runs the block on the main thread, which is what lets it touch this
        // MainActor instance at all — `assumeIsolated` says so to the compiler (@see the same
        // pattern in EditViewModel+MissingFiles.swift's own NotificationCenter watch).
        let center = NotificationCenter.default
        frameObserver = center.addObserver(forName: NSView.frameDidChangeNotification,
                                            object: title, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
        windowObservers = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: window,
                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.relayout() }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.relayout() }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.relayout() }
            },
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window,
                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.rebuild(for: window)
                }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window,
                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.rebuild(for: window)
                }
            },
        ]
        relayout()
    }

    /// AppKit's own title text field: the frontmost `NSTextField` in the title-bar chrome,
    /// outside the content view (`debugTitlebarTextFields()`'s walk, word for word — measured
    /// on this exact window to hold exactly one such field before this label ever adds a
    /// second one). `excluding` a field that is already OUR OWN label, so a re-`attach` after a
    /// full-screen transition cannot mistake the label for the title it sits beside.
    private static func findTitleField(in root: NSView, excluding content: NSView) -> NSTextField? {
        var found: NSTextField?
        func walk(_ view: NSView) {
            guard found == nil, view !== content else { return }
            if let field = view as? NSTextField, field.identifier != Self.labelIdentifier {
                found = field
                return
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return found
    }

    private static let labelIdentifier = NSUserInterfaceItemIdentifier("objekat.audioDeviceLabel")

    // MARK: - Layout

    private func relayout() {
        guard let label, let title = titleField, let chrome else { return }
        label.identifier = Self.labelIdentifier
        guard !text.isEmpty else {
            label.isHidden = true
            label.stringValue = ""
            return
        }

        // THE TRAP THIS EXISTS TO AVOID: `title.frame` is in the coordinate space of the
        // title's OWN immediate superview — a small private AppKit container, not `chrome` (the
        // outer theme frame the label is actually added to, chosen so a native tab-bar control
        // elsewhere in the chrome is still found by `trailingBound`). Laying the label out with
        // title's RAW frame numbers, unconverted, once put it near the WINDOW'S BOTTOM instead
        // of beside the title (found by `debug.titlebar`'s own geometry — measured, not
        // guessed, exactly the discipline 4a was built on). One conversion, done once here, and
        // every number after it is in `chrome`'s own space, label included.
        let titleInChrome = title.superview?.convert(title.frame, to: chrome) ?? title.frame

        let gap: CGFloat = 6
        let originX = titleInChrome.maxX + gap
        let trailing = Self.trailingBound(in: chrome, after: titleInChrome, excluding: label)
        let available = trailing - originX

        let minWidth: CGFloat = 24
        guard available >= minWidth else {
            label.isHidden = true
            return
        }

        label.font = title.font
        label.stringValue = "— " + text
        let natural = label.attributedStringValue.size().width
        let width = min(natural, available)
        // Baseline-aligned with the title: same y, same height, both now in `chrome`'s space.
        label.frame = NSRect(x: originX, y: titleInChrome.origin.y,
                              width: width, height: titleInChrome.height)
        label.isHidden = false
    }

    /// The nearest sibling to the RIGHT of the title (a native tab-bar control, a full-screen
    /// button once shown), minus a small pad — or, finding none, a fixed inset from the chrome's
    /// own width. Recomputed on every relayout: what sits there can appear, move or disappear
    /// with the window (a full-screen button fades in only on hover). `titleInChrome` is
    /// ALREADY converted to `chrome`'s space by the caller — every sibling frame read here is
    /// natively in that same space (`chrome.subviews`), so no further conversion is needed.
    private static func trailingBound(in chrome: NSView, after titleInChrome: CGRect,
                                       excluding label: NSView) -> CGFloat {
        let pad: CGFloat = 4
        var nearest: CGFloat?
        for sibling in chrome.subviews where sibling !== label {
            let frame = sibling.frame
            guard frame.minX > titleInChrome.maxX else { continue }
            if nearest == nil || frame.minX < nearest! { nearest = frame.minX }
        }
        if let nearest { return nearest - pad }
        return chrome.bounds.maxX - 8
    }
}
