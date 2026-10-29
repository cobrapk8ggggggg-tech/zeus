import SwiftUI
import WebKit
import ZEUSBrowser

/// This feature has no RootfsManager/ISH dependency and never stages an APK in
/// the local agent workspace. The remote page uses a nonpersistent WebKit store.
enum ZeusAndroidTools {
    static let names: Set<String> = ["android_device", "android_ui", "android_screenshot", "android_network", "android_project"]
    static func schema(_ name: String) -> [String: Any]? {
        guard names.contains(name) else { return nil }
        var fields: [String: Any] = ["tool_title": ["type":"string"], "approval_reason":["type":"string"]]
        let operations: [String]
        switch name {
        case "android_device": operations = ["status", "stop"]
        case "android_ui": operations = ["tree", "tap", "swipe", "type", "key", "launch"]
        case "android_network": operations = ["start", "stop", "list", "read"]
        case "android_project": operations = ["list", "install", "analyze", "decode", "build", "job", "files", "read", "write"]
        default: operations = []
        }
        if !operations.isEmpty { fields["operation"] = ["type":"string", "enum":operations] }
        if name == "android_ui" {
            for field in ["x", "y", "x2", "y2"] { fields[field] = ["type":"number", "minimum":0, "maximum":1] }
            fields["text"] = ["type":"string", "maxLength":4000]
            fields["key"] = ["type":"string", "enum":["back", "home", "recent", "enter", "delete"]]
            fields["package"] = ["type":"string", "maxLength":200]
        }
        if name == "android_network" { fields["after"] = ["type":"integer", "minimum":0] }
        if name == "android_project" {
            for field in ["project", "job", "path", "expected_sha256"] { fields[field] = ["type":"string", "maxLength":500] }
            fields["content"] = ["type":"string", "maxLength":100000]
            fields["variant"] = ["type":"string", "enum":["original", "rebuilt"]]
            fields["tree"] = ["type":"string", "enum":["decoded", "sources"]]
        }
        return ["type":"object", "properties":fields, "required":operations.isEmpty ? [] : ["operation"], "additionalProperties":false]
    }
    @MainActor static var definitions: [AgentToolDefinition] {
        guard NativeCloudAccountAPI.ownerID != nil else { return [] }
        let descriptions = [
            "android_device":"Read/stop this conversation's remote Android session. The user must open Android Lab, start the device and explicitly hand control to you. Never install an emulator locally or infer that a device exists. Sessions have a hard time limit.",
            "android_ui":"Inspect the remote Android UI or tap/swipe/type/launch. Coordinates are normalized 0...1. Read the UI tree first; screenshot for visual inspection. Human takeover blocks agent mutations. Text uses the laboratory's Unicode IME.",
            "android_screenshot":"Read the current remote Android screenshot using native image input. No screenshot is written to the iPhone or local Linux workspace.",
            "android_network":"Start/stop bounded HTTP(S) capture or read/list events. after is a numeric cursor. HTTPS requires a trusted certificate; pinned/non-proxy traffic may be unavailable. Never claim every request was captured or infer causality from timing alone.",
            "android_project":"Inspect uploaded APK projects, install original/rebuilt APK, analyze with JADX, decode/edit/build with Apktool. Jobs run on the separate Android node; poll job. read returns SHA256; write requires expected_sha256. Preserve original APK. Re-signing may break integrity/login. No heavy Android builds on Railway."
        ]
        return names.sorted().map { name in
            let shape = schema(name)!, properties = shape["properties"] as! [String:[String:Any]]
            let parameters = properties.mapValues { property in
                AgentToolParam(type: property["type"] as? String == "integer" ? .integer : .string,
                    description:"Use the structured JSON schema. " + (property["description"] as? String ?? ""))
            }
            return AgentToolDefinition(name:name, description:descriptions[name]!, parameters:parameters, required:shape["required"] as? [String] ?? [])
        }
    }
    @MainActor static func execute(_ name: String, args: [String:Any], session: String?, callID: String) async throws -> [String:Any] {
        guard let session, let identifier = UUID(uuidString:session), names.contains(name) else { throw ZeusPatch.failure("افتح محادثة محفوظة أولًا.") }
        let body: [String:Any] = ["name":name, "arguments":args, "request_id":callID]
        let data = try await NativeCloudAccountAPI.runtime("v1/android/\(identifier.uuidString.lowercased())/tool", method:"POST", body:JSONSerialization.data(withJSONObject:body))
        guard let value = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw ZeusPatch.failure("استجابة مختبر غير صالحة.") }
        return value
    }
}

struct ZeusAndroidLabButton: View {
    let session: String?
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: { Label("مختبر Android", systemImage:"apps.iphone") }
            .accessibilityIdentifier("zeusAndroidLabButton")
            .fullScreenCover(isPresented:$presented) { ZeusAndroidLabView(session:session) }
    }
}

