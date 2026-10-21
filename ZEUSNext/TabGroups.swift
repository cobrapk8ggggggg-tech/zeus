import SwiftUI
import UniformTypeIdentifiers

struct TabGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var color: String
    var collapsed = false
}

extension BrowserModel {
    var groups: [TabGroup] { data.tabGroups ?? [] }
    func group(for tab: BrowserTab) -> TabGroup? { groups.first { $0.id == tab.groupID } }
    @discardableResult func createGroup(name: String, color: String, tab: BrowserTab) -> UUID? {
        guard tabs.contains(where: { $0.id == tab.id }), tab.profileID == profile.id else { return nil }
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let group = TabGroup(name: clean.isEmpty ? "مجلد جديد" : clean, color: color)
        data.tabGroups = groups + [group]; tab.groupID = group.id; changed(); persist(); return group.id
    }
    func assign(_ tab: BrowserTab, to groupID: UUID?) {
        guard tabs.contains(where: { $0.id == tab.id }), tab.profileID == profile.id,
              groupID == nil || groups.contains(where: { $0.id == groupID }) else { return }
        tab.groupID = groupID
        if let i = data.tabGroups?.firstIndex(where: { $0.id == groupID }) { data.tabGroups?[i].collapsed = false }
        changed(); persist()
    }
    func toggleGroup(_ id: UUID) {
        guard let i = data.tabGroups?.firstIndex(where: { $0.id == id }) else { return }
        data.tabGroups?[i].collapsed.toggle(); persist()
    }
    func removeGroup(_ id: UUID) {
        for tab in tabs where tab.groupID == id { tab.groupID = nil }
        data.tabGroups?.removeAll { $0.id == id }; changed(); persist()
    }
    func moveTab(_ id: UUID, before target: UUID) {
        guard id != target, let from = tabs.firstIndex(where: { $0.id == id }), let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(to, tabs.count))
        persist()
    }
}

private struct TabAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) { value.merge(nextValue()) { _, new in new } }
}
private struct TabToken: Identifiable {
    var id: String
    var tab: BrowserTab?
    var group: TabGroup?
}

