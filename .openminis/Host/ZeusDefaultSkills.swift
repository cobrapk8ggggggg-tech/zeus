import SwiftUI

@MainActor final class ZeusDefaultSkills: ObservableObject {
    static let shared = ZeusDefaultSkills()
    struct Catalog: Decodable {
        let revision: String
        let repository: String
        let skills: [Entry]
    }
    struct Entry: Decodable, Identifiable {
        let directory: String
        let name: String
        let plugin: String
        let url: String
        let installedName: String
        var id: String { directory }
    }
    @Published var entries: [Entry] = []
    @Published var error: String?
    @Published var busy = false
    private let revisionKey = "zeus.defaultSkills.revision"
    func install() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            guard let root = Bundle.main.url(forResource: "ZEUSDefaultSkills", withExtension: nil) else {
                throw ZeusPatch.failure("ملفات المهارات الافتراضية غير موجودة في هذه النسخة.")
            }
            let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
            entries = catalog.skills
            guard UserDefaults.standard.string(forKey: revisionKey) != catalog.revision else { return }
            for entry in entries {
                let source = root.appendingPathComponent(entry.directory)
                let original = try String(contentsOf: source.appendingPathComponent("SKILL.md"), encoding: .utf8)
                let pattern = try NSRegularExpression(pattern: "(?m)^name:.*$")
                let match = pattern.firstMatch(in: original, range: NSRange(original.startIndex..., in: original))
                var content = original
                if let match, let range = Range(match.range, in: original) { content.replaceSubrange(range, with: "name: " + entry.installedName) }
                // Preserve user edits/deletions after initial installation. The
                // original SkillStore controls enablement, sync and discovery.
                let parsedName = SkillStore.parse(skillMD: content).name
                if SkillStore.shared.skills.contains(where: { $0.name == parsedName }) { continue }
                let skill = try SkillStore.shared.importSkill(content: content, source: .bundled)
                let destination = SkillStore.shared.skillDirectoryURL(for: skill.id)
                for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where file.lastPathComponent != "SKILL.md" {
                    let target = destination.appendingPathComponent(file.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: file, to: target) }
                }
            }
            UserDefaults.standard.set(catalog.revision, forKey: revisionKey)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct ZeusDefaultSkillsView: View {
    @ObservedObject private var store = ZeusDefaultSkills.shared
    var body: some View {
        List {
            NavigationLink("إدارة المهارات وتفعيلها") { SkillsManagementView() }
            ForEach(store.entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name)
                    Text(entry.plugin).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = store.error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("مهارات OpenAI الرسمية").task { await store.install() }
    }
}
