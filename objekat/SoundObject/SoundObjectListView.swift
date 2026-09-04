import SwiftUI

struct SoundObjectListView: View {
    @Bindable var viewModel: EditViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search bar plus sorting
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 11))
                TextField(L("objectList.filter"), text: $viewModel.filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .focused($searchFocused)
                if !viewModel.filterText.isEmpty {
                    Button {
                        viewModel.filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Column headers
            HStack(spacing: 0) {
                sortHeader(L("objectList.column.name"),     key: .startTime, width: nil)
                sortHeader(L("objectList.column.time"),     key: .startTime, width: 50)
                sortHeader(L("objectList.column.duration"), key: .duration,  width: 46)
                sortHeader(L("objectList.column.lane"),     key: .lane,      width: 34)
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // List
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.filteredObjects) { obj in
                        let sc = viewModel.stemColor(for: obj.id)
                        ObjectRow(
                            obj: obj,
                            isSelected: viewModel.isSelected(obj.id),
                            filterText: viewModel.filterText,
                            stemColor: sc
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            searchFocused = false
                            viewModel.select(obj.id, additive: false)
                        }
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                viewModel.engine?.seek(to: obj.startTime)
                            }
                        )
                        Divider()
                    }
                }
            }
            .simultaneousGesture(TapGesture().onEnded {
                searchFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            })
        }
        .frame(minWidth: 240)
    }

    @ViewBuilder
    private func sortHeader(_ label: String, key: EditViewModel.SortKey, width: CGFloat?) -> some View {
        Button {
            if viewModel.sortKey == key {
                viewModel.sortAscending.toggle()
            } else {
                viewModel.sortKey = key
                viewModel.sortAscending = true
            }
        } label: {
            HStack(spacing: 2) {
                Text(label)
                if viewModel.sortKey == key {
                    Image(systemName: viewModel.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7))
                }
            }
            .frame(minWidth: width,
                   maxWidth: width == nil ? .infinity : nil,
                   alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Object row

private struct ObjectRow: View {
    let obj: SoundObject
    let isSelected: Bool
    let filterText: String
    let stemColor: Color

    var body: some View {
        HStack(spacing: 0) {
            // Colour dot (the stem's colour)
            Circle()
                .fill(stemColor.opacity(0.75))
                .frame(width: 6, height: 6)
                .padding(.leading, 6)
                .padding(.trailing, 4)

            // Name (highlighted if filtered)
            highlightedText(obj.displayName, filter: filterText)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Time
            Text(String(format: "%.2f", obj.startTime))
                .frame(width: 50, alignment: .trailing)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)

            // Length
            Text(String(format: "%.2f", obj.duration))
                .frame(width: 46, alignment: .trailing)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)

            // Lane
            Text(verbatim: "\(obj.lane)")
                .frame(width: 34, alignment: .trailing)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    @ViewBuilder
    private func highlightedText(_ text: String, filter: String) -> some View {
        if filter.isEmpty {
            Text(text)
        } else if let range = text.range(of: filter, options: .caseInsensitive) {
            Text(text[text.startIndex..<range.lowerBound])
            + Text(text[range]).bold().foregroundColor(.accentColor)
            + Text(text[range.upperBound..<text.endIndex])
        } else {
            Text(text).opacity(0.45)
        }
    }
}
