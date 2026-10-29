import Foundation

enum ZeusCloudCache {
    static func encode(_ parts: [[String: Any]]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: parts, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    static func signature(_ parts: [ContentPart]) -> String? {
        var result: [[String: Any]] = []
        for part in parts {
            switch part {
            case .text(let text): result.append(["type": "text", "text": text])
            case .toolUse(let call):
                guard let input = try? JSONSerialization.jsonObject(with: Data(call.input.utf8)) else { return nil }
                result.append(["type": "tool", "id": call.toolUseId, "name": call.name, "input": input])
            case .toolResult(let value):
                // Media remains local until its own remote reference is verified.
                guard value.mediaRef == nil && value.snapshot == nil && value.pageURL == nil else { return nil }
                result.append(["type": "result", "id": value.toolUseId, "output": value.output, "success": value.success])
            default: return nil
            }
        }
        return encode(result)
    }
    static func eventsSignature(_ events: [[String: Any]]) -> String? {
        var result: [[String: Any]] = [], text = ""
        func flush() { if !text.isEmpty { result.append(["type": "text", "text": text]); text = "" } }
        for event in events {
            let data = event["data"] as? [String: Any] ?? [:]
            switch event["kind"] as? String {
            case "text": text += data["delta"] as? String ?? ""
            case "tool_start":
                flush()
                result.append(["type": "tool", "id": data["id"] as? String ?? "", "name": data["name"] as? String ?? "", "input": data["input"] as? [String: Any] ?? [:]])
            case "tool_result": result.append(["type": "result", "id": data["id"] as? String ?? "", "output": data["output"] as? String ?? "", "success": data["success"] as? Bool ?? false])
            default: break
            }
        }
        flush(); return encode(result)
    }
}
