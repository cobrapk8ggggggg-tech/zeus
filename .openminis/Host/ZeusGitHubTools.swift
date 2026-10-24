import Foundation

private final class ZeusArtifactLimit: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maximum: Int64
    let allowLoopback: Bool
    init(maximum: Int64, allowLoopback: Bool) { self.maximum = maximum; self.allowLoopback = allowLoopback }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximum || totalBytesExpectedToWrite > maximum { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https" || (allowLoopback && url.scheme == "http" && url.host == "127.0.0.1") else { completionHandler(nil); return }
        var safe = request; safe.setValue(nil, forHTTPHeaderField: "Authorization"); completionHandler(safe)
    }
}

private final class ZeusGitHubNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Return redirect metadata, never forward a Keychain Authorization
        // header to a download host or a caller-supplied origin.
        completionHandler(nil)
    }
}

@MainActor final class ZeusGitHubTools {
    static let shared = ZeusGitHubTools()
    let connections: ZeusConnections
    private var base = URL(string: "https://api.github.com")!
    private let session = URLSession(configuration: .ephemeral, delegate: ZeusGitHubNoRedirect(), delegateQueue: nil)
    init(connections: ZeusConnections = .shared) { self.connections = connections }
    #if DEBUG
    func configureFixture(_ url: URL) { precondition(url.host == "127.0.0.1"); base = url }
    #endif
    func close() { session.invalidateAndCancel() }
    private func permittedDownload(_ url: URL) -> Bool {
        if url.scheme == "https", url.host != nil, url.user == nil, url.password == nil { return true }
        #if DEBUG
        if base.host == "127.0.0.1", url.scheme == "http", url.host == "127.0.0.1" { return true }
        #endif
        return false
    }
    static func relativePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\"), !path.contains("?"), !path.contains("#"),
              !path.split(separator: "/").contains("..") else { throw ZeusPatch.failure("GitHub path must be an API-relative path without an origin, query, fragment or traversal; supply query separately.") }
        guard let url = URL(string: "https://api.github.com" + path), url.host == "api.github.com", url.user == nil, url.password == nil else { throw ZeusPatch.failure("Invalid GitHub API path.") }
        let decoded = path.removingPercentEncoding ?? path
        guard !decoded.contains("\\"), !decoded.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { throw ZeusPatch.failure("Encoded GitHub path traversal is not allowed.") }
    }
    func request(accountID: String, method: String = "GET", path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> [String: Any] {
        do { _ = try connections.account(accountID, provider: "github") }
        catch { throw NSError(domain: "ZeusGitHubHTTP", code: 401, userInfo: [NSLocalizedDescriptionKey: "حساب GitHub المحدد لم يعد مرتبطاً؛ أعد ربطه أو اختر الحساب الصحيح."]) }
        try Self.relativePath(path)
        guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"].contains(method) else { throw ZeusPatch.failure("Unsupported GitHub HTTP method.") }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let prefix = base.path == "/" ? "" : base.path
        guard let pathURL = URL(string: "https://api.github.com" + path) else { throw ZeusPatch.failure("Invalid API path.") }
        components.percentEncodedPath = prefix + pathURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#%")))!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!); request.httpMethod = method; request.timeoutInterval = 45
        let credential: String
        do { credential = try await connections.githubAccessToken(accountID) }
        catch { throw NSError(domain: "ZeusGitHubHTTP", code: 401, userInfo: [NSLocalizedDescriptionKey: "أعد ربط حساب GitHub المطلوب عبر OAuth: " + error.localizedDescription]) }
        request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ZEUS-Browser", forHTTPHeaderField: "User-Agent")
        if let body {
            let data = try JSONSerialization.data(withJSONObject: body)
            guard data.count <= 2_000_000 else { throw ZeusPatch.failure("Split this GitHub change into smaller file/commit requests (2MB body limit).") }
            request.httpBody = data; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 4_000_000 else { throw ZeusPatch.failure("GitHub response exceeds the 4MB limit; use a smaller page/file request.") }
        let object: Any = data.isEmpty ? NSNull() : (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) ?? String(String(decoding: data, as: UTF8.self).prefix(30000)) as Any
        if (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"), let url = URL(string: location), permittedDownload(url) {
            if method == "GET", path.range(of: #"^/repos/[^/]+/[^/]+/actions/jobs/[0-9]+/logs$"#, options: .regularExpression) != nil {
                return try await jobLog(url)
            }
            return ["status": http.statusCode, "redirect_url": location, "authorization_forwarded": false]
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (object as? [String: Any])?["message"] as? String ?? "Request was rejected"
            throw NSError(domain: "ZeusGitHubHTTP", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "GitHub HTTP \(http.statusCode): \(String(message.prefix(1000))). Inspect permissions, repository/ref and rate limits; do not blindly retry an uncertain write."])
        }
        return ["status": http.statusCode, "data": object, "rate_limit_remaining": http.value(forHTTPHeaderField: "X-RateLimit-Remaining") as Any? ?? NSNull()]
    }
    private func jobLog(_ url: URL) async throws -> [String: Any] {
        // GitHub job logs redirect to a temporary download host. Fetch them
        // natively, without forwarding the account token or requiring curl.
        let transport = URLSession(configuration: .ephemeral)
        defer { transport.invalidateAndCancel() }
        let limit = ZeusArtifactLimit(maximum: 16 * 1024 * 1024, allowLoopback: base.host == "127.0.0.1")
        var request = URLRequest(url: url); request.timeoutInterval = 60
        let (temporary, response) = try await transport.download(for: request, delegate: limit)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024 else {
            throw ZeusPatch.failure("Job log retrieval failed or exceeded 16MB. Inspect the failed job's step annotations and smaller log outputs.")
        }
        let log = String(decoding: try Data(contentsOf: temporary), as: UTF8.self)
        let truncated = log.count > 100000
        let visible = truncated ? String(log.prefix(40000)) + "\n[Middle of large job log omitted]\n" + String(log.suffix(60000)) : log
        return ["status": 200, "data": visible, "log_truncated": truncated, "authorization_forwarded": false]
    }
    func object(accountID: String, path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        guard let object = try await request(accountID: accountID, path: path, query: query)["data"] as? [String: Any] else { throw ZeusPatch.failure("GitHub returned no structured JSON object for verification.") }
        return object
    }
    private func pages(accountID: String, path: String, key: String) async throws -> [[String: Any]] {
        var all: [[String: Any]] = []
        for page in 1...10 {
            let object = try await object(accountID: accountID, path: path, query: ["per_page": "100", "page": String(page)])
            guard let items = object[key] as? [[String: Any]] else { throw ZeusPatch.failure("GitHub verification response is missing \(key).") }
            all += items
            if items.count < 100 { return all }
        }
        throw ZeusPatch.failure("Verification exceeds 1000 items; select a smaller workflow/run.")
    }
    func verify(proposal: ZeusProjectContract.Proposal, accountID: String, repository: String, runID: Int, sha: String, generation: Int) async throws -> [ZeusProjectContract.Evidence] {
        guard proposal.build_route == "github_actions", proposal.github_account_id == accountID,
              proposal.repository?.lowercased() == repository.lowercased() else { throw ZeusPatch.failure("Verification must use the approved project account and repository.") }
        let prefix = "/repos/" + repository
        let run = try await object(accountID: accountID, path: prefix + "/actions/runs/\(runID)")
        let repo = run["repository"] as? [String: Any]
        guard (repo?["full_name"] as? String)?.lowercased() == repository.lowercased(),
              (run["head_sha"] as? String)?.lowercased() == sha.lowercased(), run["head_branch"] as? String == proposal.branch,
              (run["path"] as? String)?.split(separator: "@").first.map(String.init) == proposal.workflow,
              run["status"] as? String == "completed", run["conclusion"] as? String == "success" else {
            throw ZeusPatch.failure("The GitHub run is not a successful terminal run for the exact approved repository, branch, workflow and commit.")
        }
        let ref = try await object(accountID: accountID, path: prefix + "/git/ref/heads/" + (proposal.branch ?? ""))
        guard ((ref["object"] as? [String: Any])?["sha"] as? String)?.lowercased() == sha.lowercased() else { throw ZeusPatch.failure("The branch now has a different commit. Build and test its current HEAD; an old successful run is insufficient.") }
        let jobs = try await pages(accountID: accountID, path: prefix + "/actions/runs/\(runID)/jobs", key: "jobs")
        let artifacts = try await pages(accountID: accountID, path: prefix + "/actions/runs/\(runID)/artifacts", key: "artifacts")
        return proposal.checks.map { check in
            let job = jobs.first { $0["name"] as? String == check.github_job && $0["conclusion"] as? String == "success" }
            let step = (job?["steps"] as? [[String: Any]])?.first { $0["name"] as? String == check.github_step && $0["conclusion"] as? String == "success" }
            let artifact = artifacts.first { $0["name"] as? String == check.artifact && $0["expired"] as? Bool != true && ($0["size_in_bytes"] as? Int ?? 0) > 0 }
            let passed = step != nil && ((check.artifact ?? "").isEmpty || artifact != nil)
            let summary = "run=\(runID) sha=\(sha) job=\(check.github_job ?? "") step=\(check.github_step ?? "") artifact=\(check.artifact ?? "none") " + (passed ? "verified" : "required successful step/artifact missing")
            return .init(criterion: check.id, passed: passed, generation: generation, source: "github_actions", summary: summary, date: Date())
        }
    }
    func artifact(proposal: ZeusProjectContract.Proposal, accountID: String, repository: String, runID: Int, artifactID: Int, sha: String) async throws -> (name: String, bytes: Int64) {
        guard proposal.github_account_id == accountID, proposal.repository?.lowercased() == repository.lowercased() else { throw ZeusPatch.failure("Use the approved project account/repository for artifact retrieval.") }
        let prefix = "/repos/" + repository
        let run = try await object(accountID: accountID, path: prefix + "/actions/runs/\(runID)")
        guard (run["head_sha"] as? String)?.lowercased() == sha.lowercased(), run["head_branch"] as? String == proposal.branch,
              (run["path"] as? String)?.split(separator: "@").first.map(String.init) == proposal.workflow else { throw ZeusPatch.failure("Artifact run does not match the approved branch/workflow/commit.") }
        let metadata = try await object(accountID: accountID, path: prefix + "/actions/artifacts/\(artifactID)")
        let ownerRun = metadata["workflow_run"] as? [String: Any]
        guard let name = metadata["name"] as? String, proposal.checks.contains(where: { $0.artifact == name }),
              ownerRun?["id"] as? Int == runID, (ownerRun?["head_sha"] as? String)?.lowercased() == sha.lowercased(),
              metadata["expired"] as? Bool != true, let bytes = (metadata["size_in_bytes"] as? NSNumber)?.int64Value, bytes > 0, bytes <= 200 * 1024 * 1024 else {
            throw ZeusPatch.failure("Artifact is expired, too large, not required by the approved plan, or belongs to another run/commit.")
        }
        return (name, bytes)
    }
    func downloadArtifact(accountID: String, repository: String, artifactID: Int) async throws -> URL {
        let result = try await request(accountID: accountID, path: "/repos/" + repository + "/actions/artifacts/\(artifactID)/zip")
        guard let raw = result["redirect_url"] as? String, let url = URL(string: raw), permittedDownload(url) else { throw ZeusPatch.failure("GitHub did not return a valid artifact download address.") }
        let transport = URLSession(configuration: .ephemeral)
        defer { transport.invalidateAndCancel() }
        let limit = ZeusArtifactLimit(maximum: 200 * 1024 * 1024, allowLoopback: base.host == "127.0.0.1")
        var request = URLRequest(url: url); request.timeoutInterval = 120 // Deliberately no account Authorization header.
        let (temporary, response) = try await transport.download(for: request, delegate: limit)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 200 * 1024 * 1024 else { throw ZeusPatch.failure("Artifact download failed or exceeded 200MB.") }
        let handle = try FileHandle(forReadingFrom: temporary); defer { try? handle.close() }
        let header = try handle.read(upToCount: 4)
        guard header == Data([0x50, 0x4b, 0x03, 0x04]) || header == Data([0x50, 0x4b, 0x05, 0x06]) else { throw ZeusPatch.failure("Artifact response is not a ZIP archive.") }
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-artifact-" + UUID().uuidString + ".zip")
        try FileManager.default.moveItem(at: temporary, to: owned)
        return owned
    }
}

