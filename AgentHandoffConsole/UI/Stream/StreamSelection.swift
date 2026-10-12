import AppKit

// 대화 스트림 전체에 걸친 선택. 메시지마다 NSTextView(`MarkdownTextView`)가 따로라 텍스트 뷰 하나의 선택은 그 메시지에서
// 멈춘다 — 메시지 사이에 명령 · 도구 기록이 끼면 응답 하나도 한 번에 고를 수 없었다. 메시지 안에서 시작한 끌기를 여기서 이어 받아
// 메시지는 글자 단위로, 그 사이의 SwiftUI 행(실행 기록 줄 · 머리글 · 안내)은 행 단위로 고르고, ⌘C 는 화면 순서대로 잇는다.
// ⌘A 는 대화 전체. 참여자는 따로 등록하지 않고 필요할 때 스크롤 뷰 안에서 찾는다 (SwiftUI 가 행을 다시 만들어도 어긋나지 않게).

/// 복사할 때 이웃과의 구분. 블록(메시지 · 안내)은 빈 줄로, 실행 기록 줄끼리는 줄바꿈으로, 머리글(누가 말했나)은 바로 아래 글에 붙인다.
enum StreamCopyKind {
    case block, line, label
}

/// 대화 스트림 선택에 참여하는 뷰. 메시지는 글자 단위(`MarkdownTextView`), SwiftUI 행은 행 단위(`StreamSelectionAtomView`).
@MainActor
protocol StreamSelectable: NSView {
    /// 고를 수 있는 길이 — 행 단위는 1 (통째로 고르거나 안 고른다).
    var streamLength: Int { get }
    var isStreamAtom: Bool { get }
    var streamCopyKind: StreamCopyKind { get }
    /// 창 좌표의 점에 가장 가까운 글자 위치 (글자 단위 참여자만 쓴다).
    func streamIndex(at windowPoint: NSPoint) -> Int
    /// 고른 범위를 보인다 — nil 이면 지운다.
    func showStreamSelection(_ range: NSRange?)
    func streamCopyText(_ range: NSRange) -> String
}

/// 한 스크롤 뷰(대화 스트림) 안의 선택 상태.
@MainActor
final class StreamSelection {
    private struct Point {
        weak var view: (any StreamSelectable)?
        var index: Int
    }

    private struct Item {
        let view: any StreamSelectable
        /// 창 좌표 (위가 큰 y).
        let frame: NSRect
    }

    private static let domains = NSMapTable<NSScrollView, StreamSelection>.weakToStrongObjects()

    /// 뷰가 든 대화 스트림의 선택. 스크롤 뷰 밖이면 nil (그때 텍스트 뷰는 기본 동작만 한다).
    static func domain(for view: NSView) -> StreamSelection? {
        guard let scrollView = view.enclosingScrollView else { return nil }
        if let existing = domains.object(forKey: scrollView) { return existing }
        let created = StreamSelection(scrollView: scrollView)
        domains.setObject(created, forKey: scrollView)
        return created
    }

    private weak var scrollView: NSScrollView?
    private var anchor: Point?
    private var focus: Point?
    /// ⌘C 가 닿는 텍스트 뷰 (첫 응답자). 선택의 기준점은 행일 수도 있어(⌘A) 따로 둔다.
    private weak var owner: NSView?
    private var keyObservers: [NSObjectProtocol] = []

    private init(scrollView: NSScrollView) {
        self.scrollView = scrollView
    }

    // MARK: 끌기

