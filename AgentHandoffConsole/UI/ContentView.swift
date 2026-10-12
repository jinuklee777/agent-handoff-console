import SwiftUI

// `InspectorTab` · `WindowStateKey` · `MenuShortcut` 는 App/WindowState.swift (검증 하네스에서도 컴파일된다).
// 인스펙터 탭의 ⌘⌥ + 숫자도 `MenuShortcut.inspectorTab` 으로 건다.
extension MenuShortcut {
    var eventModifiers: EventModifiers {
        var out: EventModifiers = []
        if modifiers.contains(.command) { out.insert(.command) }
        if modifiers.contains(.shift) { out.insert(.shift) }
        if modifiers.contains(.option) { out.insert(.option) }
        if modifiers.contains(.control) { out.insert(.control) }
        return out
    }
}

extension View {
    /// 메뉴 명령에 `MenuShortcut` 표의 단축키를 건다.
    func menuShortcut(_ shortcut: MenuShortcut) -> some View {
        keyboardShortcut(KeyEquivalent(shortcut.key), modifiers: shortcut.eventModifiers)
    }
}

// MARK: 사이드바 칸

/// 사이드바와 본문 사이의 1pt 선. 창 위 끝(신호등 줄)부터 아래 끝까지 이어지고, 끌면 사이드바 너비를 바꾼다 (`bounds` 안에서),
/// 두 번 누르면 기본 너비로. 사이드바는 NavigationSplitView 가 아니라 `ContentView` 가 직접 그린 칸이다 — macOS 26 의
/// NavigationSplitView 사이드바는 창 안에 떠 있는 유리 카드로 그려져 본문과 따로 노는 것처럼 보였다 (2026-09-28).
private struct SidebarDivider: View {
    /// 저장된 너비 (`WindowStateKey.sidebarWidth`).
    @Binding var width: Double
    /// 지금 그려진 너비 (저장값을 창에 맞춰 줄인 값). 끌기는 여기서 시작한다.
    let current: CGFloat
    let bounds: ClosedRange<CGFloat>
    let defaultWidth: Double
    @State private var dragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Theme.hair)
            .frame(width: PanelFit.Metrics.app.divider)
            .frame(maxHeight: .infinity)
            .ignoresSafeArea(edges: .top)
            .overlay {
                // 1pt 는 잡기 어렵다 — 양옆으로 넓힌 투명한 손잡이.
                Color.clear
                    .frame(width: 9)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? current
                                if dragStart == nil { dragStart = current }
                                let next = min(max(start + value.translation.width, bounds.lowerBound), bounds.upperBound)
                                width = Double(next.rounded())
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                    .onTapGesture(count: 2) { width = defaultWidth }
                    .help("끌어서 사이드바 너비 바꾸기 · 두 번 누르면 기본 너비")
            }
            .zIndex(1)
            .accessibilityHidden(true)
    }
}

/// 이 뷰가 놓인 자리의 창 x 를 알린다 — 툴바 항목(대화 제목)이 신호등 · 사이드바 버튼 뒤 어디에 놓였는지 재서
/// 제목을 본문 칸 위로 밀 때 쓴다 (`PanelFit.toolbarTitleLead`). 전체 화면에서 신호등이 사라지면 항목이 옮겨 가므로 창 알림으로도 잰다.
private struct WindowXProbe: NSViewRepresentable {
    @Binding var x: CGFloat?

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { [binding = $x] value in if binding.wrappedValue != value { binding.wrappedValue = value } }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var lastReported: CGFloat?
        private var observers: [NSObjectProtocol] = []

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window {
                for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                             NSWindow.didExitFullScreenNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                        MainActor.assumeIsolated { self?.report() }
                    })
                }
            }
            report()
        }

        override func layout() { super.layout(); report() }

        /// 배치 도중에는 SwiftUI 상태를 바꿀 수 없으므로 다음 런루프 차례에 알린다.
        private func report() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                let x = self.convert(NSPoint.zero, to: nil).x.rounded()
                guard x != self.lastReported else { return }
                self.lastReported = x
                self.onChange?(x)
            }
        }
    }
}

/// 창의 실제 내용 폭을 SwiftUI 에 알린다 (`fitPanels` · `sidebarMaxWidth` 용).
///
/// 뷰의 geometry 로 재면 안 된다: 칸들이 창보다 넓게 요구될 때 SwiftUI 루트 뷰는 창이 아니라 그 요구만큼 커진다
/// (2026-09-14 실측: 창 1000 · 뷰 1296). 그 값으로 접힘을 판정하면 접자마자 "공간이 있다"고 다시 펴서 세 칸이
/// 창 양 끝으로 잘린 채 남는다. 창 크기 변화는 `NSWindow.didResizeNotification` 으로 따라간다 (드래그 중에도 온다).
private struct WindowWidthProbe: NSViewRepresentable {
    @Binding var width: CGFloat

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { [binding = $width] value in if binding.wrappedValue != value { binding.wrappedValue = value } }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ProbeView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class ProbeView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var observer: NSObjectProtocol?
        private var lastReported: CGFloat?

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        deinit { observer.map(NotificationCenter.default.removeObserver) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            report()
        }

        /// 배치 도중에는 SwiftUI 상태를 바꿀 수 없으므로 다음 런루프 차례에 알린다.
        private func report() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                let width = window.contentLayoutRect.width
                guard width > 0, width != self.lastReported else { return }
                self.lastReported = width
                self.onChange?(width)
            }
        }
    }
}

extension Notification.Name {
    static let handoffConsoleFocusFileSearch = Notification.Name("handoffConsoleFocusFileSearch")
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// 사이드바 너비 (끌어서 정한 값, 창을 다시 열어도 남는다). 보일 때는 `sidebarShownWidth` 로 창에 맞춘다.
    @AppStorage(WindowStateKey.sidebarWidth) private var sidebarWidth: Double = Double(Theme.Metric.sidebar)
    /// 툴바의 대화 제목 항목이 놓인 창 x (`WindowXProbe`). 제목을 본문 칸 위로 미는 데 쓴다.
    @State private var titleItemX: CGFloat?
    @AppStorage(WindowStateKey.pane) private var pane: Pane = .conversation
    @AppStorage(WindowStateKey.inspectorVisible) private var showInspector = WindowStateKey.inspectorVisibleByDefault
    @AppStorage(WindowStateKey.inspectorTab) private var inspectorTab: InspectorTab = .files
    @State private var windowWidth: CGFloat = 0
    /// 창이 좁아 세 칸이 다 들어가지 않을 때, 사용자가 마지막으로 연 쪽을 남기고 다른 쪽을 접는다.
    @State private var lastOpenedPanel: Panel = .inspector
    /// 앱이 자동으로 접은 패널. 공간이 돌아오면 다시 연다 (사용자가 직접 닫은 패널은 다시 열지 않는다).
    @State private var autoHidden: Panel?
    @State private var applyingFit = false
    /// 창이 좁아 패널을 접었다는 안내를 한 번 보였는가 (처음 한 번만 — 그 뒤는 툴바 단추의 도움말이 말한다).
    @AppStorage("window.autoHideNoticeShown") private var autoHideNoticeShown = false

    /// 접힘 판정은 `PanelFit` (App/WindowState.swift, 오프라인 검증).
    typealias Panel = PanelFit.Panel

    /// 칸 최소 너비 (`PanelFit.Metrics.app` 과 같은 값). 창이 좁아지면 본문이 최소까지 줄어든 뒤 사이드바가 최소까지 줄고,
    /// 그 다음 칸들이 잘린다 — 그 전에 `fitPanels` 가 한쪽 패널을 접는다.
    static let sidebarMinWidth: CGFloat = PanelFit.Metrics.app.sidebar
    /// 사이드바 고정 상한.
    static let sidebarMaxWidth: CGFloat = 360

    /// 사이드바 실제 상한: 고정 상한과 이 창에서 줄 수 있는 너비(`PanelFit.sidebarLimit` — 인스펙터는 최소 너비로) 중 작은 쪽.
    private var sidebarMaxWidth: CGFloat {
        guard windowWidth > 0 else { return Self.sidebarMaxWidth }
        let limit = PanelFit.sidebarLimit(windowWidth: windowWidth, inspector: showInspector)
        return min(Self.sidebarMaxWidth, max(Self.sidebarMinWidth, limit))
    }

    /// 지금 그리는 사이드바 너비 — 저장값을 창에 맞춰 줄인 것 (창을 넓히면 저장값으로 돌아간다).
    private var sidebarShownWidth: CGFloat {
        min(max(CGFloat(sidebarWidth), Self.sidebarMinWidth), sidebarMaxWidth)
    }

    /// 사이드바 칸 (사이드바 + 구분선). 접혀 있으면 0.
    private var sidebarColumnWidth: CGFloat {
        model.sidebarVisible ? sidebarShownWidth + PanelFit.Metrics.app.divider : 0
    }

    /// 인스펙터를 열었을 때 한도 칩이 쓸 수 있는 폭 — 인스펙터가 가장 좁을 때(`inspectorMinWidth`)에서 ⋯ · 인스펙터 토글 ·
    /// 창 끝 여백 · 경계선과의 틈(`inspectorToolbarReserve`)과 "응답 필요" 칩 몫을 뺀 것. 인스펙터를 닫았으면 nil (본문 위 툴바는 넓다).
    /// 실제 인스펙터 너비를 재어 쓰지 않는다 — 인스펙터 안에서 잰 너비를 이 뷰의 상태로 받으면 인스펙터가 최소 폭보다 좁아질 때까지
    /// 줄어들었다 (2026-10-09 미리보기, 420 → 약 270). 사람이 인스펙터를 넓혀도 칩은 좁은 단계 그대로다.
    private var limitsChipBudget: CGFloat? {
        guard showInspector else { return nil }
        let response: CGFloat = model.responseNeeded.isEmpty ? 0 : Self.responseChipReserve
        return Self.inspectorMinWidth - Self.inspectorToolbarReserve - response
    }

