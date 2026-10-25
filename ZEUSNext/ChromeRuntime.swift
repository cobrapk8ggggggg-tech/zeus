import SwiftUI

struct ChromeBlockDecoration: ViewModifier {
    let block: ChromeBlock
    func body(content: Content) -> some View {
        content.foregroundStyle(BrowserTheme.color(block.foreground))
            .font(.system(size: block.fontSize, weight: .medium))
            .background {
                if block.glass { RoundedRectangle(cornerRadius: block.corner).fill(.ultraThinMaterial) }
                RoundedRectangle(cornerRadius: block.corner).fill(BrowserTheme.color(block.background).opacity(block.opacity))
            }
            .clipShape(RoundedRectangle(cornerRadius: block.corner))
            .overlay(RoundedRectangle(cornerRadius: block.corner).strokeBorder(BrowserTheme.color(block.border), lineWidth: block.borderWidth))
    }
}
struct ChromeBlockGlyph: View {
    let block: ChromeBlock
    var body: some View {
        VStack(spacing: 3) {
            if block.kind == .action || block.kind == .address { Image(systemName: block.displaySymbol) }
            if block.kind != .action || block.showTitle { Text(block.displayTitle).font(.system(size: min(block.fontSize, 14))).lineLimit(1).minimumScaleFactor(0.6) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
    }
}

/// Uses the browser's existing model/actions. A saved design is geometry and
/// appearance data; it cannot inject scripts or bypass profile permissions.
struct ChromeRuntimeLayer: View {
    @ObservedObject var model: BrowserModel
    let composition: ChromeComposition
    let perform: (BrowserAction) -> Void
    @State private var address = ""
    @FocusState private var focused: Bool
    var body: some View {
        GeometryReader { geometry in
            ForEach(composition.blocks.filter { !$0.hidden }) { block in
                let rect = block.rect(in: geometry.size)
                blockContent(block)
                    .buttonStyle(.plain).frame(width: rect.width, height: rect.height)
                    .modifier(ChromeBlockDecoration(block: block))
                    .rotationEffect(.degrees(block.rotation))
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(block.kind != .panel && block.kind != .label)
            }
        }.environment(\.layoutDirection, .leftToRight)
            .onAppear { address = model.address }
            .onChange(of: model.address) { _, newValue in if !focused { address = newValue } }
    }
    @ViewBuilder private func blockContent(_ block: ChromeBlock) -> some View {
        switch block.kind {
        case .action:
            if let action = BrowserAction(rawValue: block.action) {
                if action == .tools {
                    Menu {
                        ForEach(BrowserActionGroup.allCases) { group in
                            Menu { ForEach(group.actions) { action in Button(action.title, systemImage: action.symbol) { perform(action) } } } label: { Label(group.title, systemImage: group.symbol) }
                        }
                    } label: { ChromeBlockGlyph(block: block) }
                        .accessibilityLabel(block.displayTitle)
                } else {
                    Button { focused = false; perform(action) } label: { ChromeBlockGlyph(block: block) }
                        .disabled(action == .back && model.webView?.canGoBack != true || action == .forward && model.webView?.canGoForward != true)
                        .accessibilityLabel(block.displayTitle).accessibilityIdentifier("custom-" + block.id.uuidString)
                }
            }
        case .address:
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 14))
                TextField("ابحث أو أدخل رابطًا", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.webSearch).submitLabel(.go)
                    .focused($focused).onSubmit { focused = false; model.open(address) }
                    .font(.system(size: min(20, block.fontSize)))
            }.padding(.horizontal, 12)
        case .tabs:
            RememberedTabScroll(model: model, key: "studio-" + block.id.uuidString) {
                HStack(spacing: 3) { BrowserTabCollection(model: model, compact: true) }
            }
        case .bookmarks:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) { ForEach(model.data.bookmarks) { site in Button(site.title) { model.open(site.url) }.font(.system(size: min(18, block.fontSize))).lineLimit(1) } }.padding(.horizontal, 10)
            }
        case .label: Text(block.displayTitle).lineLimit(2).minimumScaleFactor(0.5).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .panel: Color.clear
        }
    }
}
