import SwiftUI

struct BrowserPane: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var model: BrowserModel
    let tab: BrowserTab?
    var body: some View {
        Group {
            if tab?.isHome != false { OriginalHome(model: model).id(model.profile.id) }
            else if let error = tab?.error { VStack(spacing: 20) { Image(systemName: "network.slash").font(.largeTitle); Text(error).multilineTextAlignment(.center); Button("إعادة المحاولة") { if let tab { model.focusPane(tab) }; model.reload() }; Button("توافق الموقع") { if let tab { model.focusPane(tab) }; model.toggleCompatibility() } }.padding(25) }
            else if let view = tab?.webView { ZStack { WebSurface(webView: view).accessibilityIdentifier("webContent"); if tab?.committed == false, let snapshot = tab?.snapshot { Image(uiImage: snapshot).resizable().scaledToFill().allowsHitTesting(false) } }.clipped() }
            else { VStack(spacing: 18) { Text(BrowserURL.displayHost(tab?.url ?? "")).font(.footnote).foregroundStyle(.secondary); Button("إعادة فتح الصفحة") { model.reload() } }.task(id: tab?.id) { await model.ensureCurrentLoaded() } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.backgroundColor)
            .simultaneousGesture(TapGesture().onEnded { if let tab { model.focusPane(tab) } })
    }
}
struct TwinBrowserSurface: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var model: BrowserModel
    @State private var initialFraction: CGFloat?
    var body: some View {
        GeometryReader { geometry in
            Group {
                if model.twinVertical {
                    VStack(spacing: 0) { pane(model.primary).frame(height: max(0, geometry.size.height * model.twinFraction - 3)); divider(geometry); pane(model.secondary) }
                } else {
                    HStack(spacing: 0) { pane(model.primary).frame(width: max(0, geometry.size.width * model.twinFraction - 3)); divider(geometry); pane(model.secondary) }
                }
            }.environment(\.layoutDirection, .leftToRight)
        }
    }
    private func pane(_ tab: BrowserTab?) -> some View {
        BrowserPane(model: model, tab: tab).overlay(Rectangle().stroke(theme.textColor.opacity(model.current?.id == tab?.id ? 0.35 : 0), lineWidth: 1))
    }
    private func divider(_ geometry: GeometryProxy) -> some View {
        Rectangle().fill(theme.textColor.opacity(0.25)).frame(width: model.twinVertical ? nil : 6, height: model.twinVertical ? 6 : nil)
            .gesture(DragGesture().onChanged { drag in
                if initialFraction == nil { initialFraction = model.twinFraction }
                let movement = model.twinVertical ? drag.translation.height / max(1, geometry.size.height) : drag.translation.width / max(1, geometry.size.width)
                model.twinFraction = min(0.8, max(0.2, (initialFraction ?? 0.5) + movement))
            }.onEnded { _ in initialFraction = nil })
    }
}
