import Foundation
import CoreGraphics

enum ChromeBlockKind: String, Codable, CaseIterable, Identifiable {
    case action, address, tabs, bookmarks, label, panel
    var id: String { rawValue }
    var title: String { switch self { case .action: return "زر"; case .address: return "شريط العنوان"; case .tabs: return "التبويبات"; case .bookmarks: return "المفضلة"; case .label: return "نص"; case .panel: return "خلفية / شكل" } }
    var symbol: String { switch self { case .action: return "hand.tap"; case .address: return "magnifyingglass"; case .tabs: return "square.on.square"; case .bookmarks: return "bookmark"; case .label: return "textformat"; case .panel: return "rectangle.roundedtop" } }
}
struct ChromeBlock: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: ChromeBlockKind
    var action = BrowserAction.tools.rawValue
    var title = ""
    var symbol = ""
    // Unit-space coordinates keep layouts responsive to split/rotation.
    var x: Double = 0.1, y: Double = 0.1, width: Double = 0.065, height: Double = 0.06
    var corner: Double = 14
    var fontSize: Double = 18
    var foreground = "FFFFFF"
    var background = "202020"
    var opacity: Double = 0.85
    var glass = true
    var showTitle = false
    var border = "FFFFFF"
    var borderWidth: Double = 0
    var locked = false
    var hidden = false
    var rotation: Double = 0
    var displayTitle: String { title.isEmpty ? (kind == .action ? BrowserAction(rawValue: action)?.title ?? kind.title : kind.title) : title }
    var displaySymbol: String { symbol.isEmpty ? (kind == .action ? BrowserAction(rawValue: action)?.symbol ?? "questionmark" : kind.symbol) : symbol }
    func rect(in size: CGSize) -> CGRect {
        let w = min(size.width, max(kind == .panel ? 8 : 44, width * size.width))
        let h = min(size.height, max(kind == .panel ? 8 : 44, height * size.height))
        return CGRect(x: min(max(0, x * size.width), max(0, size.width - w)), y: min(max(0, y * size.height), max(0, size.height - h)), width: w, height: h)
    }
    mutating func constrain() {
        width = min(1, max(0.025, width)); height = min(1, max(0.025, height))
        x = min(1 - width, max(0, x)); y = min(1 - height, max(0, y))
    }
    func validated() -> Bool {
        [x, y, width, height, corner, fontSize, opacity, borderWidth, rotation].allSatisfy(\.isFinite)
        && (0...1).contains(x) && (0...1).contains(y) && (0.025...1).contains(width) && (0.025...1).contains(height)
        && (0...100).contains(corner) && (10...40).contains(fontSize) && (0...1).contains(opacity)
        && (0...8).contains(borderWidth) && (-180...180).contains(rotation)
        && title.utf8.count <= 500 && symbol.utf8.count <= 100
        && (kind != .action || BrowserAction(rawValue: action) != nil)
        && [foreground, background, border].allSatisfy { $0.range(of: "^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$", options: .regularExpression) != nil }
    }
}
struct ChromeComposition: Codable, Equatable {
    var blocks: [ChromeBlock] = []
    var topInset: Double = 0
    var bottomInset: Double = 0
    func validated() -> Bool {
        blocks.count <= 120 && Set(blocks.map(\.id)).count == blocks.count && blocks.allSatisfy { $0.validated() }
        && topInset.isFinite && bottomInset.isFinite && (0...0.4).contains(topInset) && (0...0.4).contains(bottomInset)
    }
}
struct ChromeDesign: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var base: ChromeLayout?
    var portrait: ChromeComposition
    var landscape: ChromeComposition
    func composition(wide: Bool) -> ChromeComposition { wide ? landscape : portrait }
    mutating func set(_ value: ChromeComposition, wide: Bool) { if wide { landscape = value } else { portrait = value } }
    func validated() -> Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 200 && portrait.validated() && landscape.validated() }
    static func preset(_ layout: ChromeLayout) -> ChromeDesign {
        func make(wide: Bool) -> ChromeComposition {
            let screenW: Double = wide ? 1024 : 430, screenH: Double = wide ? 768 : 932
            var result = ChromeComposition()
            func add(_ kind: ChromeBlockKind, _ action: BrowserAction, _ x: Double, _ y: Double, _ w: Double, _ h: Double) {
                var b = ChromeBlock(kind: kind); b.action = action.rawValue
                b.x = x / screenW; b.y = y / screenH; b.width = w / screenW; b.height = h / screenH
                if kind == .panel { b.glass = true; b.opacity = 0.92; b.corner = 18 }
                if kind == .action { b.background = "000000"; b.opacity = 0.2 }
                b.constrain(); result.blocks.append(b)
            }
            func add(_ kind: ChromeBlockKind, _ x: Double, _ y: Double, _ w: Double, _ h: Double) { add(kind, .tools, x, y, w, h) }
            switch layout {
            case .icab:
                add(.panel, 0, 0, screenW, 148)
                let left: [BrowserAction] = wide ? [.library, .share, .tabs, .back, .forward] : [.back, .forward]
                for (index, action) in left.enumerated() { add(.action, action, 4 + Double(index) * 46, 5, 44, 44) }
                let start = 8 + Double(left.count) * 46
                add(.address, start, 5, screenW - start - 104, 44)
                add(.action, .assistant, screenW - 96, 5, 44, 44); add(.action, .profiles, screenW - 48, 5, 44, 44)
                add(.bookmarks, 8, 53, wide ? screenW - 390 : 190, 44)
                let actions: [BrowserAction] = wide ? [.home, .reader, .scripts, .downloads, .fullScreen, .settings, .tools] : [.reader, .downloads, .settings, .tools]
                let first = screenW - Double(actions.count) * 46 - 4
                for (index, action) in actions.enumerated() { add(.action, action, first + Double(index) * 46, 53, 44, 44) }
                add(.tabs, 8, 101, screenW - 64, 44); add(.action, .newTab, screenW - 48, 101, 44, 44)
                result.topInset = 152 / screenH
            case .dualBars:
                add(.panel, 0, 0, screenW, 52)
                add(.action, .profiles, 8, 4, 44, 44); add(.action, .assistant, screenW - 100, 4, 44, 44); add(.action, .settings, screenW - 52, 4, 44, 44)
                add(.panel, 0, screenH - 108, screenW, 108); add(.address, 8, screenH - 104, screenW - 16, 44)
                for (index, action) in [BrowserAction.back, .forward, .library, .downloads, .tabs, .tools].enumerated() { add(.action, action, Double(index) * (screenW / 6) + (screenW / 6 - 44) / 2, screenH - 52, 44, 44) }
                result.topInset = 56 / screenH; result.bottomInset = 112 / screenH
            case .original:
                let actions: [BrowserAction] = [.assistant, .back, .forward, .reload, .home, .newTab, .library, .history, .reader, .gallery, .console, .scripts, .darkPage, .tools]
                let height = min(screenH - 60, Double(actions.count) * 46 + 16)
                add(.panel, screenW - 64, (screenH - height) / 2, 64, height)
                for (index, action) in actions.enumerated() { add(.action, action, screenW - 54, (screenH - height) / 2 + 8 + Double(index) * 46, 44, 44) }
            }
            return result
        }
        return ChromeDesign(name: layout.title, base: layout, portrait: make(wide: false), landscape: make(wide: true))
    }
}
struct ChromeWorkspace: Codable, Equatable {
    var designs: [ChromeDesign] = []
    var selected: UUID?
    func active(for base: ChromeLayout) -> ChromeDesign? {
        if let selected, let custom = designs.first(where: { $0.id == selected }) { return custom }
        return designs.first { $0.base == base }
    }
    func validated() -> Bool {
        designs.count <= 24 && Set(designs.map(\.id)).count == designs.count && designs.allSatisfy { $0.validated() }
        && Set(designs.compactMap(\.base)).count == designs.compactMap(\.base).count
        && (selected == nil || designs.contains { $0.id == selected })
    }
}
