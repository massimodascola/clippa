import AppKit
import ClippaCore
import SwiftUI

/// Search on the left, the lists (Clipboard and pinboards) in the middle,
/// suggestions and the menu on the right.
struct TopBarView: View {
    @Bindable var model: ShelfModel
    @AppStorage(Pref.suggestionsEnabled) private var suggestionsEnabled = true

    var body: some View {
        // Three columns: search on the left and buttons on the right get the
        // same width, so the lists stay centered and nothing gets squeezed.
        GeometryReader { geometry in
            let side = min(520, max(220, geometry.size.width * 0.3))
            HStack(spacing: 10) {
                SearchFieldView(model: model)
                    .frame(width: side, alignment: .leading)
                ListTabsView(model: model)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 8) {
                    if suggestionsEnabled {
                        Button {
                            model.controller?.toggleSuggestions()
                        } label: {
                            Image(systemName: "sparkles")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(model.showingSuggestions ? Color.white : Color.primary.opacity(0.75))
                                .frame(width: 30, height: 26)
                                .background(model.showingSuggestions ? Color.accentColor : Color.primary.opacity(0.06),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(L("Suggestions: items that fit the app you are pasting into"))
                    }
                    MoreMenu(model: model)
                }
                .frame(width: side, alignment: .trailing)
            }
            .padding(.horizontal, 18)
            .frame(maxHeight: .infinity)
        }
    }
}

/// The magnifying glass that becomes a search field with filter tokens.
struct SearchFieldView: View {
    @Bindable var model: ShelfModel
    @FocusState private var focused: Bool

