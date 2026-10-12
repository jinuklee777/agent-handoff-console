import AppKit
import CoreText
import SwiftUI

// 파일 diff 본문을 그리는 AppKit 표 (NSTableView). 행(`DiffRow`)은 FileDiff.swift 가 만들고, 여기서는 줄 나눔 · 높이를 재고 그린다.
//
// 왜 AppKit 인가 (2026-09-13 실측, Debug 빌드 · 6,000줄 파일 3,000줄 변경 · 좁은 패널 줄바꿈 · `-preview.scrollProbe 60`):
// SwiftUI `LazyVStack` 에 diff 한 줄 = 한 행(9,002행)을 넣으면 빠른 연속 스크롤(160pt × 60Hz) 60초 동안 150ms 넘는 끊김이
// 100번(최대 0.63초) 났다. 행 크기 재기를 Text 하나로 줄여도 90번(최대 0.54초) — 메인 스레드의 약 40% 가 지연 스택이 새 행의
// 뷰 그래프를 만들고 놓는 데 쓰였다(sample). 이 표로 바꾼 뒤 (좁은 패널 · 크게 보기 통합 · 나란히 각 3회, 모두 9회):
// 60초 왕복 스크롤은 9회 모두 150ms 넘는 끊김 0 · 멈춤 0 (가장 긴 응답 지연 105ms, 50ms 넘은 표본은 9회 합쳐 4번).
// 10초 무작위 위치 이동은 9회 중 1회에 151ms 한 번 (나머지 0). 크게 보기로 바뀌는 순간에 150–165ms 한 번씩(크게 보기 6회 중 4회) —
// 가운데 칸 전환 몫이라 21줄짜리 파일에서도 같다. 열기부터 첫 행까지 0.48–0.64초.
// NSTableView 는 보이는 행의 뷰만 재사용하고, 높이는 여기서 미리 잰 값(배열)을 쓴다.
//
// - 줄 나눔 · 높이: **백그라운드**에서 잰다. 고정폭 ASCII 줄은 코드용 규칙(`DiffWrap` — 공백 뒤에서 끊는다), 그 밖의 줄은
//   CoreText(`CTTypesetterSuggestLineBreak`). 그릴 때도 같은 끊는 자리를 쓴다 (잰 높이와 그린 줄 수가 어긋나지 않는다).
//   폭이 바뀌면 다시 잰다 (그동안은 앞 높이).
// - 줄 높이는 한 줄 = `DiffMetrics.lineHeight` 로 고정이다 (좁은 19pt · 크게 보기 20pt).
// - 색은 Theme 의 동적 색을 그대로 쓴다 (그릴 때 보기 방식에 맞춰 풀린다 — 다크 모드).
// - 표는 첫 응답자가 되지 않는다 — 키는 diff 의 키 받는 뷰(`DiffKeyCatcher`)가 받는다. 누르면 그 뷰에 포커스를 준다.

/// diff 본문 표 (SwiftUI 에 붙이는 껍데기).
struct DiffTableView: NSViewRepresentable {
    let box: DiffRowsBox
    let metrics: DiffMetrics
    let split: Bool
    /// 펼칠 구간 (표가 지금 그리는 행을 만든 문서의 구간).
    let onExpand: (DiffGap) -> Void
    let onInteract: () -> Void
    /// 세로 스크롤 막대가 차지하는 폭 (막대가 늘 보이는 설정일 때 > 0).
    var onScrollerInset: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> DiffTableCoordinator { DiffTableCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = DiffNSTableView()
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.focusRingType = .none
        table.usesAutomaticRowHeights = false
        table.rowSizeStyle = .custom
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(Theme.codeBackground)
        scroll.borderType = .noBorder
        context.coordinator.attach(scroll: scroll, table: table)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onExpand = onExpand
        coordinator.onInteract = onInteract
        coordinator.onScrollerInset = onScrollerInset
        coordinator.update(box: box, metrics: metrics, split: split)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: DiffTableCoordinator) {
        coordinator.detach()
    }
}

