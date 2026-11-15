//
//  DiagIssueReport.swift
//  objekat
//
//  « Signaler un problème… » (menu OBJEKAT ▸ Diagnostic, ⌃⌥⌘I) : une note facultative, écrite dans
//  le journal en une ligne `ISSUE "note"`. Rien d'autre — ni dossier, ni copie, ni presse-papiers :
//  c'est `tools/diag_latest.py` qui, plus tard, retrouve la ligne et ce qui l'entoure.
//

import AppKit

@MainActor
enum DiagIssueReport {

    /// L'alerte avec le champ de note, puis la ligne ISSUE.
    static func askAndMark() {
        let alert = NSAlert()
        alert.messageText = L("diag.issue.title")
        alert.informativeText = L("diag.issue.info")
        alert.addButton(withTitle: L("diag.issue.send"))
        alert.addButton(withTitle: L("common.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 72))
        field.placeholderString = L("diag.issue.placeholder")
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Diag.mark(note: field.stringValue)
    }

    /// Ouvre le dossier des journaux dans le Finder (il est créé au besoin).
    static func openFolder() {
        let root = Diag.rootDirectory
        DiagStore.ensureDirectories(root)
        NSWorkspace.shared.open(root)
    }
}
