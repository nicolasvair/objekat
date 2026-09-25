import Foundation
import UniformTypeIdentifiers

// MARK: - The session file on disk

/// The session file's EXTENSION and TYPE — one definition for every door that names such a file:
/// the open panels, "Save as", "Save a copy", the display name, and an opening that comes from the
/// Finder.
///
/// WHY `.objekat` AND NOT `.json`. The content IS JSON and stays JSON — the type below conforms to
/// `public.json`, so anything that reads JSON still reads it, and `_readme` still sits at its head
/// (@see SessionSchema). What changes is who OWNS the file. A `.json` belongs to whatever editor
/// the system hands JSON to, so a double-click on a session in the Finder opened a text editor on
/// it. An extension of its own, declared in `Info.plist` (`UTExportedTypeDeclarations` for the
/// type, `CFBundleDocumentTypes` with role Editor and rank Owner for the claim), is what lets the
/// Finder hand it to OBJEKAT (@see `AppDelegate.application(_:open:)`).
///
/// THE LEGACY `.json` IS STILL A SESSION. Every project written before this change is a `.json`,
/// and nothing renames one behind the user's back: the open panels accept both, and `save()`
/// writes where it read (@see `EditViewModel.save`) — only a NEW name (Save As, Save a copy) takes
/// `.objekat`. The command API writes the path it is GIVEN, as it always has: a script that saves
/// `session.json` gets `session.json`.
///
/// `nonisolated` for the reason `LaunchArguments` is: the target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and constants have no business being tied to it.
nonisolated enum SessionFile {

    /// The extension every session the app NAMES from now on carries.
    static let fileExtension = "objekat"

    /// The extension of the sessions written before — still opened, never given to a new name.
    static let legacyExtension = "json"

    /// The exported type. Derived from the bundle identifier (`org.labelpeche.objekat`), as an
    /// exported type should be, and declared in `objekat/Info.plist`: KEEP THE TWO IN STEP — a
    /// type named here and declared nowhere is a type the Finder has never heard of.
    static let typeIdentifier = "org.labelpeche.objekat.session"

    /// The declared type. `conformingTo:` is only a fallback for a system that has not read the
    /// declaration (it is `Info.plist`'s `UTTypeConformsTo` that the system believes).
    static let contentType = UTType(exportedAs: typeIdentifier, conformingTo: .json)

    /// What an open panel accepts: a session under either extension.
    /// The type is also resolved from the EXTENSION, and not only named: a build the system has not
    /// registered yet (run straight out of a build folder) does not know the declaration, and a
    /// `.objekat` then carries a dynamic type — which the declared one would not match, greying out
    /// in the panel the very files it exists for. Registered, the two are the same type and the
    /// list says it once.
    static var openableContentTypes: [UTType] {
        var types = [contentType]
        if let byExtension = UTType(filenameExtension: fileExtension), byExtension != contentType {
            types.append(byExtension)
        }
        types.append(.json)
        return types
    }

    /// The manifest's file name for a project called `base`: `Mix` → `Mix.objekat`.
    static func fileName(for base: String) -> String { "\(base).\(fileExtension)" }

    /// True if `url` carries one of the two extensions a session can have, in any case — the
    /// only filter an opening from OUTSIDE goes through before being decoded (what the file holds
    /// is settled by decoding it, never by its name).
    static func hasSessionExtension(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == fileExtension || ext == legacyExtension
    }

    /// The extensions a display name strips, the current one first.
    static let strippedExtensions = [fileExtension, legacyExtension]
}
