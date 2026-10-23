import SwiftUI
import CryptoKit

/// The executing agent remains the original AIChatViewModel and its selected
/// provider. This runtime adds durable plans, tools and completion gates to it.
@MainActor final class ZeusAgentHarness: ObservableObject {
    static let shared = ZeusAgentHarness()
    struct Step: Codable { var step: String; var status: String }
    struct Check: Codable { let command: String; let exitCode: Int; let output: String; let generation: Int; let date: Date }
    struct State: Codable {
        var goal = ""
        var status = "running"
        var plan: [Step] = []
        var checkpoint = ""
        var checks: [Check] = []
        var verificationCommands: [String] = []
        var generation = 0
        var noToolContinuations = 0
        var started = Date()
        var updated = Date()
        var ledger: [String: String] = [:]
        var commands: [String: String]? = [:]
    }
    struct Job: Identifiable {
        let id: String; let owner: String; let command: String
        let started = Date()
        var output = ""; var baseOffset = 0; var exitCode: Int?; var error: String?
        var task: Task<Void, Never>?
    }
    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var jobs: [String: Job] = [:]
    private var results: [String: String] = [:]
    private var patching = false
    private let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("ZeusAgentTasks", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }
    private func file(_ session: String) -> URL {
        let hash = SHA256.hash(data: Data(session.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(hash + ".json")
    }
    func state(_ session: String) -> State {
        if let saved = states[session] { return saved }
        let saved = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: file(session)))) ?? State()
        states[session] = saved
        return saved
    }
    private func save(_ session: String, _ value: State) throws {
        var value = value; value.updated = Date()
        let data = try JSONEncoder().encode(value)
        try data.write(to: file(session), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        states[session] = value
    }
    static func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self) }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static var maxTurns: Int { let n = UserDefaults.standard.integer(forKey: "zeus.agent.maxTurns"); return n == 0 ? 500 : min(max(n, 100), 2000) }
    static var maxHours: Int { let n = UserDefaults.standard.integer(forKey: "zeus.agent.maxHours"); return n == 0 ? 2 : min(max(n, 1), 12) }
    func budgetNotice(session: String?) -> String? {
        guard let session else { return nil }
        var value = state(session)
        guard value.status == "running", !value.plan.isEmpty, Date().timeIntervalSince(value.started) >= Double(Self.maxHours * 3600) else { return nil }
        value.status = "waiting_user"; value.checkpoint = "بلغت المهمة حد الوقت المحدد؛ التقدم محفوظ، ويمكن متابعة المهمة."; try? save(session, value)
        return value.checkpoint
    }
    func refreshContext(_ prompt: String, session: String?) -> String {
        var prompt = prompt
        if let begin = prompt.range(of: "<zeus_task_state>"), let end = prompt.range(of: "</zeus_task_state>", range: begin.upperBound..<prompt.endIndex) { prompt.removeSubrange(begin.lowerBound..<end.upperBound) }
        return prompt + context(session: session)
    }
    static var definitions: [AgentToolDefinition] {
        let descriptions = [
            "integration_accounts": "List the real linked integration accounts, IDs and default selections. Never invent an account or copy credentials into a message.",
            "integration_tools": "Discover a linked account's actual MCP tools directly from this device. Without query returns names/descriptions; with query (a tool name or distinctive keyword) returns matching complete input schemas, limit default 10. Use account_id or provider. No Zeus/Codex server is needed.",
            "integration_call": "Invoke a real tool for the specified linked account. Read integration_tools first, use its exact tool_name and a structured arguments OBJECT matching its inputSchema. The runtime validates the schema and does not replay an uncertain write.",
            "update_plan": "Create/update this conversation's real task plan. plan is an ARRAY of {step,status}; at most one in_progress step. Work yourself using the selected chat provider; never delegate to Codex. Use task_complete only after real verification.",
            "apply_patch": "Apply a context-checked multi-file patch to this device's project. Grammar: *** Begin Patch, *** Add File: relative/path with +lines; *** Update File: relative/path with @@ and context/+/− lines; *** Delete File: relative/path; optional *** Move to: relative/path; *** End Patch. Read files first. All paths/hunks validate before writes; ambiguous context is rejected.",
            "exec_command": "Start a REAL shell command in this conversation's local Linux environment. Returns a session_id and available output after yield_time_ms; use write_stdin to poll. workdir defaults to /var/minis/workspace. No Codex account/server is used. For interactive stdin use the original terminal tool; this tool captures noninteractive commands.",
            "write_stdin": "Read new output or terminate a command started by exec_command in THIS conversation. Empty chars polls; terminate cancels. Interactive input is unsupported here; use the original terminal tool for that. Supply offset from previous next_offset to avoid duplicate output.",
            "task_checkpoint": "Save/read the current plan, verification and checkpoint. action=save with note records durable progress for reconnect/resume. Do not store credentials. Read before resuming a long project.",
            "task_verify": "Run actual build/test commands in the current project and record each exit code/output against the current edit generation. commands is an ARRAY of strings. Failed checks remain failures and must be fixed. This is evidence, not a promise to test.",
            "task_complete": "Finish a planned task only when all steps are complete, no jobs are running and current-generation verification passes. Use status=blocked or waiting_user with the precise reason when verification/resources are unavailable. Do not mark tests passed when they were not run."
        ]
        return ZeusAgentSchemas.names.sorted().map { name in
            let shape = ZeusAgentSchemas.schema(name)!, properties = shape["properties"] as! [String: [String: Any]]
            let params = properties.mapValues { property in
                AgentToolParam(type: property["type"] as? String == "integer" ? .integer : property["type"] as? String == "boolean" ? .boolean : .string,
                    description: "See the structured JSON schema. " + (property["description"] as? String ?? ""))
            }
            return AgentToolDefinition(name: name, description: descriptions[name]!, parameters: params, required: shape["required"] as? [String] ?? [])
        }
    }
    func context(session: String?) -> String {
        guard let session else { return "" }
        let value = state(session)
        guard !value.plan.isEmpty else { return "" }
        return "\n<zeus_task_state>" + ((try? snapshot(session)) ?? "") + "</zeus_task_state>"
    }
    func continuation(session: String?) -> String? {
        guard let session else { return nil }
        var value = state(session)
        guard value.status == "running", !value.plan.isEmpty,
              Date().timeIntervalSince(value.started) < Double(Self.maxHours * 3600) else { return nil }
        if value.noToolContinuations >= 2 {
            value.status = "waiting_user"; value.checkpoint = "توقف النموذج عن استدعاء الأدوات رغم وجود خطوات غير مكتملة. التقدم محفوظ؛ يمكنك الاستئناف أو اختيار نموذج آخر."; try? save(session, value); return nil
        }
        value.noToolContinuations += 1; try? save(session, value)
        return "Runtime continuation: this task is still active. A progress message is not completion. Inspect task_checkpoint, continue the pending steps using real structured tool calls, run task_verify, then task_complete. If blocked, record the actual blocker with task_complete(status:blocked). Do not repeat an uncertain mutation; inspect its result first."
    }
    func pausedNotice(session: String?) -> String? {
        guard let session else { return nil }; let value = state(session)
        return value.status == "waiting_user" && !value.checkpoint.isEmpty ? value.checkpoint : nil
    }
    func observe(session: String?, tool: String, success: Bool) {
        guard let session, !ZeusAgentSchemas.names.contains(tool), !tool.hasPrefix("zeus_browser_") else { return }
        if ["file_write", "file_edit", "shell_execute"].contains(tool) {
            var value = state(session); value.generation += 1; value.noToolContinuations = 0; try? save(session, value)
        }
    }
    func cancel(session: String?) {
        guard let session else { return }
        for job in jobs.values where job.owner == session && job.exitCode == nil { job.task?.cancel() }
        var value = state(session); value.status = "interrupted"; try? save(session, value)
    }
    func execute(_ name: String, args: [String: Any], callID: String, vm: AIChatViewModel) async throws -> String {
        guard let session = vm.sessionId else { throw ZeusPatch.failure("No active conversation.") }
        guard let shape = ZeusAgentSchemas.schema(name) else { throw ZeusPatch.failure("Unknown native runtime tool.") }
        try ZeusAgentSchemas.validate(args, schema: shape)
        let signature = SHA256.hash(data: Data((name + (try Self.json(args))).utf8)).map { String(format: "%02x", $0) }.joined()
        var value = state(session)
        if let prior = value.ledger[callID] {
            guard prior == signature else { throw ZeusPatch.failure("This call ID was already used for different arguments. Nothing executed.") }
            if let result = results[session + ":" + callID] { return result }
            throw ZeusPatch.failure("This tool call was already attempted. Read the checkpoint/files/process status before issuing a NEW call; the previous mutation was not replayed.")
        }
        value.ledger[callID] = signature; value.noToolContinuations = 0
        if value.ledger.count > 2000 { throw ZeusPatch.failure("Task reached its tool-call budget. Save a checkpoint and resume a new task.") }
        try save(session, value)
        if ["apply_patch", "exec_command", "task_verify"].contains(name) { try await prepareEnvironment(vm: vm) }
        let output = try await dispatch(name, args: args, session: session, vm: vm)
        results[session + ":" + callID] = output
        if results.count > 100, let oldest = results.keys.first { results.removeValue(forKey: oldest) }
        return output
    }
    func prepareEnvironment(vm: AIChatViewModel) async throws {
        vm.ensureKernelBooted()
        for _ in 0..<300 {
            if ISHKernel.shared.isBooted { return }
            try Task.checkCancellation()
            if case .failed(let reason) = vm.kernelStatus { throw ZeusPatch.failure(reason) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ZeusPatch.failure("Local execution environment did not finish starting. No command was launched.")
    }
    private func dispatch(_ name: String, args: [String: Any], session: String, vm: AIChatViewModel) async throws -> String {
        var value = state(session)
        switch name {
        case "integration_accounts": return try Self.json(["accounts": ZeusConnections.shared.accountSummary()])
        case "integration_tools":
            let account = try ZeusConnections.shared.account(args["account_id"] as? String, provider: args["provider"] as? String)
            let all = try await ZeusConnections.shared.listTools(account.id), query = args["query"] as? String ?? ""
            let filtered = query.isEmpty ? all : all.filter { (($0["name"] as? String ?? "") + " " + ($0["description"] as? String ?? "")).localizedCaseInsensitiveContains(query) }
            let selected: [[String: Any]] = query.isEmpty ? filtered.map { ["name": $0["name"] ?? "", "description": String(($0["description"] as? String ?? "").prefix(240))] } : Array(filtered.prefix(args["limit"] as? Int ?? 10))
            return try Self.json(["account_id": account.id, "matching_tools": filtered.count, "tools": selected, "schema_hint": "Use query with an exact tool name to fetch its full inputSchema before calling it."])
        case "integration_call":
            let account = try ZeusConnections.shared.account(args["account_id"] as? String)
            return try Self.json(try await ZeusConnections.shared.call(account.id, name: args["tool_name"] as! String, arguments: args["arguments"] as! [String: Any]))
        case "update_plan":
            let data = try JSONSerialization.data(withJSONObject: args["plan"]!)
            let plan = try JSONDecoder().decode([Step].self, from: data)
            guard plan.filter({ $0.status == "in_progress" }).count <= 1 else { throw ZeusPatch.failure("Only one plan step can be in_progress.") }
            if value.plan.isEmpty || value.status != "running" { value.started = Date() }
            if value.status == "completed" { value.checks = []; value.verificationCommands = []; value.generation = 0 }
            if let commands = args["verification_commands"] as? [String], !commands.isEmpty {
                guard value.verificationCommands.isEmpty || Set(value.verificationCommands).isSubset(of: Set(commands)) else { throw ZeusPatch.failure("Verification checks cannot be removed or weakened during an active task.") }
                value.verificationCommands = commands
            }
            value.plan = plan; value.goal = args["goal"] as? String ?? value.goal; value.status = "running"
            if let explanation = args["explanation"] as? String { value.checkpoint = explanation }
            try save(session, value)
            return "الخطة محدثة.\n" + plan.map { ($0.status == "completed" ? "✓ " : $0.status == "in_progress" ? "→ " : "○ ") + $0.step }.joined(separator: "\n")
        case "task_checkpoint":
            if args["action"] as? String == "save" { value.checkpoint = args["note"] as? String ?? value.checkpoint; try save(session, value) }
            return try snapshot(session)
        case "apply_patch":
            guard !patching else { throw ZeusPatch.failure("Another patch is committing; inspect its result before applying the next patch.") }
            patching = true; defer { patching = false }
            let workdir = try directory(args)
            guard let root = await vm.resolvePathForDirectRead(workdir) else { throw ZeusPatch.failure("Project directory cannot be resolved: \(workdir)") }
            let changes = try ZeusPatch.prepare(args["patch"] as! String, root: root)
            for change in changes {
                let url = try ZeusPatch.safeURL(change.path, root: root)
                let current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
                guard current == change.before else { throw ZeusPatch.failure("File changed during patch preparation: \(change.path)") }
            }
            var committed: [ZeusPatch.Change] = []
            value = state(session); value.generation += 1; try save(session, value)
            do {
                for change in changes {
                    let url = try ZeusPatch.safeURL(change.path, root: root)
                    let current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
                    guard current == change.before else { throw ZeusPatch.failure("File changed before commit: \(change.path)") }
                    try await write(change.after, path: workdir + "/" + change.path, vm: vm)
                    committed.append(change)
                }
            } catch {
                var failed: [String] = []
                for change in committed.reversed() {
                    do {
                        let url = try ZeusPatch.safeURL(change.path, root: root)
                        let current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
                        guard current == change.after else { throw ZeusPatch.failure("Concurrent edit preserved") }
                        try await write(change.before, path: workdir + "/" + change.path, vm: vm)
                    } catch { failed.append(change.path) }
                }
                throw ZeusPatch.failure("Patch commit failed: \(error.localizedDescription). Rollback failures: \(failed). Inspect files before retrying.")
            }
            return "Applied verified patch to \(changes.count) file(s):\n" + changes.map(\.path).joined(separator: "\n")
        case "exec_command":
            let command = args["cmd"] as! String, cwd = try directory(args), id = UUID().uuidString
            let timeout = try commandTimeout(args["timeout_seconds"] as? Int ?? 900, session: session)
            guard jobs.values.filter({ $0.owner == session && $0.exitCode == nil }).count < 8 else { throw ZeusPatch.failure("Eight commands are already running. Poll or finish them before starting more.") }
            let finished = jobs.values.filter({ $0.exitCode != nil }).sorted { $0.started < $1.started }
            for old in finished.prefix(max(0, finished.count - 24)) { jobs.removeValue(forKey: old.id) }
            value.commands = value.commands ?? [:]; value.commands?[id] = "running: started " + Date().ISO8601Format()
            value.generation += 1; try save(session, value)
            jobs[id] = Job(id: id, owner: session, command: command)
            let task = Task { @MainActor [weak self] in
                do {
                    let result = try await vm.executeCommand("cd " + Self.quote(cwd) + " && " + command, timeout: timeout) { line in self?.append(line + "\n", job: id) }
                    guard var job = self?.jobs[id] else { return }
                    if job.output.isEmpty { job.output = String(result.output.suffix(100000)) }
                    job.exitCode = result.exitCode; job.task = nil; self?.jobs[id] = job
                    self?.recordCommand(id, session: session, result: "exit_code=\(result.exitCode)")
                } catch {
                    guard var job = self?.jobs[id] else { return }
                    job.error = error.localizedDescription; job.exitCode = -1; job.task = nil; self?.jobs[id] = job
                    self?.recordCommand(id, session: session, result: "interrupted: " + error.localizedDescription)
                }
            }
            jobs[id]?.task = task
            try await Task.sleep(for: .milliseconds(min(args["yield_time_ms"] as? Int ?? 1000, 1000)))
            return try result(job: id, session: session, offset: 0, limit: args["max_output_chars"] as? Int ?? 12000)
        case "write_stdin":
            let id = args["session_id"] as! String
            guard let job = jobs[id], job.owner == session else { throw ZeusPatch.failure("No running command with this ID in this conversation. After an app restart inspect the filesystem; do not replay the command blindly.") }
            guard (args["chars"] as? String ?? "").isEmpty else { throw ZeusPatch.failure("Interactive input is not supported by this capture tool. Use the original interactive terminal tool instead. Nothing was sent.") }
            if args["terminate"] as? Bool == true { job.task?.cancel() }
            if job.exitCode == nil { try await Task.sleep(for: .milliseconds(min(args["yield_time_ms"] as? Int ?? 1000, 1000))) }
            return try result(job: id, session: session, offset: args["offset"] as? Int ?? 0, limit: args["max_output_chars"] as? Int ?? 12000)
        case "task_verify":
            guard !jobs.values.contains(where: { $0.owner == session && $0.exitCode == nil }) else { throw ZeusPatch.failure("Wait for or cancel running commands before verification.") }
            let cwd = try directory(args), generation = value.generation
            let commands = args["commands"] as! [String]
            guard value.verificationCommands.isEmpty || Set(value.verificationCommands).isSubset(of: Set(commands)) else { throw ZeusPatch.failure("Run every previously registered verification command. Failed checks cannot be replaced with weaker commands.") }
            value.verificationCommands = commands; value.checks = []; try save(session, value)
            var checks: [Check] = []
            for command in commands {
                try Task.checkCancellation()
                let timeout = try commandTimeout(args["timeout_seconds"] as? Int ?? 900, session: session)
                let result = try await vm.executeCommand("cd " + Self.quote(cwd) + " && " + command, timeout: timeout) { _ in }
                checks.append(Check(command: command, exitCode: result.exitCode, output: String(result.output.suffix(20000)), generation: generation, date: Date()))
                value = state(session); value.checks = checks; try save(session, value)
            }
            value = state(session); value.checks = checks; try save(session, value)
            return try Self.json(checks.map { ["command": $0.command, "exitCode": $0.exitCode, "output": String($0.output.suffix(6000)), "generation": $0.generation] as [String: Any] })
        case "task_complete":
            let status = args["status"] as! String
            if status == "completed" {
                guard !value.plan.isEmpty, value.plan.allSatisfy({ $0.status == "completed" }) else { throw ZeusPatch.failure("Completion blocked: unfinished plan steps.") }
                guard !jobs.values.contains(where: { $0.owner == session && $0.exitCode == nil }) else { throw ZeusPatch.failure("Completion blocked: command still running.") }
                guard !value.checks.isEmpty, value.checks.allSatisfy({ $0.exitCode == 0 && $0.generation == value.generation }) else { throw ZeusPatch.failure("Completion blocked: run task_verify after the latest edits and fix every failing check. If the environment cannot verify, record status=blocked with that limitation.") }
            }
            if status == "completed" {
                guard !value.verificationCommands.isEmpty, Set(value.checks.map(\.command)) == Set(value.verificationCommands) else { throw ZeusPatch.failure("Completion blocked: not every registered verification command has a recorded result.") }
            }
            value.status = status; value.checkpoint = (args["summary"] as! String) + "\n" + (args["limitations"] as? String ?? ""); try save(session, value)
            return "Task status: " + status + "\n" + value.checkpoint
        default: throw ZeusPatch.failure("Unknown native runtime tool.")
        }
    }
    private func commandTimeout(_ requested: Int, session: String) throws -> TimeInterval {
        if let notice = budgetNotice(session: session) { throw ZeusPatch.failure(notice) }
        let value = state(session)
        if value.plan.isEmpty { return Double(requested) }
        let remaining = Double(Self.maxHours * 3600) - Date().timeIntervalSince(value.started)
        guard remaining > 0 else { throw ZeusPatch.failure("Task time budget exhausted; checkpoint saved.") }
        return min(Double(requested), remaining)
    }
    private func directory(_ args: [String: Any]) throws -> String {
        let path = args["workdir"] as? String ?? "/var/minis/workspace"
        guard path.hasPrefix("/"), path != "/", !path.contains("\0"), !path.split(separator: "/").contains("..") else { throw ZeusPatch.failure("workdir must be an absolute project path without traversal.") }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
    private func write(_ data: Data?, path: String, vm: AIChatViewModel) async throws {
        if let data {
            guard let content = String(data: data, encoding: .utf8) else { throw ZeusPatch.failure("Patch content must be UTF-8.") }
            let result = try await vm.executeFileWrite(from: Self.json(["path": path, "content": content, "create_dirs": true]))
            guard result.success else { throw ZeusPatch.failure(result.output) }
        } else {
            let result = try await vm.executeCommand("rm -- " + Self.quote(path), timeout: 30) { _ in }
            guard result.exitCode == 0 else { throw ZeusPatch.failure(result.output) }
        }
    }
    private func append(_ text: String, job id: String) {
        guard var job = jobs[id] else { return }; job.output += text
        if job.output.count > 100000 { let excess = job.output.count - 100000; job.baseOffset += excess; job.output = String(job.output.suffix(100000)) }
        jobs[id] = job
    }
    private func recordCommand(_ id: String, session: String, result: String) {
        var value = state(session); value.commands = value.commands ?? [:]; value.commands?[id] = String(result.prefix(1000)); try? save(session, value)
    }
    private func result(job id: String, session: String, offset: Int, limit: Int) throws -> String {
        guard let job = jobs[id], job.owner == session else { throw ZeusPatch.failure("Unknown command session.") }
        let start = min(max(offset - job.baseOffset, 0), job.output.count)
        let content = String(job.output.dropFirst(start).prefix(limit))
        return try Self.json(["session_id": id, "running": job.exitCode == nil, "exit_code": job.exitCode as Any? ?? NSNull(), "output": content,
            "next_offset": job.baseOffset + start + content.count, "output_was_truncated": offset < job.baseOffset, "error": job.error as Any? ?? NSNull()])
    }
    private func snapshot(_ session: String) throws -> String {
        let value = state(session)
        let commands = value.commands ?? [:]
        let records = commands.sorted { lhs, rhs in
            if lhs.value.hasPrefix("running:") != rhs.value.hasPrefix("running:") { return lhs.value.hasPrefix("running:") }
            return lhs.key < rhs.key
        }.prefix(40).map { id, status in
            (id, status.hasPrefix("running:") && jobs[id] == nil ? "Possibly interrupted after restart; inspect process/files before retrying. " + status : status)
        }
        return try Self.json(["goal": value.goal, "status": value.status, "generation": value.generation, "checkpoint": value.checkpoint,
            "plan": value.plan.map { ["step": $0.step, "status": $0.status] }, "verification_commands": value.verificationCommands,
            "checks": value.checks.map { ["command": $0.command, "exit_code": $0.exitCode, "generation": $0.generation] as [String: Any] },
            "recorded_tool_calls": value.ledger.count, "command_records_count": commands.count, "command_records": Dictionary(uniqueKeysWithValues: records),
            "local_commands": jobs.values.filter { $0.owner == session }.map { ["session_id": $0.id, "running": $0.exitCode == nil] as [String: Any] }])
    }
}

struct ZeusAgentRuntimeSettings: View {
    @AppStorage("zeus.agent.maxTurns") private var maxTurns = 500
    @AppStorage("zeus.agent.maxHours") private var maxHours = 2
    var body: some View {
        List {
            Section("المزوّد والنموذج") {
                NavigationLink("إدارة المزوّدين") { ProviderInstancesView() }
                NavigationLink("مجموعات النماذج") { ModelGroupsView() }
            }
            Section("قدرات الوكيل") {
                ForEach(["خطة محفوظة لكل محادثة", "رقع متعددة الملفات مع تحقق السياق", "جلسات أوامر ومتابعة المخرجات", "اختبارات فعلية قبل إعلان الإكمال", "نقاط استئناف بعد الانقطاع"], id: \.self) { Text($0) }
            }
            Section("حدود المهمة") {
                Stepper("دورات النموذج: \(maxTurns)", value: $maxTurns, in: 100...2000, step: 100)
                Stepper("الوقت: \(maxHours) ساعة", value: $maxHours, in: 1...12)
                Text("يستمر التنفيذ المحلي أثناء إتاحة iOS للتطبيق. تُحفظ الخطة عند الانقطاع؛ لا تُعاد الأوامر تلقائياً بعد إغلاق التطبيق.").font(.caption).foregroundStyle(.secondary)
            }
            NavigationLink("المهارات الافتراضية") { ZeusDefaultSkillsView() }
            NavigationLink("الإضافات والحسابات") { ZeusPluginsSettingsView() }
        }.navigationTitle("وكيل ZEUS")
    }
}
