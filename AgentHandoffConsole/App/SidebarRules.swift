import Foundation

// 사이드바와 빈 칸이 무엇을 보일지 — 순수 판정 (SwiftUI 없이 — 검증 하네스가 컴파일한다).
// 그리는 곳은 `UI/SidebarView.swift` · `UI/PaneGrid.swift`, 사실(선택 · 실행 · 칸)을 모으는 곳은 그 뷰와 `AppModel`.

enum SidebarRules {
    /// 프로젝트마다 처음에 보이는 대화 수. 더 있으면 "더보기 N개" 로 편다.
    static let visibleLimit = 3

    /// 한 프로젝트에서 그릴 활성 대화. 순서는 목록 그대로.
    /// - 검색 중이면 맞는 것(`active` 는 이미 거른 목록) 전부.
    /// - 접혔으면 하나도 그리지 않는다 (사용자 결정 2026-10-09 — 예전에는 선택 · 실행 중 · 답을 기다리는 · 칸에 열린 대화를 남겨, 새
    ///   프로젝트의 하나뿐인 대화는 접어도 그대로였다). 답을 기다리는 대화는 툴바 "응답 필요" · 현황 · Dock 배지가 알린다.
    /// - "더보기" 로 폈거나 3개 이하면 전부, 아니면 앞 3개 + 그 뒤의 꼭 보여야 할 대화(`pinned` — 선택 · 실행 중 · 답을 기다림 · 칸에 열림).
    static func visible<Thread>(_ active: [Thread], searching: Bool, collapsed: Bool, expanded: Bool,
                                pinned: (Thread) -> Bool) -> [Thread] {
        if searching { return active }
        if collapsed { return [] }
        if expanded || active.count <= visibleLimit { return active }
        return Array(active.prefix(visibleLimit)) + active.dropFirst(visibleLimit).filter(pinned)
    }

    /// 검색어에 맞는 대화 — 제목 · 목표 (본문은 찾지 않는다 — 대화 안 찾기는 ⌘F). 앞뒤 공백은 무시하고, 비면 모두 맞다.
    static func matches(_ thread: ConversationThread, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return thread.title.localizedCaseInsensitiveContains(query) || thread.goal.localizedCaseInsensitiveContains(query)
    }

    /// 검색어가 있는데 어느 프로젝트에도 맞는 대화가 없을 때의 한 줄.
    static let noMatchText = "제목 · 목표에 맞는 대화가 없습니다"

    /// 검색칸의 자리 글 — 무엇을 찾는지와 단축키.
    static let searchPlaceholder = "대화 제목 · 목표 검색"

    /// 프로젝트의 화면 이름 (사이드바 · 칸 머리 · 툴바 부제). 이름이 같은 프로젝트가 둘 이상이면 서로 달라질 때까지 위 폴더를
    /// 덧붙인다 ("app — a", 그래도 같으면 "app — work/a"). 이름이 하나뿐이면 이름 그대로.
    static func displayNames(_ projects: [Project]) -> [String: String] {
        var out: [String: String] = [:]
        for (name, group) in Dictionary(grouping: projects, by: \.name) {
            guard group.count > 1 else {
                if let only = group.first { out[only.id] = name }
                continue
            }
            // 경로의 위 폴더들 (마지막 칸 · 맨 앞 "/" 빼고).
            let parents = group.map { project in
                Array(URL(fileURLWithPath: project.path).standardizedFileURL.pathComponents.dropLast().filter { $0 != "/" })
            }
            let deepest = parents.map(\.count).max() ?? 0
            var depth = 1
            while depth < deepest {
                let labels = parents.map { $0.suffix(depth).joined(separator: "/") }
                if Set(labels).count == labels.count { break }
                depth += 1
            }
            for (project, parent) in zip(group, parents) {
                let label = parent.suffix(depth).joined(separator: "/")
                out[project.id] = label.isEmpty ? name : "\(name) — \(label)"
            }
        }
        return out
    }

