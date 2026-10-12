import Foundation

/// 인스펙터 탭. 같은 자리의 내용을 바꾼다.
///
/// 값은 `@AppStorage(WindowStateKey.inspectorTab)` 와 실행 인수 `-inspector.tab` 으로 저장·복원된다.
/// 예전 "브랜치" 탭은 "변경사항" 탭이 됐다. 저장돼 있던 옛 값 `branch` 도 변경사항 탭으로 읽는다
/// (`@AppStorage` 는 `init?(rawValue:)` 로 읽으므로 여기서 받아 준다).
///
/// SwiftUI 에 의존하지 않아 검증 하네스(`scripts/build-inttest.sh`)에서도 컴파일된다.
enum InspectorTab: String, CaseIterable, Identifiable {
    /// `agents`: 포커스 대화의 실행이 띄운 하위 에이전트 · 워크플로 · 백그라운드 명령의 흐름 (읽기 전용).
    case terminal, files, pullRequest, changes, agents

    init?(rawValue: String) {
        switch rawValue {
        case "terminal": self = .terminal
        case "files": self = .files
        case "pullRequest": self = .pullRequest
        // "branch" 는 1단계 이전의 브랜치 탭 값이다.
        case "changes", "branch": self = .changes
        case "agents": self = .agents
        default: return nil
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: return "터미널"
        case .files: return "파일"
        case .pullRequest: return "Pull Request"
        case .changes: return "변경사항"
        case .agents: return "에이전트"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: return "terminal"
        case .files: return "folder"
        case .pullRequest: return "arrow.triangle.pull"
        // 문서 + 플러스 (목업의 changes 아이콘과 같은 뜻). macOS 11 부터 있는 이름.
        case .changes: return "doc.badge.plus"
        case .agents: return "person.2"
        }
    }

    /// ⌘⌥ 와 함께 쓰는 숫자 키.
    var shortcut: Character {
        switch self {
        case .terminal: return "1"
        case .files: return "2"
        case .pullRequest: return "3"
        case .changes: return "4"
        case .agents: return "5"
        }
    }
}

/// 창 상태 중 메뉴 명령과 공유하는 값.
enum WindowStateKey {
    static let inspectorVisible = "inspector.visible"
    /// 저장값이 없을 때 인스펙터를 보일지. 닫아 둔다 — 대화가 먼저고, 변경은 툴바의 "변경 N" · 실행 카드 · ⌥⌘4 로 연다.
    /// `@AppStorage(inspectorVisible)` 을 두는 곳마다 이 값을 기본값으로 쓴다 (다르면 처음 읽을 때 화면마다 다르게 보인다).
    static let inspectorVisibleByDefault = false
    static let inspectorTab = "inspector.tab"
    static let pane = "window.pane"
    /// 크게 보기의 통합 / 나란히 선택 (`DiffRows.Mode` rawValue).
    static let diffWideMode = "diff.wideMode"
    /// 사이드바 너비 (사용자가 구분선을 끌어 정한 값). 보일 때는 창에 맞춰 `PanelFit.sidebarLimit` 까지로 줄여 쓴다.
    static let sidebarWidth = "sidebar.width"
}

/// 가운데 칸 (`ContentView.Pane`). 값은 `@AppStorage(WindowStateKey.pane)` 와 실행 인수 `-window.pane` 으로 저장·복원된다.
///
/// 대화와 "에이전트 기록"(코드 이름은 scoreboard — 예전 화면 이름 "전적")은 보기 메뉴(⇧⌘B) · 툴바 ⋯ · 사이드바 아래 단추로 오간다
/// (`togglingScoreboard`).
/// `review`(크게 보기)는 변경사항 탭의 "크게 보기" 로만 들어간다 — 앱이 이번 실행에서 연 diff 가 있을 때만 보인다(`shown`).
/// 저장값이나 실행 인수로 `review` 가 와도 대화로 연다(`restored`).
/// SwiftUI 에 의존하지 않아 검증 하네스에서도 컴파일된다.
enum WindowPane: String, CaseIterable, Identifiable {
    case conversation
    case scoreboard
    case review
    /// 에이전트 현황 — 지금 도는 실행 · 답을 기다리는 것을 한 화면에 (`UI/OverviewView.swift`, 판정은 `Overview`).
    case overview

    /// 저장값은 식별자다 — 화면 글(`title`)을 번역해도 저장값이 깨지지 않게. 예전에는 한국어 표시 글을 그대로 저장했으므로
    /// 옛 저장값과 실행 인수(`-window.pane 대화` — 화면 확인 스크립트)도 받는다.
    init?(rawValue: String) {
        switch rawValue {
        case "conversation", "대화": self = .conversation
        case "scoreboard", "전적": self = .scoreboard
        case "review", "크게 보기": self = .review
        case "overview", "현황": self = .overview
        default: return nil
        }
    }

    var id: String { rawValue }

    /// 에이전트 기록을 여닫는 항목(보기 메뉴 ⇧⌘B · 툴바 ⋯ · 사이드바 아래 단추)이 누른 뒤 보일 칸 — 기록이면 대화로, 아니면 기록.
    /// 크게 보기 중이면 크게 보기를 닫고 기록으로 간다 (부르는 쪽이 diff 를 닫는다).
    static func togglingScoreboard(shown: WindowPane) -> WindowPane {
        shown == .scoreboard ? .conversation : .scoreboard
    }

    /// 그 항목의 글 (메뉴 · 툴바 ⋯ · 사이드바 단추 · 접근성 이름이 같이 쓴다).
    static func scoreboardToggleTitle(shown: WindowPane) -> String {
        shown == .scoreboard ? "대화로 돌아가기" : scoreboardTitle
    }

