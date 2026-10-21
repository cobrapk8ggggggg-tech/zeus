import SwiftUI

struct ScriptsSheet: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: BrowserScript?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.title2) }
                Spacer(); Text("مدير السكربتات").font(.headline); Spacer()
                Button { editing = BrowserScript(name: "سكربت جديد", domain: "*", code: "// اكتب كود جافا سكربت هنا\n") } label: { Image(systemName: "plus").font(.title2) }
            }.padding().background(theme.backgroundColor)
            if model.data.scripts.isEmpty {
                VStack { Spacer(); Image(systemName: "curlybraces").font(.system(size: 60)).opacity(0.5); Text("لا توجد سكربتات مضافة").opacity(0.5).padding(); Spacer() }.frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(model.data.scripts) { script in
                        HStack {
                            VStack(alignment: .leading) { Text(script.name).font(.headline); Text(script.domain).font(.caption).opacity(0.5) }.onTapGesture { editing = script }
                            Spacer()
                            Toggle("تشغيل", isOn: Binding(get: { model.data.scripts.first { $0.id == script.id }?.isActive ?? false }, set: { value in if let index = model.data.scripts.firstIndex(where: { $0.id == script.id }) { model.data.scripts[index].isActive = value; model.applySettings() } })).labelsHidden()
                            Button { editing = script } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).padding(.leading, 10)
                            Button { model.data.scripts.removeAll { $0.id == script.id }; model.applySettings() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).padding(.leading, 10)
                        }.listRowBackground(theme.backgroundColor)
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }.background(theme.backgroundColor).foregroundStyle(theme.textColor).tint(theme.buttonTextColor).disabled(model.profile.account?.allowScripts == false)
            .fullScreenCover(item: $editing) { script in ScriptEditor(script: script) { changed in if let index = model.data.scripts.firstIndex(where: { $0.id == changed.id }) { model.data.scripts[index] = changed } else { model.data.scripts.append(changed) }; model.applySettings() } }
    }
}

struct ScriptEditor: View {
    @Environment(\.browserTheme) private var theme
    @State var script: BrowserScript
    var save: (BrowserScript) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var invalid = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("الاسم", text: $script.name)
                TextField("المضيف أو *", text: $script.domain).textInputAutocapitalization(.never).autocorrectionDisabled().environment(\.layoutDirection, .leftToRight)
                TextEditor(text: $script.code).font(.system(.footnote, design: .monospaced)).frame(minHeight: 300).environment(\.layoutDirection, .leftToRight).autocorrectionDisabled().textInputAutocapitalization(.never)
            }.navigationTitle("محرر السكربت")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("حفظ") { script.domain = script.domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(); guard (script.domain == "*" || FilterRules.validDomain(script.domain)), script.code.utf8.count <= 100_000 else { invalid = true; return }; save(script); dismiss() } }
                }.alert("تحقق من المدخلات", isPresented: $invalid) { Button("حسنًا") {} } message: { Text("أدخل اسم مضيف فقط أو *، واجعل حجم السكربت أقل من 100 كيلوبايت.") }
        }.environment(\.layoutDirection, .rightToLeft)
    }
}

struct ConsoleSheet: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var command = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !model.data.settings.developerTools || model.profile.account?.allowDeveloperTools == false {
                    ContentUnavailableView("الكونسول غير مفعّل", systemImage: "terminal", description: Text("فعّله من الإعدادات لالتقاط سجلات الصفحات الجديدة."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(model.console) { entry in Text(entry.text).font(.system(.caption, design: .monospaced)).foregroundStyle(entry.kind == "error" ? theme.textColor : entry.kind == "warn" ? theme.textColor : theme.textColor.opacity(0.85)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(theme.textColor.opacity(0.03), in: RoundedRectangle(cornerRadius: 10)) }
                        }.padding(15)
                    }.environment(\.layoutDirection, .leftToRight)
                    HStack {
                        TextField("JavaScript", text: $command).font(.system(.footnote, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { execute() }
                        Button { execute() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    }.environment(\.layoutDirection, .leftToRight).padding(17).glassSurface(22).padding(12)
                }
            }.background { OrbitBackground(tint: theme.textColor) }.navigationTitle("الكونسول")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("تم") { dismiss() } }; ToolbarItem(placement: .topBarLeading) { Button("مسح") { model.console.removeAll() } } }
        }
    }
    private func execute() {
        guard model.data.settings.developerTools, model.profile.account?.allowDeveloperTools != false, !command.isEmpty else { return }
        let source = String(command.prefix(100_000)); command = ""
        model.console.append(ConsoleEntry(text: "> " + source, kind: "command"))
        model.webView?.evaluateJavaScript(source) { value, error in
            model.console.append(ConsoleEntry(text: String(describing: error?.localizedDescription ?? value.map { String(describing: $0) } ?? "undefined"), kind: error == nil ? "result" : "error"))
            if model.console.count > 300 { model.console.removeFirst(model.console.count - 300) }
        }
    }
}
