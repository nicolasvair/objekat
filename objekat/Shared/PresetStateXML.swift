import Foundation

// MARK: - What of a plugin's state a preset carries

/// A preset is a plugin's SOUND, not its place. The state Tracktion serialises (`getPluginStateXML`)
/// also carries what belongs to the INSTANCE: its identity (`id`), its bypass (`enabled`), its channel
/// width (`layout`, mono / stereo — a stereo preset laid on a mono instance would widen it), and where
/// its window last stood. Those are taken out when a preset is stored, and put back from the live
/// instance when one is laid (`adapted`), so loading a preset never bypasses, re-widens or moves anything.
nonisolated enum PresetStateXML {

    /// The PLUGIN element's attributes that are the instance's, never the preset's.
    static let instanceAttributes = ["id", "enabled", "layout", "windowX", "windowY", "windowLocked",
                                     "sidechainSourceID", "objBridgeRank", "sidechainTrigger"]

    /// The state as a preset stores it. nil if `xml` is not a PLUGIN tree.
    static func stripped(_ xml: String) -> String? {
        guard let doc = try? XMLDocument(xmlString: xml, options: [.nodePreserveAll]),
              let root = doc.rootElement(), root.name == "PLUGIN" else { return nil }
        for a in instanceAttributes { root.removeAttribute(forName: a) }
        return root.xmlString(options: [.nodePreserveAll])
    }

    /// The preset's state made to fit the live instance `liveXML`: the instance's own attributes copied
    /// over (and removed where the instance has none). nil if either is not a PLUGIN tree.
    static func adapted(_ presetXML: String, toLive liveXML: String) -> String? {
        guard let doc = try? XMLDocument(xmlString: presetXML, options: [.nodePreserveAll]),
              let root = doc.rootElement(), root.name == "PLUGIN",
              let live = (try? XMLDocument(xmlString: liveXML, options: [.nodePreserveAll]))?.rootElement(),
              live.name == "PLUGIN" else { return nil }
        for a in instanceAttributes {
            root.removeAttribute(forName: a)
            if let v = live.attribute(forName: a)?.stringValue {
                root.addAttribute(XMLNode.attribute(withName: a, stringValue: v) as! XMLNode)
            }
        }
        return root.xmlString(options: [.nodePreserveAll])
    }

    /// The `type` attribute (a built-in's kind, "vst" for an external): two states are only ever
    /// exchanged between plugins of the same type.
    static func pluginType(_ xml: String) -> String? {
        (try? XMLDocument(xmlString: xml, options: []))?.rootElement()?.attribute(forName: "type")?.stringValue
    }
}
