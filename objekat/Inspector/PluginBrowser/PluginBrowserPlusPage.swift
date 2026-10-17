import SwiftUI

// MARK: - The plugin browser's "+" page: what each zone of the signal view's "+" asks for

/// The circle a "+" of the signal view draws while it is dragged (@see PlusSectorsView — the same drawing,
/// scaled up), with its sixteen zones: eight directions of 45°, each NEAR (inside the 80 pt circle) and FAR
/// (beyond it). Under it a PALETTE — the built-in actions, the colour categories the plugins carry, then the
/// effects of the catalogue (an instrument has no place in an FX chain) — whose items are DRAGGED onto a zone:
///
///  - dropped on a zone, an item replaces what the zone held (an item may sit on several zones);
///  - a zone's item dragged onto another zone MOVES there, the two exchanging what they held;
///  - the ✕ of a zone (on hover) empties it;
///  - "Reset to defaults" brings the "+" back as it was designed.
///
/// An empty far zone does what its near zone does (shown faintly); an empty near zone does nothing short of
/// the far circle (@see PlusShortcutMap.effective). The map is the APP's memory (`PlusShortcutStore`,
/// UserDefaults), not the project's; this page is the one door that edits it.
struct PluginBrowserPlusPage<SearchRow: View>: View {
    var viewModel: EditViewModel
    /// The effects the palette lists (the browser's search and formats already applied).
    let plugins: [AvailablePlugin]
    /// The colour categories that hold a plugin, in the order of their tabs.
    let categories: [Int]
    /// The browser's search pill, laid above the palette's plugins.
    @ViewBuilder var searchRow: () -> SearchRow

    private var store: PlusShortcutStore { .shared }

    /// What the hand carries: an item of the palette (`from` nil) or a zone's (`from` = that zone).
    private struct Carried {
        var action: PlusAction
        var from: PlusSlot?
        var location: CGPoint
    }

    @State private var carried: Carried? = nil
    @State private var hoveredSlot: PlusSlot? = nil
    /// Where the circle's centre sits in the page (the "plusPage" space).
    @State private var circleFrame: CGRect = .zero

    private static var space: String { "plusPage" }

