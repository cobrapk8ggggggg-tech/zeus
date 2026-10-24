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
        var remoteVerificationKeys: [String]?
        var remoteChecks: [Check]?
        var remoteVerificationSpecs: [String]?
        var generation = 0
        var noToolContinuations = 0
        var started = Date()
        var updated = Date()
        var ledger: [String: String] = [:]
        var commands: [String: String]? = [:]
        var project: ZeusProjectContract?
        var lastEnvironment: ZeusProjectContract.Environment?
        var toolTextRepairs: Int?
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
    var artifactDownloads: Set<String> = []
    private var sourceChanges: [String: Set<UUID>] = [:]
    private let root: URL
    var taskStorageDirectory: URL { root }
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
    func save(_ session: String, _ value: State) throws {
        var value = value; value.updated = Date()
        let data = try JSONEncoder().encode(value)
        try data.write(to: file(session), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        states[session] = value
        if let raw = value.project?.approvalBlock, let id = UUID(uuidString: raw) {
            NotificationCenter.default.post(name: .zeusApprovalChanged, object: id)
        }
    }
    static func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self) }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func scopedCallID(providerID: String, sourceMessageID: String?) -> String {
        // RawMessage IDs are persisted. UI ChatMessage/AssistantBlock UUIDs are
        // recreated on load and must never be used as durable execution keys.
        guard let sourceMessageID else { return providerID }
        return sourceMessageID + ":" + providerID
    }
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
        for name in ["zeus_project_skills", "zeus_task_state"] {
            if let begin = prompt.range(of: "<" + name + ">"), let end = prompt.range(of: "</" + name + ">", range: begin.upperBound..<prompt.endIndex) {
                var start = begin.lowerBound
                if start > prompt.startIndex, prompt[prompt.index(before: start)] == "\n" { start = prompt.index(before: start) }
                prompt.removeSubrange(start..<end.upperBound)
            }
        }
        return prompt + context(session: session)
    }
    static var definitions: [AgentToolDefinition] {
        let descriptions = [
            "project_environment": "Inspect this device's ACTUAL local toolchains and linked GitHub accounts before proposing a project. iOS apps require macOS/Xcode on GitHub Actions, not Linux Swift. This fixed read-only probe is allowed before plan approval.",
            "propose_project_plan": "Present the complete project brief as a native INLINE PLAN CARD and WAIT for the user's explicit approve/revise/cancel response. Required before source/build/repository mutations for project tasks. Include features, architecture, ordered steps, deliverables and real acceptance checks covering EVERY feature, plus build, functional and UI review checks. Inspect project_environment first. iOS route must be github_actions with a real linked account/repository/branch/workflow. Local checks identify exact commands (UI also screenshot_path); GitHub checks identify exact job and step names, and app/screenshot artifact names for build/UI. User revisions require a new proposal; prose is not approval.",
            "github_read_file": "Read a repository UTF-8 source file directly as plain text with its actual SHA. For large files use offset (default 0) and max_chars (default 8000); continue from next_offset while truncated is true. Check SHA stays identical across chunks before editing; never mistake a partial read for the whole file. Use the selected account/repository/branch. No local clone, shell, Base64 generation or decoding is needed.",
            "github_write_files": "Write/create/delete up to 30 text source files DIRECTLY to the approved GitHub repository branch in one real Git commit. files is an array of {path,content} using normal source text, NOT Base64; use {path,delete:true} only for deliberate deletions. The runtime creates Git blobs/tree/commit and updates the ref without force. First inspect existing files with github_read_file. The branch must already exist (initialize a new repo with auto_init:true, then create the approved branch using github_request). No local git push, token handling, shell or manual Base64 is needed. The returned SHA is the source to build on Actions. On an uncertain/conflicting ref update inspect HEAD before a new write; do not blindly repeat.",
            "github_request": "Execute GitHub REST directly using the specified linked account's private Keychain credential (never returned to the model). path is relative to api.github.com, e.g. /repos/owner/repo/contents/src/App.swift. Supports branches/files/commits/PRs, creating repositories and GitHub Actions dispatch/status/jobs/artifacts. GET /repos/o/r/actions/jobs/JOB_ID/logs returns bounded actual log text natively, without curl. method defaults GET, query is a string-valued object, body is a JSON object. For approved project source use github_read_file/github_write_files with plain text rather than contents PUT or Base64. Use Git blobs/trees/commits only when a specialized operation requires them; inspect HEAD before updating its ref, do not force push by default. A new workflow on a feature branch should include an on:push trigger so its committed source starts CI. Inspect runs for the exact head SHA; workflow_dispatch may require the workflow to be registered on the default branch, so do not loop on a 404. For an available dispatch endpoint, POST /repos/o/r/actions/workflows/name.yml/dispatches uses body {ref:branch}. Commit all intended source/tests before dispatch; the approved repository/branch is the deliverable source of truth. Respect the selected account and read actual errors; never blindly retry an uncertain mutation.",
            "task_verify_github": "Verify a REAL GitHub Actions run against exact repository, commit SHA, approved branch/workflow, successful terminal result, each approved job/step and required app/screenshot artifacts. It records current-generation acceptance evidence for the approved project plan. Poll github_request until completed, fix failed builds/tests, then invoke this tool. Missing local Swift/Xcode is a reason to use Actions, not to return an unbuilt project as completed.",
            "github_download_artifact": "Download an approved project's actual GitHub build/screenshot artifact ZIP into this conversation workspace using the native account credential. Provide exact account/repository/run/commit/artifact and a new relative .zip destination. The token/temporary download URL is never returned to the model. Download screenshots, inspect archive paths before extracting into a dedicated artifact directory, read actual screenshots with read_image, then task_verify_github after any local extraction commands and task_complete. No local compiler is needed to retrieve/review a remote build.",
            "integration_accounts": "List the real linked integration accounts, IDs and default selections. Never invent an account or copy credentials into a message.",
            "integration_tools": "Discover a linked account's actual MCP tools directly from this device. Without query returns names/descriptions; with query (a tool name or distinctive keyword) returns matching complete input schemas, limit default 10. Use account_id or provider. No Zeus/Codex server is needed.",
            "integration_call": "Invoke a real tool for the specified linked account. Read integration_tools first, use its exact tool_name and a structured arguments OBJECT matching its inputSchema. The runtime validates the schema and does not replay an uncertain write.",
            "update_plan": "Create/update this conversation's real task plan. plan is an ARRAY of {step,status}; at most one in_progress step. Work yourself using the selected chat provider; never delegate to Codex. Use task_complete only after real verification.",
            "apply_patch": "Apply a context-checked multi-file patch to this device's project. Grammar: *** Begin Patch, *** Add File: relative/path with +lines; *** Update File: relative/path with @@ and context/+/− lines; *** Delete File: relative/path; optional *** Move to: relative/path; *** End Patch. Read files first. All paths/hunks validate before writes; ambiguous context is rejected.",
            "exec_command": "Start a REAL shell command in this conversation's local Linux environment. Returns a session_id and available output after yield_time_ms; use write_stdin to poll. workdir defaults to /var/minis/workspace. No Codex account/server is used. For interactive stdin use the original terminal tool; this tool captures noninteractive commands.",
            "write_stdin": "Read new output or terminate a command started by exec_command in THIS conversation. Empty chars polls; terminate cancels. Interactive input is unsupported here; use the original terminal tool for that. Supply offset from previous next_offset to avoid duplicate output.",
            "task_checkpoint": "Save/read the current plan, verification and checkpoint. action=save with note records durable progress for reconnect/resume. Do not store credentials. Read before resuming a long project.",
            "task_verify": "Run actual build/test commands in the current project and record each exit code/output against the current edit generation. commands is an ARRAY of strings. Failed checks remain failures and must be fixed. This is evidence, not a promise to test.",
            "task_verify_mcp": "Verify remote work through actual READ-ONLY linked MCP tools, e.g. GitHub Actions or deployment status, without requiring a local shell. checks is an array of exact account/tool/arguments plus assertions [{path:[JSON keys or array indices],equals:scalar}]. Use exact run/deployment IDs and assert commit identity AND successful terminal status. Only structured JSON evidence is accepted; prose promises do not count. Earlier registered assertions cannot be weakened. Remote mutations invalidate earlier verification.",
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
        guard !value.plan.isEmpty || value.project != nil else { return "" }
        // Stable full skill bodies precede dynamic task state, improving
        // provider prefix caching and avoiding duplication in tool/history JSON.
        var skills: [String: [String: String]] = [:]
        for (name, body) in value.project?.loadedSkills ?? [:] {
            skills[name] = ["path": value.project?.skillPaths?[name] ?? "", "body": body]
        }
        let prefix = skills.isEmpty ? "" : "\n<zeus_project_skills>" + ((try? Self.json(skills)) ?? "") + "</zeus_project_skills>"
        return prefix + "\n<zeus_task_state>" + ((try? snapshot(session)) ?? "") + "</zeus_task_state>"
    }
    func continuation(session: String?) -> String? {
        guard let session else { return nil }
        var value = state(session)
        guard value.status == "running", (!value.plan.isEmpty || value.project?.required == true),
              Date().timeIntervalSince(value.started) < Double(Self.maxHours * 3600) else { return nil }
        if value.noToolContinuations >= (value.project?.required == true ? 6 : 2) {
            value.status = "waiting_user"; value.checkpoint = "توقف النموذج عن استدعاء الأدوات رغم وجود خطوات غير مكتملة. التقدم محفوظ؛ يمكنك الاستئناف أو اختيار نموذج آخر."; try? save(session, value); return nil
        }
        value.noToolContinuations += 1; try? save(session, value)
        if let project = value.project, project.decision != "approved" {
            return "Application project gate: this is an unfinished project request. Inspect project_environment, then call propose_project_plan and await the user's actual inline approval. Source/shell/build writes are blocked until approval. Incorporate revision notes from task_checkpoint. A code snippet or progress message is not a completed product. If the user cancelled, respect that cancellation."
        }
        return "Runtime continuation: this task is still active. A progress message is not completion. Inspect task_checkpoint, continue the pending steps using real structured tool calls, run task_verify, then task_complete. If blocked, record the actual blocker with task_complete(status:blocked). Do not repeat an uncertain mutation; inspect its result first."
    }
    func recoverToolText(_ text: String, tools: Set<String>, session: String?) -> (notice: String, instruction: String?)? {
        guard let session else { return nil }
        var value = state(session)
        guard value.status == "running",
              let candidate = ZeusToolRecovery.candidate(text, tools: tools) else { return nil }
        let attempt = (value.toolTextRepairs ?? 0) + 1; value.toolTextRepairs = attempt
        let notice = "أرسل المزوّد طلب أداة كنص؛ لم يُنفَّذ. " + (attempt <= 2 ? "أعيد طلبه الآن بصيغة أداة صحيحة." : "تعذّر تصحيح بروتوكول الأدوات لهذا المزوّد. التقدم محفوظ؛ غيّر النموذج أو إعدادات مزوّد الأدوات ثم استأنف.")
        value.checkpoint = notice; value.project?.appendNote(notice)
        if attempt > 2 { value.status = "waiting_user" }
        try? save(session, value)
        let name = candidate == "github_request" && text.contains("\"content\"") && tools.contains("github_write_files") ? "github_write_files" : candidate
        let instruction = attempt <= 2 ? ZeusToolRecovery.marker + name + "\nThe previous assistant JSON was visible text and WAS NOT EXECUTED. Send the actual provider function call now, separately from visible prose. Use normal UTF-8 source text with github_write_files; never generate or print Base64. Do not replay any already executed write. Preserve the approved project plan and continue with actual tools. Acknowledge no false success." : nil
        return (notice, instruction)
    }
    func pausedNotice(session: String?) -> String? {
        guard let session else { return nil }; let value = state(session)
        return value.status == "waiting_user" && !value.checkpoint.isEmpty ? value.checkpoint : nil
    }
    func beginSourceChange(session: String?, tool: String, args: [String: Any], ticket: UUID, includeNative: Bool = false) throws -> Bool {
        guard let session else { return false }
        let legacy = ["file_write", "file_edit", "shell_execute"].contains(tool)
        let native = includeNative && (["apply_patch", "exec_command", "github_write_files"].contains(tool) || (tool == "github_request" && !["GET", "HEAD"].contains(args["method"] as? String ?? "GET")))
        guard legacy || native else { return false }
        sourceChanges[session, default: []].insert(ticket)
        if legacy || state(session).status == "completed" {
            var value = state(session)
            if legacy { value.generation += 1; value.noToolContinuations = 0 }
            if value.status == "completed" { value.status = "running" }
            do { try save(session, value) } catch { sourceChanges[session]?.remove(ticket); throw error }
        }
        return true
    }
    func finishSourceChange(session: String?, ticket: UUID) { if let session { sourceChanges[session]?.remove(ticket) } }
    func hasSourceChanges(_ session: String) -> Bool { !(sourceChanges[session] ?? []).isEmpty }
    func observe(session: String?, tool: String, success: Bool, args: [String: Any] = [:], sourceWasTracked: Bool? = nil, imageDelivered: Bool = true) {
        guard let session, !ZeusAgentSchemas.names.contains(tool), !tool.hasPrefix("zeus_browser_") else { return }
        if success { var value = state(session); value.toolTextRepairs = 0; value.noToolContinuations = 0; try? save(session, value) }
        if ["file_write", "file_edit", "shell_execute"].contains(tool), sourceWasTracked == nil {
            var value = state(session); value.generation += 1; value.noToolContinuations = 0
            if value.status == "completed" { value.status = "running" }
            try? save(session, value)
        }
        if tool == "read_image", success, imageDelivered, let path = args["path"] as? String {
            var value = state(session)
            if value.project != nil {
                let normalized = Self.projectImagePath(path)
                if value.project?.referenceImages?.contains(normalized) == true {
                    if value.project?.inspectedReferences == nil { value.project?.inspectedReferences = [] }
                    if value.project?.inspectedReferences?.contains(normalized) != true { value.project?.inspectedReferences?.append(normalized) }
                }
                value.project?.reviewedImages[normalized] = value.generation
                if let source = value.project?.artifactRoots?.sorted(by: { $0.key.count > $1.key.count }).first(where: { normalized.hasPrefix($0.key + "/") }) {
                    if value.project?.reviewedImageCommits == nil { value.project?.reviewedImageCommits = [:] }
                    value.project?.reviewedImageCommits?[normalized] = source.value
                }
                try? save(session, value); try? recordProjectChecks(session: session)
            }
        }
    }
    func cancel(session: String?) {
        guard let session else { return }
        for job in jobs.values where job.owner == session && job.exitCode == nil { job.task?.cancel() }
        var value = state(session); value.status = "interrupted"; try? save(session, value)
    }
    func execute(_ name: String, args: [String: Any], callID: String, vm: AIChatViewModel) async throws -> String {
        guard let session = vm.sessionId else { throw ZeusPatch.failure("No active conversation.") }
        if name == "propose_project_plan", isUtilityTask(session: session) {
            return try Self.json(["project_plan_required": false, "next": "This is a utility/script task. Execute the requested tools directly, without a project approval card. A simple update_plan checklist is optional."])
        }
        guard let shape = ZeusAgentSchemas.schema(name) else { throw ZeusPatch.failure("Unknown native runtime tool.") }
        try ZeusAgentSchemas.validate(args, schema: shape)
        try projectGate(tool: name, args: args, session: session)
        if ["task_verify", "task_verify_mcp", "task_verify_github", "task_complete"].contains(name), hasSourceChanges(session) {
            throw ZeusPatch.failure("A source/repository mutation is still executing. Wait for its actual result before verification or completion.")
        }
        let sourceTicket = UUID(), sourceTracked = try beginSourceChange(session: session, tool: name, args: args, ticket: sourceTicket, includeNative: true)
        defer { if sourceTracked { finishSourceChange(session: session, ticket: sourceTicket) } }
        let signature = SHA256.hash(data: Data((name + (try Self.json(args))).utf8)).map { String(format: "%02x", $0) }.joined()
        var value = state(session)
        if let prior = value.ledger[callID] {
            guard prior == signature else { throw ZeusPatch.failure("This call ID was already used for different arguments. Nothing executed.") }
            if let result = results[session + ":" + callID] { return result }
            throw ZeusPatch.failure("This tool call was already attempted. Read the checkpoint/files/process status before issuing a NEW call; the previous mutation was not replayed.")
        }
        value.ledger[callID] = signature; value.noToolContinuations = 0; value.toolTextRepairs = 0
        if value.ledger.count > 2000 { throw ZeusPatch.failure("Task reached its tool-call budget. Save a checkpoint and resume a new task.") }
        try save(session, value)
        if ["apply_patch", "exec_command", "task_verify"].contains(name) { try await prepareEnvironment(vm: vm) }
        let output = try await dispatch(name, args: args, session: session, vm: vm)
        results[session + ":" + callID] = output
        if results.count > 100, let oldest = results.keys.first { results.removeValue(forKey: oldest) }
        return output
    }
    func prepareEnvironment(vm: AIChatViewModel) async throws {
        if let session = vm.sessionId { try Self.prepareWorkspace(session: session) }
        vm.ensureKernelBooted()
        for _ in 0..<300 {
            if ISHKernel.shared.isBooted { vm.ensureParentDirsInMetaDB(for: "/var/minis/workspace"); return }
            try Task.checkCancellation()
            if case .failed(let reason) = vm.kernelStatus { throw ZeusPatch.failure(reason) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ZeusPatch.failure("Local execution environment did not finish starting. No command was launched.")
    }
    static func prepareWorkspace(session: String) throws {
        guard !session.isEmpty, !session.contains("/"), session != ".", session != ".." else { throw ZeusPatch.failure("Invalid conversation storage identifier.") }
        let base = AIChatViewModel.minisPersistentBase.appendingPathComponent(session, isDirectory: true)
        for directory in ["workspace", "attachments", "offloads", "browser"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(directory, isDirectory: true), withIntermediateDirectories: true)
        }
    }
    private func dispatch(_ name: String, args: [String: Any], session: String, vm: AIChatViewModel) async throws -> String {
        var value = state(session)
        switch name {
        case "project_environment": return try await projectEnvironment(vm: vm)
        case "propose_project_plan":
            let proposal = try ZeusProjectContract.decoded(args)
            guard value.project?.decision == "approved", value.project?.approvedHash == proposal.hash else { throw ZeusPatch.failure("The project plan has not been approved by the user. Do not execute its changes.") }
            return try Self.json(["approved": true, "plan_hash": proposal.hash, "steps": proposal.steps, "next": "Implement the approved product brief, architecture and acceptance checks; follow the selected build route and continue until verified."])
        case "github_read_file": return try await githubReadFile(args, session: session)
        case "github_write_files": return try await githubWriteFiles(args, session: session)
        case "github_request": return try await githubProjectRequest(args, session: session)
        case "task_verify_github": return try await verifyGitHubProject(args, session: session)
        case "github_download_artifact": return try await downloadGitHubArtifact(args, session: session, vm: vm)
        case "integration_accounts": return try Self.json(["accounts": ZeusConnections.shared.accountSummary()])
        case "integration_tools":
            let account = try ZeusConnections.shared.account(args["account_id"] as? String, provider: args["provider"] as? String)
            let all = try await ZeusConnections.shared.listTools(account.id), query = args["query"] as? String ?? ""
            let filtered = query.isEmpty ? all : all.filter { (($0["name"] as? String ?? "") + " " + ($0["description"] as? String ?? "")).localizedCaseInsensitiveContains(query) }
            let selected: [[String: Any]] = query.isEmpty ? filtered.map { ["name": $0["name"] ?? "", "description": String(($0["description"] as? String ?? "").prefix(240))] } : Array(filtered.prefix(args["limit"] as? Int ?? 10))
            return try Self.json(["account_id": account.id, "matching_tools": filtered.count, "tools": selected, "schema_hint": "Use query with an exact tool name to fetch its full inputSchema before calling it."])
        case "integration_call":
            let account = try ZeusConnections.shared.account(args["account_id"] as? String)
            _ = try await ZeusConnections.shared.listTools(account.id)
            if !ZeusConnections.shared.isReadOnly(account.id, tool: args["tool_name"] as! String) { value = state(session); value.generation += 1; try save(session, value) }
            return try Self.json(try await ZeusConnections.shared.call(account.id, name: args["tool_name"] as! String, arguments: args["arguments"] as! [String: Any]))
        case "update_plan":
            let data = try JSONSerialization.data(withJSONObject: args["plan"]!)
            let plan = try JSONDecoder().decode([Step].self, from: data)
            guard Set(plan.map(\.step)).count == plan.count else { throw ZeusPatch.failure("Plan step descriptions must be unique.") }
            if let project = value.project, project.decision == "approved", let proposal = project.proposal {
                guard Set(proposal.steps).isSubset(of: Set(plan.map(\.step))) else { throw ZeusPatch.failure("Approved project steps cannot disappear from update_plan. Propose a revised plan and obtain user approval for scope changes.") }
            }
            guard plan.filter({ $0.status == "in_progress" }).count <= 1 else { throw ZeusPatch.failure("Only one plan step can be in_progress.") }
            if value.plan.isEmpty || value.status != "running" { value.started = Date() }
            if value.status == "completed", value.project == nil { value.checks = []; value.verificationCommands = []; value.remoteChecks = []; value.remoteVerificationKeys = []; value.remoteVerificationSpecs = []; value.generation = 0 }
            if let commands = args["verification_commands"] as? [String], !commands.isEmpty {
                guard value.verificationCommands.isEmpty || Set(value.verificationCommands).isSubset(of: Set(commands)) else { throw ZeusPatch.failure("Verification checks cannot be removed or weakened during an active task.") }
                value.verificationCommands = commands
            }
            if value.project?.decision == "approved", plan.contains(where: { next in value.plan.first(where: { $0.step == next.step })?.status != next.status }) {
                guard let explanation = args["explanation"] as? String, !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ZeusPatch.failure("A project milestone update needs explanation: briefly tell the user what finished or was discovered and what you will do next. It is shown on the live plan/notes card.") }
                let newlyCompleted = plan.filter { next in next.status == "completed" && value.plan.first(where: { $0.step == next.step })?.status != "completed" }
                guard newlyCompleted.count <= 1 else { throw ZeusPatch.failure("Update approved project stages as you finish each one, rather than checking off all stages at once. Record the concrete milestone finding in explanation.") }
            }
            value.plan = plan; value.goal = args["goal"] as? String ?? value.goal; value.status = "running"
            if let explanation = args["explanation"] as? String { value.checkpoint = explanation; value.project?.appendNote(explanation) }
            try save(session, value)
            return "الخطة محدثة.\n" + plan.map { ($0.status == "completed" ? "✓ " : $0.status == "in_progress" ? "→ " : "○ ") + $0.step }.joined(separator: "\n")
        case "task_checkpoint":
            if args["action"] as? String == "save" { value.checkpoint = args["note"] as? String ?? value.checkpoint; value.project?.appendNote(value.checkpoint); try save(session, value) }
            return try snapshot(session)
        case "task_verify_mcp": return try await verifyRemote(args["checks"] as! [[String: Any]], session: session)
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
            try recordProjectChecks(session: session)
            return try Self.json(checks.map { ["command": $0.command, "exitCode": $0.exitCode, "output": String($0.output.suffix(6000)), "generation": $0.generation] as [String: Any] })
        case "task_complete":
            let status = args["status"] as! String
            try validateProjectCompletion(session: session, status: status)
            if status == "completed" {
                guard !value.plan.isEmpty, value.plan.allSatisfy({ $0.status == "completed" }) else { throw ZeusPatch.failure("Completion blocked: unfinished plan steps.") }
                guard !jobs.values.contains(where: { $0.owner == session && $0.exitCode == nil }) else { throw ZeusPatch.failure("Completion blocked: command still running.") }
                let checks = value.checks + (value.remoteChecks ?? [])
                guard (!checks.isEmpty || value.project?.decision == "approved"), checks.allSatisfy({ $0.exitCode == 0 && $0.generation == value.generation }) else { throw ZeusPatch.failure("Completion blocked: run task_verify/task_verify_mcp after the latest edits and fix every failing check. If the environment cannot verify, record status=blocked with that limitation.") }
            }
            if status == "completed" {
                guard Set(value.checks.map(\.command)) == Set(value.verificationCommands), Set((value.remoteChecks ?? []).map(\.command)) == Set(value.remoteVerificationKeys ?? []) else { throw ZeusPatch.failure("Completion blocked: not every registered verification check has a recorded result.") }
            }
            value.status = status; value.checkpoint = (args["summary"] as! String) + "\n" + (args["limitations"] as? String ?? ""); try save(session, value)
            return "Task status: " + status + "\n" + value.checkpoint
        default: throw ZeusPatch.failure("Unknown native runtime tool.")
        }
    }
    func verifyRemote(_ specs: [[String: Any]], session: String, connections: ZeusConnections? = nil) async throws -> String {
        try ZeusAgentSchemas.validate(["checks": specs], schema: ZeusAgentSchemas.schema("task_verify_mcp")!)
        let connection = connections ?? ZeusConnections.shared
        var prepared: [(spec: [String: Any], key: String, json: String)] = []
        for spec in specs {
            let id = spec["account_id"] as! String, name = spec["tool_name"] as! String
            _ = try connection.account(id)
            let definitions = try await connection.listTools(id)
            guard let definition = definitions.first(where: { $0["name"] as? String == name }), connection.isReadOnly(id, tool: name), let schema = definition["inputSchema"] as? [String: Any] else { throw ZeusPatch.failure("Remote verification requires an advertised read-only tool and its exact schema.") }
            try ZeusAgentSchemas.validate(spec["arguments"]!, schema: schema)
            let json = try Self.json(spec)
            guard json.utf8.count <= 8000 else { throw ZeusPatch.failure("Remote verification specification exceeds 8KB; request a smaller status result.") }
            let hash = SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
            prepared.append((spec, "mcp:" + id + ":" + name + ":" + hash, json))
        }
        guard !jobs.values.contains(where: { $0.owner == session && $0.exitCode == nil }) else { throw ZeusPatch.failure("Wait for running project commands before verification.") }
        var value = state(session)
        let keys = prepared.map(\.key), generation = value.generation
        guard Set(value.remoteVerificationKeys ?? []).isSubset(of: Set(keys)) else { throw ZeusPatch.failure("Remote verification assertions cannot be removed or weakened. Run every registered check.") }
        value.remoteVerificationKeys = keys; value.remoteVerificationSpecs = prepared.map(\.json); value.remoteChecks = []; try save(session, value)
        var checks: [Check] = []
        for item in prepared {
            try Task.checkCancellation()
            if let notice = budgetNotice(session: session) { throw ZeusPatch.failure(notice) }
            let spec = item.spec
            let output: String, code: Int
            do {
                let response = try await connection.call(spec["account_id"] as! String, name: spec["tool_name"] as! String, arguments: spec["arguments"] as! [String: Any])
                output = try ZeusRemoteEvidence.evaluate(response, assertions: spec["assertions"] as! [[String: Any]]); code = 0
            } catch { output = String(error.localizedDescription.prefix(6000)); code = 1 }
            checks.append(Check(command: item.key, exitCode: code, output: output, generation: generation, date: Date()))
            value = state(session); value.remoteChecks = checks; try save(session, value)
        }
        return try Self.json(checks.map { ["command": $0.command, "exitCode": $0.exitCode, "output": $0.output, "generation": $0.generation] as [String: Any] })
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
            "remote_verification": (value.remoteVerificationSpecs ?? []).compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) },
            "remote_checks": (value.remoteChecks ?? []).map { ["key": $0.command, "exit_code": $0.exitCode, "generation": $0.generation] as [String: Any] },
            "checks": value.checks.map { ["command": $0.command, "exit_code": $0.exitCode, "generation": $0.generation] as [String: Any] },
            "recorded_tool_calls": value.ledger.count, "command_records_count": commands.count, "command_records": Dictionary(uniqueKeysWithValues: records),
            "local_commands": jobs.values.filter { $0.owner == session }.map { ["session_id": $0.id, "running": $0.exitCode == nil] as [String: Any] },
            "project_contract": try projectContext(value.project)])
    }
}

