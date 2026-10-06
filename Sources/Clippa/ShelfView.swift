import AppKit
import ClippaCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Internal drag type: an item id, for dropping cards on a pinboard.
    static let clippaItem = UTType(exportedAs: "com.massimodascola.clippa.item")
}

extension PinboardColor {
    var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .mint: return .mint
        case .teal: return .teal
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .brown: return .brown
        case .gray: return .gray
        }
    }

    var name: String {
        switch self {
        case .red: return L("Red")
        case .orange: return L("Orange")
        case .yellow: return L("Yellow")
        case .green: return L("Green")
        case .mint: return L("Mint")
        case .teal: return L("Teal")
        case .blue: return L("Blue")
        case .indigo: return L("Indigo")
        case .purple: return L("Purple")
        case .pink: return L("Pink")
        case .brown: return L("Brown")
        case .gray: return L("Gray")
        }
    }
}

/// The whole shelf: top bar, then the horizontal strip of cards.
struct ShelfView: View {
    @Bindable var model: ShelfModel

    var body: some View {
        ZStack(alignment: .top) {
            VisualEffectBackground()
            VStack(spacing: 0) {
                TopBarView(model: model)
                    .frame(height: model.compact ? 40 : 50)
                    .padding(.top, 4)
                content
            }
            ResizeHandle(model: model)
                .frame(height: 6)
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 4)
                    .padding(.top, 54)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.toast)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var content: some View {
        if model.showingSuggestions && !model.isSearching && model.suggestionsLoading && model.suggestions.isEmpty {
            EmptyStateView(symbol: "sparkles", title: L("Finding suggestions…"), detail: nil, loading: true)
        } else if model.visibleItems.isEmpty {
            emptyState
        } else {
            CardStripView(model: model)
                .overlay(alignment: .bottom) {
                    if model.selection.count > 1 {
                        SelectionBar(model: model)
                            .padding(.bottom, model.compact ? 4 : 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: model.selection.count > 1)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isSearching {
            EmptyStateView(symbol: "magnifyingglass", title: L("No results"),
                           detail: L("Search looks in every list, including text inside images."))
        } else if model.showingSuggestions {
            EmptyStateView(symbol: "sparkles", title: L("No suggestions yet"),
                           detail: L("Clippa learns what you paste in each app."))
        } else if model.currentPinboard != nil {
            EmptyStateView(symbol: "pin", title: L("This pinboard is empty"),
                           detail: L("Drag items here, or right-click an item and choose Pin."))
        } else {
            EmptyStateView(symbol: "doc.on.clipboard", title: L("Nothing copied yet"),
                           detail: L("Everything you copy appears here."))
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let detail: String?
    var loading = false

    var body: some View {
        VStack(spacing: 8) {
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
            }
            Text(title).font(.system(size: 14, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 20)
    }
}

private struct CardFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// The horizontal, lazily loaded row of cards.
struct CardStripView: View {
    @Bindable var model: ShelfModel

    var body: some View {
        GeometryReader { geometry in
            let height = max(geometry.size.height - (model.compact ? 18 : 30), 90)
            let width = model.compact ? height * 1.18 : height * 0.94
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: model.compact ? 10 : 16) {
                        ForEach(Array(model.visibleItems.enumerated()), id: \.element.id) { index, item in
                            CardView(item: item, index: index, model: model, width: width, height: height)
                                .id(item.id)
                                .background(GeometryReader { card in
                                    Color.clear.preference(key: CardFramesKey.self,
                                                           value: [index: card.frame(in: .named("strip")).minX])
                                })
                                .onAppear {
                                    if index >= model.visibleItems.count - 20 { model.loadMore() }
                                }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, model.compact ? 4 : 8)
                    .padding(.bottom, model.compact ? 14 : 22)
                }
                .coordinateSpace(name: "strip")
                .onPreferenceChange(CardFramesKey.self) { frames in
                    let visible = frames.filter { $0.value >= -width / 2 }.map(\.key)
                    model.firstVisibleIndex = visible.min() ?? 0
                }
                .onChange(of: model.scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(target) }
                    model.scrollTarget = nil
                }
            }
        }
    }
}

/// Frosted background, like the system's own panels.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The top edge: drag it to make the shelf taller or shorter.
struct ResizeHandle: NSViewRepresentable {
    let model: ShelfModel

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: HandleView, context: Context) {
        nsView.model = model
    }

    final class HandleView: NSView {
        weak var model: ShelfModel?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }

        override func mouseDragged(with event: NSEvent) {
            MainActor.assumeIsolated {
                model?.controller?.resize(toTop: NSEvent.mouseLocation.y)
            }
        }
    }
}

/// Shown when several cards are selected (⌘-click, ⇧-click, ⇧← ⇧→ or ⌘A):
/// what can be done to all of them at once.
struct SelectionBar: View {
    @Bindable var model: ShelfModel

    var body: some View {
        HStack(spacing: 14) {
            Text(L("%lld selected", model.selection.count))
                .font(.system(size: 12, weight: .semibold))
            Divider().frame(height: 16)
            Button { model.pasteSelection(plainText: false) } label: {
                Label(L("Paste"), systemImage: "arrow.down.doc")
            }
            Menu {
                ForEach(model.pinboards) { pinboard in
                    Button(pinboard.name) { model.pin(model.selectedItemsInOrder.map(\.id), to: pinboard.id) }
                }
                if !model.pinboards.isEmpty { Divider() }
                Button(L("New Pinboard…")) { model.creatingPinboard = true }
            } label: {
                Label(L("Pin"), systemImage: "pin")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button(role: .destructive) { model.deleteSelection() } label: {
                Label(L("Delete"), systemImage: "trash")
            }
            .foregroundStyle(.red)
            Button { model.selection = Array(model.selection.suffix(1)) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .help(L("Deselect"))
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }
}
