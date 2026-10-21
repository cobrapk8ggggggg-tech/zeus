import Foundation

// One reusable provider layer for translation and the AI workspace. Private account
// protocols are isolated here so a service change never blocks ordinary browsing.
actor AIProviderService {
    static let shared = AIProviderService()
    private var threads: [UUID: [Any]] = [:]
    private var parents: [UUID: (String, String)] = [:]
    private struct GeminiSession { var at: String; var sid: String; var build: String; var cookie: String }
    private var googleSessions: [String: GeminiSession] = [:]
    func clearRuntime() { threads.removeAll(); parents.removeAll(); googleSessions.removeAll() }
    func end(_ context: UUID) { threads.removeValue(forKey: context); parents.removeValue(forKey: context) }
    func discover(_ input: AIProviderConfiguration, secret: String, chatLimit: Int = 50) async throws -> AIProviderConfiguration {
        var config = input; config.discoveryNotice = nil
        switch config.kind {
        case .openAICompatible:
            let url = try AIHTTP.endpoint(config.baseURL, path: "models")
            let value = try await AIHTTP.object(AIHTTP.request(url, headers: bearer(secret))) as? [String: Any]
            config.models = (value?["data"] as? [[String: Any]] ?? []).compactMap { item in guard let id = item["id"] as? String else { return nil }; return AIChoice(id: id, name: item["name"] as? String ?? id) }.sorted { $0.name < $1.name }
        case .geminiAPI:
            var page: String?; var models: [AIChoice] = []
            repeat {
                var c = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
                c.queryItems = [URLQueryItem(name: "pageSize", value: "100")]; if let page { c.queryItems?.append(URLQueryItem(name: "pageToken", value: page)) }
                let value = try await AIHTTP.object(AIHTTP.request(c.url!, headers: ["x-goog-api-key": secret])) as? [String: Any]
                models += (value?["models"] as? [[String: Any]] ?? []).compactMap { m in guard let id = m["name"] as? String, (m["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") else { return nil }; return AIChoice(id: id.replacingOccurrences(of: "models/", with: ""), name: m["displayName"] as? String ?? id) }
                page = value?["nextPageToken"] as? String
            } while page != nil && models.count < 500
            config.models = models
        case .chatGPTAccount:
            let headers = try chatGPTHeaders(secret)
            let models = try await accountGet("models", headers: headers) as? [String: Any]
            config.models = (models?["models"] as? [[String: Any]] ?? []).compactMap { m in guard let id = m["slug"] as? String else { return nil }; return AIChoice(id: id, name: m["title"] as? String ?? id) }
            if !config.models.contains(where: { $0.id == "auto" }) { config.models.insert(AIChoice(id: "auto", name: "اختيار الحساب التلقائي"), at: 0) }
            var chats: [AIChoice] = []
            for offset in stride(from: 0, to: min(chatLimit, 500), by: 50) {
                let list = try await accountGet("conversations?offset=\(offset)&limit=50&order=updated&is_archived=false", headers: headers) as? [String: Any]
                let items = (list?["items"] as? [[String: Any]] ?? []).compactMap(Self.chatChoice)
                chats += items; if items.count < 50 { break }
            }
            config.chats = chats
            do {
                let value = try await accountGet("gizmos/snorlax/sidebar?owned_only=true&conversations_per_gizmo=100&limit=100", headers: headers) as? [String: Any]
                config.projects = (value?["items"] as? [[String: Any]] ?? []).compactMap { item in
                    let wrapper = item["gizmo"] as? [String: Any] ?? [:], gizmo = wrapper["gizmo"] as? [String: Any] ?? wrapper
                    guard let id = gizmo["id"] as? String else { return nil }
                    return AIProject(id: id, name: (gizmo["display"] as? [String: Any])?["name"] as? String ?? "مشروع", chats: ((item["conversations"] as? [String: Any])?["items"] as? [[String: Any]] ?? []).compactMap(Self.chatChoice))
                }
            } catch { config.discoveryNotice = "جُلبت النماذج والمحادثات؛ تعذر جلب المشاريع: " + error.localizedDescription }
        case .geminiAccount:
            let session = try await geminiSession(config, secret: secret, refresh: true)
            let status = try await geminiRPC(config, session: session, id: "otAQ7b", payload: [])
            config.models = []
            if let body = status.first {
                let code = AIHTTP.nested(body, [14]) as? Int ?? 1000
                guard code == 1000 else { throw TranslationFailure.message("حساب Gemini غير جاهز (\(code)). أكمل تسجيل الدخول وشروط الخدمة في موقعه.") }
                let tiers = AIHTTP.nested(body, [16]) as? [Int] ?? [], flags = AIHTTP.nested(body, [17]) as? [Int] ?? []
                let field = tiers.contains(21) || tiers.contains(22) ? 13 : 12
                let capacity = tiers.contains(22) ? 2 : tiers.contains(21) ? 1 : flags.contains(115) ? 4 : tiers.contains(16) || flags.contains(106) ? 3 : tiers.contains(8) || flags.contains(19) ? 2 : 1
                config.models = (AIHTTP.nested(body, [15]) as? [[Any]] ?? []).compactMap { m in
                    guard let id = m.first as? String else { return nil }
                    let name = (AIHTTP.nested(m, [11]) as? String) ?? (AIHTTP.nested(m, [19]) as? String) ?? (AIHTTP.nested(m, [1]) as? String) ?? id
                    var header: [Any] = [1, NSNull(), NSNull(), NSNull(), id, NSNull(), NSNull(), 0, [4,5,6,8], NSNull(), NSNull()]
                    while header.count <= field { header.append(NSNull()) }; header[field] = capacity
                    header.append(NSNull()); header.append(NSNull()); header.append((AIHTTP.nested(m, [17]) as? Int) ?? (AIHTTP.nested(m, [9]) as? Int) ?? 1)
                    return AIChoice(id: id, name: name, metadata: try? AIHTTP.string(header))
                }
            }
            config.chats = []
            for pinned in [1, 0] {
                let payload: [Any] = [min(chatLimit, 500), NSNull(), [pinned, NSNull(), 1]]
                let values = try await geminiRPC(config, session: session, id: "MaZiqc", payload: payload)
                for value in values {
                    for row in AIHTTP.nested(value, [2]) as? [[Any]] ?? [] {
                        if let id = row.first as? String, let name = AIHTTP.nested(row, [1]) as? String, !config.chats.contains(where: { $0.id == id }) { config.chats.append(AIChoice(id: id, name: name)) }
                    }
                }
            }
            config.projects = [] // Gemini account does not expose ChatGPT-style Projects.
        }
        guard !config.models.isEmpty else { throw TranslationFailure.message("اتصل الخادم لكنه لم يُرجع نماذج متاحة لهذا الحساب. لا توجد نماذج مُختلقة؛ تحقق من العنوان أو الجلسة.") }
        if !config.models.contains(where: { $0.id == config.model }) { config.model = config.models[0].id }
        config.lastChecked = Date(); return config
    }
    private static func chatChoice(_ m: [String: Any]) -> AIChoice? { guard let id = m["id"] as? String else { return nil }; return AIChoice(id: id, name: m["title"] as? String ?? "محادثة بلا عنوان") }
    private func bearer(_ secret: String) -> [String: String] { secret.isEmpty ? [:] : ["Authorization": "Bearer " + secret] }
    func chatGPTHeaders(_ secret: String) throws -> [String: String] {
        let parts = secret.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 3 else { throw TranslationFailure.message("أدخل Access Token لحساب ChatGPT؛ مفتاح API يُستخدم مع مزود OpenAI المتوافق.") }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let claims = try AIHTTP.json(data) as? [String: Any], let auth = claims["https://api.openai.com/auth"] as? [String: Any], let account = auth["chatgpt_account_id"] as? String else { throw TranslationFailure.message("لم يتضمن الرمز معرّف حساب ChatGPT.") }
        if let exp = claims["exp"] as? Double, exp < Date().timeIntervalSince1970 { throw TranslationFailure.message("انتهت صلاحية رمز ChatGPT. أدخل رمزًا جديدًا.") }
        return ["Authorization": "Bearer " + secret, "ChatGPT-Account-ID": account, "User-Agent": "ChatGPT/1.2026.195 (Android 16; build 2619512)", "oai-package-name": "com.openai.chatgpt", "oai-client-type": "android", "oai-device-id": UUID().uuidString, "chatgpt-residency-region": "no_constraint", "x-device-tier": "mid"]
    }
    private func accountGet(_ path: String, headers: [String: String]) async throws -> Any {
        try await AIHTTP.object(AIHTTP.request(URL(string: "https://android.chat.openai.com/backend-api/" + path)!, headers: headers))
    }
    func generate(_ prompt: String, config: AIProviderConfiguration, secret: String, context: UUID, attachments: [AIAttachment] = []) async throws -> String {
        guard attachments.reduce(0, { $0 + $1.data.count }) <= 20_000_000 else { throw TranslationFailure.message("قلل مجموع المرفقات إلى 20 ميجابايت.") }
        guard !config.model.isEmpty else { throw TranslationFailure.message("اختر نموذجًا بعد اختبار اتصال المزود في الإعدادات.") }
        switch config.kind {
        case .openAICompatible:
            var parts: [[String: Any]] = [["type": "text", "text": prompt]]
            for attachment in attachments {
                if attachment.isImage { parts.append(["type": "image_url", "image_url": ["url": attachment.dataURL]]) }
                else if attachment.mime == "application/pdf" { parts.append(["type": "file", "file": ["filename": attachment.name, "file_data": attachment.dataURL]]) }
                else if let text = String(data: attachment.data, encoding: .utf8) { parts.append(["type": "text", "text": "Attachment: " + attachment.name + "\n" + text]) }
                else { throw TranslationFailure.message("هذا الملف غير مدعوم في chat/completions. اختر صورة أو PDF أو ملفًا نصيًا؛ يعتمد قبول المرفقات على المزود والنموذج.") }
            }
            let message: [String: Any] = ["role": "user", "content": attachments.isEmpty ? prompt as Any : parts as Any]
            let body: [String: Any] = ["model": config.model, "messages": [message], "stream": false]
            let value = try await AIHTTP.object(AIHTTP.request(AIHTTP.endpoint(config.baseURL, path: "chat/completions"), method: "POST", body: body, headers: bearer(secret))) as? [String: Any]
            guard let choice = (value?["choices"] as? [[String: Any]])?.first, let message = choice["message"] as? [String: Any], let text = message["content"] as? String, !text.isEmpty else { throw TranslationFailure.message("لم يُرجع المزود نصًا من chat/completions.") }; return text
        case .geminiAPI:
            guard config.model.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { throw TranslationFailure.message("معرّف النموذج غير صالح.") }
            let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/" + config.model + ":generateContent")!
            var parts: [[String: Any]] = [["text": prompt]]
            parts += attachments.map { ["inline_data": ["mime_type": $0.mime, "data": $0.data.base64EncodedString()]] }
            let value = try await AIHTTP.object(AIHTTP.request(url, method: "POST", body: ["contents": [["role": "user", "parts": parts]]], headers: ["x-goog-api-key": secret])) as? [String: Any]
            let text = ((value?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            let result = text.compactMap { $0["text"] as? String }.joined(); guard !result.isEmpty else { throw TranslationFailure.message("لم يُرجع Gemini نصًا؛ قد يكون المحتوى مرفوضًا أو الحد مستنفدًا.") }; return result
        case .chatGPTAccount: return try await chatGPT(prompt, config: config, secret: secret, context: context, attachments: attachments)
        case .geminiAccount: return try await gemini(prompt, config: config, secret: secret, context: context, attachments: attachments)
        }
    }
    private func chatGPT(_ prompt: String, config: AIProviderConfiguration, secret: String, context: UUID, attachments: [AIAttachment]) async throws -> String {
        let headers = try chatGPTHeaders(secret)
        var conversation = parents[context]?.0 ?? config.conversationID
        var parent = parents[context]?.1 ?? UUID().uuidString
        if parents[context] == nil, let conversation {
            let value = try await accountGet("conversation/" + conversation, headers: headers) as? [String: Any]; parent = value?["current_node"] as? String ?? parent
        }
        var uploaded: [[String: Any]] = [], imageParts: [[String: Any]] = []
        for attachment in attachments { let result = try await chatGPTUpload(attachment, secret: secret); uploaded.append(result.metadata); if let image = result.image { imageParts.append(image) } }
        var message: [String: Any] = ["id": UUID().uuidString, "author": ["role": "user"], "content": ["content_type": "text", "parts": [prompt]], "status": "finished_successfully", "recipient": "all", "metadata": [:]]
        if !uploaded.isEmpty { message["metadata"] = ["attachments": uploaded] }
        if !imageParts.isEmpty { message["content"] = ["content_type": "multimodal_text", "parts": imageParts.map { $0 as Any } + [prompt]] }
        var q: [String: Any] = ["action": "next", "messages": [message], "parent_message_id": parent, "model": config.model, "timezone": TimeZone.current.identifier, "timezone_offset_min": TimeZone.current.secondsFromGMT() / 60, "history_and_training_disabled": false, "force_use_sse": true, "stream": true, "websocket_request_id": UUID().uuidString]
        if let conversation { q["conversation_id"] = conversation }
        if let project = config.projectID { var metadata = message["metadata"] as? [String: Any] ?? [:]; metadata["gizmo_id"] = project; message["metadata"] = metadata; q["messages"] = [message]; q["conversation_mode"] = ["kind": "gizmo_interaction", "gizmo_id": project]; q["conversation_origin"] = "tpp" }
        var request = try AIHTTP.request(URL(string: "https://android.chat.openai.com/backend-api/conversation")!, method: "POST", body: q, headers: headers)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let data = try await AIHTTP.data(request); var answer = "", node = parent
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let e = try? AIHTTP.json(Data(payload.utf8)) as? [String: Any] else { continue }
            if let cid = e["conversation_id"] as? String { conversation = cid }
            if e["error"] != nil { throw TranslationFailure.message("أعاد ChatGPT خطأ أثناء التوليد. تحقق من الجلسة وحد الاستخدام.") }
            if let m = e["message"] as? [String: Any], (m["author"] as? [String: Any])?["role"] as? String == "assistant" {
                let text = ((m["content"] as? [String: Any])?["parts"] as? [Any] ?? []).compactMap { $0 as? String }.joined()
                if !text.isEmpty { answer = text; node = m["id"] as? String ?? node }
            }
        }
        guard !answer.isEmpty else { throw TranslationFailure.message("لم يصل رد نصي من ChatGPT. ربما تغير بروتوكول الحساب أو انتهت الجلسة.") }
        if let conversation { parents[context] = (conversation, node) }; return answer
    }
    private func capture(_ text: String, pattern: String) -> String? {
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[r]).components(separatedBy: "\":\"").last?.dropLast().description
    }
    private func geminiSession(_ config: AIProviderConfiguration, secret: String, refresh: Bool = false) async throws -> GeminiSession {
        let key = config.id.uuidString + ":" + String(config.googleAccountIndex)
        if !refresh, let s = googleSessions[key], s.cookie == secret { return s }
        guard !secret.isEmpty, !secret.contains("\n"), !secret.contains("\r") else { throw TranslationFailure.message("أدخل ترويسة Cookie لحساب Google من جلسة تخصك.") }
        let url = URL(string: "https://gemini.google.com/u/\(config.googleAccountIndex)/app")!
        let data = try await AIHTTP.data(AIHTTP.request(url, headers: ["Cookie": secret, "User-Agent": "Mozilla/5.0", "Accept": "text/html"]))
        let text = String(decoding: data, as: UTF8.self)
        guard let at = capture(text, pattern: #""SNlM0e":"[^"]+""#), let sid = capture(text, pattern: #""FdrFJe":"[^"]+""#) else { throw TranslationFailure.message("لم تكتمل مصادقة Gemini. سجّل الدخول إلى موقعه وحدّث كوكيز الحساب.") }
        let session = GeminiSession(at: at, sid: sid, build: capture(text, pattern: #""cfb2h":"[^"]+""#) ?? "", cookie: secret)
        googleSessions[key] = session; return session
    }
    private func geminiRPC(_ config: AIProviderConfiguration, session: GeminiSession, id: String, payload: Any) async throws -> [Any] {
        var c = URLComponents(string: "https://gemini.google.com/u/\(config.googleAccountIndex)/_/BardChatUi/data/batchexecute")!
        c.queryItems = [URLQueryItem(name: "rpcids", value: id), URLQueryItem(name: "source-path", value: "/u/\(config.googleAccountIndex)/app"), URLQueryItem(name: "f.sid", value: session.sid), URLQueryItem(name: "bl", value: session.build), URLQueryItem(name: "rt", value: "c")]
        var request = try AIHTTP.request(c.url!, method: "POST", headers: ["Cookie": session.cookie, "Origin": "https://gemini.google.com", "Referer": "https://gemini.google.com/", "X-Same-Domain": "1"])
        request.httpBody = AIHTTP.form(["at": session.at, "f.req": try AIHTTP.string([[[id, AIHTTP.string(payload), NSNull(), "generic"]]] )]); request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        return AIHTTP.rpc(try await AIHTTP.data(request), id: id)
    }
    private func gemini(_ prompt: String, config: AIProviderConfiguration, secret: String, context: UUID, attachments: [AIAttachment]) async throws -> String {
        let session = try await geminiSession(config, secret: secret)
        var history = threads[context] ?? ["", "", "", NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), ""]
        if threads[context] == nil, let cid = config.conversationID {
            let turns = try await geminiRPC(config, session: session, id: "hNvQHb", payload: [cid, 1, NSNull(), 1, [1], [4], NSNull(), 1])
            guard let turn = turns.first.flatMap({ AIHTTP.nested($0, [0,0]) }),
                  let rid = AIHTTP.nested(turn, [0,1]) as? String,
                  let rcid = AIHTTP.nested(turn, [3,0,0,0]) as? String else { throw TranslationFailure.message("تعذر جلب سياق محادثة Gemini المختارة؛ اختر محادثة جديدة أو حدّث القائمة.") }
            history[0] = cid; history[1] = rid; history[2] = rcid
        }
        var uploaded: [Any] = []
        for attachment in attachments { let uri = try await geminiUpload(attachment, cookie: secret); uploaded.append([[uri, 1], attachment.name]) }
        let content: [Any] = [[prompt, 0, NSNull(), uploaded, NSNull(), NSNull(), 0], ["ar"], history, NSNull(), NSNull(), NSNull(), [], 0, [], [], 1, 0]
        var c = URLComponents(string: "https://gemini.google.com/u/\(config.googleAccountIndex)/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate")!
        c.queryItems = [URLQueryItem(name: "bl", value: session.build), URLQueryItem(name: "hl", value: "ar"), URLQueryItem(name: "f.sid", value: session.sid), URLQueryItem(name: "rt", value: "c"), URLQueryItem(name: "_reqid", value: String(Int.random(in: 10000...99999)))]
        var headers = ["Cookie": secret, "Origin": "https://gemini.google.com", "Referer": "https://gemini.google.com/", "X-Same-Domain": "1"]
        if let header = config.models.first(where: { $0.id == config.model })?.metadata { headers["x-goog-ext-525001261-jspb"] = header }
        var request = try AIHTTP.request(c.url!, method: "POST", headers: headers)
        request.httpBody = AIHTTP.form(["at": session.at, "f.req": try AIHTTP.string([NSNull(), AIHTTP.string(content)])]); request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        let data = try await AIHTTP.data(request); var result = ""
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
            guard let outer = try? AIHTTP.json(Data(line.utf8)), let s = AIHTTP.nested(outer, [0,2]) as? String, let inner = try? AIHTTP.json(Data(s.utf8)) else { continue }
            if let text = AIHTTP.nested(inner, [4,0,1,0]) as? String, !text.isEmpty { result = text }
            if let cid = AIHTTP.nested(inner, [1,0]) as? String, let rid = AIHTTP.nested(inner, [1,1]) as? String, let rcid = AIHTTP.nested(inner, [4,0,0]) as? String {
                let at = (AIHTTP.nested(inner, [3]) as? [String: Any])?["26"] as? String ?? ""
                threads[context] = [cid, rid, rcid, NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), at]
            }
        }
        guard !result.isEmpty else { throw TranslationFailure.message("لم يُرجع Gemini نصًا. أعد اختبار الاتصال؛ بروتوكول الويب قد يتغير.") }; return result
    }
}
