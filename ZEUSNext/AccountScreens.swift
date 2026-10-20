import SwiftUI
import PhotosUI
import UIKit

struct AccountAvatar: View {
    let profile: BrowserProfile
    let store: ProfileStore
    var size: CGFloat = 54
    var body: some View {
        Group {
            if let url = store.avatarURL(profile), let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: profile.role == .guest ? "person.crop.circle.badge.questionmark" : profile.symbol).resizable().scaledToFit().padding(size * 0.15) }
        }.frame(width: size, height: size).clipShape(Rectangle()).overlay(Rectangle().stroke(.white.opacity(0.2)))
    }
}

struct ProfilesSheet: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject private var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var name = ""
    @State private var selectedRole: AccountRole = .standard
    @State private var editing: BrowserProfile?
    @State private var deleting: BrowserProfile?
    @State private var login: BrowserProfile?
    @State private var password = ""
    @State private var failure: String?
    @State private var busy = false
    init(model: BrowserModel) { self.model = model; store = model.profiles }
    var body: some View {
        NavigationStack {
            List {
                Section("الحساب الرئيسي") {
                    ForEach(store.profiles.filter { $0.isAdmin }) { profile in accountRow(profile) }
                }
                Section("الحسابات") {
                    ForEach(store.profiles.filter { $0.role == .standard && $0.account?.enabled != false }) { profile in accountRow(profile) }.onMove { store.moveStandardAccounts(from: $0, to: $1) }
                }
                if store.profiles.contains(where: { [.guest, .kiosk].contains($0.role) && $0.account?.enabled == true }) {
                    Section("ضيف وكشك") { ForEach(store.profiles.filter { [.guest, .kiosk].contains($0.role) && $0.account?.enabled == true }) { profile in accountRow(profile) } }
                }
                if model.profile.isAdmin && !model.requiresUnlock {
                    Section("إدارة الحسابات") {
                        Button("إضافة حساب", systemImage: "person.badge.plus") { creating = true }.accessibilityIdentifier("addProfileButton")
                        special(.guest); special(.kiosk)
                    }
                }
                if !model.requiresUnlock {
                    Section { Button("تسجيل الخروج", systemImage: "rectangle.portrait.and.arrow.right") { model.logout() } }
                }
                if let failure { Section { Text(failure).font(.footnote) } }
            }.scrollContentBackground(.hidden).background(.black).navigationTitle("الحسابات").navigationBarTitleDisplayMode(.inline)
                .toolbar { if !model.requiresUnlock { ToolbarItem(placement: .topBarTrailing) { Button("تم") { dismiss() } } } }
                .fullScreenCover(isPresented: $creating) { createAccount }
                .fullScreenCover(item: $editing) { SettingsSheet(model: model, profile: $0) }
                .alert("تسجيل الدخول إلى \(login?.name ?? "")", isPresented: Binding(get: { login != nil }, set: { if !$0 { login = nil } })) {
                    SecureField("كلمة المرور", text: $password)
                    Button("دخول") { if let target = login { attempt(target, password: password) }; login = nil; password = "" }
                    Button("إلغاء", role: .cancel) { login = nil; password = "" }
                }
                .confirmationDialog("حذف الحساب وبياناته؟", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) { Button("حذف نهائي", role: .destructive) { if let target = deleting { Task { await model.deleteProfile(target) } }; deleting = nil } }
                .disabled(busy).overlay { if busy { ProgressView().padding(25).glassSurface() } }
        }.tint(.white).preferredColorScheme(.dark)
    }
    private func accountRow(_ profile: BrowserProfile) -> some View {
        HStack(spacing: 14) {
            Button { if AccountVault.exists(profile.id) { password = ""; login = profile } else { attempt(profile, password: "") } } label: {
                HStack(spacing: 14) {
                    AccountAvatar(profile: profile, store: store, size: 70)
                    VStack(alignment: .leading, spacing: 5) { Text(profile.name).font(.headline); Text(profile.role.title).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if AccountVault.exists(profile.id) || profile.locked { Image(systemName: "lock") }
                    if !model.requiresUnlock && model.profile.id == profile.id { Image(systemName: "checkmark") }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("profile-" + profile.name)
            if !model.requiresUnlock && (model.profile.id == profile.id || model.profile.isAdmin && !AccountVault.exists(profile.id)) {
                Button { editing = profile } label: { Image(systemName: "info.circle").frame(width: 40, height: 44) }.buttonStyle(.borderless).accessibilityLabel("إعدادات " + profile.name)
            }
        }.frame(minHeight: 88).listRowBackground(Color.black).listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 12))
            .swipeActions { if model.profile.isAdmin && !model.requiresUnlock && profile.role == .standard { Button("حذف", role: .destructive) { deleting = profile } } }
    }
    private func attempt(_ target: BrowserProfile, password: String) {
        busy = true; failure = nil
        Task {
            await model.switchProfile(to: target, password: password)
            busy = false
            if model.profile.id == target.id && !model.requiresUnlock { dismiss() }
            else { failure = model.notice?.text ?? "تعذر تسجيل الدخول."; model.notice = nil }
        }
    }
    private func special(_ role: AccountRole) -> some View {
        Toggle(role == .guest ? "تفعيل حساب الضيف" : "تفعيل حساب الكشك", isOn: Binding(get: { store.profiles.first { $0.role == role }?.account?.enabled == true }, set: { enabled in
            if var existing = store.profiles.first(where: { $0.role == role }) { existing.account?.enabled = enabled; store.update(existing) }
            else if enabled {
                var profile = store.add(name: role.title, accent: "white", isPrivate: role == .guest)
                profile.account = AccountOptions(role: role, allowScripts: false, allowDeveloperTools: false, allowSettings: role != .kiosk)
                store.update(profile)
            }
        }))
    }
    private var createAccount: some View {
        NavigationStack {
            Form { Section("الحساب الجديد") { TextField("اسم الحساب", text: $name).accessibilityIdentifier("profileNameField") } }.scrollContentBackground(.hidden).background(.black).navigationTitle("إضافة حساب")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { creating = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("إنشاء") { var target = store.add(name: name, accent: "white", isPrivate: false); target.account = AccountOptions(); store.update(target); name = ""; creating = false; editing = target }.accessibilityIdentifier("createProfileButton") }
                }
        }.tint(.white).preferredColorScheme(.dark)
    }
}