    /// 새 대화를 만들지 않고 다시 쓸 수 있는 빈 대화의 후보 (⌘N · 사이드바 ＋ 가 빈 "새 대화" 를 쌓지 않게): 자리 표시 제목 ·
    /// 보관하지 않음 · 독립 작업 폴더 없음 · 내부 대화 아님 · 목표 · 고정 메모 없음. 최근 것이 먼저. 기록(이벤트 · 실행)이
    /// 정말 없는지는 부르는 쪽이 저장소에서 확인한다 (`AppModel.startNewConversation`).
    static func blankCandidates(_ threads: [ConversationThread]) -> [ConversationThread] {
        threads.filter {
            $0.hasPlaceholderTitle && !$0.archived && $0.worktree == nil && !$0.isInternal
                && $0.goal.isEmpty && $0.pinnedNotes.isEmpty
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 사이드바 행의 접근성 이름에 덧붙일 상태 — 분할 화면의 다른 칸에 열린 대화 (바탕색만으로 알리지 않는다).
    static let openElsewhereLabel = "다른 칸에 열림"

    /// 목록에 보이는 대화 이름 — 옛 자리 표시 제목("새 스레드")은 지금 말로 (저장된 제목은 그대로).
    static func displayTitle(_ thread: ConversationThread) -> String {
        thread.hasPlaceholderTitle ? "새 대화" : thread.title
    }

    // MARK: 프로젝트 순서 · 이전 프로젝트

    /// 이보다 오래 쉰 프로젝트는 목록 맨 아래 "이전 프로젝트 N개" 안에 둔다.
    static let idleDays: Double = 14
    /// "이전 프로젝트" 줄 오른쪽의 기준 글 (`idleDays` 와 같이 바꾼다).
    static let idleNote = "2주 넘게 쉼"
    static let idleHelp = "마지막으로 쓴 지 2주가 넘은 프로젝트 — 실행 중이거나 답을 기다리는 대화가 있으면 위에 남습니다"

    static func idleGroupTitle(count: Int) -> String { "이전 프로젝트 \(count)개" }

    /// 프로젝트의 마지막 활동 — 그 프로젝트 대화(보관 포함)의 가장 최근 `updatedAt`, 대화가 없으면 프로젝트를 연 때.
    static func lastActivity(_ project: Project, threads: [ConversationThread]) -> Date {
        threads.map(\.updatedAt).max() ?? project.createdAt
    }

    struct Sections: Equatable {
        /// 위에 놓는 프로젝트 — 마지막 활동이 최근인 순.
        var recent: [Project]
        /// "이전 프로젝트" 안에 두는 프로젝트 — 마지막 활동이 최근인 순.
        var idle: [Project]
    }

    /// 사이드바의 프로젝트 순서와 묶음 (순수): 마지막 활동이 최근인 순(같으면 원래 순서). `idleDays` 보다 오래 쉰 프로젝트는 `idle` —
    /// 단 꼭 보여야 할 대화(`pinned` — 선택 · 실행 중 · 답을 기다림 · 칸에 열림)가 있으면 위에 남는다. 위가 비면 가장 최근 하나는 위에
    /// 둔다 (오래 쉬다 돌아왔을 때 접힌 한 줄만 남지 않게). 검색 중이면 묶지 않는다 — 전부 최근 순으로 위에.
    static func sections(_ projects: [Project], threadsByProject: [String: [ConversationThread]], now: Date,
                         searching: Bool, pinned: (ConversationThread) -> Bool) -> Sections {
        let ordered = projects.enumerated()
            .map { (index: $0.offset, project: $0.element,
                    last: lastActivity($0.element, threads: threadsByProject[$0.element.id] ?? [])) }
            .sorted { $0.last != $1.last ? $0.last > $1.last : $0.index < $1.index }
        guard !searching else { return Sections(recent: ordered.map(\.project), idle: []) }
        let cutoff = now.addingTimeInterval(-idleDays * 86_400)
        var recent: [Project] = []
        var idle: [Project] = []
        for entry in ordered {
            if entry.last >= cutoff || (threadsByProject[entry.project.id] ?? []).contains(where: pinned) {
                recent.append(entry.project)
            } else {
                idle.append(entry.project)
            }
        }
        if recent.isEmpty, !idle.isEmpty { recent.append(idle.removeFirst()) }
        return Sections(recent: recent, idle: idle)
    }
}

/// 대화 칸이 비었을 때의 안내 (`PaneGrid`) — 분할 · 이 칸이 포커스인지 · 사이드바가 보이는지 · 프로젝트가 있는지로 고른다.
/// "왼쪽에서 …" 처럼 지금 화면에 없는 것을 가리키지 않는다.
struct EmptyPaneText: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// 새 대화 (⌘N — 선택된 프로젝트에).
        case newConversation
        /// 사이드바 보기 (⌃⌘S).
        case showSidebar
        /// 프로젝트 폴더 열기 (⌘O).
        case openFolder
    }

    var title: String
    var detail: String
    var actions: [Action]

    static func make(split: Bool, focused: Bool, sidebarVisible: Bool, hasProjects: Bool) -> EmptyPaneText {
        guard hasProjects else {
            return EmptyPaneText(title: "프로젝트 폴더를 여세요",
                                 detail: "에이전트가 일할 폴더를 열면 첫 대화가 시작됩니다 (⌘O).",
                                 actions: [.openFolder])
        }
        let sidebarAction: [Action] = sidebarVisible ? [] : [.showSidebar]
        if split {
            let pick = sidebarVisible ? "사이드바에서 대화를 고르면" : "사이드바를 열고 대화를 고르면"
            let detail = focused ? "\(pick) 이 칸에 열립니다." : "이 칸을 누른 뒤 \(pick) 여기에 열립니다."
            return EmptyPaneText(title: "빈 칸", detail: detail, actions: [.newConversation] + sidebarAction)
        }
        let detail = sidebarVisible ? "사이드바에서 대화를 고르거나 새 대화를 시작하세요 (⌘N)."
                                    : "사이드바를 열어 대화를 고르거나 새 대화를 시작하세요 (⌘N)."
        return EmptyPaneText(title: "대화를 고르세요", detail: detail, actions: [.newConversation] + sidebarAction)
    }

    static func title(_ action: Action) -> String {
        switch action {
        case .newConversation: return "새 대화"
        case .showSidebar: return "사이드바 보기"
        case .openFolder: return "프로젝트 폴더 열기…"
        }
    }
}
