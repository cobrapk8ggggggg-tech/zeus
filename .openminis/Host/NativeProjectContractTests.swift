import XCTest
import UIKit
@testable import Minis

@MainActor final class NativeProjectContractTests: XCTestCase {
    private func proposal(remote: Bool = false, repository: String = "fixture-owner/project") throws -> [String: Any] {
        let raw = remote ? #"""
        {"title":"Audio app project","objective":"Implement and verify the approved audio product","platform":"ios",
         "features":[{"id":"playback","title":"Audio playback"},{"id":"offline","title":"Offline library"}],
         "architecture":["App and Views","Audio and Library services","Unit and UI tests"],
         "steps":["Implement approved app","Build, test and review UI"],
         "checks":[{"id":"build","title":"Build native app","kind":"build","covers":[],"github_job":"verify","github_step":"Build app","artifact":"app-bundle"},
                   {"id":"features","title":"Playback and offline tests","kind":"functional","covers":["playback","offline"],"github_job":"verify","github_step":"Test features"},
                   {"id":"ui","title":"Inspect actual app screenshots","kind":"ui","covers":[],"github_job":"verify","github_step":"Review screenshots","artifact":"ui-screenshots","screenshot_path":"artifacts/ui/home.png"}],
         "deliverables":["Native app build","Source and tests","UI screenshots"],"assumptions":["Test audio fixtures"],
         "build_route":"github_actions","github_account_id":"first","repository":"fixture-owner/project","branch":"feature/project","workflow":".github/workflows/ci.yml"}
        """# : #"""
        {"title":"Local project","objective":"Implement and verify a project value","platform":"backend",
         "features":[{"id":"value","title":"Stores the correct value"}],"architecture":["Project value","Project tests"],
         "steps":["Implement project","Build and verify"],
         "checks":[{"id":"build","title":"Project file exists","kind":"build","covers":[],"command":"test -s value.txt"},
                   {"id":"value","title":"Value is correct","kind":"functional","covers":["value"],"command":"test \"$(cat value.txt)\" = correct"}],
         "deliverables":["Verified project files"],"assumptions":[],"build_route":"local"}
        """#
        var result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        if remote { result["repository"] = repository }
        return result
    }
    private func waitForPlan(_ block: UUID) async throws {
        for _ in 0..<200 {
            if ZeusToolPermissions.shared.requests[block]?.plan != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Inline plan approval did not appear")
    }
    func testProseToolJSONIsNeverExecutedAndRecoveryIsBoundedAndSelectsOnlyAnAdvertisedTool() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ZeusAgentHarness(root: root), session = UUID().uuidString
        runtime.registerUserRequest("Build a Swift audio app", session: session)
        let text = #"{"tool_calls":[{"name":"github_request","arguments":{"body":{"content":"BASE64_TEXT"}}}]}"#
        let tools: Set<String> = ["github_request", "github_write_files"]
        let first = try XCTUnwrap(runtime.recoverToolText(text, tools: tools, session: session))
        XCTAssertTrue(first.instruction?.hasPrefix(ZeusToolRecovery.marker + "github_write_files") == true)
        XCTAssertFalse(first.notice.contains("BASE64_TEXT"))
        XCTAssertEqual(runtime.state(session).ledger.count, 0, "Visible text must never execute or enter the execution ledger")
        let messages = [AgentMessage(role: .user, parts: [.text(first.instruction!)])]
        XCTAssertEqual(ZeusToolRecovery.forcedTool(messages, available: tools), "github_write_files")
        XCTAssertNil(ZeusToolRecovery.forcedTool(messages, available: ["file_read"]))
        XCTAssertNotNil(runtime.recoverToolText(text, tools: tools, session: session)?.instruction)
        XCTAssertNil(runtime.recoverToolText(text, tools: tools, session: session)?.instruction)
        XCTAssertEqual(runtime.state(session).status, "waiting_user")
        XCTAssertNil(ZeusToolRecovery.candidate("A normal progress update", tools: tools))
    }
    func testRepeatedProviderIDsAreScopedToTheirOriginalToolSlotWithoutReplayingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ZeusAgentHarness(root: root), vm = AIChatViewModel(); vm.sessionId = UUID().uuidString
        let message = UUID().uuidString
        let first = ZeusAgentHarness.scopedCallID(providerID: "call_0", sourceMessageID: message)
        let second = ZeusAgentHarness.scopedCallID(providerID: "call_0", sourceMessageID: UUID().uuidString)
        XCTAssertNotEqual(first, second)
        _ = try await runtime.execute("update_plan", args: ["plan": [["step": "Inspect", "status": "in_progress"]]], callID: first, vm: vm)
        _ = try await runtime.execute("update_plan", args: ["plan": [["step": "Inspect", "status": "completed"]]], callID: second, vm: vm)
        do { _ = try await runtime.execute("update_plan", args: ["plan": [["step": "Different call", "status": "pending"]]], callID: first, vm: vm); XCTFail("The same persisted tool slot must not be replayed with different arguments") } catch {}
    }
    func testProjectIntentAndCancellationDoNotAuthorizeSourceWrites() async throws {
        XCTAssertTrue(ZeusProjectContract.isProjectRequest("أنشئ لي تطبيقاً جديداً"))
        XCTAssertTrue(ZeusProjectContract.isProjectRequest("ابني لي تطبيق أصوات"))
        XCTAssertTrue(ZeusProjectContract.isProjectRequest("Build a website with offline support"))
        XCTAssertFalse(ZeusProjectContract.isProjectRequest("Create an apple pie recipe"))
        XCTAssertFalse(ZeusProjectContract.isProjectRequest("اشرح إعدادات المتصفح"))
        let fallback = ZeusAgentHarness(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), fallbackSession = UUID().uuidString
        fallback.registerUserRequest("أريد تطبيق Swift صوتي بواجهات الصور", session: fallbackSession)
        XCTAssertThrowsError(try fallback.projectGate(tool: "file_write", args: ["path": "App.swift"], session: fallbackSession))
        XCTAssertTrue(fallback.state(fallbackSession).project?.userGoal.contains("Swift") == true)
        let runtime = ZeusAgentHarness.shared, permissions = ZeusToolPermissions.shared
        let prior = permissions.mode; permissions.mode = .unrestricted
        defer { permissions.mode = prior }
        let vm = AIChatViewModel(); vm.sessionId = UUID().uuidString
        let sid = try XCTUnwrap(vm.sessionId)
        runtime.registerUserRequest("Build a backend project", session: sid)
        _ = try await runtime.projectEnvironment(vm: vm)
        let args: [String: Any] = ["proposal": try proposal()]
        let block = UUID()
        let pending = Task { try await permissions.authorize(tool: "propose_project_plan", args: args, sessionID: sid, blockID: block) }
        defer { pending.cancel() }
        try await waitForPlan(block)
        permissions.respondPlan(block, decision: "cancelled")
        do { try await pending.value; XCTFail("Cancelled plan must not be authorized") } catch {}
        XCTAssertEqual(runtime.state(sid).project?.decision, "cancelled")
        XCTAssertThrowsError(try runtime.projectGate(tool: "shell_execute", args: ["command": "touch unauthorized"], session: sid))
        do { _ = try await runtime.execute("task_complete", args: ["status": "completed", "summary": "Cancelled project"], callID: "cancelled-complete", vm: vm); XCTFail("Cancellation is not completed work") } catch {}
    }
    func testProjectPlanRequiresRealApprovalEvenWhenToolsAreUnrestrictedAndSurvivesReload() async throws {
        let runtime = ZeusAgentHarness.shared, permissions = ZeusToolPermissions.shared
        let prior = permissions.mode; permissions.mode = .unrestricted
        defer { permissions.mode = prior }
        let vm = AIChatViewModel(); vm.sessionId = UUID().uuidString
        let sid = try XCTUnwrap(vm.sessionId)
        runtime.registerUserRequest("أنشئ مشروع خدمة كامل مع اختبارات", session: sid)
        do { _ = try await runtime.execute("exec_command", args: ["cmd": "touch must-not-exist"], callID: "before-plan", vm: vm); XCTFail("Project source execution must be blocked before approval") } catch {}
        _ = try await runtime.projectEnvironment(vm: vm)
        let resolvedRoot = await vm.resolvePathForDirectRead("/var/minis/workspace")
        let root = try XCTUnwrap(resolvedRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-exist").path))
        var brief = try proposal(), args: [String: Any] = ["proposal": brief]
        let first = UUID()
        let rejected = Task { try await permissions.authorize(tool: "propose_project_plan", args: args, sessionID: sid, blockID: first) }
        defer { rejected.cancel() }
        try await waitForPlan(first)
        permissions.mode = .unrestricted // Must not auto-approve the plan.
        XCTAssertNotNil(permissions.requests[first])
        XCTAssertNil(runtime.state(sid).project?.approvedHash)
        XCTAssertThrowsError(try runtime.projectGate(tool: "file_write", args: ["path": "/var/minis/workspace/App.swift"], session: sid))
        permissions.respondPlan(first, decision: "changes_requested", note: "Separate the data and UI modules")
        do { try await rejected.value; XCTFail("Revision must not authorize execution") } catch { XCTAssertTrue(error.localizedDescription.contains("Separate the data")) }
        XCTAssertEqual(runtime.state(sid).project?.decision, "changes_requested")
        brief["architecture"] = ["Separate data module", "Separate UI module", "Acceptance tests"]; args = ["proposal": brief]
        let second = UUID()
        let accepted = Task { try await permissions.authorize(tool: "propose_project_plan", args: args, sessionID: sid, blockID: second) }
        defer { accepted.cancel() }
        try await waitForPlan(second)
        permissions.respondPlan(second, decision: "approved")
        try await accepted.value
        _ = try await runtime.execute("propose_project_plan", args: args, callID: "approved-plan", vm: vm)
        XCTAssertEqual(runtime.state(sid).project?.approvedHash, try ZeusProjectContract.decoded(args).hash)
        XCTAssertEqual(ZeusAgentHarness().state(sid).project?.approvedHash, runtime.state(sid).project?.approvedHash)
        let reloadedBlock = AssistantBlock(kind: .shellTool(command: "propose_project_plan"), content: "", toolStatus: .success, toolUseId: "approved-plan")
        reloadedBlock.toolInputArgs = try ZeusAgentHarness.json(args)
        let loadedRuntime = ZeusAgentHarness()
        loadedRuntime.rebindProjectCard(session: sid, messages: [ChatMessage(role: .assistant, content: "", blocks: [reloadedBlock])])
        XCTAssertNotNil(loadedRuntime.projectForBlock(reloadedBlock.id))
        permissions.mode = .consequential
        try await permissions.authorize(tool: "file_write", args: ["path": "/var/minis/workspace/Source.swift", "content": "source"], sessionID: sid, blockID: UUID())
        XCTAssertFalse(permissions.requests.values.contains { $0.sessionID == sid })
        do { _ = try await runtime.execute("task_complete", args: ["status": "completed", "summary": "one source file is enough"], callID: "premature", vm: vm); XCTFail("Unbuilt product must not complete") } catch {}
        let changed = try proposal()
        do { _ = try await runtime.execute("propose_project_plan", args: ["proposal": changed], callID: "forged-approval", vm: vm); XCTFail("Different plan hash requires new approval") } catch {}
    }
    func testActualGitHubRESTChecksRouteCommitJobsArtifactsAndReadsDownloadedUIScreenshot() async throws {
        let key = "zeus.contract.fixture." + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let connections = ZeusConnections(storageKey: key)
        let accounts = ["first", "second"].map { ZeusLinkedAccount(id: $0, provider: "github", label: $0, isDefault: $0 == "first", verified: false, toolCount: 0, linkedAt: Date()) }
        connections.configureFixture(endpoint: URL(string: "http://127.0.0.1:8765/mcp-fixture")!, accounts: accounts)
        let client = ZeusGitHubTools(connections: connections)
        client.configureFixture(URL(string: "http://127.0.0.1:8765/github-rest-fixture")!)
        defer { client.close() }
        let firstIdentity = try await client.object(accountID: "first", path: "/user")
        let secondIdentity = try await client.object(accountID: "second", path: "/user")
        XCTAssertEqual(firstIdentity["login"] as? String, "fixture-owner")
        XCTAssertEqual(secondIdentity["login"] as? String, "other-owner")
        let logs = try await client.request(accountID: "first", path: "/repos/fixture-owner/project/actions/jobs/123/logs")
        XCTAssertTrue((logs["data"] as? String ?? "").contains("App.swift:12: missing symbol"))
        XCTAssertEqual(logs["authorization_forwarded"] as? Bool, false)
        let runtime = ZeusAgentHarness.shared, vm = AIChatViewModel()
        let created = try DebugRPCProvider.instancesCreate(params: ["providerType": "openAI", "label": "Contract vision fixture", "apiKey": "local-fixture-only", "customBaseURL": "http://127.0.0.1:8765/v1", "appendV1Suffix": false, "seedBuiltInModels": false])
        let instance = try XCTUnwrap(created["instance"] as? [String: Any]), providerID = try XCTUnwrap(instance["id"] as? String)
        defer { _ = try? DebugRPCProvider.instancesDelete(params: ["instanceId": providerID, "confirm": true]) }
        let model = try DebugRPCProvider.modelsAdd(params: ["instanceId": providerID, "modelId": "fixture-contract-vision", "supportsImageInput": true])
        let entryID = try XCTUnwrap(model["id"] as? String)
        let saved = await ChatStore.shared.createSession(modelId: "fixture-contract-vision", title: "Project contract test")
        vm.sessionId = saved.id; let sid = saved.id
        ProviderConfigStore.shared.setBinding(SessionModelBinding(sessionId: sid, primarySource: .directEntry(modelEntryId: entryID)), for: sid)
        runtime.registerUserRequest("ابني لي تطبيق Swift أصوات مثل سبوتيفاي مع مكتبة دون اتصال", session: sid)
        _ = try await runtime.projectEnvironment(vm: vm)
        XCTAssertEqual(runtime.state(sid).project?.environment?.hasIOSSDK, false)
        XCTAssertNotNil(runtime.state(sid).project?.loadedSkills?["swiftui-ui-patterns"])
        let once = runtime.refreshContext("Original system", session: sid)
        XCTAssertEqual(runtime.refreshContext(once, session: sid), once, "Refreshing context must not duplicate skill bodies or grow whitespace")
        XCTAssertTrue(once.contains("<zeus_project_skills>"))
        XCTAssertTrue(runtime.state(sid).project?.notes?.contains(where: { $0.text.contains("مهارات") }) == true)
        let raw = try proposal(remote: true)
        var invalidLocal = raw; invalidLocal["build_route"] = "local"
        XCTAssertThrowsError(try ZeusProjectContract.validate(ZeusProjectContract.decoded(["proposal": invalidLocal])))
        var withReference = runtime.state(sid)
        withReference.project?.referenceImages = ["/var/minis/attachments/reference.png"]
        try runtime.save(sid, withReference)
        XCTAssertThrowsError(try runtime.prepareProjectProposal(["proposal": raw], session: sid, blockID: UUID(), connections: connections), "A user-supplied UI image must be inspected before planning")
        runtime.observe(session: sid, tool: "read_image", success: true, args: ["path": "minis://attachments/reference.png"], imageDelivered: true)
        XCTAssertEqual(runtime.state(sid).project?.inspectedReferences, ["/var/minis/attachments/reference.png"])
        XCTAssertThrowsError(try runtime.prepareProjectProposal(["proposal": raw], session: sid, blockID: UUID(), connections: connections), "Inspected references still need concrete design notes")
        withReference.project?.referenceImages = []; try runtime.save(sid, withReference)
        let approved = try runtime.prepareProjectProposal(["proposal": raw], session: sid, blockID: UUID(), connections: connections)
        try runtime.decideProject(session: sid, hash: approved.hash, decision: "approved")
        do { _ = try await runtime.execute("task_complete", args: ["status": "blocked", "summary": "Swift is absent; user should build manually"], callID: "no-remote-attempt", vm: vm); XCTFail("Missing local Swift must not stop an approved remote project") } catch {}
        _ = try await runtime.githubProjectRequest(["account_id": "first", "path": "/repos/fixture-owner/project"], session: sid, client: client)
        do { _ = try await runtime.execute("task_complete", args: ["status": "waiting_user", "summary": "I inspected GitHub but user should build manually"], callID: "one-read-not-work", vm: vm); XCTFail("One successful metadata read is not a hard blocker") } catch {}
        for path in ["https://evil.example/", "//evil.example/", "/repos/o/r/../escape", "/repos/o/r/%2e%2e/escape"] { XCTAssertThrowsError(try ZeusGitHubTools.relativePath(path)) }
        do { _ = try await runtime.githubProjectRequest(["account_id": "second", "path": "/user"], session: sid, client: client); XCTFail("Never substitute a different account") } catch {}
        do { _ = try await runtime.githubProjectRequest(["account_id": "first", "method": "PUT", "path": "/repos/fixture-owner/project/contents/App.swift", "body": ["branch": "main", "content": "dGVzdA=="]], session: sid, client: client); XCTFail("Do not write the wrong branch") } catch {}
        let source = "import SwiftUI\n// مصدر عربي\nstruct AudioApp {}\n"
        let commitReceipt = try await runtime.githubWriteFiles(["account_id": "first", "repository": "fixture-owner/project", "branch": "feature/project", "message": "Implement real source", "files": [["path": "App.swift", "content": source], ["path": "README.md", "content": "Audio app"]]], session: sid, client: client)
        XCTAssertTrue(commitReceipt.contains("written_directly_to_github"))
        let read = try await client.readSource(accountID: "first", repository: "fixture-owner/project", branch: "feature/project", path: "App.swift")
        XCTAssertEqual(read["content"] as? String, source)
        XCTAssertThrowsError(try ZeusGitHubTools.sourcePath("../escape.swift"))
        _ = try await runtime.githubProjectRequest(["account_id": "first", "method": "POST", "path": "/repos/fixture-owner/project/actions/workflows/ci.yml/dispatches", "body": ["ref": "feature/project"]], session: sid, client: client)
        let sha = String(repeating: "1", count: 40)
        let base: [String: Any] = ["account_id": "first", "repository": "fixture-owner/project", "run_id": 42, "expected_sha": sha]
        for run in [43, 44, 45] {
            do { _ = try await client.verify(proposal: approved, accountID: "first", repository: "fixture-owner/project", runID: run, sha: sha, generation: 0); XCTFail("Wrong SHA/workflow or failed run must be rejected") } catch {}
        }
        let stale = try ZeusProjectContract.decoded(["proposal": proposal(remote: true, repository: "fixture-owner/stale")])
        do { _ = try await client.verify(proposal: stale, accountID: "first", repository: "fixture-owner/stale", runID: 42, sha: sha, generation: 0); XCTFail("An old run cannot verify a newer branch HEAD") } catch {}
        for run in [47, 48] {
            let checks = try await client.verify(proposal: approved, accountID: "first", repository: "fixture-owner/project", runID: run, sha: sha, generation: 0)
            XCTAssertTrue(checks.contains { !$0.passed })
        }
        _ = try await runtime.verifyGitHubProject(base, session: sid, client: client)
        for index in approved.steps.indices {
            _ = try await runtime.execute("update_plan", args: ["explanation": "انتهت مرحلة التنفيذ والتحقق " + String(index), "plan": approved.steps.enumerated().map { ["step": $0.element, "status": $0.offset <= index ? "completed" : "pending"] }], callID: "steps-done-" + String(index), vm: vm)
        }
        do { _ = try await runtime.execute("task_complete", args: ["status": "completed", "summary": "CI is green; skip UI inspection"], callID: "unseen-ui", vm: vm); XCTFail("Artifact presence alone is not visual review") } catch {}
        var download = base; download["artifact_id"] = 2; download["destination"] = "artifacts/ui.zip"
        let receipt = try await runtime.downloadGitHubArtifact(download, session: sid, vm: vm, client: client)
        XCTAssertFalse(receipt.contains("Bearer")); XCTAssertFalse(receipt.contains("redirect_url"))
        let extraction = try await vm.executeCommand("mkdir -p /var/minis/workspace/artifacts/ui && busybox unzip -o /var/minis/workspace/artifacts/ui.zip -d /var/minis/workspace/artifacts/ui", timeout: 30) { _ in }
        XCTAssertEqual(extraction.exitCode, 0, extraction.output)
        runtime.observe(session: sid, tool: "shell_execute", success: extraction.exitCode == 0)
        let imagePath = "/var/minis/workspace/artifacts/ui/home.png"
        let block = AssistantBlock(kind: .readImageTool(path: imagePath), content: "", toolStatus: .running, toolUseId: "review-ui")
        vm.messages = [ChatMessage(role: .assistant, content: "", blocks: [block])]
        let call = AIChatViewModel.StreamResult.ToolEntry(id: "review-ui", name: "read_image", args: ["path": imagePath], blockIdx: 0, metadata: nil, inputChunkRing: [])
        let outcome = await vm.executeSingleToolUse(tu: call, msgIdx: 0, tools: vm.makeAgentTools(), batchBudget: AIChatViewModel.BatchImageBudget(initial: 1))
        if case .toolResult(_, _, let content, let isError, let image, _, _, _) = outcome.resultPart {
            XCTAssertFalse(isError, content); XCTAssertNotNil(image)
        } else { XCTFail("Actual read_image must deliver pixels") }
        XCTAssertEqual(runtime.state(sid).project?.reviewedImageCommits?[imagePath], sha)
        _ = try await runtime.verifyGitHubProject(base, session: sid, client: client)
        _ = try await runtime.execute("task_complete", args: ["status": "completed", "summary": "Verified exact build, tests and reviewed screenshots"], callID: "verified", vm: vm)
        XCTAssertEqual(runtime.state(sid).status, "completed")
        let ticket = UUID()
        XCTAssertTrue(try runtime.beginSourceChange(session: sid, tool: "file_write", args: [:], ticket: ticket))
        do { _ = try await runtime.execute("task_complete", args: ["status": "completed", "summary": "Race completion against a write"], callID: "racy", vm: vm); XCTFail("Do not verify while a mutation is executing") } catch {}
        runtime.finishSourceChange(session: sid, ticket: ticket)
        do { _ = try await runtime.execute("task_complete", args: ["status": "completed", "summary": "Old checks after an edit"], callID: "stale", vm: vm); XCTFail("Source edits invalidate earlier CI/UI evidence") } catch {}
        let redirect = try await client.request(accountID: "first", path: "/redirect")
        XCTAssertEqual(redirect["authorization_forwarded"] as? Bool, false)
        await ChatStore.shared.deleteSession(sid)
    }
}
