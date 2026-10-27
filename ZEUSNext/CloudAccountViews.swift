import SwiftUI
import UIKit
import CoreImage

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
    @State private var showingEmailHelp = false
    @FocusState private var focusedField: Field?
    private enum Field { case email, password, confirmation }
    private var showingCredentials: Bool { account.phase != .loading && account.phase != .claim && account.phase != .blocked && !account.passwordRecovery }
    private var formTitle: String { account.passwordRecovery ? "كلمة مرور جديدة" : recovering ? "استعادة الحساب" : creating ? "إنشاء حساب" : "تسجيل الدخول" }

    var body: some View {
        GeometryReader { geometry in
            let cardWidth = geometry.size.width >= 700 ? min(520, geometry.size.width * 0.5) : min(460, geometry.size.width - 40)
            ZStack {
                CloudWelcomeBackground().ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        Image("ZEUS")
                            .resizable().scaledToFill().frame(width: 128, height: 128)
                            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 1))
                            .accessibilityHidden(true)
                        Text("ZEUS").font(.system(size: 42, weight: .bold)).padding(.top, 18)
                        Text("متصفحك ووكيلك، في مكان واحد")
                            .font(.system(size: 20, weight: .medium)).foregroundStyle(.white.opacity(0.68)).padding(.top, 5)
                            .multilineTextAlignment(.center)
                        VStack(spacing: 24) {
                            form
                            if let issue = account.issue, account.phase != .blocked {
                                Label(issue, systemImage: "exclamationmark.circle")
                                    .font(.footnote).foregroundStyle(.white.opacity(0.9)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let notice = account.notice {
                                Text(notice).font(.footnote).foregroundStyle(.white.opacity(0.78)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if account.busy { ProgressView().tint(.white).accessibilityLabel("جارٍ الاتصال") }
                        }
                        .padding(.horizontal, 30).padding(.vertical, 30)
                        .frame(maxWidth: .infinity)
                        .background(Color(white: 0.065).opacity(0.94), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.13), lineWidth: 1))
                        .padding(.top, 46)
                        if showingCredentials { footer.padding(.top, 30) }
                    }
                    .frame(width: cardWidth)
                    .padding(.vertical, 38)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .foregroundStyle(.white).tint(.white)
            .environment(\.layoutDirection, .rightToLeft).preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingEmailHelp) { emailHelp }
    }

    @ViewBuilder private var form: some View {
        if account.phase == .loading {
            ProgressView("جارٍ فتح حسابك…").tint(.white).padding(.vertical, 20)
        } else if account.phase == .claim {
            Text("بيانات جهازك").font(.system(size: 27, weight: .bold))
            Text(account.identity?.email ?? "").font(.subheadline).textSelection(.enabled)
            Text("اربط بيانات هذا التثبيت بحسابك لتتمكن من استعادتها لاحقًا.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.72)).multilineTextAlignment(.center)
            action("ربط بيانات الجهاز بهذا الحساب") {
                do { try account.claimLocalData() } catch { account.issue = error.localizedDescription }
            }.accessibilityIdentifier("cloudClaimLocalData")
            Button("استخدام حساب آخر") { Task { await account.signOut() } }.font(.subheadline)
        } else if account.phase == .blocked {
            Text("حماية بيانات الحساب").font(.system(size: 27, weight: .bold))
            Text(account.issue ?? "تعذر فتح بيانات هذا الحساب.").multilineTextAlignment(.center)
            action("العودة لتسجيل الدخول") { await account.signOut() }
        } else {
            Text(formTitle).font(.system(size: 28, weight: .bold)).padding(.bottom, 6)
            VStack(spacing: 18) {
                if !account.passwordRecovery {
                    input(symbol: "envelope") {
                        TextField("", text: $email, prompt: prompt("البريد الإلكتروني"))
                            .textContentType(.emailAddress).keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focusedField, equals: .email).submitLabel(recovering ? .go : .next)
                            .onSubmit { if recovering { submit() } else { focusedField = .password } }
                            .accessibilityLabel("البريد الإلكتروني").accessibilityIdentifier("cloudEmail")
                    }
                }
                if !recovering || account.passwordRecovery {
                    input(symbol: "lock") {
                        SecureField("", text: $password, prompt: prompt(account.passwordRecovery ? "كلمة المرور الجديدة" : "كلمة المرور"))
                            .textContentType(creating || account.passwordRecovery ? .newPassword : .password)
                            .focused($focusedField, equals: .password).submitLabel(creating || account.passwordRecovery ? .next : .go)
                            .onSubmit { if creating || account.passwordRecovery { focusedField = .confirmation } else { submit() } }
                            .accessibilityLabel("كلمة المرور").accessibilityIdentifier("cloudPassword")
                    }
                    if creating || account.passwordRecovery {
                        input(symbol: "lock.badge.checkmark") {
                            SecureField("", text: $confirmation, prompt: prompt("تأكيد كلمة المرور"))
                                .textContentType(.newPassword).focused($focusedField, equals: .confirmation).submitLabel(.go)
                                .onSubmit { submit() }.accessibilityLabel("تأكيد كلمة المرور")
                        }
                    }
                }
            }
            action(account.passwordRecovery ? "حفظ كلمة المرور" : recovering ? "إرسال رابط الاستعادة" : creating ? "إنشاء الحساب" : "دخول") {
                await authenticate()
            }
            .disabled(!credentialsValid).accessibilityIdentifier("cloudSubmit")
            .padding(.top, 6)
            if !recovering && !account.passwordRecovery {
                HStack(spacing: 14) {
                    Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                    Text("أو").font(.system(size: 16)).foregroundStyle(.white.opacity(0.45))
                    Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                }.padding(.vertical, 2)
                Button { account.notice = "الدخول باستخدام Google سيُضاف لاحقًا. استخدم البريد وكلمة المرور حاليًا." } label: {
                    HStack(spacing: 13) {
                        Text("G").font(.system(size: 28, weight: .bold)).accessibilityHidden(true)
                        Text("المتابعة باستخدام Google").font(.system(size: 20, weight: .bold))
                        Text("لاحقًا").font(.system(size: 10, weight: .semibold)).foregroundStyle(.black.opacity(0.55))
                    }
                    .foregroundStyle(.black).frame(maxWidth: .infinity, minHeight: 64)
                    .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("المتابعة باستخدام Google، ستتوفر لاحقًا")
                .accessibilityIdentifier("cloudGoogleDeferred")
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 18) {
            if recovering {
                Button("العودة إلى تسجيل الدخول") { recovering = false; password = "" }
                    .font(.system(size: 18, weight: .semibold))
            } else {
                HStack(spacing: 4) {
                    Text(creating ? "لديك حساب بالفعل؟" : "ليس لديك حساب؟").foregroundStyle(.white.opacity(0.68))
                    Button(creating ? "تسجيل الدخول" : "إنشاء حساب جديد") {
                        creating.toggle(); password = ""; confirmation = ""; account.issue = nil
                    }.fontWeight(.bold).foregroundStyle(Color(red: 0.33, green: 0.51, blue: 0.75))
                }.font(.system(size: 18))
            }
            HStack(spacing: 18) {
                if !recovering {
                    Button("نسيت كلمة المرور؟") { recovering = true; creating = false; password = ""; account.issue = nil }
                }
                Button("مساعدة تأكيد البريد") { showingEmailHelp = true }
            }.font(.system(size: 13)).foregroundStyle(.white.opacity(0.48))
        }.multilineTextAlignment(.center)
    }
    private func prompt(_ value: String) -> Text { Text(value).foregroundColor(.white.opacity(0.67)) }
    private func input<Content: View>(symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 20, weight: .regular)).frame(width: 24).foregroundStyle(.white.opacity(0.65)).accessibilityHidden(true)
            content().font(.system(size: 20)).multilineTextAlignment(.trailing).environment(\.layoutDirection, .leftToRight)
        }
        .foregroundStyle(.white).padding(.horizontal, 18).frame(minHeight: 64)
        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }
    private var credentialsValid: Bool {
        if account.passwordRecovery { return password.count >= 12 && password == confirmation }
        return !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (recovering || (!password.isEmpty && (!creating || password == confirmation)))
    }
    private func submit() {
        guard credentialsValid, !account.busy else { return }
        Task { await authenticate() }
    }
    private func authenticate() async {
        focusedField = nil
        if account.passwordRecovery { await account.updatePassword(password) }
        else if recovering { await account.recover(email: email.trimmingCharacters(in: .whitespacesAndNewlines)) }
        else if creating { await account.signUp(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password) }
        else { await account.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password) }
    }
    private func action(_ title: String, run: @escaping () async -> Void) -> some View {
        Button { Task { await run() } } label: {
            Text(title).font(.system(size: 23, weight: .bold)).frame(maxWidth: .infinity, minHeight: 64)
        }.buttonStyle(CloudLoginButtonStyle()).disabled(account.busy)
    }
    private var emailHelp: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Text("انسخ رابط التأكيد من رسالة البريد والصقه هنا إذا لم يفتح التطبيق تلقائيًا.")
                    .foregroundStyle(.white.opacity(0.75))
                input(symbol: "link") {
                    SecureField("", text: $emailLink, prompt: prompt("رابط التأكيد من بريدك"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("رابط تأكيد البريد")
                }
                action("التحقق من الرابط") {
                    await account.verifyEmailLink(emailLink)
                    if account.issue == nil { emailLink = ""; showingEmailHelp = false }
                }.disabled(emailLink.isEmpty)
                if let issue = account.issue { Text(issue).font(.footnote).foregroundStyle(.white.opacity(0.8)) }
                Spacer()
            }
            .padding(26).background(.black).navigationTitle("تأكيد البريد")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { showingEmailHelp = false } } }
        }
        .foregroundStyle(.white).tint(.white).preferredColorScheme(.dark).environment(\.layoutDirection, .rightToLeft)
        .presentationDetents([.medium, .large])
    }
}

