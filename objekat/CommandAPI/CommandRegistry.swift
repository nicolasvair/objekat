import Foundation

// MARK: - Command error

/// The error handed back to the client. The `code` is a STABLE contract: a third-party script
/// must be able to branch on it without reading the message (which is English, meant for a human).
struct CommandError: Error, Sendable {

    enum Code: String, Sendable {
        case unknown_command   // the command name is not in the registry
        case bad_params        // a parameter is missing, of the wrong type, or out of range
        case not_found         // the named object / stem / job does not exist
        case invalid_state     // the app is not in a state that allows the operation
        case engine_error      // the audio engine refused or failed
        case timeout           // the wait expired (wait_idle, job.wait)
        /// A safety net: any untyped Swift error coming up out of an adapter. It was not in the
        /// original list, but without it an unforeseen exception would carry no stable code.
        case internal_error
    }

    let code: Code
    let message: String
    /// Optional machine-readable context (the list of what is still in flight for `timeout`,
    /// the offending identifier for `not_found`…).
    var details: JSONValue? = nil

    /// A uniform wrapper: anything that is not already a `CommandError` becomes `internal_error`.
    static func wrap(_ error: Error) -> CommandError {
        if let e = error as? CommandError { return e }
        return CommandError(code: .internal_error, message: String(describing: error))
    }

    var jsonObject: JSONValue {
        var o: [String: JSONValue] = ["code": .string(code.rawValue), "message": .string(message)]
        if let details { o["details"] = details }
        return .object(o)
    }
}

// MARK: - A command's parameters

/// Typed access to the parameter dictionary. Each accessor produces an explicit, uniform
/// `bad_params` — without which the ~20 adapters would each have reinvented their own message.
struct CommandParams: Sendable {

    let raw: [String: JSONValue]

    init(_ raw: [String: JSONValue] = [:]) { self.raw = raw }

    var isEmpty: Bool { raw.isEmpty }

    private func missing(_ key: String, _ type: String) -> CommandError {
        CommandError(code: .bad_params, message: "parameter '\(key)' (\(type)) required")
    }
    private func wrongType(_ key: String, _ expected: String, _ got: JSONValue) -> CommandError {
        CommandError(code: .bad_params,
                     message: "parameter '\(key)': \(expected) expected, \(got.typeName) received")
    }

    // MARK: Required

    func string(_ key: String) throws -> String {
        guard let v = raw[key] else { throw missing(key, "string") }
        guard let s = v.stringValue else { throw wrongType(key, "string", v) }
        return s
    }

    func double(_ key: String) throws -> Double {
        guard let v = raw[key] else { throw missing(key, "number") }
        guard let d = v.doubleValue else { throw wrongType(key, "number", v) }
        return d
    }

    func int(_ key: String) throws -> Int {
        guard let v = raw[key] else { throw missing(key, "int") }
        guard let i = v.intValue else { throw wrongType(key, "int", v) }
        return i
    }

    func bool(_ key: String) throws -> Bool {
        guard let v = raw[key] else { throw missing(key, "bool") }
        guard let b = v.boolValue else { throw wrongType(key, "bool", v) }
        return b
    }

    func array(_ key: String) throws -> [JSONValue] {
        guard let v = raw[key] else { throw missing(key, "array") }
        guard let a = v.arrayValue else { throw wrongType(key, "array", v) }
        return a
    }

    func uuid(_ key: String) throws -> UUID {
        let s = try string(key)
        guard let id = UUID(uuidString: s) else {
            throw CommandError(code: .bad_params, message: "parameter '\(key)': invalid UUID ('\(s)')")
        }
        return id
    }

    /// A list of UUIDs. A lone string is accepted too, so that `{"ids": "…"}` is not a silly
    /// mistake to hunt down from a script.
    func uuids(_ key: String) throws -> [UUID] {
        if let v = raw[key], v.stringValue != nil { return [try uuid(key)] }
        let items = try array(key)
        return try items.map { element in
            guard let s = element.stringValue, let id = UUID(uuidString: s) else {
                throw CommandError(code: .bad_params,
                                   message: "parameter '\(key)': a list of UUIDs was expected")
            }
            return id
        }
    }

