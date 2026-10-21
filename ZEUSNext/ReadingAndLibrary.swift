import SwiftUI
import WebKit
import ImageIO

struct LibrarySheet: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var section = 0
    @State private var search = ""
    init(model: BrowserModel, initialSection: Int = 0) { self.model = model; _section = State(initialValue: initialSection) }
    var body: some View {
        NavigationStack {
            List {
                Picker("المكتبة", selection: $section) { Text("المفضلة").tag(0); Text("السجل").tag(1) }.pickerStyle(.segmented).listRowBackground(Color.clear)
                if section == 0 {
                    if model.data.bookmarks.isEmpty { ContentUnavailableView("صفحات تستحق العودة", systemImage: "bookmark", description: Text("أضف صفحة من صندوق الأدوات؛ تُحفظ في هذه المساحة فقط.")) }
                    ForEach(model.data.bookmarks.filter { matches($0.title, $0.url) }) { item in
                        Button { model.open(item.url); dismiss() } label: { libraryRow(item.title, url: item.url, symbol: "bookmark.fill") }.buttonStyle(.plain)
                            .contextMenu { Button("حذف") { model.data.bookmarks.removeAll { $0.id == item.id }; model.persist() } }
                    }
                } else {
                    if model.data.history.isEmpty { ContentUnavailableView("بداية نظيفة", systemImage: "clock", description: Text(model.profile.isPrivate ? "لا يُحفظ سجل في هذه المساحة الخاصة." : "ستظهر زياراتك هنا.")) }
                    ForEach(model.data.history.filter { matches($0.title, $0.url) }) { item in
                        Button { model.open(item.url); dismiss() } label: {
                            VStack(alignment: .leading, spacing: 6) { libraryRow(item.title, url: item.url, symbol: "clock"); Text(item.date, style: .date).font(.caption2).foregroundStyle(.tertiary) }
                        }.buttonStyle(.plain).contextMenu { Button("حذف الزيارة") { model.data.history.removeAll { $0.id == item.id }; model.persist() } }
                    }
                }
            }.scrollContentBackground(.hidden).background { OrbitBackground(tint: theme.accentColor) }.navigationTitle("مكتبة المساحة").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "بحث في العناوين والروابط")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("تم") { dismiss() } } }
        }
    }
    private func matches(_ title: String, _ url: String) -> Bool { search.isEmpty || title.localizedCaseInsensitiveContains(search) || url.localizedCaseInsensitiveContains(search) }
    private func libraryRow(_ title: String, url: String, symbol: String) -> some View {
        HStack(spacing: 13) { Image(systemName: symbol).foregroundStyle(theme.accentColor).frame(width: 26); VStack(alignment: .leading, spacing: 5) { Text(title).font(.subheadline.weight(.medium)).lineLimit(2); Text(url).font(.caption).foregroundStyle(theme.secondaryTextColor).lineLimit(1).environment(\.layoutDirection, .leftToRight) } }.padding(.vertical, 5)
    }
}

