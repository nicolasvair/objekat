import Foundation

/// What the commands act on: the current session and, through it, the document, the engine
/// and the transport state.
///
/// Today the app has only one document open at a time — hence the singleton, filled in at
/// launch. It is deliberately the ONLY place where the command layer reaches for global state:
/// the adapters know nothing but this context, which is what made it possible to have the
/// session carry things instead of the view-model alone without touching a single one.
@MainActor
final class CommandContext {

    static let shared = CommandContext()

    /// Weak: the context must not keep alive a session the app has let go of.
    weak var session: ObjekatSession?

    var viewModel: EditViewModel? { session?.viewModel }
    var engine: OBJEngineCore? { session?.engine }

    private init() {}

    func requireSession() throws -> ObjekatSession {
        guard let session else {
            throw CommandError(code: .invalid_state,
                               message: "no session open (session not attached)")
        }
        return session
    }

    func requireViewModel() throws -> EditViewModel {
        guard let viewModel else {
            throw CommandError(code: .invalid_state,
                               message: "no document open (session not attached)")
        }
        return viewModel
    }

    /// The engine is wired up when the session starts (`start()`). A transport command that
    /// arrives before that moment must say so clearly rather than fail in silence.
    func requireEngine() throws -> OBJEngineCore {
        guard let engine else {
            throw CommandError(code: .invalid_state, message: "audio engine not initialised")
        }
        return engine
    }
}
