import Foundation
import CoreFoundation

/// Provider-independent JSON schemas for the native execution runtime.
/// These are real nested schemas, not JSON encoded inside string parameters.
enum ZeusAgentSchemas {
    static let names: Set<String> = ["update_plan", "apply_patch", "exec_command", "write_stdin", "task_checkpoint", "task_verify", "task_complete"]
    static func schema(_ name: String) -> [String: Any]? {
        var fields: [String: Any] = ["tool_title": ["type": "string"], "approval_reason": ["type": "string"]]
        var requiredFields: [String] = []
        switch name {
        case "update_plan":
            fields.merge(["explanation": ["type": "string"], "goal": ["type": "string"], "plan": ["type": "array", "minItems": 1, "maxItems": 30,
                "items": ["type": "object", "properties": ["step": ["type": "string", "minLength": 1], "status": ["type": "string", "enum": ["pending", "in_progress", "completed"]]], "required": ["step", "status"], "additionalProperties": false]], "verification_commands": ["type": "array", "maxItems": 15, "items": ["type": "string", "minLength": 1]]]) { _, b in b }; requiredFields = ["plan"]
        case "apply_patch":
            fields.merge(["patch": ["type": "string", "minLength": 1, "maxLength": 500000], "workdir": ["type": "string"]]) { _, b in b }; requiredFields = ["patch"]
        case "exec_command":
            fields.merge(["cmd": ["type": "string", "minLength": 1], "workdir": ["type": "string"], "yield_time_ms": ["type": "integer", "minimum": 0, "maximum": 30000], "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 7200], "max_output_chars": ["type": "integer", "minimum": 100, "maximum": 30000]]) { _, b in b }; requiredFields = ["cmd"]
        case "write_stdin":
            fields.merge(["session_id": ["type": "string"], "chars": ["type": "string"], "offset": ["type": "integer", "minimum": 0], "yield_time_ms": ["type": "integer", "minimum": 0, "maximum": 30000], "max_output_chars": ["type": "integer", "minimum": 100, "maximum": 30000], "terminate": ["type": "boolean"]]) { _, b in b }; requiredFields = ["session_id"]
        case "task_checkpoint":
            fields.merge(["note": ["type": "string", "maxLength": 16000], "action": ["type": "string", "enum": ["read", "save"]]]) { _, b in b }
        case "task_verify":
            fields.merge(["commands": ["type": "array", "minItems": 1, "maxItems": 15, "items": ["type": "string", "minLength": 1]], "workdir": ["type": "string"], "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 3600]]) { _, b in b }; requiredFields = ["commands"]
        case "task_complete":
            fields.merge(["status": ["type": "string", "enum": ["completed", "blocked", "waiting_user"]], "summary": ["type": "string", "minLength": 1], "limitations": ["type": "string"]]) { _, b in b }; requiredFields = ["status", "summary"]
        default: return nil
        }
        return ["type": "object", "properties": fields, "required": requiredFields, "additionalProperties": false]
    }
    static func validate(_ value: Any, schema: [String: Any], path: String = "arguments") throws {
        func invalid(_ why: String) -> NSError { NSError(domain: "ZeusSchema", code: 1, userInfo: [NSLocalizedDescriptionKey: "INVALID_ARGUMENTS: \(path): \(why). Nothing was executed; correct the structured call."]) }
        if let options = schema["enum"] as? [String], let string = value as? String, !options.contains(string) { throw invalid("expected one of \(options.joined(separator: ", "))") }
        switch schema["type"] as? String {
        case "object":
            guard let object = value as? [String: Any] else { throw invalid("expected an object") }
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            for key in schema["required"] as? [String] ?? [] where object[key] == nil || object[key] is NSNull { throw invalid("missing \(key)") }
            for (key, child) in object {
                if let shape = properties[key] { try validate(child, schema: shape, path: path + "." + key) }
                else if schema["additionalProperties"] as? Bool == false { throw invalid("unknown field \(key)") }
            }
        case "array":
            guard let array = value as? [Any] else { throw invalid("expected an array, not an encoded JSON string") }
            if let n = schema["minItems"] as? Int, array.count < n { throw invalid("needs at least \(n) items") }
            if let n = schema["maxItems"] as? Int, array.count > n { throw invalid("too many items") }
            if let shape = schema["items"] as? [String: Any] { for (i, item) in array.enumerated() { try validate(item, schema: shape, path: "\(path)[\(i)]") } }
        case "string":
            guard let string = value as? String else { throw invalid("expected a string") }
            if let n = schema["minLength"] as? Int, string.count < n { throw invalid("string is too short") }
            if let n = schema["maxLength"] as? Int, string.count > n { throw invalid("string is too long") }
        case "integer", "number":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw invalid("expected a finite number") }
            let n = number.doubleValue
            if schema["type"] as? String == "integer", n.rounded() != n { throw invalid("expected an integer") }
            if let min = schema["minimum"] as? Double, n < min { throw invalid("below minimum") }
            if let max = schema["maximum"] as? Double, n > max { throw invalid("above maximum") }
        case "boolean":
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid("expected a boolean") }
        default: break
        }
    }
    static func gemini(_ input: [String: Any]) -> [String: Any] {
        var output = input
        if let type = output["type"] as? String { output["type"] = type.uppercased() }
        output.removeValue(forKey: "additionalProperties")
        if let props = output["properties"] as? [String: [String: Any]] { output["properties"] = props.mapValues(gemini) }
        if let items = output["items"] as? [String: Any] { output["items"] = gemini(items) }
        return output
    }
    static func patchAnthropic(_ request: NSMutableURLRequest) {
        guard let data = request.httpBody, var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], var tools = root["tools"] as? [[String: Any]] else { return }
        var changed = false
        for i in tools.indices {
            if let name = tools[i]["name"] as? String, let schema = schema(name) { tools[i]["input_schema"] = schema; changed = true }
        }
        if changed { root["tools"] = tools; request.httpBody = try? JSONSerialization.data(withJSONObject: root) }
    }
}
