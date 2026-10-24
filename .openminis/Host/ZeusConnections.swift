import SwiftUI

struct ZeusService: Identifiable {
    let id: String; let name: String; let endpoint: String; let summary: String; let symbol: String
    static let catalog = [
        ZeusService(id: "github", name: "GitHub", endpoint: "https://api.githubcopilot.com/mcp/", summary: "المستودعات والفروع وطلبات الدمج والاختبارات", symbol: "chevron.left.forwardslash.chevron.right"),
        ZeusService(id: "railway", name: "Railway", endpoint: "https://mcp.railway.com", summary: "الخدمات والمشاريع والنشر وسجلات التشغيل", symbol: "tram.fill"),
        ZeusService(id: "vercel", name: "Vercel", endpoint: "https://mcp.vercel.com", summary: "مشاريع الويب والمعاينات وعمليات النشر", symbol: "triangle.fill")
    ]
}
struct ZeusLinkedAccount: Codable, Identifiable, Hashable {
    let id: String; let provider: String
    var label: String; var avatar: String?; var isDefault: Bool; var verified: Bool; var toolCount: Int; var linkedAt: Date
}
struct ZeusOAuthSetupRequired: Error { let config: MCPOAuthConfig }

@MainActor final class ZeusConnections: ObservableObject {
    static let shared = ZeusConnections()
    @Published private(set) var accounts: [ZeusLinkedAccount] = []
    @Published var busy = false
    @Published var error: String?
    private var sessions: [String: String] = [:]
    private var tools: [String: [[String: Any]]] = [:]
    private var refreshTasks: [String: Task<String, Error>] = [:]
    private var listingTasks: [String: Task<[[String: Any]], Error>] = [:]
    private var versions: [String: String] = [:]
    private let key: String
    #if DEBUG
    private var fixtureEndpoint: URL?
    func configureFixture(endpoint: URL, accounts: [ZeusLinkedAccount]) { fixtureEndpoint = endpoint; self.accounts = accounts }
    #endif
    init(storageKey: String = "zeus.integrations.accounts.v2") {
        key = storageKey
        if let data = UserDefaults.standard.data(forKey: key) { accounts = (try? JSONDecoder().decode([ZeusLinkedAccount].self, from: data)) ?? [] }
        if storageKey == "zeus.integrations.accounts.v2" {
            for service in ZeusService.catalog {
                let id = "zeus-direct-" + service.id
                if !accounts.contains(where: { $0.id == id }), var old = MCPStore.shared.servers.first(where: { $0.id == id }), let oauth = old.oauth, MCPOAuthController.tokens(server: id) != nil {
                    accounts.append(ZeusLinkedAccount(id: id, provider: service.id, label: old.note ?? service.name, isDefault: linked(service.id).isEmpty, verified: false, toolCount: 0, linkedAt: Date()))
                    old.enabled = false; MCPStore.shared.update(old)
                    if client(service.id) == nil { try? saveClient(service.id, config: oauth, secret: MCPOAuthController.clientSecret(server: id) ?? "") }
                }
            }
            save()
        }
    }
    private func endpoint(_ account: ZeusLinkedAccount) -> URL {
        #if DEBUG
        if let fixtureEndpoint { return fixtureEndpoint.appendingPathComponent(account.id) }
        #endif
        return URL(string: ZeusService.catalog.first(where: { $0.id == account.provider })!.endpoint)!
    }
    private func save() { if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: key) } }
    func linked(_ provider: String) -> [ZeusLinkedAccount] { accounts.filter { $0.provider == provider } }
    func makeDefault(_ id: String) {
        guard let provider = accounts.first(where: { $0.id == id })?.provider else { return }
        for i in accounts.indices where accounts[i].provider == provider { accounts[i].isDefault = accounts[i].id == id }; save()
    }
    func rename(_ id: String, name: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        accounts[i].label = String(name.prefix(120)); save()
    }
    func disconnect(_ id: String) { listingTasks[id]?.cancel(); refreshTasks[id]?.cancel(); MCPStore.shared.delete(id: id); sessions.removeValue(forKey: id); tools.removeValue(forKey: id); versions.removeValue(forKey: id); accounts.removeAll { $0.id == id }; save() }
    func client(_ provider: String) -> MCPOAuthConfig? {
        if let data = UserDefaults.standard.data(forKey: "zeus.integrations.client." + provider), let config = try? JSONDecoder().decode(MCPOAuthConfig.self, from: data) { return config }
        if provider == "vercel" {
            // Public native client registered for ZEUS itself on 2026-10-23.
            // This identifier is not a token or secret and carries no account.
            var config = MCPOAuthConfig(); config.clientId = "cl_WbdtcToDrMR4ZHvXLGAmbfoYCsQjMeS8"
            config.authorizationEndpoint = "https://vercel.com/oauth/authorize"; config.tokenEndpoint = "https://api.vercel.com/login/oauth/token"
            config.redirectURI = "http://127.0.0.1:18467/callback"; config.scopes = "openid profile email offline_access"; config.zeusResource = "https://mcp.vercel.com/"; return config
        }
        return nil
    }
    func saveClient(_ provider: String, config: MCPOAuthConfig, secret: String) throws {
        guard !config.clientId.isEmpty, URL(string: config.authorizationEndpoint)?.scheme == "https", URL(string: config.tokenEndpoint)?.scheme == "https" else { throw ZeusPatch.failure("أكمل بيانات تطبيق OAuth الخاص بـZEUS.") }
        UserDefaults.standard.set(try JSONEncoder().encode(config), forKey: "zeus.integrations.client." + provider)
        MCPOAuthController.setClientSecret(secret, server: "zeus-client-" + provider)
    }
    private func metadata(_ url: URL, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw ZeusPatch.failure("عنوان OAuth غير آمن.") }
        var request = URLRequest(url: url); request.timeoutInterval = 30
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ZeusPatch.failure("تعذر اكتشاف إعدادات OAuth لدى الخدمة.") }
        return object
    }
    func discover(_ service: ZeusService) async throws -> MCPOAuthConfig {
        if let saved = client(service.id) { return saved }
        let endpoint = URL(string: service.endpoint)!
        var probe = URLRequest(url: endpoint); probe.timeoutInterval = 15
        let (_, response) = try await URLSession.shared.data(for: probe)
        let challenge = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
        let regex = try NSRegularExpression(pattern: "resource_metadata=\"([^\"]+)\"")
        var resourceURL = URL(string: "https://" + endpoint.host! + "/.well-known/oauth-protected-resource")!
        if let match = regex.firstMatch(in: challenge, range: NSRange(challenge.startIndex..., in: challenge)), let range = Range(match.range(at: 1), in: challenge), let advertised = URL(string: String(challenge[range])) { resourceURL = advertised }
        let resource = try await metadata(resourceURL)
        guard let issuerString = (resource["authorization_servers"] as? [String])?.first, let issuer = URL(string: issuerString), issuer.scheme == "https", let host = issuer.host else { throw ZeusPatch.failure("الخدمة لم تعلن خادم OAuth صالحاً.") }
        let server = try await metadata(URL(string: "https://" + host + "/.well-known/oauth-authorization-server" + (issuer.path == "/" ? "" : issuer.path))!)
        guard let authorization = server["authorization_endpoint"] as? String, let token = server["token_endpoint"] as? String else { throw ZeusPatch.failure("بيانات OAuth غير مكتملة لدى الخدمة.") }
        var config = MCPOAuthConfig(); config.authorizationEndpoint = authorization; config.tokenEndpoint = token; config.redirectURI = "http://127.0.0.1:18467/callback"
        config.scopes = (resource["scopes_supported"] as? [String])?.joined(separator: " ")
        config.zeusResource = resource["resource"] as? String
        if service.id == "railway" { config.scopes = "openid profile email offline_access workspace:member" }
        guard let registration = server["registration_endpoint"] as? String, let address = URL(string: registration) else { throw ZeusOAuthSetupRequired(config: config) }
        let result: [String: Any]
        do { result = try await metadata(address, body: ["client_name": "ZEUS Browser", "redirect_uris": [config.redirectURI!], "token_endpoint_auth_method": "none", "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"], "scope": config.scopes ?? ""]) }
        catch { throw ZeusOAuthSetupRequired(config: config) }
        guard let id = result["client_id"] as? String, !id.isEmpty else { throw ZeusPatch.failure("الخدمة لم تُرجع معرّف تطبيق OAuth.") }
        config.clientId = id; try saveClient(service.id, config: config, secret: result["client_secret"] as? String ?? ""); return config
    }
    func connect(_ service: ZeusService) async throws {
        guard !busy else { return }; busy = true; defer { busy = false }
        var oauth = try await discover(service); oauth.prompt = "select_account"
        if oauth.zeusResource == nil { oauth.zeusResource = service.id == "vercel" ? "https://mcp.vercel.com/" : service.endpoint }
        let id = "zeus-direct-" + service.id + "-" + UUID().uuidString.lowercased()
        var server = try JSONDecoder().decode(MCPServerConfig.self, from: JSONSerialization.data(withJSONObject: ["id": id, "note": service.name, "enabled": false, "url": service.endpoint]))
        server.oauth = oauth; MCPStore.shared.add(server)
        if let secret = MCPOAuthController.clientSecret(server: "zeus-client-" + service.id) { MCPOAuthController.setClientSecret(secret, server: id) }
        do {
            if service.id == "github" {
                let tokens = try await ZeusGitHubAuthorization.shared.authorize(oauth)
                try MCPOAuthController.storeTokensForZeus(tokens, server: id, oauth: oauth)
            } else { try await MCPOAuthController.shared.authorize(server: id, oauth: oauth) }
        } catch { MCPStore.shared.delete(id: id); throw error }
        accounts.append(ZeusLinkedAccount(id: id, provider: service.id, label: service.name + " " + String(linked(service.id).count + 1), isDefault: linked(service.id).isEmpty, verified: false, toolCount: 0, linkedAt: Date()))
        save(); await identity(id)
        do { _ = try await listTools(id); error = nil } catch { self.error = error.localizedDescription }
    }
    func account(_ id: String?, provider: String? = nil) throws -> ZeusLinkedAccount {
        if let id, !id.isEmpty {
            guard let account = accounts.first(where: { $0.id == id }), provider == nil || account.provider == provider else { throw ZeusPatch.failure("account_id غير موجود أو لا ينتمي للخدمة المحددة. لم يُستبدل بحساب آخر.") }
            return account
        }
        let candidates = accounts.filter { provider == nil || $0.provider == provider }
        if candidates.count == 1 { return candidates[0] }
        if provider != nil, let selected = candidates.first(where: \.isDefault) { return selected }
        throw ZeusPatch.failure("اختر account_id من integration_accounts؛ لا يمكن تخمين الحساب المقصود.")
    }
    private func bearer(_ id: String) async throws -> String {
        #if DEBUG
        if fixtureEndpoint != nil { return "fixture-" + id }
        #endif
        if let task = refreshTasks[id] { return try await task.value }
        guard let oauth = MCPStore.shared.servers.first(where: { $0.id == id })?.oauth else { throw ZeusPatch.failure("الحساب غير مربوط عبر OAuth.") }
        let task = Task { @MainActor in try await MCPOAuthController.refreshAccessTokenForZeus(server: id, oauth: oauth) }
        refreshTasks[id] = task; defer { refreshTasks.removeValue(forKey: id) }; return try await task.value
    }
    func githubAccessToken(_ id: String) async throws -> String {
        _ = try account(id, provider: "github")
        return try await bearer(id)
    }
    private func rpc(_ id: String, method: String, parameters: [String: Any], initialize: Bool = false) async throws -> [String: Any] {
        let account = try account(id), service = ZeusService.catalog.first(where: { $0.id == account.provider })!
        var request = URLRequest(url: endpoint(account)); request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("Bearer " + (try await bearer(id)), forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !initialize { request.setValue(versions[id] ?? "2025-03-26", forHTTPHeaderField: "MCP-Protocol-Version") }
        if let session = sessions[id] { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        let requestID = UUID().uuidString
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": requestID, "method": method, "params": parameters])
        let transport = URLSession(configuration: .ephemeral); defer { transport.invalidateAndCancel() }
        let (bytes, response) = try await transport.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            sessions.removeValue(forKey: id); tools.removeValue(forKey: id)
            if let i = accounts.firstIndex(where: { $0.id == id }) { accounts[i].verified = false; save() }
            throw ZeusPatch.failure("تعذر اتصال \(service.name) بالحساب المحدد (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). أعد الربط عند انتهاء التفويض.")
        }
        if initialize, let session = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessions[id] = session }
        var json = "", event = ""
        for try await line in bytes.lines {
            guard json.count + event.count + line.count <= 4000000 else { throw ZeusPatch.failure("رد MCP تجاوز حد الذاكرة؛ افتح النتيجة عبر أداة الملف أو اطلب نطاقاً أصغر.") }
            if http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
                if line.hasPrefix("data:") { event += String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) + "\n" }
                if line.hasPrefix("data:"), !event.isEmpty { json = event }
                else if line.isEmpty { json = event; event = "" }
                else { continue }
            } else { json += line }
            if let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                event = ""; json = ""
                guard object["id"] as? String == requestID else { continue }
                if let error = object["error"] as? [String: Any] { throw ZeusPatch.failure("MCP: " + String((error["message"] as? String ?? "خطأ الأداة").prefix(1000))) }
                return object["result"] as? [String: Any] ?? [:]
            }
        }
        throw ZeusPatch.failure("انقطع رد MCP قبل وصول نتيجة كاملة. لم تُعد الأداة تلقائياً؛ افحص الحالة قبل تكرار أي تعديل.")
    }
    private func initialize(_ id: String) async throws {
        if tools[id] != nil { return }
        let initialized = try await rpc(id, method: "initialize", parameters: ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "ZEUS Browser", "version": "3.0"]], initialize: true)
        guard let version = initialized["protocolVersion"] as? String, ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(version) else { throw ZeusPatch.failure("الخدمة اقترحت إصدار MCP غير مدعوم.") }
        versions[id] = version
        let account = try account(id), service = ZeusService.catalog.first(where: { $0.id == account.provider })!
        var request = URLRequest(url: endpoint(account)); request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("Bearer " + (try await bearer(id)), forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept"); request.setValue(versions[id], forHTTPHeaderField: "MCP-Protocol-Version")
        if let session = sessions[id] { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ZeusPatch.failure("لم يكتمل بدء اتصال MCP.") }
    }
    func listTools(_ id: String, refresh: Bool = false) async throws -> [[String: Any]] {
        if let task = listingTasks[id] { return try await task.value }
        let task = Task { @MainActor in try await self.loadTools(id, refresh: refresh) }
        listingTasks[id] = task; defer { listingTasks.removeValue(forKey: id) }; return try await task.value
    }
    private func loadTools(_ id: String, refresh: Bool) async throws -> [[String: Any]] {
        if refresh { tools.removeValue(forKey: id); sessions.removeValue(forKey: id) }
        if let cached = tools[id] { return cached }; try await initialize(id)
        var collected: [[String: Any]] = [], cursor: String?, cursors = Set<String>()
        repeat {
            let result = try await rpc(id, method: "tools/list", parameters: cursor.map { ["cursor": $0] } ?? [:])
            collected += (result["tools"] as? [[String: Any]] ?? []).filter { $0["name"] is String && $0["inputSchema"] is [String: Any] }; cursor = result["nextCursor"] as? String
            guard collected.count <= 1000 else { throw ZeusPatch.failure("تجاوز عدد أدوات الخدمة الحد المسموح.") }
            if let cursor { guard cursors.insert(cursor).inserted, cursors.count < 100 else { throw ZeusPatch.failure("الخدمة أعادت مؤشر صفحات متكرراً؛ لم يُكرر الطلب بلا نهاية.") } }
        } while cursor != nil
        tools[id] = collected
        if let index = accounts.firstIndex(where: { $0.id == id }) { accounts[index].verified = true; accounts[index].toolCount = collected.count; save() }
        return collected
    }
    func call(_ id: String, name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let definitions = try await listTools(id)
        guard let definition = definitions.first(where: { $0["name"] as? String == name }) else { throw ZeusPatch.failure("اسم الأداة غير موجود في هذا الحساب؛ اقرأ integration_tools أولاً.") }
        if let schema = definition["inputSchema"] as? [String: Any] { try ZeusAgentSchemas.validate(arguments, schema: schema) }
        return try await rpc(id, method: "tools/call", parameters: ["name": name, "arguments": arguments])
    }
    func isReadOnly(_ id: String, tool: String) -> Bool { ((tools[id]?.first(where: { $0["name"] as? String == tool })?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool) == true }
    func accountSummary() -> [[String: Any]] { accounts.map { ["account_id": $0.id, "provider": $0.provider, "name": $0.label, "default": $0.isDefault, "verified": $0.verified, "tools": $0.toolCount] } }
    private func identity(_ id: String) async {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }; let provider = accounts[index].provider
        guard let url = URL(string: provider == "github" ? "https://api.github.com/user" : provider == "vercel" ? "https://api.vercel.com/login/oauth/userinfo" : "https://backboard.railway.com/oauth/me"), let token = try? await bearer(id) else { return }
        var request = URLRequest(url: url); request.timeoutInterval = 20; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200, var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let user = object["user"] as? [String: Any] { object = user }; if let me = (object["data"] as? [String: Any])?["me"] as? [String: Any] { object = me }
        guard let current = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[current].label = object["login"] as? String ?? object["email"] as? String ?? object["preferred_username"] as? String ?? object["name"] as? String ?? accounts[current].label
        accounts[current].avatar = object["avatar_url"] as? String ?? object["picture"] as? String
        if let configIndex = MCPStore.shared.servers.firstIndex(where: { $0.id == id }) { var config = MCPStore.shared.servers[configIndex]; config.note = provider + " · " + accounts[current].label; MCPStore.shared.update(config) }; save()
    }
}

