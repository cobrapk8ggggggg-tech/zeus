import SwiftUI
import WebKit

enum BrowserPanel: String, Identifiable { case tabs, profiles, downloads, settings, library, history, tools, scripts, console, forms; var id: String { rawValue } }
enum BrowserAction: String, CaseIterable, Identifiable {
    case back, forward, reload, home, newTab, tabs, library, history, reader, gallery, downloads, profiles, scripts, console, shield, share, settings, tools, bookmark, pinTab, twinHorizontal, twinVertical, savePage, printPage, darkPage, fullScreen, saveForm, fillForm
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .saveForm: return "plus.rectangle.on.rectangle"; case .fillForm: return "square.and.pencil"
        case .bookmark: return "bookmark.badge.plus"; case .pinTab: return "pin"; case .twinHorizontal: return "rectangle.split.2x1"; case .twinVertical: return "rectangle.split.1x2"; case .savePage: return "doc"; case .printPage: return "printer"; case .darkPage: return "moon"; case .fullScreen: return "arrow.up.left.and.arrow.down.right"
        case .back: return "chevron.backward"; case .forward: return "chevron.forward"; case .reload: return "arrow.clockwise"; case .home: return "house.fill"; case .newTab: return "plus"; case .tabs: return "square.on.square"; case .library: return "globe"; case .history: return "clock.arrow.circlepath"; case .reader: return "doc.plaintext"; case .gallery: return "photo.on.rectangle"; case .downloads: return "arrow.down.circle"; case .profiles: return "person.crop.circle"; case .scripts: return "curlybraces"; case .console: return "terminal"; case .shield: return "shield"; case .share: return "square.and.arrow.up"; case .settings: return "gearshape"; case .tools: return "ellipsis.circle"
        }
    }
    var title: String {
        switch self {
        case .saveForm: return "حفظ النموذج"; case .fillForm: return "ملء النماذج"
        case .bookmark: return "إضافة للمفضلة"; case .pinTab: return "تثبيت التبويب"; case .twinHorizontal: return "متصفح مزدوج أفقي"; case .twinVertical: return "متصفح مزدوج عمودي"; case .savePage: return "حفظ الصفحة"; case .printPage: return "طباعة"; case .darkPage: return "تعتيم الصفحة"; case .fullScreen: return "إخفاء الأشرطة"
        case .back: return "رجوع"; case .forward: return "تقدم"; case .reload: return "تحديث"; case .home: return "الرئيسية"; case .newTab: return "تبويب جديد"; case .tabs: return "التبويبات"; case .library: return "المواقع"; case .history: return "السجل"; case .reader: return "القارئ"; case .gallery: return "معرض الصور"; case .downloads: return "التنزيلات"; case .profiles: return "البروفايلات"; case .scripts: return "السكربتات"; case .console: return "أدوات المطور"; case .shield: return "حماية الموقع"; case .share: return "مشاركة"; case .settings: return "الإعدادات"; case .tools: return "أدوات الصفحة"
        }
    }
    var identifier: String { rawValue + "Button" }
}