struct ReaderSheet: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var model: BrowserModel
    let article: ReaderArticle
    @Environment(\.dismiss) private var dismiss
    @StateObject private var translation = ReaderTranslation()
    @State private var settings = false
    @State private var controls = true
    @State private var anchor: CGFloat = 0
    @State private var forbidden = ""
    @State private var copied = false
    @State private var viewportHeight: CGFloat = 800
    private var prefs: ReadingPreferences { model.data.settings.reading ?? ReadingPreferences() }
    private var rows: [(offset: Int, element: String)] { Array((translation.paragraphs ?? article.paragraphs).enumerated()).filter { row in !prefs.blockedWords.contains { row.element.localizedCaseInsensitiveContains($0) } } }
    private var paragraphs: [String] { rows.map(\.element) }
    var body: some View {
        ZStack(alignment: .top) {
            theme.backgroundColor.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .trailing, spacing: 25) {
                    Spacer().frame(height: 65)
                    Text(translation.title ?? article.title).onGeometryChange(for: CGRect.self) { $0.frame(in: .named("readerViewport")) } action: { translation.observe(index: 0, rect: $0, height: viewportHeight) }.font(.system(size: prefs.fontSize + 6, weight: .bold, design: .serif)).multilineTextAlignment(.center).frame(maxWidth: .infinity).textSelection(.enabled)
                    if translation.suggested { HStack { Text("هل تريد ترجمة هذا الفصل؟"); Button("ترجمة") { translation.translate(article: article, model: model) }; Button("إخفاء") { translation.suggested = false } }.font(.subheadline).padding(12).glassSurface(16).environment(\.layoutDirection, .rightToLeft) }
                    if translation.running { HStack { ProgressView(); Text("جارٍ الترجمة · \(translation.completed) مقطع"); Button("إيقاف") { translation.cancel() } }.font(.caption) }
                    if let error = translation.error { Text(error).font(.footnote).textSelection(.enabled) }
                    if let notice = translation.storageNotice { Text(notice).font(.footnote) }
                    Divider().overlay(theme.textColor.opacity(0.3))
                    ForEach(rows, id: \.offset) { index, paragraph in
                        let rtl = translation.isTranslated(index + 1) ? TranslationPreferences.rtl(translation.targetLanguage) : TranslationPreferences.rtl(PageTranslation.detect(sample: article.paragraphs[index], hint: ""))
                        Text(paragraph).font(.system(size: prefs.fontSize, design: .serif)).opacity(prefs.textOpacity).lineSpacing(10).multilineTextAlignment(rtl ? .trailing : .leading).frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading).environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight).textSelection(.enabled)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("readerViewport")) } action: { translation.observe(index: index + 1, rect: $0, height: viewportHeight) }
                    }
                }.padding(25).padding(.bottom, 60)
            }.coordinateSpace(name: "readerViewport").onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, value in
                if value < 10 { controls = true; anchor = value }
                else if abs(value - anchor) > 18 { withAnimation { controls = value < anchor }; anchor = value }
            }
            if controls {
                HStack {
                    Button { settings = true } label: { Image(systemName: "slider.horizontal.3").padding(12) }
                    Button { UIPasteboard.general.string = (translation.title ?? article.title) + "\n\n" + paragraphs.joined(separator: "\n\n"); copied = true } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").padding(12) }
                    Menu { Button("ترجمة الفصل") { translation.translate(article: article, model: model) }; Button("عرض الأصل") { translation.restore() }; if translation.running { Button("إيقاف الترجمة") { translation.cancel() } } } label: { Image(systemName: "translate").padding(12) }.accessibilityIdentifier("readerTranslateButton")
                    Spacer(); Text("وضع القراءة").font(.subheadline); Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").padding(12) }.accessibilityIdentifier("closeReaderButton")
                }.padding(.horizontal, 12).background(theme.backgroundColor).transition(.move(edge: .top).combined(with: .opacity))
            }
            rightReveal.environment(\.layoutDirection, .leftToRight)
        }.foregroundStyle(theme.textColor).tint(theme.buttonTextColor).statusBarHidden().environment(\.layoutDirection, .leftToRight)
            .task { translation.prepare(article: article, model: model) }.onDisappear { translation.cancel() }
            .fullScreenCover(isPresented: $settings) {
                NavigationStack { Form {
                    ThemedSection("النص") { Text("حجم الخط \(Int(prefs.fontSize))"); Slider(value: preference(\.fontSize), in: 14...40, step: 1); Text("شفافية النص"); Slider(value: preference(\.textOpacity), in: 0.1...1) }
                    ThemedSection("القائمة السوداء") { HStack { TextField("كلمة أو جملة لحظرها", text: $forbidden); Button("إضافة") { let text = forbidden.trimmingCharacters(in: .whitespacesAndNewlines); if !text.isEmpty { var p = prefs; if !p.blockedWords.contains(text) { p.blockedWords.append(text) }; model.data.settings.reading = p; model.persist(); forbidden = "" } } }; ForEach(prefs.blockedWords, id: \.self) { word in HStack { Text(word); Spacer(); Button { var p = prefs; p.blockedWords.removeAll { $0 == word }; model.data.settings.reading = p; model.persist() } label: { Image(systemName: "xmark.circle") } } } }
                }.scrollContentBackground(.hidden).background(theme.backgroundColor).navigationTitle("إعدادات القارئ").toolbar { Button("تم") { settings = false } } }.tint(theme.buttonTextColor).preferredColorScheme(theme.light ? .light : .dark)
            }
    }
    private var readerRTL: Bool { if translation.paragraphs != nil { return TranslationPreferences.rtl((model.data.settings.translation ?? TranslationPreferences()).target) }; return TranslationPreferences.rtl(PageTranslation.detect(sample: article.paragraphs.prefix(4).joined(), hint: "")) }
    private var rightReveal: some View {
        HStack { Spacer(); Color.clear.frame(width: 24).contentShape(Rectangle()).gesture(DragGesture().onEnded { if $0.translation.width < -10 { withAnimation { controls = true } }; if $0.translation.width > 10 { withAnimation { controls = false } } }) }.frame(maxHeight: .infinity)
    }
    private func preference(_ key: WritableKeyPath<ReadingPreferences, Double>) -> Binding<Double> { Binding(get: { prefs[keyPath: key] }, set: { var value = prefs; value[keyPath: key] = $0; model.data.settings.reading = value; model.persist() }) }
}