struct ZeusPluginsSettingsView: View {
    @ObservedObject private var connections = ZeusConnections.shared
    var body: some View {
        List {
            Section { ForEach(ZeusService.catalog) { service in NavigationLink { ZeusServiceDetail(service: service) } label: {
                HStack(spacing: 14) { Image(systemName: service.symbol).font(.title2).frame(width: 42, height: 42).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)); VStack(alignment: .leading, spacing: 4) { Text(service.name).font(.headline); Text("\(connections.linked(service.id).count) حساب مرتبط").font(.caption).foregroundStyle(.secondary) } }.padding(.vertical, 6)
            } } }
            Section { NavigationLink("المهارات الافتراضية") { ZeusDefaultSkillsView() }; NavigationLink("اتصالات MCP المخصصة") { MCPIntegrationsView() } }
        }.navigationTitle("الإضافات").preferredColorScheme(.dark).environment(\.layoutDirection, .rightToLeft)
    }
}
private struct ZeusServiceDetail: View {
    let service: ZeusService
    @ObservedObject private var connections = ZeusConnections.shared
    @State private var error: String?
    @State private var setup: MCPOAuthConfig?
    @State private var showSetup = false
    @ObservedObject private var githubAuthorization = ZeusGitHubAuthorization.shared
    var body: some View {
        List {
            Section { VStack(alignment: .leading, spacing: 14) { Image(systemName: service.symbol).font(.largeTitle).padding(12).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14)); Text(service.name).font(.largeTitle.bold()); Text(service.summary).foregroundStyle(.secondary) }.padding(.vertical, 12) }
            Section("الحسابات المرتبطة") {
                ForEach(connections.linked(service.id)) { account in NavigationLink { ZeusAccountDetail(accountID: account.id) } label: {
                    HStack(spacing: 12) {
                        if let avatar = account.avatar, let url = URL(string: avatar), url.scheme == "https" { AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.crop.circle.fill") }.frame(width: 42, height: 42).clipShape(Circle()) }
                        else { Image(systemName: "person.crop.circle.fill").font(.largeTitle).foregroundStyle(.secondary) }
                        VStack(alignment: .leading, spacing: 4) { Text(account.label).lineLimit(1); Text(account.isDefault ? "الحساب الافتراضي" : account.verified ? "متصل" : "يحتاج اختبار الاتصال").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 4)
                } }
                Button { Task { await connect() } } label: { Label("ربط حساب آخر", systemImage: "plus.circle.fill") }.disabled(connections.busy)
            }
            if let error = error ?? connections.error { Section { Text(error).foregroundStyle(.red) } }
        }.navigationTitle(service.name)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { setup = connections.client(service.id); showSetup = true } label: { Image(systemName: "gearshape") } } }
            .sheet(isPresented: $showSetup) { ZeusOAuthClientSetup(service: service, initial: setup) }
            .sheet(item: service.id == "github" ? $githubAuthorization.presentation : .constant(nil), onDismiss: { githubAuthorization.cancel() }) { ZeusGitHubAuthorizationView(authorization: $0) }
    }
    private func connect() async { do { try await connections.connect(service); error = nil } catch let required as ZeusOAuthSetupRequired { setup = required.config; showSetup = true } catch { self.error = error.localizedDescription } }
}
private struct ZeusAccountDetail: View {
    let accountID: String
    @ObservedObject private var connections = ZeusConnections.shared
    @State private var tools: [[String: Any]] = []
    @State private var error: String?
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            if let account = connections.accounts.first(where: { $0.id == accountID }) {
                Section("الحساب") {
                    TextField("اسم الحساب", text: $name).onSubmit { connections.rename(accountID, name: name) }
                    Button("تعيين الحساب الافتراضي") { connections.makeDefault(accountID) }.disabled(account.isDefault)
                    Button("تحديث الاتصال والأدوات") { Task { await refresh() } }
                    Button("إلغاء ربط الحساب", role: .destructive) { connections.disconnect(accountID); dismiss() }
                }
                Section("إجراءات القراءة") { ForEach(tools.filter { (($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool) == true }, id: \.zeusToolName) { tool in toolRow(tool) } }
                Section("إجراءات التعديل والأدوات الأخرى") { ForEach(tools.filter { (($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool) != true }, id: \.zeusToolName) { tool in toolRow(tool) } }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("الحساب والأدوات").task { name = connections.accounts.first(where: { $0.id == accountID })?.label ?? ""; await refresh() }
    }
    private func toolRow(_ tool: [String: Any]) -> some View {
        NavigationLink(tool.zeusToolName) { ScrollView { VStack(alignment: .leading, spacing: 16) { Text(tool["description"] as? String ?? ""); Text((try? ZeusAgentHarness.json(tool["inputSchema"] ?? [:])) ?? "").font(.caption.monospaced()).textSelection(.enabled) }.padding() }.navigationTitle(tool.zeusToolName) }
    }
    private func refresh() async { do { tools = try await connections.listTools(accountID, refresh: true); error = nil } catch { self.error = error.localizedDescription } }
}
private struct ZeusOAuthClientSetup: View {
    let service: ZeusService; let initial: MCPOAuthConfig?
    @State private var client = ""; @State private var secret = ""; @State private var auth = ""; @State private var token = ""; @State private var scopes = ""; @State private var redirect = "http://127.0.0.1:18467/callback"; @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack { Form {
            Section("تطبيق OAuth الخاص بـZEUS") {
                if service.id == "github" {
                    Link("تسجيل تطبيق ZEUS لدى GitHub", destination: URL(string: "https://github.com/settings/applications/new?oauth_application%5Bname%5D=ZEUS%20Browser&oauth_application%5Burl%5D=https%3A%2F%2Fgithub.com%2Fcobrapk8ggggggg-tech%2Fzeus&oauth_application%5Bcallback_url%5D=http%3A%2F%2F127.0.0.1%3A18467%2Fcallback")!)
                    Text("فعّل Enable Device Flow في إعدادات التطبيق لدى GitHub. سيتم الربط برمز تحقق عبر HTTPS، دون عنوان رجوع محلي أو Client Secret.").font(.caption).foregroundStyle(.secondary)
                }
                if service.id == "railway" {
                    Link("تسجيل تطبيق ZEUS في Railway", destination: URL(string: "https://railway.com/dashboard")!)
                    Text("إعدادات مساحة العمل ← Developer ← New OAuth App ← Native. عنوان العودة أدناه. التسجيل التلقائي معطّل حالياً لدى Railway.").font(.caption).foregroundStyle(.secondary)
                }
                TextField("Client ID", text: $client).textInputAutocapitalization(.never).autocorrectionDisabled()
                if service.id != "railway" && service.id != "github" { SecureField("Client Secret عند اشتراطه", text: $secret).textInputAutocapitalization(.never).autocorrectionDisabled() }
                if service.id != "github" { Text("http://127.0.0.1:18467/callback").font(.caption.monospaced()).textSelection(.enabled).environment(\.layoutDirection, .leftToRight) }
            }
            DisclosureGroup("إعدادات متقدمة") {
                TextField("Authorization URL", text: $auth).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Token URL", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("الصلاحيات", text: $scopes).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Callback URL", text: $redirect).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("إعداد OAuth").toolbar { ToolbarItem(placement: .confirmationAction) { Button("حفظ") { save() } }; ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } } }
            .onAppear { client = initial?.clientId ?? ""; auth = initial?.authorizationEndpoint ?? (service.id == "github" ? "https://github.com/login/oauth/authorize" : "https://backboard.railway.com/oauth/auth"); token = initial?.tokenEndpoint ?? (service.id == "github" ? "https://github.com/login/oauth/access_token" : "https://backboard.railway.com/oauth/token"); scopes = service.id == "github" ? "repo read:org user:email workflow" : initial?.scopes ?? "workspace:member"; redirect = initial?.redirectURI?.hasPrefix("http") == true ? initial!.redirectURI! : "http://127.0.0.1:18467/callback" }
        }
    }
    private func save() { do { var config = MCPOAuthConfig(); config.clientId = client; config.authorizationEndpoint = auth; config.tokenEndpoint = token; config.scopes = scopes; config.redirectURI = redirect; try ZeusConnections.shared.saveClient(service.id, config: config, secret: secret); dismiss() } catch { self.error = error.localizedDescription } }
}
private extension Dictionary where Key == String, Value == Any { var zeusToolName: String { self["name"] as? String ?? "" } }