    /// 에이전트 기록 화면의 이름 (화면 머리 · 메뉴). 저장값(`scoreboard`)과 따로다.
    static let scoreboardTitle = "에이전트 기록"

    /// 현황을 여닫는 항목(보기 메뉴 ⌃⌘0 · 툴바 ⋯ · 사이드바 맨 위 행)이 누른 뒤 보일 칸 — 현황이면 대화로, 아니면 현황.
    static func togglingOverview(shown: WindowPane) -> WindowPane {
        shown == .overview ? .conversation : .overview
    }

    /// 그 항목의 글.
    static func overviewToggleTitle(shown: WindowPane) -> String {
        shown == .overview ? "대화로 돌아가기" : overviewTitle
    }

    /// 현황 화면의 이름 (화면 머리 · 메뉴 · 사이드바 행). 저장값(`overview`)과 따로다.
    static let overviewTitle = "현황"

    /// 저장값 · 실행 인수로 되살릴 칸. 크게 보기는 되살리지 않는다 (볼 파일이 앱을 다시 열 때 없다).
    static func restored(_ stored: WindowPane) -> WindowPane {
        stored == .review ? .conversation : stored
    }

    /// 지금 가운데에 보일 칸. 크게 보기는 이번 실행에서 연 diff 가 있을 때(`reviewing`)만.
    static func shown(stored: WindowPane, reviewing: Bool) -> WindowPane {
        reviewing ? .review : restored(stored)
    }
}

/// 창이 좁을 때 보조 패널(사이드바 · 인스펙터) 하나를 접고, 공간이 돌아오면 다시 펴는 순수 판정 (`ContentView.fitPanels`),
/// 그리고 사이드바 · 인스펙터가 가질 수 있는 최대 너비.
///
/// 너비는 **창의 실제 내용 폭**(`NSWindow.contentLayoutRect`)이어야 한다. 칸들이 창보다 넓게 요구되면 SwiftUI 뷰의
/// geometry 는 창이 아니라 그 요구만큼 커진다 (2026-09-14 실측: 창 1000 · 뷰 1296). 그 값으로 재면 "공간이 있다"고
/// 오판해 방금 접은 패널을 곧바로 다시 펴고, 세 칸이 창 양 끝으로 잘린 채 남는다.
///
/// 배치 (2026-09-28 부터): 사이드바는 `ContentView` 가 직접 그리는 칸(+ 1pt 구분선)이고, 본문과 함께 인스펙터 스플릿의 왼쪽 칸에 든다.
/// 그래서 세 칸이 들어가는 창 너비는 칸 최소의 합(사이드바 200 + 선 1 + 본문 460 + 인스펙터 400)이다.
/// 예전 NavigationSplitView 의 떠 있는 사이드바는 본문 칸의 최소 폭에 사이드바를 두 번 더해(macOS 26 실측) 1276 이 필요했다.
/// 인스펙터 스플릿의 왼쪽 칸 최소 폭(사이드바 + 선 + 본문)과 인스펙터 너비의 합이 창을 넘으면 AppKit 이 제약을 깨고 다시 배치하며
/// 제약 갱신이 꼬리를 물어 macOS 26 이 앱을 끝낸다 (2026-09-14 크래시) — 두 상한은 그 합이 창을
/// 넘지 않게 하는 역산이다. SwiftUI 에 의존하지 않아 검증 하네스에서도 컴파일된다.
enum PanelFit {
    enum Panel: Equatable, Sendable { case sidebar, inspector }

    /// 칸 최소 너비. 앱의 값은 `app` 하나뿐이며 `ContentView` 의 칸 제약도 이 값을 쓴다.
    struct Metrics: Equatable, Sendable {
        /// 사이드바 최소.
        var sidebar: CGFloat
        /// 사이드바와 본문 사이의 구분선.
        var divider: CGFloat
        /// 본문(대화 · 전적 · 크게 보기) 최소.
        var detail: CGFloat
        /// 인스펙터 최소.
        var inspector: CGFloat
        /// 실측에서 더 필요했던 여유.
        var slack: CGFloat

        static let app = Metrics(sidebar: 200, divider: 1, detail: 460, inspector: 400, slack: 0)
    }

    enum Change: Equatable, Sendable {
        /// 창이 좁아 이 패널을 접는다 (앱이 접은 것으로 기억해 두었다가 공간이 돌아오면 다시 편다).
        case hide(Panel)
        /// 공간이 돌아와 앱이 접었던 패널을 다시 편다.
        case show(Panel)
    }

    /// 보이는 패널들이 창에 들어가는 데 필요한 창 내용 폭 (사이드바는 최소 너비로 — 넓게 끌어 둔 사이드바는 창에 맞춰 줄어든다).
    static func requiredWidth(sidebar: Bool, inspector: Bool, metrics: Metrics = .app) -> CGFloat {
        let detail = metrics.detail + (inspector ? metrics.inspector : 0)
        let sidebarColumn = sidebar ? metrics.sidebar + metrics.divider : 0
        return detail + sidebarColumn + metrics.slack
    }

    /// 이 창 너비에서 사이드바가 가질 수 있는 최대 너비 (내림). 인스펙터는 **최소** 너비로 넣는다 — 실제 너비를 되먹이면 사이드바 상한 →
    /// 인스펙터 너비 → 사이드바 상한이 맞물려 배치가 끝나지 않는다. 사이드바를 한계까지 넓히면 인스펙터가 최소까지 줄어드는 것으로 끝난다.
    /// 창이 좁으면 최소보다 작게 나올 수 있다 — 호출하는 쪽이 최소로 막는다 (그 창에서는 `adjustment` 가 한쪽을 접는다).
    static func sidebarLimit(windowWidth: CGFloat, inspector: Bool, metrics: Metrics = .app) -> CGFloat {
        let detail = metrics.detail + (inspector ? metrics.inspector : 0)
        return (windowWidth - metrics.slack - detail - metrics.divider).rounded(.down)
    }

