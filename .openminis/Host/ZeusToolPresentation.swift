import Foundation

/// One mapping for the original local stream and the remote event stream.
/// Rendering remains AssistantBlockView / ToolLiveSheet in both modes.
enum ZeusToolPresentation {
    static func kind(_ name: String, input: [String: Any] = [:]) -> AssistantBlockKind {
        switch name {
        case "shell_execute": return .shellTool(command: input["command"] as? String ?? "")
        case "exec_command": return .shellTool(command: input["cmd"] as? String ?? "")
        case "file_read": return .fileReadTool(path: input["path"] as? String ?? "")
        case "file_write": return .fileWriteTool(path: input["path"] as? String ?? "")
        case "file_edit": return .fileEditTool(path: input["path"] as? String ?? "")
        case let tool where tool == "browser_use" || tool == "zeus_browser" || zeusBrowserOperation(tool) != nil:
            return .browserTool(action: zeusBrowserOperation(name) ?? input["operation"] as? String ?? input["action"] as? String ?? (name == "zeus_browser" ? "browser_pending" : ""))
        case "read_image": return .readImageTool(path: input["path"] as? String ?? "")
        case "memory_write", "memory_get": return .memoryTool(action: name)
        case SubAgentDefinition.toolName: return .delegateTool(title: input["title"] as? String ?? "")
        default: return .shellTool(command: name)
        }
    }
    static func output(_ value: String, name: String) -> String {
        guard ["shell_execute", "exec_command", "write_stdin"].contains(name),
              let data = value.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["id"] is String, let output = envelope["output"] as? String else { return value }
        return output
    }
}
