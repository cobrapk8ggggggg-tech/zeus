import Foundation
import Combine
import CryptoKit
import Security

/// Actions is the runtime. Only a small receipt and a Keychain encryption key
/// survive on the device; frames and decrypted control results stay in memory.
@MainActor final class ZeusActionsLab: ObservableObject {
    struct Receipt: Codable {
        let session: UUID
        let owner: String
        let conversation: UUID
        let accountID: String
        let repository: String
        let branch: String
        var commit: String
        var runID: Int?
        var sequence: Int = 0
        var pendingRequest: String?
    }
    struct Connection: Decodable {
        let session: UUID
        let owner: String
        let conversation: UUID
        let url: URL
        let deadline: TimeInterval
        let viewer_bootstrap: String
        let agent_bootstrap: String
        let control_public_key: String
    }
    private static var instances: [String: ZeusActionsLab] = [:]
    static func shared(_ conversation: UUID) -> ZeusActionsLab {
        let scope=(NativeCloudAccountAPI.ownerID ?? "signed-out")+"/"+conversation.uuidString.lowercased()
        if let current=instances[scope] { return current }
        let created=ZeusActionsLab(conversation:conversation);instances[scope]=created;return created
    }
    @Published private(set) var receipt: Receipt?
    @Published private(set) var connection: Connection?
    @Published private(set) var screenshot: Data?
    @Published private(set) var observedAt: Date?
    @Published private(set) var phase = "جاهز لبدء جلسة مؤقتة"
    @Published private(set) var busy = false
    @Published private(set) var completed = false
    @Published var issue: String?
    let conversation: UUID
    private var polling: Task<Void,Never>?
    private var pollingNow=false
    private var frameNumber = 0
    var isTrusted:Bool { lastState?["trusted"] as? Bool == true && lastState?["controller"] as? String == "agent" && !completed }
    var displayState: [String:Any]? { lastState }
    private(set) var networkEvents: [[String:Any]] = []
    private var lastHeartbeat=Date.distantPast
    private var lastState: [String:Any]?
    private var pendingCount = 0
    private var requestTail: Task<Void,Never>?
    private var observations: [String:[String:Any]] = [:]
    private let client = ZeusGitHubTools.shared
    private var storageKey: String { "zeus.android.actions." + conversation.uuidString.lowercased() }
    private init(conversation:UUID) {
        self.conversation=conversation
        if let data=UserDefaults.standard.data(forKey:storageKey),let saved=try? JSONDecoder().decode(Receipt.self,from:data),saved.owner==NativeCloudAccountAPI.ownerID?.lowercased() { receipt=saved }
    }
    private func save() throws { if let receipt { UserDefaults.standard.set(try JSONEncoder().encode(receipt),forKey:storageKey) } }
    private func requireOwner() throws -> Receipt {
        guard let receipt,receipt.owner==NativeCloudAccountAPI.ownerID?.lowercased() else { connection=nil;screenshot=nil;lastState=nil;networkEvents=[];pause();throw ZeusPatch.failure("الجلسة تخص حساب ZEUS آخر أو انتهى تسجيل الدخول") }
        return receipt
    }
    private func keyQuery(_ receipt:Receipt)->[String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"ZEUS.AndroidLab.X25519.v1",kSecAttrAccount as String:receipt.owner+"/"+receipt.session.uuidString.lowercased()]
    }
    private func privateKey(_ receipt:Receipt) throws -> Data {
        var query=keyQuery(receipt);query[kSecReturnData as String]=true;query[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result)==errSecSuccess,let data=result as? Data,data.count==32 else { throw ZeusPatch.failure("مفتاح فك تشفير الجلسة غير متاح في Keychain؛ لا تبدأ جلسة بديلة فوق نتائج لم تحفظها") }
        return data
    }
    func start(accountID:String,repository:String,ref:String,trusted:Bool=true) async throws {
        guard !busy,receipt==nil || completed else { throw ZeusPatch.failure("توجد جلسة قائمة؛ أوقفها أو انتظر اكتمالها") }
        guard let owner=NativeCloudAccountAPI.ownerID?.lowercased(),UUID(uuidString:owner) != nil,
              repository.range(of:#"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#,options:.regularExpression) != nil,
              !ref.isEmpty,!ref.contains(".."),ref.count<=200 else { throw ZeusPatch.failure("اختر حسابًا ومستودعًا وفرعًا صالحًا") }
        busy=true;defer { busy=false }
        let prefix="/repos/"+repository
        let repo=try await client.object(accountID:accountID,path:prefix)
        guard (repo["permissions"] as? [String:Any])?["push"] as? Bool==true else { throw ZeusPatch.failure("يلزم حساب GitHub بصلاحية الكتابة إلى هذا المستودع") }
        _ = try await client.readSource(accountID:accountID,repository:repository,branch:ref,path:".github/workflows/zeus-lab-tunnel.yml",maxChars:1000)
        let base=try await client.object(accountID:accountID,path:prefix+"/commits/"+ref)
        guard let sha=base["sha"] as? String,sha.count==40 else { throw ZeusPatch.failure("لم يتأكد مصدر الجلسة") }
        let session=UUID(),key=Curve25519.KeyAgreement.PrivateKey(),branch="zeus-lab/"+session.uuidString.lowercased()
        var created=Receipt(session:session,owner:owner,conversation:conversation,accountID:accountID,repository:repository,branch:branch,commit:sha)
        var query=keyQuery(created);query[kSecValueData as String]=key.rawRepresentation;query[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(query as CFDictionary,nil)==errSecSuccess else { throw ZeusPatch.failure("تعذر حفظ مفتاح الجلسة") }
        _ = try await client.request(accountID:accountID,method:"POST",path:prefix+"/git/refs",body:["ref":"refs/heads/"+branch,"sha":sha])
        receipt=created;completed=false;connection=nil;screenshot=nil;frameNumber=0;try save()
        let launch:[String:Any] = ["session":session.uuidString.lowercased(),"owner":owner,"conversation":conversation.uuidString.lowercased(),"public_key":key.publicKey.rawRepresentation.base64EncodedString(),"runtime_seconds":900,"fixture_only":false,"trusted":trusted,"purpose":"User-requested temporary Android security laboratory"]
        let content=String(decoding:try JSONSerialization.data(withJSONObject:launch,options:[.sortedKeys]),as:UTF8.self)+"\n"
        let result=try await client.writeSources(accountID:accountID,repository:repository,branch:branch,message:"Start temporary encrypted ZEUS Android laboratory",files:[["path":"experiments/actions-lab/launch.json","content":content]])
        guard let head=result["commit_sha"] as? String else { throw ZeusPatch.failure("تعذر تأكيد بدء الجلسة؛ افحص الفرع قبل إعادة المحاولة") }
        created.commit=head;receipt=created;try save();phase="يجري تجهيز Android على GitHub Actions…";resume()
    }
    func resume() {
        guard polling==nil,receipt != nil else { return }
        polling=Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                do { try await self.poll() } catch { self.issue=error.localizedDescription }
                if self.completed { break }
                try? await Task.sleep(for:.seconds(5))
            }
            self?.polling=nil
        }
    }
    func pause() { polling?.cancel();polling=nil }
    private func readArtifact(_ artifact:[String:Any],name:String,receipt:Receipt) async throws -> Data {
        guard let id=artifact["id"] as? Int,let size=artifact["size_in_bytes"] as? Int,size>0,size<6*1024*1024,artifact["expired"] as? Bool==false else { throw ZeusPatch.failure("ملف الجلسة انتهى أو يتجاوز حد القراءة") }
        let zip=try await client.downloadArtifact(accountID:receipt.accountID,repository:receipt.repository,artifactID:id)
        defer { try? FileManager.default.removeItem(at:zip) }
        let handle=try FileHandle(forReadingFrom:zip);defer { try? handle.close() }
        let entries=try BackupZipExtractor.centralDirectory(handle:handle).filter { $0.name==name || $0.name.hasSuffix("/"+name) }
        guard entries.count==1,entries[0].uncompressedSize<=4*1024*1024,entries[0].compressedSize<=4*1024*1024,
              let data=try BackupPackageReader.readEntry(at:zip,named:name) else { throw ZeusPatch.failure("مغلف الجلسة مفقود أو غير آمن") }
        let box=try JSONDecoder().decode(ZeusLabEnvelope.Box.self,from:data)
        return try ZeusLabEnvelope.open(box,using:privateKey(receipt),session:receipt.session)
    }
    private func frame(_ value:[String:Any]) {
        if let events=(value["network"] as? [String:Any])?["events"] as? [[String:Any]] { networkEvents=events }
        if let state=value["state"] as? [String:Any] ?? value["session"] as? [String:Any] { lastState=state }
        if let base64=value["screenshot"] as? String,base64.utf8.count<1_300_000,let data=Data(base64Encoded:base64),data.count<=900000 {
            screenshot=data;observedAt=(value["observed_at"] as? Double).map(Date.init(timeIntervalSince1970:))
        }
    }
    func poll() async throws {
        guard !pollingNow else { return };pollingNow=true;defer { pollingNow=false }
        var saved=try requireOwner();let prefix="/repos/"+saved.repository
        if saved.runID==nil {
            let result=try await client.object(accountID:saved.accountID,path:prefix+"/actions/runs",query:["branch":saved.branch,"per_page":"10"])
            if let run=(result["workflow_runs"] as? [[String:Any]])?.first(where: { $0["head_sha"] as? String==saved.commit && $0["path"] as? String==".github/workflows/zeus-lab-tunnel.yml" }),let id=run["id"] as? Int { saved.runID=id;receipt=saved;try save() }
            else { return }
        }
        guard let runID=saved.runID else { return }
        var artifacts:[[String:Any]]=[]
        for page in 1...3 {
            let result=try await client.object(accountID:saved.accountID,path:prefix+"/actions/runs/\(runID)/artifacts",query:["per_page":"100","page":String(page)])
            let values=result["artifacts"] as? [[String:Any]] ?? [];artifacts+=values
            if values.count<100 { break }
        }
        let stem="zeus-lab-\(runID)-1-"
        if connection==nil,let initial=artifacts.first(where: { $0["name"] as? String==stem+"0" }) {
            let access=try JSONDecoder().decode(Connection.self,from:await readArtifact(initial,name:"connection.sealed.json",receipt:saved))
            guard access.session==saved.session,access.owner.lowercased()==saved.owner,access.conversation==conversation,access.url.scheme=="https",access.url.user==nil,access.url.password==nil else { throw ZeusPatch.failure("بيانات الاتصال لا تطابق حساب الجلسة") }
            connection=access;phase="Android متصل · لقطات متتابعة مشفّرة";issue=nil
        }
        let frames=artifacts.compactMap { a -> (Int,[String:Any])? in
            guard let name=a["name"] as? String,name.hasPrefix(stem),let n=Int(name.dropFirst(stem.count)),n>=1001,n>frameNumber else { return nil };return (n,a)
        }
        if let latest=frames.max(by: { $0.0<$1.0 }) {
            let value=try JSONSerialization.jsonObject(with:await readArtifact(latest.1,name:"frame.sealed.json",receipt:saved)) as? [String:Any] ?? [:]
            frame(value);frameNumber=latest.0
        }
        if let pending=saved.pendingRequest,let observation=artifacts.first(where: { $0["name"] as? String==stem+String(100+saved.sequence) }) {
            let value=try JSONSerialization.jsonObject(with:await readArtifact(observation,name:"observation.sealed.json",receipt:saved)) as? [String:Any] ?? [:]
            guard value["request_id"] as? String==pending,value["sequence"] as? Int==saved.sequence else { throw ZeusPatch.failure("لا تطابق نتيجة الأمر الطلب المنتظر") }
            observations[pending]=value;frame(value);saved.pendingRequest=nil;receipt=saved;try save()
            if observations.count>16 { observations=observations.filter { $0.key==pending } }
        }
        let run=try await client.object(accountID:saved.accountID,path:prefix+"/actions/runs/\(runID)")
        if run["status"] as? String=="completed" { completed=true;phase="انتهت الجلسة · "+(run["conclusion"] as? String ?? "غير محسوم") }
    }
    func execute(_ name:String,args:[String:Any],requestID:String=UUID().uuidString.lowercased(),agent:Bool=false) async throws -> [String:Any] {
        let digest=Array(SHA256.hash(data:Data(requestID.utf8)).prefix(16)).map { String(format:"%02x",$0) }.joined()
        let canonical=String(digest.prefix(8))+"-"+String(digest.dropFirst(8).prefix(4))+"-"+String(digest.dropFirst(12).prefix(4))+"-"+String(digest.dropFirst(16).prefix(4))+"-"+String(digest.suffix(12))
        let requestID=UUID(uuidString:requestID)?.uuidString.lowercased() ?? canonical
        guard !busy else { throw ZeusPatch.failure("يوجد أمر قيد التنفيذ؛ انتظر نتيجته") }
        var saved=try requireOwner()
        guard let access=connection,!completed,access.deadline>Date().timeIntervalSince1970 else { throw ZeusPatch.failure("جلسة Android لم تبدأ أو انتهت مدتها") }
        guard saved.pendingRequest==nil else { throw ZeusPatch.failure("نتيجة الأمر السابق غير مؤكدة؛ يجري انتظارها ولن يتكرر الإجراء تلقائيًا") }
        busy=true;defer { busy=false }
        let command:[String:Any] = ["credential":agent ? access.agent_bootstrap:access.viewer_bootstrap,"name":name,"arguments":args,"request_id":requestID]
        let box=try ZeusLabEnvelope.seal(JSONSerialization.data(withJSONObject:command),to:access.control_public_key,session:saved.session)
        saved.sequence+=1;saved.pendingRequest=requestID;receipt=saved;try save()
        let body:[String:Any] = ["session":saved.session.uuidString.lowercased(),"sequence":saved.sequence,"payload":try JSONSerialization.jsonObject(with:JSONEncoder().encode(box))]
        let content=String(decoding:try JSONSerialization.data(withJSONObject:body),as:UTF8.self)+"\n"
        _ = try await client.writeSources(accountID:saved.accountID,repository:saved.repository,branch:saved.branch,message:"Encrypted ZEUS Android control \(saved.sequence)",files:[["path":"experiments/actions-lab/control.json","content":content]])
        let until=Date().addingTimeInterval(100)
        while Date()<until {
            try await poll()
            if let observed=observations.removeValue(forKey:requestID) {
                guard let status=observed["http_status"] as? Int,let result=observed["result"] as? [String:Any] else { throw ZeusPatch.failure("نتيجة Android غير مكتملة") }
                guard status==200 else { throw ZeusPatch.failure(result["detail"] as? String ?? "فشل أمر Android HTTP \(status)") }
                if name=="android_device",["status","take","release","stop"].contains(args["operation"] as? String ?? "") || name=="__take" { lastState=result }
                return result
            }
            if completed { break }
            try await Task.sleep(for:.seconds(3))
        }
        throw ZeusPatch.failure("انتهت مهلة انتظار النتيجة. قد يكون الأمر نُفذ؛ افحص الشاشة والسجلات قبل تكراره")
    }
}

