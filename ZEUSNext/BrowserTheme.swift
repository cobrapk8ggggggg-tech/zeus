import SwiftUI
import UIKit

enum BrowserSurfaceStyle: String, Codable, CaseIterable { case solid, glass; var title: String { self == .solid ? "سادة" : "زجاجي بلونين" } }
enum BrowserControlShape: String, Codable, CaseIterable { case rounded, capsule, square; var title: String { switch self { case .rounded: return "مستدير"; case .capsule: return "كبسولة"; case .square: return "زوايا خفيفة" } } }
struct BrowserTheme: Codable, Equatable {
    var name = "أسود وأبيض"
    var background = "000000"
    var surface = "202020"
    var surfaceSecondary = "363636"
    var text = "FFFFFF"
    var secondaryText = "AFAFAF"
    var icon = "FFFFFF"
    var buttonBackground = "00000000"
    var buttonText = "FFFFFF"
    var accent = "FFFFFF"
    var border = "666666"
    var switchOn = "30D158"
    var selection = "E6E6E6"
    var selectionText = "111111"
    var style: BrowserSurfaceStyle = .glass
    var light = false
    var controlShape: BrowserControlShape? = nil
    func radius(_ preferred: CGFloat) -> CGFloat { switch controlShape ?? .rounded { case .rounded: return preferred; case .capsule: return 100; case .square: return 6 } }
    static let standard = BrowserTheme()
    static var presets: [BrowserTheme] {
        [standard,
         BrowserTheme(name: "ذهب ليلي", surface: "211D17", surfaceSecondary: "46381F", secondaryText: "C4B899", icon: "E8C66A", buttonText: "F6D98A", accent: "E8C66A", border: "8E7339", selection: "D3B363"),
         BrowserTheme(name: "نهار هادئ", background: "F6F6F8", surface: "FFFFFF", surfaceSecondary: "DDE5EE", text: "15171A", secondaryText: "626875", icon: "202834", buttonText: "202834", accent: "1769C2", border: "ABB7C5", selection: "294B72", selectionText: "FFFFFF", style: .solid, light: true),
         BrowserTheme(name: "محيط", background: "041119", surface: "0C2636", surfaceSecondary: "164D62", secondaryText: "9AC5D2", icon: "A3E9EF", buttonText: "D1F8FF", accent: "5ED5E4", border: "397A8F", selection: "80DEE8"),
         BrowserTheme(name: "بنفسج", background: "100A18", surface: "281A39", surfaceSecondary: "543664", secondaryText: "C5B1D9", icon: "DAC0FF", buttonText: "F0DEFF", accent: "CEAEFA", border: "83649D", selection: "C5A3EB"),
         BrowserTheme(name: "زمرد", background: "06150F", surface: "133527", surfaceSecondary: "31513A", secondaryText: "ACCEB8", icon: "A0E9B7", buttonText: "D4FFE0", accent: "77D99A", border: "48825A", selection: "90DBA9")]
    }
    static func color(_ value: String) -> Color {
        let clean = value.replacingOccurrences(of: "#", with: "")
        guard (clean.count == 6 || clean.count == 8), let n = UInt64(clean, radix: 16) else { return .gray }
        let rgb = clean.count == 8 ? n >> 8 : n
        return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: clean.count == 8 ? Double(n & 255) / 255 : 1)
    }
    static func hex(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X%02X", Int(min(1,max(0,r))*255), Int(min(1,max(0,g))*255), Int(min(1,max(0,b))*255), Int(min(1,max(0,a))*255))
    }
    var backgroundColor: Color { Self.color(background) }
    var surfaceColor: Color { Self.color(surface) }
    var secondSurfaceColor: Color { Self.color(surfaceSecondary) }
    var textColor: Color { Self.color(text) }
    var secondaryTextColor: Color { Self.color(secondaryText) }
    var iconColor: Color { Self.color(icon) }
    var buttonBackgroundColor: Color { Self.color(buttonBackground) }
    var buttonTextColor: Color { Self.color(buttonText) }
    var accentColor: Color { Self.color(accent) }
    var borderColor: Color { Self.color(border) }
    var switchColor: Color { Self.color(switchOn) }
    var selectionColor: Color { Self.color(selection) }
    var selectionTextColor: Color { Self.color(selectionText) }
    var isValid: Bool { [background,surface,surfaceSecondary,text,secondaryText,icon,buttonBackground,buttonText,accent,border,switchOn,selection,selectionText].allSatisfy { ($0.count == 6 || $0.count == 8) && UInt64($0, radix: 16) != nil } }
}
private struct BrowserThemeKey: EnvironmentKey { static let defaultValue = BrowserTheme.standard }
extension EnvironmentValues { var browserTheme: BrowserTheme { get { self[BrowserThemeKey.self] } set { self[BrowserThemeKey.self] = newValue } } }
struct BrowserThemeModifier: ViewModifier {
    let theme: BrowserTheme
    func body(content: Content) -> some View {
        content.environment(\.browserTheme, theme).foregroundStyle(theme.textColor).tint(theme.accentColor)
            .buttonStyle(BrowserTextButtonStyle(theme: theme)).toggleStyle(BrowserToggleStyle(theme: theme)).preferredColorScheme(theme.light ? .light : .dark)
    }
}
extension View { func browserTheme(_ theme: BrowserTheme) -> some View { modifier(BrowserThemeModifier(theme: theme)) } }
struct BrowserToggleStyle: ToggleStyle {
    let theme: BrowserTheme
    func makeBody(configuration: Configuration) -> some View {
        HStack { configuration.label.foregroundStyle(theme.textColor); Spacer(minLength: 12); Toggle(isOn: configuration.$isOn) { configuration.label }.labelsHidden().toggleStyle(.switch).tint(theme.switchColor) }
    }
}
struct ThemeEditor: View {
    @ObservedObject var context: ProfileSettingsContext
    @State private var currentSection = 0
    private var theme: BrowserTheme { context.settings.theme ?? .standard }
    var body: some View {
        Form {
            Section("معاينة مباشرة") {
                VStack(spacing: 16) {
                    HStack { Image(systemName: "globe").foregroundStyle(theme.iconColor); Text("ZEUS Browser"); Spacer(); Image(systemName: "gearshape").foregroundStyle(theme.iconColor) }
                    HStack { Image(systemName: "magnifyingglass"); Text("البحث أو إدخال عنوان"); Spacer() }.padding(12).glassSurface(18)
                    HStack { Label("زر تجريبي", systemImage: "star.fill").foregroundStyle(theme.buttonTextColor).padding(10).background(theme.buttonBackgroundColor, in: RoundedRectangle(cornerRadius: 12)); Spacer(); Toggle("مفعّل", isOn: .constant(true)).labelsHidden().toggleStyle(.switch).tint(theme.switchColor) }
                }.padding(18).background(theme.backgroundColor, in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(theme.borderColor)).foregroundStyle(theme.textColor).environment(\.browserTheme, theme)
            }
            Section("سمات جاهزة") {
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 12) { ForEach(BrowserTheme.presets, id: \.name) { preset in
                    Button { context.settings.theme = preset; context.save() } label: { VStack(spacing: 7) { HStack(spacing: 0) { preset.backgroundColor; preset.surfaceColor; preset.accentColor }.frame(width: 100, height: 46).clipShape(RoundedRectangle(cornerRadius: 12)); Text(preset.name).font(.caption).foregroundStyle(theme.textColor) } }.buttonStyle(.borderless).accessibilityIdentifier("theme-" + preset.name)
                } }.padding(.vertical, 5) }
            }
            Section("أسلوب الأسطح") { Picker("شكل الأزرار والأسطح", selection: Binding(get: { theme.controlShape ?? .rounded }, set: { setting(\.controlShape).wrappedValue = $0 })) { ForEach(BrowserControlShape.allCases, id: \.self) { Text($0.title).tag($0) } }; Picker("المظهر", selection: setting(\.style)) { ForEach(BrowserSurfaceStyle.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented); Toggle("مظهر نظام فاتح", isOn: setting(\.light)) }
            Section("ألوان مخصصة") {
                color("الخلفية العامة", \.background); color("السطح واللون الزجاجي الأول", \.surface); color("اللون الزجاجي الثاني", \.surfaceSecondary)
                color("النص الرئيسي", \.text); color("النص الثانوي", \.secondaryText); color("الأيقونات", \.icon)
                color("خلفية الأزرار", \.buttonBackground); color("نص الأزرار", \.buttonText); color("لون التحكم والتحديد", \.accent)
                color("الحدود", \.border); color("المفتاح المفعّل", \.switchOn); color("التبويب المختار", \.selection); color("نص التبويب المختار", \.selectionText)
            }
            Section { Button("استعادة الأسود والأبيض") { context.settings.theme = .standard; context.save() }; Text("تُحفظ السمة لهذا البروفايل. الألوان لا تغيّر محتوى المواقع أو الصور. اختر ألوان نص وخلفية متباينة لسهولة القراءة.").font(.footnote) }
        }.settingsPage("الألوان والمظهر").browserTheme(theme)
    }
    private func setting<T>(_ key: WritableKeyPath<BrowserTheme, T>) -> Binding<T> { Binding(get: { theme[keyPath: key] }, set: { var value = theme; value.name = "مخصص"; value[keyPath: key] = $0; context.settings.theme = value; context.save() }) }
    private func color(_ label: String, _ key: WritableKeyPath<BrowserTheme, String>) -> some View { ColorPicker(label, selection: Binding(get: { BrowserTheme.color(theme[keyPath: key]) }, set: { setting(key).wrappedValue = BrowserTheme.hex($0) }), supportsOpacity: true) }
}

