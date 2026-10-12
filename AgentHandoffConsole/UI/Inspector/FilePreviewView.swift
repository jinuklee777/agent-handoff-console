import AppKit
import SwiftUI

/// 파일 탭 아래의 미리보기 — 고른 파일을 앱 안에서 보인다 (무엇으로 · 얼마나는 `FilePreview`). Markdown 은 대화와 같은 렌더러
/// (`MarkdownMessage` — 상대 링크는 그 파일의 폴더 기준), 글 · 코드는 고정폭(큰 파일은 앞부분만), 그림은 그림, 그 밖은
/// "기본 앱으로 열기". 머리: 이름 · 크기 · 잘림 · [기본 앱으로 열기…] · ×. 읽기만 한다 — 실행될 수 있는 파일의 규칙
/// (`FileOpenRule`)은 [기본 앱으로 열기…] 가 따른다 (부르는 쪽의 `openInDefaultApp`).
struct FilePreviewView: View {
    let url: URL
    /// 프로젝트 폴더 기준 경로 (머리 · 도움말).
    let path: String
    let openInDefaultApp: () -> Void
    let close: () -> Void

    @State private var loaded: Result<FilePreview.Content, FilePreview.LoadError>?
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.paper)
        .task(id: url) { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.control)
            Text(url.lastPathComponent)
                .font(Theme.ui(.callout, .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            if case .success(let content)? = loaded {
                Text(ByteCountFormatter.string(fromByteCount: Int64(content.byteSize), countStyle: .file))
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate2)
                    .fixedSize()
            }
            Spacer(minLength: 6)
            Button("기본 앱으로 열기…", action: openInDefaultApp)
                .buttonStyle(GhostChipStyle(height: 22, horizontalPadding: 7))
                .font(Theme.ui(.caption))
                .help("macOS 기본 앱으로 엽니다 — 실행될 수 있는 파일이면 먼저 묻습니다")
            IconButton(systemName: "xmark", size: 10, color: Theme.control, help: "미리보기 닫기", action: close)
                .accessibilityLabel("미리보기 닫기")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    @ViewBuilder
    private var content: some View {
        switch loaded {
        case nil:
            HStack(spacing: 7) {
                PendingRing(color: Theme.slate2)
                Text("읽는 중…").font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
            }
            .padding(14)
        case .failure(let error):
            note(failureText(error))
        case .success(let content):
            switch content.kind {
            case .markdown:
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if content.truncated { truncation(content) }
                        MarkdownMessage(text: content.text ?? "", color: Theme.ink2)
                            .environment(\.messageLinkBase, url.deletingLastPathComponent().path)
                    }
                    .padding(14)
                }
            case .text:
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 8) {
                        if content.truncated { truncation(content) }
                        Text(content.text ?? "")
                            .font(Theme.mono(.caption))
                            .foregroundStyle(Theme.ink2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                    .padding(12)
                }
            case .image:
                if let image {
                    ScrollView {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: min(image.size.width, 2000), maxHeight: min(image.size.height, 2000))
                            .padding(12)
                            .accessibilityLabel("\(url.lastPathComponent) 그림")
                    }
                } else {
                    note("그림을 읽지 못했습니다. 기본 앱으로 열어 보세요.")
                }
            case .other:
                note(content.byteSize > FilePreview.imageByteLimit
                     ? "파일이 커서 앱 안에서 미리 보지 않습니다. 기본 앱으로 열어 보세요."
                     : "앱 안에서 미리 볼 수 없는 형식입니다. 기본 앱으로 열어 보세요.")
            }
        }
    }

    private func truncation(_ content: FilePreview.Content) -> some View {
        Text(FilePreview.truncationNote(byteSize: content.byteSize))
            .font(Theme.ui(.caption))
            .foregroundStyle(Theme.amberText)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(.caption))
            .foregroundStyle(Theme.slate)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
    }

    private func failureText(_ error: FilePreview.LoadError) -> String {
        switch error {
        case .missing: return "파일이 없습니다 (지워졌거나 옮겨졌습니다)."
        case .directory: return "폴더입니다."
        case .unreadable(let reason): return "파일을 읽지 못했습니다: \(reason)"
        }
    }

    private func load() async {
        loaded = nil
        image = nil
        let url = self.url
        let result = await Task.detached(priority: .userInitiated) { FilePreview.load(url) }.value
        if case .success(let content) = result, content.kind == .image {
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
            guard !Task.isCancelled else { return }
            image = data.flatMap(NSImage.init(data:))
        }
        guard !Task.isCancelled else { return }
        loaded = result
    }
}
