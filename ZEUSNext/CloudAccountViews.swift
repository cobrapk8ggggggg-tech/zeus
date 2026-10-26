import SwiftUI

struct CloudAccountGate<Content: View>: View {
    @ObservedObject private var account = CloudAccount.shared
    let content: () -> Content
    var body: some View {
        Group {
            #if DEBUG
            if CommandLine.arguments.contains("--zeus-native-fixture") || CommandLine.arguments.contains("--zeus-layout-editor") {
                content()
            } else { gated }
            #else
            gated
            #endif
        }
        .task { account.start() }
        .onOpenURL { url in Task { await account.handle(url) } }
    }
    @ViewBuilder private var gated: some View {
        if account.phase == .ready && !account.passwordRecovery { content().id(account.identity?.id) }
        else { CloudWelcomeView(account: account) }
    }
}

private struct CloudWelcomeView: View {
    @ObservedObject var account: CloudAccount
    @State private var emailLink = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var creating = false
    @State private var recovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var moving = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var thermal = ProcessInfo.processInfo.thermalState
    private var animate: Bool { !reduceMotion && !lowPower && scenePhase == .active && !thermal.isSerious }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.025, green: 0.035, blue: 0.08).ignoresSafeArea()
                LinearGradient(colors: [.cyan.opacity(0.2), .indigo.opacity(0.16), .clear],
                               startPoint: moving ? .topLeading : .bottomLeading,
                               endPoint: moving ? .bottomTrailing : .topTrailing)
                    .ignoresSafeArea().accessibilityHidden(true)
                    .animation(animate ? .easeInOut(duration: 12).repeatForever(autoreverses: true) : nil, value: moving)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Image(systemName: "bolt.shield.fill").font(.system(size: 48, weight: .light)).foregroundStyle(.cyan)
                        Text("ZEUS").font(.system(size: 38, weight: .bold, design: .rounded))
                        Text("حسابك، وبروفايلاتك، ومساحة عملك").font(.title3)
                        form
                    }
                    .padding(28).frame(maxWidth: 490)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 28))
                    .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.1)))
                    .padding(24).frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }.scrollDismissesKeyboard(.interactively)
            }.foregroundStyle(.white).tint(.cyan).environment(\.layoutDirection, .rightToLeft).preferredColorScheme(.dark)
        }
        .onAppear { moving = animate }
        .onChange(of: animate) { _, value in moving = value }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in thermal = ProcessInfo.processInfo.thermalState }
    }
    @ViewBuilder private var form: some View {
        if account.phase == .loading { ProgressView("جارٍ فتح حسابك…") }
        else if account.passwordRecovery {
            Text("كلمة مرور جديدة").font(.headline)
            SecureField("", text: $password, prompt: Text("12 حرفًا على الأقل").foregroundColor(.white.opacity(0.6))).textContentType(.newPassword).modifier(CloudInputSurface()).accessibilityLabel("كلمة المرور الجديدة")
            SecureField("", text: $confirmation, prompt: Text("تأكيد كلمة المرور").foregroundColor(.white.opacity(0.6))).textContentType(.newPassword).modifier(CloudInputSurface()).accessibilityLabel("تأكيد كلمة المرور")
            action("حفظ كلمة المرور") { await account.updatePassword(password) }.disabled(password != confirmation || password.isEmpty)
        } else if account.phase == .claim {
            Text(account.identity?.email ?? "").textSelection(.enabled)
            Text("اربط بيانات هذا التثبيت بحسابك. تبقى الملفات المحلية محفوظة؛ لن تُحذف أثناء الربط أو قبل التحقق من نسخة السحابة.")
            action("ربط بيانات الجهاز بهذا الحساب") {
                do { try account.claimLocalData() } catch { account.issue = error.localizedDescription }
            }.accessibilityIdentifier("cloudClaimLocalData")
            Button("استخدام حساب آخر") { Task { await account.signOut() } }
        } else if account.phase == .blocked {
            Text("حماية بيانات الحساب").font(.headline)
            Text(account.issue ?? "تعذر فتح بيانات هذا الحساب.")
            action("العودة لتسجيل الدخول") { await account.signOut() }
        } else {
            Text(recovering ? "استعادة الحساب" : creating ? "إنشاء حساب" : "تسجيل الدخول").font(.headline)
            TextField("", text: $email, prompt: Text("البريد الإلكتروني").foregroundColor(.white.opacity(0.6))).textContentType(.emailAddress).keyboardType(.emailAddress)
                .modifier(CloudInputSurface())
                .accessibilityLabel("البريد الإلكتروني")
                .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("cloudEmail")
            if !recovering {
                SecureField("", text: $password, prompt: Text("كلمة المرور").foregroundColor(.white.opacity(0.6))).textContentType(creating ? .newPassword : .password).modifier(CloudInputSurface()).accessibilityLabel("كلمة المرور").accessibilityIdentifier("cloudPassword")
                if creating { SecureField("", text: $confirmation, prompt: Text("تأكيد كلمة المرور").foregroundColor(.white.opacity(0.6))).textContentType(.newPassword).modifier(CloudInputSurface()) }
            }
            action(recovering ? "إرسال رابط الاستعادة" : creating ? "إنشاء الحساب" : "دخول") {
                if recovering { await account.recover(email: email) }
                else if creating { await account.signUp(email: email, password: password) }
                else { await account.signIn(email: email, password: password) }
            }.disabled(email.isEmpty || (!recovering && password.isEmpty) || (creating && password != confirmation))
                .accessibilityIdentifier("cloudSubmit")
            if !recovering { Button(creating ? "لدي حساب بالفعل" : "إنشاء حساب جديد") { creating.toggle(); password = ""; confirmation = "" } }
            Button(recovering ? "العودة للدخول" : "نسيت كلمة المرور") { recovering.toggle(); creating = false; password = "" }
            DisclosureGroup("تأكيد البريد أو الاستعادة باستخدام رابط الرسالة") {
                Text("انسخ رابط التأكيد من رسالة البريد والصقه هنا إذا لم يفتح التطبيق تلقائيًا.").font(.footnote)
                SecureField("", text: $emailLink, prompt: Text("رابط التأكيد من بريدك").foregroundColor(.white.opacity(0.6))).modifier(CloudInputSurface()).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("رابط تأكيد البريد")
                action("التحقق من الرابط") { await account.verifyEmailLink(emailLink); emailLink = "" }.disabled(emailLink.isEmpty)
            }.font(.subheadline)
            Text("Google سيضاف لاحقًا. الدخول الحالي بالبريد وكلمة المرور.").font(.footnote).foregroundStyle(.white.opacity(0.65))
        }
        if let issue = account.issue, account.phase != .blocked { Text(issue).font(.footnote).foregroundStyle(.orange).textSelection(.enabled) }
        if let notice = account.notice { Text(notice).font(.footnote).foregroundStyle(.mint).textSelection(.enabled) }
        if account.busy { ProgressView().frame(maxWidth: .infinity) }
    }
    private func action(_ title: String, run: @escaping () async -> Void) -> some View {
        Button { Task { await run() } } label: { Text(title).fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 8) }
            .buttonStyle(.borderedProminent).disabled(account.busy)
    }
}