    /// 메시지 안에서 한 번 누르기. 끌면 메시지 경계를 넘어 고르고(가장자리 밖으로 끌면 스트림이 따라 스크롤된다),
    /// 끌지 않고 떼면 선택을 지운다 (링크면 연다). ⇧ 누르기는 앞 선택을 이어서 늘린다.
    /// `activating` 은 창을 앞으로 가져오는 첫 클릭이다 (`MarkdownTextView.acceptsFirstMouse`) — 끌 때만 고르고,
    /// 누르기만 하면 앞 선택을 그대로 두고 링크도 열지 않는다 (창을 누르려던 것이지 그 글자를 누르려던 것이 아니다).
    func track(from view: MarkdownTextView, mouseDown event: NSEvent, activating: Bool = false) {
        guard let window = view.window else { return }
        let start = event.locationInWindow
        let extending = event.modifierFlags.contains(.shift) && anchor?.view != nil
        if !activating { begin(at: start, in: view, extending: extending) }

        var lastDrag: NSEvent?
        var dragged = extending && !activating
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            switch next.type {
            case .leftMouseDragged:
                let point = next.locationInWindow
                if !dragged, hypot(point.x - start.x, point.y - start.y) < 3 { continue }
                if !dragged, activating { begin(at: start, in: view, extending: extending) }
                dragged = true
                lastDrag = next
                _ = view.autoscroll(with: next)
                extend(to: point)
            case .periodic:
                // 마우스를 멈춰 둬도 가장자리 밖이면 계속 스크롤한다.
                guard let drag = lastDrag, view.autoscroll(with: drag) else { continue }
                extend(to: drag.locationInWindow)
            case .leftMouseUp:
                if !dragged, !activating {
                    clear()
                    view.openLink(at: start)
                }
                return
            default:
                continue
            }
        }
    }

    /// 끌기의 시작. `view` 가 첫 응답자(⌘C 가 닿는 곳)가 되고 누른 곳이 기준점이 된다 — ⇧ 면 앞 기준점에서 이어 늘린다.
    func begin(at point: NSPoint, in view: MarkdownTextView, extending: Bool = false) {
        // 앞 첫 응답자(다른 메시지)가 물러나며 clear() 를 부른다 — 첫 응답자를 먼저 바꾸고, 이어 늘릴 기준점은 그 전에 챙겨 둔다.
        let kept = extending ? anchor : nil
        if let window = view.window, window.firstResponder !== view { window.makeFirstResponder(view) }
        owner = view
        if let kept {
            anchor = kept
            return extend(to: point)
        }
        anchor = Point(view: view, index: view.streamIndex(at: point))
        focus = anchor
        apply()
    }

    /// 끄는 중 — 기준점부터 창 좌표의 점까지 고른다.
    func extend(to point: NSPoint) {
        let items = participants()
        guard let anchorView = anchor?.view,
              let anchorOrder = items.firstIndex(where: { $0.view === anchorView }),
              let position = Self.position(of: point, frames: items.map(\.frame),
                                           lengths: items.map(\.view.streamLength),
                                           atoms: items.map(\.view.isStreamAtom), anchorOrder: anchorOrder,
                                           index: { items[$0].view.streamIndex(at: point) })
        else { return }
        focus = Point(view: items[position.order].view, index: position.index)
        apply(items)
    }

    // MARK: 전체 선택 · 지우기 · 복사

    /// ⌘A — 스트림에 보이는 대화 전체 (앞쪽 "이전 기록 더 보기" 로 접힌 행은 빼고).
    func selectAll(from view: MarkdownTextView) {
        let items = participants()
        guard let first = items.first, let last = items.last else { return }
        owner = view
        anchor = Point(view: first.view, index: 0)
        focus = Point(view: last.view, index: last.view.streamLength)
        apply(items)
    }

    func clear() {
        anchor = nil
        focus = nil
        owner = nil
        for item in participants() { item.view.showStreamSelection(nil) }
        for observer in keyObservers { NotificationCenter.default.removeObserver(observer) }
        keyObservers = []
    }

    /// 고른 곳이 메시지 하나를 넘을 때(행이 섞이거나 참여자가 둘 이상)의 복사 글. 한 메시지 안이면 nil — 그 텍스트 뷰가 스스로 복사한다.
    func spanningCopyText() -> String? {
        let items = participants()
        guard let ranges = currentRanges(items), Self.spans(ranges, atoms: items.map(\.view.isStreamAtom)) else {
            return nil
        }
        return Self.joined(ranges.keys.sorted().map { order in
            (items[order].view.streamCopyKind, items[order].view.streamCopyText(ranges[order]!))
        })
    }

    var hasSpanningSelection: Bool {
        let items = participants()
        guard let ranges = currentRanges(items) else { return false }
        return Self.spans(ranges, atoms: items.map(\.view.isStreamAtom))
    }

    /// 첫 응답자가 아닌 메시지의 선택도 활성 색으로 칠할까 — 끌기를 시작한 메시지가 키 창의 첫 응답자일 때.
    func emphasizes(_ view: NSView) -> Bool {
        guard let owner, owner !== view, let window = owner.window, window === view.window else { return false }
        return window.isKeyWindow && window.firstResponder === owner
    }

    // MARK: 계산

    /// 스크롤 뷰 안의 참여자를 화면 순서(위 → 아래, 같은 높이면 왼쪽 → 오른쪽)로. 크기가 없거나 숨은 뷰는 뺀다.
    private func participants() -> [Item] {
        guard let root = scrollView?.contentView else { return [] }
        var found: [any StreamSelectable] = []
        func walk(_ view: NSView) {
            if let participant = view as? any StreamSelectable {
                found.append(participant)
            } else {
                view.subviews.forEach(walk)
            }
        }
        walk(root)
        return found.compactMap { view -> Item? in
            guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return nil }
            let frame = view.convert(view.bounds, to: nil)
            return frame.isEmpty ? nil : Item(view: view, frame: frame)
        }
        .sorted { a, b in
            abs(a.frame.maxY - b.frame.maxY) > 0.5 ? a.frame.maxY > b.frame.maxY : a.frame.minX < b.frame.minX
        }
    }

    private func currentRanges(_ items: [Item]) -> [Int: NSRange]? {
        guard let anchor, let focus, let anchorView = anchor.view, let focusView = focus.view,
              let a = items.firstIndex(where: { $0.view === anchorView }),
              let f = items.firstIndex(where: { $0.view === focusView }) else { return nil }
        return Self.ranges(from: (a, anchor.index), to: (f, focus.index), lengths: items.map(\.view.streamLength))
    }

    private func apply(_ items: [Item]? = nil) {
        let items = items ?? participants()
        let ranges = currentRanges(items) ?? [:]
        for (order, item) in items.enumerated() { item.view.showStreamSelection(ranges[order]) }
        watchKeyWindow(owner?.window)
    }

    /// 키 창이 바뀌면 다시 칠한다 (활성 · 흐린 선택 색).
    private func watchKeyWindow(_ window: NSWindow?) {
        guard keyObservers.isEmpty, let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.participants().forEach { $0.view.needsDisplay = true }
                }
            })
        }
    }

    // MARK: 순수 판정 (MarkdownTests)

    /// 두 위치 사이를 참여자별 범위로. 위치는 (화면 순서, 글자 위치) — 앞뒤가 바뀌어도 된다. 빈 범위는 넣지 않는다.
    static func ranges(from a: (order: Int, index: Int), to b: (order: Int, index: Int),
                       lengths: [Int]) -> [Int: NSRange] {
        let (start, end) = (a.order, a.index) <= (b.order, b.index) ? (a, b) : (b, a)
        var ranges: [Int: NSRange] = [:]
        for order in start.order...end.order where lengths.indices.contains(order) {
            let lower = order == start.order ? min(start.index, lengths[order]) : 0
            let upper = order == end.order ? min(end.index, lengths[order]) : lengths[order]
            if upper > lower { ranges[order] = NSRange(location: lower, length: upper - lower) }
        }
        return ranges
    }

    /// 창 좌표의 점이 스트림의 어디인가. 참여자 안이면 그 글자 위치, 같은 높이의 여백이면 가장 가까운 참여자,
    /// 참여자 사이 틈이면 위 참여자의 끝, 맨 위보다 위면 처음. 행 단위 참여자에 닿으면 그 행을 넣는 쪽 끝 (기준점 뒤면 1, 앞이면 0).
    static func position(of point: NSPoint, frames: [NSRect], lengths: [Int], atoms: [Bool], anchorOrder: Int,
                         index: (Int) -> Int) -> (order: Int, index: Int)? {
        guard !frames.isEmpty else { return nil }
        func at(_ order: Int) -> (order: Int, index: Int) {
            atoms[order] ? (order, order >= anchorOrder ? 1 : 0) : (order, index(order))
        }
        if let order = frames.firstIndex(where: { $0.contains(point) }) { return at(order) }
        func distance(_ frame: NSRect) -> CGFloat {
            point.x < frame.minX ? frame.minX - point.x : max(0, point.x - frame.maxX)
        }
        let band = frames.indices.filter { frames[$0].minY <= point.y && point.y <= frames[$0].maxY }
        if let order = band.min(by: { distance(frames[$0]) < distance(frames[$1]) }) { return at(order) }
        if let order = frames.lastIndex(where: { $0.minY > point.y }) { return (order, lengths[order]) }
        return (0, 0)
    }

    /// 한 메시지 안의 선택이 아닌가 — 참여자가 둘 이상이거나 행이 섞였다.
    static func spans(_ ranges: [Int: NSRange], atoms: [Bool]) -> Bool {
        ranges.count > 1 || ranges.keys.contains { atoms.indices.contains($0) && atoms[$0] }
    }

    /// 참여자별 복사 글을 잇는다 (`StreamCopyKind`).
    static func joined(_ pieces: [(kind: StreamCopyKind, text: String)]) -> String {
        var result = ""
        var previous: StreamCopyKind?
        for piece in pieces where !piece.text.isEmpty {
            if let previous {
                result += previous == .label || (previous == .line && piece.kind == .line) ? "\n" : "\n\n"
            }
            result += piece.text
            previous = piece.kind
        }
        return result
    }
}

