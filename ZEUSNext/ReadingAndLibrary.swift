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
    let article: ReaderArticle
    @Environment(\.dismiss) private var dismiss
    @State private var fontSize: Double = 21
    @State private var sepia = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Text(article.title).font(.system(size: 31, weight: .bold, design: .serif)).lineSpacing(7)
                    Divider()
                    ForEach(Array(article.paragraphs.enumerated()), id: \.offset) { _, paragraph in Text(paragraph).font(.system(size: fontSize, design: .serif)).lineSpacing(fontSize * 0.48).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(27).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }.background(sepia ? Color(red: 0.14, green: 0.115, blue: 0.085) : Color(red: 0.04, green: 0.05, blue: 0.065))
                .navigationTitle("مساحة القراءة").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("تم") { dismiss() } }
                    ToolbarItem(placement: .bottomBar) { HStack { Image(systemName: "textformat.size.smaller"); Slider(value: $fontSize, in: 16...34, step: 1); Image(systemName: "textformat.size.larger"); Button { sepia.toggle() } label: { Image(systemName: "circle.lefthalf.filled") }.accessibilityLabel("لون خلفية القارئ") } }
                }
        }
    }
}

struct GallerySheet: View {
    @ObservedObject var model: BrowserModel
    let gallery: GalleryArticle
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(gallery.images, id: \.self) { address in
                        Button { if selection.contains(address) { selection.remove(address) } else { selection.insert(address) } } label: {
                            ProfileThumbnail(address: address, store: model.profiles.websiteDataStore(for: model.profile))
                                .frame(height: 190).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 20))
                                .overlay(alignment: .topTrailing) { Image(systemName: selection.contains(address) ? "checkmark.circle.fill" : "circle").symbolRenderingMode(.palette).foregroundStyle(.cyan, .black.opacity(0.4)).font(.title2).padding(10) }
                        }.buttonStyle(.plain)
                    }
                }.padding(18)
            }.background { OrbitBackground(tint: .purple) }.navigationTitle("\(gallery.images.count) صورة").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("تم") { dismiss() } }
                    ToolbarItem(placement: .bottomBar) { Button("تنزيل المحدد (\(selection.count))", systemImage: "arrow.down.circle") { let urls = selection; selection.removeAll(); Task { for item in urls { if let url = URL(string: item) { await model.downloads.start(url: url, profile: model.profile, referrer: model.webView?.url, webView: model.webView) } } }; model.notify("أُضيفت الصور المحددة إلى مدير التنزيلات.") }.disabled(selection.isEmpty) }
                }
        }
    }
}

struct ProfileThumbnail: View {
    let address: String
    let store: WKWebsiteDataStore
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            Color.white.opacity(0.04)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else if failed { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
            else { ProgressView() }
        }.task(id: address) {
            guard let url = URL(string: address), BrowserURL.isWeb(url) else { failed = true; return }
            let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) } }
            let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
            let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url); request.allHTTPHeaderFields = DownloadFiles.cookieHeaders(cookies, for: url)
            do {
                let (location, response) = try await session.download(for: request); defer { try? FileManager.default.removeItem(at: location) }
                guard (response as? HTTPURLResponse)?.statusCode == 200, Int64((try location.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) < 8_000_000,
                      let source = CGImageSourceCreateWithURL(location as CFURL, nil), let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { failed = true; return }
                image = UIImage(cgImage: thumbnail)
            } catch { failed = true }
        }
    }
}
