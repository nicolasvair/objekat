import Foundation

// MARK: - What of a plugin's state a preset carries

/// A preset is a plugin's SOUND, not its place. The state Tracktion serialises (`getPluginStateXML`)
/// also carries what belongs to the INSTANCE: its identity (`id`), its bypass (`enabled`), its channel
/// width (`layout`, mono / stereo — a stereo preset laid on a mono instance would widen it), and where
/// its window last stood. Those are taken out when a preset is stored, and put back from the live
/// instance when one is laid (`adapted`), so loading a preset never bypasses, re-widens or moves anything.
///
/// THE TRAP: JUCE writes a BINARY property under an attribute named `base64:<name>`
/// (`NamedValueSet::copyToXmlAttributes`) — an external plugin's channel layout is one, `base64:layout`.
/// To an XML parser that is an undeclared namespace prefix, and `XMLDocument` refuses the whole tree
/// ("Namespace prefix base64 … is not defined"): every AU / VST3 "Save as" answered `noState`. The
/// prefix is masked before parsing and given back after (`masked` / `unmasked`); JUCE reads it back as
/// it wrote it.
nonisolated enum PresetStateXML {

    /// The PLUGIN element's attributes that are the instance's, never the preset's.
    static let instanceAttributes = ["id", "enabled", "layout", "base64:layout", "windowX", "windowY", "windowLocked",
                                     "sidechainSourceID", "objBridgeRank", "sidechainTrigger"]

    /// The state as a preset stores it. nil if `xml` is not a PLUGIN tree.
    static func stripped(_ xml: String) -> String? {
        guard let root = pluginRoot(xml) else { return nil }
        for a in instanceAttributes { root.removeAttribute(forName: masked(name: a)) }
        return unmasked(root.xmlString(options: [.nodePreserveAll]))
    }

    /// The preset's state made to fit the live instance `liveXML`: the instance's own attributes copied
    /// over (and removed where the instance has none). nil if either is not a PLUGIN tree.
    static func adapted(_ presetXML: String, toLive liveXML: String) -> String? {
        guard let root = pluginRoot(presetXML), let live = pluginRoot(liveXML) else { return nil }
        for a in instanceAttributes.map(masked(name:)) {
            root.removeAttribute(forName: a)
            if let v = live.attribute(forName: a)?.stringValue {
                root.addAttribute(XMLNode.attribute(withName: a, stringValue: v) as! XMLNode)
            }
        }
        return unmasked(root.xmlString(options: [.nodePreserveAll]))
    }

    /// The `type` attribute (a built-in's kind, "vst" for an external): two states are only ever
    /// exchanged between plugins of the same type.
    static func pluginType(_ xml: String) -> String? {
        pluginRoot(xml)?.attribute(forName: "type")?.stringValue
    }

    // MARK: The `base64:` prefix

    /// What `base64:` becomes while a tree is in `XMLDocument`'s hands (a plain, legal name start).
    static let maskedPrefix = "objekat_b64_"

    private static func pluginRoot(_ xml: String) -> XMLElement? {
        guard let doc = try? XMLDocument(xmlString: masked(xml), options: [.nodePreserveAll]),
              let root = doc.rootElement(), root.name == "PLUGIN" else { return nil }
        return root
    }

    static func masked(name: String) -> String {
        name.hasPrefix("base64:") ? maskedPrefix + name.dropFirst("base64:".count) : name
    }

    /// Only in ATTRIBUTE-NAME position (after whitespace, before `=`): a value never holds that shape
    /// (JUCE's base64 alphabet has neither a space nor an `=`).
    static func masked(_ xml: String) -> String {
        xml.replacingOccurrences(of: #"(\s)base64:([A-Za-z_][A-Za-z0-9_.\-]*\s*=)"#,
                                 with: "$1" + maskedPrefix + "$2", options: .regularExpression)
    }

    static func unmasked(_ xml: String) -> String {
        xml.replacingOccurrences(of: #"(\s)"# + maskedPrefix + #"([A-Za-z_][A-Za-z0-9_.\-]*\s*=)"#,
                                 with: "$1base64:$2", options: .regularExpression)
    }
}
