import SwiftUI
import AppKit
import SwiftTerm

/// 프로젝트 폴더에서 도는 사용자 셸. 인스펙터 터미널 탭의 `zsh` 하위 탭이 쓴다.
///
/// - 세션은 **프로젝트 폴더마다 하나**이고, 탭을 옮기거나 스레드를 바꿔도 살아 있다.
///   (SwiftUI 뷰는 사라졌다 다시 만들어지므로 뷰 자체를 여기 보관한다.)
/// - **앱은 이 터미널의 입력·출력을 저장하거나 에이전트에게 보내지 않는다.** 사용자의 셸이다.
///   에이전트가 실행한 명령은 같은 탭의 "에이전트 실행" 하위 탭에서 따로 본다.
/// - 앱을 끝낼 때는 `shutdownAll()` 로 자식 셸을 정리한다 (앱이 시작한 프로세스는 앱이 거둔다). 종료 확인 창이 뜨기 **전에** 끄지
///   않는다 — 취소하면 셸이 살아 있어야 한다. 셸에서 명령이 돌면 확인 창이 함께 적는다 (`busySessionCount`).
@MainActor
final class ShellTerminalStore {
    static let shared = ShellTerminalStore()

    private var sessions: [String: LocalProcessTerminalView] = [:]
    private var delegates: [String: ShellTerminalDelegate] = [:]
    /// 뷰의 `terminalDelegate` 는 약한 참조라 여기서 잡아 둔다 (`ShellTerminalLinkGuard`).
    private var linkGuards: [String: ShellTerminalLinkGuard] = [:]

    private init() {}

    /// 이 폴더의 셸 뷰. 없으면 만들고 로그인 셸을 띄운다.
    func view(for directory: String, environment: [String: String]) -> LocalProcessTerminalView {
        if let existing = sessions[directory] { return existing }
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let delegate = ShellTerminalDelegate(directory: directory)
        view.processDelegate = delegate
        // ⌘ 누르고 누른 링크를 앱의 규칙으로 연다 — 셸을 띄우기 전에 바꿔 둔다.
        let linkGuard = ShellTerminalLinkGuard(view: view)
        view.terminalDelegate = linkGuard
        apply(theme: view)

        // 사용자의 로그인 셸을 그대로 띄운다. rc 파일을 읽도록 -l 을 준다.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = environment
        // 셸은 대화형이므로 CLI 용 TERM=dumb 를 쓰지 않는다.
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        // 화면 폭 안내. SwiftTerm 이 크기가 바뀔 때 다시 알려 준다.
        let variables = env.map { "\($0.key)=\($0.value)" }
        view.startProcess(executable: shell, args: ["-l"], environment: variables,
                          execName: (shell as NSString).lastPathComponent,
                          currentDirectory: directory)
        sessions[directory] = view
        delegates[directory] = delegate
        linkGuards[directory] = linkGuard
        return view
    }

    func isRunning(_ directory: String) -> Bool { sessions[directory] != nil }

    /// 셸 안에서 명령(자식 프로세스)이 돌고 있는 세션 수 — 앱 종료 확인 창이 "터미널 탭의 셸 n개에서 도는 명령도 끝납니다" 로 알린다.
    /// 프롬프트만 떠 있는 셸은 세지 않는다. 셸의 자식은 `proc_listchildpids` 로 센다 (읽지 못하면 세지 않는다).
    func busySessionCount() -> Int {
        sessions.values.filter { view in
            guard let pid = view.process?.shellPid, pid > 0 else { return false }
            return Self.childProcessCount(of: pid) > 0
        }.count
    }

