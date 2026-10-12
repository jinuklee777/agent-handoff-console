import AppKit
import SwiftUI

/// 대화 스크롤 뷰 위에서 사람이 휠 · 트랙패드로 **위로** 굴린 순간을 알린다 — 맨 아래 따라가기를 멈추는 신호 (`StreamFollow`).
///
/// SwiftUI 의 스크롤 단계(`onScrollPhaseChange`)와 자리 변화만으로는 놓쳤다: 앱이 맨 아래로 내리는 스크롤이 처리되는 중에 휠이 오면
/// interacting → idle 이 자리 변화보다 먼저 와, 한 칸 올린 것을 사람의 움직임으로 세지 못하고 곧바로 끌어내렸다 (2026-10-06 실측 —
/// 미리보기 `-preview.action stream`). 이벤트는 보는 것만 하고 그대로 흘려보낸다.
/// 스크롤 내용 안에 깔아 둔다 — 커서 아래 뷰가 이 스크롤 뷰 안일 때만 센다 (가로 코드 상자 위는 세고, 입력창 위는 세지 않는다).
struct StreamScrollIntent: NSViewRepresentable {
    let onScrollUp: () -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) { view.onScrollUp = onScrollUp }

    final class ProbeView: NSView {
        var onScrollUp: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.wheel(deltaY: event.scrollingDeltaY, at: event.locationInWindow, in: event.window)
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        /// 휠 이벤트 하나 — 위로(이전 글 쪽으로) 굴렸고 · 이 창이고 · 올라갈 곳이 있는 스크롤 뷰 위일 때만 알린다.
        func wheel(deltaY: CGFloat, at locationInWindow: NSPoint, in eventWindow: NSWindow?) {
            guard deltaY > 0, let window, eventWindow === window,
                  let scroll = enclosingScrollView, let document = scroll.documentView,
                  document.frame.height > scroll.contentView.bounds.height + 1,
                  let content = window.contentView else { return }
            let point = content.superview?.convert(locationInWindow, from: nil) ?? locationInWindow
            var candidate = content.hitTest(point)?.enclosingScrollView
            while let current = candidate, current !== scroll { candidate = current.enclosingScrollView }
            guard candidate === scroll else { return }
            onScrollUp?()
        }
    }
}