    /// 이 창 너비와 **사이드바 칸의 실제 너비**(사이드바 + 구분선)에서 인스펙터가 가질 수 있는 최대 너비 (내림).
    /// 사이드바가 접혀 있으면 사이드바 칸은 0, 너비를 모르면 최소 칸으로 본다.
    /// 창이 좁으면 인스펙터 최소보다 작게 나올 수 있다 — 호출하는 쪽이 최소로 막는다.
    static func inspectorLimit(windowWidth: CGFloat, sidebarColumnWidth: CGFloat?, sidebarVisible: Bool,
                               metrics: Metrics = .app) -> CGFloat {
        let sidebarColumn = sidebarVisible ? (sidebarColumnWidth ?? (metrics.sidebar + metrics.divider)) : 0
        return (windowWidth - metrics.slack - metrics.detail - sidebarColumn).rounded(.down)
    }

    /// 툴바의 대화 제목을 본문 칸 위에 맞추려고 제목 앞에 둘 여백. `itemX` 는 제목 항목의 창 x (툴바가 신호등 · 사이드바 버튼 뒤에 놓은 자리),
    /// 사이드바가 보이면 제목이 본문 왼쪽 선(사이드바 칸 + `contentInset`)에서 시작하게 그만큼 민다. 모르면(아직 안 잼) 여백 없이.
    static func toolbarTitleLead(sidebarVisible: Bool, sidebarColumnWidth: CGFloat, itemX: CGFloat?,
                                 contentInset: CGFloat = 16, minimum: CGFloat = 8) -> CGFloat {
        guard sidebarVisible, let itemX else { return minimum }
        return max(minimum, (sidebarColumnWidth + contentInset - itemX).rounded())
    }

    /// 지금 상태에서 할 일. `autoHidden` 은 앱이 접어 둔 패널 (사용자가 직접 닫은 패널은 다시 펴지 않는다),
    /// `lastOpened` 는 사용자가 마지막으로 연 쪽 (그쪽을 남기고 다른 쪽을 접는다). 창 폭을 모르면(0) 아무것도 하지 않는다.
    static func adjustment(windowWidth: CGFloat, sidebar: Bool, inspector: Bool, autoHidden: Panel?, lastOpened: Panel,
                           metrics: Metrics = .app) -> Change? {
        guard windowWidth > 0 else { return nil }
        if let hidden = autoHidden {
            // 공간이 돌아오면 접었던 패널을 다시 편다. 사용자가 그 사이 다른 패널을 닫았으면 그만큼 일찍 돌아온다.
            let fits = windowWidth >= requiredWidth(sidebar: sidebar || hidden == .sidebar,
                                                    inspector: inspector || hidden == .inspector, metrics: metrics)
            return fits ? .show(hidden) : nil
        }
        guard sidebar, inspector, windowWidth < requiredWidth(sidebar: true, inspector: true, metrics: metrics) else { return nil }
        return .hide(lastOpened == .sidebar ? .inspector : .sidebar)
    }

    /// 앱이 패널을 접었을 때 한 번 알리는 글 — 말없이 사라지면 결함처럼 보인다. 무엇을 접었고 어떻게 돌아오는지.
    static func autoHideNotice(_ panel: Panel) -> String {
        switch panel {
        case .sidebar: return "창이 좁아 사이드바를 접었습니다 — 창을 넓히면 다시 펼칩니다. 지금 보려면 ⌃⌘S (인스펙터가 접힙니다)."
        case .inspector: return "창이 좁아 인스펙터를 접었습니다 — 창을 넓히면 다시 펼칩니다. 지금 보려면 ⌥⌘0 (사이드바가 접힙니다)."
        }
    }

    /// 앱이 접어 둔 패널의 여닫기 단추 도움말 (툴바의 사이드바 · 인스펙터 단추).
    static func autoHiddenHelp(_ panel: Panel) -> String {
        switch panel {
        case .sidebar: return "창이 좁아 사이드바를 접었습니다 — 창을 넓히면 다시 펼칩니다 (⌃⌘S)"
        case .inspector: return "창이 좁아 인스펙터를 접었습니다 — 창을 넓히면 다시 펼칩니다 (⌥⌘0)"
        }
    }
}

/// 파일 diff 가 보일 때의 키 (좁은 패널 · 크게 보기). 메뉴 명령이 아니라 diff 의 키 받는 뷰(`DiffKeyCatcher`)가
/// **첫 응답자일 때만** 받는다 — 커밋 메시지 · 찾기 칸 · 입력창 · 터미널에 포커스가 있으면 키는 그쪽으로 가고 여기 오지 않는다
/// (AppKit 의 keyDown 은 첫 응답자에게만 간다). 파일을 눌러 열거나 diff 를 누르면 그 뷰가 첫 응답자가 된다.
enum DiffKeyCommand: Equatable, Sendable {
    /// esc — 좁은 패널은 목록으로, 크게 보기는 대화로.
    case back
    /// ⌥↑ · ⌥↓ — 목록에 보이는 순서로 이전 · 다음 파일.
    case previousFile, nextFile
    /// space — "커밋에 포함" (목록 체크박스와 같은 stage / unstage).
    case toggleInclusion

    enum Key: Equatable, Sendable {
        case escape, upArrow, downArrow, space, other
    }

    /// 수식키가 정확히 맞을 때만 (⌘↑ · ⇧space · ⌥⇧↓ 는 받지 않는다 — 다른 동작의 몫).
    static func command(for key: Key, modifiers: Set<MenuShortcut.Modifier>) -> DiffKeyCommand? {
        switch (key, modifiers) {
        case (.escape, []): return .back
        case (.upArrow, [.option]): return .previousFile
        case (.downArrow, [.option]): return .nextFile
        case (.space, []): return .toggleInclusion
        default: return nil
        }
    }