@MainActor extension ZeusAgentHarness {
    func githubProjectRequest(_ args: [String: Any], session: String, client: ZeusGitHubTools = .shared) async throws -> String {
        let id = args["account_id"] as! String, method = args["method"] as? String ?? "GET", path = args["path"] as! String
        let body = args["body"] as? [String: Any]
        var value = state(session)
        if let project = value.project, let proposal = project.proposal, project.decision == "approved" {
            guard proposal.github_account_id == nil || proposal.github_account_id == id else { throw ZeusPatch.failure("Use the GitHub account selected in the approved plan. Account changes need a revised plan.") }
            if !["GET", "HEAD"].contains(method) {
                let repo = proposal.repository ?? "", prefix = "/repos/" + repo
                let creatingUserRepo = method == "POST" && path == "/user/repos" && body?["name"] as? String == repo.split(separator: "/").last.map(String.init)
                let creatingOrgRepo = method == "POST" && path == "/orgs/" + (repo.split(separator: "/").first.map(String.init) ?? "") + "/repos" && body?["name"] as? String == repo.split(separator: "/").last.map(String.init)
                guard path.hasPrefix(prefix + "/") || creatingUserRepo || creatingOrgRepo else { throw ZeusPatch.failure("Project writes must stay within the repository approved in the plan.") }
                if creatingUserRepo {
                    let me = try await client.object(accountID: id, path: "/user")
                    guard (me["login"] as? String)?.lowercased() == repo.split(separator: "/").first.map(String.init)?.lowercased() else { throw ZeusPatch.failure("The approved repository owner differs from this GitHub account; use its organization endpoint or revise the plan.") }
                }
                if path.contains("/contents/"), ["PUT", "DELETE"].contains(method) { throw ZeusPatch.failure("Use github_write_files with plain text source files for approved project edits. It handles GitHub blobs/trees/commits natively; do not generate Base64 or use a local push.") }
                if path.hasSuffix("/dispatches"), body?["ref"] as? String != proposal.branch { throw ZeusPatch.failure("Dispatch the workflow on the approved branch.") }
                if method == "POST", path.hasSuffix("/git/refs"), body?["ref"] as? String != "refs/heads/" + (proposal.branch ?? "") { throw ZeusPatch.failure("Create the branch ref specified in the approved plan.") }
                if path.contains("/git/refs/heads/"), !path.hasSuffix("/git/refs/heads/" + (proposal.branch ?? "")) { throw ZeusPatch.failure("Update only the approved project branch ref.") }
            }
        }
        if value.project != nil { value.project?.githubAttempts += 1 }
        if !["GET", "HEAD"].contains(method) { value.generation += 1 }
        try save(session, value)
        do {
            let result = try await client.request(accountID: id, method: method, path: path, query: args["query"] as? [String: String] ?? [:], body: body)
            value = state(session); value.project?.githubLastStatus = result["status"] as? Int; value.project?.githubLastError = nil
            if method == "POST", path.hasSuffix("/dispatches") { value.project?.githubExecutionStarted = true }
            try save(session, value); return try Self.json(result)
        } catch {
            let native = error as NSError
            value = state(session); value.project?.githubLastStatus = native.domain == NSURLErrorDomain ? -1 : native.code
            value.project?.githubLastError = String(error.localizedDescription.prefix(1500)); try? save(session, value)
            throw error
        }
    }
    func verifyGitHubProject(_ args: [String: Any], session: String, client: ZeusGitHubTools = .shared) async throws -> String {
        let before = state(session)
        guard before.project?.decision == "approved", let proposal = before.project?.proposal else { throw ZeusPatch.failure("Approve the project plan before verifying its CI acceptance checks.") }
        guard !jobs.values.contains(where: { $0.owner == session && $0.exitCode == nil }) else { throw ZeusPatch.failure("Wait for running project commands before final CI verification.") }
        var attempting = before; attempting.project?.githubAttempts += 1; try save(session, attempting)
        let evidence = try await client.verify(proposal: proposal, accountID: args["account_id"] as! String, repository: args["repository"] as! String,
            runID: args["run_id"] as! Int, sha: args["expected_sha"] as! String, generation: before.generation)
        var value = state(session)
        for item in evidence { value.project?.evidence[item.criterion] = item }
        value.project?.verifiedGitHubCommit = (args["expected_sha"] as! String).lowercased()
        try save(session, value)
        return try Self.json(evidence.map { ["criterion": $0.criterion, "exitCode": $0.passed ? 0 : 1, "generation": $0.generation, "output": $0.summary] as [String: Any] })
    }
    func downloadGitHubArtifact(_ args: [String: Any], session: String, vm: AIChatViewModel, client: ZeusGitHubTools = .shared) async throws -> String {
        let before = state(session)
        guard before.project?.decision == "approved", let proposal = before.project?.proposal else { throw ZeusPatch.failure("Approve the project plan before downloading its artifacts.") }
        let id = args["account_id"] as! String, repo = args["repository"] as! String, artifactID = args["artifact_id"] as! Int
        let sha = (args["expected_sha"] as! String).lowercased(), relative = args["destination"] as! String
        guard !relative.hasPrefix("/"), relative.hasSuffix(".zip") else { throw ZeusPatch.failure("destination must be a new relative .zip path inside the conversation workspace.") }
        let downloadKey = session + ":" + relative
        guard artifactDownloads.insert(downloadKey).inserted else { throw ZeusPatch.failure("This artifact destination is already being downloaded. Wait for its result.") }
        defer { artifactDownloads.remove(downloadKey) }
        try await prepareEnvironment(vm: vm)
        guard let root = await vm.resolvePathForDirectRead("/var/minis/workspace") else { throw ZeusPatch.failure("Project workspace is unavailable.") }
        let destination = try ZeusPatch.safeURL(relative, root: root)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ZeusPatch.failure("This artifact destination already exists. Reuse it or explicitly remove the old artifact before retrieving a new build.") }
        let metadata = try await client.artifact(proposal: proposal, accountID: id, repository: repo, runID: args["run_id"] as! Int, artifactID: artifactID, sha: sha)
        let available = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let available, available < metadata.bytes * 2 + 10_000_000 {
            var value = state(session); value.project?.environmentBlocker = "Insufficient device space for the actual artifact download."; try save(session, value)
            throw ZeusPatch.failure("لا توجد مساحة كافية لتنزيل ملف المشروع. حرّر مساحة أو اختر ملف صور أصغر؛ نسخة البناء تبقى محفوظة لدى GitHub.")
        }
        let downloaded = try await client.downloadArtifact(accountID: id, repository: repo, artifactID: artifactID)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try Task.checkCancellation()
        let linux = "/var/minis/workspace/" + relative
        let parent = (linux as NSString).deletingLastPathComponent
        let result = try await vm.executeCommand("mkdir -p " + Self.quote(parent) + " && (set -C; : > " + Self.quote(linux) + ")", timeout: 30) { _ in }
        guard result.exitCode == 0 else { throw ZeusPatch.failure(result.output) }
        // Creating the guest placeholder registers its fakefs metadata; replace
        // only this newly-created download, never an unrelated source file.
        let checked = try ZeusPatch.safeURL(relative, root: root)
        guard try checked.resourceValues(forKeys: [.fileSizeKey]).fileSize == 0 else { throw ZeusPatch.failure("The artifact destination changed during download; its contents were preserved.") }
        try FileManager.default.removeItem(at: checked)
        try FileManager.default.copyItem(at: downloaded, to: checked)
        let extract = Self.projectImagePath((relative as NSString).deletingPathExtension)
        var value = state(session)
        if value.project?.artifactRoots == nil { value.project?.artifactRoots = [:] }
        value.project?.artifactRoots?[extract] = sha; value.project?.environmentBlocker = nil; try save(session, value)
        return try Self.json(["path": linux, "extract_into": extract, "artifact_name": metadata.name, "commit": sha,
            "bytes": try checked.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
            "next": "Inspect ZIP entry paths, extract into extract_into, then read the approved screenshot_path with read_image. The UI review must use images from this commit."])
    }
}