    // MARK: Optional (with a default value)

    func string(_ key: String, or fallback: String) throws -> String {
        raw[key] == nil ? fallback : try string(key)
    }
    func double(_ key: String, or fallback: Double) throws -> Double {
        raw[key] == nil ? fallback : try double(key)
    }
    func int(_ key: String, or fallback: Int) throws -> Int {
        raw[key] == nil ? fallback : try int(key)
    }
    func bool(_ key: String, or fallback: Bool) throws -> Bool {
        raw[key] == nil ? fallback : try bool(key)
    }

    func optionalDouble(_ key: String) throws -> Double? {
        raw[key] == nil ? nil : try double(key)
    }
    func optionalInt(_ key: String) throws -> Int? {
        raw[key] == nil ? nil : try int(key)
    }
    func optionalString(_ key: String) throws -> String? {
        raw[key] == nil ? nil : try string(key)
    }
    func optionalUUID(_ key: String) throws -> UUID? {
        raw[key] == nil ? nil : try uuid(key)
    }
}

// MARK: - Registry

/// The registry of named commands. The single entry point for external driving: the socket
/// server, `--exec` mode and the MCP shim all go through `execute`.
///
/// Everything is `@MainActor`-isolated: the model and the engine only meet there, so an adapter
/// never has to wonder which thread it is running on.
@MainActor
final class CommandRegistry {

    static let shared = CommandRegistry()

    /// Who pushes the undo. A design decision: the BUS carries it, never the caller — a script must
    /// not have to think about it. But some view-model methods already push one themselves (`cut`,
    /// `paste`, the group operations): wrapping them a second time would make two undo entries for
    /// one gesture. Hence the three cases.
    enum UndoPolicy: String, Sendable {
        case none      // a pure read command
        case bus       // the bus does pushUndo first, and removes it if nothing moved
        case handled   // the method being called handles its own undo
    }

    struct ParamSpec: Sendable {
        let name: String
        let type: String
        let required: Bool
        let doc: String

        init(_ name: String, _ type: String, required: Bool = true, _ doc: String) {
            self.name = name; self.type = type; self.required = required; self.doc = doc
        }

        var jsonObject: JSONValue {
            .object(["name": .string(name), "type": .string(type),
                     "required": .bool(required), "doc": .string(doc)])
        }
    }

    struct Command {
        let name: String
        let summary: String
        let params: [ParamSpec]
        let undo: UndoPolicy
        let handler: @MainActor (CommandParams) async throws -> JSONValue

        var jsonObject: JSONValue {
            .object(["name": .string(name), "summary": .string(summary),
                     "undo": .string(undo.rawValue),
                     "params": .array(params.map(\.jsonObject))])
        }
    }

    private(set) var commands: [String: Command] = [:]
    private var didBootstrap = false

    /// Armed during a `batch`: the sub-commands then do NOT lay down their own undo entry,
    /// the batch carrying a single one for the whole thing.
    var suppressUndo = false

    // MARK: Registration

    func register(_ name: String,
                  summary: String,
                  params: [ParamSpec] = [],
                  undo: UndoPolicy = .none,
                  handler: @escaping @MainActor (CommandParams) async throws -> JSONValue) {
        commands[name] = Command(name: name, summary: summary, params: params,
                                 undo: undo, handler: handler)
    }