/// 표 자료 · 줄 나눔 · 폭 변화.
@MainActor
final class DiffTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onExpand: (DiffGap) -> Void = { _ in }
    var onInteract: () -> Void = {}
    var onScrollerInset: (CGFloat) -> Void = { _ in }

    private weak var scroll: NSScrollView?
    private weak var table: DiffNSTableView?
    private var box: DiffRowsBox?
    private var metrics = DiffMetrics.narrow(maxLineNumber: 0)
    private var split = false
    private var fonts = DiffFonts(metrics: .narrow(maxLineNumber: 0))
    /// 표에 올린 행과 그 줄 나눔 (같은 순서). `rowsGaps` 는 그 행을 만든 문서의 구간 (펼치기 행의 번호가 가리키는 것).
    private var rows: [DiffRow] = []
    private var rowsGaps: [DiffGap] = []
    private var reportedScrollerInset: CGFloat = -1
    private var layouts: [DiffRowLayout] = []
    private var layoutWidth: CGFloat = 0
    private var generation = 0
    private var observer: NSObjectProtocol?
    private var pendingWidthRelayout: DispatchWorkItem?

    func attach(scroll: NSScrollView, table: DiffNSTableView) {
        self.scroll = scroll
        self.table = table
        table.dataSource = self
        table.delegate = self
        table.onClick = { [weak self] row in self?.clicked(row) }
        scroll.contentView.postsFrameChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                          object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.widthMayHaveChanged() }
        }
    }

    func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        generation += 1
    }

    func update(box: DiffRowsBox, metrics: DiffMetrics, split: Bool) {
        guard box !== self.box || metrics != self.metrics || split != self.split else { return }
        self.box = box
        if metrics != self.metrics { fonts = DiffFonts(metrics: metrics) }
        self.metrics = metrics
        self.split = split
        relayout()
    }

    private var contentWidth: CGFloat { scroll?.contentSize.width ?? 0 }

    /// 폭이 바뀌면 줄 나눔을 다시 잰다. 창을 끄는 동안 여러 번 오면 마지막 것만 (0.1초).
    private func widthMayHaveChanged() {
        reportScrollerInset()
        let width = contentWidth
        guard width > 20, abs(width - layoutWidth) > 0.5 else { return }
        if layoutWidth == 0 {
            relayout()
            return
        }
        pendingWidthRelayout?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.relayout() } }
        pendingWidthRelayout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// 행 · 폭이 바뀌었을 때 줄 나눔 · 높이를 백그라운드에서 잰 뒤 표에 올린다. 늦게 끝난 옛 계산은 버린다.
    private func relayout() {
        guard let box else { return }
        let width = contentWidth
        guard width > 20 else { return }   // 아직 자리를 받지 않았다 — 폭이 생기면 다시 온다.
        generation += 1
        let generation = self.generation
        let rows = box.rows
        let gaps = box.gaps
        let metrics = self.metrics
        let split = self.split
        let fonts = self.fonts
        Task.detached(priority: .userInitiated) {
            let layouts = DiffTextLayout.layouts(rows: rows, width: width, metrics: metrics, split: split, fonts: fonts)
            await MainActor.run { [weak self] in
                self?.apply(generation: generation, rows: rows, gaps: gaps, layouts: layouts, width: width)
            }
        }
    }

    private func apply(generation: Int, rows: [DiffRow], gaps: [DiffGap], layouts: [DiffRowLayout], width: CGFloat) {
        guard generation == self.generation, let table else { return }
        let firstLoad = self.rows.isEmpty
        self.rows = rows
        rowsGaps = gaps
        self.layouts = layouts
        layoutWidth = width
        table.reloadData()
        if firstLoad, let scroll {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        reportScrollerInset()
        #if DEBUG
        if !rows.isEmpty, let scroll {
            DispatchQueue.main.async { DiffScrollProbe.shared.attach(scrollView: scroll) }
        }
        #endif
    }

    private func clicked(_ row: Int) {
        onInteract()
        guard row >= 0, row < rows.count, case .fold(let gap, _, true) = rows[row].content, gap < rowsGaps.count else { return }
        onExpand(rowsGaps[gap])
    }

    /// 세로 스크롤 막대 폭을 알린다 (늘 보이는 막대는 본문 폭을 줄인다 — 크게 보기의 열 머리를 맞춘다). 바뀔 때만, 다음 박자에.
    private func reportScrollerInset() {
        guard let scroll else { return }
        let inset = max(0, scroll.frame.width - scroll.contentSize.width)
        guard abs(inset - reportedScrollerInset) > 0.5 else { return }
        reportedScrollerInset = inset
        let callback = onScrollerInset
        DispatchQueue.main.async { callback(inset) }
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        row < layouts.count ? max(1, layouts[row].height) : metrics.lineHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = (tableView.makeView(withIdentifier: DiffRowCanvas.identifier, owner: nil) as? DiffRowCanvas)
            ?? DiffRowCanvas()
        view.identifier = DiffRowCanvas.identifier
        if row < rows.count, row < layouts.count {
            view.configure(row: rows[row], layout: layouts[row], metrics: metrics, fonts: fonts)
        }
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// 첫 응답자가 되지 않는 표 (키는 diff 의 키 받는 뷰가 받는다). 누르면 그 행 번호만 알린다 (선택은 없다).
final class DiffNSTableView: NSTableView {
    var onClick: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onClick?(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

// MARK: - 글꼴 · 줄 나눔

/// 그리기 · 재기에 쓰는 글꼴 (한 번 만들어 백그라운드 계산에도 넘긴다 — NSFont 는 바뀌지 않는 값이다).
struct DiffFonts: @unchecked Sendable {
    let code: NSFont
    let codeBold: NSFont
    let number: NSFont
    let ui: NSFont
    let uiSemibold: NSFont
    let marker: NSFont
    let hunk: NSFont
    /// 본문 글꼴 한 줄의 높이 (올림 + 내림 + 줄 간격).
    let codeBox: CGFloat
    /// 고정폭 본문 글꼴의 글자 폭 (ASCII 줄을 칸 수로 나눌 때).
    let advance: CGFloat
    /// 안내 글(끝 행) 한 줄의 높이.
    let uiLine: CGFloat

    init(metrics: DiffMetrics) {
        code = .monospacedSystemFont(ofSize: metrics.codeSize, weight: .regular)
        advance = ("0" as NSString).size(withAttributes: [.font: code]).width
        codeBold = .monospacedSystemFont(ofSize: metrics.codeSize, weight: .semibold)
        number = .monospacedSystemFont(ofSize: metrics.numberSize, weight: .regular)
        ui = .systemFont(ofSize: TypeScale.caption.size)
        uiSemibold = .systemFont(ofSize: TypeScale.caption.size, weight: .semibold)
        let italic = NSFontManager.shared.convert(.systemFont(ofSize: TypeScale.caption.size), toHaveTrait: .italicFontMask)
        marker = italic
        hunk = .monospacedSystemFont(ofSize: TypeScale.caption.size, weight: .regular)
        codeBox = ceil(code.ascender - code.descender + code.leading)
        uiLine = ceil(ui.ascender - ui.descender + ui.leading) + 2
    }
}

/// 칸 하나의 줄 나눔 (UTF-16 범위) · 강조 범위 (UTF-16).
struct DiffCellLayout: Sendable {
    var lines: [NSRange]
    var highlights: [NSRange]
}

/// 행 하나의 높이와 칸들의 줄 나눔.
struct DiffRowLayout: Sendable {
    var height: CGFloat
    var left: DiffCellLayout?
    var right: DiffCellLayout?
    /// 끝 행 문구의 줄 나눔.
    var text: [NSRange]?
}

enum DiffTextLayout {
    static let headerHeight: CGFloat = 24
    static let trailingPadding: CGFloat = 10

    /// 통합 보기 본문 칸의 폭 (거터 두 칸 · 부호를 뺀다).
    static func unifiedTextWidth(_ width: CGFloat, _ m: DiffMetrics) -> CGFloat {
        max(40, width - (m.gutter * 2 + m.signWidth) - trailingPadding)
    }

    /// 나란히 보기 한쪽 칸의 폭과 본문 폭.
    static func splitHalf(_ width: CGFloat) -> CGFloat { max(0, (width - 1) / 2) }
    static func splitTextWidth(_ width: CGFloat, _ m: DiffMetrics) -> CGFloat {
        max(40, splitHalf(width) - (m.gutter + m.signWidth) - trailingPadding)
    }

    static func layouts(rows: [DiffRow], width: CGFloat, metrics: DiffMetrics, split: Bool,
                        fonts: DiffFonts) -> [DiffRowLayout] {
        let unified = unifiedTextWidth(width, metrics)
        let half = splitTextWidth(width, metrics)
        return rows.map { row -> DiffRowLayout in
            switch row.content {
            case .hunk, .fold:
                return DiffRowLayout(height: headerHeight)
            case .end(let text):
                let lines = lines(text, font: fonts.ui, width: max(40, width - 24))
                return DiffRowLayout(height: max(headerHeight, CGFloat(lines.count) * fonts.uiLine + 9), text: lines)
            case .unified(let cell):
                let layout = cellLayout(cell, width: unified, fonts: fonts)
                return DiffRowLayout(height: CGFloat(layout.lines.count) * metrics.lineHeight, left: layout)
            case .split(let left, let right):
                let l = left.map { cellLayout($0, width: half, fonts: fonts) }
                let r = right.map { cellLayout($0, width: half, fonts: fonts) }
                let count = max(l?.lines.count ?? 1, r?.lines.count ?? 1, 1)
                return DiffRowLayout(height: CGFloat(count) * metrics.lineHeight, left: l, right: r)
            }
        }
    }

    static func cellLayout(_ cell: DiffCell, width: CGFloat, fonts: DiffFonts) -> DiffCellLayout {
        if cell.kind == .marker {
            return DiffCellLayout(lines: [NSRange(location: 0, length: (cell.text as NSString).length)], highlights: [])
        }
        let font = cell.conflictMarker ? fonts.codeBold : fonts.code
        let lines: [NSRange]
        if isPlainASCII(cell.text), fonts.advance > 0 {
            // 고정폭 ASCII 는 코드용 규칙으로 (`DiffWrap` — 공백 뒤에서 끊는다). 글자 폭이 모두 같아 칸 수로 잰다.
            let columns = Int((width + 0.01) / fonts.advance)
            lines = DiffWrap.asciiLines(Array(cell.text.utf8), columns: columns)
                .map { NSRange(location: $0.lowerBound, length: $0.count) }
        } else {
            lines = self.lines(cell.text, font: font, width: width)
        }
        return DiffCellLayout(lines: lines, highlights: utf16Ranges(cell.highlights, in: cell.text))
    }

    /// 인쇄 가능한 ASCII 만 (고정폭 글꼴에서 글자 폭이 모두 같다).
    static func isPlainASCII(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    }

    /// CoreText 가 권하는 끊는 자리로 나눈 줄 (UTF-16). 빈 글자는 빈 줄 하나. 한 글자도 안 들어가면 한 글자씩.
    static func lines(_ text: String, font: NSFont, width: CGFloat) -> [NSRange] {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let length = attributed.length
        guard length > 0 else { return [NSRange(location: 0, length: 0)] }
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var ranges: [NSRange] = []
        var start = 0
        while start < length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width)))
            ranges.append(NSRange(location: start, length: min(count, length - start)))
            start += count
        }
        return ranges
    }

    /// `Character` 오프셋 범위 → UTF-16 범위 (한글 · 이모지 · 결합 문자).
    static func utf16Ranges(_ ranges: [Range<Int>], in text: String) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        if text.utf8.count == text.utf16.count {
            // ASCII 만 있으면 글자 = UTF-16 칸.
            return ranges.map { NSRange(location: $0.lowerBound, length: $0.count) }
        }
        var offsets: [Int] = [0]
        var utf16 = 0
        for c in text {
            utf16 += c.utf16.count
            offsets.append(utf16)
        }
        return ranges.compactMap { r in
            guard r.lowerBound >= 0, r.upperBound < offsets.count else { return nil }
            return NSRange(location: offsets[r.lowerBound], length: offsets[r.upperBound] - offsets[r.lowerBound])
        }
    }
}

