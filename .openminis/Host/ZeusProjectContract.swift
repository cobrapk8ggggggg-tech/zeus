import SwiftUI
import CryptoKit

/// A user-approved product brief and its acceptance checks, not model prose
/// interpreted as approval. Stored with the original conversation task state.
struct ZeusProjectContract: Codable {
    struct Feature: Codable { let id: String; let title: String }
    struct Criterion: Codable {
        let id: String; let title: String; let kind: String; let covers: [String]
        let command: String?
        let github_job: String?; let github_step: String?; let artifact: String?
        let screenshot_path: String?
    }
    struct Proposal: Codable {
        let title: String; let objective: String; let platform: String
        let features: [Feature]; let architecture: [String]; let steps: [String]
        let checks: [Criterion]; let deliverables: [String]; let assumptions: [String]
        var design_reference_notes: [String]?
        let build_route: String
        let github_account_id: String?; let repository: String?; let branch: String?; let workflow: String?
        var hash: String {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            return SHA256.hash(data: (try? encoder.encode(self)) ?? Data()).map { String(format: "%02x", $0) }.joined()
        }
    }
    struct Environment: Codable {
        let localTools: [String: String]; let localError: String?
        let hasIOSSDK: Bool; let githubAccounts: [String]; let checkedAt: Date
    }
    struct Evidence: Codable {
        let criterion: String; let passed: Bool; let generation: Int
        let source: String; let summary: String; let date: Date
    }
    var userGoal: String
    var required = true
    var decision = "needs_plan"
    var proposal: Proposal?
    var approvedHash: String?
    var approvalBlock: String?
    var approvedAt: Date?
    var revision = ""
    var environment: Environment?
    var evidence: [String: Evidence] = [:]
    var reviewedImages: [String: Int] = [:]
    var githubAttempts = 0
    var githubLastStatus: Int?
    var githubLastError: String?
    var githubExecutionStarted: Bool?
    var permissionBlocker: String?
    var environmentBlocker: String?
    var artifactRoots: [String: String]?
    var reviewedImageCommits: [String: String]?
    var verifiedGitHubCommit: String?
    struct Note: Codable { let text: String; let date: Date }
    var notes: [Note]?
    var loadedSkills: [String: String]?
    var skillPaths: [String: String]?
    var referenceImages: [String]?
    var inspectedReferences: [String]?
    mutating func appendNote(_ text: String) {
        let note = String(text.prefix(1200)); guard !note.isEmpty, notes?.last?.text != note else { return }
        if notes == nil { notes = [] }
        notes?.append(Note(text: note, date: Date()))
        if let count = notes?.count, count > 50 { notes?.removeFirst(count - 50) }
    }

    @MainActor mutating func loadSkills(platform: String?) {
        let names = platform == "ios" ? ["swiftui-ui-patterns", "swiftui-view-refactor", "ios-simulator-browser"] : platform == "web" ? ["frontend-app-builder", "frontend-testing-debugging"] : ["verification"]
        let selected = SkillStore.shared.skills.filter { $0.isEnabled && names.contains($0.name) }
        let previous: Set<String> = Set((loadedSkills ?? [:]).keys)
        loadedSkills = Dictionary(uniqueKeysWithValues: selected.map { ($0.name, $0.body) })
        skillPaths = Dictionary(uniqueKeysWithValues: selected.map { ($0.name, "/var/minis/skills/" + $0.id + "/SKILL.md") })
        if !selected.isEmpty, previous != Set(selected.map(\.name)) { appendNote("قُرئت تلقائياً مهارات المهمة: " + selected.map(\.name).sorted().joined(separator: "، ")) }
    }