enum ZeusRemoteEvidence {
    static func evaluate(_ response: [String: Any], assertions: [[String: Any]]) throws -> String {
        guard !assertions.isEmpty else { throw ZeusPatch.failure("At least one explicit remote verification assertion is required.") }
        guard response["isError"] as? Bool != true else { throw ZeusPatch.failure("Remote status tool reported an error; verification failed.") }
        let payload: Any
        if let structured = response["structuredContent"] { payload = structured }
        else {
            let text = (response["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { throw ZeusPatch.failure("No structured JSON evidence was returned. A prose success message is not verification.") }; payload = json
        }
        var results: [[String: Any]] = []
        for assertion in assertions {
            guard let path = assertion["path"] as? [String], !path.isEmpty, let expected = assertion["equals"] else { throw ZeusPatch.failure("Malformed remote verification assertion.") }
            var actual = payload
            for key in path {
                if let object = actual as? [String: Any], let next = object[key] { actual = next }
                else if let array = actual as? [Any], let index = Int(key), array.indices.contains(index) { actual = array[index] }
                else { throw ZeusPatch.failure("Remote verification path missing: " + path.joined(separator: ".")) }
            }
            let encoded = try JSONSerialization.data(withJSONObject: actual, options: [.fragmentsAllowed, .sortedKeys])
            let target = try JSONSerialization.data(withJSONObject: expected, options: [.fragmentsAllowed, .sortedKeys])
            guard encoded == target else { throw ZeusPatch.failure("Remote verification failed at " + path.joined(separator: ".") + ": " + String(String(decoding: encoded, as: UTF8.self).prefix(1000))) }
            results.append(["path": path, "actual": actual, "passed": true])
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: results, options: .sortedKeys), as: UTF8.self)
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
            NavigationLink("متابعة المشاريع والمهام") { ZeusTaskDashboard() }
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
