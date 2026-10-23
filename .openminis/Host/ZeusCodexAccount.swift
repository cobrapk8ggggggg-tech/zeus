import SwiftUI

struct ZeusCodexAccountView: View {
    @State private var key = ""
    @State private var state: [String: Any] = [:]
    @State private var models: [[String: Any]] = []
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        Form {
            Section("حساب Codex المستقل") {
                Button("تسجيل الدخول بحساب ChatGPT") { Task { await login("chatgptDeviceCode") } }.disabled(busy)
                if let url = state["verificationUrl"] as? String, let link = URL(string: url), link.scheme == "https" { Link("فتح صفحة تسجيل الدخول", destination: link) }
                if let code = state["userCode"] as? String { Text(code).font(.title.monospaced()).textSelection(.enabled) }
                Text(["pending": "بانتظار تسجيل الدخول", "completed": "تم تسجيل الدخول", "configured": "تم حفظ المفتاح", "expired": "انتهت صلاحية الرمز", "failed": "تعذر تسجيل الدخول"][state["status"] as? String ?? ""] ?? "")
                Button("تحديث حالة الدخول") { Task { state = (try? await ZeusProjects.shared.object("v1/account/login")) ?? [:] } }
            }
            Section("مفتاح OpenAI API") {
                SecureField("المفتاح", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("حفظ في محرك Codex") { Task { await login("apiKey") } }.disabled(busy || key.isEmpty)
            }
            Section("النماذج المتاحة للحساب") {
                Button("جلب النماذج") { Task { await loadModels() } }.disabled(busy)
                ForEach(models, id: \.zeusID) { model in Text(model["displayName"] as? String ?? model["model"] as? String ?? model.zeusID) }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("حساب Codex")
    }
    private func login(_ type: String) async {
        busy = true; defer { busy = false }
        do {
            state = try await ZeusProjects.shared.object("v1/account/login", method: "POST", body: ["type": type, "apiKey": key])
            key = ""; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func loadModels() async {
        busy = true; defer { busy = false }
        do {
            let response = try await ZeusProjects.shared.object("v1/models")
            models = response["data"] as? [[String: Any]] ?? []; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
