import AppKit
import SwiftUI

// MARK: - Markdown 메시지

/// 응답 · 사용자 메시지 본문. 제목 · 인라인 서식 · 코드 블록 · 표를 NSTextView 하나(`MarkdownTextView`)에 그려
/// 끌어 선택 · ⌘A · ⌘C 가 메시지 전체에 걸친다. 본문 14pt(`TypeScale.body`), 줄간 1.62. 실행 로그는 여기서 그리지 않는다 (원문 그대로 보여준다).
struct MarkdownMessage: View {
    let text: String
    var color: Color = Theme.ink2
    /// 흐르는 응답이면 받은 글을 고른 속도로 풀고 새 글자를 서서히 보인다 (`StreamingAgentMessage`). 기본은 곧바로 다.
    var reveal: MarkdownReveal = .instant
    /// 처음 그릴 때 받아 둔 글을 처음부터 풀지 (`reveal` 이 `.streaming` 일 때만).
    var revealsFromBeginning = false
    /// 글 위의 도움말. 텍스트 뷰가 글자 자리를 덮어 바깥 `.help` 는 여백에서만 뜬다 — 같은 말을 여기에도 준다.
    var help: String?
    /// 사람이 친 글 (사용자 메시지) — Markdown 으로 해석하지 않고 친 그대로, 코드 울타리만 상자로 (`MarkdownBlock.parsePlain`).
    var plain = false
    /// 상대 경로 링크를 풀 폴더 (대화의 프로젝트 폴더 — `ThreadView` 가 환경으로 준다). 없으면 상대 경로는 링크로 그리지 않는다.
    @Environment(\.messageLinkBase) private var linkBase

    var body: some View {
        MarkdownTextRepresentable(text: text, color: color, reveal: reveal, revealsFromBeginning: revealsFromBeginning,
                                  help: help, plain: plain, linkBase: linkBase)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension EnvironmentValues {
    /// 메시지 안 상대 경로 링크를 풀 폴더 (대화의 프로젝트 폴더 — 독립 작업 폴더면 그 폴더).
    @Entry var messageLinkBase: String? = nil
}

private struct MarkdownTextRepresentable: NSViewRepresentable {
    let text: String
    let color: Color
    let reveal: MarkdownReveal
    let revealsFromBeginning: Bool
    let help: String?
    let plain: Bool
    let linkBase: String?

    final class Coordinator {
        var rendered: (text: String, color: Color, plain: Bool, linkBase: String?)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MarkdownTextView { MarkdownTextView() }

    func updateNSView(_ view: MarkdownTextView, context: Context) {
        if view.toolTip != help { view.toolTip = help }
        // 부모가 다시 그릴 때마다 불리지만, 내용이 같으면 글자를 다시 짓지 않는다. 받기를 마친 것만 바뀌었으면 그것만 알린다.
        if let rendered = context.coordinator.rendered, rendered.text == text, rendered.color == color,
           rendered.plain == plain, rendered.linkBase == linkBase {
            view.setReveal(reveal)
            return
        }
        context.coordinator.rendered = (text, color, plain, linkBase)
        view.render(source: text, style: .app(text: color), plain: plain, linkBase: linkBase, reveal: reveal,
                    revealsFromBeginning: revealsFromBeginning)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MarkdownTextView, context: Context) -> CGSize? {
        if let width = proposal.width, width > 0, width.isFinite {
            return CGSize(width: width, height: view.height(forWidth: width))
        }
        // 폭 0 · 무한 · 없음은 VStack · frame 이 배치마다 묻는 탐색이다. 긴 메시지를 그 폭으로 다시 배치하지 않고
        // 지금 폭(처음이면 본문 단 폭)의 높이로 답한다 — 폭 0 에는 얼마든지 좁아질 수 있다(0)고.
        let width = view.bounds.width > 0 ? view.bounds.width : Theme.Metric.column
        return CGSize(width: proposal.width == 0 ? 0 : width, height: view.height(forWidth: width))
    }
}

// MARK: - 스트림 선택 (행 단위)

extension View {
    /// SwiftUI 행을 대화 스트림 선택에 넣는다 — 메시지 사이의 실행 기록 · 머리글 · 안내도 한 번의 끌기 · ⌘A 로 고르고
    /// 복사한다 (`StreamSelection`). 행 뒤에 깔리는 뷰라 버튼 · 글 누르기는 그대로 앞의 SwiftUI 가 받는다.
    func streamSelectable(_ text: String, kind: StreamCopyKind = .line) -> some View {
        background(StreamSelectionAtom(text: text, kind: kind))
    }
}

private struct StreamSelectionAtom: NSViewRepresentable {
    let text: String
    let kind: StreamCopyKind

    func makeNSView(context: Context) -> StreamSelectionAtomView { StreamSelectionAtomView() }

    func updateNSView(_ view: StreamSelectionAtomView, context: Context) {
        view.copyText = text
        view.kind = kind
    }
}

extension MarkdownStyle {
    /// Theme 의 동적 색. 문단 글자색만 메시지마다 다르다 (에이전트 ink2 · 사용자 ink).
    static func app(text: Color) -> MarkdownStyle {
        MarkdownStyle(text: NSColor(text),
                      heading: NSColor(Theme.ink),
                      link: NSColor(Theme.claudeDeep),
                      inlineCodeText: NSColor(Theme.ink2),
                      inlineCodeBackground: NSColor(Theme.wellSoft),
                      codeText: NSColor(Theme.ink2),
                      codeBackground: NSColor(Theme.codeBackground),
                      codeHeader: NSColor(Theme.codeHeader),
                      codeBorder: NSColor(Theme.codeBorder),
                      codeLabel: NSColor(Theme.slate2),
                      codeCopied: NSColor(Theme.emeraldText),
                      tableText: NSColor(Theme.ink2),
                      tableHeaderRule: NSColor(Theme.hair),
                      tableRule: NSColor(Theme.hairSoft),
                      rule: NSColor(Theme.hairSoft))
    }
}