private final class ZeusLabNoRedirect:NSObject,URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) { completionHandler(nil) }
}

@MainActor extension ZeusActionsLab {
    func stop() async throws {
        let saved=try requireOwner()
        if connection != nil,!completed { _ = try await execute("android_device",args:["operation":"stop"]);phase="يجري حفظ النتائج وإنهاء الجلسة…" }
        else if let run=saved.runID {
            _ = try await client.request(accountID:saved.accountID,method:"POST",path:"/repos/"+saved.repository+"/actions/runs/\(run)/cancel")
            phase="طُلب إلغاء تجهيز المحاكي"
        }
    }
    func upload(_ source:URL) async throws -> ZeusAndroidAPKTransfer.Uploaded {
        _ = try requireOwner()
        guard let connection,!completed,!busy else { throw ZeusPatch.failure("انتظر اتصال المحاكي وانتهاء الأمر السابق") }
        let scoped=source.startAccessingSecurityScopedResource();defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values=try source.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
        guard values.isRegularFile==true,let bytes=values.fileSize,bytes>0,bytes<=256*1024*1024,source.pathExtension.lowercased()=="apk" else { throw ZeusPatch.failure("اختر APK أصغر من256 MiB") }
        guard connection.url.scheme=="https",connection.url.host?.hasSuffix(".trycloudflare.com")==true else { throw ZeusPatch.failure("رابط رفع الجلسة غير متاح؛ لم ينسخ الملف إلى بيئة محلية") }
        busy=true;defer { busy=false }
        let configuration=URLSessionConfiguration.ephemeral;configuration.urlCache=nil;configuration.requestCachePolicy = .reloadIgnoringLocalCacheData;configuration.timeoutIntervalForRequest=180;configuration.timeoutIntervalForResource=300
        let transport=URLSession(configuration:configuration,delegate:ZeusLabNoRedirect(),delegateQueue:nil);defer { transport.invalidateAndCancel() }
        var components=URLComponents(url:connection.url,resolvingAgainstBaseURL:false)!;components.fragment=nil;components.query=nil;components.path="/v1/access/renew"
        var renew=URLRequest(url:components.url!);renew.httpMethod="POST";renew.setValue("Bearer "+connection.viewer_bootstrap,forHTTPHeaderField:"Authorization")
        let (raw,response)=try await transport.data(for:renew)
        guard (response as? HTTPURLResponse)?.statusCode==200,let access=try JSONSerialization.jsonObject(with:raw) as? [String:Any],let token=access["token"] as? String else { throw ZeusPatch.failure("تعذر الوصول إلى رابط رفع APK المؤقت. التحكم عبر GitHub يظل منفصلًا؛ لم يُرفع الملف") }
        components.path="/v1/upload";var request=URLRequest(url:components.url!);request.httpMethod="POST";request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization");request.setValue("application/vnd.android.package-archive",forHTTPHeaderField:"Content-Type");request.setValue(source.lastPathComponent.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed),forHTTPHeaderField:"X-Filename")
        let (result,uploaded)=try await transport.upload(for:request,fromFile:source)
        guard (uploaded as? HTTPURLResponse)?.statusCode==200,let project=try JSONSerialization.jsonObject(with:result) as? [String:Any],let id=project["id"] as? String,UUID(uuidString:id) != nil,let sha=project["sha256"] as? String,sha.count==64 else { throw ZeusPatch.failure("رفع APK لم يتأكد؛ افحص قائمة المشاريع قبل تكراره") }
        return .init(project:id,sha256:sha)
    }
    func route(_ path:String,body:[String:Any]?) async throws -> [String:Any] {
        guard path.hasPrefix("/v1/"),let url=URLComponents(string:path),url.host==nil else { throw ZeusPatch.failure("طلب واجهة غير مسموح") }
        switch url.path {
        case "/v1/transport":return ["preferred":"github_frames","network_feed":"github_poll"]
        case "/v1/heartbeat":
            if Date().timeIntervalSince(lastHeartbeat)>45,!busy { _ = try await execute("__heartbeat",args:[:]);lastHeartbeat=Date() }
            return ["deadline":connection?.deadline ?? 0]
        case "/v1/session":
            if let cached=lastState { return cached }
            return try await queued("android_device",args:["operation":"status"],requestID:UUID().uuidString.lowercased())
        case "/v1/control/take":return try await execute("__take",args:[:])
        case "/v1/timeline":return try await execute("android_device",args:["operation":"timeline","after":Int(url.queryItems?.first(where:{$0.name=="after"})?.value ?? "0") ?? 0])
        case "/v1/tool":
            guard let body,let name=body["name"] as? String,ZeusAndroidTools.names.contains(name),let arguments=body["arguments"] as? [String:Any],let request=body["request_id"] as? String else { throw ZeusPatch.failure("أمر Android غير صالح") }
            return try await queued(name,args:arguments,requestID:request)
        case "/v1/upload":throw ZeusPatch.failure("ارفع APK باستخدام زر الرفع في شريط المختبر")
        default:throw ZeusPatch.failure("هذا المسار غير متاح عبر قناة GitHub")
        }
    }
    private func queued(_ name:String,args:[String:Any],requestID:String) async throws -> [String:Any] {
        guard pendingCount<12 else { throw ZeusPatch.failure("انتظر اكتمال الأوامر السابقة") }
        pendingCount+=1;defer { pendingCount-=1 }
        let previous=requestTail
        let result=Task { @MainActor in
            _ = await previous?.value
            try Task.checkCancellation()
            return try await self.execute(name,args:args,requestID:requestID)
        }
        requestTail=Task { _ = await result.result }
        return try await result.value
    }
}
