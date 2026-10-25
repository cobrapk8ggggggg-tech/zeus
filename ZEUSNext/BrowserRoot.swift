import SwiftUI
import WebKit
import Combine

enum BrowserPanel: String, Identifiable { case translation, tabs, profiles, account, downloads, settings, library, history, tools, scripts, console, forms; var id: String { rawValue } }
enum BrowserAction: String, CaseIterable, Identifiable {
    case assistant, translate, back, forward, reload, home, newTab, tabs, library, history, reader, gallery, downloads, profiles, scripts, console, shield, share, settings, tools, bookmark, pinTab, twinHorizontal, twinVertical, savePage, printPage, darkPage, fullScreen, saveForm, fillForm
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .assistant: return "sparkles"
        case .translate: return "translate"
        case .saveForm: return "plus.rectangle.on.rectangle"; case .fillForm: return "square.and.pencil"
        case .bookmark: return "bookmark.badge.plus"; case .pinTab: return "pin"; case .twinHorizontal: return "rectangle.split.2x1"; case .twinVertical: return "rectangle.split.1x2"; case .savePage: return "doc"; case .printPage: return "printer"; case .darkPage: return "moon"; case .fullScreen: return "arrow.up.left.and.arrow.down.right"
        case .back: return "chevron.backward"; case .forward: return "chevron.forward"; case .reload: return "arrow.clockwise"; case .home: return "house.fill"; case .newTab: return "plus"; case .tabs: return "square.on.square"; case .library: return "globe"; case .history: return "clock.arrow.circlepath"; case .reader: return "doc.plaintext"; case .gallery: return "photo.on.rectangle"; case .downloads: return "arrow.down.circle"; case .profiles: return "person.crop.circle"; case .scripts: return "curlybraces"; case .console: return "terminal"; case .shield: return "shield"; case .share: return "square.and.arrow.up"; case .settings: return "gearshape"; case .tools: return "ellipsis.circle"
        }
    }
    var title: String {
        switch self {
        case .assistant: return "وكيل ZEUS"
        case .translate: return "ترجمة الصفحة"
        case .saveForm: return "حفظ النموذج"; case .fillForm: return "ملء النماذج"
        case .bookmark: return "إضافة للمفضلة"; case .pinTab: return "تثبيت التبويب"; case .twinHorizontal: return "متصفح مزدوج أفقي"; case .twinVertical: return "متصفح مزدوج عمودي"; case .savePage: return "حفظ الصفحة"; case .printPage: return "طباعة"; case .darkPage: return "تعتيم الصفحة"; case .fullScreen: return "إخفاء الأشرطة"
        case .back: return "رجوع"; case .forward: return "تقدم"; case .reload: return "تحديث"; case .home: return "الرئيسية"; case .newTab: return "تبويب جديد"; case .tabs: return "التبويبات"; case .library: return "المواقع"; case .history: return "السجل"; case .reader: return "القارئ"; case .gallery: return "معرض الصور"; case .downloads: return "التنزيلات"; case .profiles: return "البروفايلات"; case .scripts: return "السكربتات"; case .console: return "أدوات المطور"; case .shield: return "حماية الموقع"; case .share: return "مشاركة"; case .settings: return "الإعدادات"; case .tools: return "أدوات الصفحة"
        }
    }
    var identifier: String { rawValue + "Button" }
}

