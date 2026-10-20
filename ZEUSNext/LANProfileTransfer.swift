import Foundation
import Network
import Darwin

struct LocalHTTPRequest {
    let method: String
    let path: String
    let contentLength: Int
    let bodyOffset: Int
    static func parse(_ data: Data) throws -> LocalHTTPRequest? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { if data.count > 16_384 { throw URLError(.badServerResponse) }; return nil }
        guard range.upperBound <= 16_384, let header = String(data: data[..<range.lowerBound], encoding: .utf8) else { throw URLError(.badServerResponse) }
        let lines = header.components(separatedBy: "\r\n"), first = lines.first?.split(separator: " ") ?? []
        guard first.count == 3, ["GET", "POST"].contains(String(first[0])), first[2].hasPrefix("HTTP/1.") else { throw URLError(.badServerResponse) }
        var length: Int?; var seenLength = false
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { throw URLError(.badServerResponse) }
            let key = pieces[0].lowercased(), value = pieces[1].trimmingCharacters(in: .whitespaces)
            if key == "transfer-encoding" { throw URLError(.badServerResponse) }
            if key == "content-length" { guard !seenLength, let parsed = Int(value), (0...6_000_000).contains(parsed) else { throw URLError(.dataLengthExceedsMaximum) }; length = parsed; seenLength = true }
        }
        guard first[0] != "POST" || length != nil else { throw URLError(.badServerResponse) }
        return LocalHTTPRequest(method: String(first[0]), path: String(first[1]), contentLength: length ?? 0, bodyOffset: range.upperBound)
    }
}

private final class LocalProfileHTTPServer {
    let listener: NWListener
    private let queue = DispatchQueue(label: "tools.zeus.local-transfer")
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let snapshot: Data
    private let received: (Data) -> Void
    private var connections: [UUID: NWConnection] = [:]
    init(snapshot: Data, ready: @escaping (String) -> Void, received: @escaping (Data) -> Void, failure: @escaping (String) -> Void) throws {
        self.snapshot = snapshot; self.received = received
        let params = NWParameters.tcp; params.requiredInterfaceType = .wifi
        listener = try NWListener(using: params, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: if let port = self.listener.port, let ip = Self.wifiAddress() { ready("http://\(ip):\(port.rawValue)/\(self.token)/") } else { failure("لم يُعثر على عنوان Wi-Fi محلي.") }
            case .failed(let error): failure(error.localizedDescription)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }
    func stop() { queue.async { [self] in listener.cancel(); for connection in connections.values { connection.cancel() }; connections.removeAll() } }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 4 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection; connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 45) { [weak self, weak connection] in connection?.cancel(); self?.connections.removeValue(forKey: id) }
        read(connection, id: id, accumulated: Data())
    }
    private func read(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] bytes, _, done, error in
            guard let self else { connection.cancel(); return }
            var data = accumulated; if let bytes { data.append(bytes) }
            guard data.count <= 6_016_384, error == nil else { self.reply(connection, id: id, status: 413, type: "text/plain", body: Data("Request rejected".utf8)); return }
            do {
                if let request = try LocalHTTPRequest.parse(data), data.count >= request.bodyOffset + request.contentLength {
                    let body = data.subdata(in: request.bodyOffset..<request.bodyOffset + request.contentLength)
                    self.handle(request, body: body, connection: connection, id: id); return
                }
                if done { connection.cancel(); self.connections.removeValue(forKey: id) }
                else { self.read(connection, id: id, accumulated: data) }
            } catch { self.reply(connection, id: id, status: 400, type: "text/plain", body: Data("Invalid request".utf8)) }
        }
    }
    private func handle(_ request: LocalHTTPRequest, body: Data, connection: NWConnection, id: UUID) {
        let root = "/" + token + "/"
        if request.method == "GET" && request.path == root + "backup.json" { reply(connection, id: id, status: 200, type: "application/json", body: snapshot, attachment: true) }
        else if request.method == "POST" && request.path == root + "import" {
            guard (try? JSONDecoder().decode(ProfileBackup.self, from: body).validated()) != nil else { reply(connection, id: id, status: 400, type: "text/plain", body: Data("Invalid ZEUS profile backup".utf8)); return }
            received(body); reply(connection, id: id, status: 200, type: "text/plain", body: Data("Received. Review and approve the import on your iPhone or iPad.".utf8))
        } else if request.method == "GET" && request.path == root {
            let page = """
            <!doctype html><meta name="viewport" content="width=device-width"><title>ZEUS local transfer</title>
            <style>body{background:#000;color:#fff;font:18px system-ui;max-width:650px;margin:60px auto;padding:20px}a,button{color:inherit}button,input{background:#111;color:#fff;padding:12px;border:1px solid #fff;margin:12px 0}</style>
            <h1>ZEUS</h1><p>Local profile transfer</p><p><a href="backup.json" download>Download profile backup</a></p>
            <p>Upload a ZEUS JSON backup. Approve the import inside ZEUS.</p><input type="file" id="f" accept="application/json"><button id="send">Upload</button><p id="result"></p>
            <script>document.getElementById('send').onclick=async()=>{const file=document.getElementById('f').files[0];if(!file||file.size>6000000){document.getElementById('result').textContent='Choose a JSON backup smaller than 6 MB';return}try{const r=await fetch('import',{method:'POST',body:file,headers:{'Content-Type':'application/json'}});document.getElementById('result').textContent=await r.text()}catch{document.getElementById('result').textContent='Connection failed'}};</script>
            """
            reply(connection, id: id, status: 200, type: "text/html; charset=utf-8", body: Data(page.utf8))
        } else { reply(connection, id: id, status: 404, type: "text/plain", body: Data("Not found".utf8)) }
    }
    private func reply(_ connection: NWConnection, id: UUID, status: Int, type: String, body: Data, attachment: Bool = false) {
        let disposition = attachment ? "Content-Disposition: attachment; filename=zeus-profile.json\r\n" : ""
        let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'\r\n\(disposition)Connection: close\r\n\r\n"
        var data = Data(header.utf8); data.append(body)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in connection.cancel(); self?.connections.removeValue(forKey: id) })
    }
    private static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }; defer { freeifaddrs(list) }
        var next: UnsafeMutablePointer<ifaddrs>? = first
        while let item = next {
            let entry = item.pointee; next = entry.ifa_next
            guard String(cString: entry.ifa_name) == "en0", let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
        }
        return nil
    }
}

@MainActor final class LANProfileTransfer: ObservableObject {
    @Published var address: String?
    @Published var received: Data?
    @Published var error: String?
    @Published var running = false
    private var server: LocalProfileHTTPServer?
    func start(snapshot: Data) {
        stop(); error = nil
        do { server = try LocalProfileHTTPServer(snapshot: snapshot, ready: { [weak self] address in Task { @MainActor in self?.address = address } }, received: { [weak self] bytes in Task { @MainActor in self?.received = bytes } }, failure: { [weak self] message in Task { @MainActor in self?.error = message; self?.stop() } }); running = true }
        catch { self.error = error.localizedDescription }
    }
    func stop() { server?.stop(); server = nil; address = nil; running = false }
}
