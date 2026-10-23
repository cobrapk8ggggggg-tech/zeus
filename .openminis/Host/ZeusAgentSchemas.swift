import Foundation
import CoreFoundation

/// Provider-independent JSON schemas for the native execution runtime.
/// These are real nested schemas, not JSON encoded inside string parameters.
enum ZeusAgentSchemas {
    static let names: Set<String> = ["update_plan", "apply_patch", "exec_command", "write_stdin", "task_checkpoint", "task_verify", "task_verify_mcp", "task_complete", "integration_accounts", "integration_tools", "integration_call"]
    static func schema(_ name: String) -> [String: Any]? {
        var fields: [String: Any] = ["tool_title": ["type": "string"], "approval_reason": ["type": "string"]]
        var requiredFields: [String] = []
        switch name {
        case "integration_accounts": break
        case "integration_tools":
            fields["account_id"] = ["type": "string"]; fields["provider"] = ["type": "string", "enum": ["github", "railway", "vercel"]]
            fields["query"] = ["type": "string"]; fields["limit"] = ["type": "integer", "minimum": 1, "maximum": 50]
        case "integration_call":
            fields["account_id"] = ["type": "string"]; fields["tool_name"] = ["type": "string"]
            fields["arguments"] = ["type": "object", "additionalProperties": true]; requiredFields = ["account_id", "tool_name", "arguments"]
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
        case "task_verify_mcp":
            let assertion: [String: Any] = ["type": "object", "properties": ["path": ["type": "array", "minItems": 1, "maxItems": 12, "items": ["type": "string"]], "equals": ["type": ["string", "number", "boolean", "null"]]], "required": ["path", "equals"], "additionalProperties": false]
            let check: [String: Any] = ["type": "object", "properties": ["account_id": ["type": "string"], "tool_name": ["type": "string"], "arguments": ["type": "object", "additionalProperties": true], "assertions": ["type": "array", "minItems": 1, "maxItems": 10, "items": assertion]], "required": ["account_id", "tool_name", "arguments", "assertions"], "additionalProperties": false]
            fields["checks"] = ["type": "array", "minItems": 1, "maxItems": 15, "items": check]; requiredFields = ["checks"]
        default: return nil
        }
        return ["type": "object", "properties": fields, "required": requiredFields, "additionalProperties": false]
    }
    static func validate(_ value: Any, schema: [String: Any], path: String = "arguments", root: [String: Any]? = nil, depth: Int = 0) throws {
        func invalid(_ why: String) -> NSError { NSError(domain: "ZeusSchema", code: 1, userInfo: [NSLocalizedDescriptionKey: "INVALID_ARGUMENTS: \(path): \(why). Nothing was executed; correct the structured call."]) }
        guard depth <= 64 else { throw invalid("schema nesting exceeds the limit") }
        let root = root ?? schema
        if let reference = schema["$ref"] as? String {
            guard reference.hasPrefix("#/") else { throw invalid("external schema references are not supported") }
            var target: Any = root
            for part in reference.dropFirst(2).split(separator: "/") {
                let key = String(part).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                guard let next = (target as? [String: Any])?[key] else { throw invalid("unresolved schema reference") }; target = next
            }
            guard let shape = target as? [String: Any] else { throw invalid("invalid schema reference") }
            try validate(value, schema: shape, path: path, root: root, depth: depth + 1)
        }
        if let types = schema["type"] as? [String] {
            for type in types { var shape = schema; shape["type"] = type; if (try? validate(value, schema: shape, path: path, root: root, depth: depth + 1)) != nil { return } }
            throw invalid("value does not match the allowed types")
        }
        for keyword in ["anyOf", "oneOf", "allOf"] {
            if let shapes = schema[keyword] as? [[String: Any]] {
                let matched = shapes.filter { (try? validate(value, schema: $0, path: path, root: root, depth: depth + 1)) != nil }.count
                guard keyword == "allOf" ? matched == shapes.count : keyword == "oneOf" ? matched == 1 : matched > 0 else { throw invalid("value does not satisfy \(keyword)") }
            }
        }
        if let options = schema["enum"] as? [Any] {
            let encoded = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            guard options.contains(where: { (try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys])) == encoded }) else { throw invalid("value is outside the enum") }
        }
        switch schema["type"] as? String {
        case "null": guard value is NSNull else { throw invalid("expected null") }
        case "object":
            guard let object = value as? [String: Any] else { throw invalid("expected an object") }
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            for key in schema["required"] as? [String] ?? [] where object[key] == nil { throw invalid("missing \(key)") }
            for (key, child) in object {
                if let shape = properties[key] { try validate(child, schema: shape, path: path + "." + key, root: root, depth: depth + 1) }
                else if let shape = schema["additionalProperties"] as? [String: Any] { try validate(child, schema: shape, path: path + "." + key, root: root, depth: depth + 1) }
                else if schema["additionalProperties"] as? Bool == false { throw invalid("unknown field \(key)") }
            }
        case "array":
            guard let array = value as? [Any] else { throw invalid("expected an array, not an encoded JSON string") }
            if let n = schema["minItems"] as? Int, array.count < n { throw invalid("needs at least \(n) items") }
            if let n = schema["maxItems"] as? Int, array.count > n { throw invalid("too many items") }
            if let shape = schema["items"] as? [String: Any] { for (i, item) in array.enumerated() { try validate(item, schema: shape, path: "\(path)[\(i)]", root: root, depth: depth + 1) } }
        case "string":
            guard let string = value as? String else { throw invalid("expected a string") }
            if let n = schema["minLength"] as? Int, string.count < n { throw invalid("string is too short") }
            if let n = schema["maxLength"] as? Int, string.count > n { throw invalid("string is too long") }
            if let pattern = schema["pattern"] as? String, try NSRegularExpression(pattern: pattern).firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) == nil { throw invalid("string does not match the schema pattern") }
        case "integer", "number":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw invalid("expected a finite number") }
            let n = number.doubleValue
            if schema["type"] as? String == "integer", n.rounded() != n { throw invalid("expected an integer") }
            if let min = (schema["minimum"] as? NSNumber)?.doubleValue, n < min { throw invalid("below minimum") }
            if let max = (schema["maximum"] as? NSNumber)?.doubleValue, n > max { throw invalid("above maximum") }
        case "boolean":
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid("expected a boolean") }
        default: break
        }
    }
    static func openAI(_ name: String, description: String, responses: Bool) -> [String: Any]? {
        guard let shape = schema(name) else { return nil }
        // Responses otherwise normalizes omitted strictness and may reject
        // dynamic integration arguments or silently require optional fields.
        var function: [String: Any] = ["name": name, "description": description, "parameters": shape, "strict": false]
        if responses { function["type"] = "function"; return function }
        return ["type": "function", "function": function]
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
