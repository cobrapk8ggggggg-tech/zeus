import SwiftUI
import WebKit

struct WebsiteStorageRecord: Identifiable {
    let record: WKWebsiteDataRecord
    var id: String { record.displayName }
    var types: [String] { record.dataTypes.sorted() }
    static func title(_ type: String) -> String {
        switch type {
        case WKWebsiteDataTypeCookies: return "الكوكيز والجلسة"
        case WKWebsiteDataTypeLocalStorage: return "التخزين المحلي"
        case WKWebsiteDataTypeSessionStorage: return "تخزين الجلسة"
        case WKWebsiteDataTypeIndexedDBDatabases: return "قواعد IndexedDB"
        case WKWebsiteDataTypeDiskCache: return "كاش القرص"
        case WKWebsiteDataTypeMemoryCache: return "كاش الذاكرة"
        case WKWebsiteDataTypeFetchCache: return "كاش الطلبات"
        case WKWebsiteDataTypeServiceWorkerRegistrations: return "Service Workers"
        case WKWebsiteDataTypeWebSQLDatabases: return "قواعد WebSQL"
        default: return type.replacingOccurrences(of: "WKWebsiteDataType", with: "")
        }
    }
}

@MainActor final class WebsiteStorageController: ObservableObject {
    @Published var sites: [WebsiteStorageRecord] = []
    @Published var busy = false
    let context: ProfileSettingsContext
    init(context: ProfileSettingsContext) { self.context = context }
    func refresh() async {
        guard context.permitted else { sites = []; return }
        let records = await context.model.profiles.websiteDataStore(for: context.profile).dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        sites = records.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }.map { WebsiteStorageRecord(record: $0) }
    }
    func remove(_ site: WebsiteStorageRecord, types: Set<String>) async {
        guard context.permitted, !types.isEmpty, !busy else { return }
        busy = true; defer { busy = false }
        let model = context.model
        // Do not destroy unrelated live tabs when deleting one origin's data.
        let affected = context.isActive ? model.tabs.filter { BrowserURL.hostMatches(URL(string: $0.url)?.host ?? "", domain: site.id) } : []
        for tab in affected { tab.dispose() }
        await model.profiles.websiteDataStore(for: context.profile).removeData(ofTypes: types.intersection(site.record.dataTypes), for: [site.record])
        await refresh()
        if affected.contains(where: { $0.id == model.current?.id }) { await model.ensureCurrentLoaded() }
    }
}

struct WebsiteStoragePage: View {
    @StateObject private var controller: WebsiteStorageController
    @State private var search = ""
    init(context: ProfileSettingsContext) { _controller = StateObject(wrappedValue: WebsiteStorageController(context: context)) }
    var body: some View {
        List {
            ForEach(controller.sites.filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) }) { site in
                NavigationLink {
                    WebsiteStorageDetail(controller: controller, siteID: site.id)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(site.id).font(.headline).environment(\.layoutDirection, .leftToRight)
                        Text(site.types.map(WebsiteStorageRecord.title).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }.accessibilityIdentifier("stored-site-" + site.id)
            }
            if controller.sites.isEmpty { ContentUnavailableView("لا توجد بيانات مواقع", systemImage: "externaldrive") }
        }.settingsPage("بيانات المواقع").searchable(text: $search, prompt: "اسم الموقع")
            .task { await controller.refresh() }.refreshable { await controller.refresh() }
    }
}

private struct WebsiteStorageDetail: View {
    @ObservedObject var controller: WebsiteStorageController
    let siteID: String
    @State private var selected = Set<String>()
    @State private var confirming = false
    private var site: WebsiteStorageRecord? { controller.sites.first { $0.id == siteID } }
    var body: some View {
        Form {
            if let site {
                Section("اختر البيانات المراد حذفها") {
                    ForEach(site.types, id: \.self) { type in
                        Toggle(WebsiteStorageRecord.title(type), isOn: Binding(get: { selected.contains(type) }, set: { if $0 { selected.insert(type) } else { selected.remove(type) } })).tint(.green)
                    }
                }
                Section {
                    Button("تحديد الكل") { selected = site.record.dataTypes }
                    Button("حذف المحدد", role: .destructive) { confirming = true }.disabled(selected.isEmpty)
                }
                Section { NavigationLink("إدارة كوكيز هذا الموقع منفردة") { CookieSettingsPage(context: controller.context, initialSearch: siteID) } }
            } else { ContentUnavailableView("مُسحت بيانات هذا الموقع", systemImage: "checkmark.circle") }
        }.settingsPage(siteID).disabled(controller.busy)
            .confirmationDialog("حذف البيانات المحددة من \(siteID) فقط؟", isPresented: $confirming, titleVisibility: .visible) {
                Button("حذف المحدد", role: .destructive) { if let site { Task { await controller.remove(site, types: selected); selected = [] } } }
            }
    }
}

