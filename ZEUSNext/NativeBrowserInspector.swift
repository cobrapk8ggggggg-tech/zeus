#if ZEUS_NATIVE_HOST
import Foundation
import WebKit

/// Uses the existing tab and its actual WKWebsiteDataStore. This never creates
/// a separate browsing session or changes WebKit's navigation/UI delegates.
@MainActor enum NativeBrowserInspector {
    static let tools: [BrowserAgentTools.Tool] = [
        .init(name: "browser_dom", title: "فحص DOM", description: "Inspect real HTML, computed styles and geometry for a CSS selector in an existing tab. Output is bounded and untrusted.", properties: ["tab_id": ["type": "string"], "selector": ["type": "string"]], required: []),
        .init(name: "browser_evaluate", title: "تنفيذ JavaScript", description: "Execute an async JavaScript function body in the actual page world. Use return to produce a value. May mutate the page; governed by the global tool permission mode.", properties: ["tab_id": ["type": "string"], "code": ["type": "string"]], required: ["code"]),
        .init(name: "browser_cookies", title: "كوكيز الموقع", description: "List (including HttpOnly), set, delete one named cookie, or explicitly clear cookies matching the selected tab's host, in its profile only. Governed by the global tool permission mode. Set accepts name,value,path,secure,http_only,expires (Unix seconds).", properties: ["tab_id": ["type": "string"], "action": ["type": "string", "enum": ["list", "set", "delete", "clear"]], "name": ["type": "string"], "value": ["type": "string"], "path": ["type": "string"], "secure": ["type": "boolean"], "http_only": ["type": "boolean"], "expires": ["type": "number"]], required: ["action"]),
        .init(name: "browser_storage", title: "تخزين الموقع", description: "Read, set, remove or explicitly clear localStorage/sessionStorage for the existing page's origin. Bounded output. Reads may reveal sensitive data and are consequential under the global permission mode.", properties: ["tab_id": ["type": "string"], "area": ["type": "string", "enum": ["local", "session"]], "action": ["type": "string", "enum": ["read", "set", "remove", "clear"]], "key": ["type": "string"], "value": ["type": "string"]], required: ["area", "action"]),
        .init(name: "browser_network", title: "توقيت طلبات الصفحة", description: "Read actual Resource Timing and navigation records for the existing main frame. Includes URLs, initiators, timing, transfer sizes and protocol where WebKit exposes them. This is not a complete HTTP capture: headers, response bodies, workers and WebSocket frames are not exposed by this operation.", properties: ["tab_id": ["type": "string"]], required: []),
        .init(name: "browser_console", title: "سجل الكونسول", description: "Read actual console entries already collected for the selected tab in the active profile. Output is bounded; no messages recorded before instrumentation are invented.", properties: ["tab_id": ["type": "string"]], required: []),
        .init(name: "browser_debug", title: "تفعيل فحص المتصفح", description: "Enable or disable native Web Inspector and console capture in the active profile. Recreates its live web views and reloads the active page; requires approval.", properties: ["enabled": ["type": "boolean"]], required: ["enabled"])
    ]
    static func encode(_ value: Any) throws -> String {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        guard bytes.count <= 300_000 else { throw AgentFailure.message("نتيجة الفحص كبيرة؛ اختر عنصرًا أو مفتاحًا محددًا.") }
        return String(decoding: bytes, as: UTF8.self)
    }
    static func execute(_ operation: String, args: [String: Any], view: WKWebView) async throws -> String {
        switch operation {
        case "browser_dom":
            let value = try await view.callAsyncJavaScript(#"""
            const element=document.querySelector(selector||'html');
            if(!element)return {found:false};
            const box=element.getBoundingClientRect(),style=getComputedStyle(element);
            return {found:true,url:location.href,html:element.outerHTML.slice(0,100000),
              truncated:element.outerHTML.length>100000,rect:{x:box.x,y:box.y,width:box.width,height:box.height},
              styles:Object.fromEntries(['display','position','color','background-color','font-size','direction','visibility','z-index'].map(k=>[k,style.getPropertyValue(k)]))};
            """#, arguments: ["selector": args["selector"] as? String ?? "html"], in: nil, contentWorld: .world(name: "ZEUSInspector"))
            return try encode(value ?? NSNull())
        case "browser_evaluate":
            guard let code = args["code"] as? String, !code.isEmpty, code.utf8.count <= 50_000 else { throw AgentFailure.message("أدخل كود JavaScript أقل من 50 كيلوبايت.") }
            // WKWebView cannot bridge DOM nodes, functions, BigInt or circular
            // objects directly. Serialize inside JS while retaining real errors.
            let script = """
            const result = await (async () => {
            \(code)
            })();
            const seen = new WeakSet();
            return JSON.stringify(result === undefined ? null : result, (key, value) => {
              if (typeof value === 'bigint') return value.toString();
              if (typeof value === 'function') return '[Function]';
              if (value instanceof Node) return {node:value.nodeName,text:(value.textContent||'').slice(0,10000),html:value.outerHTML?.slice(0,20000)};
              if (typeof value === 'object' && value !== null) {
                if (seen.has(value)) return '[Circular]'; seen.add(value);
              }
              return value;
            });
            """
            let value = try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
            let output = value as? String ?? "null"
            guard output.utf8.count <= 300_000 else { throw AgentFailure.message("النتيجة كبيرة؛ أرجع حقولًا محددة أو أجزاء أصغر.") }
            return output
        case "browser_network":
            let value = try await view.callAsyncJavaScript(#"""
            return {url:location.href,coverage:'Main-frame Resource Timing only; no request/response headers or bodies. Cross-origin timings may be redacted by WebKit.',
              navigation:performance.getEntriesByType('navigation').map(e=>e.toJSON()),
              resources:performance.getEntriesByType('resource').slice(-300).map(e=>e.toJSON()),timeOrigin:performance.timeOrigin};
            """#, arguments: [:], in: nil, contentWorld: .world(name: "ZEUSInspector"))
            return try encode(value ?? NSNull())
        case "browser_storage":
            guard let area = args["area"] as? String, ["local", "session"].contains(area),
                  let action = args["action"] as? String, ["read", "set", "remove", "clear"].contains(action) else { throw AgentFailure.message("أمر التخزين غير صالح.") }
            let key = args["key"] as? String ?? "", value = args["value"] as? String ?? ""
            guard key.utf8.count <= 2000, value.utf8.count <= 50_000,
                  !["set", "remove"].contains(action) || !key.isEmpty else { throw AgentFailure.message("حدد مفتاحًا صالحًا وقيمة أقل من 50 كيلوبايت.") }
            let result = try await view.callAsyncJavaScript(#"""
            const store=area==='local'?localStorage:sessionStorage;
            if(action==='set')store.setItem(key,value);
            if(action==='remove')store.removeItem(key);
            if(action==='clear')store.clear();
            const entries=[];let size=0,truncated=false;
            const keys=key?[key]:Object.keys(store);
            for(const k of keys){const v=store.getItem(k);if(v===null)continue;
              if(entries.length>=200||size+k.length+v.length>100000){truncated=true;break;}
              entries.push({key:k,value:v});size+=k.length+v.length;}
            return {origin:location.origin,area,action,entries,truncated};
            """#, arguments: ["area": area, "action": action, "key": key, "value": value], in: nil, contentWorld: .page)
            return try encode(result ?? NSNull())
        case "browser_cookies":
            guard let host = view.url?.host, !host.isEmpty,
                  let action = args["action"] as? String, ["list", "set", "delete", "clear"].contains(action) else { throw AgentFailure.message("حدد موقعًا وأمر كوكيز صالحين.") }
            let store = view.configuration.websiteDataStore.httpCookieStore
            if action == "set" {
                guard let name = args["name"] as? String, !name.isEmpty, name.count <= 1000,
                      let value = args["value"] as? String, value.utf8.count <= 16_000 else { throw AgentFailure.message("اسم الكوكي وقيمته غير صالحين.") }
                var properties: [HTTPCookiePropertyKey: Any] = [.domain: host, .name: name, .value: value, .path: args["path"] as? String ?? "/"]
                if args["secure"] as? Bool ?? (view.url?.scheme == "https") { properties[.secure] = "TRUE" }
                if args["http_only"] as? Bool == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
                if let expiry = args["expires"] as? Double, expiry.isFinite { properties[.expires] = Date(timeIntervalSince1970: expiry) }
                guard let cookie = HTTPCookie(properties: properties) else { throw AgentFailure.message("تعذر إنشاء الكوكي بالخصائص المحددة.") }
                await withCheckedContinuation { continuation in store.setCookie(cookie) { continuation.resume() } }
            }
            let all: [HTTPCookie] = await withCheckedContinuation { continuation in store.getAllCookies { continuation.resume(returning: $0) } }
            let matching = all.filter { BrowserURL.hostMatches(host, domain: $0.domain) }
            if action == "delete" || action == "clear" {
                guard action == "clear" || !(args["name"] as? String ?? "").isEmpty else { throw AgentFailure.message("حدد اسم الكوكي المراد حذفه.") }
                let removed = matching.filter { action == "clear" || $0.name == args["name"] as? String }
                for cookie in removed { await withCheckedContinuation { continuation in store.delete(cookie) { continuation.resume() } } }
                return try encode(["host": host, "action": action, "deleted": removed.count])
            }
            let records: [[String: Any]] = matching.prefix(500).map { cookie in
                ["name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path,
                 "secure": cookie.isSecure, "httpOnly": cookie.isHTTPOnly,
                 "sessionOnly": cookie.isSessionOnly, "expires": cookie.expiresDate.map { $0.timeIntervalSince1970 as Any } ?? NSNull()]
            }
            return try encode(["host": host, "action": action, "cookies": records, "truncated": matching.count > records.count])
        default: throw AgentFailure.message("أداة فحص غير معروفة.")
        }
    }
}
#endif