    /// NSEvent 의 `charactersIgnoringModifiers` → 키. (화살표는 AppKit 의 기능 키 글자 U+F700 · U+F701.)
    static func key(characters: String?, keyCode: UInt16) -> Key {
        if keyCode == 53 { return .escape }
        switch characters {
        case "\u{F700}": return .upArrow
        case "\u{F701}": return .downArrow
        case " ": return .space
        case "\u{1B}": return .escape
        default: return .other
        }
    }
}

/// 앱 메뉴 명령의 단축키 표. 메뉴(`AgentHandoffConsoleApp`)가 이 값을 그대로 걸고, 검증 하네스가 겹침을 확인한다
/// (`inttest offline` "메뉴 단축키"). SwiftUI 에 의존하지 않는다 — 키 · 수식키 변환은 UI 쪽 확장(`menuShortcut`)이 한다.
struct MenuShortcut: Hashable, Sendable {
    enum Modifier: String, Hashable, Sendable, CaseIterable {
        case control, option, shift, command
    }

    let title: String
    let key: Character
    let modifiers: Set<Modifier>

    /// 사람이 읽는 표기 (macOS 순서 ⌃ ⌥ ⇧ ⌘, 글자는 대문자): "⇧⌘N".
    var symbol: String {
        let marks: [Modifier: String] = [.control: "⌃", .option: "⌥", .shift: "⇧", .command: "⌘"]
        let names: [Character: String] = ["\r": "↵", "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
                                          " ": "space", "\u{1B}": "esc", "\u{8}": "⌫"]
        let keyText = names[key] ?? String(key).uppercased()
        return Modifier.allCases.filter(modifiers.contains).compactMap { marks[$0] }.joined() + keyText
    }

    /// 같은 키 · 같은 수식키인지 (글자는 대소문자를 가리지 않는다 — Shift 는 수식키로 따로 센다).
    func collides(with other: MenuShortcut) -> Bool {
        String(key).lowercased() == String(other.key).lowercased() && modifiers == other.modifiers
    }

    /// 프로젝트가 없으면 폴더 고르기로 이어진다 (첫 대화는 폴더를 연 뒤에 생긴다).
    static let newThread = MenuShortcut(title: "새 대화", key: "n", modifiers: [.command])
    static let newBranch = MenuShortcut(title: "새 브랜치 만들기…", key: "n", modifiers: [.command, .shift])
    /// 파일 메뉴 — 같은 폴더면 그 프로젝트를, 새 폴더면 첫 대화까지 연다 (`ProjectFolderPicker`).
    static let openProjectFolder = MenuShortcut(title: "프로젝트 폴더 열기…", key: "o", modifiers: [.command])
    /// 포커스 칸의 대화 안에서 찾기 (찾기 막대 — `ThreadFind`). 다음 · 이전은 ⌘G · ⇧⌘G (macOS 의 찾기와 같은 키).
    static let findInConversation = MenuShortcut(title: "대화에서 찾기…", key: "f", modifiers: [.command])
    static let findNext = MenuShortcut(title: "다음 찾기", key: "g", modifiers: [.command])
    static let findPrevious = MenuShortcut(title: "이전 찾기", key: "g", modifiers: [.command, .shift])
    /// 사이드바의 대화 목록 검색 (제목 · 목표). 사이드바가 숨어 있으면 보이고 검색칸으로 간다.
    static let threadSearch = MenuShortcut(title: "대화 목록 검색", key: "f", modifiers: [.command, .option])
    static let changesSearch = MenuShortcut(title: "변경 파일 찾기", key: "f", modifiers: [.command, .shift])
    static let fileSearch = MenuShortcut(title: "파일 찾기", key: "p", modifiers: [.command])
    static let toggleInspector = MenuShortcut(title: "인스펙터 보기/숨기기", key: "0", modifiers: [.command, .option])
    /// macOS 의 사이드바 보기/숨기기와 같은 키. 사이드바를 앱이 직접 그리므로 앱이 건다 (`CommandGroup(replacing: .sidebar)`).
    static let toggleSidebar = MenuShortcut(title: "사이드바 보기/숨기기", key: "s", modifiers: [.command, .control])
    static let refreshLimits = MenuShortcut(title: "한도 새로고침", key: "r", modifiers: [.command, .shift])
    static let interrupt = MenuShortcut(title: "실행 중단", key: ".", modifiers: [.command])
    /// 카드가 없으면 만들고, 있으면(준비 · 전달 중 포함) 그 카드로 간다 — 두 경우를 함께 덮는 이름 (메뉴바와 같다).
    static let handoff = MenuShortcut(title: "인계 카드 열기", key: "h", modifiers: [.command, .shift])
    /// 가운데 칸을 에이전트 기록 ↔ 대화로 (보기 메뉴 · 툴바 ⋯ · 사이드바 아래 단추).
    static let scoreboard = MenuShortcut(title: WindowPane.scoreboardTitle, key: "b", modifiers: [.command, .shift])
    /// 가운데 칸을 현황 ↔ 대화로 (보기 메뉴 · 툴바 ⋯ · 사이드바 맨 위 행). 분할(⌃⌘1 · 2 · 4) 옆의 0 — "모든 칸".
    static let overview = MenuShortcut(title: WindowPane.overviewTitle, key: "0", modifiers: [.command, .control])
    /// 도움말 메뉴 — 이 앱 소개 (macOS 도움말 항목의 키 ⌘?).
    static let appGuide = MenuShortcut(title: "이 앱 소개", key: "?", modifiers: [.command])
    /// 도움말 메뉴 — 키보드 단축키 시트 (`helpSections`). 단축키는 없다.
    static let keyboardShortcutsTitle = "키보드 단축키"
    /// 포커스 칸의 맨 앞 승인 카드를 허용 (승인은 없고 질문만 있으면 그 질문의 답 보내기). 카드의 단추와 같은 막음을 거친다
    /// (`ApprovalCardGate` — 카드가 막 나타났으면 받지 않는다). 입력창의 ⌘↵(보내기)와 겹치지 않게 ⌥ 를 더한다.
    static let approvalAllow = MenuShortcut(title: "승인 요청 허용", key: "\r", modifiers: [.command, .option])
    /// 포커스 칸의 맨 앞 승인 카드를 거절 (사유 칸에 적은 글을 함께). 글 칸의 ⌘⌫(줄 앞까지 지우기)와 겹치지 않게 ⌥ 를 더한다.
    static let approvalDeny = MenuShortcut(title: "승인 요청 거절", key: "\u{8}", modifiers: [.command, .option])

