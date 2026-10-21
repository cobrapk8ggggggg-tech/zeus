import SwiftUI
import PhotosUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

struct AccountAvatar: View {
    @Environment(\.browserTheme) private var theme
    let profile: BrowserProfile
    let store: ProfileStore
    var size: CGFloat = 54
    var body: some View {
        Group {
            if let url = store.avatarURL(profile), let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: profile.role == .guest ? "person.crop.circle.badge.questionmark" : profile.symbol).resizable().scaledToFit().padding(size * 0.15) }
        }.frame(width: size, height: size).clipShape(Rectangle()).overlay(Rectangle().stroke(theme.textColor.opacity(0.2)))
    }
}

struct ProfilesSheet: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var model: BrowserModel
    @ObservedObject private var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var createdAccount: BrowserProfile?
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
                ThemedSection("الحساب الرئيسي") {
                    ForEach(store.profiles.filter { $0.isAdmin }) { profile in accountRow(profile) }
                }
                ThemedSection("الحسابات") {
                    ForEach(store.profiles.filter { $0.role == .standard && $0.account?.enabled != false }) { profile in accountRow(profile) }.onMove { store.moveStandardAccounts(from: $0, to: $1) }
                }
                if store.profiles.contains(where: { [.guest, .kiosk].contains($0.role) && $0.account?.enabled == true }) {
                    ThemedSection("ضيف وكشك") { ForEach(store.profiles.filter { [.guest, .kiosk].contains($0.role) && $0.account?.enabled == true }) { profile in accountRow(profile) } }
                }
                if model.profile.isAdmin && !model.requiresUnlock {
                    ThemedSection("إدارة الحسابات") {
                        Button("إضافة حساب", systemImage: "person.badge.plus") { creating = true }.accessibilityIdentifier("addProfileButton")
                        special(.guest); special(.kiosk)
                    }
                }
                if !model.requiresUnlock {
                    ThemedSection { Button("تسجيل الخروج", systemImage: "rectangle.portrait.and.arrow.right") { model.logout() } }
                }
                if let failure { ThemedSection { Text(failure).font(.footnote) } }
            }.scrollContentBackground(.hidden).background(theme.backgroundColor).navigationTitle("الحسابات").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !model.requiresUnlock { ToolbarItem(placement: .topBarTrailing) { Button("تم") { dismiss() } } }
                    if model.profile.isAdmin && !model.requiresUnlock { ToolbarItem(placement: .topBarLeading) { EditButton() } }
                }
                .fullScreenCover(isPresented: $creating, onDismiss: { if let createdAccount { editing = createdAccount; self.createdAccount = nil } }) { createAccount }
                .fullScreenCover(item: $editing) { SettingsSheet(model: model, profile: $0) }
                .alert("تسجيل الدخول إلى \(login?.name ?? "")", isPresented: Binding(get: { login != nil }, set: { if !$0 { login = nil } })) {
                    SecureField("كلمة المرور", text: $password)
                    Button("دخول") { if let target = login { attempt(target, password: password) }; login = nil; password = "" }
                    Button("إلغاء", role: .cancel) { login = nil; password = "" }
                }
                .confirmationDialog("حذف الحساب وبياناته؟", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) { Button("حذف نهائي") { if let target = deleting { Task { await model.deleteProfile(target) } }; deleting = nil } }
                .disabled(busy).overlay { if busy { ProgressView().padding(25).glassSurface() } }
        }.tint(theme.buttonTextColor).preferredColorScheme(theme.light ? .light : .dark)
    }
    private func accountRow(_ profile: BrowserProfile) -> some View {
        HStack(spacing: 14) {
            Button { if profile.requiresPassword { password = ""; login = profile } else { attempt(profile, password: "") } } label: {
                HStack(spacing: 14) {
                    AccountAvatar(profile: profile, store: store, size: 70)
                    VStack(alignment: .leading, spacing: 5) { Text(profile.name).font(.headline); Text(profile.role.title).font(.caption).foregroundStyle(theme.secondaryTextColor) }
                    Spacer()
                    if profile.requiresPassword || profile.locked { Image(systemName: "lock") }
                    if !model.requiresUnlock && model.profile.id == profile.id { Image(systemName: "checkmark") }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("profile-" + profile.name)
            if !model.requiresUnlock && (model.profile.id == profile.id || model.profile.isAdmin && !profile.requiresPassword) {
                Button { editing = profile } label: { Image(systemName: "info.circle").frame(width: 40, height: 44) }.buttonStyle(.borderless).accessibilityLabel("إعدادات " + profile.name)
            }
        }.buttonStyle(.borderless).frame(minHeight: 88).listRowBackground(theme.backgroundColor).listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 12))
            .swipeActions { if model.profile.isAdmin && !model.requiresUnlock && profile.role == .standard { Button("حذف") { deleting = profile } } }
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
            Form { ThemedSection("الحساب الجديد") { TextField("اسم الحساب", text: $name).accessibilityIdentifier("profileNameField") } }.scrollContentBackground(.hidden).background(theme.backgroundColor).navigationTitle("إضافة حساب")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { creating = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("إنشاء") { var target = store.add(name: name, accent: "white", isPrivate: false); target.account = AccountOptions(); store.update(target); name = ""; createdAccount = target; creating = false }.accessibilityIdentifier("createProfileButton") }
                }
        }.tint(theme.buttonTextColor).preferredColorScheme(theme.light ? .light : .dark)
    }
}

