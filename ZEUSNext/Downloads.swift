import Foundation
import WebKit
import Combine

enum DownloadState: String, Codable { case queued, running, pausing, paused, completed, failed }
enum DownloadEngine: String, Codable { case webKit, backgroundSession }

struct BrowserDownload: Identifiable, Codable {
    var id = UUID()
    var profileID: UUID
    var source: String
    var filename = "ملف"
    var state: DownloadState = .queued
    var engine: DownloadEngine
    var received: Int64 = 0
    var expected: Int64 = -1
    var created = Date()
    var error: String?
    var mimeType: String?
    var fraction: Double? { expected > 0 ? min(1, Double(received) / Double(expected)) : nil }
    var isBusy: Bool { state == .running || state == .queued || state == .pausing }
}

enum DownloadFiles {
    static func safeName(_ suggested: String) -> String {
        let leaf = (suggested.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let cleaned = leaf.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !"/:".unicodeScalars.contains($0) }
        let value = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return value.isEmpty ? "download" : String(value.prefix(180))
    }
    static func uniqueURL(name: String, folder: URL) -> URL {
        let name = safeName(name)
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var candidate = folder.appendingPathComponent(name)
        for number in 2...1000 {
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            candidate = folder.appendingPathComponent(stem + " (\(number))" + (ext.isEmpty ? "" : "." + ext))
        }
        return folder.appendingPathComponent(UUID().uuidString + "-" + name)
    }
    static func cookieHeaders(_ cookies: [HTTPCookie], for url: URL) -> [String: String] {
        let host = url.host?.lowercased() ?? ""
        return HTTPCookie.requestHeaderFields(with: cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            let hostAllowed = domain.hasPrefix(".") ? BrowserURL.hostMatches(host, domain: domain) : host == domain
            let path = url.path.isEmpty ? "/" : url.path
            let cookiePath = cookie.path
            let pathAllowed = path == cookiePath || (path.hasPrefix(cookiePath) && (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")))
            return hostAllowed && pathAllowed && (!cookie.isSecure || url.scheme == "https") && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
        })
    }
}

@MainActor final class DownloadService: NSObject, ObservableObject {
    @Published private(set) var records: [BrowserDownload]
    @Published var message: String?
    static var backgroundCompletion: (() -> Void)?
    static let sessionIdentifier = "tools.zeus.browser.downloads.v2"
    private let store: ProfileStore
    private let useBackground: Bool
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var webDownloads: [UUID: WKDownload] = [:]
    private var progressObservers: [UUID: NSKeyValueObservation] = [:]
    private var lastProgress: [UUID: Date] = [:]
    private lazy var session: URLSession = {
        let config = useBackground ? URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier) : .ephemeral
        if useBackground { config.sessionSendsLaunchEvents = true; config.isDiscretionary = false }
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 86_400
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    init(store: ProfileStore, useBackground: Bool = true) {
        self.store = store
        self.useBackground = useBackground
        var persisted: [BrowserDownload] = []
        for profile in store.profiles where !profile.isPrivate {
            let path = store.folder(for: profile).appendingPathComponent("downloads.json")
            persisted.append(contentsOf: BrowserDisk.read([BrowserDownload].self, from: path) ?? [])
        }
        persisted.sort { $0.created > $1.created }
        self.records = persisted
        super.init()
        restore()
    }
    func forProfile(_ id: UUID) -> [BrowserDownload] { records.filter { $0.profileID == id } }
    func fileURL(_ item: BrowserDownload) -> URL? {
        guard let profile = store.profile(item.profileID), item.state == .completed else { return nil }
        let file = store.downloads(for: profile).appendingPathComponent(DownloadFiles.safeName(item.filename))
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
    private func save() {
        for profile in store.profiles where !profile.isPrivate {
            do { try BrowserDisk.write(forProfile(profile.id), to: store.folder(for: profile).appendingPathComponent("downloads.json")) }
            catch { message = "تعذر حفظ سجل التنزيلات: \(error.localizedDescription)" }
        }
    }
    private func change(_ id: UUID, _ body: (inout BrowserDownload) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        body(&records[index])
    }
    private func resumeURL(_ item: BrowserDownload) -> URL? {
        guard let profile = store.profile(item.profileID) else { return nil }
        return store.folder(for: profile).appendingPathComponent("Resume/" + item.id.uuidString + ".resume")
    }
    private func saveResume(_ bytes: Data?, item: BrowserDownload) {
        guard let bytes, let path = resumeURL(item) else { return }
        do { try BrowserDisk.ensure(path.deletingLastPathComponent()); try bytes.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch { message = error.localizedDescription }
    }
    private func restore() {
        session.getAllTasks { [weak self] existing in
            Task { @MainActor in
                guard let self else { return }
                for task in existing {
                    guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)), self.records.contains(where: { $0.id == id }), let download = task as? URLSessionDownloadTask else { task.cancel(); continue }
                    self.tasks[id] = download
                    self.change(id) { $0.state = task.state == .running ? .running : .paused }
                }
                for item in self.records where item.isBusy && self.tasks[item.id] == nil {
                    self.change(item.id) { $0.state = .paused; $0.error = "توقف التنزيل. يمكنك استئنافه أو إعادة البدء." }
                }
                self.save()
            }
        }
    }
    func start(url: URL, profile: BrowserProfile, referrer: URL? = nil, webView: WKWebView? = nil) async {
        guard BrowserURL.isWeb(url) else { message = "افتح الرابط داخل الصفحة لتنزيل ملفات blob أو data."; return }
        let item = BrowserDownload(profileID: profile.id, source: url.absoluteString, filename: DownloadFiles.safeName(url.lastPathComponent), engine: .backgroundSession)
        records.insert(item, at: 0)
        await startRequest(item: item, profile: profile, referrer: referrer, webView: webView)
    }
    private func startRequest(item: BrowserDownload, profile: BrowserProfile, referrer: URL?, webView: WKWebView? = nil) async {
        guard let url = URL(string: item.source), BrowserURL.isWeb(url) else { return }
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.websiteDataStore(for: profile).httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        guard records.contains(where: { $0.id == item.id }) else { return }
        var request = URLRequest(url: url)
        // Authenticated requests stay inside the owning WebKit store. Do not
        // put Cookie headers into a cross-origin background redirect chain.
        if !DownloadFiles.cookieHeaders(cookies, for: url).isEmpty {
            guard let webView, webView.configuration.websiteDataStore === store.websiteDataStore(for: profile) else {
                failed(item.id, error: NSError(domain: "Download", code: 1, userInfo: [NSLocalizedDescriptionKey: "افتح الموقع في هذه المساحة ثم نزّل الرابط للحفاظ على جلسة الدخول."]))
                return
            }
            change(item.id) { $0.engine = .webKit; $0.state = .queued }
            webView.startDownload(using: request) { [weak self] download in self?.attach(download, profile: profile, existingID: item.id) }
            save(); return
        }
        if let referrer, BrowserURL.isWeb(referrer), referrer.host == url.host, var origin = URLComponents(url: referrer, resolvingAgainstBaseURL: false) {
            origin.path = "/"; origin.query = nil; origin.fragment = nil
            request.setValue(origin.url?.absoluteString, forHTTPHeaderField: "Referer")
        }
        let task = session.downloadTask(with: request); task.taskDescription = item.id.uuidString; tasks[item.id] = task
        change(item.id) { $0.state = .running; $0.error = nil; $0.received = 0; $0.expected = -1 }
        save(); task.resume()
    }
    func attach(_ download: WKDownload, profile: BrowserProfile, existingID: UUID? = nil) {
        let id: UUID
        if let existingID { id = existingID; change(id) { $0.state = .running; $0.error = nil } }
        else {
            let source = download.originalRequest?.url?.absoluteString ?? ""
            let item = BrowserDownload(profileID: profile.id, source: source, filename: "download", state: .running, engine: .webKit)
            records.insert(item, at: 0); id = item.id
        }
        download.delegate = self; webDownloads[id] = download
        progressObservers[id] = download.progress.observe(\.completedUnitCount, options: [.initial, .new]) { [weak self] progress, _ in
            let completed = progress.completedUnitCount, total = progress.totalUnitCount
            Task { @MainActor in self?.progress(id, received: completed, expected: total) }
        }
        save()
    }
    private func progress(_ id: UUID, received: Int64, expected: Int64) {
        if let last = lastProgress[id], Date().timeIntervalSince(last) < 0.25, received < expected { return }
        lastProgress[id] = Date()
        change(id) { $0.received = received; $0.expected = expected }
    }
    func pause(_ item: BrowserDownload) {
        guard item.isBusy else { return }
        change(item.id) { $0.state = .pausing }; save()
        let handler: (Data?) -> Void = { [weak self] bytes in
            Task { @MainActor in
                guard let self, self.records.contains(where: { $0.id == item.id }) else { return }
                self.saveResume(bytes, item: item)
                self.change(item.id) { $0.state = .paused; $0.error = bytes == nil ? "المصدر لا يدعم الاستئناف؛ سيعاد الطلب من البداية." : nil }
                self.tasks.removeValue(forKey: item.id); self.webDownloads.removeValue(forKey: item.id); self.progressObservers.removeValue(forKey: item.id)
                self.save()
            }
        }
        if let task = tasks[item.id] { task.cancel(byProducingResumeData: handler) }
        else if let download = webDownloads[item.id] { download.cancel(handler) }
        else { handler(nil) }
    }
    func resume(_ item: BrowserDownload, webView: WKWebView?) async {
        guard let profile = store.profile(item.profileID), !item.isBusy else { return }
        let bytes = resumeURL(item).flatMap { try? Data(contentsOf: $0) }
        if item.engine == .webKit, let bytes, let webView {
            change(item.id) { $0.state = .queued; $0.error = nil }
            webView.resumeDownload(fromResumeData: bytes) { [weak self] download in self?.attach(download, profile: profile, existingID: item.id) }
        } else if item.engine == .backgroundSession, let bytes {
            let task = session.downloadTask(withResumeData: bytes); task.taskDescription = item.id.uuidString; tasks[item.id] = task
            change(item.id) { $0.state = .running; $0.error = nil }; task.resume()
        } else if let url = URL(string: item.source), BrowserURL.isWeb(url) {
            change(item.id) { $0.engine = .backgroundSession }
            await startRequest(item: item, profile: profile, referrer: nil, webView: webView)
        } else { change(item.id) { $0.state = .failed; $0.error = "أعد فتح رابط التنزيل في الصفحة الأصلية." } }
        save()
    }
    func remove(_ item: BrowserDownload) {
        tasks.removeValue(forKey: item.id)?.cancel()
        if let download = webDownloads.removeValue(forKey: item.id) { download.cancel { _ in } }
        progressObservers.removeValue(forKey: item.id)
        if let path = fileURL(item) { do { try FileManager.default.removeItem(at: path) } catch { message = error.localizedDescription; return } }
        if let path = resumeURL(item) { try? FileManager.default.removeItem(at: path) }
        records.removeAll { $0.id == item.id }; save()
    }
    func removeAll(profileID: UUID) { for item in forProfile(profileID) { remove(item) } }
    func rename(_ item: BrowserDownload, to name: String) {
        guard let source = fileURL(item), let profile = store.profile(item.profileID) else { return }
        let safe = DownloadFiles.safeName(name)
        if safe == item.filename { return }
        let target = DownloadFiles.uniqueURL(name: safe, folder: store.downloads(for: profile))
        do { try FileManager.default.moveItem(at: source, to: target); change(item.id) { $0.filename = target.lastPathComponent }; save() }
        catch { message = "تعذرت إعادة التسمية: \(error.localizedDescription)" }
    }
    func importFile(_ url: URL, profile: BrowserProfile) async {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let folder = store.downloads(for: profile); try BrowserDisk.ensure(folder)
            let target = DownloadFiles.uniqueURL(name: url.lastPathComponent, folder: folder)
            let size: Int64 = try await Task.detached(priority: .userInitiated) {
                guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw URLError(.fileIsDirectory) }
                try FileManager.default.copyItem(at: url, to: target)
                return Int64((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }.value
            guard store.profile(profile.id) != nil else { try? FileManager.default.removeItem(at: target); return }
            var item = BrowserDownload(profileID: profile.id, source: "", filename: target.lastPathComponent, state: .completed, engine: .backgroundSession)
            item.received = size; item.expected = item.received
            records.insert(item, at: 0); save()
        } catch { message = "تعذر استيراد الملف: \(error.localizedDescription)" }
    }
    private func id(for download: WKDownload) -> UUID? { webDownloads.first(where: { $0.value === download })?.key }
    private func completed(_ id: UUID) {
        change(id) { $0.state = .completed; $0.error = nil; $0.expected = $0.received }
        if let item = records.first(where: { $0.id == id }), let resume = resumeURL(item) { try? FileManager.default.removeItem(at: resume) }
        tasks.removeValue(forKey: id); webDownloads.removeValue(forKey: id); progressObservers.removeValue(forKey: id)
        save()
    }
    private func failed(_ id: UUID, error: Error, resumeData: Data? = nil) {
        guard let item = records.first(where: { $0.id == id }), item.state != .pausing && item.state != .paused else { return }
        saveResume(resumeData, item: item)
        change(id) { $0.state = .failed; $0.error = error.localizedDescription }
        tasks.removeValue(forKey: id); webDownloads.removeValue(forKey: id); progressObservers.removeValue(forKey: id); save()
    }
    private func adopt(staged: URL, id: UUID, response: URLResponse?) {
        defer { try? FileManager.default.removeItem(at: staged) }
        guard let item = records.first(where: { $0.id == id }), let profile = store.profile(item.profileID) else { return }
        if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            failed(id, error: NSError(domain: "Download", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "رفض الخادم التنزيل (HTTP \(response.statusCode)). افتح الرابط في الصفحة ثم أعد المحاولة."]))
            return
        }
        do {
            let folder = store.downloads(for: profile); try BrowserDisk.ensure(folder)
            let target = DownloadFiles.uniqueURL(name: response?.suggestedFilename ?? item.filename, folder: folder)
            try FileManager.default.moveItem(at: staged, to: target)
            var values = URLResourceValues(); values.isExcludedFromBackup = true; var mutable = target; try? mutable.setResourceValues(values)
            let size = Int64((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            change(id) { $0.filename = target.lastPathComponent; $0.received = size; $0.mimeType = response?.mimeType }
            completed(id)
        } catch { failed(id, error: error) }
    }
}

extension DownloadService: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        // URLSession removes its temporary file when this delegate returns.
        // Move it synchronously before dispatching UI/database work.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("ZEUS-Completed-" + UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            let response = downloadTask.response
            Task { @MainActor in self.adopt(staged: staged, id: id, response: response) }
        } catch { Task { @MainActor in self.failed(id, error: error) } }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        Task { @MainActor in self.progress(id, received: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in self.failed(id, error: error, resumeData: resume) }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in let handler = Self.backgroundCompletion; Self.backgroundCompletion = nil; handler?() }
    }
}

extension DownloadService: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let id = id(for: download), let item = records.first(where: { $0.id == id }), let profile = store.profile(item.profileID) else { completionHandler(nil); return }
        do {
            let folder = store.downloads(for: profile); try BrowserDisk.ensure(folder)
            let target = DownloadFiles.uniqueURL(name: suggestedFilename, folder: folder)
            change(id) { $0.filename = target.lastPathComponent; $0.expected = response.expectedContentLength; $0.mimeType = response.mimeType }
            save(); completionHandler(target)
        } catch { failed(id, error: error); completionHandler(nil) }
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let id = id(for: download), let item = records.first(where: { $0.id == id }), let profile = store.profile(item.profileID) else { return }
        let path = store.downloads(for: profile).appendingPathComponent(item.filename)
        guard FileManager.default.fileExists(atPath: path.path) else { failed(id, error: URLError(.fileDoesNotExist)); return }
        change(id) { $0.received = Int64((try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        completed(id)
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { if let id = id(for: download) { failed(id, error: error, resumeData: resumeData) } }
    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) { completionHandler(.performDefaultHandling, nil) }
}