    static func inspectorTab(_ tab: InspectorTab) -> MenuShortcut {
        MenuShortcut(title: tab.title, key: tab.shortcut, modifiers: [.command, .option])
    }

    /// 분할 화면 — 칸 수의 숫자 (⌃⌘1 한 칸 · ⌃⌘2 두 칸 · ⌃⌘4 네 칸).
    static func paneLayout(_ layout: PaneLayout) -> MenuShortcut {
        MenuShortcut(title: layout.title, key: Character(String(layout.paneCount)), modifiers: [.command, .control])
    }

    /// 앱이 메뉴에 거는 단축키 전부.
    static var appMenu: [MenuShortcut] {
        [newThread, newBranch, openProjectFolder, findInConversation, findNext, findPrevious, threadSearch, changesSearch, fileSearch,
         toggleSidebar, toggleInspector, refreshLimits, interrupt, handoff, scoreboard, overview, appGuide, approvalAllow, approvalDeny]
            + InspectorTab.allCases.map(inspectorTab) + PaneLayout.allCases.map(paneLayout)
    }

    /// 도움말 > 키보드 단축키 시트의 한 묶음.
    struct HelpSection: Identifiable, Sendable {
        let title: String
        let items: [MenuShortcut]
        var id: String { title }
    }

    /// 도움말 > 키보드 단축키 시트의 묶음. 앱 메뉴의 단축키는 모두 꼭 한 번 들어간다 (검증 하네스 "메뉴 단축키").
    static var helpSections: [HelpSection] {
        let view: [MenuShortcut] = [toggleSidebar, toggleInspector, overview, scoreboard] + PaneLayout.allCases.map(paneLayout)
        let inScreen: [MenuShortcut] = inView + findBar
        return [HelpSection(title: "대화", items: [newThread, openProjectFolder, interrupt, handoff, refreshLimits, approvalAllow, approvalDeny]),
                HelpSection(title: "찾기", items: [findInConversation, findNext, findPrevious, threadSearch, changesSearch, fileSearch]),
                HelpSection(title: "보기", items: view),
                HelpSection(title: "인스펙터 탭", items: InspectorTab.allCases.map(inspectorTab)),
                HelpSection(title: "변경사항", items: [newBranch]),
                HelpSection(title: "도움말", items: [appGuide]),
                HelpSection(title: "화면 안에서", items: inScreen)]
    }

    /// 대화 안 찾기 막대의 칸에 포커스가 있을 때만 받는 키 (메뉴 명령이 아니다 — 겹침 검사에 넣지 않는다: esc 는 diff 의 esc 와
    /// 같은 키지만 받는 곳이 다르다). 단축키 시트에만 보인다.
    static let findBar: [MenuShortcut] = [
        MenuShortcut(title: "찾기 막대: 다음", key: "\r", modifiers: []),
        MenuShortcut(title: "찾기 막대: 이전", key: "\r", modifiers: [.shift]),
        MenuShortcut(title: "찾기 막대: 닫기", key: "\u{1B}", modifiers: []),
    ]

    /// macOS · SwiftUI 기본 메뉴(앱 · 편집 · 보기 · 윈도우)가 쓰는 단축키. 앱 단축키가 이것과 겹치면 안 된다.
    static let system: [MenuShortcut] = [
        MenuShortcut(title: "설정", key: ",", modifiers: [.command]),
        MenuShortcut(title: "종료", key: "q", modifiers: [.command]),
        MenuShortcut(title: "가리기", key: "h", modifiers: [.command]),
        MenuShortcut(title: "기타 가리기", key: "h", modifiers: [.command, .option]),
        MenuShortcut(title: "창 닫기", key: "w", modifiers: [.command]),
        MenuShortcut(title: "최소화", key: "m", modifiers: [.command]),
        MenuShortcut(title: "실행 취소", key: "z", modifiers: [.command]),
        MenuShortcut(title: "실행 복귀", key: "z", modifiers: [.command, .shift]),
        MenuShortcut(title: "오려두기", key: "x", modifiers: [.command]),
        MenuShortcut(title: "복사하기", key: "c", modifiers: [.command]),
        MenuShortcut(title: "붙여넣기", key: "v", modifiers: [.command]),
        MenuShortcut(title: "전체 선택", key: "a", modifiers: [.command]),
        MenuShortcut(title: "전체 화면", key: "f", modifiers: [.command, .control]),
    ]

