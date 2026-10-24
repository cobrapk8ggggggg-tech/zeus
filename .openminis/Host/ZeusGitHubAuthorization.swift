import SwiftUI
import SafariServices

/// GitHub's public-client device grant. Browser navigation stays on HTTPS;
/// there is no HTTP loopback callback for Safari's HTTPS-only mode to block.
@MainActor final class ZeusGitHubAuthorization: ObservableObject {
    static let shared = ZeusGitHubAuthorization()
    struct Presentation: Identifiable {
        let id = UUID()
        let code: String
        let verificationURL: URL
        let expires: Date
    }
    struct Grant {
        let deviceCode: String
        let clientID: String
        let presentation: Presentation
        let interval: Double
    }
    @Published var presentation: Presentation?
    private var cancelled = false
    private let base: URL
    init() { base = URL(string: "https://github.com")! }
    #if DEBUG
    init(fixture: URL) {
        precondition(fixture.host == "127.0.0.1")
        base = fixture
    }
    #endif
    private func request(_ path: String, form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = form.sorted(by: { $0.key < $1.key }).map { $0.key + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count < 100_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ZeusPatch.failure("تعذر قراءة استجابة تسجيل GitHub.") }
        guard (200..<300).contains(http.statusCode) || object["error"] != nil else { throw ZeusPatch.failure("تعذر تسجيل GitHub (HTTP \(http.statusCode)).") }
        return object
    }
    func start(clientID: String, scopes: String?) async throws -> Grant {
        cancelled = false
        let value = try await request("login/device/code", form: ["client_id": clientID, "scope": scopes ?? "repo read:org user:email workflow"])
        if let error = value["error"] as? String { throw failure(error) }
        guard let code = value["device_code"] as? String, !code.isEmpty,
              let userCode = value["user_code"] as? String, !userCode.isEmpty,
              let raw = value["verification_uri"] as? String, let url = URL(string: raw),
              url.scheme == "https", url.host == "github.com", url.path == "/login/device", url.user == nil, url.password == nil,
              let expires = (value["expires_in"] as? NSNumber)?.doubleValue, expires > 0 else { throw ZeusPatch.failure("استجابة تفويض GitHub غير مكتملة أو عنوان التحقق غير صالح.") }
        return Grant(deviceCode: code, clientID: clientID,
                     presentation: Presentation(code: userCode, verificationURL: url, expires: Date().addingTimeInterval(min(expires, 1800))),
                     interval: max(5, (value["interval"] as? NSNumber)?.doubleValue ?? 5))
    }
    func poll(_ grant: Grant, sleep: @escaping (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) async throws -> MCPOAuthController.StoredTokens {
        var interval = grant.interval
        while Date() < grant.presentation.expires {
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            try await sleep(interval)
            guard !cancelled else { throw CancellationError() }
            if Date() >= grant.presentation.expires { break }
            let value = try await request("login/oauth/access_token", form: ["client_id": grant.clientID, "device_code": grant.deviceCode, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
            guard !cancelled else { throw CancellationError() }
            if let error = value["error"] as? String {
                if error == "authorization_pending" { continue }
                if error == "slow_down" { interval = max(interval + 5, (value["interval"] as? NSNumber)?.doubleValue ?? 0); continue }
                throw failure(error)
            }
            guard let token = value["access_token"] as? String, !token.isEmpty else { throw ZeusPatch.failure("لم يُرجع GitHub رمز وصول صالحاً.") }
            let expires = (value["expires_in"] as? NSNumber)?.doubleValue ?? 0
            return .init(accessToken: token, refreshToken: value["refresh_token"] as? String, expiresAt: expires > 0 ? Date().timeIntervalSince1970 + expires : 0)
        }
        throw failure("expired_token")
    }
    func authorize(_ config: MCPOAuthConfig) async throws -> MCPOAuthController.StoredTokens {
        let grant = try await start(clientID: config.clientId, scopes: config.scopes)
        presentation = grant.presentation
        defer { presentation = nil }
        return try await poll(grant)
    }
    func cancel() { cancelled = true }
    private func failure(_ code: String) -> Error {
        switch code {
        case "device_flow_disabled": return ZeusPatch.failure("فعّل Enable Device Flow في إعدادات تطبيق OAuth لدى GitHub، ثم أعد الربط.")
        case "access_denied": return ZeusPatch.failure("أُلغيت موافقة GitHub؛ لم يُربط الحساب.")
        case "expired_token": return ZeusPatch.failure("انتهت صلاحية رمز التحقق. اضغط ربط الحساب لإنشاء رمز جديد.")
        case "incorrect_client_credentials": return ZeusPatch.failure("تحقق من Client ID الخاص بتطبيق GitHub.")
        default: return ZeusPatch.failure("تعذر إكمال تفويض GitHub (\(String(code.prefix(80)))).")
        }
    }
}

struct ZeusGitHubAuthorizationView: View {
    let authorization: ZeusGitHubAuthorization.Presentation
    @State private var showBrowser = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "lock.shield").font(.system(size: 44)).padding(.top, 24)
                Text("ربط حساب GitHub").font(.title2.bold())
                Text("أدخل هذا الرمز في صفحة GitHub للموافقة على ربط حسابك.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text(authorization.code).font(.system(size: 32, weight: .bold, design: .monospaced)).tracking(3).textSelection(.enabled).environment(\.layoutDirection, .leftToRight)
                    .frame(maxWidth: .infinity).padding(24).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                Button { UIPasteboard.general.string = authorization.code; showBrowser = true } label: { Label("نسخ الرمز وفتح GitHub", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity).padding(10) }.buttonStyle(.borderedProminent)
                HStack { ProgressView(); Text("بانتظار موافقتك في GitHub…").font(.callout) }
                Spacer(minLength: 0)
            }.padding(24).background(Color.black).navigationTitle("GitHub").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { ZeusGitHubAuthorization.shared.cancel(); ZeusGitHubAuthorization.shared.presentation = nil } } }
                .sheet(isPresented: $showBrowser) { ZeusGitHubVerificationBrowser(url: authorization.verificationURL).ignoresSafeArea() }
        }.preferredColorScheme(.dark).environment(\.layoutDirection, .rightToLeft)
    }
}
private struct ZeusGitHubVerificationBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
