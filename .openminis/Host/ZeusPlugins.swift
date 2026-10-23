import SwiftUI

struct ZeusPlugin: Decodable, Identifiable {
    struct Skill: Decodable { let name: String; let url: String }
    let id: String
    let name: String
    let description: String
    let installed: Bool
    let connected: Bool
    let revision: String?
    let mcp_url: String?
    let proxy_token: String?
    let skills: [Skill]
}

@MainActor final class ZeusPlugins: ObservableObject {
    static let shared = ZeusPlugins()
    @Published var plugins: [ZeusPlugin] = []
    @Published var error: String?
    @Published var busy = false
    func refresh() async {
        do {
            struct Response: Decodable { let plugins: [ZeusPlugin] }
            let data = try await ZeusProjects.shared.request("v1/plugins")
            plugins = try JSONDecoder().decode(Response.self, from: data).plugins
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func install(_ plugin: ZeusPlugin) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await ZeusProjects.shared.object("v1/plugins/\(plugin.id)/install", method: "POST")
            await refresh()
            if let installed = plugins.first(where: { $0.id == plugin.id }) { try await sync(installed) }
        } catch { self.error = error.localizedDescription }
    }
    func sync(_ plugin: ZeusPlugin) async throws {
        guard plugin.connected, plugin.mcp_url != nil, let token = plugin.proxy_token else { return }
        let id = "zeus-" + plugin.id
        let object: [String: Any] = ["id": id, "note": plugin.name, "enabled": true,
            "url": ZeusProjects.shared.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/mcp/" + plugin.id,
            "headers": ["Authorization": "Bearer " + token]]
        let config = try JSONDecoder().decode(MCPServerConfig.self, from: JSONSerialization.data(withJSONObject: object))
        if MCPStore.shared.servers.contains(where: { $0.id == id }) { MCPStore.shared.update(config) }
        else { MCPStore.shared.add(config) }
    }
}

struct ZeusPluginsSettingsView: View {
    @ObservedObject private var store = ZeusPlugins.shared
    var body: some View {
        List {
            Section {
                ForEach(store.plugins) { plugin in
                    NavigationLink { ZeusPluginDetail(plugin: plugin) } label: {
                        VStack(alignment: .leading) {
                            Text(plugin.name)
                            Text(plugin.installed ? (plugin.connected ? "مثبت ومتصل" : "مثبت") : "غير مثبت").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let error = store.error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("إضافات Zeus").task { await store.refresh() }.refreshable { await store.refresh() }
    }
}

private struct ZeusPluginDetail: View {
    let plugin: ZeusPlugin
    @ObservedObject private var store = ZeusPlugins.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var token = ""
    @State private var error: String?
    @State private var busy = false
    private var current: ZeusPlugin { store.plugins.first(where: { $0.id == plugin.id }) ?? plugin }
    var body: some View {
        Form {
            Section("المكون الأصلي") {
                Text(current.description)
                if let revision = current.revision { Text(String(revision.prefix(12))).font(.caption.monospaced()) }
                Button(current.installed ? "مزامنة اتصال الإضافة" : "تثبيت الإضافة") { Task { await store.install(current) } }.disabled(store.busy)
            }
            if current.mcp_url != nil {
                Section("الحساب") {
                    Button("تسجيل الدخول عبر OAuth") { Task { await login() } }.disabled(busy)
                    SecureField("رمز وصول الحساب", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("اختبار الرمز وربط الحساب") { Task { await connect() } }.disabled(busy || token.isEmpty)
                    if current.connected { Label("الحساب متصل", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
            }
            Section("مهارات متاحة للوكيل داخل المتصفح") {
                ForEach(current.skills, id: \.url) { skill in
                    Button(skill.name) {
                        Task {
                            busy = true; defer { busy = false }
                            do { _ = try await SkillStore.shared.importFromGitHub(urlString: skill.url); error = nil }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(busy)
                }
            }
            if let error = error ?? store.error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(current.name)
            .onChange(of: scenePhase) { value in if value == .active { Task { await store.refresh() } } }
    }
    private func login() async {
        busy = true; defer { busy = false }
        do {
            let response = try await ZeusProjects.shared.object("v1/connections/\(current.id)/oauth", method: "POST")
            guard let raw = response["url"] as? String, let url = URL(string: raw), url.scheme == "https" else { throw ZeusProjects.shared.failure("عنوان تسجيل الدخول غير صالح.") }
            await UIApplication.shared.open(url)
        } catch { self.error = error.localizedDescription }
    }
    private func connect() async {
        busy = true; defer { busy = false }
        do {
            _ = try await ZeusProjects.shared.object("v1/connections/\(current.id)/token", method: "POST", body: ["token": token])
            token = ""
            await store.refresh()
            try await store.sync(current)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
