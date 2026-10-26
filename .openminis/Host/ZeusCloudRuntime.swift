import SwiftUI
import UIKit
import CryptoKit
import ZEUSBrowser

/// This adapter keeps the stock transcript/composer and moves the execution
/// loop to Railway. A dropped observer never cancels the server's job.
@MainActor final class ZeusCloudRuntime {
    static let shared = ZeusCloudRuntime()
    static let globalWorkspace = "00000000-0000-4000-8000-000000000001"
    private(set) var transitionID: String?
    private var transitionOwner: String?
    private var transitionIssue: String?
    private var leaseHeartbeat: Task<Void, Never>?
    private struct Bases: Codable { let owner: String; var hashes: [String: String] }
    private var basesURL: URL { AIChatViewModel.minisConfigRoot.appendingPathComponent("zeus-local-cloud-bases.json") }
    private var observers: Set<String> = []
    private struct State: Codable {
        let owner: String
        let conversation: String
        let run: String
        var complete = false
        var assistantID: String? = nil
        var submission: Data? = nil
        var userID: String? = nil
    }
    private func stateURL(_ session: String) -> URL { AIChatViewModel.minisConfigRoot.appendingPathComponent("cloud-run-\(session).json") }
    private func failure(_ text: String) -> NSError { NSError(domain: "ZEUSCloud", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func json(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("رد الخادم غير صالح.") }; return value
    }
    private func request(_ path: String, _ body: [String: Any], method: String = "POST") async throws -> [String: Any] {
        try json(await NativeCloudAccountAPI.runtime(path, method: method, body: JSONSerialization.data(withJSONObject: body)))
    }
    func beginTransition() async throws {
        guard transitionID == nil, let owner = NativeCloudAccountAPI.ownerID else { throw failure("عملية نقل أخرى جارية.") }
        let id = UUID().uuidString.lowercased()
        _ = try await request("v1/transitions/\(id)/begin", [:])
        transitionID = id; transitionOwner = owner; transitionIssue = nil
        leaseHeartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60)); try Task.checkCancellation()
                    guard let self else { return }; try await self.validateTransition()
                } catch is CancellationError { return }
                catch { self?.transitionIssue = error.localizedDescription; return }
            }
        }
    }
    func validateTransition() async throws {
        guard let id = transitionID, transitionOwner == NativeCloudAccountAPI.ownerID else { throw failure("تغيرت جلسة نقل الحساب.") }
        if let transitionIssue { throw failure(transitionIssue) }
        _ = try await request("v1/transitions/\(id)/renew", [:])
    }
    func endTransition() async {
        leaseHeartbeat?.cancel(); leaseHeartbeat = nil
        let id = transitionID; transitionID = nil; transitionOwner = nil; transitionIssue = nil
        if let id { _ = try? await request("v1/transitions/\(id)/end", [:]) }
    }
    func baseHash(session: String) -> String? {
        guard let owner = NativeCloudAccountAPI.ownerID, let data = try? Data(contentsOf: basesURL),
              let bases = try? JSONDecoder().decode(Bases.self, from: data), bases.owner == owner else { return nil }
        return bases.hashes[session.lowercased()]
    }
    func recordBaseHash(session: String, hash: String) throws {
        guard let owner = NativeCloudAccountAPI.ownerID else { throw failure("انتهت جلسة الحساب.") }
        var bases = (try? Data(contentsOf: basesURL)).flatMap { try? JSONDecoder().decode(Bases.self, from: $0) }
        if bases?.owner != owner { bases = Bases(owner: owner, hashes: [:]) }
        bases!.hashes[session.lowercased()] = hash
        try JSONEncoder().encode(bases!).write(to: basesURL, options: .atomic)
    }
    private func importRequest(_ session: String, body: [String: Any]) async throws {
        var input = body
        if let id = transitionID { input["lease_id"] = id }
        if let hash = baseHash(session: session) { input["expected_workspace_hash"] = hash; input["replace_existing"] = true }
        _ = try await request("v1/conversations/\(session)/import", input, method: "PUT")
    }
    static func wire(_ history: [AgentMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for message in history {
            var texts: [String] = [], calls: [[String: Any]] = [], outputs: [[String: Any]] = []
            for part in message.parts {
                switch part {
                case .text(let text): texts.append(text)
                case .toolUse(let id, let name, let input, _):
                    if let data = try? JSONSerialization.data(withJSONObject: input) {
                        calls.append(["id": id, "type": "function", "function": ["name": name, "arguments": String(decoding: data, as: UTF8.self)]])
                    }
                case .toolResult(let id, _, let content, _, _, _, _, _, _): outputs.append(["role": "tool", "tool_call_id": id, "content": content])
                case .imageData(_, _, let path): texts.append("[صورة مرفقة\(path.map { ": " + $0 } ?? ""). استخدم ملفها؛ لا تدّعِ رؤيتها دون أداة رؤية.]")
                }
            }
            if !texts.isEmpty || !calls.isEmpty {
                var row: [String: Any] = ["role": message.role.rawValue, "content": texts.joined(separator: "\n")]
                if !calls.isEmpty { row["tool_calls"] = calls }; result.append(row)
            }
            result += outputs
        }
        return result
    }
    private func provider(_ vm: AIChatViewModel) throws -> [String: Any] {
        guard let entry = vm.resolveCurrentEntry(), let instance = ProviderConfigStore.shared.instance(for: entry.providerInstanceId),
              instance.credentialType == .apiKey, let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id), !key.isEmpty else {
            throw failure("التنفيذ السحابي يحتاج مزود API بمفتاح. اختر مزودًا متوافقًا من إعدادات النماذج؛ اشتراكات OAuth الحالية تبقى متاحة محليًا.")
        }
        let kind: String, base: String
        switch instance.providerType {
        case .openAIResponses: kind = "responses"; base = instance.resolvedBaseURL(default: "https://api.openai.com/v1").url
        case .openAI: kind = "openai"; base = instance.resolvedBaseURL(default: "https://api.openai.com/v1").url
        case .openRouter: kind = "openai"; base = instance.resolvedBaseURL(default: "https://openrouter.ai/api/v1").url
        case .xAI: kind = "openai"; base = instance.resolvedBaseURL(default: "https://api.x.ai/v1").url
        case .anthropic: kind = "anthropic"; base = instance.resolvedBaseURL(default: "https://api.anthropic.com/v1").url
        case .gemini where instance.effectiveCustomBaseURL == nil: kind = "openai"; base = "https://generativelanguage.googleapis.com/v1beta/openai"
        default: throw failure("بروتوكول هذا المزود غير مدعوم في الخادم الحالي. اختر OpenAI المتوافق أو Anthropic أو Gemini بمفتاح، أو عد إلى الوضع المحلي.")
        }
        return ["kind": kind, "base_url": base, "model": entry.model.id, "api_key": key,
                "max_tokens": min(max(entry.overrides.maxOutputTokens ?? 4096, 256), 8192)]
    }
    func run(_ vm: AIChatViewModel) async throws {
        guard !NativeCloudAccountAPI.isMigrating else { throw failure("انتظر انتهاء نقل الحساب.") }
        guard let sid = vm.sessionId, UUID(uuidString: sid) != nil, let owner = NativeCloudAccountAPI.ownerID else { throw failure("المحادثة أو جلسة الحساب غير متاحة.") }
        guard !observers.contains(sid) else { return }
        observers.insert(sid); defer { observers.remove(sid) }
        var state = (try? Data(contentsOf: stateURL(sid))).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        let currentUserID = vm.agentHistory.last(where: { $0.role == .user })?.dbMessageId
        let newUserTurn = state?.userID != nil && state?.userID != currentUserID
        if state?.owner != owner || state?.complete != false || newUserTurn {
            let history = Self.wire(vm.agentHistory)
            guard let last = history.last, last["role"] as? String == "user", let prompt = last["content"] as? String, !prompt.isEmpty else { throw failure("لا توجد رسالة جديدة قابلة للإرسال.") }
            let selectedProvider = try provider(vm)
            let grant = try await NativeCloudAccountAPI.fileGrant(conversation: sid)
            try await uploadAttachments(sid, grant: grant)
            state = State(owner: owner, conversation: sid, run: UUID().uuidString.lowercased(), assistantID: UUID().uuidString, userID: currentUserID)
            var body: [String: Any] = ["id": state!.run, "conversation": sid, "prompt": prompt,
                "history": Array(history.dropLast().suffix(150)), "provider": selectedProvider,
                "file_grant": grant, "permission_mode": ZeusToolPermissions.shared.mode == .askAll ? "ask_all" : ZeusToolPermissions.shared.mode.rawValue,
                "native_assistant_id": state!.assistantID!, "tools": ZeusCloudToolBridge.catalog(vm), "instructions": vm.baseSystemPrompt]
            if let userID = vm.agentHistory.last?.dbMessageId { body["native_user_id"] = userID }
            if let session = await ChatStore.shared.getSession(sid) { body["native_session"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) }
            // Preserve the exact request, including the selected provider, as
            // owner-encrypted data. A timeout can then reuse the same UUID.
            state!.submission = try await NativeCloudAccountAPI.sealSecrets(JSONSerialization.data(withJSONObject: body))
            try JSONEncoder().encode(state!).write(to: stateURL(sid), options: .atomic)
            var pending = state!
            try await submitPending(&pending, refreshGrant: false); state = pending
        } else {
            do { _ = try await NativeCloudAccountAPI.runtime("v1/runs/\(state!.run)") }
            catch let error as NativeCloudHTTPError where error.statusCode == 404 {
                if state!.submission != nil {
                    var pending = state!
                    try await submitPending(&pending, refreshGrant: true); state = pending
                }
                else {
                    state!.complete = true
                    try JSONEncoder().encode(state!).write(to: stateURL(sid), options: .atomic)
                    throw failure("لم تصل هذه المهمة إلى الخادم. يمكنك إعادة المحاولة؛ لم تُعد أي أوامر مجهولة النتيجة.")
                }
            }
        }
        guard var state else { return }
        // Replay from the server instead of trusting a device cursor that could
        // have been saved just before an iOS termination. Rendering is bounded.
        let display = ChatMessage(role: .assistant, content: "", blocks: [AssistantBlock(kind: .info, content: "التنفيذ سحابي. يمكنك مغادرة التطبيق؛ ستبقى المهمة على الخادم.")])
        vm.messages.append(display)
        var cursor = 0, text = "", tools: [String: AssistantBlock] = [:]
        var parts: [AgentContentPart] = []
        var textBlock: AssistantBlock?
        while true {
            try Task.checkCancellation()
            guard NativeCloudAccountAPI.ownerID == owner else { throw failure("تغير حساب التطبيق.") }
            if UIApplication.shared.applicationState != .active { try await Task.sleep(for: .seconds(2)); continue }
            let page: [String: Any]
            do { page = try json(await NativeCloudAccountAPI.runtime("v1/runs/\(state.run)/events?after=\(cursor)")) }
            catch {
                display.error = "انقطع الاتصال بالمراقبة. المهمة مستقلة على الخادم؛ أعد فتح المحادثة للمتابعة."
                throw error
            }
            if state.assistantID == nil || state.userID == nil {
                let metadata = page["run"] as? [String: Any]
                state.assistantID = state.assistantID ?? metadata?["native_assistant_id"] as? String
                state.userID = state.userID ?? metadata?["native_user_id"] as? String
                try JSONEncoder().encode(state).write(to: stateURL(sid), options: .atomic)
            }
            for event in page["events"] as? [[String: Any]] ?? [] {
                let data = event["data"] as? [String: Any] ?? [:]
                switch event["kind"] as? String {
                case "text":
                    let delta = data["delta"] as? String ?? ""
                    if textBlock == nil { let block = AssistantBlock(kind: .text, content: ""); display.blocks.append(block); textBlock = block }
                    text += delta; textBlock?.content += delta
                case "tool_start":
                    if !text.isEmpty { parts.append(.text(text)); text = "" }; textBlock = nil
                    let id = data["id"] as? String ?? UUID().uuidString, name = data["name"] as? String ?? ""
                    let input = data["input"] as? [String: Any] ?? [:]
                    let kind: AssistantBlockKind = name == "exec_command" ? .shellTool(command: input["cmd"] as? String ?? "") : name == "file_write" ? .fileWriteTool(path: input["path"] as? String ?? "") : name == "file_read" ? .fileReadTool(path: input["path"] as? String ?? "") : .info
                    let block = AssistantBlock(kind: kind, content: "جارٍ التنفيذ على الخادم…", toolStatus: .running, toolUseId: id)
                    display.blocks.append(block); tools[id] = block
                    parts.append(.toolUse(id: id, name: name, input: input))
                case "tool_result":
                    let id = data["id"] as? String ?? "", output = data["output"] as? String ?? ""
                    let success = data["success"] as? Bool ?? false
                    tools[id]?.content = output; tools[id]?.toolStatus = success ? .success : .failed(message: output)
                    parts.append(.toolResult(id: id, name: "cloud_tool", content: output, isError: !success))
                case "approval":
                    if let id = data["id"] as? String, let call = data["call"] as? [String: Any] {
                        let run = page["run"] as? [String: Any] ?? [:]
                        guard run["status"] as? String == "waiting_user", run["pending_approval"] as? String == id else { break }
                        let block = AssistantBlock(kind: .info, content: "بانتظار موافقتك على إجراء سحابي…")
                        display.blocks.append(block)
                        var allowed = true
                        do { try await ZeusToolPermissions.shared.authorize(tool: call["name"] as? String ?? "cloud", args: call["arguments"] as? [String: Any] ?? [:], sessionID: sid, blockID: block.id) }
                        catch is CancellationError { throw CancellationError() }
                        catch { allowed = false }
                        _ = try await request("v1/approvals/\(id)", ["allowed": allowed])
                        block.content = allowed ? "أُرسلت الموافقة إلى الخادم." : "رُفض الإجراء."
                    }
                default: break
                }
                cursor = event["seq"] as? Int ?? cursor
            }
            if let metadata = page["run"] as? [String: Any], metadata["status"] as? String == "waiting_user", let device = metadata["pending_device"] as? String {
                try await ZeusCloudToolBridge.perform(id: device, vm: vm, run: state.run)
            }
            display.error = nil; vm.scrollToBottomSignal.send()
            let run = page["run"] as? [String: Any] ?? [:], status = run["status"] as? String ?? ""
            if ["completed", "failed", "cancelled", "interrupted"].contains(status), cursor >= (run["seq"] as? Int ?? 0) {
                if !text.isEmpty { parts.append(.text(text)) }
                let message = AgentMessage(role: .assistant, parts: parts)
                var saved = message; saved.dbMessageId = state.assistantID
                saved.dbMessageId = await vm.persistAgentMessage(saved)
                vm.agentHistory.append(saved)
                ZeusCloudArchive.shared.scheduleBackup()
                state.complete = true; try JSONEncoder().encode(state).write(to: stateURL(sid), options: .atomic)
                if status != "completed" { display.error = run["error"] as? String ?? "توقفت المهمة: \(status). الملفات المحفوظة متاحة في السحابة." }
                return
            }
            try await Task.sleep(for: .milliseconds((page["events"] as? [Any])?.isEmpty == false ? 350 : 1000))
        }
    }
    private func submitPending(_ state: inout State, refreshGrant: Bool) async throws {
        guard let sealed = state.submission else { throw failure("حزمة الطلب غير متاحة.") }
        var body = try json(await NativeCloudAccountAPI.unsealSecrets(sealed))
        guard body["id"] as? String == state.run, (body["conversation"] as? String)?.lowercased() == state.conversation.lowercased() else { throw failure("حزمة الطلب لا تطابق المحادثة.") }
        if refreshGrant { body["file_grant"] = try await NativeCloudAccountAPI.fileGrant(conversation: state.conversation) }
        do { _ = try await request("v1/runs", body) }
        catch {
            let original = error
            if let http = error as? NativeCloudHTTPError, (400..<500).contains(http.statusCode), http.statusCode != 408, http.statusCode != 429 {
                do { _ = try await NativeCloudAccountAPI.runtime("v1/runs/\(state.run)") }
                catch let missing as NativeCloudHTTPError where missing.statusCode == 404 {
                    state.complete = true; state.submission = nil
                    try JSONEncoder().encode(state).write(to: stateURL(state.conversation), options: .atomic)
                }
                catch { }
            }
            throw original
        }
        state.submission = nil
        try JSONEncoder().encode(state).write(to: stateURL(state.conversation), options: .atomic)
    }
    func cancel(session: String?) {
        guard NativeCloudAccountAPI.usesCloud, let session,
              let data = try? Data(contentsOf: stateURL(session)), let state = try? JSONDecoder().decode(State.self, from: data), !state.complete else { return }
        Task { _ = try? await self.request("v1/runs/\(state.run)/cancel", [:]) }
    }
    func reconnect(_ vm: AIChatViewModel) async {
        guard NativeCloudAccountAPI.usesCloud, !vm.isProcessing, let sid = vm.sessionId, !observers.contains(sid) else { return }
        observers.insert(sid)
        do { try await restoreTranscript(vm, session: sid) }
        catch { vm.errorMessage = error.localizedDescription }
        observers.remove(sid)
        guard
              let data = try? await NativeCloudAccountAPI.runtime("v1/conversations/\(sid)"), let record = try? json(data), let run = record["latest_run"] as? String else { return }
        let local = (try? Data(contentsOf: stateURL(sid))).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        if local?.run == run && local?.complete == true { return }
        guard let owner = NativeCloudAccountAPI.ownerID else { return }
        try? JSONEncoder().encode(State(owner: owner, conversation: sid, run: run)).write(to: stateURL(sid), options: .atomic)
        vm.isProcessing = true; defer { vm.isProcessing = false }
        do { try await self.run(vm) } catch { vm.errorMessage = error.localizedDescription }
    }
    private func allConversations() async throws -> [[String: Any]] {
        var result: [[String: Any]] = [], after = ""
        while true {
            let page = try json(await NativeCloudAccountAPI.runtime("v1/conversations?after=" + after))
            result += page["conversations"] as? [[String: Any]] ?? []
            guard let next = page["next_cursor"] as? String, next > after, UUID(uuidString: next) != nil else { break }
            after = next
        }
        return result
    }
    func restoreSessionIndex() async throws {
        for record in try await allConversations() {
            guard let raw = record["native_session"] as? [String: Any] else { continue }
            let session = try JSONDecoder().decode(ChatSession.self, from: JSONSerialization.data(withJSONObject: raw))
            if await ChatStore.shared.getSession(session.id) == nil {
                _ = await ChatStore.shared.restoreSession(session, memoryEnabled: true, modelBinding: nil)
            }
        }
    }
    private func restoreTranscript(_ vm: AIChatViewModel, session: String) async throws {
        if try await restoreTranscript(session: session) { await vm.loadSession() }
    }
    func restoreAllTranscripts(progress: @escaping (String) -> Void) async throws {
        try await restoreSessionIndex()
        for session in await portableSessions() {
            progress("استعادة سجل المحادثات الأحدث…")
            _ = try await restoreTranscript(session: session.id)
        }
    }
    private func portableSessions() async -> [ChatSession] {
        let tombstoned = Set(await ChatStore.shared.tombstonedSessionIds())
        var sessions: [ChatSession] = []
        for id in await ChatStore.shared.allSessionIds() where !tombstoned.contains(id) {
            if let session = await ChatStore.shared.getSession(id) { sessions.append(session) }
        }
        return sessions
    }
    private func restoreTranscript(session: String) async throws -> Bool {
        let existing = await ChatStore.shared.loadMessages(sessionId: session)
        var known = Set(existing.map(\.id)), runs: [[String: Any]] = [], before = 4102444800.0
        while true {
            let page = try json(await NativeCloudAccountAPI.runtime("v1/conversations/\(session)/runs?before=\(before)"))
            let rows = page["runs"] as? [[String: Any]] ?? []; runs += rows
            guard rows.count == 25, let next = page["before"] as? Double, next < before else { break }; before = next
        }
        var changed = false
        for run in runs.reversed() {
            guard let runID = run["id"] as? String else { continue }
            if let userID = run["native_user_id"] as? String, !known.contains(userID), let prompt = run["prompt"] as? String {
                let raw = RawMessage(id: userID, sessionId: session, role: .user, parts: [.text(prompt)], createdAt: Date(timeIntervalSince1970: run["created"] as? Double ?? 0))
                await ChatStore.shared.appendMessage(raw); known.insert(userID); changed = true
            }
            guard let assistantID = run["native_assistant_id"] as? String, !known.contains(assistantID),
                  ["completed", "failed", "interrupted", "cancelled"].contains(run["status"] as? String ?? "") else { continue }
            var cursor = 0, parts: [AgentContentPart] = [], text = ""
            while cursor < (run["seq"] as? Int ?? 0) {
                let page = try json(await NativeCloudAccountAPI.runtime("v1/runs/\(runID)/events?after=\(cursor)"))
                let events = page["events"] as? [[String: Any]] ?? []
                guard !events.isEmpty else { throw failure("سجل المهمة غير مكتمل بعد؛ لم تُحفظ نسخة ناقصة.") }
                for event in events {
                    let value = event["data"] as? [String: Any] ?? [:]
                    switch event["kind"] as? String {
                    case "text": text += value["delta"] as? String ?? ""
                    case "tool_start":
                        if !text.isEmpty { parts.append(.text(text)); text = "" }
                        parts.append(.toolUse(id: value["id"] as? String ?? "", name: value["name"] as? String ?? "cloud", input: value["input"] as? [String: Any] ?? [:]))
                    case "tool_result": parts.append(.toolResult(id: value["id"] as? String ?? "", name: "cloud", content: value["output"] as? String ?? "", isError: value["success"] as? Bool != true))
                    default: break
                    }
                    cursor = event["seq"] as? Int ?? cursor
                }
            }
            if !text.isEmpty { parts.append(.text(text)) }
            let content: [ContentPart] = parts.compactMap { part in
                switch part {
                case .text(let text): return .text(text)
                case .toolUse(let id, let name, let input, _):
                    let encoded = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
                    return .toolUse(ToolUse(toolUseId: id, name: name, input: String(decoding: encoded, as: UTF8.self), description: input["tool_title"] as? String, thoughtSignature: nil))
                case .toolResult(let id, _, let output, let isError, _, _, _, _, _):
                    return .toolResult(ToolResult(toolUseId: id, output: output, success: !isError, mediaRef: nil, snapshot: nil, pageURL: nil, status: isError ? "failed" : "success"))
                case .imageData: return nil
                }
            }
            let raw = RawMessage(id: assistantID, sessionId: session, role: .assistant, parts: content,
                createdAt: Date(timeIntervalSince1970: (run["created"] as? Double ?? 0) + 0.001), errorInfo: run["error"] as? String)
            await ChatStore.shared.appendMessage(raw); known.insert(assistantID); changed = true
        }
        if let latest = runs.first, let id = latest["id"] as? String, let assistantID = latest["native_assistant_id"] as? String,
           known.contains(assistantID), let owner = NativeCloudAccountAPI.ownerID {
            let state = State(owner: owner, conversation: session, run: id, complete: true, assistantID: assistantID)
            try JSONEncoder().encode(state).write(to: stateURL(session), options: .atomic)
        }
        return changed
    }
    @discardableResult func importArchive(_ archive: NativeCloudArchive, fileKey: Data, progress: @escaping (String) -> Void) async throws -> Set<String> {
        guard !archive.files.contains(where: { $0.scope == "agent_sessions" && ($0.path.contains("/workspace/__zeus_inputs__/") || $0.path.hasSuffix("/workspace/__zeus_inputs__")) }) else {
            throw failure("اسم __zeus_inputs__ محجوز لفصل المرفقات عن نواتج المشروع. غيّر اسم هذا المجلد في المشروع قبل النقل؛ بقيت الملفات الأصلية محفوظة.")
        }
        let sessions = await portableSessions()
        for (index, session) in sessions.enumerated() {
            progress("ربط المحادثات وملفاتها بالخادم \(index + 1)/\(sessions.count)…")
            let prefix = session.id + "/"
            let files: [[String: Any]] = archive.files.filter { $0.scope == "agent_sessions" && $0.path.hasPrefix(prefix) }.map { entry in
                let relative = String(entry.path.dropFirst(prefix.count))
                let path = relative.hasPrefix("workspace/") ? String(relative.dropFirst(10)) : "__zeus_inputs__/" + relative
                return ["path": path, "bytes": entry.bytes, "sha256": entry.sha256, "mode": entry.mode ?? 0o600, "parts": entry.parts.map { ["sha256": $0.sha256, "bytes": $0.bytes] }]
            }
            let raw = await ChatStore.shared.loadMessages(sessionId: session.id)
            let history = Self.wire(raw.map { $0.toAgentMessage(mediaResolver: { _ in URL(fileURLWithPath: "/unavailable-media") }) })
            let grant = try await NativeCloudAccountAPI.fileGrant(conversation: session.id)
            let metadata = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session))
            try await importRequest(session.id, body: ["title": session.title ?? "", "native_session": metadata, "history": Array(history.suffix(150)), "files": files, "file_key": fileKey.base64EncodedString(), "file_grant": grant])
        }
        progress("نقل الملفات المشتركة والمهارات والذاكرة إلى الخادم…")
        let scopes = ["agent_shared": "shared", "agent_skills": "skills", "agent_memory": "memory"]
        let globals: [[String: Any]] = archive.files.compactMap { entry in
            guard let scope = scopes[entry.scope] else { return nil }
            return ["path": scope + "/" + entry.path, "bytes": entry.bytes, "sha256": entry.sha256, "mode": entry.mode ?? 0o600,
                    "parts": entry.parts.map { ["sha256": $0.sha256, "bytes": $0.bytes] }]
        }
        let grant = try await NativeCloudAccountAPI.fileGrant(conversation: Self.globalWorkspace)
        try await importRequest(Self.globalWorkspace, body: ["title": "ملفات الحساب المشتركة", "files": globals, "file_key": fileKey.base64EncodedString(), "file_grant": grant])
        return Set(sessions.map(\.id))
    }
    private func uploadAttachments(_ sid: String, grant: String) async throws {
        let root = AIChatViewModel.minisAttachmentsPersistentDir(for: sid)
        let snapshot = try ZeusOutputIndex.scan(root)
        guard !snapshot.truncated else { throw failure("المرفقات كثيرة؛ لم يُرسل طلب ناقص.") }
        guard !snapshot.entries.isEmpty else { return }
        let key = SymmetricKey(size: .bits256), bytes = key.withUnsafeBytes { Data($0) }
        var files: [[String: Any]] = []
        for item in snapshot.entries {
            let handle = try FileHandle(forReadingFrom: item.url); defer { try? handle.close() }
            var digest = SHA256()
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
            let sha = digest.finalize().map { String(format: "%02x", $0) }.joined(); try handle.seek(toOffset: 0)
            var parts: [[String: Any]] = []
            while let data = try handle.read(upToCount: 8 * 1024 * 1024 - 28), !data.isEmpty {
                let aad = Data("\(NativeCloudAccountAPI.ownerID ?? "")|\(sha)|\(parts.count)".utf8)
                guard let sealed = try AES.GCM.seal(data, using: key, authenticating: aad).combined else { throw failure("فشل تشفير المرفق.") }
                let ref = try await NativeCloudAccountAPI.putObject(sealed); parts.append(["sha256": ref.sha256, "bytes": ref.bytes])
            }
            files.append(["path": "__zeus_inputs__/attachments/" + item.relativePath, "bytes": item.bytes, "sha256": sha, "parts": parts])
        }
        _ = try await request("v1/conversations/\(sid)/import", ["files": files, "file_key": bytes.base64EncodedString(), "file_grant": grant], method: "PUT")
    }
    func restoreWorkspaces(progress: @escaping (String) -> Void) async throws {
        for record in try await allConversations() {
            guard let serverID = record["id"] as? String, serverID != Self.globalWorkspace else { continue }
            let id = (record["native_session"] as? [String: Any])?["id"] as? String ?? serverID
            progress("استعادة الملفات الأحدث للمحادثة…")
            try await ZeusCloudFiles.downloadAll(session: id)
        }
        let globals = try await ZeusCloudFiles.snapshot(session: Self.globalWorkspace)
        for entry in globals.files {
            let parts = entry.path.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let roots = ["shared": AIChatViewModel.minisSharedPersistentDir, "skills": AIChatViewModel.minisSkillsPersistentDir, "memory": AIChatViewModel.minisMemoryPersistentDir]
            guard let root = roots[String(parts[0])] else { continue }
            _ = try await ZeusCloudFiles.download(entry, session: Self.globalWorkspace, to: root.appendingPathComponent(String(parts[1])))
        }
        guard try await ZeusCloudFiles.snapshot(session: Self.globalWorkspace).hash == globals.hash else { throw failure("تغيرت الملفات المشتركة أثناء الاستعادة؛ أعد المحاولة.") }
        try recordBaseHash(session: Self.globalWorkspace, hash: globals.hash)
    }
}
