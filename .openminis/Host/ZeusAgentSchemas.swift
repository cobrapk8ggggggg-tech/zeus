import Foundation
import CoreFoundation

/// Provider-independent JSON schemas for the native execution runtime.
/// These are real nested schemas, not JSON encoded inside string parameters.
enum ZeusAgentSchemas {
    static let names: Set<String> = ["update_plan", "apply_patch", "exec_command", "write_stdin", "task_checkpoint", "task_verify", "task_verify_mcp", "task_complete", "integration_accounts", "integration_tools", "integration_call", "project_environment", "propose_project_plan", "github_request", "task_verify_github", "github_download_artifact", "github_read_file", "github_write_files", "github_project_inspect"]
    static func schema(_ name: String) -> [String: Any]? {
        var fields: [String: Any] = ["tool_title": ["type": "string"], "approval_reason": ["type": "string"]]
        var requiredFields: [String] = []
        switch name {
        case "project_environment": break
        case "propose_project_plan":
            let text: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 240]
            let identifier: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 80, "description": "A unique stable identifier. Reuse a feature id exactly in checks.covers; these IDs are bookkeeping, not filenames."]
            let feature: [String: Any] = ["type": "object", "properties": ["id": identifier, "title": text], "required": ["id", "title"], "additionalProperties": false]
            let criterion: [String: Any] = ["type": "object", "properties": ["id": identifier, "title": text, "kind": ["type": "string", "enum": ["build", "functional", "ui", "quality"]], "covers": ["type": "array", "maxItems": 20, "items": identifier, "description": "Exact proposal.features[].id values tested by this functional/UI check. Example: features=[{id:offline,title:Offline playback}], covers=[offline]. Do not put check IDs, filenames or command names here. Use [*] explicitly to cover all features."], "command": ["type": "string", "maxLength": 2000], "github_job": ["type": "string", "description": "Planned GitHub Actions job display name, matching jobs.<key>.name (or key when no name). Not a numeric job ID."], "github_step": ["type": "string", "description": "Planned exact step name in that workflow. Create the workflow with this explicit name and actual build/test command."], "artifact": ["type": "string", "description": "Planned uploaded artifact name for app build/UI screenshots; create a real upload-artifact step with this name."], "screenshot_path": ["type": "string", "maxLength": 500, "description": "Local path to the actual app screenshot after artifact download/extraction, for read_image review."]], "required": ["id", "title", "kind", "covers"], "additionalProperties": false]
            let list: [String: Any] = ["type": "array", "minItems": 1, "maxItems": 20, "items": text]
            let proposal: [String: Any] = ["type": "object", "properties": ["title": text, "objective": ["type": "string", "minLength": 1, "maxLength": 2000], "platform": ["type": "string", "enum": ["ios", "android", "web", "backend", "other"]], "features": ["type": "array", "minItems": 1, "maxItems": 20, "items": feature], "architecture": list, "steps": list, "checks": ["type": "array", "minItems": 2, "maxItems": 20, "items": criterion], "deliverables": list, "assumptions": ["type": "array", "maxItems": 15, "items": text], "design_reference_notes": ["type": "array", "maxItems": 20, "items": text], "build_route": ["type": "string", "enum": ["local", "github_actions"]], "github_account_id": ["type": "string"], "repository": ["type": "string", "pattern": "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"], "branch": text, "workflow": ["type": "string", "pattern": "^\\.github/workflows/[A-Za-z0-9_.-]+\\.ya?ml$"]], "required": ["title", "objective", "platform", "features", "architecture", "steps", "checks", "deliverables", "assumptions", "build_route"], "additionalProperties": false]
            fields["proposal"] = proposal; requiredFields = ["proposal"]
        case "github_read_file", "github_write_files":
            fields["account_id"] = ["type": "string"]; fields["repository"] = ["type": "string", "pattern": "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"]
            fields["branch"] = ["type": "string", "minLength": 1, "maxLength": 240]
            requiredFields = ["account_id", "repository", "branch"]
            if name == "github_read_file" {
                fields["path"] = ["type": "string", "minLength": 1, "maxLength": 500]; requiredFields += ["path"]
                fields["offset"] = ["type": "integer", "minimum": 0]
                fields["max_chars"] = ["type": "integer", "minimum": 1, "maximum": 10000]
            } else {
                fields["message"] = ["type": "string", "minLength": 1, "maxLength": 500]
                let file: [String: Any] = ["type": "object", "properties": ["path": ["type": "string", "minLength": 1, "maxLength": 500], "content": ["type": "string", "maxLength": 120000], "delete": ["type": "boolean"]], "required": ["path"], "additionalProperties": false]
                fields["files"] = ["type": "array", "minItems": 1, "maxItems": 30, "items": file]
                requiredFields += ["message", "files"]
            }
        case "github_project_inspect":
            fields["account_id"] = ["type": "string"]
            fields["repository"] = ["type": "string", "pattern": "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"]
            fields["branch"] = ["type": "string", "minLength": 1, "maxLength": 240]
            fields["action"] = ["type": "string", "enum": ["tree", "diff"]]
            fields["base"] = ["type": "string", "minLength": 1, "maxLength": 240]
            fields["tree_sha"] = ["type": "string", "pattern": "^[0-9a-fA-F]{40}$"]
            fields["expected_head_sha"] = ["type": "string", "pattern": "^[0-9a-fA-F]{40}$"]
            fields["recursive"] = ["type": "boolean"]
            fields["offset"] = ["type": "integer", "minimum": 0]
            fields["limit"] = ["type": "integer", "minimum": 1, "maximum": 20]
            requiredFields = ["account_id", "repository", "branch", "action"]
        case "github_request":
            fields["account_id"] = ["type": "string"]
            fields["method"] = ["type": "string", "enum": ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]]
            fields["path"] = ["type": "string", "minLength": 1, "maxLength": 1500]
            fields["query"] = ["type": "object", "additionalProperties": ["type": "string"]]
            fields["body"] = ["type": "object", "additionalProperties": true]
            requiredFields = ["account_id", "path"]
        case "task_verify_github", "github_download_artifact":
            fields["account_id"] = ["type": "string"]; fields["repository"] = ["type": "string", "pattern": "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"]
            fields["run_id"] = ["type": "integer", "minimum": 1]
            fields["expected_sha"] = ["type": "string", "pattern": "^[0-9a-fA-F]{40}$"]
            requiredFields = ["account_id", "repository", "run_id", "expected_sha"]
            if name == "github_download_artifact" {
                fields["artifact_id"] = ["type": "integer", "minimum": 1]
                fields["destination"] = ["type": "string", "minLength": 1, "maxLength": 500]
                requiredFields += ["artifact_id", "destination"]
            }
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
    /// Lossless transport repairs only. Never manufacture missing arguments,
    /// change a command, accept fractional integers, or ignore unknown fields.
    static func normalized(_ value: Any, schema: [String: Any], depth: Int = 0) -> Any {
        guard depth < 32 else { return value }
        let type = schema["type"] as? String
        var value = value
        if let text = value as? String {
            if type == "object" || type == "array", let data = text.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) { value = parsed }
            else if type == "boolean", ["true", "false"].contains(text.lowercased()) { value = text.lowercased() == "true" }
            else if type == "integer", let number = Int(text) { value = number }
        }
        if type == "object", var object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            let required = Set(schema["required"] as? [String] ?? [])
            for (key, child) in object {
                guard let shape = properties[key] else { continue }
                if child is NSNull, !required.contains(key), shape["type"] as? String != "null" {
                    object.removeValue(forKey: key)
                } else { object[key] = normalized(child, schema: shape, depth: depth + 1) }
            }
            return object
        }
        if type == "array", let array = value as? [Any], let shape = schema["items"] as? [String: Any] {
            return array.map { normalized($0, schema: shape, depth: depth + 1) }
        }
        return value
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