/// The same identities, menu and drag/drop are used in all three layouts.
struct BrowserTabCollection: View {
    @ObservedObject var model: BrowserModel
    var compact = false
    var grid = false
    var selected: () -> Void = {}
    @Environment(\.browserTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var creating: BrowserTab?
    @State private var groupName = ""
    @State private var groupColor = "64A8FF"
    @State private var drawing: CGFloat = 1
    @State private var dragging: UUID?
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86) }
    private var tokens: [TabToken] {
        var seen = Set<UUID>(), result: [TabToken] = []
        for tab in model.tabs {
            if let group = model.group(for: tab) {
                if seen.insert(group.id).inserted { result.append(TabToken(id: "g" + group.id.uuidString, group: group)) }
                if group.collapsed { continue }
            }
            result.append(TabToken(id: tab.id.uuidString, tab: tab))
        }
        for group in model.groups where !seen.contains(group.id) { result.append(TabToken(id: "g" + group.id.uuidString, group: group)) }
        return result
    }
    var body: some View {
        Group {
            if grid { LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], spacing: 18) { cells } }
            else { HStack(alignment: .center, spacing: compact ? 5 : 14) { cells } }
        }
        .overlayPreferenceValue(TabAnchorKey.self) { anchors in
            GeometryReader { geometry in
                ForEach(model.groups.filter { !$0.collapsed }) { group in
                    connector(group, anchors: anchors, geometry: geometry)
                        .trim(from: 0, to: drawing).stroke(BrowserTheme.color(group.color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }.allowsHitTesting(false)
        }
        .animation(motion, value: tokens.map(\.id))
        .sheet(item: $creating) { tab in
            NavigationStack {
                Form {
                    Section("المجلد") { TextField("اسم المجلد", text: $groupName).accessibilityIdentifier("tabGroupName"); ColorPicker("اللون", selection: Binding(get: { BrowserTheme.color(groupColor) }, set: { groupColor = BrowserTheme.hex($0) }), supportsOpacity: false) }
                    Section { HStack { ForEach(["64A8FF", "BF86F5", "F0BB55", "63CE9E", "EF8097", "A0A0A0"], id: \.self) { color in Button { groupColor = color } label: { Circle().fill(BrowserTheme.color(color)).frame(width: 30, height: 30).overlay { if color == groupColor { Image(systemName: "checkmark").foregroundStyle(.black) } } } } }
                }.navigationTitle("مجلد تبويبات جديد").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { creating = nil } }; ToolbarItem(placement: .confirmationAction) { Button("إنشاء") { animateAssignment { _ = model.createGroup(name: groupName, color: groupColor, tab: tab) }; creating = nil }.accessibilityIdentifier("createTabGroup") } }
            }.environment(\.layoutDirection, .rightToLeft).presentationDetents([.height(310)]).presentationDragIndicator(.visible).browserTheme(theme)
        }
    }
    @ViewBuilder private var cells: some View {
        ForEach(tokens) { token in
            Group {
                if let tab = token.tab { tabCell(tab) }
                else if let group = token.group { groupCell(group) }
            }.anchorPreference(key: TabAnchorKey.self, value: .bounds) { [token.id: $0] }
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .scale(scale: 0.05, anchor: .leading).combined(with: .opacity), removal: .scale(scale: 0.05, anchor: .leading).combined(with: .opacity)))
        }
    }
    private func tabCell(_ tab: BrowserTab) -> some View {
        HStack(spacing: compact ? 7 : 0) {
            Button { model.selectTab(tab); selected() } label: {
                Group {
                    if compact {
                        HStack(spacing: 7) { icon(tab, size: 23); Text(tab.title).font(.caption).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading) }.frame(width: 150)
                    } else {
                        VStack(spacing: 14) { icon(tab, size: 38); Text(tab.title).font(.caption.bold()).lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity) }.padding(10).frame(width: 115, height: 158)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("tab-" + tab.id.uuidString)
            if compact { close(tab) }
        }
        .padding(.horizontal, compact ? 9 : 0).frame(height: compact ? 38 : 180)
        .foregroundStyle(model.current?.id == tab.id ? theme.selectionTextColor : theme.textColor)
        .background(model.current?.id == tab.id ? theme.selectionColor : theme.surfaceColor, in: RoundedRectangle(cornerRadius: compact ? 5 : 15))
        .overlay(alignment: .topTrailing) { if !compact { close(tab) } }
        .contextMenu {
            Button("إنشاء مجلد", systemImage: "folder.badge.plus") { groupName = ""; creating = tab }
            Menu("نقل إلى مجلد", systemImage: "folder") { ForEach(model.groups) { group in Button(group.name) { animateAssignment { model.assign(tab, to: group.id) } } } }.disabled(model.groups.isEmpty)
            if tab.groupID != nil { Button("إخراج من المجلد", systemImage: "folder.badge.minus") { withAnimation(motion) { model.assign(tab, to: nil) } } }
            Button("إضافة للمفضلة", systemImage: "star") { if model.profile.role != .guest && !tab.isHome { model.data.bookmarks.append(Bookmark(title: tab.title, url: tab.url)); model.persist() } }
            Button("إغلاق التبويب", systemImage: "xmark", role: .destructive) { model.closeTab(tab) }
        }
        .onDrag { dragging = tab.id; return NSItemProvider(object: (model.profile.id.uuidString + ":" + tab.id.uuidString) as NSString) }
        .onDrop(of: [.text], delegate: TabReorderDrop(model: model, target: tab.id, dragging: $dragging, animation: motion))
    }
    private func icon(_ tab: BrowserTab, size: CGFloat) -> some View {
        FirstPartyFavicon(site: Bookmark(title: tab.title, url: tab.url), size: size, monochrome: false, iconURL: tab.faviconURL).frame(width: size, height: size).fixedSize().layoutPriority(2)
    }
    private func close(_ tab: BrowserTab) -> some View {
        Button { withAnimation(motion) { model.closeTab(tab) } } label: { Image(systemName: "xmark").font(.caption).padding(8) }.buttonStyle(.plain).accessibilityLabel("إغلاق " + tab.title)
    }
    private func groupCell(_ group: TabGroup) -> some View {
        Button { withAnimation(motion) { model.toggleGroup(group.id) } } label: {
            HStack(spacing: 6) { Image(systemName: group.collapsed ? "chevron.right" : "chevron.down"); Text(group.name).lineLimit(1); Text("\(model.tabs.filter { $0.groupID == group.id }.count)").monospacedDigit() }
                .font(.caption.bold()).padding(.horizontal, 10).frame(height: 32).frame(maxWidth: compact ? 160 : 145)
                .foregroundStyle(.black).background(BrowserTheme.color(group.color), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityIdentifier("tab-group-" + group.id.uuidString)
            .contextMenu { Button("فك المجلد وإبقاء التبويبات", systemImage: "folder.badge.minus") { withAnimation(motion) { model.removeGroup(group.id) } } }
            .dropDestination(for: String.self) { items, _ in
                guard let value = items.first, value.hasPrefix(model.profile.id.uuidString + ":"), let id = UUID(uuidString: String(value.suffix(36))), let tab = model.tabs.first(where: { $0.id == id }) else { return false }
                animateAssignment { model.assign(tab, to: group.id) }; dragging = nil; return true
            }
    }
    private func animateAssignment(_ action: () -> Void) {
        drawing = reduceMotion ? 1 : 0
        withAnimation(motion, action)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.65).delay(0.12)) { drawing = 1 }
    }
    private func connector(_ group: TabGroup, anchors: [String: Anchor<CGRect>], geometry: GeometryProxy) -> Path {
        var path = Path()
        guard let label = anchors["g" + group.id.uuidString] else { return path }
        let origin = geometry[label]
        var previous = CGPoint(x: origin.maxX, y: origin.midY)
        for tab in model.tabs where tab.groupID == group.id {
            guard let anchor = anchors[tab.id.uuidString] else { continue }
            let rect = geometry[anchor].insetBy(dx: 1.5, dy: 1.5)
            // A continuous thread with a U border: the top edge stays open.
            path.move(to: previous)
            path.addLine(to: CGPoint(x: previous.x, y: rect.maxY + 3))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY + 3))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 6))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 6))
            previous = CGPoint(x: rect.maxX, y: rect.maxY)
        }
        return path
    }
}

private struct TabReorderDrop: DropDelegate {
    let model: BrowserModel
    let target: UUID
    @Binding var dragging: UUID?
    let animation: Animation?
    func dropEntered(info: DropInfo) {
        guard let id = dragging, id != target else { return }
        withAnimation(animation) { model.moveTab(id, before: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}