    /// 화면 안에서 거는 단축키 (메뉴 명령이 아니다). ⌘↵ 는 입력창의 보내기와 커밋 칸 · 인계 카드가
    /// `ChangesState.returnKeyOwner` 로 한 번에 하나만 갖는다. 파일 diff 의 키(`DiffKeyCommand`)는 diff 의 키 받는 뷰가
    /// 첫 응답자일 때만 받는다 — 텍스트 입력에 포커스가 있으면 그쪽으로 간다. 추론 강도 ↑ ↓ (← → 도) 는 모델 칩 팝오버의 강도
    /// 목록에 포커스가 있을 때만 받는다 (`ModelPicker`).
    static let inView: [MenuShortcut] = [
        MenuShortcut(title: "보내기 · 커밋", key: "\r", modifiers: [.command]),
        MenuShortcut(title: "diff: 목록으로 · 대화로", key: "\u{1B}", modifiers: []),
        MenuShortcut(title: "diff: 이전 파일", key: "\u{F700}", modifiers: [.option]),
        MenuShortcut(title: "diff: 다음 파일", key: "\u{F701}", modifiers: [.option]),
        MenuShortcut(title: "diff: 커밋에 포함 전환", key: " ", modifiers: []),
        MenuShortcut(title: "추론 강도: 한 단계 낮춤", key: "\u{F700}", modifiers: []),
        MenuShortcut(title: "추론 강도: 한 단계 높임", key: "\u{F701}", modifiers: []),
    ]

    /// 같은 키 · 수식키를 둘 이상이 쓰는 묶음 (비어 있어야 한다).
    static func conflicts(_ list: [MenuShortcut]) -> [[MenuShortcut]] {
        var groups: [[MenuShortcut]] = []
        for shortcut in list {
            if let index = groups.firstIndex(where: { $0[0].collides(with: shortcut) }) {
                groups[index].append(shortcut)
            } else {
                groups.append([shortcut])
            }
        }
        return groups.filter { $0.count > 1 }
    }
}

// MARK: - 분할 화면 (대화 칸)

/// 가운데 칸을 몇 개의 대화 칸으로 나눌지. 칸마다 다른 대화를 열고, 실행은 대화마다 따로 돈다.
/// 인스펙터는 하나이고 포커스 칸을 따라간다. SwiftUI 에 의존하지 않아 검증 하네스에서도 컴파일된다.
enum PaneLayout: String, CaseIterable, Identifiable, Sendable {
    case single, twoColumns, fourGrid

    var id: String { rawValue }
    var paneCount: Int {
        switch self {
        case .single: return 1
        case .twoColumns: return 2
        case .fourGrid: return 4
        }
    }
    /// 한 줄에 놓이는 칸 수 (4칸은 2 × 2).
    var columns: Int { self == .single ? 1 : 2 }
    /// 칸마다 한 번에 그리는 최근 행 수 (더 오래된 행은 맨 위 버튼으로 이만큼씩 더 불러온다).
    /// 대화 스트림은 지연 없이 다 그리므로 칸 폭이 바뀔 때마다 그린 메시지 전부를 다시 배치한다 — 칸이 작을수록 적게 그린다
    /// (2026-09-29 실측, 가장 큰 대화 넷을 네 칸에 열 때: 칸마다 80행이면 CPU 12.7초, 24행이면 4.2초).
    var streamRowPage: Int {
        switch self {
        case .single: return 80
        case .twoColumns: return 40
        case .fourGrid: return 24
        }
    }
    var title: String {
        switch self {
        case .single: return "한 칸"
        case .twoColumns: return "두 칸 (좌우)"
        case .fourGrid: return "네 칸 (2 × 2)"
        }
    }
    var systemImage: String {
        switch self {
        case .single: return "rectangle"
        case .twoColumns: return "rectangle.split.2x1"
        case .fourGrid: return "rectangle.split.2x2"
        }
    }
    /// 한 단계 큰 분할 (빈 칸이 없을 때 "새 칸에서 열기" 가 키운다). 가장 크면 nil.
    var larger: PaneLayout? {
        switch self {
        case .single: return .twoColumns
        case .twoColumns: return .fourGrid
        case .fourGrid: return nil
        }
    }
}

/// 칸 배치 상태: 분할 · 칸마다의 대화(빈 칸은 nil) · 포커스 칸. 값 형식이고 규칙은 모두 여기 있다 (오프라인 검증).
struct PaneArrangement: Equatable, Sendable {
    var layout: PaneLayout = .single
    /// 길이는 늘 `layout.paneCount`.
    var threadIDs: [String?] = [nil]
    var focused = 0
    /// 분할을 줄이기 전의 (가장 큰) 배치 — 다시 늘리면 이 자리로 되살린다 (⌃⌘1 로 줄였다 ⌃⌘4 로 늘려도 네 칸이 돌아온다).
    /// 길이는 그 분할의 칸 수, 비어 있으면 기억이 없다. 설정 `pane_memory` 에 저장한다 (`AppModel.syncPanes`).
    var remembered: [String?] = []
    /// `remembered` 에서 포커스였던 칸 — 줄인 칸에 새로 연 대화는 늘릴 때 이 자리로 돌아간다.
    var rememberedFocus = 0
    /// 그 배치를 기억한 때. `rememberLifetime` 이 지난 기억은 되살리지 않는다 — 오래전에 줄인 배치가 지금 쓰지 않는 대화를 데려와
    /// 빈 칸을 막았다 (chr-3). 시각이 없는 옛 저장값도 되살리지 않는다.
    var rememberedAt: Date?

    /// 줄였다 다시 늘릴 때 앞의 배치를 되살리는 시간.
    static let rememberLifetime: TimeInterval = 30 * 60

    /// 지금(`now`) 되살릴 수 있는 기억인가.
    func remembersLayout(at now: Date) -> Bool {
        guard !remembered.isEmpty, let rememberedAt else { return false }
        return now.timeIntervalSince(rememberedAt) <= Self.rememberLifetime
    }

    var focusedThreadID: String? { threadIDs.indices.contains(focused) ? threadIDs[focused] : nil }

    init() {}

