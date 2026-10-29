import Foundation
import ZEUSBrowser

/// Command substeps used by the original project/verification tools share the
/// same remote workspace and PTY implementation as shell_execute.
@MainActor enum ZeusCloudCommands {
    static func execute(_ command: String, session: String?, timeout: TimeInterval, line: @escaping (String) -> Void) async throws -> AIChatViewModel.CommandResult {
        guard let session, UUID(uuidString: session) != nil else { throw failure("لا توجد مساحة محادثة سحابية لهذا الأمر.") }
        let grant = try await NativeCloudAccountAPI.fileGrant(conversation: session)
        let body = try JSONSerialization.data(withJSONObject: ["conversation": session, "file_grant": grant, "command": command, "timeout_seconds": min(7200, max(1, Int(timeout)))])
        var terminal: [String: Any]?
        // A 409 is returned before launching anything. Retry only that known
        // rejection while the parent's saved device request releases its slot.
        for attempt in 0..<20 {
            do {
                terminal = try object(await NativeCloudAccountAPI.runtime("v1/terminals", method: "POST", body: body)); break
            } catch let error as NativeCloudHTTPError where error.statusCode == 409 && attempt < 19 {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        guard let id = terminal?["id"] as? String else { throw failure("تعذر حجز طرفية الخادم.") }
        do {
            var offset = 0, output = ""
            while true {
                try Task.checkCancellation()
                let value = try object(await NativeCloudAccountAPI.runtime("v1/terminals/" + id + "?offset=" + String(offset)))
                let delta = (value["output"] as? String ?? "").replacingOccurrences(of: "\r\n", with: "\n")
                output = String((output + delta).suffix(64000))
                if !delta.isEmpty { line(delta) }
                offset = value["next_offset"] as? Int ?? offset
                if let exit = value["exit_code"] as? Int {
                    return AIChatViewModel.CommandResult(output: output, exitCode: exit)
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        } catch {
            _ = try? await NativeCloudAccountAPI.runtime("v1/terminals/" + id + "/close", method: "POST", body: Data("{}".utf8))
            throw error
        }
    }
    private static func object(_ bytes: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw failure("رد الطرفية غير صالح.") }; return value
    }
    private static func failure(_ message: String) -> NSError { NSError(domain: "ZEUSCloudCommand", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