struct BrowserTextButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    let theme: BrowserTheme
    func makeBody(configuration: Configuration) -> some View { configuration.label.foregroundStyle(theme.buttonTextColor).background(theme.buttonBackgroundColor, in: RoundedRectangle(cornerRadius: theme.radius(10))).opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.35) }
}
struct ThemedSection<Content: View>: View {
    @Environment(\.browserTheme) private var theme
    let title: String?
    let content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View { Section { content } header: { if let title { Text(title).foregroundStyle(theme.secondaryTextColor) } }.listRowBackground(BrowserRowBackground(theme: theme)).listRowSeparatorTint(theme.borderColor.opacity(0.45)) }
}
struct SettingsPageStyle: ViewModifier {
    @Environment(\.browserTheme) private var theme
    let title: String
    func body(content: Content) -> some View { content.scrollContentBackground(.hidden).background(theme.backgroundColor).foregroundStyle(theme.textColor).navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbarBackground(theme.surfaceColor, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar) }
}

struct BrowserRowBackground: View {
    let theme: BrowserTheme
    var body: some View {
        if theme.style == .glass { Rectangle().fill(LinearGradient(colors: [theme.surfaceColor.opacity(0.55), theme.secondSurfaceColor.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)).background(.ultraThinMaterial) }
        else { theme.surfaceColor }
    }
}
struct BrowserSettingsLabelStyle: LabelStyle {
    @Environment(\.browserTheme) private var theme
    func makeBody(configuration: Configuration) -> some View { HStack(spacing: 12) { configuration.icon.foregroundStyle(theme.iconColor); configuration.title.foregroundStyle(theme.textColor) } }
}