struct AccountSettingsView: View {
    @ObservedObject var model: BrowserModel
    @State var profile: BrowserProfile
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showCurrentUserAvatar") private var showCurrentUserAvatar = true
    @State private var photo: PhotosPickerItem?
    @State private var camera = false
    @State private var passwordScreen = false
    @State private var deleting = false
    @State private var issue: String?
    private var options: AccountOptions { profile.account ?? AccountOptions() }
    private var canAdminister: Bool { model.profile.isAdmin && !model.requiresUnlock }
    var body: some View {
        Group { if embedded { accountForm } else { NavigationStack { accountForm } } }.tint(.white).preferredColorScheme(.dark)
    }
    private var accountForm: some View {
            Form {
                Section {
                    HStack { AccountAvatar(profile: profile, store: model.profiles, size: 70); Text("صورة الحساب"); Spacer() }.frame(minHeight: 88).listRowBackground(Color.black)
                    TextField("اسم الحساب", text: $profile.name)
                    PhotosPicker(selection: $photo, matching: .images) { Label("اختيار صورة من الألبوم", systemImage: "photo") }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) { Button("التقاط صورة", systemImage: "camera") { camera = true } }
                    Picker("الصورة الرمزية", selection: $profile.symbol) { ForEach(["person.crop.circle.fill", "person.fill", "house.fill", "briefcase.fill", "book.fill", "star.fill"], id: \.self) { Image(systemName: $0).tag($0) } }
                    if options.avatarFilename != nil { Button("إزالة الصورة") { if let file = model.profiles.avatarURL(profile) { try? FileManager.default.removeItem(at: file) }; profile.account?.avatarFilename = nil } }
                } header: { Text("هذا الحساب") } footer: { Text(profile.role.title) }
                .disabled(profile.role == .guest && !canAdminister)
                Section("حماية الحساب") {
                    if profile.role != .guest { Button("كلمة مرور الحساب", systemImage: "key") { passwordScreen = true } }
                    Picker("تسجيل الخروج بعد مغادرة التطبيق", selection: option(\.logoutAfter)) { Text("أبدًا").tag(Double(-1)); Text("فورًا").tag(Double(0)); Text("دقيقة").tag(Double(60)); Text("5 دقائق").tag(Double(300)); Text("10 دقائق").tag(Double(600)); Text("30 دقيقة").tag(Double(1800)) }
                    if model.profile.id == profile.id { Button(profile.locked ? "إلغاء قفل الجهاز والبصمة" : "حماية إضافية برمز الجهاز والبصمة") { Task { await model.setProfileLock(!profile.locked); profile = model.profile } } }
                }
                if model.profile.id == profile.id { Section { Button("تسجيل الخروج الآن") { model.logout(); dismiss() } } }
                if canAdminister && profile.isAdmin {
                    Section { Toggle("إظهار صورة الحساب الحالي دائمًا", isOn: $showCurrentUserAvatar) }
                    Section("حسابات أخرى") {
                        ForEach(model.profiles.profiles.filter { [.guest, .kiosk].contains($0.role) }) { account in NavigationLink { AccountSettingsView(model: model, profile: account) } label: { HStack { AccountAvatar(profile: account, store: model.profiles, size: 50); Text(account.name); Spacer(); Text(account.account?.enabled == true ? "مفعّل" : "متوقف").font(.caption) } } }
                    }
                    Section("حسابات المستخدمين") {
                        ForEach(model.profiles.profiles.filter { $0.role == .standard }) { account in
                            if AccountVault.exists(account.id) { Label(account.name + " — سجّل الدخول لتغيير إعداداته", systemImage: "lock") }
                            else { NavigationLink(account.name) { AccountSettingsView(model: model, profile: account) } }
                        }
                    }
                }
                if canAdminister && !profile.isAdmin {
                    Section("الصلاحيات") {
                        if [.guest, .kiosk].contains(profile.role) { Toggle("تفعيل الحساب", isOn: option(\.enabled)) }
                        Toggle("التنزيلات", isOn: option(\.allowDownloads)); Toggle("السكربتات", isOn: option(\.allowScripts)); Toggle("أدوات المطور", isOn: option(\.allowDeveloperTools)); Toggle("تغيير إعدادات التصفح", isOn: option(\.allowSettings))
                        TextField("صفحة البداية", text: option(\.homePage)).textInputAutocapitalization(.never).keyboardType(.URL)
                        TextField("المواقع المسموحة، نطاق في كل سطر", text: Binding(get: { options.allowedDomains.joined(separator: "\n") }, set: { profile.account = options; profile.account?.allowedDomains = $0.components(separatedBy: .whitespacesAndNewlines).filter { FilterRules.validDomain($0) } }), axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("اترك قائمة المواقع فارغة للسماح بجميع النطاقات. قيد المواقع ينطبق على التنقلات؛ لا يعزل موارد المواقع الفرعية.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("إعدادات الحساب") {
                    if model.profile.id == profile.id {
                        NavigationLink("واجهة المستخدم والأشرطة") { AppearanceSettings(model: model) }
                        NavigationLink("المفضلة والسجل") { LibrarySheet(model: model) }
                        NavigationLink("التنزيلات") { DownloadsSheet(model: model) }
                        NavigationLink("السكربتات") { ScriptsSheet(model: model) }
                    } else {
                        NavigationLink("إعدادات التصفح لهذا الحساب") { AccountDefaultsEditor(model: model, profile: profile) }
                    }
                }
                if canAdminister && !profile.isAdmin { Section { Button("حذف الحساب وبياناته", role: .destructive) { deleting = true } } }
                if let issue { Text(issue).font(.caption) }
            }.scrollContentBackground(.hidden).background(.black).navigationTitle("إعدادات الحساب").navigationBarTitleDisplayMode(.inline)
                .toolbar { if !embedded { ToolbarItem(placement: .topBarTrailing) { Button("تم") { dismiss() } } } }
                .onChange(of: profile) { _, value in if !value.name.trimmingCharacters(in: .whitespaces).isEmpty { model.profiles.update(value) } }
                .onChange(of: photo) { _, value in Task { if let data = try? await value?.loadTransferable(type: Data.self), let image = UIImage(data: data) { saveImage(image) } } }
                .fullScreenCover(isPresented: $camera) { CameraPicker { if let image = $0 { saveImage(image) }; camera = false }.ignoresSafeArea() }
                .fullScreenCover(isPresented: $passwordScreen) { AccountPasswordView(profile: profile) }
                .confirmationDialog("حذف الحساب وكل ملفاته؟", isPresented: $deleting) { Button("حذف نهائي", role: .destructive) { Task { await model.deleteProfile(profile); dismiss() } } }
    }
    private func option<T>(_ key: WritableKeyPath<AccountOptions, T>) -> Binding<T> {
        Binding(get: { options[keyPath: key] }, set: { value in var updated = options; updated[keyPath: key] = value; profile.account = updated })
    }
    private func saveImage(_ image: UIImage) {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
        let thumbnail = renderer.image { _ in let side = max(256 / image.size.width, 256 / image.size.height); let size = CGSize(width: image.size.width * side, height: image.size.height * side); image.draw(in: CGRect(x: (256-size.width)/2, y: (256-size.height)/2, width: size.width, height: size.height)) }
        guard let data = thumbnail.jpegData(compressionQuality: 0.85) else { return }
        do { let folder = model.profiles.configurationFolder(profile); try BrowserDisk.ensure(folder); try data.write(to: folder.appendingPathComponent("avatar.jpg"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); var updated = options; updated.avatarFilename = "avatar.jpg"; profile.account = updated; model.profiles.update(profile) }
        catch { issue = error.localizedDescription }
    }
}

struct AccountPasswordView: View {
    let profile: BrowserProfile
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var issue: String?
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                if AccountVault.exists(profile.id) { SecureField("كلمة المرور الحالية", text: $current) }
                SecureField("كلمة المرور الجديدة", text: $password); SecureField("تأكيد كلمة المرور", text: $confirmation)
                Text("اترك كلمة المرور الجديدة فارغة لإزالة الحماية بعد إدخال الحالية. الحساب الرئيسي لا يتجاوز كلمة مرور حسابك.").font(.footnote)
                if let issue { Text(issue) }
                Button("حفظ") { busy = true; Task { defer { busy = false }; guard password == confirmation else { issue = "كلمتا المرور غير متطابقتين."; return }; if AccountVault.exists(profile.id), !(await AccountVault.verify(current, id: profile.id)) { issue = "كلمة المرور الحالية غير صحيحة."; return }; do { try await AccountVault.set(password, id: profile.id); dismiss() } catch { issue = error.localizedDescription } } }.disabled(busy)
            }.scrollContentBackground(.hidden).background(.black).navigationTitle("كلمة مرور الحساب").toolbar { Button("إلغاء") { dismiss() } }
        }.tint(.white).preferredColorScheme(.dark)
    }
}

