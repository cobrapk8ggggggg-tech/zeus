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
    static let directCatalog: [(String, String, String)] = [
        ("github", "GitHub", "https://api.githubcopilot.com/mcp/"),
        ("railway", "Railway", "https://mcp.railway.com"),
        ("vercel", "Vercel", "https://mcp.vercel.com")
    ]
    func directConfig(_ plugin: ZeusPlugin) -> MCPServerConfig? {
        MCPStore.shared.servers.first { $0.id == "zeus-direct-" + plugin.id }
    }
    func refresh() async {
        // A missing project worker must never hide or disable phone integrations.
        plugins = Self.directCatalog.compactMap { id, name, url in
            let config = MCPStore.shared.servers.first { $0.id == "zeus-direct-" + id }
            let object: [String: Any] = ["id": id, "name": name, "description": "MCP", "installed": config != nil,
                "connected": false, "mcp_url": url, "skills": []]
            return try? JSONDecoder().decode(ZeusPlugin.self, from: JSONSerialization.data(withJSONObject: object))
        }
        error = nil
    }
    func installDirect(_ plugin: ZeusPlugin, token: String = "") throws {
        guard let url = Self.directCatalog.first(where: { $0.0 == plugin.id })?.2 else { return }
        let identifier = "zeus-direct-" + plugin.id
        var object: [String: Any] = ["id": identifier, "note": plugin.name, "enabled": true, "url": url]
        if !token.isEmpty { object["headers"] = ["Authorization": "Bearer " + token] }
        let config = try JSONDecoder().decode(MCPServerConfig.self, from: JSONSerialization.data(withJSONObject: object))
        if directConfig(plugin) != nil { MCPStore.shared.update(config) } else { MCPStore.shared.add(config) }
    }
    func refreshCloud() async {
        do {
            struct Response: Decodable { let plugins: [ZeusPlugin] }
            let data = try await ZeusProjects.shared.request("v1/plugins")
            let cloud = try JSONDecoder().decode(Response.self, from: data).plugins
            for plugin in cloud where !plugins.contains(where: { $0.id == plugin.id }) { plugins.append(plugin) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func authorizeDirect(_ plugin: ZeusPlugin) async throws {
        if directConfig(plugin) == nil { try installDirect(plugin) }
        guard var config = directConfig(plugin), let address = URL(string: config.url ?? "") else { return }
        if let oauth = config.oauth, !oauth.clientId.isEmpty {
            try await MCPOAuthController.shared.authorize(server: config.id, oauth: oauth)
            return
        }
        func metadata(_ url: URL, body: [String: Any]? = nil) async throws -> [String: Any] {
            guard url.scheme == "https", url.user == nil, url.password == nil else { throw ZeusProjects.shared.failure("عنوان OAuth غير آمن.") }
            var request = URLRequest(url: url); request.timeoutInterval = 25
            if let body {
                request.httpMethod = "POST"
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ZeusProjects.shared.failure("تعذر اكتشاف OAuth تلقائياً. استخدم رمز الوصول أو إعدادات OAuth الأصلية.")
            }
            return result
        }
        let origin = address.scheme! + "://" + address.host!
        let resource = try await metadata(URL(string: origin + "/.well-known/oauth-protected-resource")!)
        guard let issuer = (resource["authorization_servers"] as? [String])?.first,
              let issuerURL = URL(string: issuer), issuerURL.scheme == "https", let host = issuerURL.host else {
            throw ZeusProjects.shared.failure("الخدمة تتطلب إعداد OAuth يدوياً أو رمز وصول.")
        }
        let discovery = "https://" + host + "/.well-known/oauth-authorization-server" + (issuerURL.path == "/" ? "" : issuerURL.path)
        let server = try await metadata(URL(string: discovery)!)
        guard let registration = server["registration_endpoint"] as? String, let registrationURL = URL(string: registration),
              let authorization = server["authorization_endpoint"] as? String, let authorizationURL = URL(string: authorization), authorizationURL.scheme == "https",
              let token = server["token_endpoint"] as? String, let tokenURL = URL(string: token), tokenURL.scheme == "https" else {
            throw ZeusProjects.shared.failure("الخدمة لا توفر تسجيلاً تلقائياً. أدخل Client ID في إعدادات OAuth أو استخدم رمز الوصول.")
        }
        let client = try await metadata(registrationURL, body: ["client_name": "ZEUS Browser", "redirect_uris": ["minis-mcp://oauth/callback"],
            "token_endpoint_auth_method": "none", "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"]])
        guard let identifier = client["client_id"] as? String, !identifier.isEmpty else { throw ZeusProjects.shared.failure("لم ترجع الخدمة معرّف عميل OAuth.") }
        var oauth = MCPOAuthConfig()
        oauth.clientId = identifier; oauth.authorizationEndpoint = authorization; oauth.tokenEndpoint = token
        oauth.redirectURI = "minis-mcp://oauth/callback"
        config.oauth = oauth
        MCPStore.shared.update(config)
        try await MCPOAuthController.shared.authorize(server: config.id, oauth: oauth)
    }
    func install(_ plugin: ZeusPlugin) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await ZeusProjects.shared.object("v1/plugins/\(plugin.id)/install", method: "POST")
            struct Response: Decodable { let plugins: [ZeusPlugin] }
            let data = try await ZeusProjects.shared.request("v1/plugins")
            if let installed = try JSONDecoder().decode(Response.self, from: data).plugins.first(where: { $0.id == plugin.id }) { try await sync(installed) }
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
    func syncCloud(identifier: String) async throws {
        struct Response: Decodable { let plugins: [ZeusPlugin] }
        let data = try await ZeusProjects.shared.request("v1/plugins")
        if let plugin = try JSONDecoder().decode(Response.self, from: data).plugins.first(where: { $0.id == identifier }) { try await sync(plugin) }
    }
}

struct ZeusPluginsSettingsView: View {
    @ObservedObject private var store = ZeusPlugins.shared
    var body: some View {
        List {
            Section {
                NavigationLink("إدارة اتصالات MCP وOAuth") { MCPIntegrationsView() }
                NavigationLink("المهارات الافتراضية") { ZeusDefaultSkillsView() }
            }
            Section {
                ForEach(store.plugins) { plugin in
                    NavigationLink { ZeusPluginDetail(plugin: plugin) } label: {
                        VStack(alignment: .leading) {
                            Text(plugin.name)
                            Text(plugin.installed ? "مضاف؛ اختبر الاتصال من إعداداته" : "غير مضاف").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("خادم المشاريع الاختياري") {
                Button("جلب إضافات الخادم") { Task { await store.refreshCloud() } }
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
    @State private var editor = false
    @State private var tools = false
    private var current: ZeusPlugin { store.plugins.first(where: { $0.id == plugin.id }) ?? plugin }
    var body: some View {
        Form {
            if current.mcp_url != nil {
                Section("اتصال مباشر من الجهاز") {
                    Button("تسجيل الدخول المباشر عبر OAuth") {
                        Task {
                            busy = true; defer { busy = false }
                            do { try await store.authorizeDirect(current); error = nil; await store.refresh() }
                            catch { self.error = error.localizedDescription; editor = true }
                        }
                    }.disabled(busy)
                    Button(store.directConfig(current) == nil ? "إضافة الاتصال" : "إعداد الاتصال وOAuth") {
                        do {
                            if store.directConfig(current) == nil { try store.installDirect(current) }
                            editor = true
                        } catch { self.error = error.localizedDescription }
                    }
                    SecureField("رمز وصول الحساب", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("حفظ الاتصال المباشر") {
                        do { try store.installDirect(current, token: token); token = ""; Task { await store.refresh() }; editor = true }
                        catch { self.error = error.localizedDescription }
                    }.disabled(token.isEmpty)
                    if let config = store.directConfig(current) {
                        Text(config.url ?? "").font(.caption).foregroundStyle(.secondary)
                        Button("اختبار الاتصال وجلب الأدوات") { tools = true }
                    }
                }
            }
            Section("خادم المشاريع الاختياري") {
                Text(current.description)
                if let revision = current.revision { Text(String(revision.prefix(12))).font(.caption.monospaced()) }
                Button(current.installed ? "مزامنة اتصال الإضافة" : "تثبيت الإضافة") { Task { await store.install(current) } }.disabled(store.busy)
            }
            if current.mcp_url != nil && !ZeusProjects.shared.endpoint.isEmpty {
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
            .sheet(isPresented: $editor, onDismiss: { Task { await store.refresh() } }) {
                MCPFormSheet(server: store.directConfig(current))
            }
            .sheet(isPresented: $tools) { MCPToolsSheet(serverName: "zeus-direct-" + current.id) }
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
            try await store.syncCloud(identifier: current.id)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
