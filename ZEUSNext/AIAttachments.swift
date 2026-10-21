import Foundation
import UniformTypeIdentifiers
import ImageIO

struct AIAttachment: Identifiable {
    let id = UUID()
    var name: String
    var mime: String
    var data: Data
    var width = 0
    var height = 0
    var isImage: Bool { mime.hasPrefix("image/") }
    static func load(_ url: URL) throws -> AIAttachment {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        guard (values.fileSize ?? Int.max) <= 16_000_000 else { throw TranslationFailure.message("الحد الأقصى للمرفق 16 ميجابايت.") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var item = AIAttachment(name: url.lastPathComponent, mime: values.contentType?.preferredMIMEType ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", data: data)
        if item.isImage, let source = CGImageSourceCreateWithData(data as CFData, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            item.width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0; item.height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        }
        return item
    }
    var dataURL: String { "data:" + mime + ";base64," + data.base64EncodedString() }
}

extension AIProviderService {
    func chatGPTUpload(_ attachment: AIAttachment, secret: String) async throws -> (metadata: [String: Any], image: [String: Any]?) {
        let headers = try chatGPTHeaders(secret)
        let initURL = URL(string: "https://android.chat.openai.com/backend-api/files")!
        let value = try await AIHTTP.object(AIHTTP.request(initURL, method: "POST", body: ["file_name": attachment.name, "file_size": attachment.data.count, "mime_type": attachment.mime, "use_case": "multimodal"], headers: headers)) as? [String: Any]
        guard let fileID = value?["file_id"] as? String, let address = value?["upload_url"] as? String,
              let uploadURL = URL(string: address), uploadURL.scheme == "https", uploadURL.user == nil else { throw TranslationFailure.message("لم يُرجع ChatGPT رابط رفع صالحًا.") }
        var upload = URLRequest(url: uploadURL); upload.httpMethod = "PUT"; upload.httpBody = attachment.data
        upload.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type"); upload.setValue(attachment.mime, forHTTPHeaderField: "Content-Type")
        // Presigned storage receives only the selected file, never the account token.
        _ = try await AIHTTP.data(upload)
        let ack = URL(string: "https://android.chat.openai.com/backend-api/files/" + fileID + "/uploaded")!
        _ = try await AIHTTP.object(AIHTTP.request(ack, method: "POST", body: [:] as [String: String], headers: headers))
        let metadata: [String: Any] = ["id": fileID, "name": attachment.name, "mime_type": attachment.mime, "size": attachment.data.count]
        let image: [String: Any]? = attachment.isImage ? ["content_type": "image_asset_pointer", "asset_pointer": "file-service://" + fileID, "size_bytes": attachment.data.count, "width": max(1, attachment.width), "height": max(1, attachment.height)] : nil
        return (metadata, image)
    }
    func geminiUpload(_ attachment: AIAttachment, cookie: String) async throws -> String {
        let boundary = "ZEUS-" + UUID().uuidString
        let name = attachment.name.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\"", with: "_")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: \(attachment.mime)\r\n\r\n".utf8)
        body.append(attachment.data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = try AIHTTP.request(URL(string: "https://content-push.googleapis.com/upload")!, method: "POST", headers: ["Cookie": cookie, "Origin": "https://gemini.google.com", "Referer": "https://gemini.google.com/", "X-Tenant-Id": "bard-storage", "Push-ID": "feeds/mcudyrk2a4khkz"])
        request.httpBody = body; request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        let data = try await AIHTTP.data(request), uri = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard uri.hasPrefix("/") || uri.hasPrefix("https://") else { throw TranslationFailure.message("لم يُرجع Gemini معرّفًا صالحًا للملف المرفوع.") }; return uri
    }
}