enum StoredItemCategory: String, CaseIterable, Identifiable {
    case history, search, bookmarks, scripts, forms, downloads
    var id: String { rawValue }
    var title: String {
        switch self { case .history: return "سجل التصفح"; case .search: return "سجل البحث"; case .bookmarks: return "المفضلة"; case .scripts: return "السكربتات"; case .forms: return "النماذج المحفوظة"; case .downloads: return "التنزيلات" }
    }
}

struct TranslationStoragePage: View {
    @ObservedObject var context: ProfileSettingsContext
    @State private var entries: [TranslationMemory.Entry] = []
    @State private var selected = Set<String>()
    @State private var search = ""
    @State private var confirming = false
    var body: some View {
        List {
            ForEach(entries.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }) { entry in
                Button { if !selected.insert(entry.id).inserted { selected.remove(entry.id) } } label: {
                    HStack { Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle"); VStack(alignment: .leading) { Text(entry.text).lineLimit(3); Text(byteText(entry.bytes)).font(.caption).foregroundStyle(.secondary) } }
                }.buttonStyle(.plain)
            }
        }.settingsPage("الترجمات المحفوظة").searchable(text: $search)
            .task { await refresh() }
            .toolbar { ToolbarItem(placement: .bottomBar) { Button("حذف المحدد (\(selected.count))", role: .destructive) { confirming = true }.disabled(selected.isEmpty) } }
            .confirmationDialog("حذف هذه الترجمات فقط؟", isPresented: $confirming) {
                Button("حذف", role: .destructive) { Task { guard context.permitted else { return }; await TranslationMemory.shared.remove(keys: selected, folder: context.model.profiles.folder(for: context.profile)); selected = []; await refresh() } }
            }
    }
    private func refresh() async { guard context.permitted else { return }; entries = await TranslationMemory.shared.entries(folder: context.model.profiles.folder(for: context.profile)) }
}

struct AgentStoragePage: View {
    @ObservedObject var context: ProfileSettingsContext
    @State private var sessions: [AgentSession] = []
    @State private var selected = Set<UUID>()
    @State private var confirming = false
    var body: some View {
        List {
            ForEach(sessions) { session in
                Button { if !selected.insert(session.id).inserted { selected.remove(session.id) } } label: {
                    HStack { Image(systemName: selected.contains(session.id) ? "checkmark.circle.fill" : "circle"); VStack(alignment: .leading, spacing: 4) { Text(session.title); Text("\(session.messages.count) رسالة").font(.caption).foregroundStyle(.secondary) }; Spacer() }
                }.buttonStyle(.plain)
            }
        }.settingsPage("محادثات الوكيل").onAppear(perform: refresh)
            .toolbar { ToolbarItem(placement: .bottomBar) { Button("حذف المحدد (\(selected.count))", role: .destructive) { confirming = true }.disabled(selected.isEmpty) } }
            .confirmationDialog("حذف المحادثات المحددة ومرفقاتها فقط؟", isPresented: $confirming) { Button("حذف", role: .destructive) { removeSelected() } }
    }
    private var root: URL { context.model.profiles.folder(for: context.profile).appendingPathComponent("OpenMinis") }
    private func refresh() {
        guard context.permitted else { return }
        if context.isActive, let agent = context.model.agent { agent.save(); sessions = agent.sessions }
        else { sessions = BrowserDisk.read(AgentArchive.self, from: root.appendingPathComponent("agent.json"))?.sessions ?? [] }
    }
    private func removeSelected() {
        guard context.permitted else { return }
        if context.isActive, let agent = context.model.agent { for id in selected { agent.delete(id) } }
        else if var archive = BrowserDisk.read(AgentArchive.self, from: root.appendingPathComponent("agent.json")) {
            archive.sessions.removeAll { selected.contains($0.id) }
            if let id = archive.selected, selected.contains(id) { archive.selected = nil }
            for id in selected { try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString)) }
            do { try BrowserDisk.write(archive, to: root.appendingPathComponent("agent.json")) } catch { context.model.notify(error.localizedDescription) }
        }
        selected = []; refresh()
    }
}

