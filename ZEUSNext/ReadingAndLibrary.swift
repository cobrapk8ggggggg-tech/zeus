import SwiftUI
import WebKit
import ImageIO

struct LibrarySheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var section = 0
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List {
                Picker("المكتبة", selection: $section) { Text("المفضلة").tag(0); Text("السجل").tag(1) }.pickerStyle(.segmented).listRowBackground(Color.clear)
                if section == 0 {
                    if model.data.bookmarks.isEmpty { ContentUnavailableView("صفحات تستحق العودة", systemImage: "bookmark", description: Text("أضف صفحة من صندوق الأدوات؛ تُحفظ في هذه المساحة فقط.")) }
                    ForEach(model.data.bookmarks.filter { matches($0.title, $0.url) }) { item in
                        Button { model.open(item.url); dismiss() } label: { libraryRow(item.title, url: item.url, symbol: "bookmark.fill") }.buttonStyle(.plain)
                            .contextMenu { Button("حذف", role: .destructive) { model.data.bookmarks.removeAll { $0.id == item.id }; model.persist() } }
                    }
                } else {
                    if model.data.history.isEmpty { ContentUnavailableView("بداية نظيفة", systemImage: "clock", description: Text(model.profile.isPrivate ? "لا يُحفظ سجل في هذه المساحة الخاصة." : "ستظهر زياراتك هنا.")) }
                    ForEach(model.data.history.filter { matches($0.title, $0.url) }) { item in
                        Button { model.open(item.url); dismiss() } label: {
                            VStack(alignment: .leading, spacing: 6) { libraryRow(item.title, url: item.url, symbol: "clock"); Text(item.date, style: .date).font(.caption2).foregroundStyle(.tertiary) }
                        }.buttonStyle(.plain).contextMenu { Button("حذف الزيارة", role: .destructive) { model.data.history.removeAll { $0.id == item.id }; model.persist() } }
                    }
                }
            }.scrollContentBackground(.hidden).background { OrbitBackground(tint: model.profile.color) }.navigationTitle("مكتبة المساحة").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "بحث في العناوين والروابط")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("تم") { dismiss() } } }
        }
    }
    private func matches(_ title: String, _ url: String) -> Bool { search.isEmpty || title.localizedCaseInsensitiveContains(search) || url.localizedCaseInsensitiveContains(search) }
    private func libraryRow(_ title: String, url: String, symbol: String) -> some View {
        HStack(spacing: 13) { Image(systemName: symbol).foregroundStyle(model.profile.color).frame(width: 26); VStack(alignment: .leading, spacing: 5) { Text(title).font(.subheadline.weight(.medium)).lineLimit(2); Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1).environment(\.layoutDirection, .leftToRight) } }.padding(.vertical, 5)
    }
}

struct ReaderSheet: View {
    @ObservedObject var model: BrowserModel
    let article: ReaderArticle
    @Environment(\.dismiss) private var dismiss
    @State private var settings = false
    @State private var controls = true
    @State private var anchor: CGFloat = 0
    @State private var forbidden = ""
    @State private var copied = false
    private var prefs: ReadingPreferences { model.data.settings.reading ?? ReadingPreferences() }
    private var paragraphs: [String] { article.paragraphs.filter { text in !prefs.blockedWords.contains { text.localizedCaseInsensitiveContains($0) } } }
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .trailing, spacing: 25) {
                    Spacer().frame(height: 65)
                    Text(article.title).font(.system(size: prefs.fontSize + 6, weight: .bold, design: .serif)).multilineTextAlignment(.center).frame(maxWidth: .infinity).textSelection(.enabled)
                    Divider().overlay(.white.opacity(0.3))
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in Text(paragraph).font(.system(size: prefs.fontSize, design: .serif)).opacity(prefs.textOpacity).lineSpacing(10).multilineTextAlignment(.trailing).frame(maxWidth: .infinity, alignment: .trailing).textSelection(.enabled) }
                }.padding(25).padding(.bottom, 60)
            }.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, value in
                if value < 10 { controls = true; anchor = value }
                else if abs(value - anchor) > 18 { withAnimation { controls = value < anchor }; anchor = value }
            }
            if controls {
                HStack {
                    Button { settings = true } label: { Image(systemName: "slider.horizontal.3").padding(12) }
                    Button { UIPasteboard.general.string = article.title + "\n\n" + paragraphs.joined(separator: "\n\n"); copied = true } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").padding(12) }
                    Spacer(); Text("وضع القراءة").font(.subheadline); Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").padding(12) }
                }.padding(.horizontal, 12).background(.black).transition(.move(edge: .top).combined(with: .opacity))
            }
            rightReveal
        }.foregroundStyle(.white).tint(.white).statusBarHidden()
            .fullScreenCover(isPresented: $settings) {
                NavigationStack { Form {
                    Section("النص") { Text("حجم الخط \(Int(prefs.fontSize))"); Slider(value: preference(\.fontSize), in: 14...40, step: 1); Text("شفافية النص"); Slider(value: preference(\.textOpacity), in: 0.1...1) }
                    Section("القائمة السوداء") { HStack { TextField("كلمة أو جملة لحظرها", text: $forbidden); Button("إضافة") { let text = forbidden.trimmingCharacters(in: .whitespacesAndNewlines); if !text.isEmpty { var p = prefs; if !p.blockedWords.contains(text) { p.blockedWords.append(text) }; model.data.settings.reading = p; model.persist(); forbidden = "" } } }; ForEach(prefs.blockedWords, id: \.self) { word in HStack { Text(word); Spacer(); Button { var p = prefs; p.blockedWords.removeAll { $0 == word }; model.data.settings.reading = p; model.persist() } label: { Image(systemName: "xmark.circle") } } } }
                }.scrollContentBackground(.hidden).background(.black).navigationTitle("إعدادات القارئ").toolbar { Button("تم") { settings = false } } }.tint(.white).preferredColorScheme(.dark)
            }
    }
    private var rightReveal: some View {
        HStack { Spacer(); Color.clear.frame(width: 24).contentShape(Rectangle()).gesture(DragGesture().onEnded { if $0.translation.width < -10 { withAnimation { controls = true } }; if $0.translation.width > 10 { withAnimation { controls = false } } }) }.frame(maxHeight: .infinity)
    }
    private func preference(_ key: WritableKeyPath<ReadingPreferences, Double>) -> Binding<Double> { Binding(get: { prefs[keyPath: key] }, set: { var value = prefs; value[keyPath: key] = $0; model.data.settings.reading = value; model.persist() }) }
}

