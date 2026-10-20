import SwiftUI
import WebKit
import Security

struct SavedForm: Codable, Identifiable {
    var id = UUID()
    var title: String
    var origin: String
    var fieldCount: Int
}
struct SavedFormField: Codable { var selector: String; var type: String; var value: String; var checked: Bool; var index: Int? }
struct FormDraft: Identifiable { let id = UUID(); var profileID: UUID; var origin: String; var title: String; var fields: [SavedFormField] }
enum FormVault {
    private static func query(profileID: UUID, id: UUID? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "tools.zeus.forms." + profileID.uuidString]
        if let id { q[kSecAttrAccount as String] = id.uuidString }; return q
    }
    static func save(_ fields: [SavedFormField], profileID: UUID, id: UUID) throws {
        let q = query(profileID: profileID, id: id); var add = q
        add[kSecValueData as String] = try JSONEncoder().encode(fields); add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw AccountError.keychain }
    }
    static func load(profileID: UUID, id: UUID) -> [SavedFormField]? {
        var q = query(profileID: profileID, id: id); q[kSecReturnData as String] = true
        var output: CFTypeRef?; guard SecItemCopyMatching(q as CFDictionary, &output) == errSecSuccess, let data = output as? Data else { return nil }
        return try? JSONDecoder().decode([SavedFormField].self, from: data)
    }
    static func remove(profileID: UUID, id: UUID? = nil) { SecItemDelete(query(profileID: profileID, id: id) as CFDictionary) }
}
extension BrowserModel {
    func extractForm() {
        guard profile.role != .kiosk, let view = webView, let url = view.url, let origin = Self.origin(url) else { return }
        let owner = profile.id, tabID = current?.id
        let script = #"""
        (()=>Array.from(document.querySelectorAll('input,textarea,select')).filter(e=>!['hidden','file','submit','button','reset'].includes(e.type)&&e.getClientRects().length).slice(0,200).map(e=>{let selector;if(e.id)selector='#'+CSS.escape(e.id);else if(e.name)selector=e.tagName.toLowerCase()+'[name='+CSS.escape(e.name)+']';else{let cur=e,parts=[];while(cur&&cur.parentElement){parts.unshift(cur.tagName.toLowerCase()+':nth-child('+(Array.from(cur.parentElement.children).indexOf(cur)+1)+')');cur=cur.parentElement}selector='html>'+parts.join('>')}return {selector,index:Array.from(document.querySelectorAll(selector)).indexOf(e),type:e.type||e.tagName.toLowerCase(),value:String(e.value||'').slice(0,10000),checked:!!e.checked}}))();
        """#
        view.evaluateJavaScript(script) { [weak self] value, error in
            guard let self, self.profile.id == owner, self.current?.id == tabID else { return }
            do { let data = try JSONSerialization.data(withJSONObject: value ?? []); let fields = try JSONDecoder().decode([SavedFormField].self, from: data); guard !fields.isEmpty else { self.notify("لا توجد حقول نموذج قابلة للحفظ في الصفحة الرئيسية."); return }; self.formDraft = FormDraft(profileID: owner, origin: origin, title: self.current?.title ?? "نموذج", fields: fields) }
            catch { self.notify(error.localizedDescription) }
        }
    }
    static func origin(_ url: URL) -> String? {
        guard BrowserURL.isWeb(url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = ""; parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil; return parts.url?.absoluteString
    }
    func storeForm(_ draft: FormDraft, includePasswords: Bool) throws {
        guard !requiresUnlock, profile.id == draft.profileID else { throw AccountError.permission }
        let fields = draft.fields.filter { includePasswords || $0.type != "password" }
        let item = SavedForm(title: draft.title, origin: draft.origin, fieldCount: fields.count)
        if profile.isPrivate { temporaryFormValues[item.id] = fields } else { try FormVault.save(fields, profileID: profile.id, id: item.id) }
        var forms = data.forms ?? []; forms.append(item); data.forms = forms; persist()
    }
    func fillForm(_ form: SavedForm) {
        guard let view = webView, view.url.flatMap(Self.origin) == form.origin else { notify("يمكن ملء النموذج في مصدره الأصلي فقط (البروتوكول والنطاق والمنفذ)."); return }
        guard let fields = profile.isPrivate ? temporaryFormValues[form.id] : FormVault.load(profileID: profile.id, id: form.id), let raw = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(fields)) else { notify("قيم هذا النموذج غير متاحة."); return }
        view.callAsyncJavaScript("let count=0;for(const field of fields){let e;try{e=document.querySelectorAll(field.selector)[field.index||0]}catch{continue}if(!e||e.type!==field.type)continue;if(['checkbox','radio'].includes(e.type)){e.checked=field.checked}else{const proto=e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:e.tagName==='SELECT'?HTMLSelectElement.prototype:HTMLInputElement.prototype;const setter=Object.getOwnPropertyDescriptor(proto,'value')?.set;if(setter)setter.call(e,field.value);else e.value=field.value}e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));count++}return count;", arguments: ["fields": raw], in: nil, contentWorld: .page) { [weak self] result in
            switch result { case .success(let value): self?.notify("مُلئت \(value as? Int ?? 0) حقول. راجعها قبل إرسال النموذج."); case .failure(let error): self?.notify(error.localizedDescription) }
        }
    }
    func deleteForm(_ form: SavedForm) { FormVault.remove(profileID: profile.id, id: form.id); temporaryFormValues.removeValue(forKey: form.id); data.forms?.removeAll { $0.id == form.id }; persist() }
}
struct FormDraftView: View {
    @ObservedObject var model: BrowserModel
    @State var draft: FormDraft
    @Environment(\.dismiss) private var dismiss
    @State private var includePasswords = false
    @State private var issue: String?
    var body: some View {
        NavigationStack { Form {
            TextField("اسم النموذج", text: $draft.title); Text(draft.origin).font(.caption); Text("\(draft.fields.count) حقل")
            if draft.fields.contains(where: { $0.type == "password" }) { Toggle("تضمين حقول كلمة المرور", isOn: $includePasswords) }
            Text("تُحفظ القيم داخل سلسلة مفاتيح الجهاز، وتُملأ فقط في مصدر الموقع نفسه. في الحساب الخاص تبقى في الذاكرة وتُحذف عند الخروج.").font(.footnote)
            Button("حفظ النموذج") { do { try model.storeForm(draft, includePasswords: includePasswords); dismiss() } catch { issue = error.localizedDescription } }
            if let issue { Text(issue) }
        }.settingsPage("حفظ النموذج").toolbar { Button("إلغاء") { dismiss() } } }.tint(.white).preferredColorScheme(.dark)
    }
}
struct SavedFormsPage: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack { List {
            ForEach(model.data.forms ?? []) { form in Button { model.fillForm(form); dismiss() } label: { VStack(alignment: .leading, spacing: 6) { Text(form.title); Text(form.origin).font(.caption).foregroundStyle(.secondary); Text("\(form.fieldCount) حقل").font(.caption2) } }.buttonStyle(.plain).contextMenu { Button("حذف") { model.deleteForm(form) } } }
            if (model.data.forms ?? []).isEmpty { Text("لا توجد نماذج محفوظة لهذا الحساب.") }
        }.settingsPage("ملء النماذج").toolbar { Button("تم") { dismiss() } } }.tint(.white).preferredColorScheme(.dark)
    }
}
