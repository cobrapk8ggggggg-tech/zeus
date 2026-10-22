import Foundation

@MainActor enum BrowserAgentTransport {
    static func generate(messages: [AgentWireMessage], provider: AIProviderConfiguration, secret: String, session: UUID, attachments: [AIAttachment], filesRoot: URL, delta: @escaping (String, String) -> Void) async throws -> AgentReply {
        if provider.kind != .openAICompatible {
            // Account protocols have no client tool schema; use a strict tool-call envelope.
            // Calls still run in the same native executor and return observed results to the next round.
            let catalog = String(decoding: try JSONSerialization.data(withJSONObject: BrowserAgentTools.schema), as: UTF8.self)
            let transcript = messages.map { $0.role + ": " + $0.content + ($0.calls.map { "\n" + String(decoding: (try? JSONEncoder().encode($0)) ?? Data(), as: UTF8.self) } ?? "") }.joined(separator: "\n\n")
            let prompt = "\(transcript)\n\nAVAILABLE TOOLS: \(catalog)\nIf a tool is needed, respond with a JSON object only: {\"tool_calls\":[{\"name\":\"browser_read\",\"arguments\":{}}]}. Otherwise respond naturally in Markdown. Never claim to have run a tool before its result."
            let answer = try await AIProviderService.shared.generate(prompt, config: provider, secret: secret, context: session, attachments: attachments)
            let parsed = try parseEnvelope(answer)
            if !parsed.text.isEmpty { delta(parsed.text, "") }
            return parsed
        }
        var wire = messages.map(\.json)
        for index in messages.indices {
            guard let files = messages[index].files, !files.isEmpty else { continue }
            var content: [[String: Any]] = [["type": "text", "text": messages[index].content]]
            for file in files {
                let url = filesRoot.appendingPathComponent(file.relativePath).standardizedFileURL.resolvingSymlinksInPath()
                guard url.path.hasPrefix(filesRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_000_000, let data = try? Data(contentsOf: url) else { continue }
                if file.mime.hasPrefix("image/") { content.append(["type": "image_url", "image_url": ["url": "data:" + file.mime + ";base64," + data.base64EncodedString()]]) }
                else if file.mime == "application/pdf" { content.append(["type": "file", "file": ["filename": file.name, "file_data": "data:application/pdf;base64," + data.base64EncodedString()]]) }
                else if let text = String(data: data, encoding: .utf8) { content.append(["type": "text", "text": "Attachment " + file.name + ":\n" + String(text.prefix(100_000))]) }
            }
            wire[index]["content"] = content
        }
        if !attachments.isEmpty, let i = wire.lastIndex(where: { $0["role"] as? String == "user" }) {
            var parts: [[String: Any]] = [["type":"text","text":messages[i].content]]
            for attachment in attachments {
                if attachment.isImage { parts.append(["type":"image_url","image_url":["url":attachment.dataURL]]) }
                else if attachment.mime == "application/pdf" { parts.append(["type":"file","file":["filename":attachment.name,"file_data":attachment.dataURL]]) }
                else if let text = String(data: attachment.data, encoding: .utf8) { parts.append(["type":"text","text":"Attachment \(attachment.name):\n" + String(text.prefix(100_000))]) }
                else { throw AgentFailure.message("نوع الملف غير مدعوم من هذا المزوّد.") }
            }
            wire[i]["content"] = parts
        }
        let body: [String: Any] = ["model":provider.model,"messages":wire,"tools":BrowserAgentTools.schema,"tool_choice":"auto","stream":true]
        var request = try AIHTTP.request(AIHTTP.endpoint(provider.baseURL, path: "chat/completions"), method:"POST", body:body, headers:secret.isEmpty ? [:] : ["Authorization":"Bearer " + secret])
        request.setValue("text/event-stream", forHTTPHeaderField:"Accept")
        request.timeoutInterval = 180
        let (bytes, response) = try await URLSession.shared.bytes(for:request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            var data = Data(); for try await byte in bytes { data.append(byte); if data.count > 2000 { break } }
            throw AgentFailure.message("تعذر الاتصال بالمزوّد (\((response as? HTTPURLResponse)?.statusCode ?? 0)): " + String(decoding:data,as:UTF8.self))
        }
        if !(http.value(forHTTPHeaderField:"Content-Type") ?? "").contains("event-stream") {
            var data = Data(); for try await byte in bytes { try Task.checkCancellation(); data.append(byte); if data.count > 8_000_000 { throw AgentFailure.message("رد المزوّد أكبر من الحد المسموح.") } }
            let reply = try decodeObject(JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]); delta(reply.text,""); return reply
        }
        var text = "", thought = "", pending: [Int:AgentToolCall] = [:], finished = false
        var lastUpdate = Date.distantPast, bytesRead = 0
        for try await line in bytes.lines {
            try Task.checkCancellation(); bytesRead += line.utf8.count
            guard bytesRead < 8_000_000 else { throw AgentFailure.message("تجاوز الرد الحد المسموح.") }
            guard line.hasPrefix("data:") else { continue }
            let raw = line.dropFirst(5).trimmingCharacters(in:.whitespaces)
            if raw == "[DONE]" { finished = true; break }
            guard let object = try? JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any] else { continue }
            if let error = object["error"] { throw AgentFailure.message("خطأ من المزوّد: \(error)") }
            guard let choice = (object["choices"] as? [[String:Any]])?.first else { continue }
            if let reason = choice["finish_reason"] as? String { finished = true; if reason == "length" { throw AgentFailure.message("بلغ الرد حد طول النموذج. جرّب طلبًا أقصر.") } }
            let value = choice["delta"] as? [String:Any] ?? [:]
            text += value["content"] as? String ?? ""
            thought += (value["reasoning_content"] as? String) ?? (value["reasoning"] as? String) ?? ""
            for call in value["tool_calls"] as? [[String:Any]] ?? [] {
                let index = call["index"] as? Int ?? 0, function = call["function"] as? [String:Any] ?? [:]
                var item = pending[index] ?? AgentToolCall(name:"",arguments:"")
                if let id = call["id"] as? String { item.id = id }
                item.name += function["name"] as? String ?? ""; item.arguments += function["arguments"] as? String ?? ""
                pending[index] = item
            }
            if Date().timeIntervalSince(lastUpdate) > 0.07 { delta(text,thought); lastUpdate = Date() }
        }
        delta(text,thought)
        guard finished else { throw AgentFailure.message("انقطع رد المزوّد قبل اكتماله. لم تُنفّذ أي أدوات غير مكتملة.") }
        return AgentReply(text:text,calls:pending.keys.sorted().compactMap { pending[$0] })
    }
    private static func decodeObject(_ object: [String:Any]) throws -> AgentReply {
        guard let message = (object["choices"] as? [[String:Any]])?.first?["message"] as? [String:Any] else { throw AgentFailure.message("رد المزوّد لا يحتوي على رسالة.") }
        let calls = (message["tool_calls"] as? [[String:Any]] ?? []).compactMap { value -> AgentToolCall? in
            guard let f = value["function"] as? [String:Any], let name = f["name"] as? String, let args = f["arguments"] as? String else { return nil }
            return AgentToolCall(id:value["id"] as? String ?? UUID().uuidString,name:name,arguments:args)
        }
        return AgentReply(text:message["content"] as? String ?? "",calls:calls)
    }
    static func parseEnvelope(_ value: String) throws -> AgentReply {
        var raw = value.trimmingCharacters(in:.whitespacesAndNewlines)
        if raw.hasPrefix("```json\n"), raw.hasSuffix("```") { raw = String(raw.dropFirst(8).dropLast(3)).trimmingCharacters(in:.whitespacesAndNewlines) }
        guard let object = try? JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any], let calls = object["tool_calls"] as? [[String:Any]] else { return AgentReply(text:value,calls:[]) }
        guard calls.count <= 12 else { throw AgentFailure.message("أرسل النموذج أدوات أكثر من الحد المسموح.") }
        let result = try calls.map { call -> AgentToolCall in
            guard let name = call["name"] as? String, let args = call["arguments"] as? [String:Any], BrowserAgentTools.tools.contains(where: { $0.name == name }) else { throw AgentFailure.message("أعاد النموذج تعريف أداة غير صالح.") }
            return AgentToolCall(name:name,arguments:String(decoding:try JSONSerialization.data(withJSONObject:args),as:UTF8.self))
        }
        return AgentReply(text:object["text"] as? String ?? "",calls:result)
    }
}