struct GallerySheet: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var model: BrowserModel
    let gallery: GalleryArticle
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var photoProgress = ""
    @State private var photoMessage: String?
    @State private var selection: Set<String> = []
    @State private var selecting = false
    @State private var selectedIndex: Int?
    @State private var settings = false
    @State private var controls = true
    @State private var anchor: CGFloat = 0
    @State private var scrollView: UIScrollView?
    private var prefs: ReadingPreferences { model.data.settings.reading ?? ReadingPreferences() }
    var body: some View {
        ZStack {
            theme.backgroundColor.ignoresSafeArea()
            VStack(spacing: 0) {
                galleryHeader
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                        ForEach(Array(gallery.images.enumerated()), id: \.offset) { index, address in
                            ProfileThumbnail(address: address, store: model.profiles.websiteDataStore(for: model.profile), source: model.webView)
                                .frame(height: 130).clipped().contentShape(Rectangle())
                                .overlay(alignment: .topTrailing) { if selecting { Image(systemName: selection.contains(address) ? "checkmark.circle.fill" : "circle").font(.title2).padding(8).allowsHitTesting(false) } }
                                .onTapGesture { if selecting { toggle(address) } else { selectedIndex = index; controls = false } }
                                .onLongPressGesture { selecting = true; toggle(address) }
                        }
                    }.padding(.horizontal, 2)
                }
                if selecting { HStack { Text(saving ? photoProgress : "\(selection.count) صورة"); Spacer(); Menu("حفظ المحدد", systemImage: "arrow.down.circle") { Button("حفظ في ألبوم الصور") { saveToPhotos() }; Button("تنزيل إلى ملفات المتصفح") { downloadSelection() } }.disabled(selection.isEmpty || saving) }.padding(16).background(theme.backgroundColor) }
            }
            if let index = selectedIndex { imageReader(start: index).transition(.move(edge: .bottom)) }
        }.foregroundStyle(theme.textColor).tint(theme.buttonTextColor).statusBarHidden(selectedIndex != nil).environment(\.layoutDirection, .leftToRight)
            .alert("حفظ الصور", isPresented: Binding(get: { photoMessage != nil }, set: { if !$0 { photoMessage = nil } })) { Button("حسنًا") { photoMessage = nil } } message: { Text(photoMessage ?? "") }
            .fullScreenCover(isPresented: $settings) {
                NavigationStack { Form {
                    ThemedSection("وضع قراءة الصور") { Text("عرض الصورة \(Int(prefs.imageScale * 100))٪"); Slider(value: preference(\.imageScale), in: 0.2...1, step: 0.05); Text("مسافة التمرير \(Int(prefs.scrollDistance)) نقطة"); Slider(value: preference(\.scrollDistance), in: 100...1000, step: 50) }
                    Text("انقر النصف العلوي للرجوع أو السفلي للتقدم. اسحب من اليمين لإظهار أدوات القراءة.").font(.footnote)
                }.scrollContentBackground(.hidden).background(theme.backgroundColor).navigationTitle("إعدادات العرض").toolbar { Button("تم") { settings = false } } }.tint(theme.buttonTextColor).preferredColorScheme(theme.light ? .light : .dark)
            }
    }
    private var galleryHeader: some View {
        HStack {
            if selecting {
                Button("إلغاء") { selecting = false; selection.removeAll() }; Spacer()
                Button(selection.count == gallery.images.count ? "إلغاء الكل" : "تحديد الكل") { selection = selection.count == gallery.images.count ? [] : Set(gallery.images) }
            } else {
                Button { settings = true } label: { Image(systemName: "gearshape.fill") }; Spacer(); Text("\(gallery.images.count) صور").font(.headline).accessibilityIdentifier("galleryCount"); Spacer()
                Button { selecting = true } label: { Image(systemName: "checkmark.circle") }
                Button { dismiss() } label: { Image(systemName: "xmark") }.padding(.leading, 12).accessibilityIdentifier("closeGalleryButton")
            }
        }.padding(18).background(theme.backgroundColor)
    }
    private func imageReader(start: Int) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                theme.backgroundColor.ignoresSafeArea()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(gallery.images.enumerated()), id: \.offset) { i, address in
                                ProfileThumbnail(address: address, store: model.profiles.websiteDataStore(for: model.profile), source: model.webView, fit: true)
                                    .frame(width: geometry.size.width * prefs.imageScale).frame(maxWidth: .infinity).id(i)
                            }
                        }.background(ScrollViewAccessor(scrollView: $scrollView))
                    }.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, value in if abs(value-anchor) > 18 { withAnimation { controls = value < anchor }; anchor = value } }
                        .simultaneousGesture(SpatialTapGesture().onEnded { point in scroll(point.location.y < geometry.size.height/2 ? -1 : 1) })
                        .onAppear { proxy.scrollTo(start, anchor: .top) }
                }
                if controls {
                    VStack(spacing: 16) {
                        Button { selectedIndex = nil } label: { Image(systemName: "xmark") }
                        Button { settings = true } label: { Image(systemName: "slider.horizontal.3") }
                        Button { scroll(-1) } label: { Image(systemName: "chevron.up") }
                        Button { scroll(1) } label: { Image(systemName: "chevron.down") }
                    }.font(.title3).padding(18).glassSurface(20).transition(.move(edge: .trailing))
                        .gesture(DragGesture().onEnded { if $0.translation.width > 10 { withAnimation { controls = false } } })
                } else {
                    Color.clear.frame(width: 25).contentShape(Rectangle()).gesture(DragGesture().onEnded { if $0.translation.width < -10 { withAnimation { controls = true } } })
                }
            }
        }.background(theme.backgroundColor).environment(\.layoutDirection, .leftToRight)
    }
    private func scroll(_ direction: CGFloat) { guard let view = scrollView else { return }; let value = min(max(0, view.contentOffset.y + direction * prefs.scrollDistance), max(0, view.contentSize.height-view.bounds.height)); view.setContentOffset(CGPoint(x: 0, y: value), animated: true) }
    private func toggle(_ address: String) { if selection.contains(address) { selection.remove(address) } else { selection.insert(address) } }
    private func saveToPhotos() {
        let addresses = gallery.images.filter { selection.contains($0) }
        let store = model.profiles.websiteDataStore(for: model.profile), source = model.webView
        saving = true
        Task {
            guard await GalleryPhotoSaver.authorize() else { saving = false; photoMessage = "لم يُمنح إذن إضافة الصور."; return }
            var count = 0
            for (index, address) in addresses.enumerated() { photoProgress = "\(index + 1) / \(addresses.count)"; do { try await GalleryPhotoSaver.save(address: address, store: store, source: source); count += 1 } catch { } }
            saving = false; selection.removeAll(); selecting = false; photoMessage = "حُفظت \(count) من \(addresses.count) صورة في الألبوم."
        }
    }
    private func downloadSelection() {
        let urls = gallery.images.filter { selection.contains($0) }, owner = model.profile, source = model.webView, referrer = model.webView?.url
        selection.removeAll(); selecting = false
        Task { for item in urls { if owner.isPrivate && model.profile.id != owner.id { break }; if let url = URL(string: item) { await model.downloads.start(url: url, profile: owner, referrer: referrer, webView: source) } } }
    }
    private func preference(_ key: WritableKeyPath<ReadingPreferences, Double>) -> Binding<Double> { Binding(get: { prefs[keyPath: key] }, set: { var value = prefs; value[keyPath: key] = $0; model.data.settings.reading = value; model.persist() }) }
}