    /// 인스펙터 위 툴바 칸에서 한도 칩 말고 쓰는 폭 (⋯ · 인스펙터 토글 · 사이 간격 · 창 끝 여백 약 100 + 경계선과의 틈 12).
    /// 2026-10-09 미리보기에서 잼 — 인스펙터 420 · 칩 셋(Claude · Codex 계정 둘)에서 칩의 끝이 창 끝에서 100pt.
    static let inspectorToolbarReserve: CGFloat = 112
    /// "응답 필요 · 인계 검토" 칩 + 간격의 대략 (짧은 글이면 남는다).
    static let responseChipReserve: CGFloat = 140

    static let detailMinWidth: CGFloat = PanelFit.Metrics.app.detail
    static let inspectorMinWidth: CGFloat = PanelFit.Metrics.app.inspector
    /// 인스펙터 고정 상한.
    static let inspectorMaxWidth: CGFloat = 560

    /// 인스펙터 실제 상한: 고정 상한과 이 창 · 사이드바 칸에서 줄 수 있는 너비(`PanelFit.inspectorLimit`) 중 작은 쪽.
    /// 인스펙터 스플릿의 왼쪽 칸 최소(사이드바 칸 + 본문 최소) + 인스펙터가 창을 넘으면 AppKit 이 제약을 깨고 다시 배치하며
    /// 제약 갱신이 꼬리를 물어 macOS 26 이 앱을 끝낸다 (2026-09-14 크래시). 사이드바 상한은 인스펙터 **최소**로 계산하므로
    /// 사이드바의 실제 너비를 여기서 넣어도 서로 되먹이지 않는다.
    private var inspectorMaxWidth: CGFloat {
        guard windowWidth > 0 else { return Self.inspectorMaxWidth }
        let limit = PanelFit.inspectorLimit(windowWidth: windowWidth, sidebarColumnWidth: sidebarColumnWidth,
                                            sidebarVisible: model.sidebarVisible)
        return min(Self.inspectorMaxWidth, max(Self.inspectorMinWidth, limit))
    }

    /// 가운데 칸 (대화 · 에이전트 기록 · 크게 보기). 정의와 복원 규칙은 App/WindowState.swift `WindowPane` (오프라인 검증).
    /// 크게 보기(`.review`)는 분할 컨트롤에 없고 저장하지 않는다 — 앱이 이번 실행에서 연 diff 가 있을 때만 보인다.
    typealias Pane = WindowPane

    /// 지금 가운데에 보일 칸.
    private var shownPane: Pane {
        WindowPane.shown(stored: pane, reviewing: model.diffWideActive)
    }

