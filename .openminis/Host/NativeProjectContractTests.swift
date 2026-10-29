import XCTest
import UIKit
import CryptoKit
@testable import Minis

@MainActor final class NativeProjectContractTests: XCTestCase {
    func testAndroidSchemasKeepCoordinatesTypedAndRejectLocalExecutionArguments() throws {
        let schema = try XCTUnwrap(ZeusAndroidTools.schema("android_ui"))
        XCTAssertNoThrow(try ZeusAgentSchemas.validate(["operation":"tap", "x":0.3, "y":0.4], schema:schema))
        XCTAssertThrowsError(try ZeusAgentSchemas.validate(["operation":"tap", "x":2, "y":0.4], schema:schema))
        XCTAssertThrowsError(try ZeusAgentSchemas.validate(["operation":"tap", "x":0.3, "y":0.4, "command":"uname"], schema:schema))
        XCTAssertTrue(ZeusToolPermissions.isConsequential(tool:"android_ui",args:["operation":"tap"]))
        XCTAssertFalse(ZeusToolPermissions.isConsequential(tool:"android_ui",args:["operation":"tree"]))
    }
    func testStorageBudgetDisablesDiskForPreviouslyCapturedSessionCache() async {
        let retained = URLCache.shared
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = retained
        retained.diskCapacity = 20 * 1024 * 1024
        await ZeusDeviceStorageBudget.prepare()
        XCTAssertTrue(URLCache.shared === retained)
        XCTAssertEqual(configuration.urlCache?.diskCapacity, 0)
        XCTAssertEqual(configuration.urlCache?.memoryCapacity, 2 * 1024 * 1024)
    }
    func testUploadedCopyIsRemovedOnlyAfterMatchingRemoteDigestAndOriginalIsPreserved() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let staged = root.appendingPathComponent("attachments")
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("original.txt"), copy = staged.appendingPathComponent("copy.txt")
        let bytes = Data("my cloud attachment".utf8)
        try bytes.write(to: original); try bytes.write(to: copy)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertFalse(try ZeusCloudFiles.discardVerifiedUpload(original, within: staged, bytes: Int64(bytes.count), digest: digest))
        XCTAssertFalse(try ZeusCloudFiles.discardVerifiedUpload(copy, within: staged, bytes: Int64(bytes.count), digest: String(repeating: "0", count: 64)))
        XCTAssertTrue(fm.fileExists(atPath: copy.path))
        XCTAssertTrue(try ZeusCloudFiles.discardVerifiedUpload(copy, within: staged, bytes: Int64(bytes.count), digest: digest))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        let link = staged.appendingPathComponent("link.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertFalse(try ZeusCloudFiles.discardVerifiedUpload(link, within: staged, bytes: Int64(bytes.count), digest: digest))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }
    func testIncompleteCloudReplayFailsWithoutWritingPartialMessages() async throws {
        let registered = await ChatStore.shared.createSession(modelId: "cloud-storage-fixture")
        let session = registered.id
        let before = await ChatStore.shared.loadMessages(sessionId: session)
        let runtime = ZeusCloudRuntime(transcriptRead: { path in
            if path.contains("/runs?") {
                return try JSONSerialization.data(withJSONObject: ["runs": [["id": "run", "native_user_id": "user", "native_assistant_id": "assistant", "status": "completed", "prompt": "must stay in memory", "seq": 2]]])
            }
            return Data("{\"events\":[]}".utf8)
        })
        do { _ = try await runtime.cloudTranscript(session: session); XCTFail("Incomplete replay must throw") }
        catch { }
        let after = await ChatStore.shared.loadMessages(sessionId: session)
        XCTAssertEqual(before.map(\.id), after.map(\.id))
    }
    func testCrashDiagnosticsRemainStableWhenRequestedConcurrently() async {
        let initial = CrashReporter.detectInjectedDylibs()
        let results = await withTaskGroup(of: [String].self, returning: [[String]].self) { group in
            for _ in 0..<16 { group.addTask { CrashReporter.detectInjectedDylibs() } }
            var values: [[String]] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.count, 16)
        XCTAssertTrue(results.allSatisfy { $0 == initial })
    }
    func testPristineLocalOSCanBeRemovedButEditsUnknownFilesAndSymlinksArePreserved() throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent) }
        let bytes = Data("bundled operating system".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let baseline = ["data/": "", "data/bin/": "", "data/bin/sh": digest]
        func tree(_ name: String) throws -> URL {
            let root = parent.appendingPathComponent(name)
            try fm.createDirectory(at: root.appendingPathComponent("data/bin"), withIntermediateDirectories: true)
            try bytes.write(to: root.appendingPathComponent("data/bin/sh"))
            try Data("aarch64".utf8).write(to: root.appendingPathComponent(".arch"))
            return root
        }
        let pristine = try tree("pristine")
        XCTAssertTrue(try ZeusPristineRootfs.remove(at: pristine, baseline: baseline, allowed: { false }))
        XCTAssertFalse(fm.fileExists(atPath: pristine.path))
        let overlay = try tree("overlay")
        let overlayData = Data("bundled app overlay".utf8)
        try overlayData.write(to: overlay.appendingPathComponent("data/bin/sh"))
        let overlayHash = SHA256.hash(data: overlayData).map { String(format: "%02x", $0) }.joined()
        let overlaidBaseline = baseline.merging(["@generated:data/bin/sh:" + overlayHash: overlayHash]) { old, _ in old }
        XCTAssertTrue(try ZeusPristineRootfs.remove(at: overlay, baseline: overlaidBaseline, allowed: { false }))
        let edited = try tree("edited")
        try Data("my edited shell".utf8).write(to: edited.appendingPathComponent("data/bin/sh"))
        XCTAssertFalse(try ZeusPristineRootfs.remove(at: edited, baseline: baseline, allowed: { false }))
        XCTAssertEqual(try Data(contentsOf: edited.appendingPathComponent("data/bin/sh")), Data("my edited shell".utf8))
        let unknown = try tree("unknown")
        try Data("my project".utf8).write(to: unknown.appendingPathComponent("data/project.txt"))
        XCTAssertFalse(try ZeusPristineRootfs.remove(at: unknown, baseline: baseline, allowed: { false }))
        let linked = try tree("linked")
        try fm.createSymbolicLink(at: linked.appendingPathComponent("data/outside"), withDestinationURL: unknown)
        XCTAssertFalse(try ZeusPristineRootfs.remove(at: linked, baseline: baseline, allowed: { false }))
        XCTAssertTrue(fm.fileExists(atPath: unknown.appendingPathComponent("data/project.txt").path))
        let managed = try tree("managed")
        try fm.createDirectory(at: managed.appendingPathComponent("data/var/minis"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: managed.appendingPathComponent("data/var/minis/shared"), withDestinationURL: unknown)
        let mountedBaseline = baseline.merging(["data/var/": ""]) { old, _ in old }
        XCTAssertTrue(try ZeusPristineRootfs.remove(at: managed, baseline: mountedBaseline, allowed: { false }))
        XCTAssertTrue(fm.fileExists(atPath: unknown.appendingPathComponent("data/project.txt").path))
        let local = try tree("local")
        XCTAssertFalse(try ZeusPristineRootfs.remove(at: local, baseline: baseline, allowed: { true }))
    }
    func testCloudToolEventsUseTheOriginalNativeCardKindsAndReadableTerminalOutput() {
        XCTAssertEqual(ZeusToolPresentation.kind("shell_execute", input: ["command": "uname -a"]), .shellTool(command: "uname -a"))
        XCTAssertEqual(ZeusToolPresentation.kind("file_edit", input: ["path": "main.py"]), .fileEditTool(path: "main.py"))
        XCTAssertEqual(ZeusToolPresentation.kind("memory_get"), .memoryTool(action: "memory_get"))
        XCTAssertEqual(ZeusToolPresentation.kind("browser_use", input: ["action": "get_state"]), .browserTool(action: "get_state"))
        XCTAssertEqual(ZeusToolPresentation.kind("read_image", input: ["path": "screen.png"]), .readImageTool(path: "screen.png"))
        XCTAssertEqual(ZeusToolPresentation.kind("integration_call"), .shellTool(command: "integration_call"))
        let result = #"{"id":"pty-1","output":"Linux\nfile.txt\n","exit_code":0,"next_offset":20}"#
        XCTAssertEqual(ZeusToolPresentation.output(result, name: "shell_execute"), "Linux\nfile.txt\n")
        XCTAssertEqual(ZeusToolPresentation.output(result, name: "file_read"), result, "Actual file JSON must remain unchanged")
    }
    func testCloudCacheRequiresMatchingContentAndRefusesEditedMessages() {
        let original: [ContentPart] = [.text("original cloud reply")]
        let edited: [ContentPart] = [.text("user edited reply")]
        let events: [[String: Any]] = [["kind": "text", "data": ["delta": "original cloud reply"]]]
        XCTAssertEqual(ZeusCloudCache.signature(original), ZeusCloudCache.eventsSignature(events))
        XCTAssertNotEqual(ZeusCloudCache.signature(edited), ZeusCloudCache.eventsSignature(events))
    }
    func testCloudWaitPlaceholderIsImmediateAndReusedWhenTheNetworkLoopStarts() async {
        let vm = AIChatViewModel()
        vm.messages = [ChatMessage(role: .user, content: "hello")]
        vm.isProcessing = true
        let beforeNetwork = ZeusCloudPresentation.begin(vm)
        XCTAssertTrue(beforeNetwork.isAwaitingModelResponse)
        XCTAssertEqual(ZeusCloudPresentation.begin(vm).id, beforeNetwork.id)
        let block = await ZeusCloudPresentation.append("first partial", vm: vm, message: beforeNetwork, block: nil)
        XCTAssertFalse(beforeNetwork.isAwaitingModelResponse)
        XCTAssertEqual(block.content, "first partial")
        XCTAssertEqual(vm.messages.count, 2)
        _ = await ZeusCloudPresentation.append(" then final", vm: vm, message: beforeNetwork, block: block, final: true)
        XCTAssertEqual(block.cachedMarkdown, MarkdownContent(prepareMarkdownForRender("first partial then final")))
        XCTAssertNotNil(block.cachedAttributedString)
        vm.isProcessing = false
    }
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
    func testRecreatingBrowserRootDoesNotResetLanguagePreferences() throws {
        let defaults = UserDefaults.standard
        _ = ZEUSBrowserRootEntry()
        let prior = defaults.string(forKey: "appLanguage")
        defer { defaults.set(prior, forKey: "appLanguage") }
        defaults.set("ar-test-sentinel", forKey: "appLanguage")
        _ = ZEUSBrowserRootEntry()
        _ = ZEUSBrowserRootEntry()
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "ar-test-sentinel", "Root reconstruction must not write AppStorage preferences and create a render loop")
    }
    func testPersistentPathsRemainAvailableWithoutAnAppGroupEntitlement() throws {
        let container = SharedContainerStore.containerURLForMainAppStorage
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.path))
        XCTAssertTrue(AIChatViewModel.minisAppGroupRoot.path.hasPrefix(container.path + "/"))
        XCTAssertTrue(AIChatViewModel.minisConfigRoot.path.hasPrefix(container.path + "/"))
        if !SharedContainerStore.hasAppGroupAccess {
            XCTAssertEqual(container.lastPathComponent, "MinisSharedContainer", "Keep the exact previously installed fallback to preserve user data")
        }
    }
    func testOfficialGeminiTransportCarriesNestedSchemasVisionAndNativeToolRepair() async throws {
        let provider = GeminiAgentProvider(provider: GeminiProvider(apiKey: "local-fixture-only", customBasePath: "http://127.0.0.1:8765/gemini-fixture"))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { ctx in
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }.pngData()!
        let messages = [
            AgentMessage(role: .user, parts: [.text("Inspect the actual attached design"), .imageData(data: image, mimeType: "image/png")]),
            AgentMessage(role: .assistant, parts: [.toolUse(id: "image-read", name: "read_image", input: ["path": "/var/minis/workspace/design.png"])]),
            AgentMessage(role: .user, parts: [.toolResult(id: "image-read", name: "read_image", content: "Image loaded", isError: false, imageData: image, imageMimeType: "image/png")]),
            AgentMessage(role: .user, parts: [.text(ZeusToolRecovery.marker + "propose_project_plan\nUse a real native function call.")])
        ]
        let tools = ZeusAgentHarness.definitions
        let stream = try await provider.streamAgentMessage(messages: messages, systemPrompt: "You are the embedded ZEUS agent.", tools: tools, maxTokens: 4000, thinkingLevel: .off)
        var complete = false
        for try await event in stream {
            if case .toolCallComplete(_, let name, let raw, _) = event {
                XCTAssertEqual(name, "propose_project_plan")
                let args = ZeusProjectContract.normalizedArguments(raw)
                try ZeusAgentSchemas.validate(args, schema: ZeusAgentSchemas.schema(name)!)
                try ZeusProjectContract.validate(ZeusProjectContract.decoded(args))
                complete = true
            }
        }
        XCTAssertTrue(complete, "Official Gemini must produce a parsed native call, not visible JSON")
    }
    func testNonVisionPromptsRequestRealVisionConfigurationInsteadOfRemovedMediaTools() throws {
        let model = LLMModel(id: "fixture-text-only", displayName: "Text only", provider: "openai")
        if let fragment = model.capabilityPromptFragment {
            XCTAssertFalse(fragment.contains("run ffmpeg"))
            XCTAssertTrue(fragment.contains("read_image"))
        }
        let placeholder = VisionGroupResolver.attachmentPlaceholder(linuxPath: "/var/minis/workspace/design.png")
        XCTAssertTrue(placeholder.contains("read_image"))
        XCTAssertFalse(placeholder.contains("shell_execute"))
        XCTAssertTrue(placeholder.contains("/var/minis/workspace/design.png"))
    }
    func testProviderTransportRepairsDoNotWeakenToolValidation() throws {
        let args = try ZeusToolInput.normalize(name: "exec_command", args: ["cmd": "printf ok", "yield_time_ms": "1000", "workdir": NSNull()], tools: [])
        XCTAssertEqual(args["yield_time_ms"] as? Int, 1000)
        XCTAssertNil(args["workdir"])
        let plan = try ZeusToolInput.normalize(name: "update_plan", args: ["plan": "[{\"step\":\"Inspect\",\"status\":\"pending\"}]"], tools: [])
        XCTAssertEqual((plan["plan"] as? [[String: Any]])?.first?["step"] as? String, "Inspect")
        XCTAssertThrowsError(try ZeusToolInput.normalize(name: "exec_command", args: ["cmd": "printf ok", "yield_time_ms": "1.5"], tools: []))
        XCTAssertThrowsError(try ZeusToolInput.normalize(name: "exec_command", args: ["cmd": NSNull()], tools: []))
        XCTAssertThrowsError(try ZeusToolInput.normalize(name: "exec_command", args: ["cmd": "printf ok", "unknown": true], tools: []))
    }
    func testBrowserToolsDoNotRequireProjectApprovalButKeepTheirOwnPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ZeusAgentHarness(root: root), session = UUID().uuidString
        runtime.registerUserRequest("Build an iOS application", session: session)
        XCTAssertNotNil(runtime.state(session).project)
        for name in ["zeus_browser", "browser_use", "zeus_browser_indexeddb"] {
            XCTAssertNoThrow(try runtime.projectGate(tool: name, args: ["operation": "browser_evaluate", "action": "evaluate"], session: session))
            XCTAssertTrue(ZeusToolPermissions.isConsequential(tool: name, args: ["operation": "browser_evaluate", "action": "evaluate"]))
        }
        XCTAssertThrowsError(try runtime.projectGate(tool: "file_write", args: ["path": "App.swift"], session: session))
    }
    func testStorageSelectiveDeletionAndSymlinkBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let known = root.appendingPathComponent("known-session"), orphan = root.appendingPathComponent("orphan-session")
        try FileManager.default.createDirectory(at: known, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("excluded".utf8).write(to: known.appendingPathComponent("data.txt"))
        try Data("visible".utf8).write(to: orphan.appendingPathComponent("data.txt"))
        let filtered = try ZeusStorageFiles.children(root, container: root.deletingLastPathComponent(), excluding: [known])
        XCTAssertEqual(filtered.map { $0.url.lastPathComponent }, ["orphan-session"])
        XCTAssertEqual(try ZeusStorageFiles.size(known, excluding: [known]), 0)
        XCTAssertGreaterThan(try ZeusStorageFiles.size(orphan, excluding: [known]), 0)
        let keep = root.appendingPathComponent("database"), remove = root.appendingPathComponent("cache")
        try Data("keep".utf8).write(to: keep); try Data("delete".utf8).write(to: remove)
        XCTAssertThrowsError(try ZeusStorageFiles.validateDeletion(root.appendingPathComponent("system"), container: root, protected: [], structuralRoots: [root.appendingPathComponent("system")]))
        XCTAssertNoThrow(try ZeusStorageFiles.validateDeletion(root.appendingPathComponent("system/cache"), container: root, protected: [], structuralRoots: [root.appendingPathComponent("system")]))
        XCTAssertThrowsError(try ZeusStorageFiles.delete(keep, container: root, protected: [keep]))
        try ZeusStorageFiles.delete(remove, container: root, protected: [keep])
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: remove.path))
        let secret = outside.appendingPathComponent("keep")
        try Data("outside".utf8).write(to: secret)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try ZeusStorageFiles.children(link, container: root))
        XCTAssertThrowsError(try ZeusStorageFiles.delete(link.appendingPathComponent("keep"), container: root, protected: []))
        try ZeusStorageFiles.delete(link, container: root, protected: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path))
    }
    func testSmallUtilityScriptsNeverBecomeMandatoryProjects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ZeusAgentHarness(root: root), vm = AIChatViewModel()
        vm.sessionId = UUID().uuidString
        let session = try XCTUnwrap(vm.sessionId)
        runtime.registerUserRequest("اكتب سكربت بايثون لقراءة ملف JSON، بدون اقتراح ابدأ تنفيذ", session: session)
        XCTAssertNil(runtime.state(session).project)
        let repair = runtime.recoverToolText(#"{"tool_calls":[{"name":"file_read","arguments":{"path":"inspect.py"}}]}"#, tools: ["file_read"], session: session)
        XCTAssertTrue(repair?.instruction?.hasPrefix(ZeusToolRecovery.marker + "file_read") == true)
        _ = try await runtime.projectEnvironment(vm: vm)
        XCTAssertNil(runtime.state(session).project, "Read-only environment discovery must not create a project")
        XCTAssertNoThrow(try runtime.projectGate(tool: "file_write", args: ["path": "inspect.py", "content": "print('ok')"], session: session))
        let result = try await runtime.execute("propose_project_plan", args: [:], callID: "utility-plan", vm: vm)
        XCTAssertTrue(result.contains("project_plan_required"))
        XCTAssertNil(runtime.state(session).project)
    }
    func testPlanBookkeepingRepairsEquivalentProviderShapesWithoutInventingChecks() throws {
        var raw = try proposal()
        raw["features"] = ["Stores the correct value"]
        raw["steps"] = [["step": "Implement project"], ["step": "Build and verify"]]
        raw.removeValue(forKey: "assumptions")
        raw["checks"] = [
            ["title": "Build", "type": "compile", "command": "test -s value.txt"],
            ["title": "Value", "type": "test", "feature_ids": ["Stores the correct value"], "command": "test value = value"]
        ]
        let args = ZeusProjectContract.normalizedArguments(raw)
        try ZeusAgentSchemas.validate(args, schema: ZeusAgentSchemas.schema("propose_project_plan")!)
        let decoded = try ZeusProjectContract.decoded(args)
        try ZeusProjectContract.validate(decoded)
        XCTAssertEqual(decoded.features.first?.id, "f1")
        XCTAssertEqual(decoded.checks.last?.covers, ["f1"])
        XCTAssertEqual(decoded.checks.count, 2)
        var invalid = try proposal()
        invalid["checks"] = [
            ["id": "build", "title": "Build", "kind": "build", "covers": [String](), "command": "test -s value.txt"],
            ["id": "test", "title": "Value", "kind": "functional", "covers": ["wrong-id"], "command": "test value = value"]
        ]
        XCTAssertThrowsError(try ZeusProjectContract.validate(ZeusProjectContract.decoded(["proposal": invalid]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("wrong-id"))
            XCTAssertTrue(error.localizedDescription.contains("value"))
            XCTAssertTrue(error.localizedDescription.contains("covers"))
        }
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
        XCTAssertNil(ZeusToolRecovery.candidate("A quoted API example: " + text, tools: tools))
        XCTAssertNil(ZeusToolRecovery.candidate("```json\n" + text + "\n```", tools: tools))
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
        XCTAssertFalse(ZeusProjectContract.isProjectRequest("اكتب سكربت استخراج توكن تطبيق من IndexedDB"))
        XCTAssertFalse(ZeusProjectContract.isProjectRequest("Write a script to inspect this app's IndexedDB"))
        XCTAssertTrue(ZeusProjectContract.isProjectRequest("Build an app with a script editor"))
        XCTAssertTrue(ZeusProjectContract.isProjectRequest("صمم تطبيق يستخدم IndexedDB"))
        XCTAssertTrue(ZeusProjectContract.isProjectRequest("طور لي البرنامج ليستخدم IndexedDB"))
        XCTAssertTrue(ZeusProjectContract.isProjectRequest("Write an application using IndexedDB"))
        XCTAssertFalse(ZeusProjectContract.isProjectRequest("اكتب سكربت لتحسين تطبيق موجود"))
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
        // This contract exercises local project discovery and its local skill assets.
        await ZeusDefaultSkills.shared.install(forceLocal: true)
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
        let inspectionArgs: [String: Any] = ["account_id": "first", "repository": "fixture-owner/project", "branch": "feature/project", "action": "tree", "limit": 1]
        let inspected = try await client.inspectProject(inspectionArgs)
        XCTAssertEqual(inspected["head_sha"] as? String, String(repeating: "1", count: 40))
        XCTAssertEqual(inspected["has_more"] as? Bool, true)
        XCTAssertEqual(inspected["next_offset"] as? Int, 1)
        XCTAssertEqual((inspected["entries"] as? [[String: Any]])?.first?["project_instruction"] as? Bool, true)
        var nextInspection = inspectionArgs; nextInspection["offset"] = 1; nextInspection["expected_head_sha"] = inspected["head_sha"]
        let next = try await client.inspectProject(nextInspection)
        XCTAssertEqual((next["entries"] as? [[String: Any]])?.first?["build_or_test_entry"] as? Bool, true)
        var subtree = inspectionArgs; subtree["tree_sha"] = String(repeating: "d", count: 40); subtree["path_prefix"] = "Sources"
        let folder = try await client.inspectProject(subtree)
        XCTAssertEqual((folder["entries"] as? [[String: Any]])?.first?["path"] as? String, "Sources/AGENTS.md")
        var difference = inspectionArgs; difference["action"] = "diff"; difference["base"] = "main"
        let changes = try await client.inspectProject(difference)
        XCTAssertEqual((changes["entries"] as? [[String: Any]])?.first?["patch_truncated"] as? Bool, true)
        XCTAssertTrue((changes["files_coverage"] as? String ?? "").contains("300"))
        let logs = try await client.request(accountID: "first", path: "/repos/fixture-owner/project/actions/jobs/123/logs")
        XCTAssertTrue((logs["data"] as? String ?? "").contains("App.swift:12: missing symbol"))
        XCTAssertEqual(logs["authorization_forwarded"] as? Bool, false)
        let longLog = try await client.request(accountID: "first", path: "/repos/fixture-owner/project/actions/jobs/124/logs")
        XCTAssertTrue((longLog["data"] as? String ?? "").contains("FINAL_COMPILER_ERROR"))
        XCTAssertTrue(try ZeusAgentHarness.json(longLog).count < AIChatViewModel.kMaxToolResultChars, "Keep the compiler error tail inside the original conversation result budget")
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
        var offset = 0, reconstructed = ""
        repeat {
            let chunk = try await client.readSource(accountID: "first", repository: "fixture-owner/project", branch: "feature/project", path: "App.swift", offset: offset, maxChars: 20)
            reconstructed += chunk["content"] as? String ?? ""
            offset = chunk["next_offset"] as? Int ?? source.count
        } while offset < source.count
        XCTAssertEqual(reconstructed, source, "Native source pagination must preserve Unicode and the complete file")
        let requests = try await client.object(accountID: "first", path: "/requests")
        let recorded = requests["requests"] as? [[String: Any]] ?? []
        let treeWrites = recorded.filter { ($0["path"] as? String)?.hasSuffix("/git/trees") == true }
        let postedFiles = (treeWrites.last?["body"] as? [String: Any])?["tree"] as? [[String: Any]]
        XCTAssertEqual(postedFiles?.count, 2, "Source files should be batched into one Git Trees request")
        XCTAssertEqual(postedFiles?.first?["content"] as? String, source)
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
        if case .toolResult(_, _, let content, let isError, let image, _, _, _, _) = outcome.resultPart {
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
