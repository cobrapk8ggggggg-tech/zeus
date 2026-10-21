import SwiftUI

enum BrowserActionGroup: String, CaseIterable, Identifiable {
    case navigation, reading, library, automation, account
    var id: String { rawValue }
    var title: String { switch self { case .navigation: return "التصفح والتبويبات"; case .reading: return "القراءة والعرض"; case .library: return "المكتبة والملفات"; case .automation: return "السكربتات والنماذج"; case .account: return "الحساب والحماية" } }
    var symbol: String { switch self { case .navigation: return "square.on.square"; case .reading: return "book"; case .library: return "folder"; case .automation: return "curlybraces"; case .account: return "person.crop.circle" } }
    var actions: [BrowserAction] {
        switch self {
        case .navigation: return [.back,.forward,.reload,.home,.newTab,.tabs,.pinTab,.fullScreen]
        case .reading: return [.reader,.gallery,.translate,.darkPage,.twinHorizontal,.twinVertical]
        case .library: return [.library,.history,.downloads,.bookmark,.savePage,.printPage,.share]
        case .automation: return [.scripts,.console,.saveForm,.fillForm]
        case .account: return [.profiles,.settings,.shield]
        }
    }
}
struct ProfilePickerPopover: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var model: BrowserModel
    @ObservedObject private var store: ProfileStore
    let close: () -> Void
    let manage: () -> Void
    @State private var target: BrowserProfile?
    @State private var password = ""
    @State private var busy = false
    init(model: BrowserModel, close: @escaping () -> Void, manage: @escaping () -> Void) { self.model = model; store = model.profiles; self.close = close; self.manage = manage }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.6).ignoresSafeArea().onTapGesture { if !busy { close() } }
                VStack(spacing: 0) {
                    HStack {
                        Button("إلغاء") { close() }.accessibilityIdentifier("closeProfilePicker")
                        Spacer(); Text("اختيار الحساب").font(.headline); Spacer()
                        Button("خروج") { model.logout() }.disabled(model.requiresUnlock)
                    }.padding(18).background(theme.backgroundColor)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(store.profiles.filter { $0.isAdmin }) { account in row(account) }
                            Color.clear.frame(height: 28)
                            ForEach(store.profiles.filter { !$0.isAdmin && $0.account?.enabled != false }) { account in row(account) }
                        }
                    }
                    Button("إدارة الحسابات", systemImage: "person.badge.gearshape") { manage() }.frame(maxWidth: .infinity).padding(16).background(theme.backgroundColor)
                }.frame(width: min(440, geometry.size.width - 32), height: min(660, geometry.size.height - 80))
                    .background(theme.surfaceColor).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.borderColor.opacity(0.45))).shadow(color: .black.opacity(0.5), radius: 30)
                    .disabled(busy).overlay { if busy { ProgressView().padding(20).background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 16)) } }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.environment(\.layoutDirection, .rightToLeft).accessibilityElement(children: .contain).accessibilityIdentifier("profilePickerWindow")
            .alert("دخول \(target?.name ?? "")", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
                SecureField("كلمة المرور", text: $password)
                Button("دخول") { if let account = target { attempt(account, password: password) }; password = ""; target = nil }
                Button("إلغاء", role: .cancel) { password = ""; target = nil }
            }
    }
    private func row(_ account: BrowserProfile) -> some View {
        Button { if account.requiresPassword { target = account; password = "" } else { attempt(account, password: "") } } label: {
            HStack(spacing: 18) {
                AccountAvatar(profile: account, store: store, size: 70)
                VStack(alignment: .leading, spacing: 9) { Text(account.name).font(.headline).lineLimit(2); Text(account.role.title).font(.subheadline).foregroundStyle(theme.secondaryTextColor) }
                Spacer(minLength: 0)
                if !model.requiresUnlock && account.id == model.profile.id { Image(systemName: "checkmark").foregroundStyle(theme.accentColor) }
                if account.requiresPassword { Image(systemName: "lock").font(.caption) }
            }.padding(.horizontal, 16).frame(minHeight: 88).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(theme.textColor).background(theme.surfaceColor).overlay(alignment: .bottom) { Rectangle().fill(theme.borderColor.opacity(0.3)).frame(height: 0.5).padding(.leading, 104) }.accessibilityIdentifier("select-profile-" + account.name)
    }
    private func attempt(_ account: BrowserProfile, password: String) {
        busy = true
        Task { await model.switchProfile(to: account, password: password); busy = false; if model.profile.id == account.id && !model.requiresUnlock { close() } }
    }
}
