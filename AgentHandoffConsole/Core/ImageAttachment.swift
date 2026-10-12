import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 메시지에 붙인 이미지 하나. 파일은 앱 데이터 폴더(`ImageAttachments.directory`)에 복사해 둔 것이다 — 원본(화면 캡처의
/// 임시 파일 등)은 곧 지워질 수 있다. 사용자 메시지 이벤트의 payload `"images"` 와 대기열에 이 모양으로 저장된다.
struct ImageAttachment: Codable, Hashable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    /// 복사해 둔 파일의 절대 경로.
    var path: String
    /// `image/png` · `image/jpeg`.
    var mediaType: String
    var width: Int
    var height: Int
    var byteCount: Int
    /// 원래 이름 (붙여넣은 이미지면 "붙여넣은 이미지").
    var name: String

    var url: URL { URL(fileURLWithPath: path) }
}

/// 이미지를 받아 앱 데이터 폴더에 맞는 크기로 저장하고, 보낼 때 읽는다.
///
/// 긴 변이 `maxPixel` 을 넘으면 줄인다 (Claude 는 큰 이미지를 어차피 줄여 읽고, 요청 크기에 한도가 있다).
/// PNG 로 저장하되 `maxPNGBytes` 를 넘으면 JPEG 로 — 화면 캡처는 글자가 선명한 PNG 가 낫고, 사진은 JPEG 가 작다.
enum ImageAttachments {
    static let maxPixel = 2000
    static let maxPNGBytes = 3_500_000
    /// 받지 않는 원본 크기 (이보다 큰 파일은 이미지라도 붙이지 않는다).
    static let maxSourceBytes = 50_000_000

    enum ImportError: LocalizedError {
        case unreadable(String)
        case tooLarge(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "이미지로 읽지 못했습니다: \(name)"
            case .tooLarge(let name): return "너무 커서 붙이지 않았습니다 (50MB 까지): \(name)"
            }
        }
    }

    /// 앱 데이터 폴더의 `attachments` (DB 옆 — 화면 확인용 임시 DB 로 띄우면 그 옆).
    static var directory: URL {
        Store.defaultDatabaseURL().deletingLastPathComponent().appendingPathComponent("attachments", isDirectory: true)
    }

    /// 이 파일을 이미지로 붙일 수 있는가 (확장자의 형식이 이미지).
    static func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    /// 텍스트 뷰가 넣으려는 글이 통째로 이미지 파일 경로(들)인가 — 끌어 놓은 파일 · 붙여넣은 경로. 아니면 nil.
    /// 경로에 빈칸이 있을 수 있어(화면 캡처 이름) 먼저 글 전체를, 다음에 줄 · "이미지 확장자 뒤의 빈칸 + /" 로 나눠 본다.
    static func imagePaths(in text: String) -> [URL]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("file://") || trimmed.hasPrefix("~/") else { return nil }
        if let single = imageFile(trimmed) { return [single] }
        var parts = trimmed.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if parts.count == 1,
           let regex = try? NSRegularExpression(pattern: #"(?<=\.(?:png|jpe?g|gif|heic|heif|webp|tiff?|bmp))\s+(?=/)"#,
                                                options: .caseInsensitive) {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            let marked = regex.stringByReplacingMatches(in: trimmed, range: range, withTemplate: "\n")
            parts = marked.components(separatedBy: "\n")
        }
        let files = parts.compactMap(imageFile)
        return files.count == parts.count && !files.isEmpty ? files : nil
    }

    private static func imageFile(_ text: String) -> URL? {
        let url: URL
        if text.hasPrefix("file://") {
            guard let parsed = URL(string: text), parsed.isFileURL else { return nil }
            url = parsed
        } else {
            url = URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              ImageAttachments.isImageFile(url) else { return nil }
        return url
    }

    /// 파일에서 가져온다.
    static func importFile(_ url: URL, into folder: URL = directory) throws -> ImageAttachment {
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxSourceBytes else { throw ImportError.tooLarge(name) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ImportError.unreadable(name) }
        return try store(source, name: name, in: folder)
    }

    /// 붙여넣은 이미지 데이터 (PNG · TIFF …) 에서 가져온다.
    static func importData(_ data: Data, name: String = "붙여넣은 이미지", into folder: URL = directory) throws -> ImageAttachment {
        guard data.count <= maxSourceBytes else { throw ImportError.tooLarge(name) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw ImportError.unreadable(name) }
        return try store(source, name: name, in: folder)
    }

    /// 보낼 때: 파일을 base64 로. 파일이 없어졌으면 nil.
    static func base64(_ attachment: ImageAttachment) -> String? {
        (try? Data(contentsOf: attachment.url))?.base64EncodedString()
    }

    /// 대화를 지운 뒤: 지운 대화가 쓰던 이미지 파일(`candidates`) 가운데 아무 데서도 쓰지 않는(`referenced` 에 없는) 것을 지운다 —
    /// 최선 노력 (`AppModel.removeOrphanedAttachments`). `folder` **바로 아래**의 이미지 파일만 지운다: 경로의 심볼릭 링크 · `..` 를
    /// 풀어(`realpath`) 보고, 폴더 밖 · 하위 폴더 · 링크 자체 · 폴더 · 이미지가 아닌 파일은 건드리지 않는다. 쓰는지는 적힌 경로와 푼
    /// 경로 모두로 견준다 (같은 파일을 다른 모양의 경로로 적었어도 남긴다). 돌려준 값은 지운 파일의 푼 경로.
    @discardableResult
    static func removeUnreferenced(_ candidates: Set<String>, keeping referenced: Set<String>,
                                   in folder: URL = directory) -> [String] {
        guard let root = resolvedPath(folder.path) else { return [] }
        var kept = referenced
        for path in referenced { if let real = resolvedPath(path) { kept.insert(real) } }
        let manager = FileManager.default
        var removed: [String] = []
        for candidate in candidates.sorted() where !kept.contains(candidate) {
            // 링크는 따라가지 않고 그 자리의 것을 본다 — 링크가 가리키는 다른 곳의 파일을 지우지 않게.
            guard let attributes = try? manager.attributesOfItem(atPath: candidate),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let real = resolvedPath(candidate), !kept.contains(real),
                  (real as NSString).deletingLastPathComponent == root,
                  isImageFile(URL(fileURLWithPath: real)) else { continue }
            if (try? manager.removeItem(atPath: real)) != nil { removed.append(real) }
        }
        return removed
    }

    /// 심볼릭 링크 · `.` · `..` 를 푼 실제 경로 (`realpath`). 없는 경로면 nil.
    private static func resolvedPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 설정에 저장된 입력창 첨부(`composer_attachments`)와 대기열(`message_queue`)이 쓰는 이미지 경로 — `excluding` 대화의 몫은 뺀다
    /// (지운 대화: 메모리에서는 이미 뺐는데 그 저장이 아직 닿지 않았을 수 있다). 값이 있는데 읽지 못하면 nil — 무엇을 쓰는지 모르니
    /// 아무것도 지우지 않는다.
    static func savedPaths(composerAttachments: String?, messageQueue: String?, excluding: Set<String>) -> Set<String>? {
        var paths: Set<String> = []
        if let raw = composerAttachments, !raw.isEmpty {
            guard let data = raw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: [ImageAttachment]].self, from: data) else { return nil }
            for (threadID, images) in decoded where !excluding.contains(threadID) { paths.formUnion(images.map(\.path)) }
        }
        if let raw = messageQueue, !raw.isEmpty {
            guard let data = raw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: [QueuedMessage]].self, from: data) else { return nil }
            for (threadID, queue) in decoded where !excluding.contains(threadID) {
                for message in queue { paths.formUnion(message.images.map(\.path)) }
            }
        }
        return paths
    }

    private static func store(_ source: CGImageSource, name: String, in folder: URL) throws -> ImageAttachment {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw ImportError.unreadable(name)
        }
        // 긴 변을 줄이고 회전 정보를 픽셀에 반영한다 (줄일 필요가 없어도 같은 길로 — 회전된 사진이 눕지 않게).
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxPixel),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImportError.unreadable(name)
        }
        var data = try encode(image, as: .png)
        var type = UTType.png
        if data.count > maxPNGBytes {
            data = try encode(image, as: .jpeg, quality: 0.85)
            type = .jpeg
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let file = folder.appendingPathComponent(id).appendingPathExtension(type == .png ? "png" : "jpg")
        try data.write(to: file, options: .atomic)
        return ImageAttachment(id: id, path: file.path, mediaType: type.preferredMIMEType ?? "image/png",
                               width: image.width, height: image.height, byteCount: data.count, name: name)
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ImportError.unreadable("이미지")
        }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.unreadable("이미지") }
        return data as Data
    }
}