    var body: some View {
        @Bindable var model = model
        // 창 아래 상태 막대는 없다 — 한도는 툴바의 `LimitsChip`, 브랜치 · 사용량은 툴바 부제, 실행 상태는 대화와 사이드바 점.
        // 사이드바 · 본문은 한 줄로 직접 그리고, 인스펙터만 스플릿(`.inspector`)이다. 사이드바는 NavigationSplitView 를 쓰지 않는다 —
        // macOS 26 의 NavigationSplitView 사이드바는 창 안에 떠 있는 유리 카드로 그려져 본문과 따로 노는 것처럼 보였다 (2026-09-28).
        // 사이드바 · 구분선 · 본문의 바탕은 툴바 아래(신호등 줄)까지 올라간다 — 툴바는 바탕이 없고 그 위에 제목 · 버튼만 놓인다.
        HStack(spacing: 0) {
            if model.sidebarVisible {
                SidebarView()
                    .frame(width: sidebarShownWidth)
                SidebarDivider(width: $sidebarWidth, current: sidebarShownWidth,
                               bounds: Self.sidebarMinWidth...sidebarMaxWidth, defaultWidth: Double(Theme.Metric.sidebar))
            }
            VStack(spacing: 0) {
                // 대화와 무관한 알림 · 칸에 열리지 않은 대화의 알림 — 어느 칸 · 어느 화면에서도 보이게 가운데 칸 맨 위에 (chr-4).
                // 첫 실행 점검표는 알림을 스스로 그린다.
                if !(shownPane == .conversation && model.showsFirstRun) {
                    ComposerNoticeLine(windowWide: true)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                switch shownPane {
                // 프로젝트가 없으면(읽기 성공 뒤) 가운데 칸 전체에 첫 실행 점검표. 분할 배치는 저장값을 바꾸지 않는다.
                case .conversation where model.showsFirstRun: FirstRunView(mode: .page)
                case .conversation: PaneGrid()
                case .scoreboard: ScoreboardView()
                case .overview: OverviewView()
                // 변경사항 탭의 "크게 보기" 로만 들어온다 (‹ 대화로 돌아가기 · esc · 패널로 줄이기로 나간다).
                case .review: DiffReviewView()
                }
            }
            // 도움말 > 시작 점검… (프로젝트가 있는 사람도). "기록 가져오기" 는 이 시트를 닫은 뒤 가져오기 시트를 연다 —
            // 시트 둘을 한 번에 띄우지 않는다. 가져오기 시트(아래 `.sheet`)와 다른 뷰에 붙인다.
            .sheet(isPresented: $model.showFirstRunSheet, onDismiss: {
                if model.importAfterFirstRunSheet {
                    model.importAfterFirstRunSheet = false
                    model.showImportSheet = true
                }
            }) {
                // 메인 창의 툴바 아래 높이를 넘지 않는다 — 가장 작은 창(900×560)에서 시트가 창 아래로 12pt 넘쳐 "닫기" 바닥이
                // 걸쳤다. 스크롤 칸이 줄고 아래 "다시 확인 · 닫기" 는 보인다.
                let limit = FirstRunView.sheetMaxHeight()
                FirstRunView(mode: .sheet)
                    .environment(model)
                    .frame(width: 640)
                    .frame(minHeight: min(420, limit), idealHeight: limit, maxHeight: limit)
            }
            .frame(minWidth: Self.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
            // 툴바는 바탕이 없다 — 스크롤한 대화가 제목 밑(툴바 자리)으로 올라와 비치지 않게 본문 칸 안에서 자른다.
            // 바탕(흰색)은 자르지 않아 툴바 자리까지 올라간다 (2026-09-28: 제목과 대화 글이 겹쳐 보였다).
            .clipped()
            .background(Theme.paper)
        }
        .toolbar { detailToolbar }
        // 툴바는 바탕 · 아래 선을 그리지 않는다 — 사이드바 색과 구분선이 신호등 줄까지 이어지고, 본문 위는 본문의 흰 바탕 (한 앱처럼).
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // 인스펙터 탭은 인스펙터 칸 안의 첫 줄에 있다 (`InspectorView`). 툴바에는 두지 않는다.
        .inspector(isPresented: $showInspector) {
            InspectorView(tab: $inspectorTab)
                .inspectorColumnWidth(min: Self.inspectorMinWidth, ideal: Theme.Metric.inspector, max: inspectorMaxWidth)
        }
        #if DEBUG
        .onChange(of: sidebarColumnWidth, initial: true) { _, width in SplitDividerSweep.sidebarHandleX = width - 0.5 }
        .onAppear { SplitDividerSweep.setSidebarWidth = { [sidebarStore = $sidebarWidth] in sidebarStore.wrappedValue = $0 } }
        #endif
        // 창 폭은 뷰의 geometry 가 아니라 창에서 읽는다 — 칸들이 창보다 넓게 요구되면 뷰는 그 요구만큼 커져(창 1000 · 뷰 1296)
        // 접힘 판정이 "공간이 있다"고 오판한다 (`PanelFit` 설명).
        .background(WindowWidthProbe(width: $windowWidth))
        .sheet(isPresented: $model.showImportSheet) { ImportSheet() }
        .onChange(of: windowWidth) { _, _ in fitPanels() }
        .onChange(of: model.sidebarVisible) { _, visible in
            if applyingFit { applyingFit = false; return }
            if visible {
                lastOpenedPanel = .sidebar
                if autoHidden == .sidebar { autoHidden = nil }
            } else if autoHidden == .sidebar {
                autoHidden = nil
            }
            fitPanels()
        }
        .onChange(of: showInspector) { _, visible in
            if applyingFit { applyingFit = false; return }
            if visible {
                lastOpenedPanel = .inspector
                if autoHidden == .inspector { autoHidden = nil }
            }
            fitPanels()
        }
        .toolbar(removing: .title)
        .navigationTitle(model.selectedThread?.title ?? "Agent Handoff Console")
        .task {
            // 크게 보기는 되살리지 않는다 — 저장값 · `-window.pane` 인수로 와도 대화로 (`WindowPane.restored`).
            if pane == .review { pane = WindowPane.restored(pane) }
            WindowOpener.shared.open = { id in openWindow(id: id) }
            WindowOpener.shared.registerModelReady()
            if !model.bootstrapped { await model.bootstrap() }
            // 창이 닫혀 있을 때 알림을 누르면 이동 요청이 창보다 먼저 온다. 새로 만든 창에서는
            // onChange 가 이미 들어와 있던 값에 반응하지 않으므로 나타날 때도 확인한다.
            consumePendingNotification()
            #if DEBUG
            // 화면 확인용 (AHC_OFFLINE=1 일 때만).
            // `-preview.appearance dark` 로 다크 모드, `-preview.action handoff…` 로 대화 끝에 인계 카드를 놓는다 (아래).
            if AppModel.offlinePreview {
                if let appearance = UserDefaults.standard.string(forKey: "preview.appearance") {
                    NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                }
                // `-preview.sidebarHidden YES` — 사이드바를 접은 채 시작한다 (툴바 제목 자리 · 사이드바 버튼 확인).
                if UserDefaults.standard.bool(forKey: "preview.sidebarHidden") { model.sidebarVisible = false }
                // `-preview.limits "claude=0.81@5h,fetched=now;codex=0.12"` — 한도 · CLI · 로그인 사실을 넣는다 (이어 가기 제안 줄 ·
                // 한도 줄의 대상). 한도 새로 읽기도 넣은 값을 돌려준다 — 실제 CLI 를 부르지 않는다 (`AppModel.previewApplyLimitFacts`).
                if let limits = UserDefaults.standard.string(forKey: "preview.limits") {
                    model.previewApplyLimitFacts(limits)
                }
                // `-preview.agyUsage <파일>` — `agy -p /usage --output-format json` 응답 파일을 앱의 해석기로 읽어 Antigravity 한도로 넣는다
                // (칩 · 팝오버 · 메뉴바 · 인계 카드의 받는 쪽 줄 확인용, `AppModel.previewApplyAntigravityUsage`).
                if let path = UserDefaults.standard.string(forKey: "preview.agyUsage") {
                    model.previewApplyAntigravityUsage(path: path)
                }
                // `-preview.claudeAPIKey YES` — Claude API 키가 저장된 것처럼 (메모리에만 — 키체인을 건드리지 않는다). 한도 줄 · 인계 카드 ·
                // 제안 줄의 [API 크레딧으로 계속] 을 볼 때 (`AppModel.previewClaudeAPIKey`).
                if UserDefaults.standard.bool(forKey: "preview.claudeAPIKey") { model.previewClaudeAPIKey() }
                // `-preview.codexSwitch YES` — 다른 Codex 계정으로 같은 세션을 이어 가는 카운트다운 (seed `--codex-history --codex-accounts`):
                // 입력창 위 줄 · 칸 머리 · 사이드바 배지 · 현황(`-window.pane overview`)의 행.
                if UserDefaults.standard.bool(forKey: "preview.codexSwitch") {
                    Task {
                        try? await Task.sleep(for: .milliseconds(800))
                        model.previewCodexSwitchCountdown()
                    }
                }
                // `-preview.settings agents` — 설정 창을 그 탭으로 연다 (general · agents · handoff · automation · advanced · about).
                // 긴 탭은 `-preview.settingsHeight 1700` 으로 한 장에. 설정 창은 주 창이 아니라 `KEEP=1` + `popwin` 으로 찍는다.
                if let tab = UserDefaults.standard.string(forKey: "preview.settings").flatMap(SettingsTab.init(rawValue:)) {
                    SettingsTab.select(tab)
                    openSettings()
                }
                // `-preview.windowSize 1000x700` 로 좁은 창을, `1000x700,1500x900` 처럼 이어 쓰면 차례로 바꿔 본다.
                let sizes = (UserDefaults.standard.string(forKey: "preview.windowSize") ?? "")
                    .split(separator: ",").map { $0.split(separator: "x").compactMap { Double($0) } }
                    .filter { $0.count == 2 }
                for (index, size) in sizes.enumerated() {
                    if index > 0 { try? await Task.sleep(for: .seconds(1.5)) }
                    NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })?
                        .setContentSize(NSSize(width: size[0], height: size[1]))
                }
                // `-preview.sweepDivider inspector|sidebar[:거리]` — 구분선 드래그를 흉내 내 크래시를 재현한다 (아래 `SplitDividerSweep`).
                if let sweep = UserDefaults.standard.string(forKey: "preview.sweepDivider") {
                    Task { await SplitDividerSweep.run(sweep) }
                }
                // `-preview.slash YES` — 입력창 "/" 목록을 CLI 대신 견본으로 채운다 (`-preview.typeKeys "insert:/co down"` 과 함께).
                if UserDefaults.standard.bool(forKey: "preview.slash") { model.previewSlashCommands() }
                // `-preview.typeKeys "d k s ret"` — 입력창에 키를 넣어 ↵ 보내기 · IME 조합을 확인한다 (UI/Composer.swift `ComposerKeyTyping`).
                if let keys = UserDefaults.standard.string(forKey: "preview.typeKeys") {
                    Task { await ComposerKeyTyping.run(keys) }
                }
                // `-preview.sweepMutate <초>` — 그 시점부터 가운데 칸을 대화 ↔ 전적으로 세 번 바꾼다 (드래그 도중 칸 내용이 바뀔 때의 재현).
                let mutate = UserDefaults.standard.double(forKey: "preview.sweepMutate")
                if mutate > 0 {
                    Task {
                        try? await Task.sleep(for: .seconds(mutate))
                        for _ in 0..<3 {
                            pane = pane == .scoreboard ? .conversation : .scoreboard
                            SplitDividerSweep.log("mutate pane=\(pane)")
                            try? await Task.sleep(for: .milliseconds(700))
                        }
                    }
                }
                // `-preview.action handoff[Countdown|Review|Failed|Unknown][:<claude|codex|gemini>]` — 선택된 대화의 끝에 인계 카드를
                // 놓는다: 수동 · 자동 인계 카운트다운 · 게이트가 막은 검토 · 보내지 못함 · 전달 미확인 (게이트 · 타이머 · 전송은 하지 않는다).
                // 받는 쪽을 고를 수 있다. Antigravity 는 프로젝트 허용이 필요해, `AHC_DATABASE_PATH` 로 연 DB 이고 프로젝트가 임시 폴더
                // 안일 때만 켠다 (받는 모델 칩 · 막힌 이유 줄을 볼 때). 대화에 실행 기록이 있어야 한다 (seed 의 `--handoff` · `--history`).
                // `-preview.handoffMemo <글>` 은 덧붙일 말 칸을 채운다. 다른 `-preview.action`(예: providerMenu — 카드가 있을 때의 칩 메뉴)과
                // 함께 카드를 놓으려면 같은 값을 `-preview.card` 로 준다.
                if let action = UserDefaults.standard.string(forKey: "preview.action").flatMap({ $0.hasPrefix("handoff") ? $0 : nil })
                    ?? UserDefaults.standard.string(forKey: "preview.card"),
                   action.hasPrefix("handoff"), let thread = model.selectedThread {
                    let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
                    let kind = parts[0]
                    let named = parts.count > 1 ? AgentProvider(rawValue: parts[1]) : nil
                    let target = named ?? thread.preferredProvider.other
                    if target == .gemini,
                       !(ProcessInfo.processInfo.environment["AHC_DATABASE_PATH"] ?? "").isEmpty,
                       let project = model.projects.first(where: { $0.id == thread.projectID }),
                       AppModel.isTemporaryPreviewProject(project.path) {
                        model.setAntigravityAllowed(true, projectID: thread.projectID)
                    }
                    // 대화 기록을 다 읽은 뒤에 (카드의 받는 쪽 · 요약이 기록에서 온다).
                    for _ in 0..<40 where model.threadStates[thread.id]?.loaded != true {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    // `-preview.handoffQueue YES` — 걸어 둔 메시지 하나 (입력창이 받는 쪽을 보이고 대기열이 인계 뒤로 가는 모습).
                    let queued = UserDefaults.standard.bool(forKey: "preview.handoffQueue")
                        ? ["인계가 끝나면 워커 테스트를 한 번 더 돌려 줘."] : []
                    await model.previewHandoffCard(kind: kind, target: target, queued: queued)
                }
                // `-preview.action subagents` — 가짜 어댑터(`PreviewSubAgentAdapter`)로 하위 에이전트를 띄운 실행을 시작해,
                // 메인 턴을 마치고 남은 하위를 기다리는 화면(머리글 · 입력창 · 카드 · 에이전트 탭)을 만든다. 실제 실행기를 거친다.
                // 임시 DB · 임시 폴더 프로젝트에서만 (CLI 를 부르지 않는다 — 어댑터를 바꿔 끼운다).
                if UserDefaults.standard.string(forKey: "preview.action") == "subagents",
                   !(ProcessInfo.processInfo.environment["AHC_DATABASE_PATH"] ?? "").isEmpty,
                   let project = model.selectedProject, AppModel.isTemporaryPreviewProject(project.path),
                   let thread = model.selectedThread {
                    model.runner.adapterFactory = { provider in PreviewSubAgentAdapter(provider: provider) }
                    _ = await model.send("로그인 화면의 오류 문구를 정리하고, 같은 문구를 쓰는 곳을 모두 찾아 줘. 둘로 나눠서 해 줘.",
                                         provider: thread.preferredProvider)
                }
                // `-preview.action panes` — 분할 화면(`--panes=2|4` 시드)의 칸마다 가짜 실행(`PreviewPaneAdapter`)을 보내 칸 머리 ·
                // "응답 필요" 를 만든다: 첫 칸 완료, 둘째 칸 승인 대기, 셋째 칸 실행 중, 칸에 없는 대화 하나는 질문 대기.
                // 임시 DB · 임시 폴더 프로젝트에서만 (CLI 를 부르지 않는다).
                if UserDefaults.standard.string(forKey: "preview.action") == "panes",
                   !(ProcessInfo.processInfo.environment["AHC_DATABASE_PATH"] ?? "").isEmpty,
                   let project = model.selectedProject, AppModel.isTemporaryPreviewProject(project.path) {
                    model.runner.adapterFactory = { provider in PreviewPaneAdapter(provider: provider) }
                    let open = model.panes.threadIDs
                    let prompts = ["[완료] 로그인 화면의 오류 문구를 같은 말투로 맞춰 줘.",
                                   "[승인] 바꾼 문구로 테스트를 돌려 줘.",
                                   "[실행] 토큰이 만료됐을 때의 안내도 같은 말투로 바꿔 줘."]
                    for (index, id) in open.enumerated() where index < prompts.count {
                        guard let id, let thread = model.paneThread(id) else { continue }
                        _ = await model.send(prompts[index], provider: thread.preferredProvider, threadID: id)
                    }
                    if let other = model.allThreads().first(where: { $0.projectID == project.id && !open.contains($0.id) }) {
                        _ = await model.send("[질문] 영어 화면도 함께 맞출지 물어봐 줘.", provider: other.preferredProvider,
                                             threadID: other.id)
                    }
                }
                // `-preview.action worktree` — 선택된 대화에 독립 작업 폴더를 만들고(임시 DB 옆 `worktrees`) 그 폴더에 파일 하나를 바꿔
                // 변경사항 탭 위의 작업 폴더 칸을 보인다. `worktreeFresh` 는 새 빈 대화(시작 화면의 폴더 고르기).
                // 임시 DB · 임시 폴더 프로젝트에서만.
                if let action = UserDefaults.standard.string(forKey: "preview.action"),
                   action == "worktree" || action == "worktreeFresh",
                   !(ProcessInfo.processInfo.environment["AHC_DATABASE_PATH"] ?? "").isEmpty,
                   let project = model.selectedProject, AppModel.isTemporaryPreviewProject(project.path),
                   let thread = model.selectedThread {
                    if action == "worktreeFresh" {
                        await model.addThread(projectID: project.id, title: "새 대화")
                    } else if await model.createWorktree(threadID: thread.id),
                              let path = model.projectPath(ofThread: thread.id) {
                        try? "# 메모\n\n작업 폴더에서 바꾼 파일.\n".write(toFile: path + "/NOTES.md", atomically: true, encoding: .utf8)
                        await model.workspace(forPath: path)?.refreshGit()
                    }
                }
                // `-preview.action composer` — 입력창 곁 부품(`--panes=2` 시드): 첫 칸은 편집 승인 카드, 둘째 칸은 실행 중(상태 줄)에
                // 걸어 둔 메시지 둘 · 붙인 이미지 · 쓰는 중인 글. 임시 DB · 임시 폴더 프로젝트에서만 (CLI 를 부르지 않는다).
                if UserDefaults.standard.string(forKey: "preview.action") == "composer",
                   !(ProcessInfo.processInfo.environment["AHC_DATABASE_PATH"] ?? "").isEmpty,
                   let project = model.selectedProject, AppModel.isTemporaryPreviewProject(project.path) {
                    model.runner.adapterFactory = { provider in PreviewPaneAdapter(provider: provider) }
                    let open = model.panes.threadIDs.compactMap { $0 }
                    if let first = open.first, let thread = model.paneThread(first) {
                        _ = await model.send("[편집] 오류 문구를 같은 말투로 바꿔 줘.", provider: thread.preferredProvider, threadID: first)
                    }
                    if open.count > 1, let thread = model.paneThread(open[1]) {
                        _ = await model.send("[실행] 토큰이 만료됐을 때의 안내도 같은 말투로 바꿔 줘.",
                                             provider: thread.preferredProvider, threadID: open[1])
                        model.enqueueMessage("끝나면 로그인 테스트도 돌려 줘.", images: [], threadID: open[1])
                        model.enqueueMessage("그다음 바뀐 파일을 요약해 줘.", images: [], threadID: open[1])
                        if let tiff = NSApp.applicationIconImage?.tiffRepresentation {
                            model.attachImages(data: [tiff], threadID: open[1])
                        }
                        model.updateComposerDraft("이 아이콘처럼 둥글게 바꿀 수 있을까?", for: open[1])
                    }
                }
                // `-preview.action runStatus` — 칸마다 다른 일에 머무는 가짜 실행(`PreviewPaneAdapter`): 생각 · 명령 · 찾기 · 답변 쓰기.
                // 실행 중 상태 줄의 도는 표시를 칸 수만큼 함께 돌린다 (모양 확인 · CPU 재기). 빈 칸이 있으면 남은 대화를 그 칸에 연다.
                // 임시 DB · 임시 폴더 프로젝트에서만 (CLI 를 부르지 않는다).
                if UserDefaults.standard.string(forKey: "preview.action") == "runStatus",
                   !(ProcessInfo.processInfo.environment["AHC_DATABASE_PATH"] ?? "").isEmpty,
                   let project = model.selectedProject, AppModel.isTemporaryPreviewProject(project.path) {
                    model.runner.adapterFactory = { provider in PreviewPaneAdapter(provider: provider) }
                    if model.panes.threadIDs.contains(where: { $0 == nil }),
                       let other = model.allThreads().first(where: { $0.projectID == project.id
                                                                     && !model.panes.threadIDs.contains($0.id) }) {
                        await model.openInNewPane(other.id)
                    }
                    let prompts = ["[생각] 로그인 흐름을 정리해 줘.", "[명령] 로그인 테스트를 돌려 줘.",
                                   "[찾기] 오류 문구를 쓰는 곳을 찾아 줘.", "[실행] 토큰이 만료됐을 때의 안내도 같은 말투로 바꿔 줘."]
                    for (index, id) in model.panes.threadIDs.compactMap({ $0 }).enumerated() where index < prompts.count {
                        guard let thread = model.paneThread(id) else { continue }
                        _ = await model.send(prompts[index], provider: thread.preferredProvider, threadID: id)
                    }
                }
                // `-preview.action toolRun` — 도구를 1초 간격으로 하나씩 돌리는 가짜 실행 (`PreviewPaneAdapter` 의 `[도구들]`):
                // 도는 실행의 실행 기록이 접힌 채 수만 바뀌고 지금 하는 일은 상태 줄 한 줄인지 (`ExecutionFold`).
                // 임시 DB · 임시 폴더 프로젝트에서만 (CLI 를 부르지 않는다).
                if UserDefaults.standard.string(forKey: "preview.action") == "toolRun",
                   !(ProcessInfo.processInfo.environment["AHC_DATABASE_PATH"] ?? "").isEmpty,
                   let project = model.selectedProject, AppModel.isTemporaryPreviewProject(project.path),
                   let thread = model.selectedThread {
                    model.runner.adapterFactory = { provider in PreviewPaneAdapter(provider: provider) }
                    _ = await model.send("[도구들] 로그인 화면의 오류 문구를 확인해 줘.", provider: thread.preferredProvider,
                                         threadID: thread.id)
                }
                // `-preview.action stream` — 긴 답이 빠르게 흐르는 가짜 실행으로 맨 아래 따라가기를 잰다 (`StreamFollowProbe`).
                // 임시 DB · 임시 폴더 프로젝트에서만 (CLI 를 부르지 않는다).
                if UserDefaults.standard.string(forKey: "preview.action") == "stream",
                   !(ProcessInfo.processInfo.environment["AHC_DATABASE_PATH"] ?? "").isEmpty,
                   let project = model.selectedProject, AppModel.isTemporaryPreviewProject(project.path),
                   let thread = model.selectedThread {
                    model.runner.adapterFactory = { provider in PreviewPaneAdapter(provider: provider) }
                    Task { await StreamFollowProbe.run() }
                    _ = await model.send("[흐름] 로그인 흐름을 길게 정리해 줘.", provider: thread.preferredProvider, threadID: thread.id)
                }
                // `-preview.action import` — 기록 가져오기 시트를 연 채 시작한다 (이 Mac 의 실제 ~/.claude · ~/.codex 를 읽기만 한다).
                if UserDefaults.standard.string(forKey: "preview.action") == "import" {
                    model.showImportSheet = true
                }
                // `-preview.action firstRunSheet` — 도움말 > 시작 점검… 의 시트 (사실은 `-preview.firstRun`).
                if UserDefaults.standard.string(forKey: "preview.action") == "firstRunSheet" {
                    model.showFirstRunSheet = true
                }
                // `-preview.action changesSearch` 는 ⌘⇧F 를 누른 상황 (변경사항 탭의 찾기 칸에 포커스).
                if UserDefaults.standard.string(forKey: "preview.action") == "changesSearch" {
                    model.changesSearchFocusRequested = true
                }
                // `-preview.commitDraft <메시지>` 로 변경사항 탭의 커밋 메시지 초안을 채운다.
                if let draft = UserDefaults.standard.string(forKey: "preview.commitDraft"),
                   let project = model.selectedProject {
                    model.setCommitDraft(draft, forFolder: project.path)
                }
                let action = UserDefaults.standard.string(forKey: "preview.action")
                let pullRequestFixture = UserDefaults.standard.string(forKey: "preview.pullRequest")
                let runSummaryActions = ["runSummary", "runSummaryReview"]
                if pullRequestFixture != nil || (["push", "pull", "fetch"] + runSummaryActions).contains(action ?? "") {
                    for _ in 0..<50 {
                        if let project = model.selectedProject, model.workspace.projectPath == project.path,
                           model.workspace.git != nil { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                // `-preview.pullRequest <JSON 경로>` 는 gh 가 준 형식(`gh pr view --json …`)의 파일을 **앱의 해석기**로 읽어
                // 지금 브랜치의 PR 캐시에 넣는다 (AHC_OFFLINE 에서는 변경사항 탭이 gh 를 부르지 않는다). 값을 코드에서 만들지 않는다.
                if let pullRequestFixture, let json = try? String(contentsOfFile: pullRequestFixture, encoding: .utf8) {
                    _ = model.workspace.previewUsePullRequest(json: json)
                }
                // `-preview.action push · pull · fetch` 는 시작 직후 그 git 명령을 **실제로** 실행한다 (확인을 거친 것으로
                // 보고 결과를 변경사항 탭 안에 남긴다). 업로드 거절 · 로그인 실패 · 겹치는 변경 같은 실패 표시를
                // 시나리오 저장소의 실제 git 출력으로 확인할 때 쓴다. 지어낸 결과를 넣지 않는다.
                if let action, ["push", "pull", "fetch"].contains(action) {
                    // 임시 폴더 안의 프로젝트(시나리오 저장소)에서만 — 확인 창을 건너뛰는 명령이라 실제 프로젝트에서
                    // 잘못 켜도 올리거나 받지 않게 한다.
                    if let project = model.selectedProject, AppModel.isTemporaryPreviewProject(project.path),
                       let git = model.workspace.git, git.isRepository, let branch = git.branch {
                        let operation: GitWrite.Operation = action == "push"
                            ? .push(branch: branch, setUpstream: git.upstream == nil)
                            : (action == "pull" ? .pull : .fetch)
                        await model.runGit(operation, confirmed: true, reportsInline: true)
                    }
                }
                // `-preview.action runSummary` 는 실행 전후 비교 카드와 변경사항 탭 점을 보려고, 합성한 끝난 실행 하나에
                // **실제 스냅샷 · 차이 함수**로 만든 요약을 남긴다 (임시 DB · 임시 폴더 프로젝트에서만 —
                // `AppModel.previewRecordRunChanges`). `runSummaryReview` 는 이어서 카드의 "변경사항 검토" 칩과 같은 길
                // (변경사항 탭으로 열기 + 그 실행의 파일을 위로 올리는 요청)을 탄다.
                if let action, runSummaryActions.contains(action),
                   let changes = await model.previewRecordRunChanges(),
                   action == "runSummaryReview", let threadID = model.selectedThreadID {
                    inspectorTab = .changes
                    showInspector = true
                    model.requestChangesReview(threadID: threadID, changes: changes)
                }
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .handoffConsoleOpenHandoff)) { _ in
            pane = .conversation
            // 크게 보기 중이면 패널로 줄인다 (보던 diff 는 변경사항 탭에 남는다). 카드는 대화에 놓이므로 diff 는 키를 가져가지 않는다.
            if model.diffWideActive { model.setDiffWide(false, focusKeys: false) }
            guard let thread = model.selectedThread else { return }
            // 메뉴바에서 온 요청: 카드가 있으면 그 카드로, 없으면 기본 대상(다른 에이전트)으로 카드를 만든다
            // (`prepareHandoff` 가 있는 카드로 간다). 다른 대상(다른 Codex 계정 등)은 입력창 칩 메뉴의 이어 맡기기 행에서 고른다.
            let target = model.defaultHandoffTarget(for: thread)
            Task { await model.prepareHandoff(to: target.provider, toAccountID: target.codexAccountID) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 앱 밖(터미널·편집기)에서 파일을 바꿨을 수 있다. 활성화될 때만 다시 읽는다 (폴링하지 않음).
            guard model.bootstrapped else { return }
            Task { await model.refreshOpenWorkspaces() }
            // 터미널에서 설치 · 로그인하고 돌아왔을 수 있다 — 점검표가 보이거나 모르는 사실이 있을 때만, 15초에 한 번.
            Task { await model.recheckFactsOnActivation() }
        }
        .onChange(of: model.notifications.pendingThreadID) { _, _ in
            consumePendingNotification()
        }
        // 크게 보기는 대화 칸 자리에 들어온다 — 저장된 칸을 대화로 둔다. 분할 컨트롤은 대화를 가리키고, ‹ 대화로 돌아가기 · esc ·
        // 마지막 파일이 빠져 닫힘은 이름 그대로 대화로 돌아가며, 크게 보기 중에 앱을 끄면 다음에 대화로 연다 (전적에서 열었어도).
        .onChange(of: model.diffWideActive) { _, active in
            if active, pane != .conversation { pane = .conversation }
        }
        // 대화를 고르거나 새로 만들었다 (⌘N · 사이드바 ＋ · 폴더 열기 · 메뉴바 · ⌘F) — 에이전트 기록 · 크게 보기 중이어도 그 대화가 보이게.
        // 크게 보기는 패널로 줄인다 (보던 diff 는 변경사항 탭에 남는다).
        .onChange(of: model.conversationRevealRequest) { _, _ in
            if pane != .conversation { pane = .conversation }
            if model.diffWideActive { model.setDiffWide(false, focusKeys: false) }
        }
        // 현황을 열어 달라는 요청 (메뉴바 "현황 열기" · 응답 필요 칩의 "현황에서 모두 보기").
        .onChange(of: model.overviewRevealRequest) { _, _ in
            if model.diffWideActive { model.closeDiff() }
            pane = .overview
        }
        // 도움말 메뉴의 시트 (UI/HelpSheets.swift). 시트마다 다른 뷰에 붙인다 (가져오기 · 시작 점검 시트와 같은 방식).
        .background {
            Color.clear.sheet(isPresented: $model.showKeyboardShortcuts) { KeyboardShortcutsSheet() }
        }
        .background {
            Color.clear.sheet(isPresented: $model.showAppGuide) { AppGuideSheet().environment(model) }
        }
        .overlay(alignment: .center) {
            if let error = model.bootstrapError {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Theme.slate)
                    Text("저장소를 열지 못했습니다").font(Theme.barTitle).foregroundStyle(Theme.ink)
                    Text(error).font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                    Text(Store.defaultDatabaseURL().path)
                        .font(Theme.mono(.caption))
                        .foregroundStyle(Theme.slate2)
                }
                .padding(30)
                .cardSurface(radius: 12)
            }
        }
    }

    /// 알림을 눌러 들어온 스레드 이동 요청을 한 번만 처리한다.
    /// 자동 인계 알림의 취소 · 검토(카운트다운 멈춤)는 창과 무관하게 모델이 직접 처리한다 (`NotificationService.automaticActionHandler`).
    /// 인계 알림이면 그 대화를 열고 대화 끝의 인계 카드로 내려간다 — 카드는 대화에 붙어 있어 다른 칸의 대화를 바꿔도 잃지 않는다.
    private func consumePendingNotification() {
        guard let id = model.notifications.pendingThreadID else { return }
        let opensHandoff = model.notifications.pendingOpensHandoff
        model.notifications.pendingThreadID = nil
        model.notifications.pendingOpensHandoff = false
        pane = .conversation
        if model.diffWideActive { model.setDiffWide(false, focusKeys: false) }
        Task {
            await model.selectThread(id)
            if opensHandoff, model.hasHandoffActivity(threadID: id) {
                await model.revealHandoffCard(threadID: id)
            }
        }
    }

    /// 세 칸이 창에 들어가지 않으면 칸들이 창 밖으로 밀려 잘린다. 그 전에 한쪽 패널을 접고, 공간이 돌아오면 다시 편다.
    /// 판정은 `PanelFit.adjustment` — 여기서는 그 결과를 상태에 옮기기만 한다.
    private func fitPanels() {
        let change = PanelFit.adjustment(windowWidth: windowWidth, sidebar: model.sidebarVisible,
                                         inspector: showInspector, autoHidden: autoHidden, lastOpened: lastOpenedPanel)
        switch change {
        case .hide(let panel)?:
            autoHidden = panel
            set(panel, visible: false)
            // 말없이 사라지면 결함처럼 보인다 — 처음 한 번 알린다 (다른 안내가 떠 있으면 덮지 않는다).
            if !autoHideNoticeShown, model.banner == nil, model.bootstrapped {
                autoHideNoticeShown = true
                model.banner = AppModel.BannerMessage(text: PanelFit.autoHideNotice(panel), isError: false)
            }
        case .show(let panel)?:
            autoHidden = nil
            set(panel, visible: true)
        case nil:
            break
        }
    }

    /// 앱이 여닫는 것이므로 `onChange` 가 사용자 조작으로 세지 않게 표시한다 (값이 실제로 바뀔 때만 — 아니면 표시가 남아
    /// 다음 사용자 조작을 삼킨다).
    private func set(_ panel: Panel, visible: Bool) {
        switch panel {
        case .sidebar:
            guard model.sidebarVisible != visible else { return }
            applyingFit = true
            model.sidebarVisible = visible
        case .inspector:
            guard showInspector != visible else { return }
            applyingFit = true
            showInspector = visible
        }
    }

    // MARK: 상단 바

    /// 툴바 제목(+ 부제) 항목의 폭 상한. 긴 제목은 줄여 오른쪽 항목을 밀어내지 않는다 (전문은 도움말).
    static let toolbarTitleMaxWidth: CGFloat = 420

    // 왼쪽은 사이드바 단추와 제목뿐이다. 오른쪽: 응답 필요 · 변경 N(인스펙터를 닫았을 때) · 한도 · ⋯(분할 화면 · 에이전트 기록) · 인스펙터.
    // 분할 화면 · 에이전트 기록은 자주 쓰지 않는 가운데 칸 조작이라 ⋯ 와 보기 메뉴(단축키)로 옮겼다.
    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        // 사이드바 보기/숨기기 — 신호등 바로 뒤 (Claude · Codex 앱처럼 사이드바 위에 놓인다). 보기 메뉴 ⌃⌘S 와 같다.
        ToolbarItem(placement: .navigation) {
            Button {
                model.sidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.slate2)
            }
            .help(model.sidebarVisible ? "사이드바 숨기기 (⌃⌘S)"
                  : (autoHidden == .sidebar ? PanelFit.autoHiddenHelp(.sidebar) : "사이드바 보기 (⌃⌘S)"))
            .accessibilityLabel(model.sidebarVisible ? "사이드바 숨기기" : "사이드바 보기")
        }
        .plainToolbarBackground()
        ToolbarItem(placement: .navigation) {
            // 제목 한 줄 + 부제 한 줄 (프로젝트 — 브랜치 ↑↓). 칩 · 테두리는 두지 않는다. 이 스레드의 토큰 · 비용은 부제의 도움말에.
            // 에이전트 기록 · 현황 화면은 본문에 자체 머리줄이 있어 비운다. 사이드바가 보이면 제목을 본문 칸 위(사이드바 칸 + 16)로 민다 —
            // 툴바 항목은 신호등 · 사이드바 버튼 뒤에 놓이므로, 이 항목이 놓인 자리(`titleItemX`)를 재서 그 차이만큼.
            HStack(spacing: 0) {
                Color.clear.frame(width: PanelFit.toolbarTitleLead(sidebarVisible: model.sidebarVisible,
                                                                   sidebarColumnWidth: sidebarColumnWidth, itemX: titleItemX),
                                  height: 1)
                VStack(alignment: .leading, spacing: 1) {
                    // 첫 실행 점검표가 가운데를 차지하면 제목을 비운다 (점검표에 자체 제목이 있다 — "스레드 없음" 은 잘못 읽힌다).
                    // 분할한 직후처럼 포커스 칸이 비었으면 "대화 없음" 이 아니라 그 상황을 (chr-8).
                    let emptyPane: Bool = model.selectedThread == nil && model.panes.layout != .single
                    let title = shownPane == .scoreboard || shownPane == .overview || model.showsFirstRun ? ""
                        : (model.selectedThread?.title ?? (emptyPane ? "빈 칸" : "대화 없음"))
                    Text(title)
                        .font(Theme.barTitle)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(emptyPane ? "사이드바에서 대화를 고르거나 ⌘N 으로 새 대화를 이 칸에 엽니다" : title)
                    if shownPane != .scoreboard, shownPane != .overview, let subtitle = toolbarSubtitle {
                        Text(subtitle)
                            .font(Theme.ui(.caption))
                            .foregroundStyle(Theme.slate)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(toolbarSubtitleHelp)
                    }
                }
                .frame(maxWidth: Self.toolbarTitleMaxWidth, alignment: .leading)
            }
            .background(WindowXProbe(x: $titleItemX))
        }
        .plainToolbarBackground()
        // macOS 26 부터 도구 막대 항목이 앞쪽으로 모인다. 여기부터는 오른쪽으로 민다.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
        // 사람의 답을 기다리는 다른 대화 (승인 · 질문 · 자동 작업). 없으면 두지 않는다. 누르면 그 대화로 — 에이전트 기록 · 크게 보기 중이면 대화 화면으로.
        if !model.responseNeeded.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                ResponseNeededChip(items: model.responseNeeded) { showConversation() }
            }
            .plainToolbarBackground()
        }
        // 인스펙터를 닫아 두었을 때만 — 작업 폴더에 바뀐 파일이 있으면 "변경 N +a −d". 누르면 변경사항 탭으로 연다.
        if !showInspector, let summary = ChangesState.summary(of: model.workspace.git) {
            ToolbarItem(placement: .primaryAction) {
                ChangesPill(summary: summary) {
                    inspectorTab = .changes
                    showInspector = true
                }
            }
            .plainToolbarBackground()
        }
        ToolbarItem(placement: .primaryAction) {
            LimitsChip(budget: limitsChipBudget)
        }
        .plainToolbarBackground()
        ToolbarItem(placement: .primaryAction) {
            moreMenu
        }
        .plainToolbarBackground()
        // 인스펙터를 숨겨도 다시 열 수 있도록 토글은 창 오른쪽 끝에 둔다.
        ToolbarItem(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.slate2)
            }
            .help(showInspector ? "인스펙터 숨기기 (⌥⌘0)"
                  : (autoHidden == .inspector ? PanelFit.autoHiddenHelp(.inspector) : "인스펙터 보기 (⌥⌘0)"))
            .accessibilityLabel(showInspector ? "인스펙터 숨기기" : "인스펙터 보기")
        }
        // 다른 항목처럼 유리 바탕 없이 — 없으면 macOS 26 에서 이 단추만 흰 원이 떠 보였다.
        .plainToolbarBackground()
    }

    /// ⋯ — 분할 화면 · 에이전트 기록 (보기 메뉴에 단축키와 함께 있는 것과 같다). 분할을 고르면 대화 화면으로 돌아온다 —
    /// 칸을 늘리면 포커스가 새 빈 칸으로 간다 (`PaneArrangement.resized`), 줄였다 늘리면 앞의 배치가 돌아온다.
    private var moreMenu: some View {
        Menu {
            Picker("분할 화면", selection: Binding(get: { model.panes.layout }, set: { layout in
                showConversation()
                Task { await model.setPaneLayout(layout) }
            })) {
                ForEach(PaneLayout.allCases) { layout in
                    Label(layout.title, systemImage: layout.systemImage).tag(layout)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button(WindowPane.overviewToggleTitle(shown: shownPane)) {
                if model.diffWideActive { model.closeDiff() }
                pane = WindowPane.togglingOverview(shown: shownPane)
            }
            Button(WindowPane.scoreboardToggleTitle(shown: shownPane)) {
                let next = WindowPane.togglingScoreboard(shown: shownPane)
                if model.diffWideActive { model.closeDiff() }
                pane = next
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.slate2)
        }
        .menuIndicator(.hidden)
        .help("분할 화면 · \(WindowPane.overviewTitle) · \(WindowPane.scoreboardTitle)")
        .accessibilityLabel("분할 화면 · \(WindowPane.overviewTitle) · \(WindowPane.scoreboardTitle)")
    }

    /// 가운데 칸을 대화로 (크게 보기 중이면 닫는다).
    private func showConversation() {
        if model.diffWideActive { model.closeDiff() }
        pane = .conversation
    }

    /// `moa-ios — feature/login ↑2`. 모르는 값은 채우지 않는다. 이 스레드의 토큰 · 비용은 도움말에 (`toolbarSubtitleHelp`).
    private var toolbarSubtitle: String? {
        guard let project = model.selectedProject else { return nil }
        // 이름이 같은 프로젝트가 있으면 위 폴더를 덧붙인 이름 (`AppModel.projectDisplayName`).
        var text = model.projectDisplayName(project)
        if let git = model.workspace.git, git.isRepository, let head = git.headLabel {
            text += " — " + head
            if let ahead = git.ahead, ahead > 0 { text += " ↑\(ahead)" }
            if let behind = git.behind, behind > 0 { text += " ↓\(behind)" }
        }
        return text
    }

    private var toolbarSubtitleHelp: String {
        var lines: [String] = []
        if let project = model.selectedProject { lines.append(project.path) }
        if let git = model.workspace.git, git.isRepository {
            lines.append(git.upstream.map { "추적: \($0)" } ?? "추적 중인 원격 브랜치 없음")
        }
        let agg = model.threadUsageAggregate
        if model.selectedThread != nil, agg.turns > 0 {
            var usage = "이 대화 누적 토큰 \(Fmt.tokens(agg.totalTokens))"
            if agg.costUnknownTurns == 0 { usage += " · \(Fmt.cost(agg.displayCostUSD))" }
            else if agg.knownCostTurns > 0 { usage += " · 확인된 \(Fmt.cost(agg.displayCostUSD)) · 미확인 \(agg.costUnknownTurns)턴" }
            else { usage += " · 금액 미확인" }
            lines.append(usage + " (API 가격표 기준 환산 — 구독 실제 청구액이 아님)")
        }
        return lines.joined(separator: "\n")
    }
}

/// 툴바의 "변경 N +a −d" — 인스펙터를 닫아 두었을 때 작업 폴더에 바뀐 파일이 있으면 놓인다. 누르면 변경사항 탭으로 연다.
/// 수는 변경사항 탭의 목록과 같은 판정이다 (`ChangesState.summary`).
private struct ChangesPill: View {
    let summary: ChangesState.Summary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text("변경 \(summary.files)")
                    .foregroundStyle(Theme.ink2)
                if summary.conflicts > 0 {
                    Text("충돌 \(summary.conflicts)").foregroundStyle(Theme.danger)
                }
                if summary.added > 0 {
                    Text("+\(summary.added)").font(Theme.mono(.caption, .medium)).foregroundStyle(Theme.emeraldText)
                }
                if summary.removed > 0 {
                    Text("−\(summary.removed)").font(Theme.mono(.caption, .medium)).foregroundStyle(Theme.danger)
                }
            }
            .font(Theme.ui(.caption, .medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hair))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
        .accessibilityLabel(accessibility)
    }

    private var help: String {
        var lines = ["바뀐 파일 \(summary.files)개 — 눌러서 변경사항 탭 열기 (⌥⌘\(InspectorTab.changes.shortcut))"]
        if summary.unknownLines > 0 { lines.append("줄 수를 모르는 파일 \(summary.unknownLines)개는 합에서 뺐습니다") }
        return lines.joined(separator: "\n")
    }

    private var accessibility: String {
        var text = "바뀐 파일 \(summary.files)개"
        if summary.conflicts > 0 { text += ", 충돌 \(summary.conflicts)개" }
        if summary.added > 0 || summary.removed > 0 { text += ", \(summary.added)줄 추가, \(summary.removed)줄 삭제" }
        return text + ", 변경사항 탭 열기"
    }
}