    var body: some View {
        GeometryReader { geo in
            let scale = Self.scale(forHeight: geo.size.height)
            VStack(spacing: 0) {
                circle(scale: scale)
                    .frame(height: Self.circleHeight(scale))
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .topTrailing) {
                        Button(L("pluginBrowser.plus.reset")) { store.reset() }
                            .controlSize(.small)
                            .disabled(store.map.isDefault)
                            .padding(8)
                    }
                Divider()
                palette
            }
            .overlay(alignment: .topLeading) { carriedGhost }
            .coordinateSpace(name: Self.space)
        }
    }

    // MARK: Geometry

    /// The drawing's size: the circle takes about half the page (the palette the other half), never smaller
    /// than the signal view's.
    private static func scale(forHeight h: CGFloat) -> CGFloat {
        let outer = SynopticPlusGesture.sectorOuterRadius
        return min(1.8, max(1, (h * 0.48 - 16) / (2 * outer)))
    }

    private static func circleHeight(_ scale: CGFloat) -> CGFloat {
        2 * SynopticPlusGesture.sectorOuterRadius * scale + 16
    }

    /// The zone under `point` (in the page's space), whatever it holds; nil off the circle (or on the "+").
    private func slot(at point: CGPoint, scale: CGFloat) -> PlusSlot? {
        let c = CGPoint(x: circleFrame.midX, y: circleFrame.midY)
        let t = CGSize(width: (point.x - c.x) / scale, height: (point.y - c.y) / scale)
        let r = hypot(t.width, t.height)
        guard r >= SynopticPlusGesture.sectorInnerRadius, r <= SynopticPlusGesture.sectorOuterRadius else { return nil }
        return SynopticPlusGesture.rawSlot(t)
    }

    // MARK: The circle

    private func isMissing(_ action: PlusAction) -> Bool {
        action.pluginRef.map { viewModel.availablePlugin(for: $0) == nil } ?? false
    }

    private func circle(scale: CGFloat) -> some View {
        let map = store.map
        var sectors = SynopticPlusGesture.slotSectors(map: map)
        for i in sectors.indices where isMissing(map.action(PlusSlot(sectors[i].direction, sectors[i].level))) {
            sectors[i].isAvailable = false
        }
        let target = carried.flatMap { slot(at: $0.location, scale: scale) }
        let lit = target.flatMap { t in sectors.firstIndex { $0.direction == t.direction && $0.level == t.level } }
        return GeometryReader { g in
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            ZStack(alignment: .topLeading) {
                PlusSectorsView(center: c, sectors: sectors, highlighted: lit, showsIcons: false,
                                emphasis: 2.2, scale: scale, backdrop: 0)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                    .position(c)
                ForEach(sectors.indices, id: \.self) { i in
                    zoneItem(sectors[i], center: c, scale: scale)
                }
            }
            .background(GeometryReader { inner in
                Color.clear
                    .onAppear { circleFrame = inner.frame(in: .named(Self.space)) }
                    .onChange(of: inner.frame(in: .named(Self.space))) { _, f in circleFrame = f }
            })
        }
    }

    /// What a zone shows at its centre: its item (draggable, ✕ on hover), or for an empty far zone the near
    /// zone's item, faint — that is what a drag reaching it does.
    @ViewBuilder
    private func zoneItem(_ s: PlusSector, center c: CGPoint, scale: CGFloat) -> some View {
        let slot = PlusSlot(s.direction, s.level)
        let action = store.map.action(slot)
        let at = CGPoint(x: c.x + s.iconOffset.width * scale, y: c.y + s.iconOffset.height * scale)
        let width = Self.labelWidth(s, scale: scale)
        if action != .none {
            let missing = isMissing(action)
            itemFace(action, missing: missing, width: width, stacked: true)
                .opacity(carried?.from == slot ? 0.3 : 1)
                .overlay(alignment: .topTrailing) {
                    if hoveredSlot == slot && carried == nil {
                        Button { store.clear(slot) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                        .help(L("pluginBrowser.plus.clear"))
                    }
                }
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { hoveredSlot = slot } else if hoveredSlot == slot { hoveredSlot = nil }
                }
                .gesture(carryGesture(action, from: slot, scale: scale))
                .help(PlusShortcutText.directionLabel(slot.direction) + " · " + PlusShortcutText.levelName(slot.level)
                      + " — " + PlusShortcutText.helpDescription(action, missing: missing))
                .position(at)
        } else if slot.level == .far, store.map.action(slot.direction, .near) != .none {
            itemFace(store.map.action(slot.direction, .near), missing: false, width: width, stacked: true)
                .opacity(0.3)
                .allowsHitTesting(false)
                .position(at)
        }
    }

    /// The room a zone's label has: the arc's chord at its middle radius, a little less — and never more than
    /// a short name needs (a long one is cut with an ellipsis, its tooltip says it whole).
    private static let maxLabelWidth: CGFloat = 84

    private static func labelWidth(_ s: PlusSector, scale: CGFloat) -> CGFloat {
        let mid = (s.inner.distance(at: s.midAngle) + s.outer.distance(at: s.midAngle)) / 2 * scale
        let chord = 2 * mid * CGFloat(sin((s.toAngle - s.fromAngle) / 2 * .pi / 180))
        return min(maxLabelWidth, max(28, chord - 8))
    }

    // MARK: Items (the palette's and the zones')

    private func symbol(_ action: PlusAction, missing: Bool) -> String {
        missing ? "nosign" : SynopticPlusPresentation.symbol(for: action.gestureResult)
    }

    private func iconColor(_ action: PlusAction) -> Color? {
        action.categoryIndex.map { ObjekatPalette.pluginCategory($0) }
    }

    /// An action's face: its icon and its name — side by side in the palette, stacked in a zone. A colour
    /// category shows its coloured icon alone: it has no name, its tab is a colour.
    private func itemFace(_ action: PlusAction, missing: Bool, width: CGFloat? = nil, stacked: Bool) -> some View {
        let name = PlusShortcutText.actionName(action, missing: missing)
        let iconOnly = action.categoryIndex != nil
        let icon = Image(systemName: symbol(action, missing: missing))
            .font(.system(size: iconOnly ? 13 : (stacked ? 11 : 10), weight: .semibold))
            .foregroundStyle(iconColor(action) ?? (missing ? Color.secondary : Color.accentColor))
        let text = Text(verbatim: name)
            .font(.system(size: stacked ? 9 : 10))
            .foregroundStyle(missing ? Color.secondary : Color.primary)
            .lineLimit(1)
            .truncationMode(.tail)
        return Group {
            if iconOnly {
                icon.frame(width: 24, height: 22)
            } else if stacked {
                VStack(spacing: 1) { icon; text }
                    .frame(maxWidth: width)
                    .padding(.horizontal, 3).padding(.vertical, 2)
            } else {
                HStack(spacing: 5) { icon; text }
                    .padding(.horizontal, 7)
                    .frame(height: 22)
            }
        }
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: missing ? [3, 2] : [])))
    }

    /// Carries `action` (from the zone `from`, or from the palette) and lays it where the hand lets go: on a
    /// zone, the palette's item REPLACES what it held, a zone's item SWAPS with it. Anywhere else: nothing.
    private func carryGesture(_ action: PlusAction, from: PlusSlot?, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { v in carried = Carried(action: action, from: from, location: v.location) }
            .onEnded { v in
                carried = nil
                guard let target = slot(at: v.location, scale: scale) else { return }
                if let from { store.swap(from, target) } else { store.assign(action, to: target) }
            }
    }

    /// The item under the hand while it is carried.
    @ViewBuilder
    private var carriedGhost: some View {
        if let c = carried {
            ghostFace(c.action)
                .fixedSize()
                .shadow(color: .black.opacity(0.45), radius: 5, y: 2)
                .offset(x: c.location.x + 8, y: c.location.y - 11)
                .allowsHitTesting(false)
        }
    }

    /// The carried item: a plugin looks as it does in the list, anything else as its zone face.
    @ViewBuilder
    private func ghostFace(_ action: PlusAction) -> some View {
        if let ref = action.pluginRef, let p = viewModel.availablePlugin(for: ref) {
            PluginBrowserRowLabel(plugin: p)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(width: 200)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.6)))
        } else {
            itemFace(action, missing: isMissing(action), stacked: false)
        }
    }

    // MARK: The palette

    private var palette: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(PlusAction.builtIns, id: \.self) { paletteItem($0) }
                if !categories.isEmpty {
                    Divider().frame(height: 18).padding(.horizontal, 2)
                    ForEach(categories, id: \.self) { i in categoryItem(i) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            searchRow()
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6),
                                         count: PluginBrowserLayout.columnCount(sheetWidth: PluginBrowserLayout.sheetSize().width)),
                          spacing: 6) {
                    ForEach(plugins) { p in pluginItem(p) }
                }
                .padding(.top, 8)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func paletteItem(_ action: PlusAction, help: String? = nil) -> some View {
        itemFace(action, missing: false, stacked: false)
            .frame(maxWidth: action.pluginRef == nil ? nil : .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(carryGesture(action, from: nil, scale: currentScale))
            .help(help.map { PlusShortcutText.actionName(action) + " — " + $0 }
                  ?? PlusShortcutText.helpDescription(action))
    }

    /// A plugin of the palette, drawn as the colour tabs draw it (@see PluginBrowserRowLabel), carried by drag.
    private func pluginItem(_ p: AvailablePlugin) -> some View {
        PluginBrowserRowLabel(plugin: p)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .contentShape(Rectangle())
            .gesture(carryGesture(.plugin(PlusPluginRef(p)), from: nil, scale: currentScale))
            .help(PlusShortcutText.helpDescription(.plugin(PlusPluginRef(p))))
    }

    /// A colour category: its dot alone (a category has no name, its tab is a colour).
    private func categoryItem(_ i: Int) -> some View {
        Circle()
            .fill(ObjekatPalette.pluginCategory(i))
            .frame(width: 14, height: 14)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .gesture(carryGesture(.category(i), from: nil, scale: currentScale))
            .help(PlusShortcutText.helpDescription(.category(i)))
    }

    /// The circle's scale as drawn (read back from its frame: the palette has no GeometryReader of its own).
    private var currentScale: CGFloat {
        circleFrame.height > 0
            ? (circleFrame.height - 16) / (2 * SynopticPlusGesture.sectorOuterRadius)
            : 1
    }
}