struct BrowserRoot: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("showCurrentUserAvatar") private var showCurrentUserAvatar = false
    @State private var panel: BrowserPanel?
    @State private var toolbarVisible = false
    @State private var topTray = false
    @State private var draft = ""
    @State private var dialogText = ""
    @FocusState private var addressFocused: Bool
    private var layout: ChromeLayout { model.data.settings.chromeLayout ?? .original }
    private var barsVisible: Bool { !model.chromeHidden || addressFocused || model.current?.isHome != false }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.requiresUnlock { lockedView }
            else {
                VStack(spacing: 0) {
                    if model.profile.role != .kiosk && layout != .original && barsVisible { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
                    browserContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.profile.role != .kiosk && layout == .dualBars && barsVisible { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
                }
                if model.profile.role == .kiosk { kioskControls }
                else if layout == .original { originalControls.environment(\.layoutDirection, .leftToRight) }
                else if !barsVisible { edgeReveal }
                if topTray { tabsTray.transition(.move(edge: .top)).zIndex(10) }
            }
            if scenePhase != .active { Color.black.ignoresSafeArea().overlay(Image(systemName: "lock").font(.largeTitle)).accessibilityHidden(true) }
        }
        .foregroundStyle(.white).tint(.white).background(.black)
        .statusBarHidden(layout == .original)
        .ignoresSafeArea(.container, edges: layout == .original ? .all : [])
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.chromeHidden)
        .fullScreenCover(item: $panel) { item in panelContent(item).tint(.white).preferredColorScheme(.dark).environment(\.layoutDirection, .rightToLeft) }
        .fullScreenCover(item: $model.article) { ReaderSheet(model: model, article: $0).tint(.white) }
        .fullScreenCover(item: $model.gallery) { GallerySheet(model: model, gallery: $0).tint(.white) }
        .fullScreenCover(item: $model.formDraft) { FormDraftView(model: model, draft: $0) }
        .sheet(item: $model.share) { ActivitySheet(url: $0.url) }
        .onChange(of: model.dialog?.id) { _, _ in if let dialog = model.dialog { model.dialog = nil; BrowserPresentation.present(dialog) } }
        .onChange(of: model.notice?.id) { _, _ in if let notice = model.notice { model.notice = nil; BrowserPresentation.notice(notice.text) } }
        .onChange(of: model.requiresUnlock) { _, locked in if locked { panel = nil; model.article = nil; model.gallery = nil; model.formDraft = nil; model.share = nil; BrowserPresentation.dismissTools() } }
        .onChange(of: model.address) { _, value in if !addressFocused { draft = value } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.backgrounded() }; if phase == .active { model.becameActive() } }
        .onReceive(model.profiles.objectWillChange) { model.changed() }
        .onReceive(model.downloads.objectWillChange) { model.changed() }
        .onReceive(model.downloads.$message) { if let text = $0 { model.downloads.message = nil; model.notify(text) } }
        .onReceive(model.profiles.$errorMessage) { if let text = $0 { model.profiles.errorMessage = nil; model.notify(text) } }
        .task { draft = model.address; await model.ensureCurrentLoaded() }
    }
    @ViewBuilder private var browserContent: some View {
        if model.secondary != nil { TwinBrowserSurface(model: model) }
        else { BrowserPane(model: model, tab: model.current) }
    }
    private var addressBar: some View {
        HStack(spacing: 8) {
            actionButton(layout == .icab ? .bookmark : .shield)
            TextField("ابحث أو أدخل رابطًا", text: $draft).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.webSearch).submitLabel(.go).focused($addressFocused).environment(\.layoutDirection, .leftToRight).multilineTextAlignment(layout == .icab ? .leading : .center).accessibilityIdentifier("addressField").onSubmit { addressFocused = false; model.open(draft) }
            actionButton(.reload)
        }.padding(.horizontal, 5).glassSurface(24)
    }
    private var topBar: some View {
        VStack(spacing: 5) {
            if layout == .icab {
                HStack(spacing: 0) {
                    if sizeClass == .regular { actionButton(.library); actionButton(.share); actionButton(.tabs) }
                    actionButton(.back); actionButton(.forward); addressBar; actionButton(.profiles)
                }
                if model.data.settings.advanced?.showBookmarksBar != false {
                    HStack(spacing: 0) {
                        actionButton(.home)
                        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 18) { ForEach(model.data.bookmarks) { bookmark in Button(bookmark.title) { model.open(bookmark.url) }.font(.subheadline).lineLimit(1) } } }
                        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 0) { ForEach([BrowserAction.reader, .scripts, .downloads, .fullScreen, .twinHorizontal, .darkPage, .settings]) { actionButton($0) } } }.frame(maxWidth: sizeClass == .regular ? 270 : 140)
                        actionButton(.tools)
                    }
                }
                if model.data.settings.advanced?.showTabsBar != false {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 1) {
                            ForEach(model.tabs) { tab in HStack(spacing: 10) { Button { model.closeTab(tab) } label: { Image(systemName: "xmark").font(.caption) }; Button { model.selectTab(tab) } label: { Text(tab.title).font(.caption).lineLimit(1).frame(minWidth: 75, maxWidth: 170) } }.padding(.horizontal, 12).frame(height: 34).background(model.selectedTabID == tab.id ? .white.opacity(0.12) : .black).overlay(Rectangle().stroke(.white.opacity(0.12), lineWidth: 0.5)) }
                            actionButton(.newTab)
                        }
                    }
                }
            } else { HStack { actionButton(.profiles); Spacer(); Text(model.profile.name).font(.subheadline); Spacer(); actionButton(.tools) } }
            if model.current?.loading == true { ProgressView(value: model.current?.progress ?? 0).tint(.white).frame(height: 2) }
        }.padding(.horizontal, layout == .icab ? 4 : 12).padding(.vertical, 5).background(.black).environment(\.layoutDirection, .leftToRight)
    }
    private var bottomBar: some View {
        VStack(spacing: 4) {
            if model.pendingPopup != nil { HStack { Text("حُظرت نافذة منبثقة").font(.caption); Spacer(); Button("فتح مرة") { model.allowPendingPopup() }; Button("إخفاء") { model.pendingPopup = nil } }.font(.caption).padding(10) }
            if layout == .dualBars { addressBar }
            HStack {
                ForEach(layout == .icab ? [BrowserAction.library, .downloads, .profiles, .tabs, .settings, .tools] : [.back, .forward, .library, .downloads, .tabs, .tools]) { item in actionButton(item).frame(maxWidth: .infinity) }
            }
        }.padding(.horizontal, 12).padding(.bottom, 3).background(.black)
    }
    private var originalControls: some View {
        ZStack(alignment: .trailing) {
            if toolbarVisible {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 9) {
                        ForEach([BrowserAction.back, .forward, .reload, .home, .newTab, .library, .history, .reader, .gallery, .console, .scripts, .darkPage, .tools]) { item in actionButton(item); if [.home, .gallery, .profiles].contains(item) { Divider().frame(width: 30).overlay(.white.opacity(0.3)) } }
                    }.padding(.vertical, 14).padding(.horizontal, 8)
                }.frame(width: 64).frame(maxHeight: 680).glassSurface(20)
                    .transition(.move(edge: .trailing)).padding(.vertical, 24)
                    .gesture(DragGesture().onEnded { if $0.translation.width > 10 { withAnimation { toolbarVisible = false } } })
            } else {
                Color.clear.frame(width: 25).contentShape(Rectangle()).accessibilityIdentifier("toolbarEdge")
                    .gesture(DragGesture().onEnded { if $0.translation.width < -10 { withAnimation { toolbarVisible = true } } })
                    .onTapGesture { withAnimation { toolbarVisible = true } }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .overlay(alignment: .top) {
                Color.clear.frame(height: 24).contentShape(Rectangle()).accessibilityIdentifier("tabsEdge")
                    .gesture(DragGesture().onEnded { if $0.translation.height > 25 { withAnimation { topTray = true } } })
            }
    }
    private var kioskControls: some View {
        VStack { Spacer(); HStack { Button("الحسابات") { model.logout(); panel = .profiles }; Spacer(); Button("الرئيسية") { model.open(model.profile.account?.homePage ?? "zeus://home") }; Button("رجوع") { model.webView?.goBack() } }.font(.caption).padding(12).background(.black) }
    }
    private var edgeReveal: some View {
        HStack { Spacer(); Button { model.chromeHidden = false } label: { Image(systemName: "chevron.left").font(.caption).padding(8).glassSurface(12) }.accessibilityLabel("إظهار الأشرطة") }.frame(maxHeight: .infinity, alignment: .center)
    }
    private var tabsTray: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { withAnimation { topTray = false } }
            VStack(spacing: 0) {
                Capsule().fill(.white.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 10).padding(.bottom, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 15) {
                        ForEach(model.tabs) { tab in
                            ZStack(alignment: .topTrailing) {
                                Button { model.selectTab(tab); withAnimation { topTray = false } } label: {
                                    VStack(spacing: 10) { Image(systemName: tab.isHome ? "house.fill" : "globe").font(.system(size: 32)).frame(width: 40, height: 40); Text(tab.title).font(.caption.bold()).lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 5) }.frame(width: 140, height: 180).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(model.selectedTabID == tab.id ? 1 : 0.2), lineWidth: 2))
                                }.contextMenu { Button("إضافة للمفضلة", systemImage: "star") { if model.profile.role != .guest && !tab.isHome { model.data.bookmarks.append(Bookmark(title: tab.title, url: tab.url)); model.persist() } } }
                                Button { model.closeTab(tab) } label: { Image(systemName: "xmark.circle.fill").padding(8) }
                            }.scaleEffect(model.selectedTabID == tab.id ? 1.05 : 1)
                        }
                        Button { _ = model.newTab(); withAnimation { topTray = false } } label: { Image(systemName: "plus").font(.system(size: 30)).frame(width: 140, height: 180).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5])).foregroundStyle(.white.opacity(0.3))) }
                    }.padding(.horizontal, 20)
                }.frame(height: 200)
                HStack { actionButton(.profiles); actionButton(.downloads); actionButton(.library); actionButton(.settings); actionButton(.tools) }.padding(.top, 10)
            }.frame(height: 300).frame(maxWidth: .infinity).background(.ultraThinMaterial).background(.black.opacity(0.8)).clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 30, bottomTrailingRadius: 30))

        }
    }
    @ViewBuilder private func actionButton(_ action: BrowserAction) -> some View {
        if action == .tools {
            Menu {
                ForEach(BrowserAction.allCases.filter { $0 != .tools }) { item in Button(item.title, systemImage: item.symbol) { perform(item) }.accessibilityIdentifier(item.identifier) }
                Button("أدوات الصفحة وحفظها", systemImage: "slider.horizontal.3") { panel = .tools }
            } label: { Image(systemName: action.symbol).font(.system(size: 19)).frame(width: 44, height: 40) }.accessibilityIdentifier(action.identifier).accessibilityLabel(action.title)
        } else { Button { perform(action) } label: { Group { if action == .profiles && showCurrentUserAvatar { AccountAvatar(profile: model.profile, store: model.profiles, size: 28) } else { Image(systemName: action.symbol).font(.system(size: 19)) } }.frame(width: 44, height: 40).overlay(alignment: .topTrailing) { if action == .tabs { Text("\(model.tabs.count)").font(.system(size: 9)).padding(2).background(.black, in: Circle()) } } }
            .buttonStyle(.plain).accessibilityLabel(action.title).accessibilityIdentifier(action.identifier)
            .disabled(action == .back && model.webView?.canGoBack != true || action == .forward && model.webView?.canGoForward != true)
    }
    }
    private func perform(_ action: BrowserAction) {
        withAnimation { toolbarVisible = false; topTray = false }
        switch action {
        case .back: model.webView?.goBack(); case .forward: model.webView?.goForward(); case .reload: model.reload(); case .home: model.home(); case .newTab: _ = model.newTab(); topTray = false
        case .tabs: if layout == .original { withAnimation { topTray.toggle() } } else { panel = .tabs }
        case .library: panel = .library; case .history: panel = .history
        case .reader: model.readerMode(); case .gallery: model.galleryMode()
        case .downloads: panel = .downloads; case .profiles: panel = .profiles; case .scripts: panel = .scripts; case .console: panel = .console
        case .shield: model.toggleCompatibility(); case .settings: panel = .settings; case .tools: panel = .tools
        case .saveForm: model.extractForm(); case .fillForm: panel = .forms
        case .bookmark: model.bookmarkCurrent(); case .pinTab: model.pinCurrent()
        case .twinHorizontal: model.toggleTwin(vertical: false); case .twinVertical: model.toggleTwin(vertical: true)
        case .savePage: model.saveWebArchive(); case .printPage: model.printPage()
        case .darkPage: var options = model.data.settings.advanced ?? AdvancedSettings(); options.forceDarkWebPages.toggle(); model.data.settings.advanced = options; model.applySettings()
        case .fullScreen: model.chromeHidden.toggle()
        case .share: if let url = model.webView?.url { model.share = ShareItem(url: url) }
        }
    }
    private var lockedView: some View {
        VStack(spacing: 24) { Image(systemName: "lock.shield").font(.system(size: 58)); Text("تسجيل الدخول").font(.title2); Button("اختيار الحساب") { panel = .profiles }.buttonStyle(.bordered) }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var restrictedPanel: some View { VStack(spacing: 20) { Image(systemName: "lock"); Text("هذه الأداة مقيدة لهذا الحساب"); Button("رجوع") { panel = nil } }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black) }
    @ViewBuilder private func panelContent(_ panel: BrowserPanel) -> some View {
        switch panel { case .forms: SavedFormsPage(model: model); case .tabs: TabsSheet(model: model); case .profiles: ProfilesSheet(model: model); case .downloads: DownloadsSheet(model: model); case .settings: if model.profile.account?.allowSettings != false { SettingsSheet(model: model) } else { restrictedPanel }; case .library: LibrarySheet(model: model); case .history: LibrarySheet(model: model, initialSection: 1); case .tools: ToolsSheet(model: model); case .scripts: if model.profile.account?.allowScripts != false { ScriptsSheet(model: model) } else { restrictedPanel }; case .console: if model.profile.account?.allowDeveloperTools != false { ConsoleSheet(model: model) } else { restrictedPanel } }
    }
}

