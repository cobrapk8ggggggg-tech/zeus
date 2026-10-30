import SwiftUI
import WebKit
import Combine
import UniformTypeIdentifiers

/// Bundled inspector remains available when a temporary tunnel cannot be
/// reached. Its commands and changed screenshots travel as sealed GitHub data.
struct ZeusActionsLabView: View {
    let conversation: UUID
    var chatPanel: AnyView?
    var stopAgent: (() -> Void)?
    @StateObject private var lab: ZeusActionsLab
    @ObservedObject private var connections = ZeusConnections.shared
    @State private var accountID = ""
    @State private var repository = "cobrapk8ggggggg-tech/zeus"
    @State private var sourceRef = "feature/zeus-security-lab-20261030"
    @State private var trusted = true
    @State private var selecting = false
    @State private var working = false
    @State private var showAgent = true
    init(conversation:UUID,chatPanel:AnyView?=nil,stopAgent:(() -> Void)?=nil) {
        self.conversation=conversation;self.chatPanel=chatPanel;self.stopAgent=stopAgent
        _lab=StateObject(wrappedValue:ZeusActionsLab.shared(conversation))
    }
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Circle().fill(lab.connection != nil && !lab.completed ? Color.mint:Color.gray).frame(width:7,height:7)
                VStack(alignment:.leading,spacing:4) {
                    Text(lab.phase).font(.subheadline.weight(.semibold))
                    if let observed=lab.observedAt { Text("آخر لقطة · "+observed.formatted(date:.omitted,time:.standard)).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if working || lab.busy { ProgressView() }
                if lab.connection != nil && !lab.completed { Button { selecting=true } label: { Label("APK",systemImage:"square.and.arrow.up") }.disabled(working || lab.busy) }
                if lab.receipt != nil && !lab.completed { Button("إنهاء",role:.destructive) { perform { try await lab.stop() } } }
                if chatPanel != nil { Button { showAgent.toggle() } label: { Image(systemName:"sidebar.right") }.accessibilityLabel("إظهار الوكيل") }
            }.padding(14).background(.ultraThinMaterial)
            if let issue=lab.issue { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(10).frame(maxWidth:.infinity,alignment:.leading) }
            if lab.connection != nil {
                GeometryReader { geometry in
                    HStack(spacing:0) {
                        if geometry.size.width>=950 || !showAgent || chatPanel==nil { ZeusActionsInspector(lab:lab,stopAgent:stopAgent) }
                        if showAgent,let chatPanel {
                            if geometry.size.width>=950 { Divider() }
                            chatPanel.frame(width:geometry.size.width>=950 ? min(400,geometry.size.width * 0.34):nil)
                        }
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment:.leading,spacing:24) {
                        Image(systemName:"apps.iphone").font(.system(size:56,weight:.ultraLight)).foregroundStyle(.mint)
                        Text("مختبرك، عند الطلب.").font(.largeTitle.bold())
                        Text("محاكي Android مؤقت على GitHub Actions. التحليل والملفات على بيئة الجلسة، والتحكم والنتائج مشفّرة.").foregroundStyle(.secondary)
                        VStack(spacing:18) {
                            Picker("حساب GitHub",selection:$accountID) {
                                Text("اختر الحساب").tag("")
                                ForEach(connections.linked("github")) { account in Text(account.label).tag(account.id) }
                            }
                            TextField("owner/repository",text:$repository).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("فرع مصدر المختبر",text:$sourceRef).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }.padding(20).background(Color.white.opacity(0.045),in:RoundedRectangle(cornerRadius:20))
                        Text("تتطلب النسخة الحالية وجود ملفات المختبر في الفرع المختار. الجلسة15 دقيقة بعد الإقلاع وعلى مشغّل Ubuntu قياسي. يدعم المستودعات الخاصة والعامة؛ تشغيل الخاص يُخصم من حصة GitHub.").font(.caption).foregroundStyle(.secondary)
                        Toggle("الثقة بالجلسة: تحكم الوكيل وتعديل نسخ الاختبار",isOn:$trusted).tint(.mint).font(.subheadline)
                        Button { perform { try await lab.start(accountID:accountID,repository:repository,ref:sourceRef,trusted:trusted) } } label: {
                            HStack { Image(systemName:"play.fill");Text("بدء جلسة Android");Spacer();if working { ProgressView() } }.padding(12)
                        }.buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black).disabled(accountID.isEmpty || working || lab.receipt != nil && !lab.completed)
                        if lab.receipt != nil && !lab.completed { Text("قد يستغرق تجهيز المحاكي عدة دقائق. يمكنك إغلاق هذه الواجهة والعودة؛ مدة الجلسة تبقى محدودة على Actions.").font(.caption).foregroundStyle(.secondary) }
                        Text("الحفظ الحالي في Actions مؤقت لمدة24 ساعة. لا تحذف تشغيل الجلسة قبل تنزيل نتائجك ومفتاح استعادتها.").font(.caption).foregroundStyle(.secondary)
                    }.padding(30).frame(maxWidth:620,alignment:.leading).frame(maxWidth:.infinity)
                }.background(LinearGradient(colors:[Color(red:0.035,green:0.085,blue:0.07),.black],startPoint:.topLeading,endPoint:.bottomTrailing))
            }
        }
        .fileImporter(isPresented:$selecting,allowedContentTypes:[UTType(filenameExtension:"apk") ?? .item],allowsMultipleSelection:false) { result in
            switch result {
            case .success(let urls): if let source=urls.first { perform { _ = try await lab.upload(source) } }
            case .failure(let error):lab.issue=error.localizedDescription
            }
        }
        .task { if accountID.isEmpty { accountID=connections.linked("github").first(where:{$0.isDefault})?.id ?? connections.linked("github").first?.id ?? "" };lab.resume() }
    }
    private func perform(_ action:@escaping @MainActor () async throws -> Void) { working=true;Task { @MainActor in defer { working=false };do { try await action() } catch { lab.issue=error.localizedDescription } } }
}