struct ZeusAndroidLabView: View {
    let session: String?
    @Environment(\.dismiss) private var dismiss
    @State private var access: ZeusAndroidAccess?
    @State private var issue: String?
    @State private var loading = true
    var body: some View {
        NavigationStack {
            Group {
                if let access { ZeusAndroidWebView(access:access, renew:load) }
                else {
                    VStack(spacing:22) {
                        Image(systemName:"apps.iphone").font(.system(size:65, weight:.ultraLight)).foregroundStyle(.mint)
                        Text("مختبر Android").font(.largeTitle.bold())
                        Text(issue ?? "يجري التحقق من اتصال المختبر…").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth:430)
                        if loading { ProgressView() }
                        else { Button("إعادة التحقق") { Task { await load() } }.buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black) }
                        Text("تشغيل منفصل عن جهازك وبيئة الوكيل المحلية").font(.caption).foregroundStyle(.secondary)
                    }.padding(28).frame(maxWidth:.infinity,maxHeight:.infinity)
                        .background(LinearGradient(colors:[Color(red:0.04,green:0.09,blue:0.07),.black], startPoint:.topTrailing,endPoint:.bottomLeading))
                }
            }
            .navigationTitle("ZEUS · Android").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("إغلاق") { dismiss() } } }
            .task { await load() }
        }.preferredColorScheme(.dark)
    }
    @MainActor private func load() async {
        loading = true; defer { loading = false }
        guard NativeCloudAccountAPI.ownerID != nil else { issue="سجّل دخولك إلى حساب ZEUS أولًا."; return }
        guard let session, let identifier = UUID(uuidString:session) else { issue="افتح محادثة محفوظة لربط المشروع ونتائجه بها."; return }
        do {
            let capabilities = try await NativeCloudAccountAPI.runtime("v1/android/capabilities")
            let value = try JSONSerialization.jsonObject(with:capabilities) as? [String:Any]
            guard value?["configured"] as? Bool == true else { issue=value?["reason"] as? String ?? "لم يربط خادم Android بعد."; return }
            let data = try await NativeCloudAccountAPI.runtime("v1/android/\(identifier.uuidString.lowercased())/access",method:"POST",body:Data("{}".utf8))
            access = try JSONDecoder().decode(ZeusAndroidAccess.self,from:data); issue=nil
        } catch { issue=error.localizedDescription }
    }
}

struct ZeusAndroidAccess: Decodable, Equatable { let url: URL; let token: String }

private struct ZeusAndroidWebView: UIViewRepresentable {
    let access: ZeusAndroidAccess
    let renew: @MainActor () async -> Void
    func makeCoordinator() -> Coordinator { Coordinator(renew:renew) }
    func makeUIView(context:Context) -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); configuration.allowsInlineMediaPlayback=true
        configuration.userContentController.add(context.coordinator,name:"labRenew")
        configuration.userContentController.add(context.coordinator,name:"labFullscreen")
        let view = WKWebView(frame:.zero,configuration:configuration)
        view.navigationDelegate=context.coordinator; view.isOpaque=false; view.backgroundColor = .black
        context.coordinator.view=view; context.coordinator.origin=access.url
        return view
    }
    func updateUIView(_ view:WKWebView,context:Context) {
        guard access.url.scheme == "https", access.url.user == nil, access.url.password == nil else { return }
        if context.coordinator.loaded == nil {
            var components = URLComponents(url:access.url,resolvingAgainstBaseURL:false)!
            components.fragment="token="+access.token
            if let url=components.url { view.load(URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData)); context.coordinator.loaded=access }
        } else if context.coordinator.loaded?.token != access.token {
            if let raw=try? JSONSerialization.data(withJSONObject:[access.token]),let literal=String(data:raw,encoding:.utf8) {
                view.evaluateJavaScript("window.zeusLabRenew(\(literal)[0])",completionHandler:nil); context.coordinator.loaded=access
            }
        }
    }
    static func dismantleUIView(_ view:WKWebView,coordinator:Coordinator) {
        view.stopLoading(); view.loadHTMLString("",baseURL:nil)
        view.configuration.userContentController.removeScriptMessageHandler(forName:"labRenew")
        view.configuration.userContentController.removeScriptMessageHandler(forName:"labFullscreen")
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var view:WKWebView?
        var origin:URL?
        var loaded:ZeusAndroidAccess?
        let renew:@MainActor () async -> Void
        init(renew:@escaping @MainActor () async -> Void) { self.renew=renew }
        func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping (WKNavigationActionPolicy)->Void) {
            guard let url=action.request.url, url.scheme=="https",url.host==origin?.host,url.port==origin?.port else { decisionHandler(.cancel);return }
            decisionHandler(.allow)
        }
        func userContentController(_ controller:WKUserContentController,didReceive message:WKScriptMessage) {
            guard message.frameInfo.isMainFrame,message.frameInfo.securityOrigin.host==origin?.host else { return }
            if message.name=="labRenew" { Task { @MainActor in await renew() } }
            if message.name=="labFullscreen" { view?.evaluateJavaScript("document.getElementById('screen').scrollIntoView({block:'start'})",completionHandler:nil) }
        }
    }
}
