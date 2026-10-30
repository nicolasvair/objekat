import SwiftUI

/// The plugin browser as a sheet/popover content, sized the way every picker of the app is. The synoptic's '+'
/// (FX), its instruments zone and a send's chain use it, and so does the Inputs tab (the instrument of a MIDI input).
///
/// `instrumentsOnly` restricts it to instruments; otherwise instruments are ALWAYS left out of the list — an instrument
/// needs MIDI at its input, which only a MIDI clip, a recording zone or a MIDI input provides, each through a dedicated
/// slot, so it belongs in NO FX chain. `objectID` is the host the pick is made for (the browser reads it for the ARA
/// source and the FX link pages).
struct PluginPickerSheet: View {
    var viewModel: EditViewModel
    let objectID: UUID
    var instrumentsOnly: Bool = false
    var title: String? = nil
    var showsARASource: Bool = true
    var insertion: PluginBrowserInsertion? = nil
    var category: Int? = nil
    @Binding var searchText: String
    let dismiss: () -> Void
    let onSelect: (AvailablePlugin) -> Void

    var body: some View {
        let size = PluginBrowserLayout.sheetSize()
        PluginBrowserView(
            viewModel: viewModel,
            objectID: objectID,
            title: title ?? (instrumentsOnly ? L("synoptic.sheet.chooseInstrument") : L("synoptic.sheet.addPlugin")),
            searchText: $searchText,
            dismiss: dismiss,
            onSelect: { available in onSelect(available); dismiss() },
            kind: instrumentsOnly ? .instrumentsOnly : .effectsOnly,
            showsARASource: showsARASource && !instrumentsOnly,
            insertion: insertion,
            initialPage: category.map { .plugins(.category($0)) } ?? .plugins(.all)
        )
        .frame(width: size.width)   // the height is the browser's own: it depends on the page shown
    }
}
