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
        var output: String?
        var success: Bool?
    }
    static func perform(id: String, vm: AIChatViewModel, run: String) async throws {
        guard let owner = NativeCloudAccountAPI.ownerID, UUID(uuidString: id) != nil,
              UIApplication.shared.applicationState == .active else { return }
        let file = AIChatViewModel.minisConfigRoot.appendingPathComponent("device-tool-" + id + ".json")
        let existing = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Journal.self, from: $0) }
        if let existing, existing.owner != owner { throw issue("طلب الأداة يخص حسابًا آخر.") }
        var journal = existing ?? Journal(owner: owner, claimant: UUID().uuidString.lowercased())
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
                  let callID = call["id"] as? String, let args = call["arguments"] as? [String: Any],
                  let msgIdx = vm.messages.indices.last else { throw issue("طلب أداة غير صالح.") }
            let definitions = vm.makeAgentTools()
            guard definitions.contains(where: { $0.name == name }) else { throw issue("الأداة غير مفعلة في هذه المحادثة.") }
            let block = AssistantBlock(kind: .info, content: "التنفيذ بالأداة الأصلية على الجهاز…", toolStatus: .running, toolUseId: callID)
            vm.messages[msgIdx].blocks.append(block)
            let index = vm.messages[msgIdx].blocks.count - 1
            journal.executing = true; try save()
            let entry = AIChatViewModel.StreamResult.ToolEntry(id: callID, name: name, args: args, blockIdx: index, metadata: nil, inputChunkRing: [])
            let outcome = await vm.executeSingleToolUse(tu: entry, msgIdx: msgIdx, tools: definitions, batchBudget: AIChatViewModel.BatchImageBudget(initial: 1))
            if case .toolResult(_, _, let text, let isError, _, _, _, _, _) = outcome.resultPart {
                journal.output = String(text.prefix(32000)); journal.success = !isError
            } else { journal.output = "لم تنتج الأداة نتيجة صالحة."; journal.success = false }
            try save()
        }
        _ = try await request("result", ["claimant": journal.claimant, "output": journal.output ?? "", "success": journal.success == true])
        // Retain the small journal until the job leaves waiting_user. Replaying
        // its result is idempotent; its actual side effect is never repeated.
    }
    private static func issue(_ text: String) -> NSError { NSError(domain: "ZEUSCloudDeviceTool", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