private struct ZeusActionsInspector: UIViewRepresentable {
    @ObservedObject var lab:ZeusActionsLab
    var stopAgent:(() -> Void)?
    func makeCoordinator()->Coordinator { Coordinator(lab:lab,stopAgent:stopAgent) }
    func makeUIView(context:Context)->WKWebView {
        let configuration=WKWebViewConfiguration();configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator,name:"labActions")
        configuration.userContentController.add(context.coordinator,name:"labStopAgent")
        configuration.setURLSchemeHandler(context.coordinator,forURLScheme:"zeuslab")
        let code="""
        (()=>{let next=0;const pending=new Map();window.zeusLabNative=(path,body)=>new Promise((resolve,reject)=>{const id=++next;const timer=setTimeout(()=>{pending.delete(id);reject(new Error('انتهت مهلة انتظار GitHub؛ افحص النتيجة قبل تكرار الأمر'))},115000);pending.set(id,{resolve,reject,timer});window.webkit.messageHandlers.labActions.postMessage({id,path,body:body??null})});window.zeusNativeComplete=v=>{const p=pending.get(v.id);if(!p)return;clearTimeout(p.timer);pending.delete(v.id);if(v.error)p.reject(new Error(v.error));else p.resolve(v.value)};window.zeusNativeFrame=v=>{window.dispatchEvent(new CustomEvent('zeusLabFrame',{detail:v}))};})();
        """
        configuration.userContentController.addUserScript(WKUserScript(source:code,injectionTime:.atDocumentStart,forMainFrameOnly:true))
        let view=WKWebView(frame:.zero,configuration:configuration);view.isOpaque=false;view.backgroundColor = .black;view.navigationDelegate=context.coordinator
        context.coordinator.view=view;context.coordinator.bind()
        view.load(URLRequest(url:URL(string:"zeuslab://session/index.html")!));return view
    }
    func updateUIView(_ view:WKWebView,context:Context) {}
    static func dismantleUIView(_ view:WKWebView,coordinator:Coordinator) { coordinator.subscriptions.removeAll();view.stopLoading();view.navigationDelegate=nil;view.configuration.userContentController.removeAllScriptMessageHandlers() }
    final class Coordinator:NSObject,WKScriptMessageHandler,WKURLSchemeHandler,WKNavigationDelegate {
        let lab:ZeusActionsLab;let stopAgent:(() -> Void)?;weak var view:WKWebView?;var subscriptions=Set<AnyCancellable>()
        init(lab:ZeusActionsLab,stopAgent:(() -> Void)?) { self.lab=lab;self.stopAgent=stopAgent }
        @MainActor func bind() {
            lab.$screenshot.combineLatest(lab.$observedAt).sink { [weak self] data,time in
                guard let data else { return };self?.sendFrame(data,time:time)
            }.store(in:&subscriptions)
        }
        @MainActor private func sendFrame(_ data:Data,time:Date?) {
            send("window.zeusNativeFrame",["screenshot":data.base64EncodedString(),"observed_at":time?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,"state":lab.displayState ?? [:],"network":["events":lab.networkEvents]])
        }
        @MainActor private func send(_ method:String,_ object:[String:Any]) {
            guard let data=try? JSONSerialization.data(withJSONObject:object),let literal=String(data:data,encoding:.utf8) else { return }
            view?.evaluateJavaScript(method+"("+literal+")",completionHandler:nil)
        }
        func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
            if let data=lab.screenshot { sendFrame(data,time:lab.observedAt) }
        }
        func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping (WKNavigationActionPolicy)->Void) { decisionHandler(action.request.url?.scheme=="zeuslab" && action.request.url?.host=="session" ? .allow:.cancel) }
        func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
            guard message.frameInfo.isMainFrame,message.frameInfo.request.url?.scheme=="zeuslab",message.frameInfo.request.url?.host=="session" else { return }
            if message.name=="labStopAgent" { stopAgent?();return }
            guard message.name=="labActions",let body=message.body as? [String:Any],let id=body["id"] as? Int,let path=body["path"] as? String,path.count<1000 else { return }
            Task { @MainActor in
                do { let result=try await lab.route(path,body:body["body"] as? [String:Any]);send("window.zeusNativeComplete",["id":id,"value":result]) }
                catch { send("window.zeusNativeComplete",["id":id,"error":error.localizedDescription]) }
            }
        }
        func webView(_ webView:WKWebView,start task:WKURLSchemeTask) {
            guard task.request.url?.host=="session",let name=task.request.url?.lastPathComponent,["index.html","lab.js","lab.css","transports.js"].contains(name),
                  let root=Bundle.main.url(forResource:"ZeusAndroidLab",withExtension:nil),let data=try? Data(contentsOf:root.appendingPathComponent(name)) else { task.didFailWithError(ZeusPatch.failure("ملفات واجهة المختبر غير موجودة"));return }
            let mime=name.hasSuffix(".html") ? "text/html":name.hasSuffix(".js") ? "application/javascript":"text/css"
            task.didReceive(URLResponse(url:task.request.url!,mimeType:mime,expectedContentLength:data.count,textEncodingName:"utf-8"));task.didReceive(data);task.didFinish()
        }
        func webView(_ webView:WKWebView,stop task:WKURLSchemeTask) {}
    }
}
