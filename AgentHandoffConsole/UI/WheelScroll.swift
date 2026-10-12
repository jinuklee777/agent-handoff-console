import AppKit

/// 마우스 휠(한 칸씩 도는 휠)의 스크롤 거리.
///
/// AppKit 의 스크롤 뷰는 휠 한 칸에 `verticalLineScroll`(기본 10pt)만큼 움직여 브라우저 · Electron 앱(Chromium 은 한 칸 40px —
/// `kScrollbarPixelsPerCocoaTick`)의 4분의 1이다. 휠 이벤트가 오면 커서 아래의 스크롤 뷰(바깥 것까지)의 한 줄 거리를 넓힌 뒤
/// 이벤트는 그대로 보낸다 — 이벤트를 다시 만들지 않으므로 가속 · 대상 창 · 스크롤 단계는 AppKit 그대로다.
/// SwiftUI `ScrollView`(HostingScrollView)도 이 값을 따른다 (2026-10-06 실측: 한 칸 10pt → 40pt).
/// 트랙패드 · Magic Mouse 처럼 픽셀 단위로 오는 이벤트(`hasPreciseScrollingDeltas`)는 이 값을 쓰지 않아 그대로다.
/// 앱 안 터미널(SwiftTerm)은 휠을 스스로 줄 수로 바꾸므로 영향이 없다.
@MainActor
enum WheelScroll {
    /// 휠 한 칸(가속 전)의 거리.
    static let lineDistance: CGFloat = 40

    private static var monitor: Any?

    /// 앱 전체(메인 창 · 설정 창 · 팝오버)에 한 번 건다.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            if !event.hasPreciseScrollingDeltas { widenScrollViews(in: event.window, at: event.locationInWindow) }
            return event
        }
    }

    /// 커서 아래 뷰를 감싼 스크롤 뷰들 — 가로 코드 상자 안에서 세로로 굴리면 AppKit 이 바깥 스크롤 뷰로 넘기므로 바깥까지 넓힌다.
    static func widenScrollViews(in window: NSWindow?, at locationInWindow: NSPoint) {
        guard let content = window?.contentView else { return }
        let point = content.superview?.convert(locationInWindow, from: nil) ?? locationInWindow
        guard let hit = content.hitTest(point) else { return }
        var scrollView = hit as? NSScrollView ?? hit.enclosingScrollView
        while let current = scrollView {
            widen(current)
            scrollView = current.enclosingScrollView
        }
    }

    /// 표 뷰처럼 스스로 더 큰 값을 둔 스크롤 뷰는 줄이지 않는다.
    static func widen(_ scrollView: NSScrollView) {
        if scrollView.verticalLineScroll < lineDistance { scrollView.verticalLineScroll = lineDistance }
        if scrollView.horizontalLineScroll < lineDistance { scrollView.horizontalLineScroll = lineDistance }
    }
}
