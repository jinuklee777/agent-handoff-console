import Foundation

/// 파일 탭의 미리보기 — 고른 파일을 앱 안에서 무엇으로 보일지와 얼마나 읽을지 (SwiftUI 없이 — 검증 하네스가 컴파일).
/// Markdown 은 대화와 같은 렌더러, 글 · 코드는 고정폭(큰 파일은 앞부분만), 그림은 그림, 그 밖은 "기본 앱으로 열기".
/// 미리보기는 파일을 읽기만 한다 — 실행될 수 있는 파일의 규칙(`FileOpenRule`)은 "기본 앱으로 열기" 에만 걸린다.
enum FilePreview {
    enum Kind: Equatable, Sendable {
        case markdown
        case text
        case image
        /// 미리 볼 수 없는 형식 (이진 파일 · 너무 큰 그림 등) — "기본 앱으로 열기" 로.
        case other
    }

    /// 글로 읽을 앞부분의 크기 — 이보다 크면 앞부분만 보이고 그 사실을 적는다.
    static let textByteLimit = 128 * 1024
    /// 글로 보일 줄 수의 상한 (한 줄이 짧은 큰 파일).
    static let textLineLimit = 3000
    /// 그림으로 읽을 파일의 상한 — 넘으면 기본 앱으로.
    static let imageByteLimit = 40 * 1024 * 1024
    /// 글인지 볼 앞부분.
    static let sniffBytes = 8 * 1024

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp",
                                               "ico", "icns"]
    /// 글이 아닌 것이 분명한 형식 — 앞부분이 우연히 글처럼 읽혀도 글로 보이지 않는다.
    static let binaryExtensions: Set<String> = ["pdf", "zip", "gz", "tgz", "xz", "bz2", "7z", "rar", "dmg", "pkg", "app", "a", "o",
                                                "dylib", "so", "exe", "class", "jar", "sqlite", "sqlite3", "db", "mp3", "mp4",
                                                "mov", "m4a", "wav", "aiff", "ttf", "otf", "woff", "woff2", "psd", "sketch", "key",
                                                "pages", "numbers", "docx", "xlsx", "pptx"]

    /// 확장자로 먼저 고르고, 모르는 확장자(없는 것 포함)는 앞부분 바이트로 — NUL 이 없고 UTF-8 로 읽히면 글.
    static func kind(fileName: String, head: Data) -> Kind {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return isText(head) ? .markdown : .other }
        if imageExtensions.contains(ext) { return .image }
        if binaryExtensions.contains(ext) { return .other }
        return isText(head) ? .text : .other
    }

    /// 앞부분이 글인가 — NUL 바이트가 없고 UTF-8 로 읽힌다 (끝의 잘린 다중 바이트 글자는 봐준다). 빈 파일은 글.
    static func isText(_ head: Data) -> Bool {
        if head.isEmpty { return true }
        if head.contains(0) { return false }
        return decodeUTF8Prefix(head) != nil
    }

    /// UTF-8 로 읽는다 — 앞부분만 읽어 끝이 글자 중간에서 잘렸으면 그 조각(최대 3바이트)을 떼고 읽는다.
    static func decodeUTF8Prefix(_ data: Data) -> String? {
        for drop in 0...min(3, data.count) {
            if let text = String(data: data.dropLast(drop), encoding: .utf8) { return text }
        }
        return nil
    }

    /// 보일 글 — 줄 수 상한을 넘으면 앞의 줄들만. `truncated` 는 바이트 · 줄 어느 쪽으로든 잘렸는지.
    static func shownText(_ text: String, byteTruncated: Bool) -> (text: String, truncated: Bool) {
        var lines = 0
        var end = text.endIndex
        for index in text.indices where text[index] == "\n" {
            lines += 1
            if lines == textLineLimit {
                end = index
                break
            }
        }
        let cut = end != text.endIndex
        return (cut ? String(text[..<end]) : text, cut || byteTruncated)
    }

    /// 잘렸을 때 미리보기 머리에 적는 말.
    static func truncationNote(byteSize: Int) -> String {
        "앞부분만 보입니다 (전체 \(ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)) — 다 보려면 기본 앱으로 여세요)"
    }

    /// 읽은 결과.
    struct Content: Equatable, Sendable {
        var kind: Kind
        /// Markdown · 글이면 보일 글.
        var text: String?
        /// 앞부분만 읽었다.
        var truncated: Bool = false
        /// 파일 크기 (바이트).
        var byteSize: Int
    }

    enum LoadError: Error, Equatable, Sendable {
        case missing
        case directory
        case unreadable(String)
    }

    /// 파일을 읽어 미리보기 내용을 만든다 (블로킹 — 부르는 쪽이 뒤에서). 글은 앞부분 `textByteLimit` 만 읽는다.
    static func load(_ url: URL) -> Result<Content, LoadError> {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .failure(.missing) }
        guard !isDirectory.boolValue else { return .failure(.directory) }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { return .failure(.unreadable(error.localizedDescription)) }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: sniffBytes)) ?? Data()
        let kind = kind(fileName: url.lastPathComponent, head: head)
        switch kind {
        case .image:
            return .success(Content(kind: size <= imageByteLimit ? .image : .other, byteSize: size))
        case .other:
            return .success(Content(kind: .other, byteSize: size))
        case .markdown, .text:
            var data = head
            if head.count == sniffBytes, let rest = try? handle.read(upToCount: textByteLimit - sniffBytes) { data += rest }
            let byteTruncated = size > data.count
            guard let decoded = decodeUTF8Prefix(data) else { return .success(Content(kind: .other, byteSize: size)) }
            let shown = shownText(decoded, byteTruncated: byteTruncated)
            return .success(Content(kind: kind, text: shown.text, truncated: shown.truncated, byteSize: size))
        }
    }
}