struct OriginalHome: View {
    @ObservedObject var model: BrowserModel
    @State private var query = ""
    @State private var adding = false
    @State private var title = ""
    @State private var url = ""
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer().frame(height: 50)
                Image("ZEUS").resizable().scaledToFit().frame(width: 135, height: 135).accessibilityHidden(true)
                Text("ZEUS Browser").font(.system(size: 28, weight: .bold, design: .rounded)).tracking(2).padding(.top, 10).padding(.bottom, 40)
                HStack { Image(systemName: "magnifyingglass"); TextField("ابحث أو أدخل رابطاً", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.go).accessibilityIdentifier("homeSearchField").onSubmit { model.open(query) }; if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") } } }.padding(.horizontal, 20).frame(height: 55).glassSurface(28).padding(.horizontal, 20)
                if !query.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array((model.data.searches ?? []).filter { $0.localizedCaseInsensitiveHasPrefix(query) && $0 != query }.prefix(5)), id: \.self) { suggestion in
                            HStack { Button { query = suggestion; model.open(suggestion) } label: { HStack { Image(systemName: "clock"); Text(suggestion).lineLimit(1); Spacer() } }; Button { model.data.searches?.removeAll { $0 == suggestion }; model.persist() } label: { Image(systemName: "xmark").font(.caption) } }.padding(12)
                        }
                    }.padding(.horizontal, 20)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 25) {
                    ForEach(model.data.bookmarks) { item in
                        Button { model.open(item.url) } label: { VStack(spacing: 8) { Image(systemName: "globe").font(.system(size: 32)).frame(width: 60, height: 60).background(.white.opacity(0.08), in: Circle()); Text(item.title).font(.system(size: 12)).lineLimit(1).frame(width: 75) } }.buttonStyle(.plain).contextMenu { Button("حذف") { model.data.bookmarks.removeAll { $0.id == item.id }; model.persist() } }
                    }
                    Button { adding = true } label: { VStack(spacing: 8) { Image(systemName: "plus").font(.title2).frame(width: 60, height: 60).overlay(Circle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))); Text("إضافة").font(.system(size: 12)).frame(width: 75) } }.buttonStyle(.plain).disabled([.guest, .kiosk].contains(model.profile.role))
                }.padding(.horizontal, 15).padding(.top, 35)
                Spacer().frame(height: 50)
            }
        }.background(.black).foregroundStyle(.white)
            .fullScreenCover(isPresented: $adding) {
                NavigationStack { Form { TextField("الاسم", text: $title); TextField("الرابط", text: $url).keyboardType(.URL).textInputAutocapitalization(.never) }.scrollContentBackground(.hidden).background(.black).navigationTitle("إضافة موقع").toolbar { ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { adding = false } }; ToolbarItem(placement: .confirmationAction) { Button("حفظ") { if let address = BrowserURL.resolve(url, provider: model.data.settings.searchProvider), BrowserURL.isWeb(address) { model.data.bookmarks.append(Bookmark(title: title.isEmpty ? address.host ?? url : title, url: address.absoluteString)); model.persist(); adding = false } } } } }.tint(.white).preferredColorScheme(.dark)
            }
    }
}
