import XCTest
import WebKit
@testable import ZEUSBrowser
@testable import Minis

@MainActor
final class NativeBrowserIntegrationTests: XCTestCase {
    func testGitHubDeviceGrantUsesHTTPSVerificationAndHonorsPendingSlowdownAndCancellation() async throws {
        let auth = ZeusGitHubAuthorization(fixture: URL(string: "http://127.0.0.1:8765/github-device-fixture")!)
        let grant = try await auth.start(clientID: UUID().uuidString, scopes: "repo read:org user:email workflow")
        XCTAssertEqual(grant.presentation.verificationURL.absoluteString, "https://github.com/login/device")
        var delays: [Double] = []
        let tokens = try await auth.poll(grant) { delays.append($0) }
        XCTAssertEqual(tokens.accessToken, "fixture-device-access")
        XCTAssertEqual(delays, [5, 5, 10])
        for client in ["disabled", "untrusted"] {
            do { _ = try await auth.start(clientID: client, scopes: nil); XCTFail("Invalid or disabled device grants must be rejected") } catch {}
        }
        for client in ["denied", "expired"] {
            let rejected = try await auth.start(clientID: client, scopes: nil)
            do { _ = try await auth.poll(rejected) { _ in }; XCTFail("Rejected grants must not create accounts") } catch {}
        }
        let cancelled = try await auth.start(clientID: "cancelled", scopes: nil)
        auth.cancel()
        do { _ = try await auth.poll(cancelled) { _ in XCTFail("Cancellation must stop polling") }; XCTFail("Cancelled grant must fail") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error") }
    }
    func testActualNativeModelLoopStreamsAndVerifiesAProject() async throws {
        let store = ProviderConfigStore.shared
        for _ in 0..<200 where !store.zeusFixtureLoadFinished { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(store.zeusFixtureLoadFinished)
        let created = try DebugRPCProvider.instancesCreate(params: ["providerType": "openAI", "label": "Native loop fixture " + UUID().uuidString, "apiKey": "local-fixture-only", "customBaseURL": "http://127.0.0.1:8765/v1", "appendV1Suffix": false, "seedBuiltInModels": false])
        let instance = try XCTUnwrap(created["instance"] as? [String: Any]), id = try XCTUnwrap(instance["id"] as? String)
        defer { _ = try? DebugRPCProvider.instancesDelete(params: ["instanceId": id]) }
        XCTAssertEqual(ProviderKeychainHelper.loadAPIKey(instanceId: id), "local-fixture-only", "The simulator must preserve real Keychain credentials")
        let stream = try DebugRPCProvider.modelsAdd(params: ["instanceId": id, "modelId": "fixture-native-stream", "displayName": "Native full loop", "contextWindow": 128000, "maxOutputTokens": 16000])
        let response = try await DebugRPCChat.prompt(params: ["prompt": "اعرض النص كاملًا كما يرسله مزود الاختبار.", "modelEntryId": stream["id"]!, "thinkingLevel": "off", "wait": true, "waitTimeout": 60])
        XCTAssertTrue((response["responseText"] as? String ?? "").hasSuffix("نهاية الرسالة NATIVE_STREAM_END"))
        let project = try DebugRPCProvider.modelsAdd(params: ["instanceId": id, "modelId": "fixture-native-harness-" + UUID().uuidString, "displayName": "Native project loop", "contextWindow": 128000, "maxOutputTokens": 4000])
        let prior = ZeusToolPermissions.shared.mode; ZeusToolPermissions.shared.mode = .unrestricted
        defer { ZeusToolPermissions.shared.mode = prior }
        let completed = try await DebugRPCChat.prompt(params: ["prompt": "أنشئ المشروع، شغّل الفحص وأصلح الخطأ وتحقق منه فعلياً.", "modelEntryId": project["id"]!, "thinkingLevel": "off", "wait": true, "waitTimeout": 60])
        XCTAssertTrue((completed["responseText"] as? String ?? "").contains("NATIVE_HARNESS_VERIFIED"))
        let session = try XCTUnwrap(completed["sessionId"] as? String)
        XCTAssertEqual(ZeusAgentHarness.shared.state(session).status, "completed")
        await ChatStore.shared.deleteSession(session)
        if let session = response["sessionId"] as? String { await ChatStore.shared.deleteSession(session) }
    }
    func testNativeMCPUsesRealHTTPPaginationNestedSchemasAndIsolatedAccounts() async throws {
        let key = "zeus.integration.fixture." + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let connections = ZeusConnections(storageKey: key)
        let accounts = ["first", "second"].map { ZeusLinkedAccount(id: $0, provider: "github", label: $0, isDefault: $0 == "first", verified: false, toolCount: 0, linkedAt: Date()) }
        connections.configureFixture(endpoint: URL(string: "http://127.0.0.1:8765/mcp-fixture")!, accounts: accounts)
        XCTAssertThrowsError(try connections.account("missing", provider: "github"))
        XCTAssertThrowsError(try connections.account("first", provider: "vercel"))
        XCTAssertEqual(try connections.account(nil, provider: "github").id, "first")
        async let first = connections.listTools("first")
        async let second = connections.listTools("second")
        let lists = try await [first, second]
        XCTAssertEqual(lists.map(\.count), [2, 2])
        XCTAssertTrue(connections.isReadOnly("first", tool: "fixture_read"))
        XCTAssertFalse(connections.isReadOnly("first", tool: "fixture_write"))
        do { _ = try await connections.call("first", name: "fixture_write", arguments: ["input": "malformed"]); XCTFail("Nested arguments must be rejected before HTTP mutation") } catch {}
        let result = try await connections.call("second", name: "fixture_read", arguments: ["input": ["values": [1, 2, 3]]])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("second")); XCTAssertFalse(text.contains("first"))
        connections.makeDefault("second")
        XCTAssertEqual(try connections.account(nil, provider: "github").id, "second")
        XCTAssertEqual(ZeusConnections(storageKey: key).accounts.count, 2)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ZeusAgentHarness(root: root), vm = AIChatViewModel(); vm.sessionId = "remote-" + UUID().uuidString
        _ = try await runtime.execute("update_plan", args: ["plan": [["step": "Verify remote project", "status": "completed"]]], callID: "plan", vm: vm)
        let spec: [String: Any] = ["account_id": "second", "tool_name": "fixture_read", "arguments": ["input": ["values": [1]]], "assertions": [["path": ["account"], "equals": "second"]]]
        _ = try await runtime.verifyRemote([spec], session: vm.sessionId!, connections: connections)
        var weakened = spec; weakened["assertions"] = [["path": ["account"], "equals": "first"]]
        do { _ = try await runtime.verifyRemote([weakened], session: vm.sessionId!, connections: connections); XCTFail("Registered remote assertions cannot change") } catch {}
        var mutating = spec; mutating["tool_name"] = "fixture_write"
        do { _ = try await runtime.verifyRemote([mutating], session: vm.sessionId!, connections: connections); XCTFail("Verification must not invoke mutating tools") } catch {}
        runtime.observe(session: vm.sessionId, tool: "shell_execute", success: true)
        do { _ = try await runtime.execute("task_complete", args: ["status": "completed", "summary": "stale evidence"], callID: "stale", vm: vm); XCTFail("Mutations invalidate remote evidence too") } catch {}
        _ = try await runtime.verifyRemote([spec], session: vm.sessionId!, connections: connections)
        _ = try await runtime.execute("task_complete", args: ["status": "completed", "summary": "Verified using real remote read-only JSON without local Linux"], callID: "finish", vm: vm)
        XCTAssertEqual(runtime.state(vm.sessionId!).status, "completed")
    }
    func testRemoteVerificationRejectsProseWrongCommitsAndErrorResults() throws {
        let assertions: [[String: Any]] = [["path": ["conclusion"], "equals": "success"], ["path": ["head_sha"], "equals": "expected-commit"]]
        let success: [String: Any] = ["structuredContent": ["conclusion": "success", "head_sha": "expected-commit"]]
        XCTAssertNoThrow(try ZeusRemoteEvidence.evaluate(success, assertions: assertions))
        XCTAssertThrowsError(try ZeusRemoteEvidence.evaluate(["content": [["type": "text", "text": "The deployment succeeded!"]]], assertions: assertions))
        XCTAssertThrowsError(try ZeusRemoteEvidence.evaluate(["structuredContent": ["conclusion": "success", "head_sha": "other-commit"]], assertions: assertions))
        XCTAssertThrowsError(try ZeusRemoteEvidence.evaluate(["isError": true, "structuredContent": success["structuredContent"]!], assertions: assertions))
    }
    func testIntegrationSchemasResolveReferencesAndNullableAlternatives() throws {
        let shape: [String: Any] = ["type": "object", "$defs": ["id": ["type": "string", "pattern": "^[a-z]+$"]], "properties": ["ids": ["type": "array", "items": ["$ref": "#/$defs/id"]], "name": ["type": ["string", "null"]]], "required": ["ids", "name"], "additionalProperties": false]
        try ZeusAgentSchemas.validate(["ids": ["alpha"], "name": NSNull()], schema: shape)
        XCTAssertThrowsError(try ZeusAgentSchemas.validate(["ids": [12], "name": NSNull()], schema: shape))
        XCTAssertThrowsError(try ZeusAgentSchemas.validate(["ids": ["UPPER"], "name": true], schema: shape))
    }
    func testGeminiWireUsesFullJSONSchemaForNativeObjectArguments() throws {
        let declaration = GeminiConversation.toolDefinition(name: "integration_call", description: "fixture", parameters: [:])
        XCTAssertNil(declaration["parameters"])
        let shape = try XCTUnwrap(declaration["parametersJsonSchema"] as? [String: Any])
        let fields = try XCTUnwrap(shape["properties"] as? [String: [String: Any]])
        XCTAssertEqual(fields["arguments"]?["type"] as? String, "object")
        XCTAssertEqual(fields["arguments"]?["additionalProperties"] as? Bool, true)
        let plan = GeminiConversation.toolDefinition(name: "update_plan", description: "fixture", parameters: [:])
        XCTAssertEqual((((plan["parametersJsonSchema"] as? [String: Any])?["properties"] as? [String: [String: Any]])?["plan"]?["type"] as? String), "array")
    }
    func testOpenAIWiresKeepDynamicArgumentsAndOptionalFields() throws {
        for responses in [false, true] {
            let declaration = try XCTUnwrap(ZeusAgentSchemas.openAI("integration_call", description: "fixture", responses: responses))
            let function: [String: Any]
            if responses { function = declaration } else { function = try XCTUnwrap(declaration["function"] as? [String: Any]) }
            XCTAssertEqual(function["strict"] as? Bool, false)
            let shape = try XCTUnwrap(function["parameters"] as? [String: Any])
            try ZeusAgentSchemas.validate(["account_id": "fixture", "tool_name": "read", "arguments": ["nested": ["ids": [1, 2]]]], schema: shape)
            XCTAssertFalse((shape["required"] as? [String] ?? []).contains("approval_reason"))
        }
    }
    func testNativeRuntimeAcceptsNestedSchemasAndRejectsMalformedArguments() throws {
        let schema = try XCTUnwrap(ZeusAgentSchemas.schema("update_plan"))
        try ZeusAgentSchemas.validate(["plan": [["step": "Build", "status": "in_progress"]]], schema: schema)
        let badCases: [[String: Any]] = [
            ["plan": "[{\"step\":\"Build\"}]"], ["plan": [["step": "Build", "status": "invented"]]],
            ["plan": [["step": "Build"]]], ["plan": [], "unknown": true]
        ]
        for bad in badCases { XCTAssertThrowsError(try ZeusAgentSchemas.validate(bad, schema: schema)) }
        XCTAssertThrowsError(try ZeusAgentSchemas.validate(["cmd": "pwd", "timeout_seconds": true], schema: ZeusAgentSchemas.schema("exec_command")!))
        XCTAssertThrowsError(try ZeusAgentSchemas.validate(["cmd": "pwd", "timeout_seconds": -1], schema: ZeusAgentSchemas.schema("exec_command")!))
        XCTAssertThrowsError(try ZeusAgentSchemas.validate(["cmd": "pwd", "timeout_seconds": 999999], schema: ZeusAgentSchemas.schema("exec_command")!))
    }
    func testPatchPrevalidatesAllFilesAndRejectsAmbiguousOrEscapingPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "first\nold\nlast\n".write(to: root.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        let patch = "*** Begin Patch\n*** Update File: one.txt\n@@\n first\n-old\n+new\n last\n*** Add File: two.txt\n+created\n*** End Patch"
        let changes = try ZeusPatch.prepare(patch, root: root)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(String(data: changes[0].after!, encoding: .utf8), "first\nnew\nlast\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("one.txt"), encoding: .utf8), "first\nold\nlast\n")
        XCTAssertThrowsError(try ZeusPatch.prepare(patch.replacingOccurrences(of: "+created", with: "bad"), root: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("two.txt").path))
        XCTAssertThrowsError(try ZeusPatch.prepare("*** Begin Patch\n*** Add File: ../escape\n+x\n*** End Patch", root: root))
        try "old\nold\n".write(to: root.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ZeusPatch.prepare("*** Begin Patch\n*** Update File: one.txt\n@@\n-old\n+new\n*** End Patch", root: root))
    }
    func testRuntimePlanLedgerAndIncompleteWorkSurviveReloadWithoutReplaying() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ZeusAgentHarness(root: root), vm = AIChatViewModel(); vm.sessionId = UUID().uuidString
        let plan: [String: Any] = ["plan": [["step": "Implement", "status": "in_progress"], ["step": "Verify", "status": "pending"]]]
        let first = try await runtime.execute("update_plan", args: plan, callID: "same", vm: vm)
        let repeated = try await runtime.execute("update_plan", args: plan, callID: "same", vm: vm)
        XCTAssertEqual(first, repeated)
        do { _ = try await runtime.execute("task_complete", args: ["status": "completed", "summary": "Done"], callID: "premature", vm: vm); XCTFail("Unfinished work must not complete") } catch {}
        let restored = ZeusAgentHarness(root: root)
        XCTAssertEqual(restored.state(vm.sessionId!).plan.count, 2)
        XCTAssertNotNil(restored.continuation(session: vm.sessionId))
        do { _ = try await restored.execute("update_plan", args: plan, callID: "same", vm: vm); XCTFail("A persisted call must never replay") } catch {}
        XCTAssertFalse(restored.context(session: vm.sessionId).contains("ledger"))
        XCTAssertNotNil(restored.continuation(session: vm.sessionId))
        XCTAssertNil(restored.continuation(session: vm.sessionId))
        XCTAssertEqual(restored.state(vm.sessionId!).status, "waiting_user")
        XCTAssertNotNil(restored.pausedNotice(session: vm.sessionId))
    }
    func testPartialVerificationCannotMarkTaskCompleteAfterReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ZeusAgentHarness(root: root), vm = AIChatViewModel(); vm.sessionId = UUID().uuidString
        _ = try await runtime.execute("update_plan", args: ["plan": [["step": "Verify", "status": "completed"]], "verification_commands": ["check-one", "check-two"]], callID: "plan", vm: vm)
        // Simulate interruption after only one of the two real check results
        // reached durable storage. Completion must reject incomplete evidence.
        var saved = runtime.state(vm.sessionId!)
        saved.checks = [ZeusAgentHarness.Check(command: "check-one", exitCode: 0, output: "", generation: saved.generation, date: Date())]
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        try JSONEncoder().encode(saved).write(to: file, options: .atomic)
        let restored = ZeusAgentHarness(root: root)
        do { _ = try await restored.execute("task_complete", args: ["status": "completed", "summary": "Finished"], callID: "finish", vm: vm); XCTFail("Both registered results are required") } catch {}
        XCTAssertEqual(restored.state(vm.sessionId!).status, "running")
    }
    func testNativeRuntimeReallyEditsTestsRepairsAndVerifiesAProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ZeusAgentHarness(root: root), vm = AIChatViewModel(); vm.sessionId = "harness-" + UUID().uuidString
        try await runtime.prepareEnvironment(vm: vm)
        let dir = "/var/minis/workspace/native-harness-" + UUID().uuidString
        let result = try await vm.executeCommand("mkdir -p " + ZeusAgentHarness.quote(dir), timeout: 30) { _ in }
        XCTAssertEqual(result.exitCode, 0, result.output)
        let nonzero = try await vm.executeCommand("exit 7", timeout: 30) { _ in }
        XCTAssertEqual(nonzero.exitCode, 7, nonzero.output)
        let check = "test \"$(cat value.txt)\" = correct"
        _ = try await runtime.execute("update_plan", args: ["plan": [["step": "Implement and verify", "status": "in_progress"]], "verification_commands": [check]], callID: "plan", vm: vm)
        _ = try await runtime.execute("apply_patch", args: ["workdir": dir, "patch": "*** Begin Patch\n*** Add File: value.txt\n+wrong\n*** Add File: README.md\n+Native runtime project\n*** End Patch"], callID: "create", vm: vm)
        let failed = try await runtime.execute("task_verify", args: ["workdir": dir, "commands": [check]], callID: "failing-check", vm: vm)
        XCTAssertTrue(failed.contains("\"exitCode\":1"))
        do { _ = try await runtime.execute("task_verify", args: ["workdir": dir, "commands": ["true"]], callID: "weaken", vm: vm); XCTFail("Cannot weaken a failed check") } catch {}
        _ = try await runtime.execute("apply_patch", args: ["workdir": dir, "patch": "*** Begin Patch\n*** Update File: value.txt\n@@\n-wrong\n+correct\n*** End Patch"], callID: "repair", vm: vm)
        _ = try await runtime.execute("task_verify", args: ["workdir": dir, "commands": [check]], callID: "passing-check", vm: vm)
        _ = try await runtime.execute("update_plan", args: ["plan": [["step": "Implement and verify", "status": "completed"]]], callID: "finish-plan", vm: vm)
        _ = try await runtime.execute("task_complete", args: ["status": "completed", "summary": "Actual files and shell checks passed"], callID: "finish", vm: vm)
        XCTAssertEqual(runtime.state(vm.sessionId!).status, "completed")
        let other = AIChatViewModel(); other.sessionId = "other-" + UUID().uuidString
        let written = try await other.executeFileWrite(from: ZeusAgentHarness.json(["path": dir + "/value.txt", "content": "isolated-other", "create_dirs": true]))
        XCTAssertTrue(written.success)
        let original = try await vm.executeCommand("cat " + ZeusAgentHarness.quote(dir + "/value.txt"), timeout: 30) { _ in }
        XCTAssertEqual(original.output.trimmingCharacters(in: .whitespacesAndNewlines), "correct")
        let isolated = try await other.executeCommand("cat " + ZeusAgentHarness.quote(dir + "/value.txt"), timeout: 30) { _ in }
        XCTAssertEqual(isolated.output.trimmingCharacters(in: .whitespacesAndNewlines), "isolated-other")
        _ = try await other.executeCommand("rm -rf -- " + ZeusAgentHarness.quote(dir), timeout: 30) { _ in }
        _ = try await vm.executeCommand("rm -rf -- " + ZeusAgentHarness.quote(dir), timeout: 30) { _ in }
    }
    func testOfficialSkillsInstallOfflineWithTheirOriginalAssets() async throws {
        await ZeusDefaultSkills.shared.install()
        XCTAssertNil(ZeusDefaultSkills.shared.error)
        XCTAssertEqual(ZeusDefaultSkills.shared.entries.count, 59)
        for entry in ZeusDefaultSkills.shared.entries {
            let skill = try XCTUnwrap(SkillStore.shared.skills.first { $0.name == entry.installedName })
            XCTAssertTrue(FileManager.default.fileExists(atPath: SkillStore.shared.skillDirectoryURL(for: skill.id).appendingPathComponent("SKILL.md").path))
        }
        // Regression: >20 bundled skills previously made recent.prefix(-N)
        // trap before the original agent sent its first provider request.
        let fragment = try XCTUnwrap(SkillStore.shared.skillPromptFragment(for: UUID().uuidString))
        XCTAssertEqual(fragment.components(separatedBy: "  <skill>\n").count - 1, 20)
        XCTAssertTrue(fragment.contains("more skills not shown above"))
        for entry in ZeusDefaultSkills.shared.entries {
            XCTAssertTrue(fragment.contains(entry.installedName), entry.installedName)
        }
    }
    func testDirectIntegrationCatalogDoesNotRequireAProjectServer() throws {
        XCTAssertEqual(Set(ZeusService.catalog.map(\.id)), ["github", "railway", "vercel"])
        XCTAssertTrue(ZeusService.catalog.allSatisfy { URL(string: $0.endpoint)?.scheme == "https" })
        XCTAssertEqual(ZeusService.catalog.first(where: { $0.id == "github" })?.endpoint, "https://api.githubcopilot.com/mcp/")
    }
    func testProgressTextAndQuotedJSONNeverBecomeToolCalls() async throws {
        let model = LLMModel(id: "fixture-native-progress-tool", displayName: "Progress fixture", provider: "openai")
        let provider = OpenAIAgentProvider(provider: OpenAIProvider(apiKey: "fixture", model: model, customBaseURL: "http://127.0.0.1:8765/v1", appendV1Suffix: false))
        let stream = try await provider.streamAgentMessage(messages: [AgentMessage(role: .user, parts: [.text("Inspect")])], systemPrompt: nil, tools: [ZEUSNativeAgentBridge.definition], maxTokens: 1000, thinkingLevel: .off)
        var text = "", calls: [String] = []
        for try await event in stream {
            if case .textDelta(let delta) = event { text += delta }
            if case .toolCallComplete(_, let name, let args, _) = event {
                calls.append(name); XCTAssertEqual(args["operation"] as? String, "browser_tabs")
            }
        }
        XCTAssertTrue(text.contains("مستجد")); XCTAssertTrue(text.contains("shell_execute"))
        XCTAssertEqual(calls, ["zeus_browser"])
    }
    func testCoreToolTypesAreNormalizedBeforeExecution() throws {
        let tool = AgentToolDefinition(name: "fixture", description: "fixture", parameters: ["enabled": AgentToolParam(type: .boolean, description: "flag"), "limit": AgentToolParam(type: .integer, description: "count"), "arguments": AgentToolParam(type: .string, description: "JSON arguments"), "action": AgentToolParam(type: .string, description: "action", enumValues: ["read", "write"])], required: [])
        let result = try ZeusToolInput.normalize(name: "fixture", args: ["enabled": "false", "limit": "25", "arguments": ["key": "value"], "action": "read"], tools: [tool])
        XCTAssertEqual(result["enabled"] as? Bool, false)
        XCTAssertEqual(result["limit"] as? Int, 25)
        XCTAssertTrue((result["arguments"] as? String ?? "").contains("value"))
        XCTAssertThrowsError(try ZeusToolInput.normalize(name: "fixture", args: ["enabled": 1], tools: [tool]))
        XCTAssertThrowsError(try ZeusToolInput.normalize(name: "fixture", args: ["limit": true], tools: [tool]))
        XCTAssertThrowsError(try ZeusToolInput.normalize(name: "fixture", args: ["action": "invented"], tools: [tool]))
    }
    func testStoredBrowserToolCardsKeepTheirBrowserAndURLAfterRoundTrip() throws {
        let parts: [ContentPart] = [
            .toolUse(ToolUse(toolUseId: "auto1", name: "browser_use", input: #"{"action":"navigate","url":"https://automation.invalid"}"#, description: nil, thoughtSignature: nil)),
            .toolResult(ToolResult(toolUseId: "auto1", output: "automation", success: true, mediaRef: nil, snapshot: nil, pageURL: "https://automation.invalid", status: "success")),
            .toolUse(ToolUse(toolUseId: "user", name: "zeus_browser_read", input: "{}", description: nil, thoughtSignature: nil)),
            .toolResult(ToolResult(toolUseId: "user", output: "user browser", success: true, mediaRef: nil, snapshot: nil, pageURL: "https://user.invalid", status: "success")),
            .toolUse(ToolUse(toolUseId: "auto2", name: "browser_use", input: #"{"action":"get_state"}"#, description: nil, thoughtSignature: nil))
        ]
        let raw = RawMessage(id: UUID().uuidString, sessionId: "fixture", role: .assistant, parts: parts, createdAt: Date(), tokenUsage: nil, reasoningContent: nil)
        let restored = try JSONDecoder().decode(RawMessage.self, from: JSONEncoder().encode(raw))
        let message = restored.toChatMessage(mediaResolver: { _ in FileManager.default.temporaryDirectory })
        XCTAssertEqual(message.blocks.count, 3)
        if case .browserTool(let operation) = message.blocks[1].kind { XCTAssertEqual(operation, "browser_read") }
        else { XCTFail("User browser history was restored as a different tool kind") }
        XCTAssertEqual(message.blocks[1].browserURL, "https://user.invalid")
        XCTAssertEqual(message.blocks[2].browserURL, "https://automation.invalid")
    }
    func testProfileSwitchCancelsInlineBrowserApproval() async throws {
        let (browser, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = NativeBrowserSession(browser: browser)
        browser.agent = bridge; ZEUSNativeAgentBridge.shared.bind(bridge)
        let permissions = ZeusToolPermissions.shared, previous = permissions.mode
        permissions.mode = .askAll; defer { permissions.mode = previous }
        let id = UUID()
        let call = Task { try await permissions.authorize(tool: "zeus_browser", args: ["operation": "browser_tabs"], sessionID: "test", blockID: id) }
        while permissions.requests[id] == nil { try await Task.sleep(for: .milliseconds(10)) }
        let second = browser.profiles.add(name: "Second", accent: "white", isPrivate: false)
        await browser.switchProfile(to: second)
        XCTAssertNil(permissions.requests[id])
        do { try await call.value; XCTFail("Old approval must be cancelled immediately") } catch {}
    }
    func testPermissionModesAndConcurrentRequestsStayIndependent() async throws {
        let permissions = ZeusToolPermissions.shared, previous = permissions.mode
        defer { permissions.mode = previous }
        permissions.mode = .consequential
        try await permissions.authorize(tool: "zeus_browser", args: ["operation": "browser_read"], sessionID: "test", blockID: UUID())
        XCTAssertFalse(ZeusToolPermissions.isConsequential(tool: "zeus_browser", args: ["operation": "browser_settings", "action": "read"]))
        XCTAssertTrue(ZeusToolPermissions.isConsequential(tool: "zeus_browser", args: ["operation": "browser_settings", "action": "set"]))
        XCTAssertTrue(ZeusToolPermissions.isConsequential(tool: "shell_execute", args: ["command": "rm file"]))
        XCTAssertFalse(ZeusToolPermissions.isConsequential(tool: "memory_get", args: [:]))
        XCTAssertFalse(ZeusToolPermissions.isConsequential(tool: "browser_use", args: ["action": "get_readable"]))
        XCTAssertTrue(ZeusToolPermissions.isConsequential(tool: "browser_use", args: ["action": "get_cookies"]))
        permissions.mode = .askAll
        let first = UUID(), second = UUID()
        let a = Task { try await permissions.authorize(tool: "file_read", args: [:], sessionID: "test", blockID: first) }
        let b = Task { try await permissions.authorize(tool: "file_read", args: [:], sessionID: "test", blockID: second) }
        while permissions.requests.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        permissions.respond(first, allowed: false)
        XCTAssertNotNil(permissions.requests[second])
        permissions.respond(second, allowed: true)
        do { try await a.value; XCTFail("Denied call must not execute") } catch {}
        try await b.value
        permissions.mode = .unrestricted
        try await permissions.authorize(tool: "shell_execute", args: ["command": "true"], sessionID: "test", blockID: UUID())
        XCTAssertTrue(permissions.requests.isEmpty)
    }
    func testBrowserToolAcceptsFlatAndLegacyObjectsAndRejectsInvalidFields() throws {
        let open = try XCTUnwrap(ZEUSNativeAgentBridge.definitions.first { $0.name == "zeus_browser_open" })
        XCTAssertTrue(open.required.contains("url"))
        XCTAssertNil(open.parameters["operation"])
        XCTAssertNil(open.parameters["arguments"])
        XCTAssertNil(AIChatViewModel.preflightValidateToolCall(name: "zeus_browser_type", args: ["tab_id": UUID().uuidString, "element_id": "e1", "text": ""], tools: ZEUSNativeAgentBridge.definitions))
        let storage = try XCTUnwrap(ZEUSNativeAgentBridge.definitions.first { $0.name == "zeus_browser_storage" })
        XCTAssertEqual(storage.parameters["action"]?.enumValues, ["read", "set", "remove", "clear"])
        XCTAssertEqual(try ZEUSNativeAgentBridge.normalizedInput(["url": "https://example.com"], toolName: "zeus_browser_open").0, "browser_open")
        let flat = try ZEUSNativeAgentBridge.normalizedInput(["operation": "browser_open", "url": "https://example.com", "new_tab": "false"])
        XCTAssertEqual(flat.0, "browser_open")
        XCTAssertTrue(flat.1.contains("false"))
        let legacy = try ZEUSNativeAgentBridge.normalizedInput(["operation": "browser_open", "arguments": ["url": "https://example.com", "new_tab": false]])
        XCTAssertEqual(flat.1, legacy.1)
        XCTAssertThrowsError(try ZEUSNativeAgentBridge.normalizedInput(["operation": "browser_open"]))
        XCTAssertThrowsError(try ZEUSNativeAgentBridge.normalizedInput(["operation": "browser_read", "selector_typo": "a"]))
        XCTAssertThrowsError(try ZEUSNativeAgentBridge.normalizedInput(["operation": "browser_cookies", "action": "removeAll"]))
        XCTAssertThrowsError(try ZEUSNativeAgentBridge.normalizedInput(["operation": "browser_open", "url": "https://a.test", "arguments": ["url": "https://b.test"]]))
    }
    func testParallelBrowserCallsAreSerializedRatherThanRandomlyRejected() async throws {
        let (browser, root) = model(); defer { try? FileManager.default.removeItem(at: root) }
        let bridge = NativeBrowserSession(browser: browser)
        bridge.authorization = { _ in try? await Task.sleep(for: .milliseconds(50)); return true }
        async let first = bridge.execute(operation: "browser_tabs", arguments: "{}", sessionID: nil)
        async let second = bridge.execute(operation: "browser_tabs", arguments: "{}", sessionID: nil)
        let results = try await [first, second]
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.text.contains("tab_id=") })
    }
    func testSettingsToolsPersistRealSettingsAndValidateBeforeWriting() async throws {
        let (browser, root) = model(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await NativeBrowserControl.execute("browser_settings", args: ["action": "set", "key": "shieldsEnabled", "value": "false"], browser: browser)
        XCTAssertFalse(browser.data.settings.shieldsEnabled)
        XCTAssertFalse(browser.profiles.load(browser.profile).settings.shieldsEnabled)
        do { _ = try await NativeBrowserControl.execute("browser_settings", args: ["action": "set", "key": "textScale", "value": "99"], browser: browser); XCTFail("Invalid value accepted") } catch {}
        XCTAssertEqual(browser.data.settings.textScale, 1)
        let read = try await NativeBrowserControl.execute("browser_settings", args: ["action": "read"], browser: browser)
        XCTAssertTrue(read.contains("advanced.forceDarkWebPages"))
        _ = try await NativeBrowserControl.execute("browser_settings", args: ["action": "set", "key": "reading.backgroundHex", "value": "\"141414\""], browser: browser)
        XCTAssertEqual(browser.data.settings.reading?.backgroundHex, "141414")
        _ = try await NativeBrowserControl.execute("browser_settings", args: ["action": "set", "key": "reading.backgroundHex", "value": "null"], browser: browser)
        XCTAssertNil(browser.data.settings.reading?.backgroundHex)
        let help = try await NativeBrowserControl.execute("browser_help", args: [:], browser: browser)
        XCTAssertTrue(help.contains("assistantButton")); XCTAssertTrue(help.contains("twinHorizontal"))
        _ = try await NativeBrowserControl.execute("browser_profiles", args: ["action": "create", "name": "Agent created"], browser: browser)
        let target = try XCTUnwrap(browser.profiles.profiles.first { $0.name == "Agent created" })
        _ = try await NativeBrowserControl.execute("browser_profiles", args: ["action": "update", "profile_id": target.id.uuidString, "key": "name", "value": "\"Updated profile\""], browser: browser)
        XCTAssertEqual(browser.profiles.profile(target.id)?.name, "Updated profile")
    }
    func testOriginalAgentTransportStreamsLongUnicodeAnswerWithoutDroppingTheTail() async throws {
        let model = LLMModel(id: "fixture-native-stream", displayName: "Native stream fixture", provider: "openai")
        let transport = OpenAIProvider(apiKey: "local-fixture-only", model: model, customBaseURL: "http://127.0.0.1:8765/v1", appendV1Suffix: false)
        let provider = OpenAIAgentProvider(provider: transport)
        let stream = try await provider.streamAgentMessage(messages: [AgentMessage(role: .user, parts: [.text("Stream fixture")])], systemPrompt: nil, tools: [], maxTokens: 16000, thinkingLevel: .off)
        var text = "", deltas = 0
        for try await event in stream { if case .textDelta(let delta) = event { deltas += 1; text += delta } }
        XCTAssertGreaterThan(deltas, 6)
        XCTAssertGreaterThan(text.count, 20_000)
        XCTAssertTrue(text.contains("العربية"))
        XCTAssertTrue(text.hasSuffix("نهاية الرسالة NATIVE_STREAM_END"))
        XCTAssertTrue(text.contains("```swift"))
    }
    func testOriginalAgentTransportAccumulatesPartialBrowserToolArguments() async throws {
        let model = LLMModel(id: "fixture-native-tool", displayName: "Native tool fixture", provider: "openai")
        let provider = OpenAIAgentProvider(provider: OpenAIProvider(apiKey: "local-fixture-only", model: model, customBaseURL: "http://127.0.0.1:8765/v1", appendV1Suffix: false))
        let stream = try await provider.streamAgentMessage(messages: [AgentMessage(role: .user, parts: [.text("Inspect tabs")])], systemPrompt: nil, tools: [ZEUSNativeAgentBridge.definition], maxTokens: 1000, thinkingLevel: .off)
        var partials = 0, complete = false
        for try await event in stream {
            switch event {
            case .toolInputDelta(let name, _): XCTAssertEqual(name, "zeus_browser"); partials += 1
            case .toolCallComplete(let id, let name, let args, _):
                XCTAssertEqual(id, "native-tool-fixture"); XCTAssertEqual(name, "zeus_browser")
                XCTAssertEqual(args["operation"] as? String, "browser_tabs")
                XCTAssertEqual(args["arguments"] as? String, "{}")
                XCTAssertEqual(args["tool_title"] as? String, "قراءة التبويبات الفعلية")
                complete = true
            default: break
            }
        }
        XCTAssertGreaterThan(partials, 1)
        XCTAssertTrue(complete)
    }
    func testInspectorRunsAgainstRealDOMAndOriginStorage() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let loader = NativeInspectorFixture()
        try await loader.load("<main id='chapter' style='color:rgb(0,0,0)'>Real chapter text</main>", view: view)
        let dom = try await NativeBrowserInspector.execute("browser_dom", args: ["selector": "#chapter"], view: view)
        XCTAssertTrue(dom.contains("Real chapter text"))
        let evaluated = try await NativeBrowserInspector.execute("browser_evaluate", args: ["code": "document.querySelector('#chapter').textContent='Changed by real JavaScript'; return document.querySelector('#chapter').textContent"], view: view)
        XCTAssertTrue(evaluated.contains("Changed by real JavaScript"))
        let node = try await NativeBrowserInspector.execute("browser_evaluate", args: ["code": "return document.querySelector('#chapter')"], view: view)
        XCTAssertTrue(node.contains("MAIN"))
        let circular = try await NativeBrowserInspector.execute("browser_evaluate", args: ["code": "const a={n:123n};a.self=a;return a;"], view: view)
        XCTAssertTrue(circular.contains("Circular")); XCTAssertTrue(circular.contains("123"))
        do { _ = try await NativeBrowserInspector.execute("browser_evaluate", args: ["code": "throw Error('Fixture real failure')"], view: view); XCTFail("JS error must surface") } catch {}

        _ = try await NativeBrowserInspector.execute("browser_storage", args: ["area": "local", "action": "set", "key": "chapter", "value": "42"], view: view)
        let stored = try await NativeBrowserInspector.execute("browser_storage", args: ["area": "local", "action": "read", "key": "chapter"], view: view)
        XCTAssertTrue(stored.contains("42"))
        _ = try await NativeBrowserInspector.execute("browser_storage", args: ["area": "local", "action": "remove", "key": "chapter"], view: view)
        let empty = try await NativeBrowserInspector.execute("browser_storage", args: ["area": "local", "action": "read", "key": "chapter"], view: view)
        XCTAssertFalse(empty.contains("42"))
    }
    func testPageReadSuppliesTabIDAndOldElementIDsSurviveAnotherRead() async throws {
        var step = "load first document"
        do {
        let (browser, root) = model(); defer { try? FileManager.default.removeItem(at: root) }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let loader = NativeInspectorFixture()
        try await loader.load("<input id='name' aria-label='Name'><div contenteditable='true' aria-label='Message' style='width:200px;height:80px'></div><p>Real interaction fixture.</p>", view: view)
        let tab = try XCTUnwrap(browser.current); tab.url = "https://example.com"; tab.webView = view
        let session = NativeBrowserSession(browser: browser); session.authorization = { _ in true }
        step = "read first document"
        let first = try await session.execute(operation: "browser_read", arguments: "{}", sessionID: nil)
        let data = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(first.text.utf8)) as? [String: Any])
        XCTAssertEqual(data["tab_id"] as? String, tab.id.uuidString)
        let elements = try XCTUnwrap(data["elements"] as? [[String: Any]])
        let input = try XCTUnwrap(elements.first { $0["label"] as? String == "Name" }?["element_id"] as? String)
        let editor = try XCTUnwrap(elements.first { $0["label"] as? String == "Message" }?["element_id"] as? String)
        step = "read same document again"
        _ = try await session.execute(operation: "browser_read", arguments: "{}", sessionID: nil)
        func args(_ id: String, _ text: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["tab_id": tab.id.uuidString, "element_id": id, "text": text]), as: UTF8.self)
        }
        step = "type input using first-read ID"
        _ = try await session.execute(operation: "browser_type", arguments: args(input, "Alice"), sessionID: nil)
        step = "type contenteditable using first-read ID"
        _ = try await session.execute(operation: "browser_type", arguments: args(editor, "A real editable message"), sessionID: nil)
        step = "verify real DOM values"
        let actual = try await view.callAsyncJavaScript("return {name:document.querySelector('#name').value,message:document.querySelector('[contenteditable]').textContent}", arguments: [:], in: nil, contentWorld: .page) as? [String: String]
        XCTAssertEqual(actual?["name"], "Alice")
        XCTAssertEqual(actual?["message"], "A real editable message")
        step = "load replacement document"
        try await loader.load("<input id='replacement' value='unchanged'>", view: view)
        step = "reject previous-document ID"
        do { _ = try await session.execute(operation: "browser_type", arguments: args(input, "must not type"), sessionID: nil); XCTFail("Previous-document IDs must be rejected") } catch {}
        step = "verify replacement document was not edited"
        let unchanged = try await view.callAsyncJavaScript("return document.querySelector('#replacement').value", arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(unchanged, "unchanged")
        } catch {
            // XCTest's async wrapper can replace a thrown WebKit error with an
            // unhelpful InvalidTransition(deinit). Keep its actual operation,
            // domain/code and JavaScript details in the assertion/report.
            let detail = error as NSError
            XCTFail("Page interaction failed at \(step): \(detail.domain) \(detail.code) \(detail.userInfo)")
        }
    }
    func testInspectorCookiesIncludeHttpOnlyButStayWithinTheSelectedSite() async throws {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let loader = NativeInspectorFixture()
        try await loader.load("<main>Cookie fixture</main>", view: view)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: "fixture-session", .value: "fixture-only", HTTPCookiePropertyKey("HttpOnly"): "TRUE"]))
        let other = try XCTUnwrap(HTTPCookie(properties: [.domain: "unrelated.invalid", .path: "/", .name: "unrelated-session", .value: "must-not-leak"]))
        for item in [cookie, other] { await withCheckedContinuation { c in config.websiteDataStore.httpCookieStore.setCookie(item) { c.resume() } } }
        let result = try await NativeBrowserInspector.execute("browser_cookies", args: ["action": "list"], view: view)
        XCTAssertTrue(result.contains("fixture-only"))
        XCTAssertTrue(result.contains("\"httpOnly\":true"))
        XCTAssertFalse(result.contains("must-not-leak"))
        _ = try await NativeBrowserInspector.execute("browser_cookies", args: ["action": "delete", "name": "fixture-session"], view: view)
        let after = try await NativeBrowserInspector.execute("browser_cookies", args: ["action": "list"], view: view)
        XCTAssertFalse(after.contains("fixture-only"))
    }
    func testBackupReaderAcceptsValidBackupWithoutJSONExtensionAndRejectsInvalidFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("My browser.backup")
        var data = ProfileData()
        data.tabs = [SavedTab(title: "Restored chapter", url: "https://example.com/chapter")]
        try JSONEncoder().encode(ProfileBackup(name: "Source", data: data)).write(to: file)
        let backup = try await BackupFileReader.load(file)
        XCTAssertEqual(backup.data.tabs.first?.title, "Restored chapter")
        try Data("not a browser backup".utf8).write(to: file)
        do { _ = try await BackupFileReader.load(file); XCTFail("Invalid input must not be accepted") } catch {}
        try Data(repeating: 32, count: BackupFileReader.maximumBytes + 1).write(to: file)
        do { _ = try await BackupFileReader.load(file); XCTFail("Oversized input must not be loaded") } catch {
            XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
        }
    }
    func testBackupRestoresLiveTabOrderGroupsSelectionAndScrollAfterRelaunch() throws {
        let (browser, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        var source = ProfileData()
        let group = TabGroup(name: "Research", color: "FFD700", collapsed: true)
        source.tabs = [SavedTab(title: "One", url: "https://example.com/one", groupID: group.id),
                       SavedTab(title: "Two", url: "https://example.com/two")]
        source.selectedTabID = source.tabs[1].id
        source.tabGroups = [group]
        source.tabScrollOffsets = ["icab-strip": 420]
        source.history = [Visit(title: "Chapter", url: "https://example.com/chapter")]
        source.scripts = [BrowserScript(name: "Imported script", domain: "example.com", code: "void 0", isActive: true)]
        let merged = try ProfileBackup(name: "Source", data: source).merged(into: browser.data, importSettings: true, restoreTabs: true)
        try browser.importProfileData(merged, restoreOpenTabs: true)
        XCTAssertEqual(browser.tabs.map(\.id), source.tabs.map(\.id))
        XCTAssertEqual(browser.current?.id, source.selectedTabID)
        XCTAssertEqual(browser.data.tabGroups, source.tabGroups)
        XCTAssertEqual(browser.data.tabScrollOffsets, source.tabScrollOffsets)
        XCTAssertFalse(try XCTUnwrap(browser.data.scripts.first).isActive)
        let reloaded = BrowserModel(profiles: browser.profiles, useBackgroundDownloads: false)
        XCTAssertEqual(reloaded.tabs.map(\.id), source.tabs.map(\.id))
        XCTAssertEqual(reloaded.current?.id, source.selectedTabID)
        XCTAssertEqual(reloaded.data.history.first?.url, source.history.first?.url)
    }
    func testFailedBackupWritePreservesLiveBrowserSession() throws {
        let (browser, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalIDs = browser.tabs.map(\.id)
        let folder = browser.profiles.folder(for: browser.profile)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A directory in place of the data file reliably fails atomic writes.
        let blockedDataFile = folder.appendingPathComponent("browser.json")
        if FileManager.default.fileExists(atPath: blockedDataFile.path) {
            try FileManager.default.removeItem(at: blockedDataFile)
        }
        try FileManager.default.createDirectory(at: blockedDataFile, withIntermediateDirectories: true)
        var imported = ProfileData()
        imported.tabs = [SavedTab(title: "Must not replace live tab", url: "https://example.com")]
        XCTAssertThrowsError(try browser.importProfileData(imported, restoreOpenTabs: true))
        XCTAssertEqual(browser.tabs.map(\.id), originalIDs)
    }
    private func model() -> (BrowserModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (BrowserModel(profiles: ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads")), useBackgroundDownloads: false), root)
    }
    func testOriginalChatDatabaseAndProvidersRemainSharedAfterProfileSwitch() async throws {
        let (browser, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = await ChatStore.shared.createSession(modelId: "integration-reference", title: "Shared across browser profiles")
        let providers = ProviderConfigStore.shared
        let firstStore = browser.profiles.websiteDataStore(for: browser.profile)
        let second = browser.profiles.add(name: "Second", accent: "white", isPrivate: false)
        await browser.switchProfile(to: second)
        let sessions = await ChatStore.shared.listSessions()
        XCTAssertTrue(sessions.contains { $0.id == chat.id })
        XCTAssertTrue(providers === ProviderConfigStore.shared)
        XCTAssertFalse(firstStore === browser.profiles.websiteDataStore(for: browser.profile))
        await ChatStore.shared.deleteSession(chat.id)
    }
    func testRealTabToolUsesCurrentBrowserAndDoesNotCreateChatArchive() async throws {
        let (browser, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        browser.current?.title = "A real browser tab"
        let bridge = NativeBrowserSession(browser: browser)
        var requests = 0
        bridge.authorization = { _ in requests += 1; return true }
        let result = try await bridge.execute(operation: "browser_tabs", arguments: "{}", sessionID: nil)
        XCTAssertTrue(result.text.contains("A real browser tab"))
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: browser.profiles.folder(for: browser.profile).appendingPathComponent("OpenMinis/agent.json").path))
    }
    func testDenialPreventsNavigation() async throws {
        let (browser, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = NativeBrowserSession(browser: browser)
        bridge.authorization = { _ in false }
        do {
            _ = try await bridge.execute(operation: "browser_open", arguments: #"{"url":"https://example.com"}"#, sessionID: nil)
            XCTFail("Denied navigation must throw")
        } catch {}
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertTrue(browser.current?.isHome == true)
    }
    func testSwitchInvalidatesAnApprovalThatWasAlreadyPending() async throws {
        let (browser, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = NativeBrowserSession(browser: browser)
        browser.agent = bridge
        var answer: CheckedContinuation<Bool, Never>?
        let waiting = expectation(description: "Real tool awaiting authorization")
        bridge.authorization = { _ in
            await withCheckedContinuation { continuation in answer = continuation; waiting.fulfill() }
        }
        let call = Task {
            try await bridge.execute(operation: "browser_open", arguments: #"{"url":"https://example.com"}"#, sessionID: nil)
        }
        await fulfillment(of: [waiting], timeout: 5)
        let second = browser.profiles.add(name: "Second", accent: "white", isPrivate: false)
        await browser.switchProfile(to: second)
        answer?.resume(returning: true)
        do { _ = try await call.value; XCTFail("The old profile must not navigate after a switch") } catch {}
        XCTAssertEqual(browser.profile.id, second.id)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertTrue(browser.current?.isHome == true)
    }
}

@MainActor private final class NativeInspectorFixture: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var watchdog: Task<Void, Never>?
    func load(_ html: String, view: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            view.navigationDelegate = self
            watchdog = Task { @MainActor [weak self, weak view] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                view?.stopLoading(); self?.finish(URLError(.timedOut))
            }
            view.loadHTMLString(html, baseURL: URL(string: "https://example.com"))
        }
    }
    private func finish(_ error: Error? = nil) {
        watchdog?.cancel(); watchdog = nil
        let answer = continuation; continuation = nil
        if let error { answer?.resume(throwing: error) } else { answer?.resume() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
}