@MainActor extension ZeusGitHubTools {
    static func sourcePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0 == ".git" }) else {
            throw ZeusPatch.failure("Source paths must be repository-relative regular file paths without traversal or .git metadata.")
        }
    }
    func readSource(accountID: String, repository: String, branch: String, path: String) async throws -> [String: Any] {
        try Self.sourcePath(path)
        let result = try await object(accountID: accountID, path: "/repos/" + repository + "/contents/" + path, query: ["ref": branch])
        guard result["type"] as? String == "file", result["encoding"] as? String == "base64",
              let encoded = result["content"] as? String, let bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), bytes.count <= 240000,
              let text = String(data: bytes, encoding: .utf8) else { throw ZeusPatch.failure("This source is binary, too large or unavailable. Use smaller text files; inspect actual GitHub errors.") }
        return ["path": path, "branch": branch, "sha": result["sha"] ?? NSNull(), "content": text]
    }
    func writeSources(accountID: String, repository: String, branch: String, message: String, files: [[String: Any]]) async throws -> [String: Any] {
        guard !files.isEmpty, files.count <= 30, Set(files.compactMap { $0["path"] as? String }).count == files.count else { throw ZeusPatch.failure("A commit needs 1–30 unique file paths.") }
        var total = 0
        for file in files {
            guard let path = file["path"] as? String else { throw ZeusPatch.failure("Each file needs a path.") }
            try Self.sourcePath(path)
            let deleting = file["delete"] as? Bool == true
            guard deleting ? file["content"] == nil : file["content"] is String else { throw ZeusPatch.failure("Use {path,content} for normal source text or {path,delete:true} for deletion; do not send Base64.") }
            total += (file["content"] as? String)?.utf8.count ?? 0
        }
        guard total <= 1_000_000 else { throw ZeusPatch.failure("Split the source into commits smaller than 1MB of UTF-8 text.") }
        let prefix = "/repos/" + repository
        let ref = try await object(accountID: accountID, path: prefix + "/git/ref/heads/" + branch)
        guard let parent = (ref["object"] as? [String: Any])?["sha"] as? String else { throw ZeusPatch.failure("The branch has no commit. Initialize a new repository with auto_init:true and create the approved branch before writing files.") }
        let commit = try await object(accountID: accountID, path: prefix + "/git/commits/" + parent)
        guard let baseTree = (commit["tree"] as? [String: Any])?["sha"] as? String else { throw ZeusPatch.failure("GitHub returned no base tree.") }
        var entries: [[String: Any]] = []
        for file in files {
            let path = file["path"] as! String
            if file["delete"] as? Bool == true { entries.append(["path": path, "mode": "100644", "type": "blob", "sha": NSNull()]); continue }
            // Git Trees accepts inline UTF-8 content and creates its blobs on
            // the server. Batch every file into one request instead of making
            // a separate network round trip per source file.
            entries.append(["path": path, "mode": "100644", "type": "blob", "content": file["content"] as! String])
        }
        let tree = try await request(accountID: accountID, method: "POST", path: prefix + "/git/trees", body: ["base_tree": baseTree, "tree": entries])
        guard let treeSHA = (tree["data"] as? [String: Any])?["sha"] as? String else { throw ZeusPatch.failure("GitHub did not confirm the source tree.") }
        let created = try await request(accountID: accountID, method: "POST", path: prefix + "/git/commits", body: ["message": message, "tree": treeSHA, "parents": [parent]])
        guard let sha = (created["data"] as? [String: Any])?["sha"] as? String else { throw ZeusPatch.failure("GitHub did not confirm the commit.") }
        _ = try await request(accountID: accountID, method: "PATCH", path: prefix + "/git/refs/heads/" + branch, body: ["sha": sha, "force": false])
        let confirmed = try await object(accountID: accountID, path: prefix + "/git/ref/heads/" + branch)
        guard (confirmed["object"] as? [String: Any])?["sha"] as? String == sha else { throw ZeusPatch.failure("The branch moved during confirmation. Inspect its HEAD; do not blindly repeat this commit.") }
        return ["repository": repository, "branch": branch, "parent_sha": parent, "commit_sha": sha, "files": files.map { $0["path"] as! String }, "written_directly_to_github": true]
    }
}