    /// 저장값에서 되살린다. 없어진 대화는 빈 칸으로, 칸 수는 분할에 맞추고, 포커스는 칸 수 안으로. 같은 대화가 두 칸에 있으면
    /// 앞의 것만 남긴다 (한 대화의 입력창 · 실행은 하나다). 기억해 둔 배치도 같은 규칙으로 거른다 (칸 수는 그대로).
    init(layout: PaneLayout, threadIDs: [String?], focused: Int, existing: Set<String>,
         remembered: [String?] = [], rememberedFocus: Int = 0, rememberedAt: Date? = nil) {
        self.layout = layout
        var seen = Set<String>()
        var restored = threadIDs.prefix(layout.paneCount).map { id -> String? in
            guard let id, existing.contains(id), seen.insert(id).inserted else { return nil }
            return id
        }
        restored += Array(repeating: nil, count: layout.paneCount - restored.count)
        self.threadIDs = restored
        self.focused = min(max(0, focused), layout.paneCount - 1)
        var seenRemembered = Set<String>()
        let memory = remembered.prefix(PaneLayout.fourGrid.paneCount).map { id -> String? in
            guard let id, existing.contains(id), seenRemembered.insert(id).inserted else { return nil }
            return id
        }
        // 지금보다 칸이 많고 대화가 하나라도 남아 있을 때만 기억으로 쓴다.
        if memory.count > layout.paneCount, memory.contains(where: { $0 != nil }) {
            self.remembered = memory
            self.rememberedFocus = min(max(0, rememberedFocus), memory.count - 1)
            self.rememberedAt = rememberedAt
        }
    }

    /// 분할을 바꾼다.
    /// - 줄일 때: 열려 있는 대화를 앞에서부터 남기되 **포커스 대화는 반드시 남긴다**. 줄이기 전 배치는 기억해 둔다.
    /// - 늘릴 때: 기억해 둔 배치가 있으면(`rememberLifetime` 안에 줄였으면) 그 자리로 되살린다 (지금 칸의 대화는 모두 남는다).
    ///   없으면 뒤에 빈 칸을 붙인다. 포커스는 **첫 빈 칸**으로 간다 — 분할한 뒤 사이드바에서 고른 대화가 보던 칸을 바꾸지 않고
    ///   새 칸에 열린다. 빈 칸이 없으면(다 되살렸으면) 보던 대화의 칸.
    func resized(to next: PaneLayout, now: Date = Date()) -> PaneArrangement {
        var result = self
        result.layout = next
        let focusedID = focusedThreadID
        if next.paneCount >= threadIDs.count {
            let grown: [String?]
            if !remembersLayout(at: now) {
                result.remembered = []
                result.rememberedFocus = 0
                result.rememberedAt = nil
            }
            if remembersLayout(at: now), remembered.count > threadIDs.count {
                grown = Self.merging(current: threadIDs, focusedID: focusedID, into: remembered,
                                     rememberedFocus: rememberedFocus, count: next.paneCount)
            } else {
                grown = threadIDs + Array(repeating: nil, count: next.paneCount - threadIDs.count)
            }
            result.threadIDs = grown
            // 기억은 더 큰 배치를 위해 남긴다 — 그 칸 수까지 다 늘렸으면 지운다.
            if result.remembered.count <= next.paneCount {
                result.remembered = []
                result.rememberedFocus = 0
                result.rememberedAt = nil
            }
            if let empty = grown.firstIndex(where: { $0 == nil }) {
                result.focused = empty
            } else {
                result.focused = focusedID.flatMap { id in grown.firstIndex { $0 == id } } ?? 0
            }
            return result
        }
        // 줄이기 전 배치를 기억한다. 이미 더 큰 배치를 기억하고 있으면 그 위에 지금 칸들을 겹친다 (지금 칸의 대화가 이긴다).
        if threadIDs.contains(where: { $0 != nil }) {
            result.rememberedAt = now
            if remembersLayout(at: now), remembered.count > threadIDs.count {
                let merged = Self.merging(current: threadIDs, focusedID: focusedID, into: remembered,
                                          rememberedFocus: rememberedFocus, count: remembered.count)
                result.remembered = merged
                result.rememberedFocus = focusedID.flatMap { id in merged.firstIndex { $0 == id } } ?? rememberedFocus
            } else {
                result.remembered = threadIDs
                result.rememberedFocus = focused
            }
        }
        var kept = Array(threadIDs.compactMap { $0 }.prefix(next.paneCount))
        if let focusedID, !kept.contains(focusedID) { kept[kept.count - 1] = focusedID }
        result.threadIDs = kept.map(Optional.some) + Array(repeating: nil, count: next.paneCount - kept.count)
        result.focused = focusedID.flatMap { id in result.threadIDs.firstIndex { $0 == id } } ?? 0
        return result
    }

    /// 기억해 둔 배치(`memory`)를 `count` 칸으로 되살리면서 지금 칸의 대화(`current`)를 모두 넣는다. 기억에 이미 있는 대화는 그
    /// 자리에, 없는 대화는 기억의 포커스 칸(그 칸의 대화가 지금 보이지 않을 때 — 줄인 칸에서 바꿔 연 대화가 원래 자리로) →
    /// 첫 빈 칸 → 지금 보이지 않는 기억의 대화 중 마지막 칸 순으로 자리를 얻는다. 포커스 대화가 먼저 자리를 고른다.
    static func merging(current: [String?], focusedID: String?, into memory: [String?], rememberedFocus: Int,
                        count: Int) -> [String?] {
        var slots = Array(memory.prefix(count)) + Array(repeating: nil, count: max(0, count - memory.count))
        let shown = current.compactMap { $0 }
        let shownSet = Set(shown)
        let ordered = (focusedID.map { [$0] } ?? []) + shown.filter { $0 != focusedID }
        var placed = Set(slots.compactMap { $0 }).intersection(shownSet)
        for id in ordered where !placed.contains(id) {
            func replaceable(_ index: Int) -> Bool { slots[index].map { !shownSet.contains($0) } ?? true }
            let target: Int?
            if slots.indices.contains(rememberedFocus), replaceable(rememberedFocus) {
                target = rememberedFocus
            } else if let empty = slots.firstIndex(where: { $0 == nil }) {
                target = empty
            } else {
                target = slots.indices.last(where: replaceable)
            }
            guard let target else { continue }
            slots[target] = id
            placed.insert(id)
        }
        return slots
    }

