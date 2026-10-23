import SwiftUI

enum ZeusPermissionMode: String, CaseIterable {
    case askAll, consequential, unrestricted
    var title: String {
        switch self {
        case .askAll: return "طلب الموافقة لكل أداة"
        case .consequential: return "طلب الموافقة للإجراءات المؤثرة فقط"
        case .unrestricted: return "تنفيذ جميع الأدوات دون سؤال"
        }
    }
}

/// One authoritative gate for every tool in the original agent loop, including
/// browser automation, shell, files and MCP. OS permissions remain independent.
@MainActor final class ZeusToolPermissions: ObservableObject {
    static let shared = ZeusToolPermissions()
    static let modeKey = "zeus.agent.permissionMode"
    struct Request: Identifiable {
        let id: UUID
        let tool: String
        let title: String
        let explanation: String
        let destination: String
        let sessionID: String?
    }
    @Published private(set) var requests: [UUID: Request] = [:]
    private var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    var mode: ZeusPermissionMode {
        get { ZeusPermissionMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .consequential }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.modeKey)
            objectWillChange.send()
            if newValue == .unrestricted { for id in Array(requests.keys) { respond(id, allowed: true) } }
        }
    }

    static func isConsequential(tool: String, args: [String: Any]) -> Bool {
        switch tool {
        case "file_read", "read_image", "memory_read": return false
        case "zeus_browser":
            let op = args["operation"] as? String ?? ""
            var inner = args
            if let nested = args["arguments"] as? [String: Any] { inner.merge(nested) { _, new in new } }
            if let raw = args["arguments"] as? String,
               let nested = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] { inner.merge(nested) { _, new in new } }
            if ["browser_tabs", "browser_profile", "browser_help", "browser_read", "browser_dom", "browser_network", "browser_console", "browser_screenshot", "browser_find", "browser_scroll", "browser_library", "browser_select_tab"].contains(op) { return false }
            if ["browser_profiles", "browser_settings"].contains(op), ["read", "list"].contains(inner["action"] as? String ?? "read") { return false }
            // Cookie/storage reads may reveal credentials; arbitrary JS, clicks,
            // navigation, settings writes and downloads need explicit consent.
            return true
        case "browser_use":
            return !["get_state", "getState", "snapshot", "screenshot", "get_tabs", "list_tabs", "scroll"].contains(args["action"] as? String ?? "")
        default: return true // Shell/MCP can conceal writes; never guess from a title.
        }
    }

    func authorize(tool: String, args: [String: Any], sessionID: String?, blockID: UUID) async throws {
        try Task.checkCancellation()
        guard mode == .askAll || (mode == .consequential && Self.isConsequential(tool: tool, args: args)) else { return }
        let request = Request(id: blockID, tool: tool,
            title: String((args["tool_title"] as? String ?? tool).prefix(180)),
            explanation: String((args["approval_reason"] as? String ?? "سيستخدم Zeus هذه الأداة لتنفيذ طلبك. راجع الإجراء والوجهة قبل المتابعة.").prefix(800)),
            destination: Self.destination(tool: tool, args: args), sessionID: sessionID)
        let allowed = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                continuations[request.id] = continuation
                requests[request.id] = request
                changed(request.id)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(300))
                    self.respond(request.id, allowed: false)
                }
            }
        } onCancel: {
            Task { @MainActor in self.respond(request.id, allowed: false) }
        }
        try Task.checkCancellation()
        guard allowed else { throw NSError(domain: "ZeusApproval", code: 1, userInfo: [NSLocalizedDescriptionKey: "لم تُمنح الموافقة؛ لم تُنفذ الأداة. لا تكرر طلب الإذن لنفس الإجراء دون طلب جديد من المستخدم."]) }
    }
    func respond(_ id: UUID, allowed: Bool) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        requests.removeValue(forKey: id)
        changed(id)
        continuation.resume(returning: allowed)
    }
    func cancelBrowserRequests() {
        for request in Array(requests.values) where request.tool == "zeus_browser" { respond(request.id, allowed: false) }
    }
    private func changed(_ id: UUID) {
        NotificationCenter.default.post(name: .zeusApprovalChanged, object: id)
    }
    private static func destination(tool: String, args: [String: Any]) -> String {
        if tool == "zeus_browser" { return "متصفحك ZEUS · " + (args["operation"] as? String ?? "") + "\n" + (args["url"] as? String ?? args["tab_id"] as? String ?? "البروفايل النشط") }
        if tool == "browser_use" { return "متصفح الأتمتة المستقل · " + (args["action"] as? String ?? "") + "\n" + (args["url"] as? String ?? "") }
        if let path = args["path"] as? String { return String(path.prefix(500)) }
        if let command = args["command"] as? String { return String(command.prefix(600)) }
        return tool
    }
}
extension Notification.Name { static let zeusApprovalChanged = Notification.Name("zeus.agent.approvalChanged") }

/// Lives inside the original tool block's self-sizing collection cell. No sheet
/// and no overlay intercepting browser/chat interactions.
struct ZeusInlineApprovalCard: View {
    let blockID: UUID
    @ObservedObject private var permissions = ZeusToolPermissions.shared
    @State private var choice: Bool? = nil
    var body: some View {
        if let request = permissions.requests[blockID] {
            VStack(alignment: .leading, spacing: 12) {
                Label("موافقة على إجراء", systemImage: "hand.raised.fill").font(.headline)
                Text(request.title).font(.subheadline.bold()).fixedSize(horizontal: false, vertical: true)
                Text(request.explanation).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Text(request.destination).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                option("السماح هذه المرة", value: true)
                option("رفض الإجراء", value: false)
                Button {
                    if let choice { permissions.respond(request.id, allowed: choice) }
                } label: { Text("تأكيد الاختيار").frame(maxWidth: .infinity).padding(.vertical, 6) }
                    .buttonStyle(.borderedProminent).disabled(choice == nil)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor.opacity(0.35)))
            .environment(\.layoutDirection, .rightToLeft)
            .accessibilityIdentifier("zeusInlineToolApproval")
        }
    }
    private func option(_ title: String, value: Bool) -> some View {
        Button { choice = value } label: {
            HStack(spacing: 10) {
                Image(systemName: choice == value ? "largecircle.fill.circle" : "circle").font(.title3)
                Text(title).foregroundStyle(.primary)
                Spacer()
            }.padding(10).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(choice == value ? [.isSelected] : [])
    }
}

struct ZeusPermissionSettingsSection: View {
    @AppStorage(ZeusToolPermissions.modeKey) private var selection = ZeusPermissionMode.consequential.rawValue
    var body: some View {
        Section("صلاحيات وكيل Zeus") {
            ForEach(ZeusPermissionMode.allCases, id: \.rawValue) { mode in
                Button {
                    selection = mode.rawValue
                    ZeusToolPermissions.shared.mode = mode
                } label: {
                    HStack {
                        Text(mode.title).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: selection == mode.rawValue ? "largecircle.fill.circle" : "circle")
                    }
                }.accessibilityAddTraits(selection == mode.rawValue ? [.isSelected] : [])
            }
        }
    }
}