    static func isProjectRequest(_ text: String) -> Bool {
        let text = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "ar"))
            .replacingOccurrences(of: "أ", with: "ا").replacingOccurrences(of: "إ", with: "ا").replacingOccurrences(of: "آ", with: "ا")
        let actions = ["ابني", "ابن لي", "انشئ", "انشاء", "اصنع", "اعمل لي", "سوي", "برمج", "طور لي", "بناء", "build", "create", "develop", "implement", "refactor"]
        let products = ["تطبيق", "مشروع", "موقع", "لعبه", "لعبة", "برنامج", "app", "apps", "application", "project", "website", "web site", "webapp", "game", "backend"]
        func contains(_ term: String) -> Bool {
            if term.unicodeScalars.allSatisfy({ $0.isASCII }) { return text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: term) + "\\b", options: .regularExpression) != nil }
            return text.contains(term)
        }
        return actions.contains(where: contains) && products.contains(where: contains)
    }
    static func decoded(_ args: [String: Any]) throws -> Proposal {
        guard let proposal = args["proposal"] else { throw ZeusPatch.failure("A structured proposal is required.") }
        return try JSONDecoder().decode(Proposal.self, from: JSONSerialization.data(withJSONObject: proposal))
    }
    static func explicitPlatform(_ goal: String) -> String? {
        let text = (goal.components(separatedBy: "\nUser follow-up:").last ?? goal).lowercased()
        if text.range(of: #"\b(ios|iphone|ipad)\b"#, options: .regularExpression) != nil || ["آيفون", "ايفون", "آيباد", "ايباد"].contains(where: text.contains) { return "ios" }
        if ["android", "اندرويد", "أندرويد"].contains(where: text.contains) { return "android" }
        if ["website", "web app", "موقع ويب", "موقع الكتروني", "موقع إلكتروني"].contains(where: text.contains) { return "web" }
        return nil
    }
    static func validate(_ p: Proposal) throws {
        guard Set(p.features.map(\.id)).count == p.features.count, Set(p.checks.map(\.id)).count == p.checks.count,
              Set(p.steps).count == p.steps.count else { throw ZeusPatch.failure("Feature/check IDs and plan steps must be unique.") }
        let featureIDs = Set(p.features.map(\.id))
        guard p.checks.allSatisfy({ Set($0.covers).isSubset(of: featureIDs) }),
              featureIDs.isSubset(of: Set(p.checks.filter { ["functional", "ui"].contains($0.kind) }.flatMap(\.covers))),
              p.checks.contains(where: { $0.kind == "build" }), p.checks.contains(where: { $0.kind == "functional" }) else {
            throw ZeusPatch.failure("The plan needs a real build check, functional tests, and acceptance checks covering every requested feature. A build alone is not product completion.")
        }
        if ["ios", "android", "web"].contains(p.platform), !p.checks.contains(where: { $0.kind == "ui" }) {
            throw ZeusPatch.failure("User-facing apps need a UI review check and actual screenshots in addition to build and functional tests.")
        }
        if p.build_route == "local" {
            guard p.platform != "ios" else { throw ZeusPatch.failure("This device's Linux guest has no iOS SDK or Xcode. Select github_actions with a real linked account and macOS/Xcode workflow; Linux Swift cannot build an iOS app.") }
            for check in p.checks {
                let command = (check.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty, !["true", ":", "exit 0"].contains(command), !command.hasPrefix("echo ") else { throw ZeusPatch.failure("Each local acceptance check needs an actual build/test command, not a placeholder success.") }
                if check.kind == "ui", (check.screenshot_path ?? "").isEmpty { throw ZeusPatch.failure("A local UI review must name its actual screenshot_path for read_image inspection.") }
            }
        } else {
            guard !(p.github_account_id ?? "").isEmpty, let repo = p.repository, repo.split(separator: "/").count == 2,
                  !(p.branch ?? "").isEmpty, let workflow = p.workflow, workflow.hasPrefix(".github/workflows/") else {
                throw ZeusPatch.failure("GitHub execution needs a linked account ID, owner/repository, branch and exact .github/workflows/... path in the approved plan.")
            }
            for check in p.checks {
                guard !(check.github_job ?? "").isEmpty, !(check.github_step ?? "").isEmpty else { throw ZeusPatch.failure("Each remote criterion must identify its actual GitHub job and step; success prose does not count.") }
                if ["build", "ui"].contains(check.kind), (check.artifact ?? "").isEmpty { throw ZeusPatch.failure("Remote build/UI checks must name the expected app/build or screenshot artifact.") }
                if check.kind == "ui", (check.screenshot_path ?? "").isEmpty { throw ZeusPatch.failure("Remote UI review must name the downloaded screenshot_path the agent will actually inspect with read_image.") }
            }
        }
    }
}

private struct ZeusProjectPlanDetails: View {
    let proposal: ZeusProjectContract.Proposal
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("المنصة: " + proposal.platform, systemImage: proposal.platform == "ios" ? "iphone" : proposal.platform == "web" ? "globe" : "app.dashed").font(.subheadline)
            Label(proposal.build_route == "github_actions" ? "البناء عبر GitHub Actions" : "البناء في البيئة المحلية", systemImage: "hammer")
                .font(.subheadline.bold())
            if let repository = proposal.repository {
                Text(repository + " · " + (proposal.branch ?? "")).font(.caption.monospaced()).environment(\.layoutDirection, .leftToRight).textSelection(.enabled)
            }
            if let id = proposal.github_account_id, let account = ZeusConnections.shared.accounts.first(where: { $0.id == id }) {
                Label(account.label, systemImage: "person.crop.circle").font(.caption).foregroundStyle(.secondary)
            }
            Text("المميزات المطلوبة").font(.subheadline.bold())
            ForEach(proposal.features, id: \.id) { feature in Label(feature.title, systemImage: "checklist").font(.subheadline) }
            if let notes = proposal.design_reference_notes, !notes.isEmpty {
                Text("تفاصيل الصور المرجعية").font(.subheadline.bold())
                ForEach(Array(notes.enumerated()), id: \.offset) { item in Text("• " + item.element).font(.subheadline) }
            }
            Text("بنية المشروع").font(.subheadline.bold())
            ForEach(Array(proposal.architecture.enumerated()), id: \.offset) { item in Text("• " + item.element).font(.subheadline) }
            Text("مراحل التنفيذ").font(.subheadline.bold())
            ForEach(Array(proposal.steps.enumerated()), id: \.offset) { item in Text("\(item.offset + 1). " + item.element).font(.subheadline) }
            Text("شروط قبول النتيجة").font(.subheadline.bold())
            ForEach(proposal.checks, id: \.id) { check in
                VStack(alignment: .leading, spacing: 4) {
                    Label(check.title, systemImage: check.kind == "ui" ? "photo" : check.kind == "build" ? "hammer" : "checkmark.seal").font(.subheadline)
                    if let command = check.command { Text(command).font(.caption.monospaced()).foregroundStyle(.secondary).environment(\.layoutDirection, .leftToRight).textSelection(.enabled) }
                    if let step = check.github_step { Text((check.github_job ?? "") + " · " + step).font(.caption).foregroundStyle(.secondary) }
                    if let artifact = check.artifact { Label(artifact, systemImage: "shippingbox").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Text("ما سأستلمه").font(.subheadline.bold())
            ForEach(Array(proposal.deliverables.enumerated()), id: \.offset) { item in Text("• " + item.element).font(.subheadline) }
            if !proposal.assumptions.isEmpty {
                Text("افتراضات الخطة").font(.subheadline.bold())
                ForEach(Array(proposal.assumptions.enumerated()), id: \.offset) { item in Text("• " + item.element).font(.subheadline).foregroundStyle(.secondary) }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

struct ZeusProjectApprovalCard: View {
    let request: ZeusToolPermissions.Request
    @State private var choice = ""
    @State private var note = ""
    @State private var expanded = false
    var body: some View {
        if let proposal = request.plan {
            VStack(alignment: .leading, spacing: 14) {
                Label("خطة المشروع · بانتظار موافقتك", systemImage: "list.clipboard.fill").font(.headline)
                Text(proposal.title).font(.title3.bold())
                Text(proposal.objective).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                HStack { Label("\(proposal.steps.count) مراحل", systemImage: "list.number"); Label("\(proposal.features.count) مميزات", systemImage: "square.grid.2x2"); Label("\(proposal.checks.count) فحوص", systemImage: "checkmark.seal") }.font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("المميزات والبنية والخطوات ومعايير القبول", isExpanded: $expanded) { ZeusProjectPlanDetails(proposal: proposal).padding(.top, 12) }
                Divider()
                option("اعتماد الخطة وبدء التنفيذ", value: "approved")
                option("أريد تعديل الخطة", value: "changes_requested")
                if choice == "changes_requested" {
                    TextField("اكتب التعديلات المطلوبة", text: $note, axis: .vertical).lineLimit(3...3).textFieldStyle(.roundedBorder)
                }
                option("إلغاء تنفيذ المشروع", value: "cancelled")
                Button {
                    ZeusToolPermissions.shared.respondPlan(request.id, decision: choice, note: note)
                } label: { Text("تأكيد الاختيار").frame(maxWidth: .infinity).padding(.vertical, 6) }
                    .buttonStyle(.borderedProminent).disabled(choice.isEmpty || (choice == "changes_requested" && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.blue.opacity(0.4)))
                .foregroundStyle(.primary).tint(.blue).environment(\.layoutDirection, .rightToLeft)
                .accessibilityIdentifier("zeusInlineProjectPlan")
                .onChange(of: expanded) { _ in changed() }.onChange(of: choice) { _ in changed() }
        }
    }
    private func changed() { NotificationCenter.default.post(name: .zeusApprovalChanged, object: request.id) }
    private func option(_ title: String, value: String) -> some View {
        Button { choice = value } label: {
            HStack(spacing: 10) { Image(systemName: choice == value ? "largecircle.fill.circle" : "circle").font(.title3); Text(title).foregroundStyle(.primary); Spacer() }.padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(choice == value ? [.isSelected] : [])
    }
}

struct ZeusProjectProgressCard: View {
    let blockID: UUID
    @ObservedObject private var runtime = ZeusAgentHarness.shared
    @State private var expanded = false
    @State private var notesExpanded = false
    var body: some View {
        if let (state, project) = runtime.projectForBlock(blockID), let proposal = project.proposal {
            VStack(alignment: .leading, spacing: 12) {
                Label(title(state, project), systemImage: state.status == "completed" ? "checkmark.seal.fill" : "list.clipboard").font(.headline)
                Text(proposal.title).font(.subheadline.bold())
                if let skills = project.loadedSkills, !skills.isEmpty { Text("مهارات المهمة: " + skills.keys.sorted().joined(separator: "، ")).font(.caption).foregroundStyle(.secondary) }

                ForEach(state.plan, id: \.step) { step in
                    Label(step.step, systemImage: step.status == "completed" ? "checkmark.circle.fill" : step.status == "in_progress" ? "arrow.triangle.2.circlepath" : "circle").font(.subheadline)
                }
                if let notes = project.notes, !notes.isEmpty {
                    Text("ملاحظات وتقدم التنفيذ").font(.subheadline.bold())
                    ForEach(Array(notes.suffix(4).enumerated()), id: \.offset) { item in
                        HStack(alignment: .top) { Image(systemName: "note.text"); Text(item.element.text).font(.caption).fixedSize(horizontal: false, vertical: true) }
                    }
                    if notes.count > 4 {
                        DisclosureGroup("سجل الملاحظات (\(notes.count))", isExpanded: $notesExpanded) {
                            ScrollView { VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(notes.enumerated()), id: \.offset) { item in Text(item.element.text).font(.caption).fixedSize(horizontal: false, vertical: true) }
                            }}.frame(maxHeight: 240)
                        }.font(.caption)
                    }
                }
                if !project.revision.isEmpty { Text(project.revision).font(.subheadline).foregroundStyle(.secondary) }
                HStack { Text("شروط القبول المكتملة"); Spacer(); Text("\(passedCount(state, project, proposal)) / \(proposal.checks.count)").monospacedDigit() }.font(.caption)
                DisclosureGroup("تفاصيل الخطة المعتمدة", isExpanded: $expanded) { ZeusProjectPlanDetails(proposal: proposal).padding(.top, 10) }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.primary).tint(.blue).environment(\.layoutDirection, .rightToLeft)
                .accessibilityIdentifier("zeusProjectProgress")
                .onChange(of: expanded) { _ in NotificationCenter.default.post(name: .zeusApprovalChanged, object: blockID) }
                .onChange(of: notesExpanded) { _ in NotificationCenter.default.post(name: .zeusApprovalChanged, object: blockID) }
        }
    }
    private func title(_ state: ZeusAgentHarness.State, _ project: ZeusProjectContract) -> String {
        if project.decision == "changes_requested" { return "الخطة تحتاج تعديلاً" }
        if project.decision == "cancelled" { return "أُلغي تنفيذ الخطة" }
        if project.decision == "expired" { return "انتهت مهلة مراجعة الخطة" }
        if state.status == "completed" { return "اكتمل المشروع واجتاز فحوص الخطة" }
        return project.decision == "approved" ? "خطة معتمدة · متابعة التنفيذ" : "الخطة لم تُعتمد بعد"
    }
    private func passedCount(_ state: ZeusAgentHarness.State, _ project: ZeusProjectContract, _ p: ZeusProjectContract.Proposal) -> Int {
        p.checks.filter { check in
            guard project.evidence[check.id]?.passed == true, project.evidence[check.id]?.generation == state.generation else { return false }
            if check.kind != "ui" { return true }
            let path = ZeusAgentHarness.projectImagePath(check.screenshot_path ?? "")
            guard project.reviewedImages[path] == state.generation else { return false }
            return p.build_route == "local" || (project.verifiedGitHubCommit != nil && project.reviewedImageCommits?[path] == project.verifiedGitHubCommit)
        }.count
    }
}

@MainActor extension ZeusAgentHarness {
    func registerUserRequest(_ text: String, session: String?) {
        guard let session, !text.isEmpty else { return }
        var value = state(session)
        if ZeusProjectContract.isProjectRequest(text), value.project == nil || value.status == "completed" || value.project?.decision == "cancelled" {
            value.project = ZeusProjectContract(userGoal: String(text.prefix(12000)))
            value.goal = String(text.prefix(2000)); value.status = "running"; value.started = Date()
            value.plan = []; value.checks = []; value.verificationCommands = []
            value.remoteChecks = []; value.remoteVerificationKeys = []; value.remoteVerificationSpecs = []
        } else if var project = value.project {
            // New user messages may revise the brief. Approval is never inferred
            // from user text, web content, a model response or permission mode.
            project.userGoal = String((project.userGoal + "\nUser follow-up: " + text).suffix(16000))
            value.project = project
            if value.status != "completed" { value.status = "running" }
        } else {
            // Keep the actual request for the source-write fallback even when
            // a colloquial "I want an app" did not match intent keywords.
            value.goal = String(text.prefix(4000))
        }
        try? save(session, value)
    }
    func projectGate(tool: String, args: [String: Any], session: String?) throws {
        guard let session else { return }
        var value = state(session)
        if value.project == nil, ["file_write", "file_edit", "apply_patch"].contains(tool) {
            var paths = [args["path"] as? String ?? ""]
            if let patch = args["patch"] as? String { paths += patch.split(separator: "\n").filter { $0.hasPrefix("*** Add File: ") || $0.hasPrefix("*** Update File: ") }.map { String($0.dropFirst($0.hasPrefix("*** Add") ? 14 : 17)) } }
            let sourceExtensions = ["swift", "tsx", "jsx", "js", "ts", "py", "html", "css", "kt", "dart", "cs", "go", "rs"]
            if paths.contains(where: { sourceExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }) {
                value.project = ZeusProjectContract(userGoal: value.goal.isEmpty ? "Implement the user's requested source change" : value.goal)
                try save(session, value)
            }
        }
        guard let project = value.project, project.required else { return }
        if ["project_environment", "propose_project_plan", "integration_accounts", "integration_tools", "task_checkpoint", "update_plan", "task_complete", "file_read", "read_image", "memory_read", "memory_get"].contains(tool) { return }
        if tool == "github_read_file" { return }
        if tool == "github_request", ["GET", "HEAD"].contains(args["method"] as? String ?? "GET") { return }
        if tool == "integration_call", ZeusConnections.shared.isReadOnly(args["account_id"] as? String ?? "", tool: args["tool_name"] as? String ?? "") { return }
        // Ordinary read-only browser inspection is useful while researching the
        // brief. Shell/Swift/file mutations cannot bypass project approval.
        if tool.hasPrefix("zeus_browser"), !ZeusToolPermissions.isConsequential(tool: tool, args: args) { return }
        if tool == "browser_use", !ZeusToolPermissions.isConsequential(tool: tool, args: args) { return }
        guard project.decision == "approved", project.approvedHash == project.proposal?.hash else {
            throw ZeusPatch.failure("PROJECT_PLAN_REQUIRED: Inspect project_environment, propose a complete product brief with propose_project_plan, and wait for the user's inline approval before writing source, compiling or changing a repository. Current user goal: " + String(project.userGoal.prefix(1200)) + (project.revision.isEmpty ? "" : "\nRequested revision: " + project.revision))
        }
        if tool == "integration_call", (try? ZeusConnections.shared.account(args["account_id"] as? String))?.provider == "github" {
            throw ZeusPatch.failure("Use github_request for project writes so the approved account/repository/branch can be checked. Read-only MCP inspection remains available.")
        }
    }
    func prepareProjectProposal(_ args: [String: Any], session: String, blockID: UUID, connections: ZeusConnections = .shared) throws -> ZeusProjectContract.Proposal {
        try ZeusAgentSchemas.validate(args, schema: ZeusAgentSchemas.schema("propose_project_plan")!)
        let proposal = try ZeusProjectContract.decoded(args)
        try ZeusProjectContract.validate(proposal)
        guard try JSONEncoder().encode(proposal).count <= 18000 else { throw ZeusPatch.failure("Keep the reviewable project proposal under 18KB; use concise features, steps and acceptance checks.") }
        var value = state(session), project = state(session).project ?? ZeusProjectContract(userGoal: proposal.objective)
        if let expected = ZeusProjectContract.explicitPlatform(project.userGoal), expected != proposal.platform {
            throw ZeusPatch.failure("The user explicitly requested \(expected). A proposal for \(proposal.platform) cannot silently replace that platform; revise the plan or obtain the user's actual platform change.")
        }
        if let references = project.referenceImages, !references.isEmpty {
            guard Set(references).isSubset(of: Set(project.inspectedReferences ?? [])), !(proposal.design_reference_notes ?? []).isEmpty else { throw ZeusPatch.failure("Read every supplied reference image with read_image before proposing the UI. Include design_reference_notes describing its actual layout, spacing, typography, colors and interaction details; generic UI assumptions are insufficient.") }
        }
        guard project.environment != nil else { throw ZeusPatch.failure("Call project_environment before proposing a project; inspect actual toolchains and linked accounts instead of guessing where it will build.") }
        if proposal.build_route == "local", project.environment?.localTools["sh"] == nil { throw ZeusPatch.failure("The local shell probe did not succeed. Select a working remote route or resolve the reported environment error before proposing local execution.") }
        if proposal.build_route == "github_actions" {
            _ = try connections.account(proposal.github_account_id, provider: "github")
        }
        project.loadSkills(platform: proposal.platform)
        project.proposal = proposal; project.decision = "awaiting_approval"; project.approvedHash = nil
        project.appendNote("عُرضت خطة المشروع للمراجعة.")
        project.approvalBlock = blockID.uuidString; project.revision = ""; project.evidence = [:]
        value.project = project; value.status = "running"; try save(session, value)
        return proposal
    }
    func decideProject(session: String, hash: String, decision: String, note: String = "") throws {
        var value = state(session)
        guard var project = value.project, project.proposal?.hash == hash, project.decision == "awaiting_approval" else { throw ZeusPatch.failure("The plan changed or is no longer awaiting approval. No project action was authorized.") }
        project.decision = decision; project.revision = String(note.prefix(4000))
        if decision == "approved", let proposal = project.proposal {
            project.appendNote("اعتمد المستخدم الخطة؛ يبدأ تنفيذ المراحل ومتابعة نتائجها.")
            project.approvedHash = hash; project.approvedAt = Date(); value.started = Date()
            project.permissionBlocker = nil; project.environmentBlocker = nil
            value.plan = proposal.steps.map { Step(step: $0, status: "pending") }
            value.verificationCommands = proposal.build_route == "local" ? proposal.checks.compactMap(\.command) : []
            value.checks = []; value.remoteChecks = []; value.remoteVerificationKeys = []; value.remoteVerificationSpecs = []
        } else {
            project.approvedHash = nil
            if ["cancelled", "expired"].contains(decision) { value.status = "waiting_user"; value.checkpoint = decision == "cancelled" ? "ألغى المستخدم خطة المشروع؛ لم يُؤذن بتنفيذها." : "انتهت مهلة مراجعة الخطة؛ التقدم محفوظ ويمكن طلب موافقة جديدة." }
        }
        value.project = project; try save(session, value)
    }
    func projectEnvironment(vm: AIChatViewModel) async throws -> String {
        guard let session = vm.sessionId else { throw ZeusPatch.failure("No active conversation.") }
        var paths: [String: String] = [:], probeError: String?
        do {
            try await prepareEnvironment(vm: vm)
            let result = try await vm.executeCommand("for x in sh git python3 node npm swift xcodebuild; do p=$(command -v \"$x\" 2>/dev/null || true); printf '%s=%s\\n' \"$x\" \"$p\"; done", timeout: 30) { _ in }
            for line in result.output.split(separator: "\n") {
                let fields = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if fields.count == 2, !fields[1].isEmpty { paths[String(fields[0])] = String(fields[1]) }
            }
        } catch { probeError = error.localizedDescription }
        let accounts = ZeusConnections.shared.linked("github").map(\.id)
        let environment = ZeusProjectContract.Environment(localTools: paths, localError: probeError, hasIOSSDK: false, githubAccounts: accounts, checkedAt: Date())
        var value = state(session), project = state(session).project ?? ZeusProjectContract(userGoal: value.goal)
        project.environment = environment
        await ZeusDefaultSkills.shared.install()
        let platform = ZeusProjectContract.explicitPlatform(project.userGoal) ?? (project.userGoal.range(of: #"\b(swift|swiftui)\b"#, options: [.regularExpression, .caseInsensitive]) != nil ? "ios" : nil)
        project.loadSkills(platform: platform)
        let references = vm.messages.last(where: { $0.role == .user })?.attachments.filter(\.isImage).map(\.path) ?? []
        project.referenceImages = Array(Set((project.referenceImages ?? []) + references)).sorted()
        value = state(session); value.project = project; try save(session, value)
        var output: [String: Any] = [:]
        output["host"] = "ZEUS Browser on iOS/iPadOS"
        output["local_execution"] = "Linux guest; not macOS"
        output["has_ios_sdk"] = false
        output["automatically_loaded_skills"] = (project.loadedSkills ?? [:]).keys.sorted()
        output["skill_paths"] = project.skillPaths ?? [:]
        output["reference_images_to_read"] = project.referenceImages ?? []
        output["local_tools"] = paths
        output["probe_error"] = probeError as Any? ?? NSNull()
        output["github_accounts"] = ZeusConnections.shared.accountSummary().filter { $0["provider"] as? String == "github" }
        output["required_route"] = "iOS apps require a linked GitHub account and a macOS/Xcode Actions workflow. Use github_read_file/github_write_files for plain-text source and github_request for repository/branch/Actions APIs. If no account is linked, ask for that precise connection, preserve the brief and resume; do not offer manual building as completed work."
        return try Self.json(output)
    }
    func recordProjectChecks(session: String) throws {
        var value = state(session)
        guard var project = value.project, project.decision == "approved", let proposal = project.proposal, proposal.build_route == "local" else { return }
        for criterion in proposal.checks {
            guard let check = value.checks.first(where: { $0.command == criterion.command }) else { continue }
            let reviewed = criterion.kind != "ui" || project.reviewedImages[Self.projectImagePath(criterion.screenshot_path ?? "")] == value.generation
            project.evidence[criterion.id] = .init(criterion: criterion.id, passed: check.exitCode == 0 && reviewed, generation: check.generation,
                source: "actual_local_command", summary: String(check.output.suffix(1500)) + (reviewed ? "" : "\nRead the actual screenshot with read_image before completing UI review."), date: Date())
        }
        value.project = project; try save(session, value)
    }
    func validateProjectCompletion(session: String, status: String) throws {
        let value = state(session)
        guard let project = value.project, project.required else { return }
        guard status == "completed" else {
            if project.decision == "approved", project.proposal?.build_route == "github_actions" {
                let hardBlocker = [401, 403, -1].contains(project.githubLastStatus ?? 0) || project.permissionBlocker != nil || project.environmentBlocker != nil || Date().timeIntervalSince(value.started) >= Double(Self.maxHours * 3600)
                guard hardBlocker else { throw ZeusPatch.failure("The approved GitHub Actions route has no observed access/network/user-permission blocker. Missing local Swift/Xcode, one successful status read, or a failed build is not a reason to hand the project back for manual building. Continue: commit source/workflow, dispatch, inspect logs, repair and verify. Real authorization/network failures or user denial are recorded automatically; time-budget exhaustion preserves the checkpoint.") }
            }
            return
        }
        guard project.decision == "approved", let proposal = project.proposal, proposal.hash == project.approvedHash else { throw ZeusPatch.failure("Completion blocked: no user-approved project plan.") }
        let missing = proposal.checks.filter { project.evidence[$0.id]?.passed != true || project.evidence[$0.id]?.generation != value.generation }
        guard missing.isEmpty else { throw ZeusPatch.failure("Completion blocked: approved acceptance checks lack current passing evidence: " + missing.map(\.title).joined(separator: ", ")) }
        let unseen = proposal.checks.filter { $0.kind == "ui" && project.reviewedImages[Self.projectImagePath($0.screenshot_path ?? "")] != value.generation }
        guard unseen.isEmpty else { throw ZeusPatch.failure("Completion blocked: inspect the actual current UI screenshots with read_image: " + unseen.compactMap(\.screenshot_path).joined(separator: ", ")) }
        if proposal.build_route == "github_actions" {
            let staleImages = proposal.checks.filter { $0.kind == "ui" && (project.verifiedGitHubCommit == nil || project.reviewedImageCommits?[Self.projectImagePath($0.screenshot_path ?? "")] != project.verifiedGitHubCommit) }
            guard staleImages.isEmpty else { throw ZeusPatch.failure("UI screenshots must come from github_download_artifact for the exact verified commit. Extract into its returned extract_into directory and inspect the new screenshots, not an older build or a reference image.") }
        }
    }
    func projectContext(_ project: ZeusProjectContract?) throws -> Any {
        guard let project else { return NSNull() }
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        object["userGoal"] = String(project.userGoal.prefix(4000))
        object.removeValue(forKey: "loadedSkills")
        object["loaded_skill_names"] = (project.loadedSkills ?? [:]).keys.sorted()
        object["notes"] = project.notes?.suffix(4).map { $0.text } ?? []
        object["evidence"] = project.evidence.mapValues { ["passed": $0.passed, "generation": $0.generation, "source": $0.source] as [String: Any] }
        object.removeValue(forKey: "reviewedImages")
        object.removeValue(forKey: "reviewedImageCommits")
        object["rules"] = "The user must explicitly approve the native plan card before any project mutation, even in unrestricted mode. Follow the approved architecture/features/steps. Implement loading/error/empty/offline states, responsive accessible UI and actual tests. Read repository AGENTS.md and relevant skills. Build/test on the approved route; absent local Swift/Xcode must lead to GitHub Actions or a precise connection request, not manual-build completion. Keep milestone updates and continue. Completion requires current evidence for every approved criterion; preserve checkpoints and never weaken failed checks silently."
        return object
    }
    func rebindProjectCard(session: String, messages: [ChatMessage]) {
        var value = state(session)
        guard let hash = value.project?.proposal?.hash else { return }
        // Original persisted tool inputs identify the approved proposal even
        // when the UI rebuilds every block with a fresh UUID on reload.
        let match = messages.reversed().lazy.flatMap { $0.blocks.reversed() }.first { block in
            guard case .shellTool(let command) = block.kind, command == "propose_project_plan",
                  let input = block.toolInputArgs, let data = input.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let proposal = try? ZeusProjectContract.decoded(args) else { return false }
            return proposal.hash == hash
        }
        guard let match, value.project?.approvalBlock != match.id.uuidString else { return }
        value.project?.approvalBlock = match.id.uuidString
        try? save(session, value)
    }
    func projectForBlock(_ id: UUID) -> (State, ZeusProjectContract)? {
        for value in states.values where value.project?.approvalBlock == id.uuidString {
            if let project = value.project { return (value, project) }
        }
        return nil
    }
    func recordProjectPermission(session: String?, tool: String, allowed: Bool) {
        guard let session else { return }; var value = state(session)
        guard value.project != nil else { return }
        if !allowed { value.project?.permissionBlocker = tool }
        else if value.project?.permissionBlocker == tool { value.project?.permissionBlocker = nil }
        try? save(session, value)
    }
    func isRoutineProjectAction(tool: String, args: [String: Any], session: String?) -> Bool {
        guard let session, let project = state(session).project, project.decision == "approved", let p = project.proposal, p.hash == project.approvedHash else { return false }
        func inWorkspace(_ path: String) -> Bool {
            let normalized = Self.projectImagePath(path)
            return normalized == "/var/minis/workspace" || normalized.hasPrefix("/var/minis/workspace/")
        }
        if ["file_write", "file_edit"].contains(tool), let path = args["path"] as? String { return inWorkspace(path) }
        if tool == "apply_patch" { return inWorkspace(args["workdir"] as? String ?? "/var/minis/workspace") }
        if tool == "task_verify", let commands = args["commands"] as? [String] {
            return inWorkspace(args["workdir"] as? String ?? "/var/minis/workspace") && Set(commands).isSubset(of: Set(p.checks.compactMap(\.command)))
        }
        if tool == "github_write_files", let branch = p.branch, !["main", "master", "production", "release"].contains(branch.lowercased()) {
            return args["account_id"] as? String == p.github_account_id && args["repository"] as? String == p.repository && args["branch"] as? String == branch
        }
        if tool == "github_download_artifact" { return args["account_id"] as? String == p.github_account_id && args["repository"] as? String == p.repository }
        if tool == "github_request", args["account_id"] as? String == p.github_account_id, let repo = p.repository,
           let branch = p.branch, !["main", "master", "production", "release"].contains(branch.lowercased()),
           let path = args["path"] as? String, path.hasPrefix("/repos/" + repo + "/") {
            let method = args["method"] as? String ?? "GET", body = args["body"] as? [String: Any] ?? [:]
            if method == "PUT", path.contains("/contents/"), body["branch"] as? String == branch { return true }
            if method == "POST", path.hasSuffix("/git/refs"), body["ref"] as? String == "refs/heads/" + branch { return true }
            if method == "POST", path.hasSuffix("/git/trees") || path.hasSuffix("/git/commits") { return true }
            if method == "PATCH", path.hasSuffix("/git/refs/heads/" + branch), body["force"] as? Bool != true { return true }
            if method == "POST", path.hasSuffix("/actions/workflows/" + ((p.workflow ?? "") as NSString).lastPathComponent + "/dispatches"), body["ref"] as? String == branch { return true }
        }
        return false
    }
    static func projectImagePath(_ path: String) -> String {
        URL(fileURLWithPath: path.hasPrefix("/") ? path : "/var/minis/workspace/" + path).standardizedFileURL.path
    }
}