    private var expanded: Bool { model.searchFocused || model.isSearching }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if expanded {
                ForEach(model.filters) { token in
                    TokenView(token: token, removable: true) { model.remove(token) }
                }
                TextField(L("Search"), text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .frame(minWidth: 120)
                if !model.filterSuggestions.isEmpty {
                    ForEach(model.filterSuggestions) { token in
                        Button { model.apply(token) } label: {
                            TokenView(token: token, removable: false, suggested: true) {}
                        }
                        .buttonStyle(.plain)
                    }
                }
                FilterMenu(model: model)
                if model.isSearching {
                    Button { model.clearSearch() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: expanded ? .infinity : 34, alignment: .leading)
        .background(Color.primary.opacity(expanded ? 0.08 : 0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.searchFocused = true }
        .onChange(of: model.searchFocused) { _, value in focused = value }
        .onChange(of: focused) { _, value in if value != model.searchFocused { model.searchFocused = value } }
        .onAppear { focused = model.searchFocused }
        .animation(.easeOut(duration: 0.15), value: expanded)
    }
}

struct TokenView: View {
    let token: FilterToken
    let removable: Bool
    var suggested = false
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: token.symbol).font(.system(size: 10, weight: .semibold))
            Text(token.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
            if removable {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(suggested ? Color.primary : Color.white)
        .background(suggested ? Color.primary.opacity(0.1) : Color.accentColor, in: Capsule())
    }
}

/// Every filter, from the funnel button (or Command-F while searching).
struct FilterMenu: View {
    @Bindable var model: ShelfModel

    var body: some View {
        Menu {
            Section(L("Type")) {
                ForEach(ItemKind.allCases, id: \.self) { kind in
                    Button { model.apply(.kind(kind)) } label: { Label(kind.pluralName, systemImage: kind.symbol) }
                }
            }
            Section(L("Date")) {
                ForEach(DateFilter.allCases, id: \.self) { date in
                    Button(date.name) { model.apply(.date(date)) }
                }
            }
            let options = model.allFilterOptions
            Menu(L("App")) {
                ForEach(options.apps.prefix(40), id: \.bundleID) { app in
                    Button(app.name) { model.apply(.app(app.bundleID, app.name)) }
                }
            }
            if options.devices.count > 1 {
                Menu(L("Device")) {
                    ForEach(options.devices, id: \.id) { device in
                        Button(device.name) { model.apply(.device(device.id, device.name)) }
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Filters"))
    }
}

/// Clipboard History plus one tab per pinboard, and the + button.
struct ListTabsView: View {
    @Bindable var model: ShelfModel
    @State private var newName = ""
    @FocusState private var newNameFocused: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                TabButton(title: L("Clipboard"), symbol: "clock", color: nil,
                          selected: model.list == .history && !model.isSearching && !model.showingSuggestions) {
                    model.show(list: .history)
                }
                ForEach(model.pinboards) { pinboard in
                    PinboardTab(model: model, pinboard: pinboard)
                }
                if model.creatingPinboard {
                    HStack(spacing: 5) {
                        Circle().fill(nextColor.color).frame(width: 8, height: 8)
                        TextField(L("Pinboard name"), text: $newName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 120)
                            .focused($newNameFocused)
                            .onSubmit {
                                model.createPinboard(name: newName, color: nextColor)
                                newName = ""
                            }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .onAppear { newNameFocused = true }
                } else {
                    Button { model.creatingPinboard = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L("New Pinboard (⇧⌘N)"))
                }
            }
            .padding(.horizontal, 2)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: model.creatingPinboard) { _, creating in if !creating { newName = "" } }
    }

    private var nextColor: PinboardColor {
        let used = Set(model.pinboards.map(\.color))
        let palette: [PinboardColor] = [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink, .mint, .indigo, .brown, .gray]
        return palette.first { !used.contains($0) } ?? palette[model.pinboards.count % palette.count]
    }
}

struct TabButton: View {
    let title: String
    let symbol: String?
    let color: Color?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let color {
                    Circle().fill(color).frame(width: 8, height: 8)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(selected ? Color.primary.opacity(0.14) : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct PinboardTab: View {
    @Bindable var model: ShelfModel
    let pinboard: Pinboard
    @State private var name = ""
    @State private var dropTargeted = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        Group {
            if model.editingPinboardID == pinboard.id {
                HStack(spacing: 5) {
                    Circle().fill(pinboard.color.color).frame(width: 8, height: 8)
                    TextField("", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 110)
                        .focused($nameFocused)
                        .onSubmit { model.renamePinboard(pinboard.id, to: name) }
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Color.primary.opacity(0.1), in: Capsule())
                .onAppear {
                    name = pinboard.name
                    nameFocused = true
                }
            } else {
                TabButton(title: pinboard.name, symbol: nil, color: pinboard.color.color,
                          selected: model.list == .pinboard(pinboard.id) && !model.isSearching && !model.showingSuggestions) {
                    model.show(list: .pinboard(pinboard.id))
                }
                .overlay(Capsule().strokeBorder(pinboard.color.color, lineWidth: dropTargeted ? 2 : 0))
            }
        }
        .onDrop(of: [.clippaItem], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadDataRepresentation(for: .clippaItem) { data, _ in
                    guard let data, let id = String(data: data, encoding: .utf8) else { return }
                    DispatchQueue.main.async {
                        let ids = model.selection.contains(id) ? model.selectedItemsInOrder.map(\.id) : [id]
                        model.pin(ids, to: pinboard.id)
                    }
                }
            }
            return true
        }
        .contextMenu {
            Button(L("Rename")) { model.editingPinboardID = pinboard.id }
            Menu(L("Color")) {
                ForEach(PinboardColor.allCases, id: \.self) { color in
                    Button {
                        model.setColor(color, of: pinboard.id)
                    } label: {
                        if color == pinboard.color {
                            Label(color.name, systemImage: "checkmark")
                        } else {
                            Text(color.name)
                        }
                    }
                }
            }
            if let index = model.pinboards.firstIndex(of: pinboard) {
                if index > 0 {
                    Button(L("Move Left")) { model.movePinboard(pinboard.id, before: model.pinboards[index - 1].id) }
                }
                if index < model.pinboards.count - 1 {
                    Button(L("Move Right")) {
                        model.movePinboard(pinboard.id, before: index + 2 < model.pinboards.count ? model.pinboards[index + 2].id : nil)
                    }
                }
            }
            Divider()
            Button(L("Delete Pinboard…"), role: .destructive) {
                model.controller?.confirmDeletePinboard(pinboard)
            }
        }
    }
}

/// The "…" menu: pause, Paste Stack, settings.
struct MoreMenu: View {
    @Bindable var model: ShelfModel

    var body: some View {
        Menu {
            Button(L("New Text Item")) { model.createTextItem() }
            Button(L("New Pinboard")) { model.creatingPinboard = true }
            Divider()
            Button(L("Paste Stack")) { model.controller?.startPasteStack() }
            Button(L("Pause Clippa for 1 Hour")) { model.controller?.pause() }
            Divider()
            Button(L("Settings…")) { model.controller?.openSettings() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
