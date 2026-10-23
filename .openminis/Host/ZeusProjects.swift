import SwiftUI
import Security

struct ZeusProject: Decodable, Identifiable {
    let id: String
    let name: String
    let kind: String
    let branch: String
    let model: String
}
struct ZeusProjectTask: Decodable, Identifiable {
    let id: String
    let project_id: String
    let prompt: String
    let status: String
    let error: String?
    var title: String { String(prompt.prefix(100)) }
    var stateTitle: String {
        ["queued": "في الانتظار", "running": "جارٍ التنفيذ", "waiting_user": "ينتظر إجابتك", "completed": "اكتمل التحقق", "needs_verification": "ينتظر إعداد التحقق", "failed": "تعذر الإكمال", "cancelled": "أُلغيت", "interrupted": "متوقفة؛ يمكن استئنافها", "exhausted": "انتهت الميزانية", "cancelling": "جارٍ الإلغاء"][status] ?? status
    }
}

@MainActor final class ZeusProjects: ObservableObject {
    static let shared = ZeusProjects()
    @Published var projects: [ZeusProject] = []
    @Published var tasks: [ZeusProjectTask] = []
    @Published var connected = false
    @Published var error: String?
    var endpoint: String {
        get { UserDefaults.standard.string(forKey: "zeus.projects.endpoint") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "zeus.projects.endpoint"); connected = false }
    }
    var token: String {
        get {
            var query = Self.keyQuery
            query[kSecReturnData as String] = true
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            let data = Data(newValue.utf8)
            let status = SecItemUpdate(Self.keyQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var query = Self.keyQuery
                query[kSecValueData as String] = data
                query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                SecItemAdd(query as CFDictionary, nil)
            }
        }
    }
    private static var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "tools.zeus.project-service", kSecAttrAccount as String: "connection-token"]
    }
    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard var url = URL(string: endpoint), url.scheme == "https" || ["localhost", "127.0.0.1", "::1"].contains(url.host ?? ""), url.user == nil, url.password == nil, !token.isEmpty else {
            throw failure("أكمل ربط خادم المشاريع بعنوان HTTPS ورمز الربط أولًا.")
        }
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        for component in parts[0].split(separator: "/") { url.appendPathComponent(String(component)) }
        if parts.count == 2, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = parts[1]
            guard let selected = components.url else { throw failure("استعلام غير صالح.") }
            url = selected
        }
        var request = URLRequest(url: url, timeoutInterval: 180)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw failure(detail ?? "تعذر الاتصال بخادم المشاريع.")
        }
        return data
    }
    func object(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        let data = try await request(path, method: method, body: body)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("استجابة خادم غير صالحة.") }
        return value
    }
    func refresh() async {
        do {
            _ = try await object("v1/capabilities")
            struct Projects: Decodable { let projects: [ZeusProject] }
            struct Tasks: Decodable { let tasks: [ZeusProjectTask] }
            projects = try JSONDecoder().decode(Projects.self, from: await request("v1/projects")).projects
            tasks = try JSONDecoder().decode(Tasks.self, from: await request("v1/tasks")).tasks
            connected = true; error = nil
        } catch { self.error = error.localizedDescription; connected = false }
    }
    func failure(_ text: String) -> NSError { NSError(domain: "ZeusProjects", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

struct ZeusProjectsSettingsView: View {
    @ObservedObject private var service = ZeusProjects.shared
    @State private var endpoint = ZeusProjects.shared.endpoint
    @State private var token = ZeusProjects.shared.token
    @State private var showCreate = false
    @State private var capabilities: [String: Any] = [:]
    var body: some View {
        List {
            Section("اتصال التنفيذ البعيد") {
                TextField("عنوان الخادم HTTPS", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("رمز ربط Zeus", text: $token).textInputAutocapitalization(.never)
                Button("حفظ واختبار الاتصال") {
                    service.endpoint = endpoint; service.token = token
                    Task { await service.refresh(); capabilities = (try? await service.object("v1/capabilities")) ?? [:] }
                }
                if service.connected {
                    Label("متصل", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    LabeledContent("محرك التنفيذ", value: capabilities["codex_version"] as? String ?? "Codex")
                    LabeledContent("مصادقة النموذج", value: capabilities["auth_configured"] as? Bool == true ? "مُعدّة" : "تحتاج إعدادًا على الخادم")
                }
                if let error = service.error { Text(error).foregroundStyle(.red) }
                NavigationLink("حساب محرك Codex والنماذج") { ZeusCodexAccountView() }.disabled(!service.connected)
            }
            Section("المشاريع") {
                ForEach(service.projects) { project in
                    NavigationLink { ZeusProjectDetail(project: project) } label: {
                        VStack(alignment: .leading) { Text(project.name); Text(project.branch).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Button("مشروع جديد", systemImage: "plus") { showCreate = true }.disabled(!service.connected)
            }
            Section("مهام محفوظة") {
                ForEach(service.tasks) { task in
                    NavigationLink { ZeusProjectTaskDetail(taskID: task.id) } label: {
                        VStack(alignment: .leading) { Text(task.title).lineLimit(2); Text(task.stateTitle).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }.navigationTitle("المشاريع والبيئات")
        .task { if !service.endpoint.isEmpty { await service.refresh() } }
        .refreshable { await service.refresh() }
        .sheet(isPresented: $showCreate) { NavigationStack { ZeusNewProject() } }
    }
}

private struct ZeusNewProject: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var repository = ""
    @State private var kind = "web"
    @State private var checks = ""
    @State private var error: String?
    @State private var saving = false
    var body: some View {
        Form {
            TextField("اسم المشروع", text: $name)
            TextField("رابط المستودع (اختياري)", text: $repository).textInputAutocapitalization(.never)
            Picker("نوع المشروع", selection: $kind) { Text("موقع ويب").tag("web"); Text("تطبيق iOS").tag("ios"); Text("تطبيق Android").tag("android"); Text("عام").tag("generic") }
            Section("أوامر التحقق، كل أمر في سطر") { TextEditor(text: $checks).frame(minHeight: 90).font(.system(.body, design: .monospaced)) }
            if let error { Text(error).foregroundStyle(.red) }
            Button("إنشاء مساحة المشروع") {
                saving = true
                Task {
                    do {
                        _ = try await ZeusProjects.shared.object("v1/projects", method: "POST", body: ["name": name, "repo_url": repository, "kind": kind, "verify_commands": checks.split(separator: "\n").map(String.init)])
                        await ZeusProjects.shared.refresh(); dismiss()
                    } catch { self.error = error.localizedDescription }
                    saving = false
                }
            }.disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.navigationTitle("مشروع جديد").toolbar { Button("إلغاء") { dismiss() } }
    }
}

private struct ZeusProjectDetail: View {
    let project: ZeusProject
    @State private var prompt = ""
    @State private var acceptance = ""
    @State private var error: String?
    @State private var running = false
    @State private var started: String?
    var body: some View {
        Form {
            Section("المهمة") { TextEditor(text: $prompt).frame(minHeight: 150) }
            Section("نتيجة القبول المطلوبة") { TextEditor(text: $acceptance).frame(minHeight: 90) }
            Button("بدء التنفيذ المستقل") {
                running = true
                Task {
                    do {
                        let result = try await ZeusProjects.shared.object("v1/projects/\(project.id)/tasks", method: "POST", body: ["prompt": prompt, "acceptance": acceptance, "permission_mode": ZeusToolPermissions.shared.mode.rawValue, "idempotency_key": UUID().uuidString])
                        started = result["id"] as? String
                    } catch { self.error = error.localizedDescription }
                    running = false
                }
            }.disabled(running || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let started { NavigationLink("متابعة المهمة") { ZeusProjectTaskDetail(taskID: started) } }
            if let error { Text(error).foregroundStyle(.red) }
            NavigationLink("ملفات المشروع والفروق") { ZeusProjectFiles(projectID: project.id) }
        }.navigationTitle(project.name)
    }
}

private struct ZeusProjectFiles: View {
    let projectID: String
    @State private var output = ""
    var body: some View {
        ScrollView { Text(output).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding().textSelection(.enabled) }
            .navigationTitle("تغييرات المشروع").task {
                do { let value = try await ZeusProjects.shared.object("v1/projects/\(projectID)/diff"); output = (value["status"] as? String ?? "") + "\n" + (value["diff"] as? String ?? "") }
                catch { output = error.localizedDescription }
            }
    }
}

struct ZeusProjectTaskDetail: View {
    let taskID: String
    @State private var current: ZeusProjectTask?
    @StateObject private var message = ChatMessage(role: .assistant, content: "")
    @State private var blocks: [AssistantBlock] = []
    @State private var cursor = 0
    @State private var textByID: [String: AssistantBlock] = [:]
    @State private var approvals: [[String: Any]] = []
    @State private var error: String?
    @State private var detail: AssistantBlock?
    @State private var highlighted: UUID?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let current { Text(current.stateTitle).font(.headline); if let failure = current.error { Text(failure).foregroundStyle(.red) } }
                ForEach(blocks) { block in
                    AssistantBlockView(block: block, message: message, isActiveMessage: current?.status == "running", highlightedBlockId: $highlighted, detailBlock: $detail)
                }
                ForEach(approvals, id: \.zeusID) { approval in ZeusRemoteApprovalCard(approval: approval) { await refreshApprovals() } }
                if let error { Text(error).foregroundStyle(.red) }
            }.padding()
        }.navigationTitle("مهمة Zeus")
        .toolbar {
            Button("استئناف") { Task { await control("resume") } }
            Button("إلغاء", role: .destructive) { Task { await control("cancel") } }
        }
        .sheet(item: $detail) { block in ToolLiveSheet(toolBlocks: blocks, currentIdx: blocks.firstIndex(where: { $0.id == block.id }) ?? 0) }
        .task {
            while !Task.isCancelled {
                do {
                    let service = ZeusProjects.shared
                    // Query uses URLComponents through the client helper.
                    let value = try await service.object("v1/tasks/\(taskID)/events?after=\(cursor)")
                    if let task = value["task"] { current = try JSONDecoder().decode(ZeusProjectTask.self, from: JSONSerialization.data(withJSONObject: task)) }
                    for event in value["events"] as? [[String: Any]] ?? [] { ingest(event) }
                    cursor = value["cursor"] as? Int ?? cursor
                    await refreshApprovals()
                    error = nil
                } catch { self.error = error.localizedDescription }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    private func ingest(_ event: [String: Any]) {
        let kind = event["kind"] as? String ?? ""
        let data = event["data"] as? [String: Any] ?? [:]
        let item = data["item"] as? [String: Any] ?? data
        let id = item["id"] as? String ?? data["itemId"] as? String ?? "event-\(event["seq"] ?? 0)"
        if kind == "item/agentMessage/delta" {
            let block = textByID[id] ?? AssistantBlock(kind: .text, content: "")
            if textByID[id] == nil { textByID[id] = block; blocks.append(block) }
            block.content += data["delta"] as? String ?? ""
        } else if kind == "item/started" || kind == "item/completed" {
            let type = item["type"] as? String ?? ""
            if type == "agentMessage" {
                let block = textByID[id] ?? AssistantBlock(kind: .text, content: "")
                if textByID[id] == nil { textByID[id] = block; blocks.append(block) }
                if let text = item["text"] as? String, !text.isEmpty { block.content = text }
            } else {
                let title = item["command"] as? String ?? item["tool"] as? String ?? type
                let block = textByID[id] ?? AssistantBlock(kind: .shellTool(command: title), content: "")
                if textByID[id] == nil { textByID[id] = block; blocks.append(block) }
                block.content = item["aggregatedOutput"] as? String ?? String(data: (try? JSONSerialization.data(withJSONObject: item, options: [.prettyPrinted, .sortedKeys])) ?? Data(), encoding: .utf8) ?? ""
                if kind == "item/completed" {
                    let failed = (item["exitCode"] as? Int).map { $0 != 0 } ?? (item["status"] as? String == "failed")
                    block.toolStatus = failed ? .failed(message: "تعذر تنفيذ الأداة") : .success
                } else { block.toolStatus = .running }
            }
        } else if kind == "item/commandExecution/outputDelta", let block = textByID[id] {
            block.content += data["delta"] as? String ?? ""
        } else if kind == "verification" {
            let code = data["exit_code"] as? Int ?? -1
            blocks.append(AssistantBlock(kind: .shellTool(command: data["command"] as? String ?? "تحقق"), content: data["output"] as? String ?? "", toolStatus: code == 0 ? .success : .failed(message: "رمز الخروج \(code)")))
        }
    }
    private func refreshApprovals() async {
        let value = try? await ZeusProjects.shared.object("v1/approvals")
        approvals = (value?["approvals"] as? [[String: Any]] ?? []).filter { $0["task_id"] as? String == taskID }
    }
    private func control(_ action: String) async {
        do { _ = try await ZeusProjects.shared.object("v1/tasks/\(taskID)/\(action)", method: "POST"); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

extension Dictionary where Key == String, Value == Any { var zeusID: String { self["id"] as? String ?? "" } }

private struct ZeusRemoteApprovalCard: View {
    let approval: [String: Any]
    let answered: () async -> Void
    @State private var choice: Bool?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("موافقة على إجراء", systemImage: "hand.raised.fill").font(.headline)
            let details = approval["details"] as? [String: Any] ?? [:]
            Text(details["reason"] as? String ?? details["command"] as? String ?? "راجع الإجراء الذي يطلبه وكيل المشروع.")
            Text(String(data: (try? JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys])) ?? Data(), encoding: .utf8) ?? "").font(.caption.monospaced()).lineLimit(12).textSelection(.enabled)
            ForEach([true, false], id: \.self) { value in
                Button { choice = value } label: { Label(value ? "السماح هذه المرة" : "رفض الإجراء", systemImage: choice == value ? "largecircle.fill.circle" : "circle") }.buttonStyle(.plain)
            }
            Button("تأكيد الاختيار") {
                Task {
                    do { _ = try await ZeusProjects.shared.object("v1/approvals/\(approval.zeusID)", method: "POST", body: ["allowed": choice == true]); await answered() }
                    catch { self.error = error.localizedDescription }
                }
            }.buttonStyle(.borderedProminent).disabled(choice == nil)
            if let error { Text(error).foregroundStyle(.red) }
        }.padding().background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

@MainActor enum ZeusProjectTools {
    static let definitions: [AgentToolDefinition] = [
        .init(name: "zeus_project_list", description: "List real remote projects and saved tasks; no IDs need to be invented. ZEUS Browser's project worker is independent of the phone and keeps running when iOS disconnects.", parameters: [:], required: []),
        .init(name: "zeus_project_create", description: "Create a persistent isolated Git workspace on the configured ZEUS project worker. Optionally clone an HTTPS repository. Provide meaningful verification commands as a JSON string array; do not weaken them to make failures pass.", parameters: ["name": .init(type: .string, description: "Project name"), "repo_url": .init(type: .string, description: "Optional HTTPS repository URL"), "kind": .init(type: .string, description: "Project kind", enumValues: ["generic", "web", "ios", "android"]), "verify_commands": .init(type: .string, description: "JSON array of shell commands that verify the intended outcome")], required: ["name"]),
        .init(name: "zeus_project_run", description: "Delegate a complete coding task to the actual remote Codex engine. It has Git/files/shell, installed skills and MCP integrations. Supply acceptance criteria. Start returns a durable task_id; monitor zeus_project_status/events rather than claiming completion. Linux cannot execute Xcode: use a configured Mac or GitHub Actions. Independent checks control completed versus needs_verification.", parameters: ["project_id": .init(type: .string, description: "Existing project ID from list/create"), "prompt": .init(type: .string, description: "Complete implementation request and constraints"), "acceptance": .init(type: .string, description: "Verifiable outcomes"), "max_seconds": .init(type: .integer, description: "Task time budget, 60 to 86400 seconds")], required: ["project_id", "prompt"]),
        .init(name: "zeus_project_status", description: "Inspect a saved coding task's actual state and error. Only completed means independent verification succeeded; queued/running/needs_verification are not success.", parameters: ["task_id": .init(type: .string, description: "Task ID")], required: ["task_id"]),
        .init(name: "zeus_project_events", description: "Read actual streamed coding tool activity, outputs and verification reports, from a durable event cursor. Use after to avoid rereading old output.", parameters: ["task_id": .init(type: .string, description: "Task ID"), "after": .init(type: .integer, description: "Last received event seq, initially zero")], required: ["task_id"]),
        .init(name: "zeus_project_control", description: "Cancel or explicitly resume a saved task from its Codex thread and current files. Inspect an interrupted task before resuming; uncertain writes are not automatically replayed.", parameters: ["task_id": .init(type: .string, description: "Task ID"), "action": .init(type: .string, description: "Action", enumValues: ["cancel", "resume"])], required: ["task_id", "action"]),
        .init(name: "zeus_project_diff", description: "Read actual Git status and diff for a remote project.", parameters: ["project_id": .init(type: .string, description: "Project ID")], required: ["project_id"])
    ]
    static func execute(_ name: String, args: [String: Any], callID: String) async throws -> String {
        let service = ZeusProjects.shared
        var value: [String: Any]
        let project = args["project_id"] as? String ?? ""
        let task = args["task_id"] as? String ?? ""
        switch name {
        case "zeus_project_list": value = ["projects": try await service.object("v1/projects"), "tasks": try await service.object("v1/tasks")]
        case "zeus_project_create":
            var body = args; body.removeValue(forKey: "tool_title"); body.removeValue(forKey: "approval_reason")
            if let raw = body["verify_commands"] as? String { body["verify_commands"] = try JSONSerialization.jsonObject(with: Data(raw.utf8)) }
            value = try await service.object("v1/projects", method: "POST", body: body)
        case "zeus_project_run":
            value = try await service.object("v1/projects/\(project)/tasks", method: "POST", body: ["prompt": args["prompt"] as? String ?? "", "acceptance": args["acceptance"] as? String ?? "", "permission_mode": ZeusToolPermissions.shared.mode.rawValue, "max_seconds": args["max_seconds"] as? Int ?? 7200, "idempotency_key": callID])
        case "zeus_project_status": value = try await service.object("v1/tasks/\(task)")
        case "zeus_project_events": value = try await service.object("v1/tasks/\(task)/events?after=\(args["after"] as? Int ?? 0)")
        case "zeus_project_control": value = try await service.object("v1/tasks/\(task)/\(args["action"] as? String ?? "")", method: "POST")
        case "zeus_project_diff": value = try await service.object("v1/projects/\(project)/diff")
        default: throw service.failure("أداة مشاريع غير معروفة.")
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}