struct AccountSettingsView: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var model: BrowserModel
    @State var profile: BrowserProfile
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showCurrentUserAvatar") private var showCurrentUserAvatar = false
    private enum AvatarSource: String, Identifiable { case camera, album, symbols; var id: String { rawValue } }
    @State private var avatarSource: AvatarSource?
    @State private var accountsManager = false
    @State private var editingAccount: BrowserProfile?
    @State private var passwordScreen = false
    @State private var deleting = false
    @State private var issue: String?
    private var options: AccountOptions { profile.account ?? AccountOptions() }
    private var canAdminister: Bool { model.profile.isAdmin && !model.requiresUnlock }
    var body: some View {
        Group { if embedded { accountForm } else { NavigationStack { accountForm } } }.tint(theme.buttonTextColor).preferredColorScheme(theme.light ? .light : .dark)
    }
    private var accountForm: some View {
            Form {
                ThemedSection("البيانات الشخصية") {
                    HStack(spacing: 18) {
                        AccountAvatar(profile: profile, store: model.profiles, size: 70)
                        VStack(spacing: 12) {
                            HStack { Button("الكاميرا") { avatarSource = .camera }.accessibilityIdentifier("avatarCameraButton").disabled(!UIImagePickerController.isSourceTypeAvailable(.camera)); Divider(); Button("الألبوم") { avatarSource = .album }.accessibilityIdentifier("avatarAlbumButton") }.frame(height: 30)
                            Button("صور رمزية") { avatarSource = .symbols }.accessibilityIdentifier("avatarSymbolsButton").frame(maxWidth: .infinity)
                        }
                    }.buttonStyle(.borderless).frame(minHeight: 88).listRowBackground(theme.backgroundColor)
                    LabeledContent("الاسم") { TextField("اسم الحساب", text: $profile.name).multilineTextAlignment(.trailing) }
                    if options.avatarFilename != nil { Button("إزالة الصورة") { if let file = model.profiles.avatarURL(profile) { try? FileManager.default.removeItem(at: file) }; profile.account?.avatarFilename = nil } }

                    if profile.role != .guest { Button("كلمة مرور الحساب", systemImage: "key") { passwordScreen = true } }
                    Picker("تسجيل الخروج بعد مغادرة التطبيق", selection: option(\.logoutAfter)) { Text("أبدًا").tag(Double(-1)); Text("فورًا").tag(Double(0)); Text("دقيقة").tag(Double(60)); Text("5 دقائق").tag(Double(300)); Text("10 دقائق").tag(Double(600)); Text("30 دقيقة").tag(Double(1800)) }
                    if model.profile.id == profile.id && (profile.isAdmin || profile.locked) { Button(profile.locked ? "إلغاء قفل الجهاز والبصمة" : "حماية إضافية برمز الجهاز والبصمة") { Task { await model.setProfileLock(!profile.locked); profile = model.profile } } }
                }
                .disabled(profile.role == .guest && !canAdminister)
                if model.profile.id == profile.id { Button("تسجيل الخروج الآن") { model.logout(); dismiss() } }
                if canAdminister && profile.isAdmin {
                    ThemedSection { Toggle("إظهار صورة الحساب الحالي دائمًا", isOn: $showCurrentUserAvatar) }
                    ThemedSection("حسابات أخرى") {
                        ForEach(model.profiles.profiles.filter { [.guest, .kiosk].contains($0.role) }) { account in Button { editingAccount = account } label: { HStack { AccountAvatar(profile: account, store: model.profiles, size: 50); Text(account.name); Spacer(); Text(account.account?.enabled == true ? "مفعّل" : "متوقف").font(.caption) } } }
                    }
                    ThemedSection("حسابات المستخدمين") {
                        Button("إدارة الحسابات وإضافة حساب") { accountsManager = true }
                        ForEach(model.profiles.profiles.filter { $0.role == .standard }) { account in
                            if account.requiresPassword { Label(account.name + " — سجّل الدخول لتغيير إعداداته", systemImage: "lock") }
                            else { Button(account.name) { editingAccount = account } }
                        }
                    }
                }
                if canAdminister && !profile.isAdmin {
                    ThemedSection("الصلاحيات") {
                        if [.guest, .kiosk].contains(profile.role) { Toggle("تفعيل الحساب", isOn: option(\.enabled)) }
                        Toggle("التنزيلات", isOn: option(\.allowDownloads)); Toggle("السكربتات", isOn: option(\.allowScripts)); Toggle("أدوات المطور", isOn: option(\.allowDeveloperTools)); Toggle("تغيير إعدادات التصفح", isOn: option(\.allowSettings))
                        TextField("صفحة البداية", text: option(\.homePage)).textInputAutocapitalization(.never).keyboardType(.URL)
                        TextField("المواقع المسموحة، نطاق في كل سطر", text: Binding(get: { options.allowedDomains.joined(separator: "\n") }, set: { profile.account = options; profile.account?.allowedDomains = $0.components(separatedBy: .whitespacesAndNewlines).filter { FilterRules.validDomain($0) } }), axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("اترك قائمة المواقع فارغة للسماح بجميع النطاقات. قيد المواقع ينطبق على التنقلات؛ لا يعزل موارد المواقع الفرعية.").font(.caption).foregroundStyle(theme.secondaryTextColor)
                    }
                }
                if canAdminister && !profile.isAdmin { ThemedSection { Button("حذف الحساب وبياناته") { deleting = true } } }
                if let issue { Text(issue).font(.caption) }
            }.scrollContentBackground(.hidden).background(theme.backgroundColor).navigationTitle("إعدادات الحساب").navigationBarTitleDisplayMode(.inline)
                .toolbar { if !embedded { ToolbarItem(placement: .topBarTrailing) { Button("تم") { dismiss() } } } }
                .onChange(of: profile) { _, value in if !value.name.trimmingCharacters(in: .whitespaces).isEmpty { model.profiles.update(value) } }
                .fullScreenCover(item: $avatarSource) { source in
                    switch source {
                    case .camera: CameraPicker { if let image = $0 { saveImage(image) }; avatarSource = nil }.ignoresSafeArea()
                    case .album: AvatarAlbumPicker { data in
                        if let data, let source = CGImageSourceCreateWithData(data as CFData, nil), let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary) { saveImage(UIImage(cgImage: bitmap)) }
                        avatarSource = nil
                    }.ignoresSafeArea()
                    case .symbols: avatarCatalogue
                    }
                }
                .fullScreenCover(isPresented: $accountsManager) { ProfilesSheet(model: model) }
                .fullScreenCover(item: $editingAccount) { SettingsSheet(model: model, profile: $0) }
                .fullScreenCover(isPresented: $passwordScreen) { AccountPasswordView(profile: profile) { protected in profile.passwordProtected = protected; model.profiles.update(profile) } }
                .confirmationDialog("حذف الحساب وكل ملفاته؟", isPresented: $deleting) { Button("حذف نهائي") { Task { await model.deleteProfile(profile); dismiss() } } }
    }
    private var avatarCatalogue: some View {
                    NavigationStack { ScrollView { LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 24) { ForEach(["person.crop.circle.fill", "person.fill", "house.fill", "briefcase.fill", "book.fill", "star.fill", "moon.fill", "sun.max.fill", "globe", "bolt.fill", "leaf.fill", "heart.fill", "pawprint.fill", "paperplane.fill", "gamecontroller.fill", "desktopcomputer"], id: \.self) { symbol in Button { profile.symbol = symbol; profile.account = options; profile.account?.avatarFilename = nil; avatarSource = nil } label: { Image(systemName: symbol).font(.system(size: 36)).frame(width: 70, height: 70).glassSurface(12) } } }.padding() }.background(theme.backgroundColor).navigationTitle("الصور الرمزية").toolbar { Button("تم") { avatarSource = nil } } }.tint(theme.buttonTextColor).preferredColorScheme(theme.light ? .light : .dark).accessibilityIdentifier("avatarSymbolCatalogue")
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
    @Environment(\.browserTheme) private var theme
    let profile: BrowserProfile
    var saved: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var issue: String?
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                if profile.requiresPassword { SecureField("كلمة المرور الحالية", text: $current) }
                SecureField("كلمة المرور الجديدة", text: $password); SecureField("تأكيد كلمة المرور", text: $confirmation)
                Text("اترك كلمة المرور الجديدة فارغة لإزالة الحماية بعد إدخال الحالية. الحساب الرئيسي لا يتجاوز كلمة مرور حسابك.").font(.footnote)
                if let issue { Text(issue) }
                Button("حفظ") { busy = true; Task { defer { busy = false }; guard password == confirmation else { issue = "كلمتا المرور غير متطابقتين."; return }; if profile.requiresPassword, !(await AccountVault.verify(current, id: profile.id)) { issue = "كلمة المرور الحالية غير صحيحة."; return }; do { try await AccountVault.set(password, id: profile.id); saved(!password.isEmpty); dismiss() } catch { issue = error.localizedDescription } } }.disabled(busy)
            }.scrollContentBackground(.hidden).background(theme.backgroundColor).navigationTitle("كلمة مرور الحساب").toolbar { Button("إلغاء") { dismiss() } }
        }.tint(theme.buttonTextColor).preferredColorScheme(theme.light ? .light : .dark)
    }
}

