import SwiftUI
import ZEUSBrowser

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
    func install(forceLocal: Bool = false) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            guard let root = Bundle.main.url(forResource: "ZEUSDefaultSkills", withExtension: nil) else {
                throw ZeusPatch.failure("ملفات المهارات الافتراضية غير موجودة في هذه النسخة.")
            }
            let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
            entries = catalog.skills
            guard forceLocal || (NativeCloudAccountAPI.ownerID != nil && !NativeCloudAccountAPI.usesCloud) else { return }
            guard UserDefaults.standard.string(forKey: revisionKey) != catalog.revision || (forceLocal && entries.contains(where: { entry in
                guard let skill = SkillStore.shared.skills.first(where: { $0.name == entry.installedName }) else { return false }
                return !FileManager.default.fileExists(atPath: SkillStore.shared.skillDirectoryURL(for: skill.id).appendingPathComponent("SKILL.md").path)
            })) else { return }
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
                let skill: Skill
                if let existing = SkillStore.shared.skills.first(where: { $0.name == parsedName }) {
                    if FileManager.default.fileExists(atPath: SkillStore.shared.skillDirectoryURL(for: existing.id).appendingPathComponent("SKILL.md").path) { continue }
                    skill = existing
                    let directory = SkillStore.shared.skillDirectoryURL(for: skill.id)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try Data(content.utf8).write(to: directory.appendingPathComponent("SKILL.md"), options: .atomic)
                } else { skill = try SkillStore.shared.importSkill(content: content, source: .bundled) }
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
    /// Only byte-identical catalog files are reproducible. Custom edits remain
    /// user data even if the skill was originally shipped with the application.
    func bundledCopies() throws -> [String: Data] {
        guard let root = Bundle.main.url(forResource: "ZEUSDefaultSkills", withExtension: nil) else { return [:] }
        var copies: [String: Data] = [:]
        for entry in entries {
            guard let skill = SkillStore.shared.skills.first(where: { $0.name == entry.installedName }) else { continue }
            let source = root.appendingPathComponent(entry.directory)
            let destination = SkillStore.shared.skillDirectoryURL(for: skill.id)
            guard let files = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let file as URL in files {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let relative = String(file.path.dropFirst(source.path.count + 1))
                var data = try Data(contentsOf: file)
                if relative == "SKILL.md", let text = String(data: data, encoding: .utf8) {
                    let regex = try NSRegularExpression(pattern: "(?m)^name:.*$")
                    data = Data(regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "name: " + entry.installedName).utf8)
                }
                copies[destination.appendingPathComponent(relative).path] = data
            }
        }
        return copies
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