struct GallerySheet: View {
    @ObservedObject var model: BrowserModel
    let gallery: GalleryArticle
    @Environment(\.dismiss) private var dismiss
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
            Color.black.ignoresSafeArea()
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
                if selecting { HStack { Text("\(selection.count) صورة"); Spacer(); Button("تنزيل المحدد", systemImage: "arrow.down.circle") { downloadSelection() }.disabled(selection.isEmpty) }.padding(16).background(.black) }
            }
            if let index = selectedIndex { imageReader(start: index).transition(.move(edge: .bottom)) }
        }.foregroundStyle(.white).tint(.white).statusBarHidden(selectedIndex != nil)
            .fullScreenCover(isPresented: $settings) {
                NavigationStack { Form {
                    Section("وضع قراءة الصور") { Text("عرض الصورة \(Int(prefs.imageScale * 100))٪"); Slider(value: preference(\.imageScale), in: 0.2...1, step: 0.05); Text("مسافة التمرير \(Int(prefs.scrollDistance)) نقطة"); Slider(value: preference(\.scrollDistance), in: 100...1000, step: 50) }
                    Text("انقر النصف العلوي للرجوع أو السفلي للتقدم. اسحب من اليمين لإظهار أدوات القراءة.").font(.footnote)
                }.scrollContentBackground(.hidden).background(.black).navigationTitle("إعدادات العرض").toolbar { Button("تم") { settings = false } } }.tint(.white).preferredColorScheme(.dark)
            }
    }
    private var galleryHeader: some View {
        HStack {
            if selecting {
                Button("إلغاء") { selecting = false; selection.removeAll() }; Spacer()
                Button(selection.count == gallery.images.count ? "إلغاء الكل" : "تحديد الكل") { selection = selection.count == gallery.images.count ? [] : Set(gallery.images) }
            } else {
                Button { settings = true } label: { Image(systemName: "gearshape.fill") }; Spacer(); Text("\(gallery.images.count) صور").font(.headline); Spacer()
                Button { selecting = true } label: { Image(systemName: "checkmark.circle") }
                Button { dismiss() } label: { Image(systemName: "xmark") }.padding(.leading, 12)
            }
        }.padding(18).background(.black)
    }
    private func imageReader(start: Int) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                Color.black.ignoresSafeArea()
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
        }.background(.black)
    }
    private func scroll(_ direction: CGFloat) { guard let view = scrollView else { return }; let value = min(max(0, view.contentOffset.y + direction * prefs.scrollDistance), max(0, view.contentSize.height-view.bounds.height)); view.setContentOffset(CGPoint(x: 0, y: value), animated: true) }
    private func toggle(_ address: String) { if selection.contains(address) { selection.remove(address) } else { selection.insert(address) } }
    private func downloadSelection() { let urls = gallery.images.filter { selection.contains($0) }; selection.removeAll(); selecting = false; Task { for item in urls { if let url = URL(string: item) { await model.downloads.start(url: url, profile: model.profile, referrer: model.webView?.url, webView: model.webView) } } } }
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
            } else { ZStack { Color.white.opacity(0.04); if failed { Image(systemName: "photo").font(.largeTitle) } else { ProgressView() } }.frame(minHeight: fit ? 220 : 0) }
        }.task(id: address) { await load() }
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
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let output = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: fit ? 1600 : 450, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: output)
    }
}
