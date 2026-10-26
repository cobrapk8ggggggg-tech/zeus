import SwiftUI
import UIKit
import CryptoKit
import ZEUSBrowser

/// This adapter keeps the stock transcript/composer and moves the execution
/// loop to Railway. A dropped observer never cancels the server's job.
@MainActor final class ZeusCloudRuntime {
    static let shared = ZeusCloudRuntime()
    private var observers: Set<String> = []
    private struct State: Codable {
        let owner: String
        let conversation: String
        let run: String
        var complete = false
    }
    private func stateURL(_ session: String) -> URL { AIChatViewModel.minisConfigRoot.appendingPathComponent("cloud-run-\(session).json") }
    private func failure(_ text: String) -> NSError { NSError(domain: "ZEUSCloud", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func json(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("رد الخادم غير صالح.") }; return value
    }
    private func request(_ path: String, _ body: [String: Any], method: String = "POST") async throws -> [String: Any] {
        try json(await NativeCloudAccountAPI.runtime(path, method: method, body: JSONSerialization.data(withJSONObject: body)))
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
        if state?.owner != owner || state?.complete != false {
            let history = Self.wire(vm.agentHistory)
            guard let last = history.last, last["role"] as? String == "user", let prompt = last["content"] as? String, !prompt.isEmpty else { throw failure("لا توجد رسالة جديدة قابلة للإرسال.") }
            let selectedProvider = try provider(vm)
            let grant = try await NativeCloudAccountAPI.fileGrant(conversation: sid)
            try await uploadAttachments(sid, grant: grant)
            state = State(owner: owner, conversation: sid, run: UUID().uuidString.lowercased())
            // Save the idempotency key before the request, including on timeout.
            try JSONEncoder().encode(state!).write(to: stateURL(sid), options: .atomic)
            _ = try await request("v1/runs", ["id": state!.run, "conversation": sid, "prompt": prompt,
                "history": Array(history.dropLast().suffix(150)), "provider": selectedProvider,
                "file_grant": grant, "permission_mode": ZeusToolPermissions.shared.mode == .askAll ? "ask_all" : ZeusToolPermissions.shared.mode.rawValue])
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
            display.error = nil; vm.scrollToBottomSignal.send()
            let run = page["run"] as? [String: Any] ?? [:], status = run["status"] as? String ?? ""
            if ["completed", "failed", "cancelled", "interrupted"].contains(status), cursor >= (run["seq"] as? Int ?? 0) {
                if !text.isEmpty { parts.append(.text(text)) }
                let message = AgentMessage(role: .assistant, parts: parts)
                var saved = message; saved.dbMessageId = await vm.persistAgentMessage(message)
                vm.agentHistory.append(saved)
                state.complete = true; try JSONEncoder().encode(state).write(to: stateURL(sid), options: .atomic)
                if status != "completed" { display.error = run["error"] as? String ?? "توقفت المهمة: \(status). الملفات المحفوظة متاحة في السحابة." }
                return
            }
            try await Task.sleep(for: .milliseconds((page["events"] as? [Any])?.isEmpty == false ? 350 : 1000))
        }
    }
    func cancel(session: String?) {
        guard NativeCloudAccountAPI.usesCloud, let session,
              let data = try? Data(contentsOf: stateURL(session)), let state = try? JSONDecoder().decode(State.self, from: data), !state.complete else { return }
        Task { _ = try? await self.request("v1/runs/\(state.run)/cancel", [:]) }
    }
    func reconnect(_ vm: AIChatViewModel) async {
        guard NativeCloudAccountAPI.usesCloud, !vm.isProcessing, let sid = vm.sessionId, !observers.contains(sid),
              let data = try? await NativeCloudAccountAPI.runtime("v1/conversations/\(sid)"), let record = try? json(data), let run = record["latest_run"] as? String else { return }
        let local = (try? Data(contentsOf: stateURL(sid))).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        if local?.run == run && local?.complete == true { return }
        guard let owner = NativeCloudAccountAPI.ownerID else { return }
        try? JSONEncoder().encode(State(owner: owner, conversation: sid, run: run)).write(to: stateURL(sid), options: .atomic)
        vm.isProcessing = true; defer { vm.isProcessing = false }
        do { try await self.run(vm) } catch { vm.errorMessage = error.localizedDescription }
    }
    func importArchive(_ archive: NativeCloudArchive, fileKey: Data, progress: @escaping (String) -> Void) async throws {
        let sessions = await ChatStore.shared.listSessions()
        for (index, session) in sessions.enumerated() {
            progress("ربط المحادثات وملفاتها بالخادم \(index + 1)/\(sessions.count)…")
            let prefix = session.id + "/"
            let files: [[String: Any]] = archive.files.filter { $0.scope == "agent_sessions" && $0.path.hasPrefix(prefix) }.map { entry in
                let relative = String(entry.path.dropFirst(prefix.count))
                let path = relative.hasPrefix("workspace/") ? String(relative.dropFirst(10)) : relative
                return ["path": path, "bytes": entry.bytes, "sha256": entry.sha256, "parts": entry.parts.map { ["sha256": $0.sha256, "bytes": $0.bytes] }]
            }
            let raw = await ChatStore.shared.loadMessages(sessionId: session.id)
            let history = Self.wire(raw.map { $0.toAgentMessage(mediaResolver: { _ in URL(fileURLWithPath: "/unavailable-media") }) })
            let grant = try await NativeCloudAccountAPI.fileGrant(conversation: session.id)
            _ = try await request("v1/conversations/\(session.id)/import", ["title": session.title ?? "", "history": Array(history.suffix(150)), "files": files, "file_key": fileKey.base64EncodedString(), "file_grant": grant], method: "PUT")
        }
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
            files.append(["path": "attachments/" + item.relativePath, "bytes": item.bytes, "sha256": sha, "parts": parts])
        }
        _ = try await request("v1/conversations/\(sid)/import", ["files": files, "file_key": bytes.base64EncodedString(), "file_grant": grant], method: "PUT")
    }
    func restoreWorkspaces(progress: @escaping (String) -> Void) async throws {
        let data = try await NativeCloudAccountAPI.runtime("v1/conversations")
        for record in try json(data)["conversations"] as? [[String: Any]] ?? [] {
            guard let id = record["id"] as? String else { continue }
            progress("استعادة الملفات الأحدث للمحادثة…")
            try await ZeusCloudFiles.downloadAll(session: id)
        }
    }
}