@MainActor extension ZeusAgentHarness {
    func githubReadFile(_ args: [String: Any], session: String, client: ZeusGitHubTools = .shared) async throws -> String {
        if let proposal = state(session).project?.proposal, state(session).project?.decision == "approved" {
            guard proposal.github_account_id == nil || proposal.github_account_id == args["account_id"] as? String else { throw ZeusPatch.failure("Use the approved GitHub account.") }
        }
        return try Self.json(try await client.readSource(accountID: args["account_id"] as! String, repository: args["repository"] as! String, branch: args["branch"] as! String, path: args["path"] as! String))
    }
    func githubWriteFiles(_ args: [String: Any], session: String, client: ZeusGitHubTools = .shared) async throws -> String {
        let id = args["account_id"] as! String, repository = args["repository"] as! String, branch = args["branch"] as! String
        let before = state(session)
        guard let project = before.project, project.decision == "approved", let proposal = project.proposal,
              proposal.github_account_id == id, proposal.repository?.lowercased() == repository.lowercased(), proposal.branch == branch else { throw ZeusPatch.failure("Direct source commits require the exact user-approved GitHub project account, repository and branch.") }
        let key = "git-write:" + repository.lowercased() + ":" + branch
        guard artifactDownloads.insert(key).inserted else { throw ZeusPatch.failure("Another direct commit to this branch is in flight. Inspect its result before writing again.") }
        defer { artifactDownloads.remove(key) }
        var value = before; value.generation += 1; value.project?.githubAttempts += 1; try save(session, value)
        do {
            let receipt = try await client.writeSources(accountID: id, repository: repository, branch: branch, message: args["message"] as! String, files: args["files"] as! [[String: Any]])
            value = state(session); value.project?.githubLastStatus = 200; value.project?.githubLastError = nil
            value.project?.appendNote("حُفظت ملفات المصدر مباشرة في GitHub: " + String((args["files"] as! [[String: Any]]).count) + " ملفات · " + branch)
            try save(session, value); return try Self.json(receipt)
        } catch {
            let native = error as NSError; value = state(session)
            value.project?.githubLastStatus = native.domain == NSURLErrorDomain ? -1 : native.code
            value.project?.githubLastError = String(error.localizedDescription.prefix(1500)); try? save(session, value)
            throw error
        }
    }
}