    /// 그 프로세스의 바로 아래 자식 수. 0 이면 없거나 읽지 못했다.
    nonisolated static func childProcessCount(of pid: pid_t) -> Int {
        let size = proc_listchildpids(pid, nil, 0)
        guard size > 0 else { return 0 }
        // 읽는 사이 자식이 늘 수 있어 여유를 둔다.
        var buffer = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 8)
        let filled = buffer.withUnsafeMutableBytes { raw in
            proc_listchildpids(pid, raw.baseAddress, Int32(raw.count))
        }
        guard filled > 0 else { return 0 }
        return buffer.prefix(Int(filled)).filter { $0 > 0 }.count
    }

    /// 이 폴더의 셸을 끝낸다 (사용자가 "새로 시작"을 누르거나 프로젝트를 지울 때).
    func close(_ directory: String) {
        guard let view = sessions.removeValue(forKey: directory) else { return }
        delegates[directory] = nil
        linkGuards[directory] = nil
        view.terminate()
    }

    /// 앱 종료 시 정리 — **종료가 확정된 뒤에만** 부른다 (`AppDelegate` 의 `.terminateNow` · `shutDownAndTerminate` 의 끝).
    /// 확인 창에서 취소하면 셸과 그 안의 개발 서버가 그대로 살아 있어야 한다. 정리하지 못한 셸이 있으면 false.
    @discardableResult
    func shutdownAll() -> Bool {
        let all = sessions.keys
        for directory in all { close(directory) }
        return sessions.isEmpty
    }

    private func apply(theme view: LocalProcessTerminalView) {
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = NSColor(Theme.paper)
        view.nativeForegroundColor = NSColor(Theme.ink)
        view.caretColor = NSColor(Theme.claude)
    }
}

/// 셸 세션의 상태 (제목·작업 폴더·종료). 화면 갱신 신호로만 쓴다.
@MainActor
final class ShellTerminalDelegate: LocalProcessTerminalViewDelegate {
    let directory: String
    private(set) var title: String = ""
    private(set) var exitCode: Int32?

    init(directory: String) { self.directory = directory }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in self.title = title }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.exitCode = exitCode
            // 셸이 끝나면 다음에 탭을 열 때 새로 시작하도록 보관 목록에서 뺀다.
            ShellTerminalStore.shared.forget(directory: self.directory)
        }
    }
}

extension ShellTerminalStore {
    /// 프로세스가 스스로 끝났을 때 (`exit`) 보관 목록에서만 제거한다.
    /// 링크 대리자는 남긴다 — 끝난 셸의 화면이 남아 있는 동안에도 지난 출력의 링크를 같은 규칙으로 연다 (다음 셸이 덮어쓴다).
    fileprivate func forget(directory: String) {
        sessions[directory] = nil
        delegates[directory] = nil
    }
}

/// 셸 뷰의 `terminalDelegate` 자리를 대신 받는다 — ⌘ 누르고 누른 링크(OSC 8 하이퍼링크)를 대화 링크와 같은 규칙(`LinkOpener`)으로
/// 열고, 나머지는 뷰에 그대로 넘긴다.
///
/// SwiftTerm 의 기본 `requestOpenLink` 는 어떤 주소든 `NSWorkspace.open` 으로 연다 — 셸에 찍힌 링크의 보이는 글은 `https://…` 인데
/// 가리키는 곳이 `file:///…/x.command` 면 ⌘클릭 한 번에 스크립트가 돌았다 (2026-10-12). 그 기본 구현은 프로토콜 확장에 있어
/// `LocalProcessTerminalView` 의 하위 클래스에 같은 이름의 메서드를 두어도 불리지 않는다 (그 클래스의 준수가 확장의 것을 가리킨다).
/// 그래서 대리자 자리를 이것으로 바꾼다. 뷰가 구현한 것(크기 · 제목 · 작업 폴더 · 입력 보내기 · 스크롤 · 클립보드 · 다시 그린 범위)은
/// 프로토콜을 거쳐 뷰에 그대로 넘기고, 종소리 · iTerm 내용은 뷰와 같이 SwiftTerm 의 기본을 쓴다. 셸의 종료는 이 길이 아니다
/// (`LocalProcess` → 뷰 → `processDelegate`). SwiftTerm 1.10.0 기준 — 버전을 올리면 `TerminalViewDelegate` 의 요구가 늘었는지 본다.
final class ShellTerminalLinkGuard: TerminalViewDelegate {
    /// 원래 대리자 — 뷰 자신 (`LocalProcessTerminalView` 가 만들 때 `terminalDelegate = self` 로 둔다).
    private weak var inner: TerminalViewDelegate?