// MARK: - 행 단위 참여자

/// SwiftUI 행(실행 기록 줄 · 머리글 · 안내) 뒤에 깔려 자리와 복사 글을 알리고, 골라지면 선택 색을 칠한다.
/// 마우스는 받지 않는다 (hitTest nil) — 앞의 SwiftUI 버튼 · 글이 그대로 받는다. SwiftUI 쪽은 `.streamSelectable(_:)`.
final class StreamSelectionAtomView: NSView, StreamSelectable {
    var copyText = ""
    var kind: StreamCopyKind = .line
    private(set) var isStreamSelected = false {
        didSet { if isStreamSelected != oldValue { needsDisplay = true } }
    }

    var streamLength: Int { 1 }
    var isStreamAtom: Bool { true }
    var streamCopyKind: StreamCopyKind { kind }
    func streamIndex(at windowPoint: NSPoint) -> Int { 0 }
    func showStreamSelection(_ range: NSRange?) { isStreamSelected = range != nil }
    func streamCopyText(_ range: NSRange) -> String { copyText }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard isStreamSelected else { return }
        (window?.isKeyWindow == true ? NSColor.selectedTextBackgroundColor
                                     : NSColor.unemphasizedSelectedTextBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
}

// MARK: - 입력창으로 넘기는 타자

/// 메시지(선택 전용 텍스트 뷰)를 눌러 고른 뒤 바로 친 글자를 그 칸의 입력창으로 보낸다 (`MarkdownTextView.keyDown`).
/// 메시지는 편집할 수 없어 친 글자가 그냥 사라졌다 (경고음 — 첫 사용자 시험 chat-19).
@MainActor
enum StreamTyping {
    /// 글자를 치는 키인가: ⌘ · ⌃ 없이, 방향 · 기능 · ↵ · ⇥ · ⌫ 같은 특수 키가 아니고, 글자가 제어 문자(esc …)가 아니다.
    /// ⌥ 로 치는 글자는 글자다.
    static func isTyping(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command), !flags.contains(.control), !flags.contains(.function),
              event.specialKey == nil, let characters = event.characters, !characters.isEmpty else { return false }
        return !characters.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// 메시지가 든 대화 칸의 입력창 텍스트 뷰: 메시지의 스크롤 뷰(대화 스트림) 자리 안에 겹쳐 놓인 편집할 수 있는 텍스트 뷰 중
    /// 그 스크롤 뷰의 자손이 아닌 것 — 입력창은 스트림 위에 겹쳐 놓인다 (`ThreadView`). 스트림 안의 편집 칸(인계 카드의 덧붙일 말)은
    /// 스크롤 뷰의 자손이라 빠지고, 다른 칸의 입력창 · 인스펙터의 커밋 칸은 자리 밖이라 빠진다. 없으면 nil (내부 대화 · 인스펙터).
    static func composer(near view: NSView) -> NSTextView? {
        guard let scrollView = view.enclosingScrollView, let window = view.window, let root = window.contentView
        else { return nil }
        let area = scrollView.convert(scrollView.bounds, to: nil)
        var found: NSTextView?
        func visit(_ candidate: NSView) {
            guard found == nil, candidate !== scrollView, !candidate.isHidden else { return }
            if let textView = candidate as? NSTextView, textView.isEditable, !textView.isFieldEditor {
                // 자리는 그 편집 칸의 틀 — TextEditor 면 자기 스크롤 뷰. `visibleRect` 는 쓰지 않는다: 부모를 자르지 않는 뷰(macOS 14+)는
                // 부모 밖에 있어도 부모의 보이는 자리를 돌려줘 다른 칸의 입력창이 이 칸 안에 있는 것처럼 보였다.
                let box: NSView = textView.enclosingScrollView ?? textView
                let frame = box.convert(box.bounds, to: nil)
                if !frame.isEmpty, area.contains(NSPoint(x: frame.midX, y: frame.midY)) {
                    found = textView
                    return
                }
            }
            candidate.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    /// 키를 다시 보내는 곳 — 앱 이벤트 대기열의 맨 앞. 시험은 바꿔 넣는다 (검증 실행 파일에서 앱 이벤트 대기열을 돌리면
    /// 실행 파일이 그 자리에서 끝났다).
    static var post: @MainActor (NSEvent) -> Void = { NSApp.postEvent($0, atStart: true) }

    /// 입력창이 글자를 받게 하고 그 키를 다시 보낸다 — 입력창의 입력기(한글 조합)가 처음부터 받도록 이벤트 대기열의 맨 앞에.
    /// 입력창이 첫 응답자가 되지 못하면 false (부르는 쪽이 기본 동작을 한다).
    @discardableResult
    static func forward(_ event: NSEvent, to composer: NSTextView) -> Bool {
        guard let window = composer.window, window.makeFirstResponder(composer) else { return false }
        post(event)
        return true
    }
}