struct BrowserRoot: View {
    @ObservedObject var model: BrowserModel
    #if ZEUS_NATIVE_HOST
    var nativeAssistant: NativeAssistantFactory? = nil
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("showCurrentUserAvatar") private var showCurrentUserAvatar = false
    @AppStorage("zeus.assistant.dockRight") private var assistantOnRight = false
    @State private var panel: BrowserPanel?
    @State private var profilePicker = false
    @State private var toolbarVisible = false
    @State private var topTray = false
    @State private var draft = ""
    @State private var dialogText = ""
    @State private var assistantVisible = false
    @State private var assistantExpanded = false
    @FocusState private var addressFocused: Bool
    private var layout: ChromeLayout { model.data.settings.chromeLayout ?? .original }
    private var customDesign: ChromeDesign? { model.data.settings.chromeWorkspace?.active(for: layout) }
    private var theme: BrowserTheme { model.data.settings.theme ?? .standard }
    private var barsVisible: Bool { !(layout == .icab && model.chromeManuallyHidden) && (!model.chromeHidden || addressFocused || model.current?.isHome != false) }
    var body: some View {
        ZStack {
            theme.backgroundColor.ignoresSafeArea()
            if model.requiresUnlock { lockedView }
            else {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        if assistantVisible, sizeClass == .regular, !assistantExpanded, !assistantOnRight, let agent = model.agent {
                            assistant(agent, fullScreen: false)
                                .frame(width: max(300, min(420, geometry.size.width * 0.29)))
                            Divider().overlay(.white.opacity(0.15))
                        }
                        browsingSurface
                        if assistantVisible, sizeClass == .regular, !assistantExpanded, assistantOnRight, let agent = model.agent {
                            Divider().overlay(.white.opacity(0.15))
                            assistant(agent, fullScreen: false)
                                .frame(width: max(300, min(420, geometry.size.width * 0.29)))
                        }
                    }.environment(\.layoutDirection, .leftToRight)
                }
            }
            if scenePhase != .active { theme.backgroundColor.ignoresSafeArea().overlay(Image(systemName: "lock").font(.largeTitle)).accessibilityHidden(true) }
        }
        .foregroundStyle(theme.textColor).tint(theme.accentColor).background(theme.backgroundColor)
        .statusBarHidden(layout == .original)
        .ignoresSafeArea(.container, edges: layout == .original ? .all : [])
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.chromeHidden)
        .fullScreenCover(isPresented: assistantCover) { if let agent = model.agent { assistant(agent, fullScreen: true) } }
        .fullScreenCover(item: $panel) { item in panelContent(item).browserTheme(theme).environment(\.layoutDirection, .rightToLeft) }
        .overlay { if profilePicker { ProfilePickerPopover(model: model, close: { profilePicker = false }, manage: { profilePicker = false; panel = .profiles }).browserTheme(theme) } }
        .overlay(alignment: .top) { if model.current?.loading == true { ProgressView(value: max(0.05, model.current?.progress ?? 0)).progressViewStyle(.linear).tint(theme.accentColor).frame(height: 2).allowsHitTesting(false) } }
        .overlay(alignment: .top) { if !model.requiresUnlock, let page = model.current?.translation { TranslationCard(page: page, settings: { panel = .translation }).id(model.current?.id).animation(.spring(response: 0.45, dampingFraction: 0.82), value: page.offered) } }
        .browserTheme(theme)
        .onChange(of: model.current?.id) { _, _ in model.current?.translation?.becameVisible() }
        .fullScreenCover(item: $model.article) { ReaderSheet(model: model, article: $0).tint(theme.buttonTextColor) }
        .fullScreenCover(item: $model.gallery) { GallerySheet(model: model, gallery: $0).tint(theme.buttonTextColor) }
        .fullScreenCover(item: $model.formDraft) { FormDraftView(model: model, draft: $0) }
        .sheet(item: $model.share) { ActivitySheet(url: $0.url) }
        .onChange(of: model.dialog?.id) { _, _ in if let dialog = model.dialog { model.dialog = nil; BrowserPresentation.present(dialog) } }
        .onChange(of: model.notice?.id) { _, _ in if let notice = model.notice { model.notice = nil; BrowserPresentation.notice(notice.text) } }
        .onChange(of: model.requiresUnlock) { _, locked in if locked { assistantVisible = false; model.agent?.cancel(); model.agent = nil; profilePicker = false; panel = nil; model.article = nil; model.gallery = nil; model.formDraft = nil; model.share = nil; BrowserPresentation.dismissTools() } }
        .onChange(of: model.address) { _, value in if !addressFocused { draft = value } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.backgrounded() }; if phase == .active { model.becameActive() } }
        .onReceive(model.profiles.$activeID.dropFirst()) { _ in assistantVisible = false; model.agent?.cancel(); model.agent = nil; profilePicker = false; panel = nil; model.article = nil; model.gallery = nil; model.formDraft = nil; model.share = nil; BrowserPresentation.dismissTools() }
        .onReceive(model.profiles.objectWillChange) { model.changed() }
        .onReceive(model.downloads.objectWillChange) { model.changed() }
        .onReceive(model.downloads.$message) { if let text = $0 { model.downloads.message = nil; model.notify(text) } }
        .onReceive(model.profiles.$errorMessage) { if let text = $0 { model.profiles.errorMessage = nil; model.notify(text) } }
        .task {
            draft = model.address
            await model.ensureCurrentLoaded()
            #if DEBUG && ZEUS_NATIVE_HOST
            if CommandLine.arguments.contains("--open-native-agent"), !assistantVisible { perform(.assistant) }
            #endif
        }
    }
    @ViewBuilder private var browsingSurface: some View {
        if let customDesign, model.profile.role != .kiosk {
            GeometryReader { geometry in
                let composition = customDesign.composition(wide: geometry.size.width > geometry.size.height)
                ZStack {
                    browserContent
                        .padding(.top, barsVisible ? geometry.size.height * composition.topInset : 0)
                        .padding(.bottom, barsVisible ? geometry.size.height * composition.bottomInset : 0)
                    if barsVisible { ChromeRuntimeLayer(model: model, composition: composition, perform: perform) }
                    if !barsVisible { edgeReveal }
                    VStack { Spacer(); HStack { Spacer();
                        Menu {
                            Button("إعدادات الواجهة", systemImage: "slider.horizontal.3") { panel = .settings }
                            Button("العودة للتوزيع الافتراضي", systemImage: "arrow.uturn.backward") {
                                model.data.settings.chromeWorkspace?.selected = nil
                                model.data.settings.chromeWorkspace?.designs.removeAll { $0.base == layout }
                                model.chromeHidden = false; model.chromeManuallyHidden = false; model.persist()
                            }
                        } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 13)).frame(width: 36, height: 36).background(.regularMaterial, in: Circle()) }
                        .accessibilityLabel("إدارة التوزيع واستعادته").padding(8)
                    } }
                }
            }
        } else { standardBrowsingSurface }
    }
    private var standardBrowsingSurface: some View {
        ZStack {
                VStack(spacing: 0) {
                    if model.profile.role != .kiosk && layout != .original && barsVisible { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
                    browserContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.profile.role != .kiosk && layout == .dualBars && barsVisible { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
                }
                if model.profile.role == .kiosk { kioskControls }
                else if layout == .original { originalControls.environment(\.layoutDirection, .leftToRight) }
                else if !barsVisible { edgeReveal }
                if showCurrentUserAvatar && layout == .original && !toolbarVisible && model.profile.role != .kiosk {
                    VStack { HStack { Spacer(); actionButton(.profiles).glassSurface(18) }; Spacer() }.padding(.top, 35).padding(.trailing, 12).environment(\.layoutDirection, .leftToRight)
                }
                if topTray { tabsTray.transition(.move(edge: .top)).zIndex(10) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var assistantCover: Binding<Bool> {
        Binding(get: { assistantVisible && (sizeClass != .regular || assistantExpanded) }, set: { visible in
            if !visible { if sizeClass == .regular { assistantExpanded = false } else { assistantVisible = false } }
        })
    }
    @ViewBuilder private func assistant(_ agent: BrowserAgent, fullScreen: Bool) -> some View {
        #if ZEUS_NATIVE_HOST
        if let nativeAssistant {
            nativeAssistant(agent, NativeAssistantPresentation(fullScreen: fullScreen, canResize: sizeClass == .regular,
                close: { withAnimation { assistantVisible = false; assistantExpanded = false } },
                resize: { assistantExpanded.toggle() }))
        }
        #else
        AIChatView(vm: agent, fullScreen: fullScreen, canResize: sizeClass == .regular,
                   close: { withAnimation { assistantVisible = false; assistantExpanded = false } },
                   resize: { assistantExpanded.toggle() }).id(model.profile.id)
        #endif
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
                    actionButton(.back); actionButton(.forward); addressBar; actionButton(.assistant); actionButton(.profiles)
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
                    RememberedTabScroll(model: model, key: "icab") {
                        HStack(spacing: 1) {
                            BrowserTabCollection(model: model, compact: true)
                            actionButton(.newTab)
                        }
                    }
                }
            } else { HStack { actionButton(.profiles); Spacer(); Text(model.profile.name).font(.subheadline); Spacer(); actionButton(.assistant); Button { panel = .account } label: { Image(systemName: "gearshape").font(.system(size: 19)).foregroundStyle(theme.iconColor).frame(width: 44, height: 40).background(theme.buttonBackgroundColor, in: RoundedRectangle(cornerRadius: theme.radius(12))) }.buttonStyle(.plain).accessibilityIdentifier("accountSettingsButton").accessibilityLabel("إعدادات البروفايل") } }
            if model.current?.loading == true { ProgressView(value: model.current?.progress ?? 0).tint(theme.buttonTextColor).frame(height: 2) }
        }.padding(.horizontal, layout == .icab ? 4 : 12).padding(.vertical, 5).background(theme.backgroundColor).environment(\.layoutDirection, .leftToRight)
    }
    private var bottomBar: some View {
        VStack(spacing: 4) {
            if model.pendingPopup != nil { HStack { Text("حُظرت نافذة منبثقة").font(.caption); Spacer(); Button("فتح مرة") { model.allowPendingPopup() }; Button("إخفاء") { model.pendingPopup = nil } }.font(.caption).padding(10) }
            if layout == .dualBars { addressBar }
            HStack {
                ForEach(layout == .icab ? [BrowserAction.library, .downloads, .profiles, .tabs, .settings, .tools] : [.back, .forward, .library, .downloads, .tabs, .tools]) { item in actionButton(item).frame(maxWidth: .infinity) }
            }
        }.padding(.horizontal, 12).padding(.bottom, 3).background(theme.backgroundColor)
    }
    private var originalControls: some View {
        ZStack(alignment: .trailing) {
            if toolbarVisible {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 9) {
                        ForEach([BrowserAction.assistant, .back, .forward, .reload, .home, .newTab, .library, .history, .reader, .gallery, .console, .scripts, .darkPage, .tools]) { item in actionButton(item); if [.home, .gallery, .profiles].contains(item) { Divider().frame(width: 30).overlay(theme.textColor.opacity(0.3)) } }
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
        VStack { Spacer(); HStack { Button("الحسابات") { model.logout(); panel = .profiles }; Spacer(); Button("الرئيسية") { model.open(model.profile.account?.homePage ?? "zeus://home") }; Button("رجوع") { model.webView?.goBack() } }.font(.caption).padding(12).background(theme.backgroundColor) }
    }
    private var edgeReveal: some View {
        HStack { Spacer(); Button { model.chromeManuallyHidden = false; model.chromeHidden = false } label: { Image(systemName: "chevron.left").font(.caption).padding(8).glassSurface(12) }.accessibilityLabel("إظهار الأشرطة") }.frame(maxHeight: .infinity, alignment: .center).environment(\.layoutDirection, .leftToRight)
    }
    private var tabsTray: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { withAnimation { topTray = false } }
            VStack(spacing: 0) {
                Capsule().fill(theme.textColor.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 10).padding(.bottom, 20)
                RememberedTabScroll(model: model, key: "original") {
                    HStack(spacing: 15) {
                        BrowserTabCollection(model: model, selected: { withAnimation { topTray = false } })
                        Button { _ = model.newTab(); withAnimation { topTray = false } } label: { Image(systemName: "plus").font(.system(size: 30)).frame(width: 140, height: 180).background(theme.textColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5])).foregroundStyle(theme.textColor.opacity(0.3))) }
                    }.padding(.horizontal, 20)
                }.frame(height: 200)
                Spacer()
            }.accessibilityElement(children: .contain).accessibilityIdentifier("originalTabsTray").frame(height: 300).frame(maxWidth: .infinity).background { if theme.style == .glass { Rectangle().fill(.ultraThinMaterial) } else { theme.surfaceColor } }.clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 30, bottomTrailingRadius: 30))

        }
    }
    @ViewBuilder private func actionButton(_ action: BrowserAction) -> some View {
        if action == .tools {
            Menu {
                ForEach(BrowserActionGroup.allCases) { group in
                    Menu { ForEach(group.actions) { item in Button(item.title, systemImage: item.symbol) { perform(item) }.accessibilityIdentifier("menu-" + item.identifier) } } label: { Label(group.title, systemImage: group.symbol) }.accessibilityIdentifier("group-" + group.rawValue)
                }
                Menu("الحفظ والتصدير", systemImage: "square.and.arrow.up") { Button("خيارات اللقطات وPDF والقراءة") { panel = .tools } }
            } label: { Image(systemName: action.symbol).font(.system(size: 19)).foregroundStyle(theme.iconColor).frame(width: 44, height: 40).background(theme.buttonBackgroundColor, in: RoundedRectangle(cornerRadius: theme.radius(12))) }.accessibilityIdentifier(action.identifier).accessibilityLabel(action.title)
        } else { Button { perform(action) } label: { Group { if action == .profiles { AccountAvatar(profile: model.profile, store: model.profiles, size: 28) } else { Image(systemName: action.symbol).font(.system(size: 19)) } }.foregroundStyle(theme.iconColor).frame(width: 44, height: 40).background(theme.buttonBackgroundColor, in: RoundedRectangle(cornerRadius: theme.radius(12))).overlay(alignment: .topTrailing) { if action == .tabs { Text("\(model.tabs.count)").font(.system(size: 9)).padding(2).background(theme.backgroundColor, in: Circle()) } } }
            .buttonStyle(.plain).accessibilityLabel(action.title).accessibilityIdentifier(action.identifier)
            .disabled(action == .back && model.webView?.canGoBack != true || action == .forward && model.webView?.canGoForward != true)
    }
    }
    private func perform(_ action: BrowserAction) {
        addressFocused = false
        withAnimation { toolbarVisible = false; topTray = false }
        switch action {
        case .assistant:
            #if ZEUS_NATIVE_HOST
            guard nativeAssistant != nil else { return }
            #endif
            if model.agent == nil { model.agent = BrowserAgent(browser: model) }
            #if ZEUS_NATIVE_HOST
            model.agent?.interfaceAction = { action in
                let owner = model.profile.id
                // Dismiss the existing cover before presenting the original
                // reader/gallery/settings UI through its normal button handler.
                assistantVisible = false
                try await Task.sleep(for: .milliseconds(450))
                guard model.profile.id == owner, !model.requiresUnlock else { throw AccountError.permission }
                perform(action)
            }
            #endif
            assistantVisible = true
        case .translate: model.current?.translation?.translate()
        case .back: model.webView?.goBack(); case .forward: model.webView?.goForward(); case .reload: model.reload(); case .home: model.home(); case .newTab: _ = model.newTab(); topTray = false
        case .tabs: if layout == .original && customDesign == nil { withAnimation { topTray.toggle() } } else { panel = .tabs }
        case .library: panel = .library; case .history: panel = .history
        case .reader: model.readerMode(); case .gallery: model.galleryMode()
        case .downloads: panel = .downloads; case .profiles: profilePicker = true; case .scripts: panel = .scripts; case .console: panel = .console
        case .shield: model.toggleCompatibility(); case .settings: panel = .settings; case .tools: panel = .tools
        case .saveForm: model.extractForm(); case .fillForm: panel = .forms
        case .bookmark: model.bookmarkCurrent(); case .pinTab: model.pinCurrent()
        case .twinHorizontal: model.toggleTwin(vertical: false); case .twinVertical: model.toggleTwin(vertical: true)
        case .savePage: model.saveWebArchive(); case .printPage: model.printPage()
        case .darkPage: var options = model.data.settings.advanced ?? AdvancedSettings(); options.forceDarkWebPages.toggle(); model.data.settings.advanced = options; model.applySettings()
        case .fullScreen: model.chromeHidden.toggle(); if layout == .icab { model.chromeManuallyHidden = model.chromeHidden }
        case .share: if let url = model.webView?.url { model.share = ShareItem(url: url) }
        }
    }
    private var lockedView: some View {
        VStack(spacing: 24) { Image(systemName: "lock.shield").font(.system(size: 58)); Text("تسجيل الدخول").font(.title2); Button("اختيار الحساب") { profilePicker = true }.buttonStyle(.bordered) }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var restrictedPanel: some View { VStack(spacing: 20) { Image(systemName: "lock"); Text("هذه الأداة مقيدة لهذا الحساب"); Button("رجوع") { panel = nil } }.frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.backgroundColor) }
    @ViewBuilder private func panelContent(_ panel: BrowserPanel) -> some View {
        switch panel { case .translation: if model.profile.account?.allowSettings != false || model.profile.isAdmin { TranslationSettingsSheet(model: model) } else { restrictedPanel }; case .forms: SavedFormsPage(model: model); case .tabs: TabsSheet(model: model); case .account: SettingsSheet(model: model, profile: model.profile); case .profiles: ProfilesSheet(model: model); case .downloads: DownloadsSheet(model: model); case .settings: if model.profile.account?.allowSettings != false { SettingsSheet(model: model) } else { restrictedPanel }; case .library: LibrarySheet(model: model); case .history: LibrarySheet(model: model, initialSection: 1); case .tools: ToolsSheet(model: model); case .scripts: if model.profile.account?.allowScripts != false { ScriptsSheet(model: model) } else { restrictedPanel }; case .console: if model.profile.account?.allowDeveloperTools != false { ConsoleSheet(model: model) } else { restrictedPanel } }
    }
}
