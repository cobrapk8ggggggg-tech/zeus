import SwiftUI

extension ReadingPreferences {
    var readerBackground: Color { BrowserTheme.color(backgroundHex ?? "202124") }
    var readerText: Color { BrowserTheme.color(textHex ?? "F1F1F1") }
    func readerFont(size: Double) -> Font {
        switch fontName ?? "system" {
        case "GeezaPro": return .custom("GeezaPro", size: size)
        case "Damascus": return .custom("Damascus", size: size)
        case "Arial": return .custom("Arial", size: size)
        case "serif": return .system(size: size, design: .serif)
        default: return .system(size: size)
        }
    }
}

struct ReaderAppearanceSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var word = ""
    private var prefs: ReadingPreferences { model.data.settings.reading ?? ReadingPreferences() }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("معاينة القراءة", systemImage: "book.pages").font(.caption)
                        Text("في هدوء الليل تبدأ حكاية جديدة…\nA new story begins tonight.")
                            .font(prefs.readerFont(size: prefs.fontSize)).opacity(prefs.textOpacity).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    }.foregroundStyle(prefs.readerText).padding(22).background(prefs.readerBackground, in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12)))
                    card("الخط والنص", "textformat") {
                        Picker("الخط", selection: Binding(get: { prefs.fontName ?? "system" }, set: { var p = prefs; p.fontName = $0; save(p) })) {
                            Text("خط النظام").tag("system"); Text("جيزة — عربي").tag("GeezaPro"); Text("دمشق — عربي").tag("Damascus"); Text("Arial").tag("Arial"); Text("Serif").tag("serif")
                        }.accessibilityIdentifier("readerFontPicker")
                        HStack { Text("حجم الخط"); Spacer(); Text("\(Int(prefs.fontSize))").monospacedDigit() }
                        Slider(value: number(\.fontSize), in: 14...40, step: 1)
                        HStack { Text("شفافية النص"); Spacer(); Text("\(Int(prefs.textOpacity * 100))٪").monospacedDigit() }
                        Slider(value: number(\.textOpacity), in: 0.1...1).accessibilityIdentifier("readerTextOpacity")
                    }
                    card("ألوان القراءة", "paintpalette") {
                        HStack(spacing: 12) {
                            preset("رمادي", background: "202124", text: "F1F1F1")
                            preset("أسود", background: "000000", text: "E7E7E7")
                            preset("ورقي", background: "F4EBD8", text: "29241D")
                        }
                        ColorPicker("الخلفية", selection: color(\.backgroundHex, fallback: "202124"), supportsOpacity: false).accessibilityIdentifier("readerBackgroundColor")
                        ColorPicker("النص", selection: color(\.textHex, fallback: "F1F1F1"), supportsOpacity: false)
                    }
                    card("الكلمات المستبعدة", "text.badge.minus") {
                        HStack { TextField("كلمة أو جملة", text: $word); Button("إضافة") { let clean = word.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty else { return }; var p = prefs; if !p.blockedWords.contains(clean) { p.blockedWords.append(clean) }; save(p); word = "" } }
                        ForEach(prefs.blockedWords, id: \.self) { text in HStack { Text(text); Spacer(); Button { var p = prefs; p.blockedWords.removeAll { $0 == text }; save(p) } label: { Image(systemName: "minus.circle") } } }
                    }
                }.padding(20)
            }.background(Color(white: 0.06)).navigationTitle("إعدادات القارئ").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
        }.environment(\.layoutDirection, .rightToLeft).preferredColorScheme(.dark).tint(.white)
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible).presentationCornerRadius(28)
    }
    private func card<Content: View>(_ title: String, _ icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) { Label(title, systemImage: icon).font(.headline); Divider(); content() }.padding(18).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.08)))
    }
    private func preset(_ name: String, background: String, text: String) -> some View {
        Button { var p = prefs; p.backgroundHex = background; p.textHex = text; save(p) } label: { Text(name).font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 14).foregroundStyle(BrowserTheme.color(text)).background(BrowserTheme.color(background), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.2))) }
    }
    private func save(_ p: ReadingPreferences) { model.data.settings.reading = p; model.persist() }
    private func number(_ key: WritableKeyPath<ReadingPreferences, Double>) -> Binding<Double> { Binding(get: { prefs[keyPath: key] }, set: { var p = prefs; p[keyPath: key] = $0; save(p) }) }
    private func color(_ key: WritableKeyPath<ReadingPreferences, String?>, fallback: String) -> Binding<Color> { Binding(get: { BrowserTheme.color(prefs[keyPath: key] ?? fallback) }, set: { var p = prefs; p[keyPath: key] = BrowserTheme.hex($0); save(p) }) }
}
