import SwiftUI
import WebKit
import UniformTypeIdentifiers
import Photos
import ImageIO

struct TabsSheet: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var closeAll = false
    var body: some View {
        NavigationStack {
            RememberedTabScroll(model: model, key: "tabs-" + (model.data.settings.chromeLayout ?? .original).rawValue, axis: .vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    PanelHeader(title: "نوافذ على عالمك", caption: "\(model.tabs.count) تبويب في \(model.profile.name)")
                    BrowserTabCollection(model: model, grid: true, selected: { dismiss() })
                }.padding(22)
            }.background { OrbitBackground(tint: theme.accentColor) }.navigationTitle("التبويبات").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("تم") { dismiss() } }
                    ToolbarItem(placement: .bottomBar) { HStack { Button("إغلاق الكل") { closeAll = true }; Spacer(); Button { _ = model.newTab(); dismiss() } label: { Label("تبويب جديد", systemImage: "plus") } } }
                }.confirmationDialog("إغلاق كل تبويبات هذه المساحة؟", isPresented: $closeAll) { Button("إغلاق الكل") { model.closeAllTabs() } }
        }.onAppear { model.snapshotCurrent() }
    }
}

struct DownloadsSheet: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var model: BrowserModel
    @ObservedObject private var service: DownloadService
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var link = ""
    @State private var importing = false
    @State private var preview: ShareItem?
    @State private var sharing: ShareItem?
    @State private var exporting: ShareItem?
    @State private var renaming: BrowserDownload?
    @State private var newName = ""
    @State private var deleting: BrowserDownload?
    init(model: BrowserModel) { self.model = model; service = model.downloads }
    private var items: [BrowserDownload] { service.forProfile(model.profile.id) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    PanelHeader(title: "التنزيلات", caption: "ملفات \(model.profile.name) · \(byteText(items.reduce(0) { $0 + ($1.state == .completed ? $1.received : 0) }))")
                    HStack(spacing: 12) {
                        Button { adding = true } label: { Label("إضافة رابط", systemImage: "link.badge.plus").frame(maxWidth: .infinity).padding(15).glassSurface(20) }
                        Button { importing = true } label: { Label("من الملفات", systemImage: "folder.badge.plus").frame(maxWidth: .infinity).padding(15).glassSurface(20) }
                    }.font(.subheadline).buttonStyle(.plain)
                    if items.isEmpty {
                        ContentUnavailableView("جاهز لملفاتك", systemImage: "arrow.down.circle", description: Text("اضغط رابط تنزيل داخل الموقع، أو أضف رابطًا مباشرًا. تبقى الملفات داخل هذه المساحة."))
                            .padding(.top, 35)
                    }
                    ForEach(items) { item in downloadRow(item) }
                }.padding(22)
            }.background { OrbitBackground(tint: theme.accentColor) }.navigationTitle("مدير الملفات").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("تم") { dismiss() } } }
                .alert("تنزيل من رابط", isPresented: $adding) {
                    TextField("https://…", text: $link).textInputAutocapitalization(.never).keyboardType(.URL)
                    Button("تنزيل") { if let url = URL(string: link), BrowserURL.isWeb(url) { Task { await service.start(url: url, profile: model.profile, referrer: model.webView?.url, webView: model.webView) } } else { model.notify("أدخل رابط HTTP أو HTTPS صالحًا.") } }
                    Button("إلغاء", role: .cancel) {}
                } message: { Text("التنزيلات المباشرة تستخدم جلسة المساحة الحالية. ملفات blob وطلبات POST تُنزّل من الصفحة الأصلية.") }
                .alert("اسم الملف", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                    TextField("الاسم", text: $newName)
                    Button("حفظ") { if let item = renaming { service.rename(item, to: newName) }; renaming = nil }
                    Button("إلغاء", role: .cancel) { renaming = nil }
                }
                .confirmationDialog("حذف الملف وإيقاف تنزيله؟", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) { Button("حذف") { if let item = deleting { service.remove(item) }; deleting = nil } }
                .zeusFileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                    switch result { case .success(let files): let owner = model.profile; for file in files { Task { await service.importFile(file, profile: owner) } }; case .failure(let error): model.notify(error.localizedDescription) }
                }
                .sheet(item: $preview) { FilePreview(url: $0.url).ignoresSafeArea() }
                .sheet(item: $sharing) { ActivitySheet(url: $0.url) }
                .sheet(item: $exporting) { FileExporter(url: $0.url).ignoresSafeArea() }
        }
    }
    private func downloadRow(_ item: BrowserDownload) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 13) {
                Image(systemName: item.state == .completed ? "doc.fill" : item.state == .failed ? "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90" : "arrow.down").font(.system(size: 24, weight: .light)).foregroundStyle(item.state == .failed ? theme.textColor : theme.accentColor).frame(width: 44, height: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.filename).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(status(item)).font(.caption).foregroundStyle(theme.secondaryTextColor)
                }
                Spacer(minLength: 0)
                Menu {
                    if let file = service.fileURL(item) {
                        Button("معاينة", systemImage: "eye") { preview = ShareItem(url: file) }
                        Button("حفظ في تطبيق الملفات", systemImage: "folder") { exporting = ShareItem(url: file) }
                        Button("مشاركة", systemImage: "square.and.arrow.up") { sharing = ShareItem(url: file) }
                        Button("إعادة تسمية", systemImage: "pencil") { newName = item.filename; renaming = item }
                        if ["jpg", "jpeg", "png", "heic", "webp"].contains(file.pathExtension.lowercased()) { Button("حفظ في الصور", systemImage: "photo") { savePhoto(file) } }
                    }
                    if item.isBusy { Button("إيقاف مؤقت", systemImage: "pause") { service.pause(item) } }
                    if item.state == .paused || item.state == .failed { Button("استئناف أو إعادة البدء", systemImage: "play") { Task { await service.resume(item, webView: model.webView) } } }
                    Button("حذف", systemImage: "trash") { deleting = item }
                } label: { Image(systemName: "ellipsis").frame(width: 38, height: 44) }.accessibilityLabel("خيارات \(item.filename)")
            }
            if item.isBusy { if let fraction = item.fraction { ProgressView(value: fraction).tint(theme.accentColor) } else { ProgressView().frame(maxWidth: .infinity, alignment: .leading) } }
            if let error = item.error { Text(error).font(.caption).foregroundStyle(theme.textColor).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text(item.engine == .backgroundSession ? "تنزيل نظام · يدعم الخلفية" : "تنزيل الصفحة · أبقِ التطبيق مفتوحًا").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                if item.isBusy { Button { service.pause(item) } label: { Image(systemName: "pause.fill").frame(width: 36, height: 30) } }
                else if item.state == .failed || item.state == .paused { Button { Task { await service.resume(item, webView: model.webView) } } label: { Label("متابعة", systemImage: "play.fill").font(.caption.bold()) } }
                else if let file = service.fileURL(item) { Button("فتح") { preview = ShareItem(url: file) }.font(.caption.bold()) }
            }.buttonStyle(.plain)
        }.padding(17).glassSurface(25)
    }
    private func status(_ item: BrowserDownload) -> String {
        switch item.state {
        case .completed: return byteText(item.received) + " · اكتمل"
        case .failed: return "تعذر الإكمال · " + byteText(item.received)
        case .paused: return "متوقف مؤقتًا · " + byteText(item.received)
        case .pausing: return "جارٍ حفظ نقطة الاستئناف…"
        case .queued: return "بانتظار الاتصال…"
        case .running: return byteText(item.received) + (item.expected > 0 ? " / " + byteText(item.expected) : " · حجم غير محدد")
        }
    }
    private func savePhoto(_ file: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { Task { @MainActor in model.notify("لم يُمنح إذن إضافة الصور.") }; return }
            PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file) } completionHandler: { success, error in Task { @MainActor in model.notify(success ? "أضيفت الصورة إلى الألبوم." : error?.localizedDescription ?? "تعذر حفظ الصورة.") } }
        }
    }
}
