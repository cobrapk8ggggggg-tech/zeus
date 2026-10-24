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
        .init(name: "browser_indexeddb", title: "فحص IndexedDB", description: "READ-ONLY IndexedDB inspector for the selected real tab and profile. Discover action=databases, then action=stores with database, then action=read with database and store. No JavaScript or schema guessing required. Paginate with offset/limit; optionally filter a key using key_json. Values are bounded previews; binary values are metadata only. May expose credentials: governed by tool permissions. Never creates a database or writes records.", properties: ["tab_id": ["type": "string"], "action": ["type": "string", "enum": ["databases", "stores", "read"]], "database": ["type": "string"], "store": ["type": "string"], "offset": ["type": "integer", "minimum": 0, "maximum": 20000], "limit": ["type": "integer", "minimum": 1, "maximum": 20], "key_json": ["type": "string"]], required: ["action"]),
        .init(name: "browser_network", title: "توقيت طلبات الصفحة", description: "Read actual Resource Timing and navigation records for the existing main frame. Includes URLs, initiators, timing, transfer sizes and protocol where WebKit exposes them. This is not a complete HTTP capture: headers, response bodies, workers and WebSocket frames are not exposed by this operation.", properties: ["tab_id": ["type": "string"]], required: []),
        .init(name: "browser_console", title: "سجل الكونسول", description: "Read actual console entries already collected for the selected tab in the active profile. Output is bounded; no messages recorded before instrumentation are invented.", properties: ["tab_id": ["type": "string"]], required: []),
        .init(name: "browser_debug", title: "تفعيل فحص المتصفح", description: "Enable or disable native Web Inspector and console capture in the active profile. Recreates its live web views and reloads the active page; requires approval.", properties: ["enabled": ["type": "boolean"]], required: ["enabled"])
    ]
    static let indexedDBScript = #"""
    let db, timer, finished=false;
    const deadline = new Promise((_, reject) => { timer=setTimeout(()=>reject(new Error('IndexedDB inspection timed out; the page may be navigating or blocking the database.')),5000); });
    async function inspect() {
      if (!indexedDB.databases) throw new Error('This WebKit version cannot enumerate databases.');
      const databases=await indexedDB.databases();
      if(action==='databases') return {origin:location.origin,databases:databases.map(d=>({name:d.name,version:d.version})),read_only:true};
      if(!databases.some(d=>d.name===database)) throw new Error('Database not found. Discover databases first; nothing was created.');
      db=await new Promise((resolve,reject)=>{
        const req=indexedDB.open(database);
        req.onupgradeneeded=()=>{req.transaction.abort();reject(new Error('Database disappeared; creation was cancelled.'));};
        req.onsuccess=()=>{if(finished){req.result.close();reject(new Error('Inspection already finished.'));}else resolve(req.result);};req.onerror=()=>reject(req.error);req.onblocked=()=>reject(new Error('Database open blocked.'));
      });
      if(action==='stores') return {database,version:db.version,stores:Array.from(db.objectStoreNames).map(name=>{
        const s=db.transaction(name,'readonly').objectStore(name);
        return {name,keyPath:s.keyPath,autoIncrement:s.autoIncrement,indexes:Array.from(s.indexNames)};
      }),read_only:true};
      if(!db.objectStoreNames.contains(store)) throw new Error('Store not found. Discover stores first.');
      const range=keyJSON?IDBKeyRange.only(JSON.parse(keyJSON)):null;
      return await new Promise((resolve,reject)=>{
        const tx=db.transaction(store,'readonly'), request=tx.objectStore(store).openCursor(range);
        let skipped=0;const records=[];
        tx.onabort=()=>reject(tx.error||new Error('Read transaction aborted.'));
        request.onerror=()=>reject(request.error);
        request.onsuccess=()=>{
          const cursor=request.result;
          if(!cursor||records.length===limit){resolve({database,store,offset,records,next_offset:offset+records.length,has_more:!!cursor,read_only:true});return;}
          if(skipped++<offset){cursor.continue();return;}
          const seen=new WeakSet();
          const encoded=JSON.stringify(cursor.value,(_,v)=>{
            if(typeof v==='bigint')return String(v);
            if(v instanceof Blob)return {type:v.type,bytes:v.size,binary_preview_only:true};
            if(v instanceof ArrayBuffer||ArrayBuffer.isView(v))return {bytes:v.byteLength,binary_preview_only:true};
            if(v&&typeof v==='object'){if(seen.has(v))return '[Circular]';seen.add(v);}return v;
          }) ?? 'null';
          const keyEncoded=JSON.stringify(cursor.key), row={key:keyEncoded.length>2000?keyEncoded.slice(0,2000):JSON.parse(keyEncoded),key_truncated:keyEncoded.length>2000,value_preview:encoded.slice(0,4000),value_truncated:encoded.length>4000};
          while(JSON.stringify(row).length>8000&&row.value_preview.length>128){row.value_preview=row.value_preview.slice(0,Math.floor(row.value_preview.length/2));row.value_truncated=true;}
          if(records.length&&JSON.stringify(records).length+JSON.stringify(row).length>10000){resolve({database,store,offset,records,next_offset:offset+records.length,has_more:true,read_only:true});return;}
          records.push(row);cursor.continue();
        };
      });
    }
    try { return await Promise.race([inspect(),deadline]); }
    finally { finished=true;clearTimeout(timer);if(db)db.close(); }
    """#
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
        case "browser_indexeddb":
            guard let action = args["action"] as? String, ["databases", "stores", "read"].contains(action) else { throw AgentFailure.message("اختر databases أو stores أو read.") }
            let database = args["database"] as? String ?? "", store = args["store"] as? String ?? ""
            let offset = args["offset"] as? Int ?? 0, limit = args["limit"] as? Int ?? 10
            guard (action == "databases" || !database.isEmpty), action != "read" || !store.isEmpty,
                  database.utf8.count <= 500, store.utf8.count <= 500, (args["key_json"] as? String ?? "").utf8.count <= 4000,
                  (0...20000).contains(offset), (1...20).contains(limit) else { throw AgentFailure.message("حدد اسم قاعدة البيانات والمخزن من نتيجة الاكتشاف، وحداً من 1 إلى 20 وإزاحة من 0 إلى 20000.") }
            let result = try await view.callAsyncJavaScript(Self.indexedDBScript, arguments: ["action": action, "database": database, "store": store, "offset": offset, "limit": limit, "keyJSON": args["key_json"] as? String ?? ""], in: nil, contentWorld: .page)
            return try encode(result ?? NSNull())
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