struct StoredProfileItemsPage: View {
    @ObservedObject var context: ProfileSettingsContext
    let category: StoredItemCategory
    @State private var selected = Set<String>()
    @State private var search = ""
    @State private var revision = 0
    @State private var confirming = false
    private struct Item: Identifiable { var id: String; var title: String; var detail: String }
    private var data: ProfileData { context.isActive ? context.model.data : context.model.profiles.load(context.profile) }
    private var items: [Item] {
        _ = revision
        switch category {
        case .history: return data.history.map { Item(id: $0.id.uuidString, title: $0.title, detail: $0.url) }
        case .search: return Array((data.searches ?? []).enumerated()).map { Item(id: String($0.offset), title: $0.element, detail: "") }
        case .bookmarks: return data.bookmarks.map { Item(id: $0.id.uuidString, title: $0.title, detail: $0.url) }
        case .scripts: return data.scripts.map { Item(id: $0.id.uuidString, title: $0.name, detail: $0.domain) }
        case .forms: return (data.forms ?? []).map { Item(id: $0.id.uuidString, title: $0.title, detail: $0.origin) }
        case .downloads: return context.model.downloads.forProfile(context.profileID).map { Item(id: $0.id.uuidString, title: $0.filename, detail: byteText($0.received)) }
        }
    }
    var body: some View {
        List {
            ForEach(items.filter { search.isEmpty || ($0.title + $0.detail).localizedCaseInsensitiveContains(search) }) { item in
                Button { if !selected.insert(item.id).inserted { selected.remove(item.id) } } label: {
                    HStack { Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle"); VStack(alignment: .leading, spacing: 4) { Text(item.title).lineLimit(2); if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }; Spacer() }
                }.buttonStyle(.plain)
            }
            if items.isEmpty { ContentUnavailableView("لا توجد عناصر", systemImage: "tray") }
        }.settingsPage(category.title).searchable(text: $search)
            .toolbar {
                ToolbarItem(placement: .bottomBar) { HStack { Button("تحديد الكل") { selected = Set(items.map(\.id)) }; Spacer(); Button("حذف المحدد (\(selected.count))", role: .destructive) { confirming = true }.disabled(selected.isEmpty) } }
            }
            .confirmationDialog("حذف العناصر المحددة فقط؟", isPresented: $confirming) { Button("حذف", role: .destructive) { removeSelected() } }
    }
    private func removeSelected() {
        guard context.permitted else { return }
        var copy = data
        switch category {
        case .history: copy.history.removeAll { selected.contains($0.id.uuidString) }
        case .search: copy.searches = (copy.searches ?? []).enumerated().filter { !selected.contains(String($0.offset)) }.map(\.element)
        case .bookmarks: copy.bookmarks.removeAll { selected.contains($0.id.uuidString) }
        case .scripts: copy.scripts.removeAll { selected.contains($0.id.uuidString) }
        case .forms:
            for form in copy.forms ?? [] where selected.contains(form.id.uuidString) { FormVault.remove(profileID: context.profileID, id: form.id); if context.isActive { context.model.temporaryFormValues.removeValue(forKey: form.id) } }
            copy.forms?.removeAll { selected.contains($0.id.uuidString) }
        case .downloads:
            for download in context.model.downloads.forProfile(context.profileID) where selected.contains(download.id.uuidString) { context.model.downloads.remove(download) }
        }
        if category != .downloads {
            if context.isActive { context.model.data = copy; context.model.persist() } else { context.model.profiles.save(copy, for: context.profile) }
        }
        selected = []; revision += 1
    }
}
