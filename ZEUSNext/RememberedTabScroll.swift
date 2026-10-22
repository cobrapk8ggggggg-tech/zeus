import SwiftUI

/// Coordinate positions belong to the profile and layout, not the lifetime of a tray.
struct RememberedTabScroll<Content: View>: View {
    @ObservedObject var model: BrowserModel
    let key: String
    var axis: Axis.Set = .horizontal
    @ViewBuilder var content: () -> Content
    @State private var position = ScrollPosition()
    @State private var restored = false
    @State private var saveTask: Task<Void, Never>?
    var body: some View {
        ScrollView(axis, showsIndicators: false) { content() }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                axis == .horizontal ? geometry.contentOffset.x + geometry.contentInsets.leading : geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                guard restored, offset.isFinite else { return }
                if model.data.tabScrollOffsets == nil { model.data.tabScrollOffsets = [:] }
                model.data.tabScrollOffsets?[key] = max(0, Double(offset))
                saveTask?.cancel()
                saveTask = Task { try? await Task.sleep(for: .milliseconds(400)); guard !Task.isCancelled else { return }; model.persist() }
            }
            .task(id: model.profile.id) {
                restored = false
                let offset = model.data.tabScrollOffsets?[key] ?? 0
                // Let the content obtain its real width/height before restoring.
                await Task.yield()
                if axis == .horizontal { position.scrollTo(x: offset) } else { position.scrollTo(y: offset) }
                await Task.yield()
                restored = true
            }
            .onDisappear { saveTask?.cancel(); model.persist() }
    }
}