// MARK: - 행 그리기

/// 행 하나를 직접 그린다 (거터 · 부호 · 본문 · 강조 · hunk 머리 · 펼치기 · 끝 행). 뒤집힌 좌표 (위가 0).
final class DiffRowCanvas: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("diff.row")

    private var row: DiffRow?
    private var layout = DiffRowLayout(height: 0)
    private var metrics = DiffMetrics.narrow(maxLineNumber: 0)
    private var fonts = DiffFonts(metrics: .narrow(maxLineNumber: 0))

    override var isFlipped: Bool { true }

    func configure(row: DiffRow, layout: DiffRowLayout, metrics: DiffMetrics, fonts: DiffFonts) {
        self.row = row
        self.layout = layout
        self.metrics = metrics
        self.fonts = fonts
        toolTip = tooltip(row)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(accessibilityText(row))
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        if case .fold(_, _, true)? = row?.content {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        switch row.content {
        case .hunk(let label, let inclusion):
            drawHunk(label, inclusion)
        case .unified(let cell):
            drawCell(cell, layout: layout.left, in: NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height),
                     gutters: 2, old: cell.oldNumber, new: cell.newNumber)
        case .split(let left, let right):
            let half = DiffTextLayout.splitHalf(bounds.width)
            let leftRect = NSRect(x: 0, y: 0, width: half, height: bounds.height)
            let rightRect = NSRect(x: half + 1, y: 0, width: bounds.width - half - 1, height: bounds.height)
            if let left {
                drawCell(left, layout: layout.left, in: leftRect, gutters: 1, old: left.oldNumber, new: nil)
            } else {
                drawHatch(leftRect)
            }
            Palette.codeBorder.setFill()
            NSRect(x: half, y: 0, width: 1, height: bounds.height).fill()
            if let right {
                drawCell(right, layout: layout.right, in: rightRect, gutters: 1, old: nil, new: right.newNumber)
            } else {
                drawHatch(rightRect)
            }
        case .fold(_, let label, let expandable):
            drawBand()
            drawCentered(label, font: fonts.ui, color: expandable ? Palette.slate : Palette.slate2, chevron: expandable)
        case .end(let text):
            drawBand()
            drawEnd(text)
        }
    }

    // MARK: 부품

    /// hunk 머리 · 펼치기 · 끝 행의 띠 (code-head 바탕 + 위아래 규칙선).
    private func drawBand() {
        Palette.codeHeader.setFill()
        bounds.fill()
        Palette.codeBorder.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    private func drawHunk(_ label: String, _ inclusion: HunkInclusion?) {
        drawBand()
        var right: CGFloat = bounds.width - 10
        if let inclusion {
            let (text, color, font): (String, NSColor, NSFont) = {
                switch inclusion {
                case .on: return ("✓ 커밋에 포함", Palette.emeraldText, fonts.uiSemibold)
                case .partial: return ("◐ 일부만 포함", Palette.amberText, fonts.uiSemibold)
                case .off: return ("✕ 이번 커밋에서 제외", Palette.slate, fonts.ui)
                }
            }()
            let attributed = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            if inclusion == .off {
                // 목업 `split_hunk`: ✕ 표시는 slate2, 글자는 slate.
                attributed.addAttribute(.foregroundColor, value: Palette.slate2, range: NSRange(location: 0, length: 1))
            }
            let size = attributed.size()
            attributed.draw(at: NSPoint(x: right - size.width, y: (bounds.height - size.height) / 2))
            right -= size.width + 12
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributed = NSAttributedString(string: label, attributes: [.font: fonts.hunk, .foregroundColor: Palette.slate,
                                                                        .paragraphStyle: style])
        let height = attributed.size().height
        attributed.draw(in: NSRect(x: 10, y: (bounds.height - height) / 2, width: max(0, right - 10), height: height))
    }

    private func drawCentered(_ text: String, font: NSFont, color: NSColor, chevron: Bool) {
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = attributed.size()
        let chevronWidth: CGFloat = chevron ? 14 : 0
        let x = (bounds.width - size.width - chevronWidth) / 2
        let y = (bounds.height - size.height) / 2
        if chevron {
            let path = NSBezierPath()
            let cx = x + 4, cy = bounds.height / 2
            path.move(to: NSPoint(x: cx - 3.5, y: cy - 1.8))
            path.line(to: NSPoint(x: cx, y: cy + 1.8))
            path.line(to: NSPoint(x: cx + 3.5, y: cy - 1.8))
            path.lineWidth = 1.3
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            Palette.slate2.setStroke()
            path.stroke()
        }
        attributed.draw(at: NSPoint(x: x + chevronWidth, y: y))
    }

    private func drawEnd(_ text: String) {
        let ns = text as NSString
        let lines = layout.text ?? [NSRange(location: 0, length: ns.length)]
        let attributes: [NSAttributedString.Key: Any] = [.font: fonts.ui, .foregroundColor: Palette.slate]
        let lineHeight = fonts.uiLine
        let total = CGFloat(lines.count) * lineHeight
        var y = (bounds.height - total) / 2
        for range in lines {
            let piece = NSAttributedString(string: ns.substring(with: range).trimmingCharacters(in: .whitespaces),
                                           attributes: attributes)
            let size = piece.size()
            piece.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: y + (lineHeight - size.height) / 2))
            y += lineHeight
        }
    }

    /// 한 칸: 줄 바탕 · 거터 바탕 · 번호 · 부호 · 본문(줄마다) · 줄 안 강조.
    private func drawCell(_ cell: DiffCell, layout: DiffCellLayout?, in rect: NSRect, gutters: Int, old: Int?, new: Int?) {
        let m = metrics
        let gutterWidth = m.gutter * CGFloat(gutters)
        switch cell.kind {
        case .added:
            Palette.addBackground.setFill()
            rect.fill()
            Palette.addGutter.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: gutterWidth, height: rect.height).fill()
        case .removed:
            Palette.deleteBackground.setFill()
            rect.fill()
            Palette.deleteGutter.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: gutterWidth, height: rect.height).fill()
        case .context, .marker:
            break
        }
        // 첫 줄의 기준선에 번호 · 부호를 맞춘다. 글자는 CoreText 로 그린다 (한 페이지를 한꺼번에 그릴 때 TextKit 보다 싸다).
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // 뒤집힌 좌표에서 글자를 바로 세운다.
        let top = (m.lineHeight - fonts.code.ascender + fonts.code.descender) / 2
        let baseline = rect.minY + top + fonts.code.ascender
        if !cell.continuation {
            let numbers = gutters == 2 ? [old, new] : [old ?? new]
            for (index, number) in numbers.enumerated() {
                guard let number else { continue }
                let line = Self.line(String(number), font: fonts.number, color: Palette.slate2)
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                draw(line, x: rect.minX + m.gutter * CGFloat(index + 1) - m.gutterPadding - width, baseline: baseline,
                     in: context)
            }
            let sign: String? = cell.kind == .added ? "+" : (cell.kind == .removed ? "−" : nil)
            if let sign {
                let color = cell.conflictMarker ? Palette.amberText : (cell.kind == .added ? Palette.emeraldText : Palette.danger)
                let line = Self.line(sign, font: fonts.code, color: color)
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                draw(line, x: rect.minX + gutterWidth + (m.signWidth - width) / 2, baseline: baseline, in: context)
            }
        }
        let x = rect.minX + gutterWidth + m.signWidth
        if cell.kind == .marker {
            draw(Self.line(cell.text, font: fonts.marker, color: Palette.slate2), x: x, baseline: baseline, in: context)
            return
        }
        guard let layout else { return }
        let ns = cell.text as NSString
        let font = cell.conflictMarker ? fonts.codeBold : fonts.code
        let color = cell.conflictMarker ? Palette.amberText : Palette.ink2
        let ascii = DiffTextLayout.isPlainASCII(cell.text)
        let word = cell.kind == .added ? Palette.addWord : Palette.deleteWord
        for (index, range) in layout.lines.enumerated() {
            let lineTop = rect.minY + CGFloat(index) * m.lineHeight
            let line = Self.line(ns.substring(with: range), font: font, color: color)
            for highlight in layout.highlights {
                let overlap = NSIntersectionRange(highlight, range)
                guard overlap.length > 0 else { continue }
                // 고정폭 ASCII 는 칸 수로, 그 밖은 CoreText 가 준 글자 위치로.
                func offset(_ index: Int) -> CGFloat {
                    let local = index - range.location
                    return ascii ? CGFloat(local) * fonts.advance
                        : CGFloat(CTLineGetOffsetForStringIndex(line, local, nil))
                }
                let start = offset(overlap.location)
                let end = offset(NSMaxRange(overlap))
                word.setFill()
                NSBezierPath(roundedRect: NSRect(x: x + start, y: lineTop + top - 1, width: end - start,
                                                 height: fonts.codeBox + 2), xRadius: 2, yRadius: 2).fill()
            }
            draw(line, x: x, baseline: baseline + CGFloat(index) * m.lineHeight, in: context)
        }
    }

    /// 한 줄짜리 CoreText 줄 (색은 그릴 때의 보기 방식으로 풀린 값).
    private static func line(_ text: String, font: NSFont, color: NSColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private func draw(_ line: CTLine, x: CGFloat, baseline: CGFloat, in context: CGContext) {
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, context)
    }

    /// 나란히 보기의 빈 칸 빗금 (목업 `repeating-linear-gradient(135deg, #F8FAFC 0 6px, #F3F6F9 6px 7px)`).
    private func drawHatch(_ rect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor(patternImage: dark ? Palette.darkHatch : Palette.lightHatch).setFill()
        rect.fill()
    }

    private func tooltip(_ row: DiffRow) -> String? {
        switch row.content {
        case .hunk(_, let inclusion?):
            return inclusion == .off ? "이번 커밋에서 제외 — " + DiffInclusion.approximationHelp
                : (inclusion == .on ? "커밋에 포함 — " : "일부만 포함 — ") + DiffInclusion.approximationHelp
        case .fold(_, _, let expandable):
            return expandable ? "마지막 커밋의 파일에서 이 구간을 읽어 끼웁니다 (변경 없는 줄)"
                : "마지막 커밋의 파일을 읽지 못해(너무 크거나 조회 실패) 펼칠 수 없습니다"
        case .unified(let cell) where cell.conflictMarker:
            return "충돌 표시 — 정리한 뒤 터미널에서 git add 로 해결됨을 표시하세요"
        case .unified(let cell) where cell.kind == .marker:
            return "git: \\ No newline at end of file"
        default:
            return nil
        }
    }

    private func accessibilityText(_ row: DiffRow) -> String {
        func describe(_ cell: DiffCell?) -> String {
            guard let cell else { return "빈 칸" }
            let kind: String
            switch cell.kind {
            case .added: kind = "더한 줄"
            case .removed: kind = "지운 줄"
            case .context: kind = "변경 없는 줄"
            case .marker: kind = "표식"
            }
            let number = (cell.newNumber ?? cell.oldNumber).map { " \($0)" } ?? ""
            return "\(kind)\(number): \(cell.text)"
        }
        switch row.content {
        case .hunk(let label, _): return label
        case .unified(let cell): return describe(cell)
        case .split(let left, let right): return "마지막 커밋 " + describe(left) + " · 지금 파일 " + describe(right)
        case .fold(_, let label, _): return label
        case .end(let text): return text
        }
    }
}

