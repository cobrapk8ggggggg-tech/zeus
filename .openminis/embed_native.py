"""Apply the declared host adapters to a separate pinned native checkout.

Apply only after the stock reference has been captured and verified, or in a
separate checkout. No chat/message/provider view is replaced, and no renderer,
transport or agent loop is reconstructed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from debug_fixture import prepare_fixture
from text_only import apply as apply_text_only


def replace(file, before, after, count=1):
    text = file.read_text()
    if text.count(before) != count:
        raise RuntimeError(f"Upstream adapter anchor changed: {file}: {before[:80]}")
    file.write_text(text.replace(before, after))


def embed(native, browser, report):
    lock = json.loads((browser / ".openminis/source.lock.json").read_text())
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=native, text=True).strip()
    if revision != lock["commit"]:
        raise RuntimeError("Wrong native source revision")
    source = native / "src/ios"
    app = source / "MinisApp.swift"
    if "private struct OpenMinisReferenceRoot: View" in app.read_text():
        app.write_bytes(subprocess.check_output(["git", "show", revision + ":src/ios/MinisApp.swift"], cwd=native))
    before = {str(f.relative_to(source)): hashlib.sha256(f.read_bytes()).hexdigest()
              for f in source.rglob("*.swift")}
    prepare_fixture(native)
    generated = browser / ".openminis/build"
    generated.mkdir(parents=True, exist_ok=True)

    # The application remains OpenMinis' original @main/AppDelegate/root setup;
    # its root content now embeds the browser with the original AI UI alongside.
    replace(source / "MinisApp.swift", "                ContentView()", "                ZEUSBrowserRootEntry()")
    for name in ("ZEUSNativeIntegration.swift", "ZeusToolPermissions.swift", "ZeusDefaultSkills.swift", "ZeusAgentSchemas.swift", "ZeusPatch.swift", "ZeusAgentHarness.swift", "ZeusConnections.swift"):
        shutil.copyfile(browser / ".openminis/Host" / name, source / name)
    # Reuse the exact native settings sheet from the browser's AI settings row.
    # Only its file-private visibility changes; its body is untouched.
    replace(source / "Views/ContentView.swift", "private struct SettingsSheet: View", "struct SettingsSheet: View")
    # A compiler boundary around the unchanged native geometry expression.
    # The original giant modifier chain hit the type-checker limit in the
    # embedded target. No view, modifier or state is replaced or reordered.
    replace(source / "Views/ContentView.swift",
            "    private static let pendingBackgroundNavigationTTL: TimeInterval = 90\n\n    var body: some View {\n        GeometryReader { geo in",
            "    private static let pendingBackgroundNavigationTTL: TimeInterval = 90\n\n    private var zeusNativeGeometry: some View {\n        GeometryReader { geo in")
    replace(source / "Views/ContentView.swift",
            "        }\n        .onReceive(\n            NotificationCenter.default.publisher(for: .sessionDidCreate),",
            "        }\n    }\n\n    var body: some View {\n        zeusNativeGeometry\n        .onReceive(\n            NotificationCenter.default.publisher(for: .sessionDidCreate),")
    replace(source / "Views/ContentView.swift", "    var body: some View {\n        zeusNativeGeometry",
            "    private var zeusNativeIncoming: some View {\n        zeusNativeGeometry")
    for anchor, name, previous in [
        ("        .fullScreenCover(isPresented: $showTerminal) {", "zeusNativePresentations", "zeusNativeIncoming"),
        ("        .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidFetchChanges)) { _ in", "zeusNativeSessionLifecycle", "zeusNativePresentations"),
        ("        .onChange(of: shareCoordinator.hasPendingShare) { hasPending in", "body", "zeusNativeSessionLifecycle")
    ]:
        declaration = "    var body: some View {" if name == "body" else "    private var " + name + ": some View {"
        replace(source / "Views/ContentView.swift", anchor, "    }\n\n" + declaration + "\n        " + previous + "\n" + anchor)

    definitions = source / "Agent/Chat/AIChatViewModel+ToolDefinitions.swift"
    replace(definitions, "        return tools", """        tools.append(contentsOf: ZEUSNativeAgentBridge.definitions)
        tools.append(contentsOf: ZeusAgentHarness.definitions)
        return tools.map { tool in
            var parameters = tool.parameters
            parameters["approval_reason"] = AgentToolParam(type: .string, description: "For consequential actions, explain what you intend to change and why in the user language. The app displays this on an inline approval card.")
            return AgentToolDefinition(name: tool.name, description: tool.description, parameters: parameters, required: tool.required, propertyOrdering: tool.propertyOrdering)
        }""")
    replace(definitions, 'description: "Control a web browser with up to 3 tabs.',
            'description: "This is the standalone Zeus automation browser, separate from the user\'s ZEUS tabs and browser profile. For the user\'s current page use zeus_browser_read; for existing tabs use zeus_browser_tabs; for user-browser navigation use zeus_browser_open. Other zeus_browser_* tools inspect its settings, cookies and storage. Control a web browser with up to 3 tabs.')
    execution = source / "Agent/Chat/AIChatViewModel+ConcurrentTools.swift"
    text = execution.read_text()
    anchor = '        case "browser_use":'
    parts = text.split(anchor)
    if len(parts) < 2:
        raise RuntimeError("Original browser tool dispatch was not found")
    adapter = '''        case let name where name == "zeus_browser" || zeusBrowserOperation(name) != nil:
            let result = try await ZEUSNativeAgentBridge.shared.execute(argsJson, sessionID: sessionId, toolName: name)
            toolOutput = result.text
            toolPageURL = result.pageURL
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].browserURL = result.pageURL
            }
            toolSuccess = true
            if let path = result.imagePath {
                toolImageData = try await Task.detached(priority: .utility) { try Data(contentsOf: URL(fileURLWithPath: path)) }.value
                toolImageMimeType = "image/jpeg"
                if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                    messages[msgIdx].blocks[blockIdx].imageFilePath = path
                }
            }

'''
    adapter += '''        case let name where ZeusAgentSchemas.names.contains(name):
            toolOutput = try await ZeusAgentHarness.shared.execute(name, args: toolArgs, callID: tu.id, vm: self)
            if let object = try? JSONSerialization.jsonObject(with: Data(toolOutput.utf8)) as? [String: Any], object["isError"] as? Bool == true { toolSuccess = false }
            else if let object = try? JSONSerialization.jsonObject(with: Data(toolOutput.utf8)) as? [String: Any], let code = object["exit_code"] as? Int { toolSuccess = code == 0 }
            else if name == "task_verify", let checks = try? JSONSerialization.jsonObject(with: Data(toolOutput.utf8)) as? [[String: Any]] { toolSuccess = checks.allSatisfy { $0["exitCode"] as? Int == 0 } }
            else { toolSuccess = true }

'''
    execution.write_text(parts[0] + adapter + anchor + parts[1] + ''.join('        case let name where name == "browser_use" || name == "zeus_browser" || zeusBrowserOperation(name) != nil:' + p for p in parts[2:]))

    replace(execution, "        do {\n        switch tu.name {", """        do {
        let toolArgs = try ZeusToolInput.normalize(name: tu.name, args: toolArgs, tools: tools)
        let argsJson = String(decoding: try JSONSerialization.data(withJSONObject: toolArgs), as: UTF8.self)
        if tu.name == "zeus_browser" || zeusBrowserOperation(tu.name) != nil { _ = try ZEUSNativeAgentBridge.normalizedInput(toolArgs, toolName: tu.name) }
        try await ZeusToolPermissions.shared.authorize(tool: tu.name, args: toolArgs, sessionID: sessionId,
            blockID: messages[msgIdx].blocks[blockIdx].id)
        switch tu.name {""")
    # Avoid a second, old modal after the common gate already authorized shell.
    text = execution.read_text()
    start = text.index("            // Offload permission check.")
    end = text.index("            // Delay execution.", start)
    execution.write_text(text[:start] + "            // Permissions are handled once by ZeusToolPermissions before dispatch.\n\n" + text[end:])
    # The original preflight incorrectly marked required Boolean/integer values
    # as damaged just because they were not strings. Preserve valid typed args.
    replace(execution,
        '                if !(raw is String) && !(raw is [Any]) && !(raw is [String: Any]) { return true }',
        '                if !(raw is String) && !(raw is NSNumber) && !(raw is [Any]) && !(raw is [String: Any]) { return true }')
    replace(source / "Agent/Chat/AIChatViewModel+ToolPreflight.swift", '        "file_edit": ["new_string"],',
        '        "file_edit": ["new_string"],\n        "zeus_browser_type": ["text"],')
    replace(execution, 'tu.name == "file_write" || tu.name == "file_edit" {',
        'tu.name == "file_write" || tu.name == "file_edit" || tu.name == "zeus_browser" || zeusBrowserOperation(tu.name) != nil || ZeusAgentSchemas.names.contains(tu.name) {')
    replace(execution, '            let modelMessage = """\n            Error: This call was NOT executed.',
        '            let modelMessage = (tu.name == "zeus_browser" || zeusBrowserOperation(tu.name) != nil) ? "Error: Browser call NOT executed: the provider truncated its arguments. Send a complete smaller call. Inspect the current page/state before retrying any mutation." : """\n            Error: This call was NOT executed.')
    replace(source / "Agent/Chat/AIChatViewModel.swift", "        var userSystemPrompt = baseSystemPrompt",
        '        var userSystemPrompt = baseSystemPrompt + "\\n\\n" + ZEUSNativeAgentBridge.context + ZeusAgentHarness.shared.context(session: sessionId)')
    replace(execution, "        let snapshotItem = ToolSnapshotItem(", "        ZeusAgentHarness.shared.observe(session: sessionId, tool: tu.name, success: toolSuccess)\n        let snapshotItem = ToolSnapshotItem(")
    replace(source / "Agent/Chat/AIChatViewModel.swift", "    func cancel() {", "    func cancel() {\n        ZeusAgentHarness.shared.cancel(session: sessionId)")
    replace(source / "Agent/Chat/AIChatViewModel.swift", "    static let maxAgentTurns = 200", "    static var maxAgentTurns: Int { ZeusAgentHarness.maxTurns }")
    replace(source / "Agent/Chat/AIChatViewModel.swift", "            defer { turnCount += 1 }", '''            defer { turnCount += 1 }
            if let notice = ZeusAgentHarness.shared.budgetNotice(session: sessionId) {
                if msgIdx >= 0, msgIdx < messages.count { messages[msgIdx].error = notice }
                canResume = true; hitTurnLimit = false; break
            }''')
    replace(source / "Agent/Chat/AIChatViewModel.swift", "            let contextHistory = effectiveAgentHistory()", "            userSystemPrompt = ZeusAgentHarness.shared.refreshContext(userSystemPrompt, session: sessionId)\n            let contextHistory = effectiveAgentHistory()")
    replace(source / "Agent/Chat/AIChatViewModel.swift", "                userSystemPrompt = baseSystemPrompt", '                userSystemPrompt = baseSystemPrompt + "\\n\\n" + ZEUSNativeAgentBridge.context')
    file_tools = source / "Agent/Chat/AIChatViewModel+FileTools.swift"
    replace(file_tools, 'ISHExecutionCoordinator.shared.hostURL(for: linuxPath)', 'ISHExecutionCoordinator.shared.hostURL(for: linuxPath, sessionId: self.sessionId)')
    replace(file_tools, 'ISHExecutionCoordinator.shared.hostURL(for: path)', 'ISHExecutionCoordinator.shared.hostURL(for: path, sessionId: self.sessionId)')
    replace(source / "Agent/Chat/AIChatViewModel.swift", "                break\n            }\n\n            // Build assistant RawMessage now but defer DB write", '''                if !canResume, !Task.isCancelled, let reminder = ZeusAgentHarness.shared.continuation(session: sessionId) {
                    agentHistory.append(AgentMessage(role: .user, parts: [.text("<zeus_runtime_instruction source='application'>" + reminder + "</zeus_runtime_instruction>")]))
                    continue
                }
                if let notice = ZeusAgentHarness.shared.pausedNotice(session: sessionId) { messages[msgIdx].error = notice; canResume = true }
                break
            }

            // Build assistant RawMessage now but defer DB write''')
    openai = source / "Providers/OpenAI/OpenAIAgentProvider.swift"
    for method, responses in [("convertToolsChatCompletions", "false"), ("convertToolsResponsesAPI", "true")]:
        anchor = '    private func ' + method + '(_ tools: [AgentToolDefinition]) -> [[String: Any]] {\n        tools.map { tool in'
        replace(openai, anchor, anchor + '\n            if let native = ZeusAgentSchemas.openAI(tool.name, description: tool.description, responses: ' + responses + ') { return native }')
    replace(source / "Providers/Gemini/GeminiAgentProvider.swift", '                parameters: params\n', '                parameters: ZeusAgentSchemas.schema(tool.name).map(ZeusAgentSchemas.gemini) ?? params\n')
    replace(source / "Providers/Antigravity/AntigravityAgentProvider.swift", '                parameters: params\n', '                parameters: ZeusAgentSchemas.schema(tool.name).map(ZeusAgentSchemas.gemini) ?? params\n')
    replace(source / "Providers/Gemini/GeminiProvider.swift", '''        [
            "name": name,
            "description": description,
            "parameters": parameters,
        ]''', '''        if let schema = ZeusAgentSchemas.schema(name) {
            return ["name": name, "description": description, "parametersJsonSchema": schema]
        }
        return ["name": name, "description": description, "parameters": parameters]''')
    replace(source / "Providers/Anthropic/OAuthHTTPClient.swift", '        if let body = request.httpBody, !body.isEmpty { return }', '        if let body = request.httpBody, !body.isEmpty { ZeusAgentSchemas.patchAnthropic(request); return }')
    replace(source / "Providers/Anthropic/OAuthHTTPClient.swift", '        // Always set httpBody (even if empty) since the stream is now consumed\n        request.httpBody = data\n', '        // Always set httpBody (even if empty) since the stream is now consumed\n        request.httpBody = data\n        ZeusAgentSchemas.patchAnthropic(request)\n')
    oauth = source / "Agent/Session/MCPOAuthController.swift"
    replace(oauth, '    var scopes: String?\n', '    var scopes: String?\n    var prompt: String?\n    var zeusResource: String?\n')
    replace(oauth, '        canonicalResourceURI(MCPStore.shared.servers.first(where: { $0.id == server })?.url)', '''        let config = MCPStore.shared.servers.first(where: { $0.id == server })
        if let resource = config?.oauth?.zeusResource, let url = URL(string: resource), url.scheme == "https", url.host != nil, url.fragment == nil { return resource }
        return canonicalResourceURI(config?.url)''')
    replace(oauth, 'URLQueryItem(name: "prompt", value: "consent")', 'URLQueryItem(name: "prompt", value: oauth.prompt ?? "consent")')
    replace(oauth, '        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")', '        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")\n        req.setValue("application/json", forHTTPHeaderField: "Accept")')
    replace(oauth, '    // MARK: - Helpers\n', '''    // Native HTTP integrations share the original Keychain and OAuth flow.
    static func refreshAccessTokenForZeus(server: String, oauth: MCPOAuthConfig) async throws -> String {
        guard var stored = tokens(server: server) else { throw OAuthError.badConfig("أعد ربط الحساب عبر OAuth.") }
        if stored.expiresAt == 0 || stored.expiresAt > Date().timeIntervalSince1970 + 60 { return stored.accessToken }
        guard let refresh = stored.refreshToken, let url = URL(string: oauth.tokenEndpoint), url.scheme == "https" else { throw OAuthError.badConfig("انتهى التفويض؛ أعد ربط الحساب.") }
        var form = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": oauth.clientId]
        if let secret = clientSecret(server: server), !secret.isEmpty { form["client_secret"] = secret }
        if let resource = resourceURI(server: server) { form["resource"] = resource }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form.map { "\\($0.key)=\\(formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let access = object["access_token"] as? String else { throw OAuthError.exchangeFailed("تعذر تجديد الحساب؛ أعد تسجيل الدخول.") }
        stored.accessToken = access
        stored.refreshToken = object["refresh_token"] as? String ?? stored.refreshToken
        stored.expiresAt = Date().timeIntervalSince1970 + ((object["expires_in"] as? NSNumber)?.doubleValue ?? 3600)
        keychainSet(try JSONEncoder().encode(stored), account: "\\(server)#tokens")
        materializeBridge(server: server, oauth: oauth, tokens: stored)
        return access
    }

    // MARK: - Helpers
''')
    # The card is inserted into the ORIGINAL self-sizing tool cell. The original
    # transcript/composer/Markdown remain unchanged; only this extension is new.
    list_file = source / "Agent/MessageList/CollectionViewMessageListV3.swift"
    replace(list_file, "    var body: some View {\n        AssistantBlockView(",
        "    var body: some View {\n        VStack(alignment: .leading, spacing: 8) {\n        AssistantBlockView(")
    replace(list_file, "            detailBlock: $bridge.detailBlock\n        )\n        .frame(maxWidth:",
        "            detailBlock: $bridge.detailBlock\n        )\n        ZeusInlineApprovalCard(blockID: block.id)\n        }\n        .frame(maxWidth:")
    replace(list_file, "            NotificationCenter.default.publisher(for: .messageListNeedsResnapshot)", """            NotificationCenter.default.publisher(for: .zeusApprovalChanged)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] notification in
                    guard let self, let blockID = notification.object as? UUID,
                          let ds = self.dataSource, let cv = self.viewController?.collectionView,
                          let layout = self.viewController?.messageListLayout else { return }
                    var snapshot = ds.snapshot()
                    for (index, item) in snapshot.itemIdentifiers.enumerated() {
                        if case .assistantBlock(_, let id) = item, id == blockID {
                            (cv.cellForItem(at: IndexPath(item: index, section: 0)) as? SelfSizingCell)?.clearCachedHeight()
                            layout.invalidateHeight(at: index)
                            snapshot.reconfigureItems([item])
                            ds.apply(snapshot, animatingDifferences: false)
                            layout.invalidateLayout()
                            break
                        }
                    }
                }.store(in: &subscriptions)
            NotificationCenter.default.publisher(for: .messageListNeedsResnapshot)""")
    replace(source / "Views/Chat/AIChatView.swift", "        .offloadPermissionDialog()", "        // Zeus approvals render inline in the original tool cells.")
    replace(source / "Views/Settings/OffloadPermissionSettingsView.swift", '        List {\n            Section("Background")',
        '        List {\n            ZeusPermissionSettingsSection()\n            Section("Background")')
    replace(source / "Views/Settings/OffloadPermissionSettingsView.swift", '''            Section("Privacy") {
                ForEach(settingsCommands, id: \\.name) { cmd in
                    CommandPermissionRow(command: cmd)
                }
            }
''', "")
    replace(source / "Views/Settings/OffloadPermissionSettingsView.swift", "                    manager.setAllBypass()",
        "                    ZeusToolPermissions.shared.mode = .unrestricted\n                    manager.setAllBypass()")


    stream = source / "Agent/Chat/AIChatViewModel+SSEStream.swift"
    text = stream.read_text()
    if 'case "browser_use":' not in text:
        raise RuntimeError("Original browser card mapping was not found")
    text = text.replace('case "browser_use":', 'case let browserName where browserName == "browser_use" || browserName == "zeus_browser" || zeusBrowserOperation(browserName) != nil:')
    # Preserve the original card/preview renderer, supplying its native action
    # field from the added browser tool's operation field.
    text = text.replace('extractPartialStringValue("action", from: accumulated)',
                        '(zeusBrowserOperation(name) ?? extractPartialStringValue(name == "zeus_browser" ? "operation" : "action", from: accumulated))')
    text = text.replace('extractPartialStringValue("action", from: json)',
                        '(zeusBrowserOperation(name) ?? extractPartialStringValue(name == "zeus_browser" ? "operation" : "action", from: json))')
    text = text.replace('args["action"] as? String', '(zeusBrowserOperation(name) ?? args["action"] as? String ?? args["operation"] as? String)')
    text = text.replace('.browserTool(action: "")', '.browserTool(action: zeusBrowserOperation(name) ?? (name == "zeus_browser" ? "browser_pending" : ""))')
    text = text.replace('(name == "browser_use")\n                    ? extractPartialStringValue', '(name == "browser_use" || name == "zeus_browser" || zeusBrowserOperation(name) != nil)\n                    ? extractPartialStringValue')
    text = text.replace('} else if let mgr = browserTabPool.activeManager {', '} else if name == "browser_use", let mgr = browserTabPool.activeManager {')
    stream.write_text(text)

    detail = source / "Views/Chat/ToolLiveSheet.swift"
    replace(detail, 'if isLive, onBrowserTakeover != nil, case .browserTool = block.kind {',
        'if isLive, onBrowserTakeover != nil, case .browserTool = block.kind, !block.zeusIsUserBrowser {')
    replace(detail, '} else if case .browserTool = block.kind, browserPool != nil {',
        '} else if case .browserTool = block.kind, browserPool != nil, !block.zeusIsUserBrowser {')
    replace(detail, '            case .browserTool: browserContent',
        '            case .browserTool:\n                if block.zeusIsUserBrowser { browserTextResultContent(block.content) } else { browserContent }')
    replace(detail, '        // Inherit from preceding browser block\n',
        '        if block.zeusIsUserBrowser { return "" }\n        // Inherit from preceding browser block\n')
    replace(detail, '                let prev = toolBlocks[i]\n',
        '                let prev = toolBlocks[i]\n                if prev.zeusIsUserBrowser { continue }\n')
    replace(detail, '        guard let manager = browserPool?.activeManager else { return }',
        '        guard !block.zeusIsUserBrowser, let manager = browserPool?.activeManager else { return }', count=2)
    replace(detail, 'let script = dict["script"] as? String,',
        'let script = (dict["script"] as? String ?? dict["code"] as? String),')
    replace(source / "Views/Chat/AssistantBlockView.swift", 'case .browserTool:   toolName = "browser_use"',
        'case .browserTool:   toolName = block.zeusIsUserBrowser ? "zeus_browser" : "browser_use"')

    # Existing DEBUG RPC only, restricted to explicit isolated fixture launches.
    # These cases are compiled out of Release together with the upstream server.
    replace(source / "Debug/DebugJSONRPC.swift", '        case "rpc.discover":', '''        case "zeus.fixture.permission":
            guard CommandLine.arguments.contains("--zeus-native-fixture"), let raw = params["mode"] as? String, let mode = ZeusPermissionMode(rawValue: raw) else { throw RPCError(code: -32602, message: "Isolated fixture mode required") }
            return await MainActor.run { ZeusToolPermissions.shared.mode = mode; return ["mode": raw] }
        case "zeus.fixture.task":
            guard CommandLine.arguments.contains("--zeus-native-fixture"), let session = params["sessionId"] as? String else { throw RPCError(code: -32602, message: "Isolated fixture and session required") }
            return await MainActor.run { ZeusAgentHarness.shared.context(session: session) }
        case "zeus.fixture.approvals":
            guard CommandLine.arguments.contains("--zeus-native-fixture") else { throw RPCError(code: -32601, message: "Fixture launch required") }
            return await MainActor.run {
                ["requests": ZeusToolPermissions.shared.requests.values.map {
                    ["id": $0.id.uuidString, "tool": $0.tool, "title": $0.title, "explanation": $0.explanation]
                }]
            }
        case "zeus.fixture.approval.respond":
            guard CommandLine.arguments.contains("--zeus-native-fixture"),
                  let value = params["id"] as? String, let id = UUID(uuidString: value),
                  let allowed = params["allowed"] as? Bool else { throw RPCError(code: -32602, message: "Fixture launch and valid response required") }
            return await MainActor.run { ZeusToolPermissions.shared.respond(id, allowed: allowed); return ["responded": true] }
        case "zeus.fixture.settings":
            guard CommandLine.arguments.contains("--zeus-native-fixture") else { throw RPCError(code: -32601, message: "Fixture launch required") }
            return try await ZEUSNativeAgentBridge.shared.execute("{\\"operation\\":\\"browser_settings\\",\\"action\\":\\"read\\"}", sessionID: nil).text
        case "rpc.discover":''')

    # Preserve native browser tool kinds when the original database rebuilds
    # UI history after restart; automation and user-browser URLs stay separate.
    history = source / "Agent/Chat/ChatStore.swift"
    replace(history, '        var lastBrowserURL: String?', '        var lastBrowserURL: String?\n        var lastZeusBrowserURL: String?')
    replace(history, '                case "browser_use":\n                    let action = extractStringParam("action", from: tu.input)', '''                case let name where name == "zeus_browser" || zeusBrowserOperation(name) != nil:
                    let operation = zeusBrowserOperation(name) ?? extractStringParam("operation", from: tu.input)
                    kind = .browserTool(action: operation)
                    content = "ZEUS: \\(operation)"
                    let argURL = extractStringParam("url", from: tu.input)
                    if !argURL.isEmpty { lastZeusBrowserURL = argURL }
                case "browser_use":
                    let action = extractStringParam("action", from: tu.input)''')
    replace(history, '                    block.browserURL = lastBrowserURL',
        '                    block.browserURL = block.zeusIsUserBrowser ? lastZeusBrowserURL : lastBrowserURL')
    replace(history, '                        lastBrowserURL = pageURL',
        '                        if blocks[blockIdx].zeusIsUserBrowser { lastZeusBrowserURL = pageURL } else { lastBrowserURL = pageURL }')
    replace(history, '        case "browser_use":\n            let action = str("action") ?? "browse"',
        '        case let name where name == "browser_use" || name == "zeus_browser" || zeusBrowserOperation(name) != nil:\n            let action = zeusBrowserOperation(name) ?? str("operation") ?? str("action") ?? "browse"')
    replace(history, 'return cap("browser_use \\(action)")', 'return cap("\\(name) \\(action)")')

    # Reviewed localization/branding overrides, preserving original localization
    # keys, command names, URL schemes and database identifiers.
    replace(source / "Agent/Session/SoulStore.swift", 'case "name":  if !value.isEmpty { meta.name = value }',
        'case "name":  if !value.isEmpty { meta.name = value.lowercased() == "minis" ? "Zeus" : value }')
    strings_file = source / "Localizable.xcstrings"
    strings = json.loads(strings_file.read_text())
    overrides = json.loads((browser / ".openminis/arabic-overrides.json").read_text())
    for key in overrides:
        strings["strings"].setdefault(key, {"localizations": {}})
    for key, entry in strings["strings"].items():
        localizations = entry.setdefault("localizations", {})
        for language, localization in localizations.items():
            unit = localization.get("stringUnit")
            if unit and isinstance(unit.get("value"), str):
                unit["value"] = unit["value"].replace("OpenMinis", "Zeus").replace("Minis", "Zeus")
        if "Minis" in key:
            localizations["en"] = {"stringUnit": {"state": "translated", "value": key.replace("OpenMinis", "Zeus").replace("Minis", "Zeus")}}
        if key in overrides:
            localizations["ar"] = {"stringUnit": {"state": "translated", "value": overrides[key]}}
    strings_file.write_text(json.dumps(strings, ensure_ascii=False, indent=2) + "\n")
    for file in source.rglob("*.swift"):
        if "MinisTests" in file.parts or "MinisUITests" in file.parts: continue
        original = file.read_text()
        branded = original.replace('"Minis"', '"Zeus"')
        # ToolLiveSheet returns dynamic strings, so explicitly localize these
        # labels; SwiftUI cannot localize an already-created String by itself.
        for tool in ("Shell", "Editor", "Browser", "Memory"):
            branded = branded.replace('return "Minis is using ' + tool + '"', 'return String(localized: "Minis is using ' + tool + '")')
        if branded != original: file.write_text(branded)

    # Separate identity from a separately installed OpenMinis. Conversations,
    # providers, skills and memory intentionally remain GLOBAL inside ZEUS.
    for file in source.rglob("*"):
        if file.suffix in (".swift", ".m", ".mm", ".h", ".entitlements"):
            text = file.read_text()
            changed = text.replace("group.com.openminis.app", "group.tools.zeus.openminis").replace("iCloud.com.openminis.app", "iCloud.tools.zeus.openminis")
            if text != changed:
                file.write_text(changed)

    original_app = (browser / "ZEUSNext/ZEUSNextApp.swift").read_text()
    (generated / "BrowserAppDelegate.swift").write_text(original_app[:original_app.index("@main struct")])
    start = original_app.index("    init() {", original_app.index("@main struct"))
    end = original_app.index("    var body: some Scene", start)
    factory = original_app[start:end].replace("    init() {", "    static func make() -> BrowserModel {")
    factory = factory.replace("_browser = StateObject(wrappedValue: model)", "return model").replace("_browser = StateObject(wrappedValue: BrowserModel())", "return BrowserModel()")
    (generated / "BrowserFixtureFactory.swift").write_text("import SwiftUI\n@MainActor enum BrowserFixtureFactory {\n" + factory + "}\n")

    apply_text_only(source, browser)
    replace(source / "Views/ContentView.swift", '                Section("Agent Runtime") {', '''                Section("وكيل ZEUS") {
                    NavigationLink { ZeusAgentRuntimeSettings() } label: { Label("أدوات الوكيل وتنفيذه", systemImage: "terminal") }
                    NavigationLink { ZeusPluginsSettingsView() } label: { Label("الإضافات", systemImage: "puzzlepiece.extension") }
                }
                Section("Agent Runtime") {''')
    changed = []
    for name, digest in before.items():
        file = source / name
        after = hashlib.sha256(file.read_bytes()).hexdigest()
        if digest != after:
            changed.append({"file": name, "before": digest, "after": after})
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({"sourceCommit": revision, "source": lock["repository"],
        "sharedAcrossProfiles": ["conversations", "providers", "models", "memory", "skills", "agentSettings"],
        "browserIsolation": "Website data stores remain per profile. Old tool contexts are invalidated on switch.",
        "modifiedNativeFiles": changed, "nativeSwiftFiles": len(before),
        "unchangedNativeSwiftFiles": len(before) - len(changed)}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("native", type=Path)
    parser.add_argument("browser", type=Path)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    embed(args.native.resolve(), args.browser.resolve(), args.report.resolve())
