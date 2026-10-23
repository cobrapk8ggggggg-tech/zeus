#if ZEUS_NATIVE_HOST
import Foundation
import CoreFoundation

/// Validate against the operation's advertised schema before asking permission
/// or touching WebKit. Never infer missing destinations or rewrite JS/content.
enum NativeBrowserContract {
    static func arguments(operation: String, json: String, tools: [BrowserAgentTools.Tool]) throws -> String {
        guard json.utf8.count <= 100_000,
              let tool = tools.first(where: { $0.name == operation }),
              var object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw AgentFailure.message("INVALID_ARGUMENTS: Unknown operation or invalid JSON object. Read the zeus_browser operation catalog.")
        }
        // Normalize only unambiguous scalar encodings; preserve text/code exactly.
        for (key, rawSchema) in tool.properties {
            guard let schema = rawSchema as? [String: Any], let value = object[key], !(value is NSNull) else { continue }
            let type = schema["type"] as? String ?? "string"
            if type == "boolean", let raw = value as? String, ["true", "false"].contains(raw.lowercased()) {
                object[key] = raw.lowercased() == "true"
            }
            if ["number", "integer"].contains(type), let raw = value as? String, let number = Double(raw), number.isFinite { object[key] = number }
            let normalized = object[key]!
            let number = normalized as? NSNumber
            let isBool = number.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            let valid: Bool
            switch type {
            case "boolean": valid = isBool
            case "number", "integer": valid = number != nil && !isBool && number!.doubleValue.isFinite && (type != "integer" || number!.doubleValue.rounded() == number!.doubleValue)
            default: valid = normalized is String
            }
            guard valid else { throw AgentFailure.message("INVALID_ARGUMENTS: \(operation).\(key) must be \(type). No action executed.") }
            if let choices = schema["enum"] as? [String], let text = normalized as? String, !choices.contains(text) {
                throw AgentFailure.message("INVALID_ARGUMENTS: \(key) must be one of: \(choices.joined(separator: ", ")). No action executed.")
            }
        }
        let missing = tool.required.filter { object[$0] == nil || object[$0] is NSNull }
        guard missing.isEmpty else { throw AgentFailure.message("INVALID_ARGUMENTS: \(operation) requires \(missing.joined(separator: ", ")). No action executed.") }
        let unknown = Set(object.keys).subtracting(tool.properties.keys)
        guard unknown.isEmpty else { throw AgentFailure.message("INVALID_ARGUMENTS: Unsupported fields \(unknown.sorted().joined(separator: ", ")) for \(operation). Allowed: \(tool.properties.keys.sorted().joined(separator: ", ")).") }
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
#endif