struct AccountDefaultsEditor: View {
    let model: BrowserModel
    let profile: BrowserProfile
    @State private var data = ProfileData()
    @State private var message: String?
    var body: some View {
        Form {
            Section("التصفح") { Picker("محرك البحث", selection: $data.settings.searchProvider) { ForEach(SearchProvider.allCases) { Text($0.rawValue).tag($0) } }; Toggle("سطح المكتب", isOn: $data.settings.desktopMode) }
            Section("الحماية") { Toggle("حجب الإعلانات", isOn: $data.settings.shieldsEnabled); Toggle("إخفاء مواضع الإعلانات", isOn: $data.settings.cosmeticFiltering) }
            Section("الواجهة") { Picker("التوزيع", selection: Binding(get: { data.settings.chromeLayout ?? .original }, set: { data.settings.chromeLayout = $0 })) { ForEach(ChromeLayout.allCases) { Text($0.title).tag($0) } } }
            Button("حفظ إعدادات الحساب") { do { if profile.isPrivate { try model.profiles.saveTemplate(data, profile: profile) } else { model.profiles.save(data, for: profile) }; message = "حُفظت الإعدادات." } catch { message = error.localizedDescription } }
            if let message { Text(message) }
        }.scrollContentBackground(.hidden).background(.black).navigationTitle(profile.name).task { data = profile.isPrivate ? model.profiles.guestTemplate(profile) : model.profiles.load(profile) }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var completion: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController { let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator; return picker }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (UIImage?) -> Void
        init(completion: @escaping (UIImage?) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { completion(info[.originalImage] as? UIImage) }
    }
}

struct AppearanceSettings: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        Form {
            Section("توزيع الأشرطة") { ForEach(ChromeLayout.allCases) { layout in Button { model.data.settings.chromeLayout = layout; model.chromeHidden = false; model.persist() } label: { HStack { Text(layout.title); Spacer(); if (model.data.settings.chromeLayout ?? .original) == layout { Image(systemName: "checkmark") } } }.accessibilityIdentifier("layout-" + layout.rawValue) } }
            Section { Text("الأوامر نفسها في التوزيعات الثلاثة. في ZEUS الأصلي اسحب من اليمين للأدوات ومن الأعلى للتبويبات. الشريطان يختفيان عند التمرير للأسفل ويعودان عند التمرير للأعلى. قائمة الأدوات تتيح جميع الأوامر في كل توزيع.").font(.footnote) }
        }.scrollContentBackground(.hidden).background(.black).navigationTitle("واجهة المستخدم")
    }
}