extension ThreadEvent {
    /// 사용자 메시지에 붙은 이미지 (payload `"images"`). 없으면 빈 목록.
    var imageAttachments: [ImageAttachment] {
        guard kind == .userMessage, let json = payloadJSON, json.contains("\"images\""),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ImagesPayload.self, from: data) else { return [] }
        return payload.images
    }

    /// 사용자 메시지 payload — 붙인 이미지.
    static func imagesPayload(_ images: [ImageAttachment]) -> String? {
        guard !images.isEmpty, let data = try? JSONEncoder().encode(ImagesPayload(images: images)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private struct ImagesPayload: Codable {
        var images: [ImageAttachment]
    }
}

/// 실행 중에 보낸 메시지 — 대화의 실행이 끝나면 차례로 보낸다 (`AppModel.dispatchQueue`).
struct QueuedMessage: Codable, Hashable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var text: String
    var images: [ImageAttachment] = []
    var createdAt: Date = Date()
}

/// 입력창에 이미지를 붙이는 길의 판별: ⌘V 인지, 클립보드에 이미지가 있는지. 입력창(`ComposerReturnKey`)이 쓴다.
enum ComposerPaste {
    /// ⌘V 인가. 글자가 아니라 **키 위치**로 본다 — 한글 입력기에서는 같은 키가 "ㅍ" 로 온다 (2026-09-29: 한글 2벌식에서
    /// 이미지 붙여넣기가 걸리지 않았다). 다른 배열을 쓰면 그 배열의 "v" 도 받는다.
    static func isPasteShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else { return false }
        return event.keyCode == 9 || event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    /// 클립보드의 이미지가 아닌 파일 (Finder 에서 복사한 PDF · 로그) — 텍스트 뷰는 이름만 넣으므로 입력창이 경로를 글로 넣는다.
    static func otherFiles(from pasteboard: NSPasteboard) -> [URL] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return urls.filter { !ImageAttachments.isImageFile($0) }
    }

    /// 클립보드의 이미지: 복사한 이미지 파일들, 또는 이미지 데이터(화면 캡처를 클립보드로 · 브라우저의 "이미지 복사").
    /// 이미지가 아니면 nil — 텍스트 뷰가 평소대로 붙여넣는다. 서식 있는 글(문서에서 복사한 RTF)은 글로 둔다.
    static func images(from pasteboard: NSPasteboard) -> (files: [URL], data: [Data])? {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let files = urls.filter(ImageAttachments.isImageFile)
        if !files.isEmpty { return (files, []) }
        if !urls.isEmpty { return nil }
        let types = pasteboard.types ?? []
        if types.contains(.rtf) || types.contains(.rtfd) { return nil }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) { return ([], [data]) }
        return nil
    }
}
