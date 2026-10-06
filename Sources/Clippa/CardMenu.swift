import AppKit
import ClippaCore
import ClippaPasteboard
import SwiftUI

/// The right-click menu of a card. It acts on the whole selection when the
/// clicked card is part of it, otherwise on that card alone.
struct CardMenu: View {
    let item: Item
    @Bindable var model: ShelfModel

    private var targets: [Item] {
        model.selection.contains(item.id) ? model.selectedItemsInOrder : [item]
    }

    private var ids: [String] { targets.map(\.id) }

    var body: some View {
        Button(L("Paste")) { paste(plain: false) }
        Button(L("Paste as Plain Text")) { paste(plain: true) }
        Button(L("Copy")) {
            model.selection = ids
            model.copySelection()
        }
        Divider()
        if item.kind == .link {
            Button(L("Open Link")) { model.controller?.open(item) }
        }
        if item.kind == .file {
            Button(L("Show in Finder")) { model.controller?.open(item) }
        }
        Button(L("Preview")) {
            model.selection = [item.id]
            model.controller?.togglePreview()
        }
        if item.kind == .text || item.kind == .link || item.kind == .color {
            Button(L("Edit")) { model.controller?.edit(item) }
        }
        Button(L("Rename")) { model.renamingID = item.id }
        if item.kind == .image {
            Button(L("Rotate Left")) { model.controller?.rotate(item, clockwise: false) }
            Button(L("Rotate Right")) { model.controller?.rotate(item, clockwise: true) }
            if let text = item.ocrText, !text.isEmpty {
                Button(L("Copy Text from Image")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    model.flash(L("Text copied"))
                }
            }
        }
        Divider()
        Menu(L("Pin")) {
            ForEach(model.pinboards) { pinboard in
                Button {
                    model.pin(ids, to: pinboard.id)
                } label: {
                    if item.pinboardID == pinboard.id {
                        Label(pinboard.name, systemImage: "checkmark")
                    } else {
                        Text(pinboard.name)
                    }
                }
            }
            if !model.pinboards.isEmpty { Divider() }
            Button(L("New Pinboard…")) { model.creatingPinboard = true }
        }
        if targets.contains(where: \.isPinned) {
            Button(L("Unpin")) { model.pin(ids, to: nil) }
        }
        Menu(L("Keep")) {
            keepButton(.automatic, L("As in Settings (%@)", Pref.keepHistoryValue.name))
            Divider()
            keepButton(.hour, L("Delete after 1 Hour"))
            keepButton(.day, L("Delete after 1 Day"))
            keepButton(.week, L("Delete after 1 Week"))
            keepButton(.month, L("Delete after 1 Month"))
            keepButton(.year, L("Delete after 1 Year"))
            Divider()
            keepButton(.forever, L("Keep Forever"))
            if let expiry = item.expiryDate(retention: Pref.keepHistoryValue) {
                Divider()
                Text(L("Will be deleted %@", expiry.formatted(date: .abbreviated, time: .shortened)))
            }
        }
        if model.isSearching || model.showingSuggestions {
            Button(item.inHistory ? L("Show in Clipboard")
                   : L("Show in %@", model.pinboards.first { $0.id == item.pinboardID }?.name ?? "")) {
                model.selection = [item.id]
                model.showSelectedInList()
            }
        }
        Divider()
        Button(ids.count > 1 ? L("Delete %lld Items", ids.count) : L("Delete"), role: .destructive) {
            model.selection = ids
            model.deleteSelection()
        }
    }

    private func paste(plain: Bool) {
        model.selection = ids
        model.pasteSelection(plainText: plain)
    }

    private func keepButton(_ choice: KeepChoice, _ title: String) -> some View {
        Button {
            model.setKeep(choice, for: ids)
        } label: {
            if isCurrent(choice) {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func isCurrent(_ choice: KeepChoice) -> Bool {
        switch (choice, item.keep) {
        case (.automatic, .automatic), (.forever, .forever): return true
        default: return false
        }
    }
}

extension HistoryRetention {
    var name: String {
        switch self {
        case .day: return L("1 Day")
        case .week: return L("1 Week")
        case .month: return L("1 Month")
        case .year: return L("1 Year")
        case .forever: return L("Forever")
        }
    }
}
