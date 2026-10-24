import SwiftUI
import CoreFoundation

/// The original tool model advertises primitive types. Enforce those types for
/// every registered tool, not only WebKit operations, before it gets permission.
enum ZeusToolInput {
    static func normalize(name: String, args: [String: Any], tools: [AgentToolDefinition]) throws -> [String: Any] {
        if let schema = ZeusAgentSchemas.schema(name) { try ZeusAgentSchemas.validate(args, schema: schema); return args }
        guard let definition = tools.first(where: { $0.name == name }) else { return args }
        var result = args
        for (key, parameter) in definition.parameters {
            guard let raw = result[key] else { continue }
            if raw is NSNull, !definition.required.contains(key) { result.removeValue(forKey: key); continue }
            switch parameter.type {
            case .boolean:
                if let value = raw as? String, ["true", "false"].contains(value.lowercased()) { result[key] = value.lowercased() == "true" }
                guard let number = result[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid(name, key, "boolean (true or false)") }
            case .integer:
                if let value = raw as? String, let number = Int(value) { result[key] = number }
                guard let number = result[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                      number.doubleValue.rounded() == number.doubleValue else { throw invalid(name, key, "integer") }
            case .string:
                if key == "keywords", ["browser_use", "memory_get"].contains(name), let keywords = raw as? [String] {
                    result[key] = keywords.joined(separator: " ")
                } else if !(raw is String), parameter.description.localizedCaseInsensitiveContains("JSON"), raw is [String: Any] || raw is [Any] {
                    result[key] = String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
                }
                guard let value = result[key] as? String else { throw invalid(name, key, "string") }
                if let values = parameter.enumValues, !values.contains(value) { throw invalid(name, key, "one of: " + values.joined(separator: ", ")) }
            }
        }
        return result
    }
    private static func invalid(_ name: String, _ key: String, _ expected: String) -> NSError {
        NSError(domain: "ZeusToolInput", code: 2, userInfo: [NSLocalizedDescriptionKey: "INVALID_ARGUMENTS: \(name).\(key) must be \(expected). The tool was not executed; correct this field before retrying."])
    }
}

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
        var plan: ZeusProjectContract.Proposal? = nil
    }
    @Published private(set) var requests: [UUID: Request] = [:]
    private var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    var mode: ZeusPermissionMode {
        get { ZeusPermissionMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .consequential }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.modeKey)
            objectWillChange.send()
            if newValue == .unrestricted { for request in Array(requests.values) where request.plan == nil { respond(request.id, allowed: true) } }
        }
    }

    static func isConsequential(tool: String, args: [String: Any]) -> Bool {
        switch tool {
        case "update_plan", "task_checkpoint", "task_complete", "task_verify_mcp", "task_verify_github", "integration_accounts", "integration_tools", "project_environment", "propose_project_plan", "github_read_file": return false
        case "github_request": return !["GET", "HEAD"].contains(args["method"] as? String ?? "GET")
        case "integration_call": return !ZeusConnections.shared.isReadOnly(args["account_id"] as? String ?? "", tool: args["tool_name"] as? String ?? "")
        case "write_stdin": return args["terminate"] as? Bool == true || !(args["chars"] as? String ?? "").isEmpty
        case "zeus_project_list", "zeus_project_status", "zeus_project_events", "zeus_project_diff", "zeus_project_files": return false
        case "file_read", "read_image", "memory_read", "memory_get": return false
        case let name where name == "zeus_browser" || zeusBrowserOperation(name) != nil:
            let op = zeusBrowserOperation(tool) ?? args["operation"] as? String ?? ""
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
            return !["get_state", "getState", "snapshot", "screenshot", "get_tabs", "list_tabs", "get_text", "get_readable", "get_page_info", "get_backbone", "find_elements", "scroll", "scroll_and_collect", "wait_for_dom_stable"].contains(args["action"] as? String ?? "")
        default: return true // Shell/MCP can conceal writes; never guess from a title.
        }
    }

    func authorize(tool: String, args: [String: Any], sessionID: String?, blockID: UUID) async throws {
        try Task.checkCancellation()
        var plan: ZeusProjectContract.Proposal?
        if tool == "propose_project_plan" {
            guard let sessionID else { throw ZeusPatch.failure("No project conversation.") }
            let proposal = try ZeusProjectContract.decoded(args)
            let current = ZeusAgentHarness.shared.state(sessionID).project
            if current?.decision == "approved", current?.approvedHash == proposal.hash { return }
            guard !requests.values.contains(where: { $0.sessionID == sessionID && $0.plan != nil }) else { throw ZeusPatch.failure("A project plan is already awaiting user review. Do not create parallel approval cards.") }
            plan = try ZeusAgentHarness.shared.prepareProjectProposal(args, session: sessionID, blockID: blockID)
        }
        let routine = mode == .consequential && ZeusAgentHarness.shared.isRoutineProjectAction(tool: tool, args: args, session: sessionID)
        guard plan != nil || mode == .askAll || (mode == .consequential && Self.isConsequential(tool: tool, args: args) && !routine) else { return }
        let request = Request(id: blockID, tool: tool,
            title: plan?.title ?? String((args["tool_title"] as? String ?? tool).prefix(180)),
            explanation: plan?.objective ?? String((args["approval_reason"] as? String ?? "سيستخدم Zeus هذه الأداة لتنفيذ طلبك. راجع الإجراء والوجهة قبل المتابعة.").prefix(800)),
            destination: Self.destination(tool: tool, args: args), sessionID: sessionID, plan: plan)
        let allowed = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                continuations[request.id] = continuation
                requests[request.id] = request
                changed(request.id)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(request.plan == nil ? 300 : 1800))
                    if request.plan != nil { self.respondPlan(request.id, decision: "expired") }
                    else { self.respond(request.id, allowed: false) }
                }
            }
        } onCancel: {
            Task { @MainActor in self.respond(request.id, allowed: false) }
        }
        try Task.checkCancellation()
        if !allowed, plan != nil {
            let revision = sessionID.flatMap { ZeusAgentHarness.shared.state($0).project?.revision } ?? ""
            throw ZeusPatch.failure("The project plan was not approved. No project mutation was authorized." + (revision.isEmpty ? " Respect cancellation; wait for a new user request." : " User requested these revisions: " + revision + ". Revise the proposal and ask again; do not begin implementation."))
        }
        guard allowed else { throw NSError(domain: "ZeusApproval", code: 1, userInfo: [NSLocalizedDescriptionKey: "لم تُمنح الموافقة؛ لم تُنفذ الأداة. لا تكرر طلب الإذن لنفس الإجراء دون طلب جديد من المستخدم."]) }
    }
    func respond(_ id: UUID, allowed: Bool) {
        if requests[id]?.plan != nil { respondPlan(id, decision: allowed ? "approved" : "cancelled"); return }
        if let request = requests[id] { ZeusAgentHarness.shared.recordProjectPermission(session: request.sessionID, tool: request.tool, allowed: allowed) }
        finish(id, allowed: allowed)
    }
    func respondPlan(_ id: UUID, decision: String, note: String = "") {
        guard ["approved", "changes_requested", "cancelled", "expired"].contains(decision), let request = requests[id],
              let proposal = request.plan, let session = request.sessionID else { return }
        do {
            try ZeusAgentHarness.shared.decideProject(session: session, hash: proposal.hash, decision: decision, note: note)
            finish(id, allowed: decision == "approved")
        } catch { finish(id, allowed: false) }
    }
    private func finish(_ id: UUID, allowed: Bool) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        requests.removeValue(forKey: id)
        changed(id)
        continuation.resume(returning: allowed)
    }
    func cancelBrowserRequests() {
        for request in Array(requests.values) where request.tool == "zeus_browser" || zeusBrowserOperation(request.tool) != nil { respond(request.id, allowed: false) }
    }
    private func changed(_ id: UUID) {
        NotificationCenter.default.post(name: .zeusApprovalChanged, object: id)
    }
    private static func destination(tool: String, args: [String: Any]) -> String {
        if tool == "zeus_browser" || zeusBrowserOperation(tool) != nil { return "متصفحك ZEUS · " + (zeusBrowserOperation(tool) ?? args["operation"] as? String ?? "") + "\n" + (args["url"] as? String ?? args["tab_id"] as? String ?? "البروفايل النشط") }
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
            if request.plan != nil { ZeusProjectApprovalCard(request: request) }
            else {
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
            .foregroundStyle(.primary).tint(.blue)
            .environment(\.layoutDirection, .rightToLeft)
            .accessibilityIdentifier("zeusInlineToolApproval")
            }
        } else if ZeusAgentHarness.shared.projectForBlock(blockID) != nil {
            ZeusProjectProgressCard(blockID: blockID)
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

// Browser cards retain the source renderer but must never attach ZEUS actions
// to the separate automation pool, its snapshots or takeover buttons.
extension AssistantBlock {
    var zeusIsUserBrowser: Bool {
        if case .browserTool(let action) = kind { return action.hasPrefix("browser_") }
        return false
    }
}
