#if ZEUS_NATIVE_HOST
import Foundation

@MainActor enum NativeBrowserControl {
    static let tools: [BrowserAgentTools.Tool] = [
        .init(name: "browser_help", title: "دليل ZEUS Browser", description: "Read the actual ZEUS interface/feature guide and live context; distinguishes user browser from automation browser.", properties: [:], required: []),
        .init(name: "browser_settings", title: "إعدادات المتصفح", description: "Read all current browser settings and editable key paths, or set ONE key to a JSON-encoded value. Always read first to discover exact keys/types/enums. Supports nested keys such as advanced.forceDarkWebPages. Provider credentials are excluded. Changes persist and may reload pages.", properties: ["action": ["type": "string", "enum": ["read", "set"]], "key": ["type": "string"], "value": ["type": "string", "description": "JSON literal encoded as text: true, 1.2, or a quoted string. Discover shape with action=read."]], required: ["action"]),
        .init(name: "browser_profiles", title: "إدارة البروفايلات", description: "List profiles, create a standard/private profile (admin only), update an allowed profile property, switch, or delete (admin only). Password/biometric locked profiles require the user's normal unlock; never bypass. Switching invalidates this tool context: reopen AI panel for further actions. Read list for exact profile_id and editable keys first.", properties: ["action": ["type": "string", "enum": ["list", "create", "update", "switch", "delete"]], "profile_id": ["type": "string"], "name": ["type": "string"], "private": ["type": "boolean"], "key": ["type": "string"], "value": ["type": "string"]], required: ["action"])
    ]
    static func execute(_ operation: String, args: [String: Any], browser: BrowserModel) async throws -> String {
        if operation == "browser_help" {
            return try NativeBrowserInspector.encode([
                "identity": "ZEUS Browser; Zeus is the integrated assistant. You are chatting inside its AI panel.",
                "activeProfile": ["id": browser.profile.id.uuidString, "name": browser.profile.name, "role": browser.profile.role.rawValue],
                "layout": (browser.data.settings.chromeLayout ?? .original).rawValue,
                "currentTab": browser.current.map { ["id": $0.id.uuidString, "title": $0.title, "url": $0.url] } ?? [:],
                "browsers": ["zeus_browser": "User browser, actual open tabs and per-profile site sessions", "browser_use": "Separate automation browser, separate tabs/cookies, background research"],
                "interface": [
                    "Original": "Swipe down from the top for tabs; pull tools from the right. Related tools are grouped in menus.",
                    "iCab": "Address/navigation toolbar, tools/bookmarks and tab strip; manual hide stays hidden until the side triangle is pressed. Profile button opens compact selector; account/settings button opens profile settings.",
                    "Top/bottom": "Address/profile controls above; navigation/actions below; scroll hides/shows chrome.",
                    "tabs": "Site icons, long-press menus, drag reorder, colored collapsible tab folders, persisted strip scroll position.",
                    "assistant": "Sparkles opens original native agent UI. iPhone fullscreen; iPad real left split with expand/close. AI conversations/providers/memory are global; website sessions are profile-isolated."
                ],
                "features": [
                    "Reader": "Full-screen article reader with RTL, fonts, text opacity and custom foreground/background settings.",
                    "Gallery": "Full-screen extracted image gallery.",
                    "Translation": "Google/AI/Cloudflare providers, target language and RTL, visible-text priority, background pretranslation, persisted cache and auto-translate settings.",
                    "Shields": "Original injected ad/popup protection; optional backup rules and per-site exceptions.",
                    "Downloads": "Native file downloads, progress, Wi-Fi/concurrency preferences and Files sharing.",
                    "Developer tools": "DOM, JavaScript, console, cookies, origin storage and Resource Timing. iOS WebKit does not expose all Chrome network headers/bodies.",
                    "Profiles": "Admin/standard/guest/kiosk, avatars, password/biometric locks, per-profile browsing/site data and capability restrictions.",
                    "Settings sections": "Account, interface/themes/layouts, tabs, launch, privacy, personal data/storage, websites, network, tools, services/transfer, other, help, translation and native AI settings.",
                    "Storage": "Granular site-data deletion, caches, history/searches, downloads and backups; browser backup JSON does not include all authenticated website sessions or native AI secrets.",
                    "Native agent": "Original chat/Markdown/code rendering, streaming, tool cards, providers/API keys/OAuth, model groups, usage, skills, memory, identity, MCP, terminal and file browser. Permissions have three global modes under AI Settings > Permissions."
                ],
                "configuration": "Read browser_settings for live full keys and values. Read browser_profiles for profiles and role-limited editable keys. Native agent preferences are managed with minis-config when its setting is enabled; technical command names remain compatible. Never invent settings or capabilities."
            ])
        }
        if operation == "browser_settings" {
            guard browser.profile.account?.allowSettings != false else { throw AccountError.permission }
            var settings = browser.data.settings
            settings.advanced = settings.advanced ?? AdvancedSettings()
            settings.theme = settings.theme ?? .standard
            settings.reading = settings.reading ?? ReadingPreferences()
            settings.translation = settings.translation ?? TranslationPreferences()
            settings.chromeLayout = settings.chromeLayout ?? .original
            var object = try json(settings)
            object.removeValue(forKey: "aiProviders") // Credentials/configs use native provider UI.
            if args["action"] as? String == "read" {
                return try NativeBrowserInspector.encode(["profile_id": browser.profile.id.uuidString,
                    "settings": object, "keys": paths(object),
                    "optionalSections": "theme, reading, translation, chromeLayout: use current values when present; do not invent enum values. All writes are JSONDecoder-validated before persistence."])
            }
            let key = args["key"] as? String ?? ""
            guard !key.isEmpty, !key.hasPrefix("aiProviders"), let raw = args["value"] as? String else { throw AgentFailure.message("Set requires key and value as JSON text; read settings first.") }
            let value = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])
            try set(&object, path: key.split(separator: ".").map(String.init), value: value)
            if let providers = browser.data.settings.aiProviders { object["aiProviders"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(providers)) }
            let updated = try JSONDecoder().decode(BrowserSettings.self, from: JSONSerialization.data(withJSONObject: object))
            guard updated.textScale.isFinite, (0.5...3).contains(updated.textScale),
                  updated.theme?.isValid != false,
                  (8...72).contains(updated.reading?.fontSize ?? 20),
                  (0.1...1).contains(updated.reading?.textOpacity ?? 1),
                  (1...100_000).contains(updated.advanced?.historyLimit ?? 1000),
                  (1...20).contains(updated.advanced?.downloadsWiFiLimit ?? 5),
                  (1...20).contains(updated.advanced?.downloadsCellularLimit ?? 2) else { throw AgentFailure.message("Setting outside allowed range: textScale 0.5–3, historyLimit 1–100000, download concurrency 1–20.") }
            // Commit to disk before changing live browser state.
            var data = browser.data; data.settings = updated
            if !browser.profile.isPrivate { try BrowserDisk.write(data, to: browser.profiles.folder(for: browser.profile).appendingPathComponent("browser.json")) }
            browser.data = data; browser.applySettings()
            return try NativeBrowserInspector.encode(["updated": key, "value": value, "profile_id": browser.profile.id.uuidString])
        }
        let action = args["action"] as? String ?? "list"
        if action == "list" {
            let visible = browser.profile.isAdmin ? browser.profiles.profiles : [browser.profile]
            return try NativeBrowserInspector.encode(["active": browser.profile.id.uuidString, "profiles": try visible.map { try json($0) },
                "editableKeys": ["name", "symbol", "accent", "account.logoutAfter", "account.homePage", "account.enabled", "account.allowDownloads", "account.allowScripts", "account.allowDeveloperTools", "account.allowSettings", "account.allowedDomains"],
                "restrictions": "Only admin can create/delete or alter capability restrictions of other profiles. Role, password, biometrics, private-kind and avatar files require native account controls; never write arbitrary file paths."])
        }
        if action == "create" {
            guard browser.profile.isAdmin, let name = args["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AccountError.permission }
            let created = browser.profiles.add(name: name, accent: "white", isPrivate: args["private"] as? Bool ?? false)
            return try NativeBrowserInspector.encode(try json(created))
        }
        guard let rawID = args["profile_id"] as? String, let id = UUID(uuidString: rawID), var target = browser.profiles.profile(id),
              browser.profile.isAdmin || target.id == browser.profile.id else { throw AccountError.permission }
        if action == "switch" {
            guard !target.requiresPassword, !target.locked else { throw AgentFailure.message("البروفايل محمي. افتحه عبر منتقي البروفايلات أولًا؛ لا تُرسل كلمة المرور إلى النموذج.") }
            await browser.switchProfile(to: target)
            guard browser.profile.id == target.id else { throw AgentFailure.message("لم يتم تبديل البروفايل؛ تحقق من تفعيله وصلاحياته.") }
            return "تم الانتقال إلى \(target.name). سياق المتصفح السابق أُلغي؛ افتح لوحة Zeus من البروفايل الجديد للمتابعة."
        }
        if action == "delete" {
            guard browser.profile.isAdmin, !target.isAdmin, target.id != browser.profile.id else { throw AccountError.permission }
            await browser.deleteProfile(target)
            guard browser.profiles.profile(id) == nil else { throw AgentFailure.message("لم يُحذف البروفايل؛ راجع حالة التخزين.") }
            return "تم حذف البروفايل المحدد وبياناته."
        }
        let key = args["key"] as? String ?? ""
        let personal = ["name", "symbol", "accent", "account.logoutAfter", "account.homePage"]
        let admin = ["account.enabled", "account.allowDownloads", "account.allowScripts", "account.allowDeveloperTools", "account.allowSettings", "account.allowedDomains"]
        guard action == "update", personal.contains(key) || (browser.profile.isAdmin && !target.isAdmin && admin.contains(key)), let raw = args["value"] as? String else { throw AccountError.permission }
        target.account = target.account ?? AccountOptions()
        var object = try json(target)
        try set(&object, path: key.split(separator: ".").map(String.init), value: JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]))
        let updated = try JSONDecoder().decode(BrowserProfile.self, from: JSONSerialization.data(withJSONObject: object))
        guard !updated.name.isEmpty, updated.name.count <= 48, updated.symbol.count <= 120 else { throw AgentFailure.message("Profile name must be 1–48 characters; symbol <=120.") }
        browser.profiles.update(updated); browser.changed()
        return try NativeBrowserInspector.encode(try json(updated))
    }
    private static func json<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:]
    }
    private static func paths(_ object: [String: Any], prefix: String = "") -> [String] {
        object.keys.sorted().flatMap { key -> [String] in
            let path = prefix.isEmpty ? key : prefix + "." + key
            if let child = object[key] as? [String: Any] { return paths(child, prefix: path) }
            return [path]
        }
    }
    private static func set(_ object: inout [String: Any], path: [String], value: Any) throws {
        guard let key = path.first, object[key] != nil else { throw AgentFailure.message("Unknown settings key: \(path.joined(separator: ".")). Read current keys first.") }
        if path.count == 1 { object[key] = value; return }
        guard var child = object[key] as? [String: Any] else { throw AgentFailure.message("Setting is not an object: \(key)") }
        try set(&child, path: Array(path.dropFirst()), value: value); object[key] = child
    }
}
#endif
