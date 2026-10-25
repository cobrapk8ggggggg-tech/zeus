import SwiftUI

struct ChromeStudioLibrary: View {
    @ObservedObject var context: ProfileSettingsContext
    @State private var editing: ChromeDesign?
    @State private var deleting: ChromeDesign?
    @Environment(\.browserTheme) private var theme
    private var workspace: ChromeWorkspace { context.settings.chromeWorkspace ?? ChromeWorkspace() }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "square.3.layers.3d").font(.system(size: 34, weight: .light))
                    Text("صمّم متصفحك بيدك").font(.title2.bold())
                    Text("اسحب العناصر وضعها مباشرة على اللوحة. عدّل توزيعًا أساسيًا أو احفظ توزيعاتك الخاصة، مع تصميم مستقل للطول والعرض.").font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 14)
            }
            Section("التوزيعات الأساسية") {
                ForEach(ChromeLayout.allCases) { base in
                    HStack {
                        Button { activate(base) } label: {
                            Label(base.title, systemImage: (workspace.selected == nil || workspace.bypass == true) && (context.settings.chromeLayout ?? .original) == base ? "checkmark.circle.fill" : "circle")
                        }.buttonStyle(.plain)
                        Spacer()
                        if let saved = workspace.designs.first(where: { $0.base == base }) {
                            Button { editing = saved } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("تعديل " + base.title)
                            Button { deleting = saved } label: { Image(systemName: "arrow.counterclockwise") }.accessibilityLabel("استعادة " + base.title)
                        } else { Button("تصميم") { editing = .preset(base) }.buttonStyle(.bordered).disabled(workspace.designs.count >= 24) }
                    }.padding(.vertical, 6)
                }
            }
            Section("توزيعاتي") {
                ForEach(workspace.designs.filter { $0.base == nil }) { design in
                    HStack {
                        Button { var value = workspace; value.selected = design.id; value.bypass = false; save(value) } label: {
                            Label(design.name, systemImage: workspace.selected == design.id && workspace.bypass != true ? "checkmark.circle.fill" : "rectangle.3.group")
                        }.buttonStyle(.plain)
                        Spacer()
                        Button { editing = design } label: { Image(systemName: "pencil") }.accessibilityLabel("تحرير " + design.name)
                    }.contextMenu {
                        Button("نسخ التوزيع", systemImage: "plus.square.on.square") { duplicate(design) }
                        Button("حذف", systemImage: "trash", role: .destructive) { deleting = design }
                    }
                }
                Menu {
                    Button("لوحة فارغة", systemImage: "rectangle.dashed") { editing = ChromeDesign(name: "توزيع جديد", portrait: ChromeComposition(), landscape: ChromeComposition()) }
                    ForEach(ChromeLayout.allCases) { base in Button("نسخة من " + base.title) { duplicate(workspace.designs.first { $0.base == base } ?? .preset(base)) } }
                } label: { Label("إنشاء توزيع جديد", systemImage: "plus.circle.fill") }.disabled(workspace.designs.count >= 24)
            }
        }
        .navigationTitle("استوديو التوزيعات").navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $editing) { design in
            ChromeStudioEditor(design: design, model: context.model, screenshot: context.model.current?.snapshot) { changed in
                var value = workspace
                if let index = value.designs.firstIndex(where: { $0.id == changed.id }) { value.designs[index] = changed } else { value.designs.append(changed) }
                if let base = changed.base { context.settings.chromeLayout = base; value.selected = nil } else { value.selected = changed.id }
                value.bypass = false
                save(value)
            }.browserTheme(theme)
        }
        .confirmationDialog("استعادة التوزيع الأساسي أو حذف التوزيع المحفوظ؟", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("تأكيد", role: .destructive) {
                guard let deleting else { return }; var value = workspace
                value.designs.removeAll { $0.id == deleting.id }; if value.selected == deleting.id { value.selected = nil }; save(value); self.deleting = nil
            }
        }
    }
    private func activate(_ base: ChromeLayout) { context.settings.chromeLayout = base; var value = workspace; value.selected = nil; value.bypass = false; save(value) }
    private func duplicate(_ design: ChromeDesign) {
        guard workspace.designs.count < 24 else { context.model.notify("يمكن حفظ ٢٤ توزيعًا. احذف توزيعًا لإضافة آخر."); return }
        var copy = design; copy.id = UUID(); copy.name += " — نسخة"; copy.base = nil
        for index in copy.portrait.blocks.indices { copy.portrait.blocks[index].id = UUID() }
        for index in copy.landscape.blocks.indices { copy.landscape.blocks[index].id = UUID() }
        editing = copy
    }
    private func save(_ value: ChromeWorkspace) {
        guard value.validated() else { context.model.notify("تجاوز التوزيع حدود الحفظ أو يحتوي قيمًا غير صالحة."); return }
        context.settings.chromeWorkspace = value; context.save()
        context.model.chromeHidden = false; context.model.chromeManuallyHidden = false
    }
}