private extension ProcessInfo.ThermalState {
    var isSerious: Bool { self == .serious || self == .critical }
}

private struct CloudInputSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.foregroundColor(.white).padding(.horizontal, 14).padding(.vertical, 12)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.18)))
    }
}

struct CloudPreparedBrowser<Content: View>: View {
    @ObservedObject var sync: BrowserCloudSync
    @State private var switching = false
    @State private var transitionProgress = ""
    @State private var transitionIssue: String?
    let content: () -> Content
    var body: some View {
        Group {
            if sync.prepared { content() }
            else {
                VStack(spacing: 20) {
                    if switching { ProgressView(transitionProgress) }
                    else if let issue = sync.issue {
                        Text(issue).multilineTextAlignment(.center)
                        Button("إعادة محاولة الاستعادة") { Task { await sync.prepare() } }.disabled(sync.busy)
                        Button("الاستعادة بالتشغيل السحابي") {
                            Task {
                                switching = true; transitionIssue = nil
                                defer { switching = false }
                                do {
                                    guard let delegate = NativeCloudAccountAPI.dataDelegate else { throw CloudAccountError.invalidResponse }
                                    try await delegate.restoreUsingCloudExecution { transitionProgress = $0 }
                                    await sync.prepare()
                                } catch { transitionIssue = error.localizedDescription }
                            }
                        }.disabled(sync.busy)
                        Text("يستعيد المحادثات والإعدادات ويُبقي ملفات المشاريع على الخادم، لتوفير مساحة الجهاز.").font(.footnote).foregroundStyle(.secondary)
                        if let transitionIssue { Text(transitionIssue).foregroundStyle(.orange) }
                    } else { ProgressView("جارٍ التحقق من بيانات حسابك…") }
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.task { await sync.prepare() }
    }
}

struct CloudAccountSettingsView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject private var account = CloudAccount.shared
    @ObservedObject private var sync: BrowserCloudSync
    @ObservedObject private var nativeBackup = NativeCloudBackupStatus.shared
    @State private var signOutPrompt = false
    init(model: BrowserModel) { self.model = model; self.sync = model.cloudSync }
    var body: some View {
        Form {
            Section("حساب ZEUS") {
                LabeledContent("البريد", value: account.identity?.email ?? "غير مسجل")
                Text("الحساب يملك بروفايلاتك الدائمة والوكيل المشترك بينها. كلمة مرور البروفايل المحلية مستقلة عن كلمة مرور حساب ZEUS.").font(.footnote)
            }
            Section("مزامنة المتصفح") {
                if sync.busy { ProgressView("جارٍ الحفظ والتحقق…") }
                else { Label(sync.pending ? "توجد بيانات تنتظر الحفظ" : sync.lastSaved == nil ? "لم تحفظ نسخة بعد" : "اكتمل آخر حفظ", systemImage: sync.pending ? "icloud.and.arrow.up" : "checkmark.icloud") }
                if let saved = sync.lastSaved { LabeledContent("آخر نسخة مكتملة") { Text(saved, style: .relative) } }
                Button("الحفظ والتحقق الآن") { Task { await sync.saveNow() } }.disabled(sync.busy || account.phase != .ready)
                    .accessibilityIdentifier("cloudSaveNow")
                if let issue = sync.issue { Text(issue).foregroundStyle(.orange).textSelection(.enabled) }
                Text("النسخة الحالية تشمل البروفايلات الدائمة وإعدادات المتصفح وسجلاته. حالة ملفات الوكيل والأسرار ستظهر منفصلة؛ لا تعتبر بياناتها محفوظة حتى يكتمل نقلها.").font(.footnote)
            }
            Section("نسخة الوكيل وملفات الحساب") {
                if let used = nativeBackup.storageUsed, let limit = nativeBackup.storageLimit {
                    ProgressView(value: Double(used), total: Double(limit))
                    Text("\(ByteCountFormatter.string(fromByteCount: used, countStyle: .file)) من \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))").font(.caption)
                    if used > limit * 8 / 10 { Text("المساحة المتبقية قليلة. يحتفظ الجهاز بالأصول إذا تعذر إكمال الرفع.").font(.footnote).foregroundStyle(.orange) }
                }
                if nativeBackup.busy { ProgressView(nativeBackup.progress) }
                else { Text(nativeBackup.progress.isEmpty ? "لم تُتحقق نسخة الوكيل في هذه الجلسة بعد." : nativeBackup.progress).font(.footnote) }
                if let saved = nativeBackup.saved { LabeledContent("آخر تحقق") { Text(saved, style: .relative) } }
                Button("حفظ الوكيل والملفات والأسرار المشفرة") {
                    Task { await sync.saveNow(); await nativeBackup.save() }
                }.disabled(nativeBackup.busy || sync.busy || account.phase != .ready)
                if let issue = nativeBackup.issue { Text(issue).foregroundStyle(.orange).textSelection(.enabled) }
                Text("يُحفظ الوكيل تلقائيًا بعد انتهاء العمل المحلي. تعذّر رفع ملف أو انتهاء الحصة يُبقي النسخة المحلية ويظهر هنا.").font(.footnote)
            }
            Section("الدخول والأمان") {
                Button("إرسال رابط تغيير كلمة المرور") { Task { await account.recover(email: account.identity?.email ?? "") } }.disabled(account.busy)
                Button("تسجيل خروج هذا الجهاز", role: .destructive) { signOutPrompt = true }
                Text("تسجيل الخروج لا يحذف بيانات السحابة. البيانات التي لم يكتمل رفعها لا تستعاد إذا حذفت التطبيق.").font(.footnote)
                if let issue = account.issue { Text(issue).foregroundStyle(.orange) }
                if let notice = account.notice { Text(notice).foregroundStyle(.secondary) }
            }
        }.navigationTitle("الحساب والمزامنة").task { await nativeBackup.refreshUsage() }
            .confirmationDialog("تسجيل الخروج؟", isPresented: $signOutPrompt) {
                Button("تسجيل الخروج", role: .destructive) { Task { await account.signOut() } }
            } message: { Text(sync.pending ? "توجد تغييرات لم تحفظ سحابيًا بعد. ستبقى محليًا في هذا التثبيت." : "تبقى نسخ الحساب محفوظة في السحابة.") }
    }
}