extension ToolbarContent {
    /// macOS 26 의 유리 캡슐을 끈다. 직접 그린 알약·제목 위에 캡슐이 한 겹 더 씌워지지 않게 한다.
    @ToolbarContentBuilder
    func plainToolbarBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// 인스펙터 탭 다섯 개 — 글자 탭. 선택된 탭은 옅은 채움 + 잉크색, 나머지는 회색 글자 (아이콘 · 테두리 · 그림자 없음).
/// `badges` 의 탭에는 이름 옆에 5pt 점 — 변경사항 탭의 "검토하지 않은 실행 변경", 에이전트 탭의 "하위 에이전트 실행 중".
/// 점의 뜻은 탭마다 달라 도움말 · 접근성 글도 탭마다 받는다.
struct InspectorTabSwitcher: View {
    struct Badge {
        /// 점의 뜻 (도움말 · 접근성 값).
        var text: String
        var color: Color
    }

    @Binding var tab: InspectorTab
    var badges: [InspectorTab: Badge] = [:]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InspectorTab.allCases) { item in
                let selected = item == tab
                let badge = badges[item]
                let help = item.title + "  ⌘⌥" + String(item.shortcut) + (badge.map { " · " + $0.text } ?? "")
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 5) {
                        Text(item.title)
                            .font(Theme.ui(.caption, selected ? .medium : .regular))
                            .foregroundStyle(selected ? Theme.ink : Theme.slate)
                        if let badge {
                            Circle().fill(badge.color).frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background {
                        if selected { RoundedRectangle(cornerRadius: 6).fill(Theme.well) }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(help)
                .accessibilityLabel(item.title)
                .accessibilityValue(badge?.text ?? "")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// 메인 창을 다시 열기 위한 액션 보관소.
/// 창을 다시 열었다고 CLI 프로세스를 중복 실행하지 않는다 (실행은 RunCoordinator 가 단독 관리).
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var open: ((String) -> Void)?
    private(set) var ready = false
    func registerModelReady() { ready = true }
}

#if DEBUG
/// 구분선 드래그 재현 도구 (`-preview.sweepDivider inspector|sidebar[:거리]`, 화면 확인용 실행에서만).
///
/// 실제 마우스 드래그는 접근성 권한 없이 자동화할 수 없어, 인스펙터는 창의 NSSplitView 구분선 위치에 합성 마우스 이벤트를 한 프레임에 1pt 씩 넣는다.
/// 사이드바는 `ContentView` 가 그린 1pt 선(`SidebarDivider` — 2026-09-28 부터 NSSplitView 가 아니다)이라 합성 이벤트를 받지 않아,
/// 저장된 너비를 같은 박자로 바꾼다.
/// 2026-09-14: 인스펙터 구분선을 끌다 제약 갱신 도중 칸 min/max 가 바뀌어 NSInternalInconsistencyException 으로 죽은 크래시의 재현용.
/// 진행 기록은 `$TMPDIR/ahc-preview/sweep.log` 에 남긴다.
@MainActor
enum SplitDividerSweep {
    /// 사이드바 구분선의 창 x (`ContentView` 가 사이드바 칸 너비가 바뀔 때마다 적는다).
    static var sidebarHandleX: CGFloat = 0
    /// 사이드바 너비를 바꾸는 길 (`ContentView` 가 넣는다 — 저장된 너비 `sidebar.width` 를 바꾼다. 구분선을 끄는 것과 같은 값이다).
    static var setSidebarWidth: ((Double) -> Void)?

    /// `;` 로 이으면 차례로 끈다 (예 `inspector:150:stay;sidebar:200` — 인스펙터를 넓혀 둔 채 사이드바를 끈다).
    /// 세 번째 항목 `stay` 는 끝점에서 되돌리지 않고 그대로 둔다 (기본은 끝점에서 잠시 멈춘 뒤 시작점으로 되돌린다).
    static func run(_ spec: String) async {
        for part in spec.split(separator: ";") { await runOne(String(part)) }
    }

    static func runOne(_ spec: String) async {
        let parts = spec.split(separator: ":")
        let which = String(parts.first ?? "inspector")
        // 거리가 음수면 반대 방향 (인스펙터: 오른쪽으로 → 좁아지게).
        let signed = parts.count > 1 ? (Double(parts[1]) ?? 150) : 150
        let distance = abs(signed)
        let stay = parts.count > 2 && parts[2] == "stay"
        // 인스펙터는 창이 뜬 뒤 몇 초 지나 배치된다 — 안쪽 스플릿의 두 번째 칸이 창 안에 실제로 놓일 때까지 기다린다 (최대 12초).
        var window: NSWindow?
        var splits: [NSSplitView] = []
        for _ in 0..<24 {
            try? await Task.sleep(for: .milliseconds(500))
            guard let candidate = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  let root = candidate.contentView else { continue }
            splits = []
            func walk(_ view: NSView) {
                if let split = view as? NSSplitView { splits.append(split) }
                view.subviews.forEach(walk)
            }
            walk(root)
            let placed = splits.map { split in split.arrangedSubviews.map { "\($0.convert($0.bounds, to: nil))" } }
            log("poll splits=\(placed)")
            window = candidate
            if which == "sidebar" { break }
            if splits.contains(where: { split in
                split.arrangedSubviews.count >= 2 && split.arrangedSubviews[1].convert(split.arrangedSubviews[1].bounds, to: nil).minX > 100
            }) { break }
        }
        guard let window, let root = window.contentView else { log("no window"); return }
        for split in splits {
            var chain: [String] = []
            var view: NSView? = split.superview
            while let current = view, chain.count < 6 { chain.append(String(describing: type(of: current))); view = current.superview }
            log("split \(ObjectIdentifier(split)) inWindow=\(split.convert(split.bounds, to: nil)) hidden=\(split.isHiddenOrHasHiddenAncestor) vertical=\(split.isVertical) supers=\(chain)")
            for sub in split.subviews {
                log("  sub \(String(describing: type(of: sub))) inWindow=\(sub.convert(sub.bounds, to: nil)) hidden=\(sub.isHidden) arranged=\(split.arrangedSubviews.contains { $0 === sub })")
            }
        }
        // 사이드바는 NSSplitView 칸이 아니다 (`SidebarDivider` 의 SwiftUI 끌기). 합성 마우스 이벤트는 SwiftUI 끌기가 받지 않으므로
        // (실제 버튼 상태를 본다 — 2026-09-28 실측: 선 위치에서 눌러도 너비가 그대로), 끌기가 하는 일 — 저장된 너비를 1pt 씩 바꾸기 — 을
        // 같은 박자로 한다. 너비가 바뀔 때의 배치(인스펙터 스플릿의 제약 갱신)가 재현하려는 것이다.
        if which == "sidebar" {
            guard let setWidth = setSidebarWidth else { log("no sidebar setter"); return }
            let start = Double(sidebarHandleX + 0.5 - PanelFit.Metrics.app.divider)
            let sign: Double = signed < 0 ? -1 : 1
            log("sidebar start width=\(start) distance=\(distance)")
            var offsets: [Double] = []
            for step in stride(from: 1.0, through: distance, by: 1) { offsets.append(step) }
            if !stay { for step in stride(from: distance - 1, through: 0, by: -1) { offsets.append(step) } }
            for (index, offset) in offsets.enumerated() {
                setWidth(start + sign * offset)
                if index % 25 == 0 || offset == distance { log("step \(index) offset=\(offset) sidebarHandleX=\(sidebarHandleX)") }
                try? await Task.sleep(for: .milliseconds(offset == distance ? 2500 : 8))
            }
            log("done alive sidebarHandleX=\(sidebarHandleX)")
            hostingConstraints(in: root).forEach { log("  constraints \($0)") }
            try? await Task.sleep(for: .milliseconds(800))
            return
        }
        // 인스펙터 스플릿: 다른 스플릿 안에 있으면 그것, 아니면(바깥 스플릿이 없으면) 마지막 것.
        let inner = splits.filter { split in splits.contains { $0 !== split && split.isDescendant(of: $0) } }
        guard let target = inner.first ?? splits.last, target.arrangedSubviews.count >= 2 else { log("no target"); return }
        // 구분선 뷰의 실제 위치에서 마우스를 누르고, 타이머(추적 런루프 모드에서도 돈다)로 드래그 이벤트를 8ms 마다 넣은 뒤 뗀다.
        // `setPosition` 은 macOS 26 인스펙터 칸을 움직이지 못한다 (제약 기반 배치) — 실제 `NSSplitView.mouseDown` 추적 루프를 태운다.
        // 계층 전체에서 이름에 Divider 가 든 뷰를 창 좌표로 기록하고, 두 번째 칸의 왼쪽 가장자리에 가장 가까운 보이는 것을 고른다.
        let edgeX = target.arrangedSubviews[1].convert(target.arrangedSubviews[1].bounds, to: nil).minX
        // 인스펙터가 자식 창에 있을 수 있다 — 모든 창과 자식 창의 계층을 훑는다.
        for other in NSApp.windows {
            log("window \(String(describing: type(of: other))) frame=\(other.frame) visible=\(other.isVisible) parent=\(other.parent.map { "\($0.windowNumber)" } ?? "-") number=\(other.windowNumber) content=\(other.contentView.map { String(describing: type(of: $0)) } ?? "-")")
        }
        var dividers: [(view: NSView, frame: NSRect)] = []
        func collect(_ view: NSView) {
            let name = String(describing: type(of: view))
            if name.lowercased().contains("divider") {
                let frame = view.convert(view.bounds, to: nil)
                log("divider-like \(name) window=\(view.window?.windowNumber ?? -1) frame=\(frame) hidden=\(view.isHiddenOrHasHiddenAncestor) super=\(view.superview.map { String(describing: type(of: $0)) } ?? "-")")
                if !view.isHiddenOrHasHiddenAncestor, frame.width > 0, frame.height > 0 { dividers.append((view, frame)) }
            }
            view.subviews.forEach(collect)
        }
        collect(root)
        for other in NSApp.windows where other !== window { other.contentView.map(collect) }
        for x in [edgeX - 2, edgeX, edgeX + 2, edgeX + 60] {
            let point = NSPoint(x: x, y: root.bounds.midY)
            var chain: [String] = []
            var view = (root.superview ?? root).hitTest(point)
            while let current = view, chain.count < 8 { chain.append(String(describing: type(of: current))); view = current.superview }
            log("hit x=\(x): \(chain)")
        }
        // macOS 26 의 NSSplitDividerView 는 폭 0 · hidden 이다 — 구분선 뷰가 없으면 칸 가장자리 지점에서 그대로 누른다
        // (NSSplitView 가 자기 hitTest 로 구분선 영역을 가져간다).
        let chosen = dividers.min(by: { abs($0.frame.midX - edgeX) < abs($1.frame.midX - edgeX) })
        let divider = chosen?.view ?? target
        let startPoint = chosen.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? NSPoint(x: edgeX, y: root.bounds.midY)
        log("start hit=\(String(describing: (root.superview ?? root).hitTest(startPoint).map { type(of: $0) }))")
        hostingConstraints(in: root).forEach { log("  constraints \($0)") }
        log("target frame=\(target.frame) start=\(startPoint) distance=\(distance)")
        // 인스펙터 구분선은 왼쪽으로(인스펙터가 넓어지게) 끌었다가 되돌린다.
        await drag(window: window, from: startPoint, sign: signed < 0 ? 1 : -1, distance: distance, stay: stay) {
            "divider=\(divider.convert(divider.bounds, to: nil)) arranged=\(target.arrangedSubviews.map { "\($0.frame)" })"
        }
        hostingConstraints(in: root).forEach { log("  constraints \($0)") }
    }

    /// `start` 에서 누르고 8ms 마다 1pt 씩 `sign` 방향으로 `distance` 만큼 끈 뒤(끝점에서 2.5초 멈춤) 되돌리거나(`stay` 면 그대로) 뗀다.
    /// 타이머는 추적 런루프 모드에서도 돈다 (NSSplitView 의 mouseDown 추적 루프 안).
    static func drag(window: NSWindow, from startPoint: NSPoint, sign: Double, distance: Double, stay: Bool,
                     progress: @escaping () -> String) async {
        guard let root = window.contentView else { return }
        var offsets: [Double] = []
        for step in stride(from: 1.0, through: distance, by: 1) { offsets.append(step) }
        if !stay { for step in stride(from: distance - 1, through: 0, by: -1) { offsets.append(step) } }
        func post(_ type: NSEvent.EventType, _ point: NSPoint) {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
            NSApp.postEvent(event, atStart: false)
        }
        var index = 0
        var holdUntil: Date?
        // 드래그가 끝날 때(마우스를 뗀 뒤)까지 기다린다 — `;` 로 이은 다음 구분선은 그 뒤에 끈다.
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
        let timer = Timer(timeInterval: 0.008, repeats: true) { timer in
            MainActor.assumeIsolated {
                if let until = holdUntil { if Date() < until { return }; holdUntil = nil }
                guard index < offsets.count else {
                    timer.invalidate()
                    // `stay` 면 끝점에서 뗀다.
                    let last = offsets.last ?? 0
                    post(.leftMouseUp, NSPoint(x: startPoint.x + (stay ? sign * last : 0), y: startPoint.y))
                    log("done alive \(progress())")
                    finished.resume()
                    return
                }
                let offset = offsets[index]
                post(.leftMouseDragged, NSPoint(x: startPoint.x + sign * offset, y: startPoint.y))
                if index % 25 == 0 || offset == distance { log("step \(index) offset=\(offset) \(progress())") }
                // 끝점에서 잠시 멈춘다 (화면을 찍어 실제 배치를 확인할 수 있게).
                if offset == distance {
                    holdUntil = Date().addingTimeInterval(2.5)
                    hostingConstraints(in: root).forEach { log("  constraints \($0)") }
                }
                index += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        post(.leftMouseDown, startPoint)
        }
        // 마우스를 뗀 뒤 배치가 자리잡을 시간을 준다.
        try? await Task.sleep(for: .milliseconds(800))
    }

    /// 칸 호스팅 뷰(NSHostingView)에 SwiftUI 가 건 min/max 제약 상수. 드래그 중 이 값이 바뀌면 제약 갱신 도중 다시 갱신을 요청한다.
    static func hostingConstraints(in root: NSView) -> [String] {
        var lines: [String] = []
        func walk(_ view: NSView, depth: Int) {
            let name = String(describing: type(of: view))
            if name.hasPrefix("NSHostingView") {
                let sizes = view.constraints.filter { [.width, .height].contains($0.firstAttribute) && $0.secondItem == nil }
                    .map { "\($0.firstAttribute == .width ? "w" : "h")\($0.relation == .greaterThanOrEqual ? ">=" : ($0.relation == .lessThanOrEqual ? "<=" : "=="))\(Int($0.constant))" }
                lines.append("\(name.prefix(48)) \(sizes.sorted().joined(separator: " "))")
            }
            view.subviews.forEach { walk($0, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return lines
    }

    static func log(_ text: String) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-preview/sweep.log")
        let line = "\(Date()) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// `-preview.action stream` 의 측정: 0.1초마다 대화 스크롤 뷰의 맨 아래까지 남은 거리를 `ahc-preview/stream.log` 에 적고,
/// `-preview.wheel "3:up,6:down"` 이면 그 초에 휠 한 칸 올림 · 맨 아래까지 내림을 대화 스크롤 뷰에 보낸다 (실제 휠과 같은 길 —
/// NSScrollView 의 scrollWheel, SwiftUI 의 스크롤 단계가 함께 돈다).
enum StreamFollowProbe {
    @MainActor
    static func run() async {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-preview/stream.log")
        try? FileManager.default.removeItem(at: url)
        var wheels: [(at: Double, up: Bool)] = (UserDefaults.standard.string(forKey: "preview.wheel") ?? "")
            .split(separator: ",").compactMap { item in
                let parts = item.split(separator: ":")
                guard parts.count == 2, let at = Double(parts[0]) else { return nil }
                return (at, parts[1] == "up")
            }
        var lines: [String] = []
        let start = Date()
        while Date().timeIntervalSince(start) < 16 {
            try? await Task.sleep(for: .milliseconds(100))
            let elapsed = Date().timeIntervalSince(start)
            guard let scroll = streamScrollView(), let document = scroll.documentView else { continue }
            if let next = wheels.first, elapsed >= next.at {
                wheels.removeFirst()
                // 실제 휠과 같은 차례: 앱의 이벤트 감시(`WheelScroll` · `StreamScrollIntent`)가 먼저 보고, 그다음 스크롤 뷰가 받는다.
                // (합성한 이벤트는 창 안의 자리를 넣을 수 없어 감시를 직접 부른다.)
                guard let window = scroll.window else { continue }
                let center = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
                WheelScroll.widenScrollViews(in: window, at: center)
                for _ in 0..<(next.up ? 1 : 60) {
                    intentViews(in: window.contentView).forEach { $0.wheel(deltaY: next.up ? 1 : -1, at: center, in: window) }
                    let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                     wheel1: next.up ? 1 : -1, wheel2: 0, wheel3: 0)
                    if let cg, let event = NSEvent(cgEvent: cg) { scroll.scrollWheel(with: event) }
                }
                lines.append(String(format: "%.1f wheel %@", elapsed, next.up ? "up" : "down"))
            }
            let distance = document.frame.height - scroll.contentView.bounds.maxY
            lines.append(String(format: "%.1f dist %.0f content %.0f", elapsed, distance, document.frame.height))
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor
    private static func intentViews(in view: NSView?) -> [StreamScrollIntent.ProbeView] {
        guard let view else { return [] }
        return ((view as? StreamScrollIntent.ProbeView).map { [$0] } ?? []) + view.subviews.flatMap { intentViews(in: $0) }
    }

    /// 메인 창에서 가장 넓은 세로 스크롤 뷰 — 인스펙터를 접은 한 칸이면 대화 스트림.
    @MainActor
    private static func streamScrollView() -> NSScrollView? {
        guard let root = MainWindowID.candidates().first(where: { $0.isVisible })?.contentView else { return nil }
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               document.frame.height > scroll.frame.height, scroll.frame.height > 250 { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found.max { $0.frame.width < $1.frame.width }
    }
}
#endif
