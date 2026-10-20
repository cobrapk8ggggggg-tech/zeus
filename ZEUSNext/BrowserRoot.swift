import SwiftUI
import WebKit

enum BrowserPanel: String, Identifiable { case tabs, profiles, downloads, settings, library, tools, scripts, console; var id: String { rawValue } }

struct BrowserRoot: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var panel: BrowserPanel?
    @State private var draft = ""
    @State private var dialogText = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        ZStack {
            OrbitBackground(tint: model.profile.color)
            if model.requiresUnlock { lockedView }
            else { browserContent }
            if scenePhase != .active {
                ZStack { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea(); Image(systemName: "sparkles").font(.system(size: 58)).foregroundStyle(model.profile.color) }.accessibilityHidden(true)
            }
        }
        .tint(model.profile.color)
        .safeAreaInset(edge: .top, spacing: 0) { if !model.requiresUnlock { header } }
        .safeAreaInset(edge: .bottom, spacing: 0) { if !model.requiresUnlock { bottomBar } }
        .sheet(item: $panel) { item in panelContent(item).presentationDragIndicator(.visible).environment(\.layoutDirection, .rightToLeft) }
        .sheet(item: $model.article) { ReaderSheet(article: $0).environment(\.layoutDirection, .rightToLeft) }
        .sheet(item: $model.gallery) { GallerySheet(model: model, gallery: $0).environment(\.layoutDirection, .rightToLeft) }
        .sheet(item: $model.share) { ActivitySheet(url: $0.url) }
        .alert("رسالة من الصفحة", isPresented: Binding(get: { model.dialog != nil }, set: { if !$0, let dialog = model.dialog { dialog.complete(nil); model.dialog = nil } })) {
            if model.dialog?.kind == .prompt { TextField("النص", text: $dialogText) }
            Button("موافق") { let dialog = model.dialog; model.dialog = nil; dialog?.complete(dialogText) }
            if model.dialog?.kind != .alert { Button("إلغاء", role: .cancel) { let dialog = model.dialog; model.dialog = nil; dialog?.complete(nil) } }
        } message: { Text(model.dialog?.text ?? "") }
        .alert("ZEUS", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }), presenting: model.notice) { _ in Button("حسنًا", role: .cancel) {} } message: { Text($0.text) }
        .onChange(of: model.dialog?.id) { _, _ in dialogText = model.dialog?.initial ?? "" }
        .onChange(of: model.address) { _, value in if !addressFocused { draft = value } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.backgrounded() } }
        .onReceive(model.profiles.objectWillChange) { model.changed() }
        .onReceive(model.downloads.objectWillChange) { model.changed() }
        .onReceive(model.downloads.$message) { if let text = $0 { model.downloads.message = nil; model.notify(text) } }
        .onReceive(model.profiles.$errorMessage) { if let text = $0 { model.profiles.errorMessage = nil; model.notify(text) } }
        .task { draft = model.address; await model.ensureCurrentLoaded() }
    }
    @ViewBuilder private var browserContent: some View {
        if model.current?.isHome != false {
            HomeSurface(model: model, showProfiles: { panel = .profiles }, showDownloads: { panel = .downloads }, focusSearch: { addressFocused = true })
        } else if let error = model.current?.error {
            VStack(spacing: 20) {
                Image(systemName: "network.slash").font(.system(size: 48)).foregroundStyle(model.profile.color)
                Text("لنبدأ من جديد").font(.title2.bold())
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack { Button("إعادة المحاولة") { model.reload() }; Button("توافق الموقع") { model.toggleCompatibility() } }.buttonStyle(.bordered)
            }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let view = model.webView {
            WebSurface(webView: view).accessibilityIdentifier("webContent").ignoresSafeArea(.container, edges: [])
        } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
    private var header: some View {
        HStack {
            Button { panel = .profiles } label: {
                HStack(spacing: 9) {
                    Image(systemName: model.profile.symbol).font(.title3).foregroundStyle(model.profile.color)
                    Text(model.profile.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }.padding(.horizontal, 13).padding(.vertical, 11).glassSurface(22)
            }.buttonStyle(.plain).accessibilityIdentifier("profilesButton")
            Spacer()
            if model.profile.isPrivate { Label("خاص", systemImage: "theatermasks.fill").font(.caption).foregroundStyle(.purple) }
            Button { panel = .tools } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 18)).frame(width: 44, height: 44).glassSurface(22) }.buttonStyle(.plain).accessibilityIdentifier("toolsButton").accessibilityLabel("أدوات الصفحة")
        }.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 8)
    }
    private var bottomBar: some View {
        VStack(spacing: 7) {
            if model.pendingPopup != nil {
                HStack {
                    Image(systemName: "rectangle.on.rectangle.slash").foregroundStyle(.orange)
                    Text("حُظرت نافذة منبثقة").font(.caption)
                    Spacer(); Button("فتح مرة") { model.allowPendingPopup() }.font(.caption.bold())
                    Button { model.pendingPopup = nil } label: { Image(systemName: "xmark").font(.caption) }.accessibilityLabel("إخفاء")
                }.padding(13).glassSurface(17)
            }
            HStack(spacing: 10) {
                Button { model.toggleCompatibility() } label: { Image(systemName: model.siteCompatible ? "shield.slash" : "checkmark.shield").foregroundStyle(model.siteCompatible ? Color.orange : model.profile.color).frame(width: 32, height: 42) }.buttonStyle(.plain).disabled(model.current?.isHome != false).accessibilityLabel("توافق الموقع وحمايته")
                TextField("ابحث أو أدخل رابطًا", text: $draft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.webSearch).submitLabel(.go)
                    .focused($addressFocused).environment(\.layoutDirection, .leftToRight).multilineTextAlignment(.center)
                    .accessibilityIdentifier("addressField")
                    .onSubmit { addressFocused = false; model.open(draft) }
                Button {
                    if addressFocused { addressFocused = false; model.open(draft) }
                    else if model.current?.loading == true { model.webView?.stopLoading() }
                    else { model.reload() }
                } label: { Image(systemName: addressFocused ? "arrow.up" : model.current?.loading == true ? "xmark" : "arrow.clockwise").frame(width: 32, height: 42) }.buttonStyle(.plain).accessibilityLabel("فتح أو تحديث")
            }.padding(.horizontal, 10).padding(.vertical, 3).glassSurface(27)
                .overlay(alignment: .bottom) { if model.current?.loading == true { GeometryReader { proxy in Capsule().fill(model.profile.color).frame(width: proxy.size.width * max(0.04, model.current?.progress ?? 0), height: 2) }.frame(height: 2).padding(.horizontal, 22) } }
            HStack(spacing: 0) {
                ToolButton(symbol: "chevron.backward", label: "رجوع", disabled: model.webView?.canGoBack != true) { model.webView?.goBack() }
                Spacer(minLength: 0)
                ToolButton(symbol: "chevron.forward", label: "تقدم", disabled: model.webView?.canGoForward != true) { model.webView?.goForward() }
                Spacer(minLength: 0)
                ToolButton(symbol: "books.vertical", label: "المكتبة") { panel = .library }.accessibilityIdentifier("libraryButton")
                Spacer(minLength: 0)
                Button { panel = .downloads } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 21)).frame(width: 44, height: 44)
                        if model.downloads.forProfile(model.profile.id).contains(where: \.isBusy) { Circle().fill(model.profile.color).frame(width: 7, height: 7).offset(x: -3, y: 5) }
                    }
                }.buttonStyle(.plain).accessibilityLabel("التنزيلات").accessibilityIdentifier("downloadsButton")
                Spacer(minLength: 0)
                Button { panel = .tabs } label: {
                    Text("\(model.tabs.count)").font(.system(size: 13, weight: .semibold, design: .rounded)).frame(width: 23, height: 25).overlay(RoundedRectangle(cornerRadius: 6).stroke(lineWidth: 1.6)).frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("التبويبات").accessibilityIdentifier("tabsButton")
                Spacer(minLength: 0)
                ToolButton(symbol: "gearshape", label: "الإعدادات") { panel = .settings }.accessibilityIdentifier("settingsButton")
            }.foregroundStyle(.white.opacity(0.9)).padding(.horizontal, 7)
        }.padding(.horizontal, 17).padding(.top, 9).padding(.bottom, 3)
            .background { LinearGradient(colors: [.clear, Color(red: 0.025, green: 0.04, blue: 0.075).opacity(0.98)], startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .bottom) }
    }
    private var lockedView: some View {
        VStack(spacing: 22) {
            Image(systemName: "lock.shield.fill").font(.system(size: 68, weight: .ultraLight)).foregroundStyle(model.profile.color)
            Text(model.profile.name).font(.title.bold())
            Text("مساحة محمية برمز الجهاز أو البصمة").foregroundStyle(.secondary)
            Button("فتح المساحة") { Task { await model.unlock() } }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @ViewBuilder private func panelContent(_ panel: BrowserPanel) -> some View {
        switch panel {
        case .tabs: TabsSheet(model: model)
        case .profiles: ProfilesSheet(model: model)
        case .downloads: DownloadsSheet(model: model)
        case .settings: SettingsSheet(model: model)
        case .library: LibrarySheet(model: model)
        case .tools: ToolsSheet(model: model)
        case .scripts: ScriptsSheet(model: model)
        case .console: ConsoleSheet(model: model)
        }
    }
}

struct HomeSurface: View {
    @ObservedObject var model: BrowserModel
    var showProfiles: () -> Void
    var showDownloads: () -> Void
    var focusSearch: () -> Void
    private var shortcuts: [Bookmark] {
        if !model.data.bookmarks.isEmpty { return Array(model.data.bookmarks.prefix(8)) }
        return [Bookmark(title: "GitHub", url: "https://github.com"), Bookmark(title: "Wikipedia", url: "https://ar.wikipedia.org"), Bookmark(title: "DuckDuckGo", url: "https://duckduckgo.com"), Bookmark(title: "Apple", url: "https://www.apple.com")]
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                brand
                VStack(alignment: .leading, spacing: 9) {
                    Text(model.profile.isPrivate ? "لحظتك، لك وحدك." : "مساحتك، بلا حدود.").font(.system(size: 31, weight: .bold, design: .rounded))
                    Text(model.profile.isPrivate ? "تُمسح جلسة هذه المساحة عند مغادرتها أو انتقال التطبيق للخلفية." : "تصفح بهدوء. نظّم عالمك. واحتفظ بكل شيء في مكانه.").font(.subheadline).foregroundStyle(.white.opacity(0.5)).lineSpacing(5)
                }
                HStack(spacing: 12) {
                    insight("checkmark.shield", title: "حماية ذكية", detail: "\(model.shield.domains.count) نطاق", color: .mint, action: focusSearch)
                    insight("square.stack.3d.up", title: "مساحات مستقلة", detail: "\(model.profiles.profiles.count) بروفايلات", color: .purple, action: showProfiles)
                }
                HStack { Text("الوصول السريع").font(.headline); Spacer(); Image(systemName: "sparkle").foregroundStyle(model.profile.color) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(shortcuts) { item in
                        Button { model.open(item.url) } label: {
                            HStack(spacing: 11) {
                                Text(String(item.title.prefix(1)).uppercased()).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(model.profile.color).frame(width: 42, height: 42).background(model.profile.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 4) { Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1); Text(BrowserURL.displayHost(item.url)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                                Spacer(minLength: 0)
                            }.padding(14).frame(maxWidth: .infinity, minHeight: 74).glassSurface(22)
                        }.buttonStyle(.plain)
                    }
                }
                Button(action: showDownloads) {
                    HStack(spacing: 15) {
                        Image(systemName: "arrow.down.to.line.compact").font(.title2).foregroundStyle(model.profile.color)
                        VStack(alignment: .leading, spacing: 5) { Text("كل ملفاتك. تحت سيطرتك.").font(.subheadline.weight(.semibold)); Text("تنزيل، استئناف، معاينة، وتصدير إلى الملفات").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.secondary)
                    }.padding(19).glassSurface(24)
                }.buttonStyle(.plain)
            }.padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
        }.scrollIndicators(.hidden)
    }
    private var brand: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("ZEUS").font(.system(size: 55, weight: .ultraLight, design: .rounded)).tracking(10)
                Text("A SPACE OF YOUR OWN").font(.system(size: 8, weight: .semibold)).tracking(3.7).foregroundStyle(.white.opacity(0.35))
            }.environment(\.layoutDirection, .leftToRight)
            Spacer()
            ZStack {
                Circle().stroke(model.profile.color.opacity(0.17), lineWidth: 1).frame(width: 108, height: 108)
                Circle().stroke(.white.opacity(0.08), lineWidth: 1).frame(width: 82, height: 82)
                Image(systemName: "sparkles").font(.system(size: 34, weight: .light)).foregroundStyle(LinearGradient(colors: [.white, model.profile.color], startPoint: .top, endPoint: .bottom)).frame(width: 66, height: 66).glassSurface(33)
                Circle().fill(model.profile.color).frame(width: 5, height: 5).offset(x: 43, y: -31)
            }.accessibilityHidden(true)
        }.padding(.top, 25).padding(.bottom, 5)
    }
    private func insight(_ symbol: String, title: String, detail: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 11) { Image(systemName: symbol).font(.system(size: 23, weight: .light)).foregroundStyle(color); Text(title).font(.subheadline.weight(.semibold)); Text(detail).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(19).glassSurface(24)
        }.buttonStyle(.plain)
    }
}