struct ScrollViewAccessor: UIViewRepresentable {
    @Binding var scrollView: UIScrollView?
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { var ancestor = uiView.superview; while let view = ancestor { if let scroll = view as? UIScrollView { scrollView = scroll; break }; ancestor = view.superview } }
    }
}

// Recalculate cookies for each redirect. Do not forward an authenticated Cookie header to another host.
final class ThumbnailRedirects: NSObject, URLSessionTaskDelegate {
    let cookies: [HTTPCookie]
    init(cookies: [HTTPCookie]) { self.cookies = cookies }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request; next.setValue(nil, forHTTPHeaderField: "Cookie")
        if let url = next.url { for (key, value) in DownloadFiles.cookieHeaders(cookies, for: url) { next.setValue(value, forHTTPHeaderField: key) } }
        completionHandler(next)
    }
}
struct ProfileThumbnail: View {
    @Environment(\.browserTheme) private var theme
    let address: String
    let store: WKWebsiteDataStore
    var source: WKWebView?
    var fit = false
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image {
                if fit { Image(uiImage: image).resizable().scaledToFit() }
                else { Image(uiImage: image).resizable().scaledToFill() }
            } else { ZStack { theme.textColor.opacity(0.04); if failed { Image(systemName: "photo").font(.largeTitle) } else { ProgressView() } }.frame(minHeight: fit ? 220 : 0) }
        }.task(id: address) { failed = false; await load() }.onDisappear { image = nil }
    }
    private func load() async {
        guard let url = URL(string: address) else { failed = true; return }
        if url.scheme == "data" || url.scheme == "blob" {
            guard let source else { failed = true; return }
            let encoded = String(data: (try? JSONEncoder().encode(address)) ?? Data(), encoding: .utf8) ?? "null"
            do {
                let value = try await source.callAsyncJavaScript("const b=await(await fetch(\(encoded))).blob();if(b.size>8388608)throw Error('image too large');return await new Promise((resolve,reject)=>{const r=new FileReader();r.onload=()=>resolve(r.result);r.onerror=reject;r.readAsDataURL(b)});", arguments: [:], in: nil, contentWorld: .page)
                guard let raw = value as? String, let part = raw.split(separator: ",", maxSplits: 1).last, let bytes = Data(base64Encoded: String(part)), let decoded = thumbnail(data: bytes) else { failed = true; return }; image = decoded
            } catch { failed = true }; return
        }
        guard BrowserURL.isWeb(url) else { failed = true; return }
        let cookies: [HTTPCookie] = await withCheckedContinuation { c in store.httpCookieStore.getAllCookies { c.resume(returning: $0) } }
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil; config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config, delegate: ThumbnailRedirects(cookies: cookies), delegateQueue: nil); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.allHTTPHeaderFields = DownloadFiles.cookieHeaders(cookies, for: url)
        if let page = source?.url { request.setValue(page.scheme.flatMap { scheme in page.host.map { scheme + "://" + $0 + "/" } }, forHTTPHeaderField: "Referer") }
        do {
            let (location, response) = try await session.download(for: request); defer { try? FileManager.default.removeItem(at: location) }
            guard (response as? HTTPURLResponse)?.statusCode == 200, ((try location.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) <= 16_777_216, let data = try? Data(contentsOf: location), let decoded = thumbnail(data: data) else { failed = true; return }
            image = decoded
        } catch { failed = true }
    }
    private func thumbnail(data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 1
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 1
        let scale = min(1, 1100 / max(1, width), sqrt(8_000_000 / max(1, width * height)))
        let maximum = fit ? min(12_000, max(width, height) * scale) : 450
        guard let output = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maximum, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: output)
    }
}
