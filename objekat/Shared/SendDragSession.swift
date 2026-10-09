import AppKit

// MARK: - The send drag in flight, readable while it hovers
//
// The twin of `PluginDragSession`: a drop target gets only an `NSItemProvider` whose payload loads too
// late to answer the cursor, so the SOURCE says what it carries when the drag begins, and every door that
// reads a drag asks here first (a send never goes to another object, a strip or the timeline: "a send
// stays on its object"). Read as ABSENT as soon as no mouse button is down.

@MainActor
final class SendDragSession {
    static let shared = SendDragSession()

    private var payload: SendDragPayload?

    func begin(_ p: SendDragPayload) { payload = p }
    func end() { payload = nil }

    var current: SendDragPayload? {
        if payload != nil, NSEvent.pressedMouseButtons == 0 { payload = nil }
        return payload
    }
}