struct ChromeStudioEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var design: ChromeDesign
    @State private var selected: UUID?
    @State private var wide = true
    @State private var snap = true
    @State private var showGrid = true
    @State private var preview = false
    @State private var inspector = false
    @State private var layers = false
    @State private var cancelling = false
    @State private var undo: [ChromeDesign] = []
    @State private var redo: [ChromeDesign] = []
    @State private var moveOrigin: ChromeBlock?
    @State private var moveResizes = false
    @State private var error: String?
    @State private var sliderEditing = false
    @State private var initialized = false
    private let initial: ChromeDesign
    private let screenshot: UIImage?
    private let model: BrowserModel?
    private let save: (ChromeDesign) -> Void
    init(design: ChromeDesign, model: BrowserModel? = nil, screenshot: UIImage? = nil, save: @escaping (ChromeDesign) -> Void) {
        initial = design; _design = State(initialValue: design); self.model = model; self.screenshot = screenshot; self.save = save
    }
    private var composition: ChromeComposition { design.composition(wide: wide) }
    private var selection: ChromeBlock? { composition.blocks.first { $0.id == selected } }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                options
                HStack(spacing: 0) {
                    GeometryReader { geometry in
                        let available = CGSize(width: max(1, geometry.size.width - 28), height: max(1, geometry.size.height - 28))
                        let ratio: CGFloat = wide ? 4 / 3 : 430 / 932
                        let width = min(available.width, available.height * ratio)
                        let global = geometry.frame(in: .global)
                        let origin = CGPoint(x: global.midX - width / 2, y: global.midY - width / ratio / 2)
                        stage(size: CGSize(width: width, height: width / ratio), globalOrigin: origin)
                            .frame(width: width, height: width / ratio)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.15), lineWidth: 1))
                            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }.background(Color(uiColor: .secondarySystemBackground))
                    if sizeClass == .regular && !preview { inspectorContent.frame(width: 280).background(Color(uiColor: .systemGroupedBackground)) }
                }
                if !preview { palette }
            }
            .navigationTitle("استوديو التوزيعات").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("إلغاء") { if design != initial { cancelling = true } else { dismiss() } } }
                ToolbarItem(placement: .principal) { HStack(spacing: 10) {
                    Button { restoreUndo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(undo.isEmpty).accessibilityLabel("تراجع")
                    Button { restoreRedo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(redo.isEmpty).accessibilityLabel("إعادة")
                } }
                ToolbarItem(placement: .topBarTrailing) { Button("حفظ وتطبيق") {
                    guard design.validated() else { error = "تحقق من اسم التوزيع والألوان وأحجام العناصر."; return }
                    save(design); dismiss()
                }.bold().accessibilityIdentifier("saveChromeDesign") }
            }
            .sheet(isPresented: $inspector) { NavigationStack { inspectorContent.navigationTitle("خصائص العنصر").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("تم") { inspector = false } } } }.presentationDetents([.medium, .large]) }
            .sheet(isPresented: $layers) { layerSheet }
            .confirmationDialog("تجاهل التغييرات؟", isPresented: $cancelling, titleVisibility: .visible) { Button("تجاهل", role: .destructive) { dismiss() } }
            .alert("تعذّر الحفظ", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("حسنًا") { error = nil } } message: { Text(error ?? "") }
            .interactiveDismissDisabled(design != initial)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                guard !initialized, size.width >= 200, size.height >= 200 else { return }
                wide = ChromeDesign.usesWideCanvas(size)
            }
        }.environment(\.layoutDirection, .rightToLeft)
    }
    private var options: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                Picker("حجم النافذة", selection: Binding(get: { wide }, set: { wide = $0; initialized = true })) { Label("واسع / iPad", systemImage: "ipad.landscape").tag(true); Label("ضيق / هاتف", systemImage: "iphone").tag(false) }.pickerStyle(.segmented).frame(width: 220)
                    .onChange(of: wide) { _, _ in selected = nil; moveOrigin = nil }
                Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { preview.toggle() } } label: { Label(preview ? "تحرير" : "معاينة", systemImage: preview ? "pencil.tip.crop.circle" : "eye") }
                Button { layers = true } label: { Label("الطبقات", systemImage: "square.3.layers.3d") }
                if sizeClass != .regular { Button { inspector = true } label: { Label("الخصائص", systemImage: "slider.horizontal.3") } }
                Toggle("شبكة", isOn: $showGrid).toggleStyle(.button)
                Toggle("محاذاة", isOn: $snap).toggleStyle(.button)
                Menu {
                    Button("نسخ هذا الاتجاه للاتجاه الآخر") { change { value in let source = value.composition(wide: wide); value.set(source, wide: !wide) } }
                    Button("مسح لوحة هذا الاتجاه", role: .destructive) { change { $0.set(ChromeComposition(), wide: wide) }; selected = nil }
                    if let base = design.base { Button("استعادة أساس " + base.title) { change { value in var restored = ChromeDesign.preset(base); restored.id = value.id; restored.name = value.name; value = restored }; selected = nil } }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("خيارات اللوحة")
            }.font(.subheadline).padding(.horizontal, 16).padding(.vertical, 10)
        }
    }
    private func stage(size: CGSize, globalOrigin: CGPoint) -> some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(white: 0.05), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let screenshot { Image(uiImage: screenshot).resizable().scaledToFill().frame(width: size.width, height: size.height).clipped().allowsHitTesting(false) }
            else { VStack(spacing: 12) { Image(systemName: "globe").font(.system(size: 44, weight: .ultraLight)); Text("ZEUS").font(.largeTitle.weight(.light)); Text("مساحة الصفحة").font(.caption) }.foregroundStyle(.white.opacity(0.25)).frame(width: size.width, height: size.height).allowsHitTesting(false) }
            if !preview {
                Rectangle().fill(.blue.opacity(0.1)).frame(height: size.height * composition.topInset).allowsHitTesting(false)
                Rectangle().fill(.blue.opacity(0.1)).frame(height: size.height * composition.bottomInset).offset(y: size.height * (1 - composition.bottomInset)).allowsHitTesting(false)
            }
            if showGrid && !preview { Canvas { context, canvas in
                var path = Path()
                stride(from: 0.0, through: canvas.width, by: 16).forEach { x in stride(from: 0.0, through: canvas.height, by: 16).forEach { y in path.addEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5)) } }
                context.fill(path, with: .color(.white.opacity(0.16)))
            }.allowsHitTesting(false) }
            Color.clear.contentShape(Rectangle()).onTapGesture { selected = nil }
            if preview, let model {
                let reference = CGSize(width: wide ? 1024 : 430, height: wide ? 768 : 932)
                ChromeRuntimeLayer(model: model, composition: composition, perform: { _ in })
                    .frame(width: reference.width, height: reference.height)
                    .scaleEffect(size.width / reference.width, anchor: .topLeading)
                    .frame(width: size.width, height: size.height, alignment: .topLeading).allowsHitTesting(false)
            }
            ForEach(composition.blocks.filter { (!$0.hidden || !preview) && !(preview && model != nil) }) { block in
                stageBlock(block, size: size, globalOrigin: globalOrigin)
            }
        }
        .coordinateSpace(name: "ChromeStage").environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .contain).accessibilityIdentifier("chromeStudioCanvas")
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.85), value: composition.blocks.map(\.id))
        .dropDestination(for: String.self) { values, point in
            guard let value = values.first, value.hasPrefix("zeus.chrome."), !preview else { return false }
            add(String(value.dropFirst("zeus.chrome.".count)), point: point, size: size); return true
        }
    }
    private func stageBlock(_ block: ChromeBlock, size: CGSize, globalOrigin: CGPoint) -> some View {
        let reference = CGSize(width: wide ? 1024 : 430, height: wide ? 768 : 932)
        let scale = size.width / reference.width
        let real = block.rect(in: reference)
        let rect = CGRect(x: real.minX * scale, y: real.minY * scale, width: real.width * scale, height: real.height * scale)
        let touchFrame = CGRect(x: -(rect.width + 28) / 2, y: -(rect.height + 28) / 2, width: rect.width + 28, height: rect.height + 28)
            .applying(CGAffineTransform(rotationAngle: block.rotation * .pi / 180))
            .offsetBy(dx: globalOrigin.x + rect.midX, dy: globalOrigin.y + rect.midY)
        var appearance = block
        appearance.corner *= Double(scale); appearance.fontSize *= Double(scale); appearance.borderWidth *= Double(scale)
        return ChromeBlockGlyph(block: block, scale: scale)
            .frame(width: rect.width, height: rect.height)
            .modifier(ChromeBlockDecoration(block: appearance))
            .opacity(block.hidden ? 0.3 : 1)
            .overlay { if selected == block.id && !preview { RoundedRectangle(cornerRadius: max(4, appearance.corner)).strokeBorder(.cyan, lineWidth: 2) } }
            .shadow(color: selected == block.id && !preview ? .cyan.opacity(0.25) : .clear, radius: 10)
            .overlay(alignment: .bottomTrailing) {
                if selected == block.id && !preview && !block.locked {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 28, height: 28).background(.cyan, in: Circle()).contentShape(Circle())
                        .accessibilityLabel("اسحب لتغيير الحجم")
                        .offset(x: 14, y: 14)
                        .allowsHitTesting(false)
                }
            }
            .padding(14)
            .contentShape(ChromeStudioHitShape(handle: selected == block.id && !preview && !block.locked))
            .onTapGesture { guard !preview else { return }; selected = block.id }
            .gesture(drag(block, size: size), including: preview || block.locked ? .none : .all)
            .contextMenu {
                Button("الخصائص", systemImage: "slider.horizontal.3") { selected = block.id; inspector = true }
                Button("نسخ", systemImage: "plus.square.on.square") { duplicate(block) }
                Button(block.locked ? "إلغاء القفل" : "قفل", systemImage: "lock") { update(block.id) { $0.locked.toggle() } }
                Button("حذف", systemImage: "trash", role: .destructive) { remove(block.id) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(block.displayTitle).accessibilityHint("اسحب للنقل؛ مقبض الزاوية لتغيير الحجم")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("chromeStudioBlock-" + block.id.uuidString)
            .rotationEffect(.degrees(block.rotation)).position(x: rect.midX, y: rect.midY)
            .accessibilityFrame(touchFrame)
    }
    private func drag(_ block: ChromeBlock, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("ChromeStage"))
            .onChanged { value in
                guard !block.locked, !preview else { return }
                if moveOrigin == nil {
                    let reference = CGSize(width: wide ? 1024 : 430, height: wide ? 768 : 932)
                    let scale = size.width / reference.width, logical = block.rect(in: reference)
                    let rect = CGRect(x: logical.minX * scale, y: logical.minY * scale, width: logical.width * scale, height: logical.height * scale)
                    let angle = -block.rotation * .pi / 180, cosine = CGFloat(cos(angle)), sine = CGFloat(sin(angle))
                    let offset = CGPoint(x: value.startLocation.x - rect.midX, y: value.startLocation.y - rect.midY)
                    let point = CGPoint(x: rect.midX + offset.x * cosine - offset.y * sine, y: rect.midY + offset.x * sine + offset.y * cosine)
                    moveResizes = selected == block.id && point.x > rect.midX + 2 && point.y > rect.midY + 2
                        && hypot(point.x - rect.maxX, point.y - rect.maxY) <= 20
                    checkpoint(); moveOrigin = block; selected = block.id
                }
                guard var changed = moveOrigin, changed.id == block.id else { return }
                let angle = moveResizes ? -block.rotation * .pi / 180 : 0
                let cosine = CGFloat(cos(angle)), sine = CGFloat(sin(angle))
                let dx = (value.translation.width * cosine - value.translation.height * sine) / max(1, size.width)
                let dy = (value.translation.width * sine + value.translation.height * cosine) / max(1, size.height)
                if moveResizes { changed.width += dx; changed.height += dy }
                else { changed.x += dx; changed.y += dy }
                if snap {
                    if moveResizes { changed.width = snapped(changed.width, pixels: size.width); changed.height = snapped(changed.height, pixels: size.height) }
                    else { changed.x = snapped(changed.x, pixels: size.width); changed.y = snapped(changed.y, pixels: size.height) }
                }
                changed.constrain(); replaceBlock(changed)
            }.onEnded { _ in moveOrigin = nil; moveResizes = false }
    }
    private func snapped(_ value: Double, pixels: Double) -> Double { (value * pixels / 8).rounded() * 8 / max(1, pixels) }
    private var palette: some View {
        VStack(spacing: 0) {
            HStack { Text("اسحب عنصرًا إلى اللوحة أو اضغط لإضافته").font(.caption).foregroundStyle(.secondary); Spacer(); Text("\(composition.blocks.count) / 120").font(.caption.monospacedDigit()) }.padding(.horizontal, 16).padding(.top, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ChromeBlockKind.allCases.filter { $0 != .action }) { kind in paletteItem(kind.title, symbol: kind.symbol, token: kind.rawValue) }
                    Divider().frame(height: 34)
                    ForEach(BrowserAction.allCases) { action in paletteItem(action.title, symbol: action.symbol, token: "action:" + action.rawValue) }
                }.padding(12)
            }
        }.background(.regularMaterial)
    }
    private func paletteItem(_ title: String, symbol: String, token: String) -> some View {
        Button { add(token) } label: { VStack(spacing: 7) { Image(systemName: symbol).font(.system(size: 20)); Text(title).font(.system(size: 10)).lineLimit(1) }.frame(width: 82, height: 64).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14)) }
            .buttonStyle(.plain).draggable("zeus.chrome." + token).hoverEffect(.lift).disabled(composition.blocks.count >= 120).accessibilityIdentifier("chromePalette-" + token)
    }
    private var inspectorContent: some View {
        Form {
            Section("التوزيع") {
                TextField("اسم التوزيع", text: Binding(get: { design.name }, set: { value in change { $0.name = String(value.prefix(100)) } }))
                insetSlider("مساحة أعلى الصفحة", top: true)
                insetSlider("مساحة أسفل الصفحة", top: false)
            }
            if let block = selection {
                blockInspector(block)
            } else { Section { Label("اضغط عنصرًا لتعديله", systemImage: "hand.tap"); Text("يمكن تغيير موضع أي عنصر وحجمه مباشرةً على اللوحة. استخدم الطبقات للوصول إلى العناصر المتداخلة.").font(.footnote).foregroundStyle(.secondary) } }
        }.scrollContentBackground(.hidden).environment(\.layoutDirection, .rightToLeft)
    }
    @ViewBuilder private func blockInspector(_ block: ChromeBlock) -> some View {
        Section(block.kind.title) {
            if block.kind == .action {
                Picker("وظيفة الزر", selection: property(\.action, block: block)) { ForEach(BrowserAction.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) } }
                Toggle("عرض اسم الزر", isOn: property(\.showTitle, block: block))
            }
            if block.kind == .label || block.kind == .action { TextField("النص", text: property(\.title, block: block)) }
            if block.kind == .action { TextField("رمز SF Symbols اختياري", text: property(\.symbol, block: block)).textInputAutocapitalization(.never).autocorrectionDisabled() }
            Toggle("قفل الموضع والحجم", isOn: property(\.locked, block: block))
            Toggle("إخفاء العنصر", isOn: property(\.hidden, block: block))
        }
        Section("الموضع والحجم") {
            number("أفقي", \.x, block, 0...1, percent: true)
            number("عمودي", \.y, block, 0...1, percent: true)
            number("العرض", \.width, block, 0.025...1, percent: true)
            number("الارتفاع", \.height, block, 0.025...1, percent: true)
            number("الدوران", \.rotation, block, -180...180)
            HStack { alignButton("يسار", "align.horizontal.left", block, axis: 0, amount: 0); alignButton("وسط", "align.horizontal.center", block, axis: 0, amount: 0.5); alignButton("يمين", "align.horizontal.right", block, axis: 0, amount: 1) }
            HStack { alignButton("أعلى", "align.vertical.top", block, axis: 1, amount: 0); alignButton("منتصف", "align.vertical.center", block, axis: 1, amount: 0.5); alignButton("أسفل", "align.vertical.bottom", block, axis: 1, amount: 1) }
        }.disabled(block.locked)
        Section("المظهر") {
            color("الأيقونة والنص", \.foreground, block)
            color("الخلفية", \.background, block)
            Toggle("خلفية زجاجية", isOn: property(\.glass, block: block))
            number("عتامة اللون", \.opacity, block, 0...1, percent: true)
            number("استدارة الزوايا", \.corner, block, 0...100)
            number("حجم الأيقونة / النص", \.fontSize, block, 10...40)
            color("الإطار", \.border, block)
            number("سُمك الإطار", \.borderWidth, block, 0...8)
        }
        Section("الطبقة") {
            HStack { Button("إلى الأمام", systemImage: "square.3.layers.3d.top.filled") { reorder(block.id, forward: true) }; Spacer(); Button("إلى الخلف", systemImage: "square.3.layers.3d.bottom.filled") { reorder(block.id, forward: false) } }
            Button("نسخ العنصر", systemImage: "plus.square.on.square") { duplicate(block) }
            Button("حذف العنصر", systemImage: "trash", role: .destructive) { remove(block.id) }
        }
    }
    private var layerSheet: some View {
        NavigationStack {
            List {
                ForEach(composition.blocks.reversed()) { block in
                    Button { selected = block.id; layers = false } label: {
                        HStack { Image(systemName: block.displaySymbol); Text(block.displayTitle); Spacer(); if block.hidden { Image(systemName: "eye.slash") }; if block.locked { Image(systemName: "lock") }; if selected == block.id { Image(systemName: "checkmark") } }
                    }.contextMenu { Button("إلى الأمام") { reorder(block.id, forward: true) }; Button("إلى الخلف") { reorder(block.id, forward: false) }; Button("حذف", role: .destructive) { remove(block.id) } }
                }
                .onMove { source, destination in
                    change { value in var c = value.composition(wide: wide); var ordered = Array(c.blocks.reversed()); ordered.move(fromOffsets: source, toOffset: destination); c.blocks = Array(ordered.reversed()); value.set(c, wide: wide) }
                }
            }.navigationTitle("الطبقات — الأعلى في المقدمة").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { EditButton() }; ToolbarItem(placement: .topBarTrailing) { Button("تم") { layers = false } } }
        }.presentationDetents([.medium, .large])
    }
    private func insetSlider(_ title: String, top: Bool) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption)
            Slider(value: Binding(get: { top ? composition.topInset : composition.bottomInset }, set: { value in change { design in var c = design.composition(wide: wide); if top { c.topInset = value } else { c.bottomInset = value }; design.set(c, wide: wide) } }), in: 0...0.4, onEditingChanged: sliderChanged)
        }
    }
    private func property<T>(_ path: WritableKeyPath<ChromeBlock, T>, block: ChromeBlock) -> Binding<T> {
        Binding(get: { composition.blocks.first { $0.id == block.id }?[keyPath: path] ?? block[keyPath: path] }, set: { value in update(block.id) { $0[keyPath: path] = value; $0.constrain() } })
    }
    private func number(_ title: String, _ path: WritableKeyPath<ChromeBlock, Double>, _ block: ChromeBlock, _ range: ClosedRange<Double>, percent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) { HStack { Text(title); Spacer(); Text("\(Int(block[keyPath: path] * (percent ? 100 : 1)))\(percent ? "٪" : "")").monospacedDigit().foregroundStyle(.secondary) }.font(.caption); Slider(value: property(path, block: block), in: range, onEditingChanged: sliderChanged) }
    }
    private func color(_ title: String, _ path: WritableKeyPath<ChromeBlock, String>, _ block: ChromeBlock) -> some View {
        ColorPicker(title, selection: Binding(get: { BrowserTheme.color(block[keyPath: path]) }, set: { color in update(block.id) { $0[keyPath: path] = BrowserTheme.hex(color) } }), supportsOpacity: true)
    }
    private func alignButton(_ title: String, _ symbol: String, _ block: ChromeBlock, axis: Int, amount: Double) -> some View {
        Button { update(block.id) { if axis == 0 { $0.x = (1 - $0.width) * amount } else { $0.y = (1 - $0.height) * amount } } } label: { Image(systemName: symbol).frame(maxWidth: .infinity).frame(height: 32) }.buttonStyle(.bordered).accessibilityLabel(title)
    }
    private func add(_ token: String, point: CGPoint? = nil, size: CGSize = CGSize(width: 800, height: 600)) {
        guard composition.blocks.count < 120 else { return }
        let action = token.hasPrefix("action:") ? BrowserAction(rawValue: String(token.dropFirst(7))) : nil
        guard action != nil || ChromeBlockKind(rawValue: token) != nil else { return }
        var block = ChromeBlock(kind: action == nil ? ChromeBlockKind(rawValue: token)! : .action)
        if let action { block.action = action.rawValue }
        switch block.kind { case .address: block.width = 0.5; case .tabs, .bookmarks: block.width = 0.7; case .panel: block.width = 0.5; block.height = 0.15; case .label: block.width = 0.25; block.title = "نص جديد"; default: break }
        if let point { block.x = point.x / max(1, size.width) - block.width / 2; block.y = point.y / max(1, size.height) - block.height / 2 }
        else { block.x = 0.15 + Double(composition.blocks.count % 8) * 0.025; block.y = 0.2 + Double(composition.blocks.count % 8) * 0.025 }
        block.constrain(); change { var c = $0.composition(wide: wide); c.blocks.append(block); $0.set(c, wide: wide) }; selected = block.id
    }
    private func duplicate(_ block: ChromeBlock) {
        guard composition.blocks.count < 120 else { return }; var copy = block; copy.id = UUID(); copy.x += 0.025; copy.y += 0.025; copy.constrain()
        change { var c = $0.composition(wide: wide); c.blocks.append(copy); $0.set(c, wide: wide) }; selected = copy.id
    }
    private func remove(_ id: UUID) { change { var c = $0.composition(wide: wide); c.blocks.removeAll { $0.id == id }; $0.set(c, wide: wide) }; if selected == id { selected = nil } }
    private func reorder(_ id: UUID, forward: Bool) {
        change { var c = $0.composition(wide: wide); guard let index = c.blocks.firstIndex(where: { $0.id == id }) else { return }; let target = forward ? min(c.blocks.count - 1, index + 1) : max(0, index - 1); c.blocks.swapAt(index, target); $0.set(c, wide: wide) }
    }
    private func update(_ id: UUID, _ edit: (inout ChromeBlock) -> Void) { change { var c = $0.composition(wide: wide); guard let index = c.blocks.firstIndex(where: { $0.id == id }) else { return }; edit(&c.blocks[index]); $0.set(c, wide: wide) } }
    private func replaceBlock(_ block: ChromeBlock) { var c = composition; guard let index = c.blocks.firstIndex(where: { $0.id == block.id }) else { return }; c.blocks[index] = block; design.set(c, wide: wide) }
    private func checkpoint() { initialized = true; undo.append(design); if undo.count > 80 { undo.removeFirst() }; redo.removeAll() }
    private func sliderChanged(_ editing: Bool) { if editing { checkpoint() }; sliderEditing = editing }
    private func change(_ edit: (inout ChromeDesign) -> Void) { initialized = true; let prior = design; edit(&design); if prior != design && !sliderEditing { undo.append(prior); if undo.count > 80 { undo.removeFirst() }; redo.removeAll() } }
    private func restoreUndo() { guard let value = undo.popLast() else { return }; redo.append(design); design = value; selected = nil }
    private func restoreRedo() { guard let value = redo.popLast() else { return }; undo.append(design); design = value; selected = nil }
}

private struct ChromeStudioHitShape: Shape {
    var handle: Bool
    func path(in rect: CGRect) -> Path {
        let body = rect.insetBy(dx: 14, dy: 14)
        var path = Path(); path.addRect(body)
        if handle { path.addEllipse(in: CGRect(x: body.maxX - 14, y: body.maxY - 14, width: 28, height: 28)) }
        return path
    }
}