/// Theme 의 동적 색을 AppKit 색으로 (같은 동적 색 — 그릴 때 보기 방식에 맞춰 풀린다).
private enum Palette {
    static let ink2 = NSColor(Theme.ink2)
    static let slate = NSColor(Theme.slate)
    static let slate2 = NSColor(Theme.slate2)
    /// 성공 글자 ("✓ 커밋에 포함" · 더한 줄의 +) — `emerald` 는 작은 글자로 흐렸다 (copy-4).
    static let emeraldText = NSColor(Theme.emeraldText)
    static let amberText = NSColor(Theme.amberText)
    static let danger = NSColor(Theme.danger)
    static let codeHeader = NSColor(Theme.codeHeader)
    static let codeBorder = NSColor(Theme.codeBorder)
    static let addBackground = NSColor(Theme.addBackground)
    static let addWord = NSColor(Theme.addWord)
    static let addGutter = NSColor(Theme.addGutter)
    static let deleteBackground = NSColor(Theme.deleteBackground)
    static let deleteWord = NSColor(Theme.deleteWord)
    static let deleteGutter = NSColor(Theme.deleteGutter)
    static let lightHatch = hatchTile(base: Theme.hatchBaseHex.light, line: Theme.hatchLineHex.light)
    static let darkHatch = hatchTile(base: Theme.hatchBaseHex.dark, line: Theme.hatchLineHex.dark)

    /// 목업 `repeating-linear-gradient(135deg, …6px, …6px 7px)`: 선은 왼쪽 아래 → 오른쪽 위("/"), 기울기 방향으로 7pt 마다 1pt.
    /// 대각선 타일이라 한 변 = 7·√2 ≈ 10pt. 무늬 이미지는 뒤집히지 않은(위가 +y) 좌표로 그려진다.
    private static func hatchTile(base: UInt32, line: UInt32) -> NSImage {
        let size: CGFloat = 10
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor(hex: base).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: -1, y: -1))
        path.line(to: NSPoint(x: size + 1, y: size + 1))
        NSColor(hex: line).setStroke()
        path.stroke()
        image.unlockFocus()
        return image
    }
}