struct AccountDefaultsEditor: View {
    @Environment(\.browserTheme) private var theme
    let model: BrowserModel
    let profile: BrowserProfile
    @State private var data = ProfileData()
    @State private var message: String?
    var body: some View {
        Form {
            ThemedSection("التصفح") { Picker("محرك البحث", selection: $data.settings.searchProvider) { ForEach(SearchProvider.allCases) { Text($0.rawValue).tag($0) } }; Toggle("سطح المكتب", isOn: $data.settings.desktopMode) }
            ThemedSection("الحماية") { Toggle("حجب الإعلانات", isOn: $data.settings.shieldsEnabled); Toggle("إخفاء مواضع الإعلانات", isOn: $data.settings.cosmeticFiltering) }
            ThemedSection("الواجهة") { Picker("التوزيع", selection: Binding(get: { data.settings.chromeLayout ?? .original }, set: { data.settings.chromeLayout = $0 })) { ForEach(ChromeLayout.allCases) { Text($0.title).tag($0) } } }
            Button("حفظ إعدادات الحساب") { do { if profile.isPrivate { try model.profiles.saveTemplate(data, profile: profile) } else { model.profiles.save(data, for: profile) }; message = "حُفظت الإعدادات." } catch { message = error.localizedDescription } }
            if let message { Text(message) }
        }.scrollContentBackground(.hidden).background(theme.backgroundColor).navigationTitle(profile.name).task { data = profile.isPrivate ? model.profiles.guestTemplate(profile) : model.profiles.load(profile) }
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
    @Environment(\.browserTheme) private var theme
    @ObservedObject var model: BrowserModel
    var body: some View {
        Form {
            ThemedSection("توزيع الأشرطة") { ForEach(ChromeLayout.allCases) { layout in Button { model.data.settings.chromeLayout = layout; model.chromeHidden = false; model.persist() } label: { HStack { Text(layout.title); Spacer(); if (model.data.settings.chromeLayout ?? .original) == layout { Image(systemName: "checkmark") } } }.accessibilityIdentifier("layout-" + layout.rawValue) } }
            ThemedSection { Text("الأوامر نفسها في التوزيعات الثلاثة. في ZEUS الأصلي اسحب من اليمين للأدوات ومن الأعلى للتبويبات. الشريطان يختفيان عند التمرير للأسفل ويعودان عند التمرير للأعلى. قائمة الأدوات تتيح جميع الأوامر في كل توزيع.").font(.footnote) }
        }.scrollContentBackground(.hidden).background(theme.backgroundColor).navigationTitle("واجهة المستخدم")
    }
}

struct AvatarAlbumPicker: UIViewControllerRepresentable {
    var completion: (Data?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared()); configuration.selectionLimit = 1; configuration.filter = .images
        let picker = PHPickerViewController(configuration: configuration); picker.delegate = context.coordinator; picker.view.accessibilityIdentifier = "avatarAlbumPicker"
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: (Data?) -> Void
        init(completion: @escaping (Data?) -> Void) { self.completion = completion }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider, let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { completion(nil); return }
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in Task { @MainActor in self.completion(data) } }
        }
    }
}