/// Recover provider protocol errors by asking for a REAL function call. JSON in
/// visible messages is never turned into an executable tool by the client.
enum ZeusToolRecovery {
    static let marker = "ZEUS_TOOL_REPAIR_REQUIRED:"
    static func candidate(_ text: String, tools: Set<String>) -> String? {
        let input = String(text.prefix(12000)).trimmingCharacters(in: .whitespacesAndNewlines)
        // Recover bare protocol envelopes, never normal prose or fenced code
        // examples that happen to mention a registered function name.
        guard input.hasPrefix("{") || input.hasPrefix("<tool_call>") else { return nil }
        guard input.contains("\"tool_calls\"") || input.contains("<tool_call>") else { return nil }
        guard let expression = try? NSRegularExpression(pattern: #""name"\s*:\s*"([a-zA-Z0-9_]+)""#),
              let match = expression.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let range = Range(match.range(at: 1), in: input) else { return nil }
        let name = String(input[range]); return tools.contains(name) ? name : nil
    }
    static func forcedGeminiTool(_ contents: [[String: Any]], tools: [[String: Any]]) -> String? {
        guard let last = contents.last, last["role"] as? String == "user",
              let parts = last["parts"] as? [[String: Any]], let text = parts.first?["text"] as? String,
              text.hasPrefix(marker) else { return nil }
        let name = String(text.dropFirst(marker.count).prefix(while: { $0 != "\n" }))
        return tools.contains(where: { $0["name"] as? String == name }) ? name : nil
    }
    static func forcedTool(_ messages: [AgentMessage], available: Set<String>) -> String? {
        guard let last = messages.last, last.role == .user,
              let text = last.parts.compactMap({ part -> String? in if case .text(let text) = part { return text }; return nil }).first,
              text.hasPrefix(marker) else { return nil }
        let name = String(text.dropFirst(marker.count).prefix(while: { $0 != "\n" }))
        return available.contains(name) ? name : nil
    }
}