    /// 사이드바에서 대화를 눌렀다: 이미 어느 칸에 열려 있으면 그 칸으로 포커스만, 아니면 포커스 칸의 대화를 바꾼다.
    func opening(_ threadID: String) -> PaneArrangement {
        var result = self
        if let index = threadIDs.firstIndex(where: { $0 == threadID }) {
            result.focused = index
        } else {
            result.threadIDs[min(focused, threadIDs.count - 1)] = threadID
        }
        return result
    }

    /// "새 칸에서 열기": 이미 열려 있으면 그 칸으로, 빈 칸이 있으면 거기에, 없으면 분할을 한 단계 키워 새 칸에.
    /// 네 칸이 다 찼으면 아무것도 바꾸지 않는다 (메뉴가 그 항목을 끈다 — `newPaneBlock`). 보던 칸을 말없이 바꾸지 않는다.
    func openingInNewPane(_ threadID: String) -> PaneArrangement {
        if threadIDs.contains(where: { $0 == threadID }) { return opening(threadID) }
        var result = self
        if let empty = threadIDs.firstIndex(where: { $0 == nil }) {
            result.threadIDs[empty] = threadID
            result.focused = empty
            return result
        }
        guard let larger = layout.larger else { return self }
        // 한 단계 키운다 — 기억해 둔 배치는 되살리지 않는다 (새 칸 하나를 바란 것이다).
        var grown = self
        grown.remembered = []
        grown.rememberedFocus = 0
        grown.rememberedAt = nil
        result = grown.resized(to: larger)
        result.remembered = remembered.count > larger.paneCount ? remembered : []
        result.rememberedFocus = result.remembered.isEmpty ? 0 : rememberedFocus
        result.rememberedAt = result.remembered.isEmpty ? nil : rememberedAt
        return result.openingInNewPane(threadID)
    }

    /// "새 칸에서 열기" 를 할 수 없는 까닭 — 이미 칸에 열려 있음 · 네 칸이 다 참. 할 수 있으면 nil.
    enum NewPaneBlock: Equatable, Sendable { case alreadyOpen, full }

    func newPaneBlock(for threadID: String) -> NewPaneBlock? {
        if threadIDs.contains(where: { $0 == threadID }) { return .alreadyOpen }
        if !threadIDs.contains(where: { $0 == nil }), layout.larger == nil { return .full }
        return nil
    }

    /// 사이드바 행 메뉴의 "새 칸에서 열기" 글 — 끈 까닭을 함께 적는다 (메뉴 항목에는 도움말이 뜨지 않는다).
    func newPaneMenuTitle(for threadID: String) -> String {
        switch newPaneBlock(for: threadID) {
        case nil: return "새 칸에서 열기"
        case .alreadyOpen: return "새 칸에서 열기 (이미 칸에 열려 있음)"
        case .full: return "새 칸에서 열기 (빈 칸 없음 — 칸의 × 로 비우세요)"
        }
    }

    /// 칸을 비운다 (대화는 닫히지 않는다 — 실행도 계속 돈다). 포커스 칸을 비웠으면 대화가 열린 다른 칸으로 포커스를 옮긴다
    /// (가까운 앞 칸 → 뒤 칸 순) — 빈 칸에 포커스가 남으면 툴바 · 인스펙터 · 메뉴가 비고 작업하던 대화를 다시 눌러야 했다.
    /// 다른 칸을 비우면 포커스는 그대로.
    func closing(pane index: Int) -> PaneArrangement {
        guard threadIDs.indices.contains(index) else { return self }
        // 사람이 × 로 비운 대화는 기억에서도 뺀다 — 칸을 늘릴 때 되살아나지 않게 (chr-3).
        var result = threadIDs[index].map { removingFromMemory($0) } ?? self
        result.threadIDs[index] = nil
        if index == focused {
            let before = result.threadIDs.indices.filter { $0 < index }.reversed()
            let after = result.threadIDs.indices.filter { $0 > index }
            if let other = (Array(before) + after).first(where: { result.threadIDs[$0] != nil }) {
                result.focused = other
            }
        }
        return result
    }

    /// 지워진 대화를 칸에서 뺀다 (기억해 둔 배치에서도). 포커스 칸의 대화였으면 칸을 비울 때처럼 대화가 열린 칸으로 포커스를 옮긴다
    /// (`closing`) — 빈 칸에 남은 포커스는 사람이 고른 것으로 보고 `AppModel.reloadProjects` 가 옮기지 않는다.
    func removing(_ threadID: String) -> PaneArrangement {
        var result = removingFromMemory(threadID)
        if threadIDs.indices.contains(focused), threadIDs[focused] == threadID { result = result.closing(pane: focused) }
        result.threadIDs = result.threadIDs.map { $0 == threadID ? nil : $0 }
        return result
    }

    private func removingFromMemory(_ threadID: String) -> PaneArrangement {
        var result = self
        result.remembered = remembered.map { $0 == threadID ? nil : $0 }
        if !result.remembered.contains(where: { $0 != nil }) {
            result.remembered = []
            result.rememberedFocus = 0
            result.rememberedAt = nil
        }
        return result
    }

    func focusing(_ index: Int) -> PaneArrangement {
        var result = self
        result.focused = min(max(0, index), threadIDs.count - 1)
        return result
    }
}
