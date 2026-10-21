import Foundation

@MainActor final class ReaderTranslation: ObservableObject {
    @Published var title: String?
    @Published var paragraphs: [String]?
    @Published var running = false
    @Published var completed = 0
    @Published var error: String?
    @Published var suggested = false
    private var task: Task<Void, Never>?
    private var context = UUID()
    func prepare(article: ReaderArticle, model: BrowserModel) {
        let p = model.data.settings.translation ?? TranslationPreferences()
        let language = PageTranslation.detect(sample: article.paragraphs.prefix(8).joined(separator: "\n"), hint: "")
        suggested = p.suggest && !language.isEmpty && language != p.target.components(separatedBy: "-")[0]
        if p.automatic && !language.isEmpty && language != p.target.components(separatedBy: "-")[0] { translate(article: article, model: model) }
    }
    func cancel() { task?.cancel(); task = nil; running = false; let old = context; context = UUID(); Task { await AIProviderService.shared.end(old) } }
    func restore() { cancel(); title = nil; paragraphs = nil; error = nil; completed = 0; suggested = false }
    func translate(article: ReaderArticle, model: BrowserModel) {
        guard !running else { return }; error = nil; running = true; completed = 0; suggested = false
        let prefs = model.data.settings.translation ?? TranslationPreferences(), owner = model.profile.id
        let provider = model.data.settings.aiProviders?.first { $0.id == prefs.providerID }
        let secret = AISecretVault.read(profile: owner, provider: prefs.engine == .googleCloud ? "google-cloud" : provider?.id.uuidString ?? "")
        let id = context
        task = Task {
            do {
                let originals = [article.title] + article.paragraphs; var results: [String] = []
                for start in stride(from: 0, to: originals.count, by: 16) {
                    let batch = originals[start..<min(start + 16, originals.count)].enumerated().map { TranslationSegment(id: String(start + $0.offset), text: $0.element) }
                    let values = try await TextTranslationService.translate(batch, preferences: prefs, provider: provider, secret: secret, context: id)
                    try Task.checkCancellation(); guard owner == model.profile.id, !model.requiresUnlock, id == context else { throw CancellationError() }
                    results += values.map(\.text); completed = results.count
                    title = results.first; paragraphs = Array(results.dropFirst()) + article.paragraphs.dropFirst(max(0, results.count - 1))
                }
            } catch is CancellationError { } catch { if id == context { self.error = error.localizedDescription } }
            if id == context { running = false }
        }
    }
}