private struct CloudLoginButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white)
            .background(Color(white: configuration.isPressed ? 0.27 : 0.21), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.38), lineWidth: 1))
    }
}

/// The homepage image is rasterized and blurred once at 384 px, rather than
/// continuously filtering a full-screen image while the keyboard or form updates.
@MainActor private enum CloudWelcomeArtwork {
    static let background: UIImage? = {
        guard let image = UIImage(named: "ZEUS") else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let size = CGSize(width: 384, height: 384 * image.size.height / max(1, image.size.width))
        let thumbnail = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.black.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let input = CIImage(image: thumbnail) else { return thumbnail }
        let blurred = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 7])
            .cropped(to: input.extent)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let result = context.createCGImage(blurred, from: input.extent) else { return thumbnail }
        return UIImage(cgImage: result)
    }()
}

private struct CloudWelcomeBackground: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let background = CloudWelcomeArtwork.background {
                    Image(uiImage: background).resizable().scaledToFit()
                        .frame(width: max(geometry.size.width * 1.35, geometry.size.height * 0.95))
                        .opacity(0.40)
                        .position(x: geometry.size.width * 0.46, y: geometry.size.height * 0.52)
                }
                LinearGradient(colors: [.black.opacity(0.25), .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            }.clipped()
        }.allowsHitTesting(false).accessibilityHidden(true)
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
