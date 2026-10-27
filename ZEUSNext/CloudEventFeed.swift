import Foundation

public struct NativeCloudEventFeed: Sendable {
    public let pages: AsyncThrowingStream<Data, Error>
    private let reader: Task<Void, Never>
    init(pages: AsyncThrowingStream<Data, Error>, reader: Task<Void, Never>) { self.pages = pages; self.reader = reader }
    public func cancel() { reader.cancel() }
}

private final class CloudFeedRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum CloudAccountNetwork {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: CloudFeedRedirectGuard(), delegateQueue: nil)
    }()
}

extension NativeCloudAccountAPI {
    /// Read the authenticated HTTP body incrementally. No data(for:) buffering,
    /// disk cache, cookie storage, periodic GET, or synthetic typewriter delay.
    public static func eventFeed(_ path: String) throws -> NativeCloudEventFeed {
        guard path.hasPrefix("v1/"), !path.contains("://"), !path.contains(".."), let owner = CloudAccount.shared.identity?.id else { throw CloudAccountError.wrongOwner }
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var url = URLComponents(url: runtimeURL.appendingPathComponent(String(parts[0])), resolvingAgainstBaseURL: false)!
        if parts.count == 2 { url.percentEncodedQuery = String(parts[1]) }
        let (pages, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
        let reader = Task { @MainActor in
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil; config.httpCookieStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 40; config.timeoutIntervalForResource = 7500
            let session = URLSession(configuration: config, delegate: CloudFeedRedirectGuard(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            do {
                var request = URLRequest(url: url.url!); request.timeoutInterval = 40
                request.setValue("Bearer " + (try await CloudAccount.shared.authorization(for: owner)), forHTTPHeaderField: "Authorization")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true else {
                    throw NativeCloudHTTPError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "تعذر فتح تدفق الرد السحابي.")
                }
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard CloudAccount.shared.identity?.id == owner, CloudAccount.shared.phase == .ready else { throw CloudAccountError.wrongOwner }
                    guard line.utf8.count <= 2 * 1024 * 1024 else { throw CloudAccountError.invalidResponse }
                    if line.hasPrefix("data:") {
                        // The server writes one escaped JSON object per data
                        // line, matching the native provider stream contract.
                        let result = continuation.yield(Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8))
                        if case .dropped = result { throw CloudAccountError.incomplete("تأخر العرض عن التدفق؛ أعد فتح المحادثة لاستعادة السجل المحفوظ.") }
                        if case .terminated = result { throw CancellationError() }
                    }
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { @Sendable _ in reader.cancel() }
        return NativeCloudEventFeed(pages: pages, reader: reader)
    }
}
