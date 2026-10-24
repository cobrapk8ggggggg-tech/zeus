#if ZEUS_NATIVE_HOST
import SwiftUI
import WebKit

public struct NativeAssistantPresentation {
    public let fullScreen: Bool
    public let canResize: Bool
    public let close: () -> Void
    public let resize: () -> Void
}
public typealias NativeAssistantFactory = (NativeBrowserSession, NativeAssistantPresentation) -> AnyView
public typealias NativePreferencesFactory = () -> AnyView
private struct NativePreferencesKey: EnvironmentKey { static let defaultValue: NativePreferencesFactory? = nil }
extension EnvironmentValues {
    public var nativeAgentPreferences: NativePreferencesFactory? {
        get { self[NativePreferencesKey.self] }
        set { self[NativePreferencesKey.self] = newValue }
    }
}

/// Browser shell only. The app supplies the unmodified OpenMinis chat root.
@MainActor public struct NativeBrowserHostView: View {
    @StateObject private var holder = NativeBrowserHolder()
    private let assistant: NativeAssistantFactory
    private let preferences: NativePreferencesFactory?
    public init(preferences: NativePreferencesFactory? = nil, assistant: @escaping NativeAssistantFactory) { self.assistant = assistant; self.preferences = preferences }
    public var body: some View {
        BrowserRoot(model: holder.model, nativeAssistant: assistant)
            .environment(\.nativeAgentPreferences, preferences)
            .preferredColorScheme(holder.model.data.settings.theme?.light == true ? .light : .dark)
            .environment(\.layoutDirection, .rightToLeft)
    }
}
@MainActor private final class NativeBrowserHolder: ObservableObject {
    let model: BrowserModel
    private let delegate = BrowserAppDelegate()
    init() { model = BrowserFixtureFactory.make(); _ = delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil) }
}
@MainActor public enum NativeBrowserBackground {
    public static func handle(_ identifier: String, completion: @escaping () -> Void) -> Bool {
        guard identifier == DownloadService.sessionIdentifier else { return false }
        DownloadService.backgroundCompletion = completion
        return true
    }
}
public struct NativeBrowserApproval {
    public let operation: String
    public let profile: String
    public let profileName: String
    public let host: String
    public let details: String
    public let allowsPermanent: Bool
}
public struct NativeBrowserToolResult {
    public let text: String
    public let imagePath: String?
    public let pageURL: String?
}
private final class NativeToolCapture { var imageFilePath: String? }

