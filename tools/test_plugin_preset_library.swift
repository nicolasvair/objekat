// The preset library and the state sanitising, alone (no engine, no model).
//
//   swiftc -parse-as-library objekat/App/LaunchArguments.swift objekat/Shared/PluginPresetLibrary.swift \
//          objekat/Shared/PresetStateXML.swift tools/test_plugin_preset_library.swift -o /tmp/tpl && /tmp/tpl
import Foundation

@main
struct TestPluginPresetLibrary {
    static var failures = 0, total = 0
    static func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        if ok { print("ok    " + label) } else { failures += 1; print("FAIL  " + label + "   " + detail()) }
    }

    static func main() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tpl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = PluginPresetLibrary(root: root)
        let au = PluginPresetKey(formatName: "AudioUnit", identifier: "AudioUnit:Effects/aufx,dly ,appl")
        let vst = PluginPresetKey(formatName: "VST3", identifier: "/Library/Audio/Plug-Ins/VST3/Delay.vst3")

        check("an empty library lists nothing", lib.presets(for: au).isEmpty)
        check("an empty name is refused", (try? lib.save(name: "  ", stateXML: "<PLUGIN/>", key: au, pluginName: "Delay")) == nil)
        _ = try? lib.save(name: "Slap", stateXML: "<PLUGIN a=\"1\"/>", key: au, pluginName: "AUDelay")
        _ = try? lib.save(name: "a/b:c", stateXML: "<PLUGIN a=\"2\"/>", key: au, pluginName: "AUDelay")
        _ = try? lib.save(name: "Écho", stateXML: "<PLUGIN a=\"3\"/>", key: au, pluginName: "AUDelay")
        check("three presets, sorted folded", lib.presets(for: au).map(\.name) == ["a/b:c", "Écho", "Slap"],
              "\(lib.presets(for: au).map(\.name))")
        check("an identifier with / and : makes ONE folder",
              ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).count == 1)
        check("the same product in another format is another type", lib.presets(for: vst).isEmpty)
        _ = try? lib.save(name: "slap", stateXML: "<PLUGIN a=\"9\"/>", key: au, pluginName: "AUDelay")
        check("a name differing by case overwrites", lib.presets(for: au).count == 3
              && lib.preset(named: "SLAP", for: au)?.stateXML == "<PLUGIN a=\"9\"/>")
        check("set_default of a missing preset is refused", (try? lib.setDefault(name: "Nope", key: au, pluginName: "x")) == nil)
        try? lib.setDefault(name: "slap", key: au, pluginName: "AUDelay")
        check("the default is named", lib.defaultPresetName(for: au) == "slap")
        check("the default state is that preset's", lib.defaultState(for: au) == "<PLUGIN a=\"9\"/>")
        try? lib.delete(name: "Slap", key: au)
        check("deleting the default clears it", lib.defaultPresetName(for: au) == nil && lib.presets(for: au).count == 2)
        check("deleting a missing preset throws", (try? lib.delete(name: "Slap", key: au)) == nil)
        check("a stable hash", PluginPresetLibrary.shortHash("abc") == PluginPresetLibrary.shortHash("abc")
              && PluginPresetLibrary.shortHash("abc") != PluginPresetLibrary.shortHash("abd"))

        let live = #"<PLUGIN type="vst" id="1042" enabled="0" layout="AAA" windowX="10" filename="x"><STATE/></PLUGIN>"#
        let stored = PresetStateXML.stripped(live) ?? ""
        check("stored: no instance attribute", !stored.contains("id=") && !stored.contains("enabled=")
              && !stored.contains("layout=") && !stored.contains("windowX="), stored)
        check("stored: the rest kept", stored.contains("filename=\"x\"") && stored.contains("<STATE"), stored)
        let other = #"<PLUGIN type="vst" id="77" enabled="1" layout="BBB"/>"#
        // XMLNode may write an added attribute with single quotes: both are XML, JUCE reads both.
        let fitted = (PresetStateXML.adapted(stored, toLive: other) ?? "").replacingOccurrences(of: "'", with: "\"")
        check("fitted: the live instance's id, bypass and width", fitted.contains("id=\"77\"")
              && fitted.contains("enabled=\"1\"") && fitted.contains("layout=\"BBB\""), fitted)
        check("fitted: no attribute the live instance lacks", !fitted.contains("windowX"), fitted)
        check("not a PLUGIN tree → nil", PresetStateXML.stripped("<RACK/>") == nil)

        // An external plugin's real state: JUCE writes its binary channel layout as `base64:layout`,
        // an attribute name XMLDocument alone refuses (undeclared namespace prefix) — "Save as" said noState.
        let ext = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n\r\n<PLUGIN type=\"vst\" uid=\"6c757767\" id=\"1029\" enabled=\"1\"\r\n"
            + "        state=\"167.hAGaoMGcv.i0AHv\"\r\n        base64:layout=\"99.LETVOUEU..P\" base64:other=\"12.AB\"/>"
        let extStored = PresetStateXML.stripped(ext)
        check("external state with base64: attributes → stripped", extStored != nil)
        let es = extStored ?? ""
        check("base64:layout is the instance's: taken out", !es.contains("layout"), es)
        check("another base64: attribute kept, prefix given back", es.contains("base64:other=\"12.AB\"")
              && !es.contains(PresetStateXML.maskedPrefix), es)
        check("type read through the prefix", PresetStateXML.pluginType(ext) == "vst")
        let liveExt = #"<PLUGIN type="vst" id="5" enabled="0" base64:layout="LIVE.LAYOUT"/>"#
        let extFitted = (PresetStateXML.adapted(es, toLive: liveExt) ?? "").replacingOccurrences(of: "'", with: "\"")
        check("adapted onto an external instance: its own layout, id, bypass", extFitted.contains("base64:layout=\"LIVE.LAYOUT\"")
              && extFitted.contains("id=\"5\"") && extFitted.contains("enabled=\"0\"")
              && !extFitted.contains(PresetStateXML.maskedPrefix), extFitted)
        check("a value is never unmasked", PresetStateXML.unmasked(#"<PLUGIN a="x objekat_b64_y"/>"#)
              == #"<PLUGIN a="x objekat_b64_y"/>"#)

        print("\n\(total - failures)/\(total) OK")
        exit(failures == 0 ? 0 : 1)
    }
}