    /// Populates the registry. Idempotent: callable from the app as from some future headless mode
    /// without any risk of registering twice.
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        registerIntrospection()
        registerCoreCommands()
        registerRuntimeCommands()
        // The increment-5 families: one file per family, no business logic, each adapter wired onto
        // the method the interface already calls.
        registerObjectCommands()
        registerGroupCommands()
        registerStemCommands()
        registerPluginCommands()
        registerTraceCommands()
        registerAuxCommands()
        registerMIDICommands()
        registerDefinitionCommands()
        registerExportCommands()
        registerTimeSelectionCommands()
    }

    private func registerIntrospection() {
        register("help",
                 summary: "Lists the available commands and their parameters.",
                 params: [ParamSpec("name", "string", required: false,
                                    "Detail only this command.")]) { p in
            let all = CommandRegistry.shared.commands
            if let name = try p.optionalString("name") {
                guard let cmd = all[name] else {
                    throw CommandError(code: .not_found, message: "unknown command: \(name)")
                }
                return cmd.jsonObject
            }
            let sorted = all.values.sorted { $0.name < $1.name }
            return .object(["commands": .array(sorted.map(\.jsonObject)),
                            "count": .int(sorted.count)])
        }
    }

    // MARK: Execution

    /// Runs a command by name. Every output is structured: the returned value is the `result`,
    /// and every error is a typed `CommandError`.
    func execute(name: String, params: CommandParams) async throws -> JSONValue {
        bootstrap()
        guard let command = commands[name] else {
            throw CommandError(code: .unknown_command, message: "unknown command: \(name)")
        }

        switch command.undo {
        case .none, .handled:
            do { return try await command.handler(params) }
            catch { throw CommandError.wrap(error) }

        case .bus:
            // Inside a batch, the batch has already pushed the undo for everyone.
            if suppressUndo {
                do { return try await command.handler(params) }
                catch { throw CommandError.wrap(error) }
            }
            let vm = try CommandContext.shared.requireViewModel()
            // The comparison baseline is taken BEFORE the push: if the gesture turns out to have
            // changed nothing, the undo entry is removed (a project convention, see `cut`). `items`
            // and `stems` are deeply `Equatable` value types — the comparison is one copy less than
            // the snapshot `pushUndo` has just paid for.
            let beforeItems = vm.items
            let beforeStems = vm.stems
            let beforeDefs  = vm.objectDefinitions
            let beforeDirty = vm.isDirty
            let beforeRedo  = vm.redoStack

            vm.pushUndo()

            func rollbackUndoIfUnchanged() {
                guard vm.items == beforeItems,
                      vm.stems == beforeStems,
                      vm.objectDefinitions == beforeDefs else { return }
                _ = vm.undoStack.popLast()
                vm.isDirty = beforeDirty
                // `pushUndo` empties the redo stack: a no-op must not cost the pending redo. (The
                // historical UI sites do not put it back; here we can, it is invisible to them and
                // strictly better for a script.)
                vm.redoStack = beforeRedo
            }

            do {
                let result = try await command.handler(params)
                rollbackUndoIfUnchanged()
                return result
            } catch {
                // A failure AFTER a partial mutation: the undo entry is kept, it is the only way back.
                // A failure with no mutation: it is removed.
                rollbackUndoIfUnchanged()
                throw CommandError.wrap(error)
            }
        }
    }

    /// Runs a full request (`{"id":…, "cmd":…, "params":{…}}`) and returns the JSON response,
    /// ready to write. Never throws: an error becomes `{"ok":false,…}`.
    func handle(request: JSONValue) async -> JSONValue {
        let id = request["id"] ?? .null
        do {
            guard let name = request["cmd"]?.stringValue else {
                throw CommandError(code: .bad_params, message: "field 'cmd' (string) required")
            }
            let result = try await execute(name: name, params: Self.params(of: request))
            return .object(["id": id, "ok": .bool(true), "result": result])
        } catch {
            return .object(["id": id, "ok": .bool(false),
                            "error": CommandError.wrap(error).jsonObject])
        }
    }

    /// A request's parameters. Two forms are accepted, the second purely for command-line
    /// ergonomics: `{"cmd":"x","params":{…}}`, or the parameters flat next to `cmd`
    /// (`{"cmd":"transport.seek","seconds":3}`). No ambiguity is possible: as soon as `params`
    /// is there, it is what counts.
    static func params(of request: JSONValue) -> CommandParams {
        if let explicit = request["params"]?.objectValue { return CommandParams(explicit) }
        guard var flat = request.objectValue else { return CommandParams() }
        flat.removeValue(forKey: "cmd")
        flat.removeValue(forKey: "id")
        return CommandParams(flat)
    }
}
