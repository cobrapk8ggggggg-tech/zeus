import Foundation

/// Native implementation of the documented Codex apply_patch grammar.
/// Exact context is required. All hunks and paths are validated before any write.
enum ZeusPatch {
    struct Change { let path: String; let before: Data?; let after: Data? }
    static func failure(_ message: String) -> NSError { NSError(domain: "ZeusPatch", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func safeURL(_ path: String, root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains(".."), !path.split(separator: "/").contains(".git") else { throw failure("Patch path must stay inside workdir and outside .git: \(path)") }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path + "/") else { throw failure("Patch path escapes workdir: \(path)") }
        return url
    }
    static func prepare(_ patch: String, root: URL) throws -> [Change] {
        var lines = patch.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.first == "*** Begin Patch", lines.last == "*** End Patch" else { throw failure("Expected complete *** Begin Patch / *** End Patch framing.") }
        var index = 1, staged: [String: Data?] = [:], before: [String: Data?] = [:], order: [String] = []
        func read(_ path: String) throws -> Data? {
            if let existing = staged[path] { return existing }
            let url = try safeURL(path, root: root)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular, ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 5_000_000 else { throw failure("Patch target is not a text-sized regular file: \(path)") }
            return try Data(contentsOf: url)
        }
        func stage(_ path: String, _ data: Data?) throws {
            _ = try safeURL(path, root: root)
            if !order.contains(path) { before[path] = .some(try read(path)); order.append(path) }
            staged[path] = .some(data)
        }
        while index < lines.count - 1 {
            let header = lines[index]; index += 1
            if header.hasPrefix("*** Add File: ") {
                let path = String(header.dropFirst(14)); guard try read(path) == nil else { throw failure("Add target already exists: \(path)") }
                var added: [String] = []
                while index < lines.count - 1, !lines[index].hasPrefix("*** ") {
                    guard lines[index].hasPrefix("+") else { throw failure("An Add File line must begin with +.") }
                    added.append(String(lines[index].dropFirst())); index += 1
                }
                try stage(path, Data((added.joined(separator: "\n") + "\n").utf8))
            } else if header.hasPrefix("*** Delete File: ") {
                let path = String(header.dropFirst(17)); guard try read(path) != nil else { throw failure("Delete target does not exist: \(path)") }; try stage(path, nil)
            } else if header.hasPrefix("*** Update File: ") {
                let path = String(header.dropFirst(17))
                guard let bytes = try read(path), var text = String(data: bytes, encoding: .utf8) else { throw failure("Update target is not UTF-8 text: \(path)") }
                var destination = path
                if index < lines.count - 1, lines[index].hasPrefix("*** Move to: ") {
                    destination = String(lines[index].dropFirst(13)); index += 1
                    guard try read(destination) == nil else { throw failure("Move destination already exists: \(destination)") }
                }
                var cursor = text.startIndex, hunks = 0
                while index < lines.count - 1, !lines[index].hasPrefix("*** ") || lines[index] == "*** End of File" {
                    if lines[index] == "*** End of File" {
                        guard text[cursor...].allSatisfy({ $0 == "\n" }) else { throw failure("End-of-file hunk did not match the file end: \(path)") }
                        index += 1; continue
                    }
                    guard lines[index].hasPrefix("@@") else { throw failure("Expected @@ before an update hunk.") }; index += 1
                    var old: [String] = [], new: [String] = []
                    while index < lines.count - 1, !lines[index].hasPrefix("@@"), !lines[index].hasPrefix("*** ") {
                        let line = lines[index]; index += 1
                        guard let prefix = line.first, " +-".contains(prefix) else { throw failure("Malformed patch hunk line.") }
                        if prefix != "+" { old.append(String(line.dropFirst())) }
                        if prefix != "-" { new.append(String(line.dropFirst())) }
                    }
                    let needle = old.joined(separator: "\n"), replacement = new.joined(separator: "\n")
                    guard !needle.isEmpty, let range = text.range(of: needle, range: cursor..<text.endIndex) else { throw failure("Patch context does not match \(path). Read the current file before retrying.") }
                    guard range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)] == "\n",
                          range.upperBound == text.endIndex || text[range.upperBound] == "\n" else { throw failure("Patch context must match complete lines: \(path)") }
                    // Ambiguous blocks must include more surrounding context.
                    guard text.range(of: needle, range: range.upperBound..<text.endIndex) == nil else { throw failure("Ambiguous patch context in \(path); include more context.") }
                    let offset = text.distance(from: text.startIndex, to: range.lowerBound)
                    text.replaceSubrange(range, with: replacement)
                    cursor = text.index(text.startIndex, offsetBy: offset + replacement.count)
                    hunks += 1
                }
                guard hunks > 0 else { throw failure("Update contains no hunks: \(path)") }
                if destination != path { try stage(path, nil) }
                try stage(destination, Data(text.utf8))
            } else { throw failure("Unknown patch header: \(header)") }
        }
        guard !order.isEmpty else { throw failure("Patch contains no file changes.") }
        return order.map { Change(path: $0, before: before[$0] ?? nil, after: staged[$0] ?? nil) }
    }
}
