import SwiftUI
import WebKit
import UniformTypeIdentifiers
import Photos
import ImageIO

struct ProfilesSheet: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject private var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var name = ""
    @State private var accent = "cyan"
    @State private var isPrivate = false
    @State private var deleting: BrowserProfile?
    init(model: BrowserModel) { self.model = model; store = model.profiles }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PanelHeader(title: "مساحاتك", caption: "كوكيز، سجل، إعدادات وتنزيلات مستقلة لكل مساحة.")
                    ForEach(store.profiles) { profile in profileRow(profile) }
                    Button { creating = true } label: { Label("إنشاء مساحة جديدة", systemImage: "plus.circle.fill").font(.headline).frame(maxWidth: .infinity).padding(19).glassSurface() }.buttonStyle(.plain).accessibilityIdentifier("addProfileButton")
                    Label("المساحة الخاصة لا تحتفظ بالنشاط بعد مغادرتها أو انتقال التطبيق للخلفية.", systemImage: "theatermasks").font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                }.padding(22)
            }.background { OrbitBackground(tint: .purple) }.navigationTitle("البروفايلات").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("تم") { dismiss() } } }
                .sheet(isPresented: $creating) { createProfile }
                .confirmationDialog("حذف المساحة وكل بياناتها وملفاتها؟", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("حذف نهائي", role: .destructive) { if let target = deleting { Task { await model.deleteProfile(target) } }; deleting = nil }
                }
        }
    }
    private func profileRow(_ profile: BrowserProfile) -> some View {
        Button {
            Task { await model.switchProfile(to: profile); if model.profile.id == profile.id { dismiss() } }
        } label: {
            HStack(spacing: 15) {
                Image(systemName: profile.symbol).font(.system(size: 30, weight: .light)).foregroundStyle(profile.color).frame(width: 56, height: 56).background(profile.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 6) {
                    Text(profile.name).font(.headline)
                    Label(profile.isPrivate ? "جلسة مؤقتة" : "مخزن مستقل", systemImage: profile.isPrivate ? "theatermasks" : "externaldrive").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if profile.locked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                if model.profile.id == profile.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(profile.color) }
            }.padding(17).glassSurface(27)
        }.buttonStyle(.plain).disabled(model.switching).accessibilityIdentifier("profile-" + profile.name)
            .contextMenu { if store.profiles.count > 1 { Button("حذف المساحة", systemImage: "trash", role: .destructive) { deleting = profile } } }
    }
    private var createProfile: some View {
        NavigationStack {
            Form {
                Section("الهوية") {
                    TextField("اسم المساحة", text: $name).accessibilityIdentifier("profileNameField")
                    Picker("اللون", selection: $accent) { Text("سماوي").tag("cyan"); Text("بنفسجي").tag("violet"); Text("وردي").tag("rose"); Text("عنبر").tag("amber"); Text("نعناعي").tag("mint") }
                }
                Section { Toggle("مساحة خاصة مؤقتة", isOn: $isPrivate) } footer: { Text("تُحذف جلسة المساحة الخاصة وتنزيلاتها الداخلية عند المغادرة. صدّر الملفات التي تريد الاحتفاظ بها أولًا.") }
            }.navigationTitle("مساحة جديدة")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { creating = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("إنشاء") { let target = store.add(name: name, accent: accent, isPrivate: isPrivate); creating = false; Task { await model.switchProfile(to: target); dismiss() } }.accessibilityIdentifier("createProfileButton") }
                }
        }.environment(\.layoutDirection, .rightToLeft).presentationDetents([.medium, .large])
    }
}

struct TabsSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var closeAll = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PanelHeader(title: "نوافذ على عالمك", caption: "\(model.tabs.count) تبويب في \(model.profile.name)")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        ForEach(model.tabs) { tab in
                            Button { model.selectTab(tab); dismiss() } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    ZStack {
                                        if let snapshot = tab.snapshot { Image(uiImage: snapshot).resizable().scaledToFill() }
                                        else { LinearGradient(colors: [model.profile.color.opacity(0.15), .black.opacity(0.2)], startPoint: .topTrailing, endPoint: .bottomLeading); Image(systemName: tab.isHome ? "sparkles" : "globe").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(model.profile.color) }
                                    }.frame(height: 155).clipped()
                                    HStack { Text(tab.title).font(.caption.weight(.semibold)).lineLimit(1); Spacer(minLength: 0); Button { model.closeTab(tab) } label: { Image(systemName: "xmark").padding(8) }.accessibilityLabel("إغلاق \(tab.title)") }.padding(10)
                                }.glassSurface(23).clipShape(RoundedRectangle(cornerRadius: 23)).overlay(RoundedRectangle(cornerRadius: 23).stroke(model.selectedTabID == tab.id ? model.profile.color : .clear, lineWidth: 2))
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(22)
            }.background { OrbitBackground(tint: model.profile.color) }.navigationTitle("التبويبات").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("تم") { dismiss() } }
                    ToolbarItem(placement: .bottomBar) { HStack { Button("إغلاق الكل", role: .destructive) { closeAll = true }; Spacer(); Button { _ = model.newTab(); dismiss() } label: { Label("تبويب جديد", systemImage: "plus") } } }
                }.confirmationDialog("إغلاق كل تبويبات هذه المساحة؟", isPresented: $closeAll) { Button("إغلاق الكل", role: .destructive) { model.closeAllTabs() } }
        }.onAppear { model.snapshotCurrent() }
    }
}

struct DownloadsSheet: View {
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
            }.background { OrbitBackground(tint: model.profile.color) }.navigationTitle("مدير الملفات").navigationBarTitleDisplayMode(.inline)
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
                .confirmationDialog("حذف الملف وإيقاف تنزيله؟", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) { Button("حذف", role: .destructive) { if let item = deleting { service.remove(item) }; deleting = nil } }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                    switch result { case .success(let files): for file in files { Task { await service.importFile(file, profile: model.profile, webView: model.webView) } }; case .failure(let error): model.notify(error.localizedDescription) }
                }
                .sheet(item: $preview) { FilePreview(url: $0.url).ignoresSafeArea() }
                .sheet(item: $sharing) { ActivitySheet(url: $0.url) }
                .sheet(item: $exporting) { FileExporter(url: $0.url).ignoresSafeArea() }
        }
    }
    private func downloadRow(_ item: BrowserDownload) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 13) {
                Image(systemName: item.state == .completed ? "doc.fill" : item.state == .failed ? "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90" : "arrow.down").font(.system(size: 24, weight: .light)).foregroundStyle(item.state == .failed ? .orange : model.profile.color).frame(width: 44, height: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.filename).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(status(item)).font(.caption).foregroundStyle(.secondary)
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
                    Button("حذف", systemImage: "trash", role: .destructive) { deleting = item }
                } label: { Image(systemName: "ellipsis").frame(width: 38, height: 44) }.accessibilityLabel("خيارات \(item.filename)")
            }
            if item.isBusy { if let fraction = item.fraction { ProgressView(value: fraction).tint(model.profile.color) } else { ProgressView().frame(maxWidth: .infinity, alignment: .leading) } }
            if let error = item.error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
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
