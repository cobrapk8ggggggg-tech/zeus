import Foundation
import UIKit
import ZEUSBrowser

/// Uses the original canonical registry and executor. No parallel tool catalog
/// lives in the app; Linux tools are dispatched by the server under the same names.
@MainActor enum ZeusCloudToolBridge {
    static func catalog(_ vm: AIChatViewModel) -> [[String: Any]] {
        vm.makeAgentTools().map { tool in
            var properties: [String: Any] = [:]
            for (key, value) in tool.parameters {
                var schema: [String: Any] = ["type": value.type.rawValue, "description": value.description]
                if let values = value.enumValues { schema["enum"] = values }
                properties[key] = schema
            }
            let schema = ZeusAgentSchemas.schema(tool.name) ?? ["type": "object", "properties": properties, "required": tool.required]
            return ["name": tool.name, "description": tool.description, "parameters": schema]
        }
    }
    private struct Journal: Codable {
        let owner: String
        let claimant: String
        var executing = false
        var acknowledged: Bool? = nil
        var output: String?
        var success: Bool?
        var image: Data?
        var imageMime: String?
    }
    static func perform(id: String, vm: AIChatViewModel, run: String) async throws {
        guard let owner = NativeCloudAccountAPI.ownerID, UUID(uuidString: id) != nil,
              UIApplication.shared.applicationState == .active else { return }
        let file = AIChatViewModel.minisConfigRoot.appendingPathComponent("device-tool-" + id + ".json")
        let existing = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Journal.self, from: $0) }
        if let existing, existing.owner != owner { throw issue("طلب الأداة يخص حسابًا آخر.") }
        var journal = existing ?? Journal(owner: owner, claimant: UUID().uuidString.lowercased())
        if journal.acknowledged == true { return }
        func save() throws { try JSONEncoder().encode(journal).write(to: file, options: .atomic) }
        func request(_ operation: String, _ body: [String: Any]) async throws -> [String: Any] {
            let data = try await NativeCloudAccountAPI.runtime("v1/device-tools/\(id)/\(operation)", method: "POST", body: JSONSerialization.data(withJSONObject: body))
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        try save()
        if journal.output == nil {
            guard !journal.executing else { throw issue("انقطع الجهاز أثناء تنفيذ هذه الأداة. لن نكرر إجراءً مجهول النتيجة تلقائيًا؛ راجع نتيجته وأوقف المهمة عند الحاجة.") }
            let value = try await request("claim", ["claimant": journal.claimant])
            guard let call = value["call"] as? [String: Any], let name = call["name"] as? String,
                  let callID = call["id"] as? String, let originalArgs = call["arguments"] as? [String: Any],
                  let msgIdx = vm.messages.indices.last else { throw issue("طلب أداة غير صالح.") }
            // Cloud execution must never fall back to the device filesystem or
            // shell, even if a stale server dispatches a server-owned tool here.
            let serverTools: Set<String> = ["exec_command", "write_stdin", "shell_execute", "file_read", "file_write", "file_edit", "memory_get", "memory_write", "apply_patch", "file_list", "task_checkpoint", "history_read"]
            guard !serverTools.contains(name), !name.hasPrefix("android_") else {
                throw issue("هذه الأداة تنفذ على الخادم فقط؛ رُفض تحويلها إلى الجهاز.")
            }
            var args = originalArgs
            var staged: URL?
            defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
            if name == "read_image", let path = args["path"] as? String, let session = vm.sessionId {
                var remote = path
                for prefix in ["/var/minis/workspace/", "minis://workspace/"] where remote.hasPrefix(prefix) { remote = String(remote.dropFirst(prefix.count)) }
                for scope in ["attachments", "offloads", "browser"] {
                    for prefix in ["/var/minis/" + scope + "/", "minis://" + scope + "/"] where remote.hasPrefix(prefix) { remote = "__zeus_inputs__/" + scope + "/" + String(remote.dropFirst(prefix.count)) }
                }
                if let entry = try await ZeusCloudFiles.list(session: session).first(where: { $0.path == remote }) {
                    let localName = UUID().uuidString + "-" + URL(fileURLWithPath: remote).lastPathComponent
                    let target = AIChatViewModel.minisAttachmentsPersistentDir(for: session).appendingPathComponent(".cloud-preview/" + localName)
                    _ = try await ZeusCloudFiles.download(entry, session: session, to: target)
                    staged = target; args["path"] = "/var/minis/attachments/.cloud-preview/" + localName
                }
            }
            let definitions = vm.makeAgentTools()
            guard definitions.contains(where: { $0.name == name }) else { throw issue("الأداة غير مفعلة في هذه المحادثة.") }
            let index: Int
            if let found = vm.messages[msgIdx].blocks.firstIndex(where: { $0.toolUseId == callID }) { index = found }
            else {
                let block = AssistantBlock(kind: ZeusToolPresentation.kind(name, input: args), content: "", toolStatus: .running, toolUseId: callID)
                block.toolSummary = args["tool_title"] as? String
                block.toolInputArgs = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
                vm.messages[msgIdx].blocks.append(block)
                index = vm.messages[msgIdx].blocks.count - 1
            }
            journal.executing = true; try save()
            let entry = AIChatViewModel.StreamResult.ToolEntry(id: callID, name: name, args: args, blockIdx: index, metadata: nil, inputChunkRing: [])
            let outcome = await vm.executeSingleToolUse(tu: entry, msgIdx: msgIdx, tools: definitions, batchBudget: AIChatViewModel.BatchImageBudget(initial: 1))
            if case .toolResult(_, _, let text, let isError, let image, let mime, _, _, _) = outcome.resultPart {
                journal.output = String(text.prefix(32000)); journal.success = !isError
                if let image, let decoded = UIImage(data: image) {
                    let factor = min(1, 1280 / max(decoded.size.width, decoded.size.height))
                    let size = CGSize(width: decoded.size.width * factor, height: decoded.size.height * factor)
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1
                    let reduced = UIGraphicsImageRenderer(size: size, format: format).image { _ in decoded.draw(in: CGRect(origin: .zero, size: size)) }
                    if let jpeg = reduced.jpegData(compressionQuality: 0.72), jpeg.count <= 900000 {
                        journal.image = jpeg; journal.imageMime = "image/jpeg"
                    } else if image.count <= 900000 { journal.image = image; journal.imageMime = mime }
                }
            } else { journal.output = "لم تنتج الأداة نتيجة صالحة."; journal.success = false }
            try save()
        }
        var result: [String: Any] = ["claimant": journal.claimant, "output": journal.output ?? "", "success": journal.success == true]
        if let image = journal.image { result["image"] = ["mime": journal.imageMime ?? "image/jpeg", "data": image.base64EncodedString()] }
        _ = try await request("result", result)
        journal.acknowledged = true; journal.executing = false
        journal.output = nil; journal.image = nil; journal.imageMime = nil; try save()
        // Retain the small journal until the job leaves waiting_user. Replaying
        // its result is idempotent; its actual side effect is never repeated.
    }
    private static func issue(_ text: String) -> NSError { NSError(domain: "ZEUSCloudDeviceTool", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