    init(view: LocalProcessTerminalView) { inner = view }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        inner?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        inner?.setTerminalTitle(source: source, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        inner?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        inner?.send(source: source, data: data)
    }

    func scrolled(source: TerminalView, position: Double) {
        inner?.scrolled(source: source, position: position)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        inner?.clipboardCopy(source: source, content: content)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        inner?.rangeChanged(source: source, startY: startY, endY: endY)
    }

    /// ⌘ 누르고 누른 링크 — 웹 주소만 바로, 파일은 실행하지 않고 Finder 에서, 그 밖의 스킴은 주소를 보이고 확인받는다.
    /// 마우스 이벤트(`mouseUp`)에서 오므로 메인 스레드다.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        MainActor.assumeIsolated { LinkOpener.openTerminalLink(link, window: source.window) }
    }
}

/// SwiftTerm 뷰를 담는 상자. SwiftUI 에는 고유 크기가 없다고 알리고, 크기 조정이 잠잠해진 뒤에 터미널을 맞춘다.
///
/// - 인스펙터 칸(NSSplitView)의 디바이더를 끌면 SwiftUI 가 제약 갱신 도중 이 뷰의 최소·최대 크기를 다시 묻는다.
///   터미널 뷰를 그대로 얹으면 그 값이 폭에 따라 달라져 갱신 중에 다시 갱신을 요청하게 되고,
///   macOS 26 AppKit 은 이를 NSInternalInconsistencyException 으로 끝낸다 (2026-09-12 크래시).
///   상자는 항상 같은 답(고유 크기 없음)을 주므로 갱신이 꼬리를 물지 않는다.
/// - 터미널 크기가 바뀔 때마다 SwiftTerm 은 셸에 SIGWINCH 를 보내고 zsh 는 프롬프트를 다시 그린다.
///   디바이더를 끄는 동안 한 픽셀마다 이 일이 일어나면 프롬프트가 수십 줄 쌓이므로, 마우스를 누르고
///   있거나 창을 늘리는 중에는 기다렸다가 잠잠해진 뒤 한 번만 맞춘다. 그 밖(탭 전환·인스펙터 열기)은 즉시.
final class ShellTerminalHostView: NSView {
    /// 크기 조정이 이만큼 잠잠해지면 터미널에 새 크기를 알린다.
    private static let settleDelay: TimeInterval = 0.15
    private weak var terminal: LocalProcessTerminalView?
    private var pendingFit: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// 아직 맞추지 않은 터미널은 왼쪽 위에 붙여 둔다.
    override var isFlipped: Bool { true }

    func embed(_ terminal: LocalProcessTerminalView) {
        guard terminal.superview !== self else { return }
        terminal.removeFromSuperview()
        terminal.autoresizingMask = []
        terminal.frame = bounds
        addSubview(terminal)
        self.terminal = terminal
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let terminal, terminal.frame.size != bounds.size else { return }
        let resizing = (NSEvent.pressedMouseButtons & 1) != 0 || (window?.inLiveResize ?? false)
        if resizing {
            pendingFit?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.fitTerminal() }
            pendingFit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
        } else {
            fitTerminal()
        }
    }

    private func fitTerminal() {
        pendingFit?.cancel()
        pendingFit = nil
        terminal?.frame = bounds
    }
}

/// SwiftUI 에 얹는 셸 터미널.
struct ShellTerminalView: NSViewRepresentable {
    let directory: String
    let environment: [String: String]

    func makeNSView(context: Context) -> ShellTerminalHostView {
        let host = ShellTerminalHostView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        host.embed(ShellTerminalStore.shared.view(for: directory, environment: environment))
        return host
    }

    func updateNSView(_ nsView: ShellTerminalHostView, context: Context) {
        nsView.embed(ShellTerminalStore.shared.view(for: directory, environment: environment))
    }

    /// 제안받은 크기를 그대로 쓴다. AppKit 의 fittingSize 계산(제약 엔진)을 타지 않아 갱신 중에도 답이 일정하다.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShellTerminalHostView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 640, height: proposal.height ?? 400)
    }
}