/// Provides real browser actions; conversations, models and rendering live in
/// the original OpenMinis runtime, shared across all browser profiles.
@MainActor public final class NativeBrowserSession: ObservableObject {
    // Keep the WKContentWorld identity alive. A name alone is insufficient if
    // all Swift references disappear between async evaluations; snapshots must
    // remain in the same isolated JavaScript world for the document lifetime.
    private static let agentWorld = WKContentWorld.world(name: "ZEUSAgent")
    private weak var browser: BrowserModel?
    private let profileID: UUID
    private var invalidated = false
    private var executing = false
    private var approved = Set<String>()
    private var selectedID: UUID?
    private var authorizedHost: String?
    private var preferences: AgentPreferences = {
        var value = AgentPreferences()
        value.contextApproved = true; value.library = true; value.history = true
        return value
    }()
    public var authorization: ((NativeBrowserApproval) async -> Bool)?
    var interfaceAction: ((BrowserAction) async throws -> Void)?
    public var onInvalidated: (() -> Void)?
    public var profileIdentifier: String { profileID.uuidString }
    public var liveContext: String {
        guard !invalidated, let browser, browser.profile.id == profileID, !browser.requiresUnlock else { return "{\"available\":false}" }
        let current: [String: Any] = browser.current.map {
            ["id": $0.id.uuidString, "title": String($0.title.prefix(256)), "url": String($0.url.prefix(2048))]
        } ?? [:]
        let context: [String: Any] = ["available": true, "application": "ZEUS Browser", "agent": "Zeus",
            "location": "Integrated AI conversation panel", "profile_id": profileIdentifier,
            "profile_name": browser.profile.name, "profile_role": browser.profile.role.rawValue,
            "layout": (browser.data.settings.chromeLayout ?? .original).rawValue,
            "current_tab": current, "tab_count": browser.tabs.count,
            "user_browser_tool": "zeus_browser_*", "separate_automation_browser_tool": "browser_use"]
        return (try? NativeBrowserInspector.encode(context)) ?? "{}"
    }
    private let folder: URL
    init(browser: BrowserModel) {
        self.browser = browser; profileID = browser.profile.id
        folder = browser.profiles.folder(for: browser.profile).appendingPathComponent("OpenMinis")
    }
    public func cancel() { invalidated = true; interfaceAction = nil; onInvalidated?() }
    static var tools: [BrowserAgentTools.Tool] { BrowserAgentTools.tools.filter { !$0.name.hasPrefix("memory_") } + NativeBrowserInspector.tools + NativeBrowserControl.tools }
    public static func validatedArguments(operation: String, json: String) throws -> String {
        try NativeBrowserContract.arguments(operation: operation, json: json, tools: tools)
    }
    public static var toolSpecifications: [[String: Any]] {
        tools.map { ["name": $0.name, "description": $0.description, "properties": $0.properties, "required": $0.required] }
    }
    public static var operationNames: [String] { tools.map(\.name) }
    public static var parameterSchemas: [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for tool in tools { for (key, schema) in tool.properties { if let schema = schema as? [String: Any] { result[key] = schema } } }
        return result
    }
    public static var catalog: String {
        let tools = Self.tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description,
            "parameters": ["type": "object", "properties": $0.properties, "required": $0.required, "additionalProperties": false]]] as [String: Any] }
        return String(decoding: (try? JSONSerialization.data(withJSONObject: tools)) ?? Data(), as: UTF8.self)
    }
    public func execute(operation: String, arguments: String, sessionID: String?) async throws -> NativeBrowserToolResult {
        try validate()
        // The upstream agent dispatches parallel tool calls. Serialize operations on
        // the same WKWebView instead of rejecting otherwise valid calls.
        while executing { try await Task.sleep(for: .milliseconds(50)); try validate() }
        executing = true; defer { executing = false }
        let normalized = try NativeBrowserContract.arguments(operation: operation, json: arguments, tools: Self.tools)
        let call = AgentToolCall(name: operation, arguments: normalized)
        let destination = (call.object["url"] as? String).flatMap(URL.init(string:))?.host
        let globalOperations = ["browser_tabs", "browser_profile", "browser_library", "browser_debug", "browser_help", "browser_settings", "browser_profiles", "browser_interface"]
        let target = globalOperations.contains(operation) || operation == "browser_open" || operation == "browser_download" ? nil : try tab(call.object)
        let targetURL = target?.url
        let host = destination ?? targetURL.flatMap { URL(string: $0)?.host } ?? browser?.currentHost ?? ""
        let permanent = !["browser_click", "browser_type", "browser_close_tab", "browser_evaluate", "browser_cookies", "browser_storage", "browser_indexeddb", "browser_debug"].contains(operation) && browser?.profile.isPrivate == false
        let title = Self.tools.first { $0.name == operation }?.title ?? operation
        guard let authorization, await authorization(NativeBrowserApproval(operation: operation,
                profile: profileIdentifier, profileName: browser?.profile.name ?? "", host: host,
                details: title + "\n" + arguments, allowsPermanent: permanent)) else { throw AccountError.permission }
        try validate(); try Task.checkCancellation()
        if let target {
            guard browser?.tabs.contains(where: { $0 === target }) == true, target.url == targetURL,
                  call.object["tab_id"] != nil || browser?.current?.id == target.id else {
                throw AgentFailure.message("تغيّر التبويب أثناء الموافقة؛ اطلب سياقًا وموافقة جديدين.")
            }
        }
        // Navigation/read operations may legitimately follow HTTP redirects. Bind
        // sensitive origin inspection to the approved host, not ordinary reads.
        authorizedHost = ["browser_evaluate", "browser_cookies", "browser_storage", "browser_indexeddb", "browser_dom", "browser_network"].contains(operation) ? host.lowercased() : nil
        defer { authorizedHost = nil }
        approved.insert(call.id); defer { approved.remove(call.id) }
        selectedID = sessionID.flatMap(UUID.init(uuidString:))
        let capture = NativeToolCapture()
        let output = try await execute(call, block: capture)
        if operation != "browser_profiles" || call.object["action"] as? String != "switch" { try validate() }
        return NativeBrowserToolResult(text: output, imagePath: capture.imageFilePath, pageURL: browser?.current?.webView?.url?.absoluteString)
    }
    private func validate() throws {
        try Task.checkCancellation()
        guard !invalidated, let browser, browser.profile.id == profileID,
              !browser.requiresUnlock, !browser.switching, browser.profile.role != .kiosk else {
            throw AgentFailure.message("The browser profile changed or is locked; request a fresh browser context.")
        }
    }
    private func requireApproval(_ call: AgentToolCall, host: String, detail: String, always: Bool = true) async throws {
        try validate()
        guard approved.contains(call.id) else { throw AccountError.permission }
    }
    private func profileContext() throws -> String {
        guard preferences.profile,let browser else{throw AgentFailure.message("قراءة بيانات البروفايل غير مسموحة.")}
        return "Profile: \(browser.profile.name), role: \(browser.profile.role.title), layout: \((browser.data.settings.chromeLayout ?? .original).title), search: \(browser.data.settings.searchProvider.rawValue)."
    }
    private func tabsContext() throws -> String {
        guard preferences.tabs,let browser else{throw AgentFailure.message("قراءة التبويبات غير مسموحة.")}
        return browser.tabs.map{"tab_id=\($0.id.uuidString) title=\($0.title) url=\($0.url) active=\($0.id==browser.current?.id)"}.joined(separator:"\n")
    }
    private func tab(_ args:[String:Any]) throws -> BrowserTab {
        try validate();guard let browser else{throw CancellationError()}
        if let raw=args["tab_id"] as? String{
            guard preferences.tabs,let id=UUID(uuidString:raw),let tab=browser.tabs.first(where:{$0.id==id}) else{throw AgentFailure.message("التبويب غير موجود أو صلاحية قراءته معطّلة.")};return tab
        }
        guard let tab=browser.current else{throw AgentFailure.message("لا يوجد تبويب.")};return tab
    }
    private func webView(_ tab:BrowserTab) async throws -> WKWebView {
        guard let browser,tab.profileID==profileID,!tab.isHome,let view=await browser.prepare(tab) else{throw AgentFailure.message("الصفحة غير متاحة.")}
        if view.url==nil,let url=URL(string:tab.url){view.load(URLRequest(url:url))}
        let until=Date().addingTimeInterval(25)
        while view.isLoading,Date()<until{try await Task.sleep(for:.milliseconds(150));try validate()}
        try Task.checkCancellation();try validate()
        guard let host=view.url?.host, authorizedHost==nil || host.lowercased()==authorizedHost else {
            throw AgentFailure.message("انتقلت الصفحة إلى موقع آخر؛ اطلب موافقة جديدة قبل فحصه.")
        }
        return view
    }
    func read(_ tab:BrowserTab,full:Bool) async throws -> String {
        guard preferences.currentPage else{throw AgentFailure.message("قراءة نص الصفحات معطّلة.")}
        let view=try await webView(tab)
        let result=try await view.callAsyncJavaScript(Self.readScript,arguments:["full":full],in:nil,contentWorld:Self.agentWorld)
        var context = result as? [String: Any] ?? [:]
        context["tab_id"] = tab.id.uuidString
        context["profile_id"] = profileIdentifier
        if let popup = browser?.pendingPopup?.url?.absoluteString { context["pending_popup_url"] = popup }
        return String(decoding: try JSONSerialization.data(withJSONObject: context), as: UTF8.self)
    }
    private func execute(_ call:AgentToolCall,block:NativeToolCapture) async throws -> String {
        try validate();guard let browser else{throw CancellationError()}
        guard Self.tools.contains(where:{$0.name==call.name}),call.arguments.utf8.count<100_000 else{throw AgentFailure.message("أداة غير معروفة أو مدخلات أكبر من الحد.")}
        guard let decoded = try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)), decoded is [String: Any] else { throw AgentFailure.message("مدخلات الأداة ليست JSON صالحًا.") }
        let args=call.object
        switch call.name{
        case "browser_interface":
            guard let name = args["action"] as? String, let action = BrowserAction(rawValue: name), action != .assistant,
                  let interfaceAction else { throw AgentFailure.message("واجهة المتصفح غير متاحة لهذا السياق.") }
            if action == .settings, browser.profile.account?.allowSettings == false { throw AccountError.permission }
            if action == .console, browser.profile.account?.allowDeveloperTools == false { throw AccountError.permission }
            try await interfaceAction(action)
            return "Invoked native ZEUS button: \(action.title). Its normal UI flow has started; asynchronous extraction, printing or sharing may still require user interaction."
        case "browser_help", "browser_settings", "browser_profiles":
            return try await NativeBrowserControl.execute(call.name, args: args, browser: browser)
        case "browser_debug":
            guard browser.profile.account?.allowDeveloperTools != false, let enabled = args["enabled"] as? Bool else { throw AccountError.permission }
            browser.data.settings.developerTools = enabled; browser.applySettings()
            return try NativeBrowserInspector.encode(["enabled": enabled, "reload": "Active page is being reloaded with the selected inspector/console configuration."])
        case "browser_console":
            guard browser.profile.account?.allowDeveloperTools != false else { throw AccountError.permission }
            let selected = try tab(args), entries = browser.console.filter { $0.tabID == selected.id }
            return try NativeBrowserInspector.encode(["captureEnabled": browser.data.settings.developerTools,
                "coverage": "Collected messages for this tab only, maximum 50 recent entries and 1000 characters per entry.",
                "tab_id": selected.id.uuidString, "totalEntries": entries.count,
                "entries": entries.suffix(50).map { ["kind": $0.kind, "text": String($0.text.prefix(1000)), "truncated": $0.text.count > 1000, "date": $0.date.timeIntervalSince1970] as [String: Any] }])
        case "browser_dom", "browser_evaluate", "browser_cookies", "browser_storage", "browser_indexeddb", "browser_network":
            guard browser.profile.account?.allowDeveloperTools != false else { throw AccountError.permission }
            let view = try await webView(tab(args))
            return try await NativeBrowserInspector.execute(call.name, args: args, view: view)
        case "browser_tabs":return try tabsContext()
        case "browser_profile":return try profileContext()
        case "browser_read":return try await read(tab(args),full:args["full_page"] as? Bool ?? false)
        case "browser_open","browser_download":
            guard let raw=args["url"] as? String,let url=URL(string:raw),BrowserURL.isWeb(url),url.user==nil,url.password==nil,browser.permits(url) else{throw AgentFailure.message("الرابط غير صالح أو غير مسموح لهذا البروفايل.")}
            if call.name=="browser_download",browser.profile.account?.allowDownloads==false{throw AccountError.permission}
            try await requireApproval(call,host:url.host ?? "",detail:url.absoluteString)
            if call.name=="browser_download"{await browser.downloads.start(url:url,profile:browser.profile,referrer:browser.webView?.url,webView:browser.webView);return "Handed URL to native download manager. Check Downloads for progress."}
            let destination: BrowserTab
            if args["new_tab"] as? Bool != false {
                guard let created = browser.newTab(foreground: true) else { throw AgentFailure.message("تعذر إنشاء تبويب جديد.") }; destination = created
            } else { guard let current = browser.current else { throw CancellationError() }; destination = current }
            destination.url = url.absoluteString; destination.title = url.host ?? "صفحة جديدة"; destination.error = nil; browser.address = destination.url
            guard let view = await browser.prepare(destination) else { throw AgentFailure.message("تعذر تجهيز الصفحة.") }
            view.load(URLRequest(url: url)); browser.changed(); browser.persist()
            _ = try await webView(destination)
            if preferences.currentPage { return try await read(destination, full: false) }
            return "Opened tab_id=\(destination.id.uuidString), URL=\(view.url?.absoluteString ?? destination.url). Page content permission is disabled."
        case "browser_select_tab","browser_close_tab":
            let selected=try tab(args)
            try await requireApproval(call,host:URL(string:selected.url)?.host ?? "tabs",detail:selected.title+"\n"+selected.url,always:call.name=="browser_select_tab")
            if call.name=="browser_close_tab"{browser.closeTab(selected);return "Closed tab \(selected.id)."}
            browser.selectTab(selected);return "Activated tab \(selected.id)."
        case "browser_click","browser_type":
            let selected=try tab(args),view=try await webView(selected)
            guard let element=args["element_id"] as? String else{throw AgentFailure.message("لم يُحدد عنصر.")}
            let metadata=try await view.callAsyncJavaScript("const s=window.__zeusAgentSnapshot;const e=s?.elements?.get(id);if(!e||!e.isConnected||s.url!==location.href)throw Error('Stale element. Read page again.');return {tag:e.tagName,type:e.type||'',name:(e.innerText||e.getAttribute('aria-label')||'').slice(0,200),href:e.href||''}",arguments:["id":element],in:nil,contentWorld:Self.agentWorld) as? [String:Any] ?? [:]
            let detail="\(selected.title)\n\(metadata["name"] as? String ?? element)"+(call.name=="browser_type" ? "\n"+String((args["text"] as? String ?? "").prefix(1000)):"")
            try await requireApproval(call,host:URL(string:selected.url)?.host ?? "",detail:detail,always:false)
            let action=call.name=="browser_type" ? "type":"click"
            _=try await view.callAsyncJavaScript(Self.interactScript,arguments:["id":element,"action":action,"text":args["text"] as? String ?? ""],in:nil,contentWorld:Self.agentWorld)
            try await Task.sleep(for:.milliseconds(350));return try await read(selected,full:false)
        case "browser_scroll":
            let selected=try tab(args),view=try await webView(selected),pixels=max(-5000,min(5000,args["pixels"] as? Double ?? 700))
            _=try await view.callAsyncJavaScript("window.scrollBy(0,pixels);return window.scrollY",arguments:["pixels":pixels],in:nil,contentWorld:.world(name:"ZEUSAgent"));return try await read(selected,full:false)
        case "browser_find":
            let view=try await webView(tab(args)),query=args["text"] as? String ?? ""
            let config=WKFindConfiguration();config.caseSensitive=false;config.wraps=true
            let found=await withCheckedContinuation{c in view.find(query,configuration:config){c.resume(returning:$0.matchFound)}}
            return found ? "Found matching text in page.":"No matching text."
        case "browser_navigation":
            let selected=try tab(args),view=try await webView(selected),action=args["action"] as? String ?? ""
            try await requireApproval(call,host:URL(string:selected.url)?.host ?? "",detail:action+"\n"+selected.url)
            if action=="back"{view.goBack()}else if action=="forward"{view.goForward()}else if action=="reload"{view.reload()}else{throw AgentFailure.message("أمر تنقل غير صالح.")}
            return try await read(selected,full:false)
        case "browser_screenshot":
            guard preferences.currentPage else{throw AccountError.permission}
            let selected=try tab(args),view=try await webView(selected)
            guard view.window != nil,view.bounds.width>0 else{throw AgentFailure.message("لقطة الشاشة تتطلب ظهور التبويب أولًا.")}
            let image=try await view.takeSnapshot(configuration:nil)
            guard let data=image.jpegData(compressionQuality:0.9) else{throw AgentFailure.message("تعذر التقاط الصفحة.")}
            let path=folder.appendingPathComponent(selectedID?.uuidString ?? "temporary").appendingPathComponent("screenshots").appendingPathComponent(UUID().uuidString+".jpg")
            try BrowserDisk.ensure(path.deletingLastPathComponent());try data.write(to:path,options:[.atomic,.completeFileProtection]);block.imageFilePath=path.path
            return "Captured current visible viewport, \(image.size.width)x\(image.size.height)."
        case "browser_library":
            let query=args["query"] as? String ?? "";var values:[String]=[]
            if preferences.library{values+=browser.data.bookmarks.filter{query.isEmpty||($0.title+$0.url).localizedCaseInsensitiveContains(query)}.prefix(60).map{"Bookmark: \($0.title) \($0.url)"}}
            if preferences.history{values+=browser.data.history.filter{query.isEmpty||($0.title+$0.url).localizedCaseInsensitiveContains(query)}.prefix(60).map{"Visit: \($0.title) \($0.url)"}}
            guard preferences.library||preferences.history else{throw AccountError.permission};return values.joined(separator:"\n")
        case "browser_bookmark":
            guard browser.profile.role != .guest, browser.profile.role != .kiosk, let current = browser.current, !current.isHome else { throw AccountError.permission }
            try await requireApproval(call,host:browser.currentHost,detail:current.title);browser.bookmarkCurrent()
            guard browser.data.bookmarks.contains(where: { $0.url == current.url }) else { throw AgentFailure.message("لم يُحفظ الموقع في المفضلة.") }
            return "Verified bookmark saved for \(current.url)."
        default:throw AgentFailure.message("الأداة غير متاحة.")
        }
    }
    static let readScript = #"""
    const root=document.body||document.documentElement,out=[];let size=0;
    const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);
    while(walker.nextNode()&&size<90000){const p=walker.currentNode.parentElement;if(!p||p.closest('script,style,noscript,input,textarea,select,[contenteditable=true]'))continue;const s=getComputedStyle(p),r=p.getBoundingClientRect();if(s.display==='none'||s.visibility==='hidden'||s.opacity==='0'||r.width===0||r.height===0||(!full&&(r.bottom<0||r.top>innerHeight*2)))continue;const t=(walker.currentNode.nodeValue||'').replace(/\s+/g,' ').trim();if(t){out.push(t);size+=t.length}}
    const previous=window.__zeusAgentSnapshot;const elements=previous?.url===location.href?previous.elements:new Map(),controls=[];if(elements.size>2000)elements.clear();
    for(const e of document.querySelectorAll('a[href],button,input:not([type=hidden]),textarea,select,[role=button],[contenteditable=true],[role=textbox]')){if(controls.length>=120)break;const r=e.getBoundingClientRect(),s=getComputedStyle(e);if(!r.width||!r.height||r.bottom<0||r.top>innerHeight*2||s.visibility==='hidden')continue;const id='e'+String(window.__zeusAgentElementSequence=(window.__zeusAgentElementSequence||0)+1);elements.set(id,e);const field=['INPUT','TEXTAREA','SELECT'].includes(e.tagName)||e.isContentEditable;controls.push({element_id:id,tag:e.tagName,type:e.type||'',label:(e.getAttribute('aria-label')||(!field?e.innerText:'')||e.getAttribute('placeholder')||e.name||'').slice(0,180),href:e.tagName==='A'?e.href:null})}
    window.__zeusAgentSnapshot={url:location.href,elements};return {url:location.href,title:document.title,text:out.join('\n').slice(0,90000),elements:controls,scroll_y:scrollY,truncated:size>=90000,controls_limit:120};
    """#
    static let interactScript = #"""
    const s=window.__zeusAgentSnapshot,e=s?.elements?.get(id);if(!e||!e.isConnected||s.url!==location.href)throw Error('Stale element; read page again.');
    if(action==='type'){
      if((!['INPUT','TEXTAREA'].includes(e.tagName)&&!e.isContentEditable)||['password','hidden','file'].includes(e.type)||/(password|passcode|credit|card|cc-|otp|one-time|cvc|cvv)/i.test([e.name,e.id,e.autocomplete,e.getAttribute('aria-label')].join(' ')))throw Error('Sensitive or unsupported field.');
      e.focus({preventScroll:true});
      if(e.isContentEditable){
        const selection=getSelection(),range=document.createRange();range.selectNodeContents(e);selection.removeAllRanges();selection.addRange(range);
        if(!document.execCommand('insertText',false,text)){e.textContent=text;e.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:text}));}
      }else{const proto=e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;Object.getOwnPropertyDescriptor(proto,'value').set.call(e,text);e.dispatchEvent(new Event('input',{bubbles:true}));}
      e.dispatchEvent(new Event('change',{bubbles:true}));return true;
    }
    if(e.tagName==='A'&&e.href&&!/^https?:/i.test(e.href))throw Error('Only HTTP links are supported.');if(typeof e.click==='function')e.click();else e.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));return true;
    """#
}
typealias BrowserAgent = NativeBrowserSession
#endif

