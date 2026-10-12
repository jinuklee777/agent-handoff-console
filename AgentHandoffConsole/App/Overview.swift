import Foundation

/// 에이전트 현황 — 가운데 칸 "현황"(⌃⌘0)의 **순수 판정** (SwiftUI 없이 — 검증 하네스가 컴파일한다).
/// 사실은 `AppModel+Overview.swift` 가 모으고(`overviewItems` · `overviewFinishedRuns`), 화면은 `UI/OverviewView.swift`.
/// 지금 도는 실행 · 사람을 기다리는 인계 카드 · 자동 작업을 한 화면에 — 답을 기다리는 것이 먼저, 그다음 일하는 것.
/// 판정의 근거는 칸 머리와 같다 (`PaneStatus` — 승인 → 질문 → 인계 검토 → 자동 작업 → 자동 인계 카운트다운 · 다른 계정에서 이어 가기
/// 카운트다운 → 실행).
enum Overview {
    /// 행 하나가 무엇을 기다리는지 · 무엇을 하는지. 한 대화에 하나 — 칸 머리와 같은 우선순위로 고른다.
    enum Kind: Equatable, Sendable {
        /// 승인 요청 (그 실행의 맨 앞 요청). 현황에서 답할 수 있는지는 `approvalChoice`.
        case approval
        /// 에이전트의 질문.
        case question
        /// 사람이 봐야 하는 인계 카드 (게이트 막힘 · 실패 · 미확인 · 계정 해제 · 낡음). 글은 칸 머리의 것.
        case handoffReview(String)
        /// 자동 작업이 사람을 기다린다 (계획 승인 · 질문 · 막힘). 글은 칸 머리의 것.
        case orchestration(String)
        /// 자동 인계 카운트다운 — 사람의 답을 기다리지는 않지만, 끝나면 스스로 넘기므로 답을 기다리는 쪽에 둔다.
        case handoffCountdown(deadline: Date)
        /// 자동 인계가 같은 Codex 의 다른 계정을 골라, 카운트다운 뒤 그 계정에서 같은 세션을 이어 간다 (인계가 아니다 —
        /// `CodexAccountSwitch.Countdown`). 자동 인계 카운트다운과 같은 구역 · 같은 순서.
        case codexSwitch(deadline: Date)
        /// 일하는 중.
        case working
        /// 메인 턴을 마치고 남은 백그라운드 작업(하위 에이전트 · 워크플로 · 백그라운드 명령)을 기다린다 (남은 수).
        case background(Int)

        /// 답을 기다리는 쪽(위 구역)에 두는가.
        var needsResponse: Bool {
            switch self {
            case .approval, .question, .handoffReview, .orchestration, .handoffCountdown, .codexSwitch: return true
            case .working, .background: return false
            }
        }

        /// 사람이 답해야 끝나는가 (카운트다운은 스스로 움직인다 — 세지 않는다).
        var waitsOnPerson: Bool { needsResponse && !isCountdown }

        var isCountdown: Bool { countdownDeadline != nil }

        /// 카운트다운의 마감 (자동 인계 · 다른 계정에서 이어 가기). 카운트다운이 아니면 nil.
        var countdownDeadline: Date? {
            switch self {
            case .handoffCountdown(let deadline), .codexSwitch(let deadline): return deadline
            default: return nil
            }
        }

        /// 정렬 순서 (상태순): 승인 · 질문 · 검토 · 자동 작업은 오래 기다린 순으로 함께, 카운트다운(두 종류 함께)은 그 뒤, 일하는 중,
        /// 백그라운드 대기.
        fileprivate var rank: Int {
            switch self {
            case .approval, .question, .handoffReview, .orchestration: return 0
            case .handoffCountdown, .codexSwitch: return 1
            case .working: return 2
            case .background: return 3
            }
        }
    }

    /// 하위 작업 한 줄 (백그라운드 대기 행).
    struct Subtask: Equatable, Sendable {
        var title: String
        /// "완료" · "52초" · "백그라운드 명령" — 상태 열의 글.
        var status: String
        var finished: Bool
    }

    /// 행 하나 (대화 하나).
    struct Item: Identifiable, Equatable, Sendable {
        var threadID: String
        var title: String
        /// 프로젝트의 화면 이름 (같은 이름이면 위 폴더를 덧붙인 것 — `AppModel.projectDisplayName`).
        var project: String
        /// 그 대화가 일하는 폴더의 브랜치 (모르면 nil).
        var branch: String?
        /// 독립 작업 폴더(git worktree)에서 일한다.
        var inWorktree = false
        var provider: AgentProvider
        var kind: Kind
        /// 기다리기 시작한 때(승인 · 질문 · 검토 · 백그라운드) 또는 실행이 시작된 때(일하는 중). 정렬과 "n분째" 의 기준.
        var since: Date
        /// 자동 작업의 내부 대화 (계획 · 하위 작업 · 검토).
        var automatic = false
        /// 지금 하는 일 한 줄 (`RunActivity.text`) — 일하는 중 · 백그라운드 대기만.
        var activity: String?
        /// 그 일의 대상 (명령 · 파일) — 고정폭으로 한 줄.
        var activityDetail: String?
        /// 상태 줄의 점 구가 보일 일 (`RunActivity.read`).
        var work: RunActivity.Work?
        /// 모델 · 강도 · 계정 등 메타 한 줄의 조각.
        var meta: [String] = []
        /// 함께 알아야 할 것 한 줄 (같은 폴더의 다른 실행 등).
        var note: String?
        /// 백그라운드 대기 행의 하위 작업.
        var subtasks: [Subtask] = []
        /// 실행 중인 실행이 있다 (중단 단추).
        var running = false

        var id: String { threadID }
    }

    /// 상태순 · 프로젝트순.
    enum Sort: String, CaseIterable, Sendable {
        case status, project

        var title: String {
            switch self {
            case .status: return "상태순"
            case .project: return "프로젝트순"
            }
        }
    }

    /// 화면의 구역 하나.
    struct Group: Identifiable, Equatable, Sendable {
        enum Role: Equatable, Sendable {
            case needsResponse
            case working
            case project(String)
        }
        var role: Role
        var title: String
        /// 머리 뒤에 흐리게 붙이는 말 ("· 자동 인계 대기 1").
        var note: String?
        var items: [Item]

        var id: String {
            switch role {
            case .needsResponse: return "needs"
            case .working: return "working"
            case .project(let name): return "project|" + name
            }
        }
    }

    // MARK: 정렬 · 구역

    /// 상태순: 같은 단계 안에서 승인 · 질문 · 검토는 오래 기다린 것 먼저, 카운트다운은 (종류와 상관없이) 마감이 이른 것 먼저,
    /// 일하는 중은 오래 일한 것 먼저.
    static func ordered(_ items: [Item]) -> [Item] {
        items.sorted { a, b in
            if a.kind.rank != b.kind.rank { return a.kind.rank < b.kind.rank }
            if let x = a.kind.countdownDeadline, let y = b.kind.countdownDeadline, x != y { return x < y }
            if a.since != b.since { return a.since < b.since }
            return a.threadID < b.threadID
        }
    }

    /// 화면의 구역. 상태순은 "응답 필요" · "일하는 중" 둘 (빈 구역은 뺀다), 프로젝트순은 프로젝트마다 하나 —
    /// 답을 기다리는 행이 있는 프로젝트가 먼저(상태순에서 먼저 나온 순서), 안에서는 상태순.
    static func groups(_ items: [Item], sort: Sort) -> [Group] {
        let ordered = ordered(items)
        switch sort {
        case .status:
            let needs = ordered.filter { $0.kind.needsResponse }
            let working = ordered.filter { !$0.kind.needsResponse }
            var groups: [Group] = []
            if !needs.isEmpty {
                let tally = counts(needs)
                let countdowns = countdownNote(tally)
                // 카운트다운만 있으면 "응답 필요 0" 이라 하지 않는다 — 그 카운트다운의 이름으로.
                groups.append(Group(role: .needsResponse,
                                    title: tally.waiting > 0 ? "응답 필요 \(tally.waiting)" : countdowns ?? "응답 필요",
                                    note: tally.waiting > 0 ? countdowns : nil, items: needs))
            }
            if !working.isEmpty {
                let background = working.filter { if case .background = $0.kind { return true }; return false }.count
                groups.append(Group(role: .working, title: "일하는 중 \(working.count)",
                                    note: background > 0 ? "백그라운드 대기 \(background) 포함" : nil, items: working))
            }
            return groups
        case .project:
            var names: [String] = []
            for item in ordered where !names.contains(item.project) { names.append(item.project) }
            return names.map { name in
                let rows = ordered.filter { $0.project == name }
                let waiting = rows.filter(\.kind.waitsOnPerson).count
                return Group(role: .project(name), title: name,
                             note: waiting > 0 ? "응답 필요 \(waiting) · 실행 \(rows.filter(\.running).count)"
                                               : "실행 \(rows.filter(\.running).count)",
                             items: rows)
            }
        }
    }

    // MARK: 머리 · 수

    struct Counts: Equatable, Sendable {
        /// 사람의 답을 기다리는 대화 (카운트다운 제외).
        var waiting = 0
        /// 자동 인계 카운트다운.
        var countdowns = 0
        /// 다른 계정에서 같은 세션을 이어 가기 카운트다운 (인계가 아니라서 따로 센다).
        var codexSwitches = 0
        /// 도는 실행 (백그라운드 대기 포함).
        var running = 0
        /// 일하는 중 (백그라운드 대기 제외).
        var working = 0
        var background = 0
        /// 백그라운드 대기 행들의 남은 하위 작업 수의 합.
        var backgroundTasks = 0
    }

    static func counts(_ items: [Item]) -> Counts {
        var counts = Counts()
        for item in items {
            if item.running { counts.running += 1 }
            switch item.kind {
            case .handoffCountdown: counts.countdowns += 1
            case .codexSwitch: counts.codexSwitches += 1
            case .working: counts.working += 1
            case .background(let left):
                counts.background += 1
                counts.backgroundTasks += left
            default:
                if item.kind.waitsOnPerson { counts.waiting += 1 }
            }
        }
        return counts
    }

    /// 머리의 한 문장 — "에이전트 7개가 실행 중입니다. 3개가 답을 기다리고, 1개는 곧 자동으로 인계합니다."
    /// 다른 계정에서 이어 가기 카운트다운은 인계라 하지 않는다 — "1개는 곧 다른 계정에서 같은 세션을 이어 갑니다".
    /// 카운트다운의 초는 행이 센다 (머리는 1초마다 바뀌지 않는다).
    static func headline(_ counts: Counts) -> String {
        // 마디마다 끝맺는 꼴과 잇는 꼴 — 마지막 마디만 끝맺는다.
        var clauses: [(end: String, joined: String)] = []
        if counts.waiting > 0 {
            clauses.append(("\(counts.waiting)개가 답을 기다립니다", "\(counts.waiting)개가 답을 기다리고"))
        }
        if counts.countdowns > 0 {
            clauses.append(("\(counts.countdowns)개는 곧 자동으로 인계합니다", "\(counts.countdowns)개는 곧 자동으로 인계하고"))
        }
        if counts.codexSwitches > 0 {
            clauses.append(("\(counts.codexSwitches)개는 곧 다른 계정에서 같은 세션을 이어 갑니다",
                            "\(counts.codexSwitches)개는 곧 다른 계정에서 같은 세션을 이어 가고"))
        }
        var after = ""
        if let last = clauses.last {
            after = " " + (clauses.dropLast().map(\.joined) + [last.end]).joined(separator: ", ") + "."
        }
        guard counts.running > 0 else {
            return clauses.isEmpty ? emptyTitle : "실행 중인 에이전트는 없습니다." + after
        }
        return "에이전트 \(counts.running)개가 실행 중입니다." + after
    }

    /// 카운트다운의 수 — 구역 머리 뒤 · 수 칸에: "자동 인계 대기 1" · "다른 계정에서 이어 가기 대기 1" (둘 다면 " · " 로 잇는다).
    /// 카운트다운이 없으면 nil.
    static func countdownNote(_ counts: Counts) -> String? {
        var parts: [String] = []
        if counts.countdowns > 0 { parts.append("자동 인계 대기 \(counts.countdowns)") }
        if counts.codexSwitches > 0 { parts.append("\(CodexAccountSwitch.waitingText) \(counts.codexSwitches)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static let emptyTitle = "지금 실행 중인 에이전트가 없습니다"

    /// 사이드바 맨 위 "현황" 행의 수 — 답을 기다리는 수(황색 점과 함께)와 실행 수. 아무것도 없으면 둘 다 nil (이름만 보인다).
    static func sidebarBadge(_ counts: Counts) -> (waiting: Int?, running: Int?) {
        (counts.waiting > 0 ? counts.waiting : nil, counts.running > 0 ? counts.running : nil)
    }

    /// 사이드바 행의 접근성 · 도움말 글.
    static func sidebarHelp(_ counts: Counts) -> String {
        var parts: [String] = []
        if counts.waiting > 0 { parts.append("응답 필요 \(counts.waiting)") }
        if counts.running > 0 { parts.append("실행 \(counts.running)") }
        return parts.isEmpty ? "현황 — 지금 도는 에이전트가 없습니다" : "현황 — " + parts.joined(separator: " · ")
    }

    /// 행의 상태 글 — "승인 대기 · 2분째" · "자동 인계 대기" · "2분 41초"(일하는 중 — 부르는 쪽이 시계로) 의 앞부분.
    static func statusText(_ kind: Kind) -> String {
        switch kind {
        case .approval: return "승인 대기"
        case .question: return "질문 대기"
        case .handoffReview(let what), .orchestration(let what): return what
        case .handoffCountdown: return "자동 인계 대기"
        case .codexSwitch: return CodexAccountSwitch.waitingText
        case .working: return "일하는 중"
        case .background: return "백그라운드 대기"
        }
    }

    /// 기다린 시간 — "2분째" (1분이 안 되면 "방금"). 승인 · 질문 · 검토 행의 상태 글 뒤에 붙는다.
    static func waitedText(since: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 { return "방금" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)분째" }
        return "\(minutes / 60)시간 \(minutes % 60)분째"
    }

    // MARK: 현황에서 답하기

    /// 승인 요청을 현황에서 답할 수 있는지. 허용은 내용을 다 볼 수 있고 되돌릴 수 있는 요청만 — 나머지는 대화에서 답한다 (카드가 전부를
    /// 보인다). 거절은 안전하므로 질문 · 입력 칸이 없으면 여기서도 받는다.
    struct ApprovalChoice: Equatable, Sendable {
        var allowsHere: Bool
        var deniesHere: Bool
        /// 허용을 대화로 미루는 까닭 (행에 한 줄). 여기서 허용하면 nil.
        var reason: String?
    }

    static func approvalChoice(kind: ApprovalKind, presentation: ApprovalPresentation, isQuestion: Bool) -> ApprovalChoice {
        if isQuestion || presentation.answersQuestion {
            return ApprovalChoice(allowsHere: false, deniesHere: false, reason: "에이전트의 질문입니다 — 대화에서 답합니다.")
        }
        if let risk = presentation.risk {
            return ApprovalChoice(allowsHere: false, deniesHere: true,
                                  reason: "되돌릴 수 없는 명령입니다 — \(risk.what). 여기서는 허용할 수 없고 대화에서 답합니다.")
        }
        // 행의 미리보기는 명령의 첫 줄만 보인다 — 줄을 끊는 글자(CR · U+2028 …) 뒤에 숨은 꼬리 · 숨은 글자 · 긴 명령은 대화의 카드에서.
        if case .command(let command)? = presentation.blocks.first,
           commandLines(command).count > 1 || CommandWrap.hasMarkers(command) || CommandWrap.width(command) > overviewCommandColumns {
            return ApprovalChoice(allowsHere: false, deniesHere: true,
                                  reason: "여러 줄이거나 길거나 숨은 글자가 있는 명령입니다 — 대화에서 전부 보고 답합니다.")
        }
        // 파일 경로 · 대상 · 이름: 값에 줄 끊는 글자 · 숨은 글자가 있으면 한 줄 미리보기가 그 뒤를 숨길 수 있다 — 대화에서.
        if presentation.blocks.contains(where: hidesText) {
            return ApprovalChoice(allowsHere: false, deniesHere: true,
                                  reason: "경로나 값에 줄바꿈 · 숨은 글자가 있습니다 — 대화에서 전부 보고 답합니다.")
        }
        if presentation.form != nil || kind == .elicitation {
            return ApprovalChoice(allowsHere: false, deniesHere: false, reason: "입력할 칸이 있는 요청입니다 — 대화에서 답합니다.")
        }
        if kind == .permissions {
            return ApprovalChoice(allowsHere: false, deniesHere: true,
                                  reason: "권한을 넓히는 요청입니다 — 무엇을 넓히는지 대화에서 보고 답합니다.")
        }
        return ApprovalChoice(allowsHere: true, deniesHere: true, reason: nil)
    }

    /// 한 줄로 보이는 경로 · 대상 · 이름에 줄 끊는 글자(LF 포함) · 숨은 글자가 있는지, 값에 LF 밖의 줄 끊는 글자 · 숨은 글자가 있는지.
    private static func hidesText(_ block: ApprovalPresentation.Block) -> Bool {
        func hidden(_ text: String) -> Bool { CommandWrap.hasMarkers(text) || text.contains("\n") }
        switch block {
        case .diff(let path, _), .content(let path, _, _): return hidden(path)
        case .target(let target): return hidden(target)
        case .fields(let fields): return fields.contains { hidden($0.name) || CommandWrap.hasMarkers($0.value) }
        case .command, .text: return false
        }
    }

    /// 현황에서 허용할 수 있는 명령의 길이 상한(고정폭 열) — 넘으면 대화의 카드에서 답한다.
    static let overviewCommandColumns = 160

    /// 승인 행에 보일 명령의 줄 — 카드의 명령 상자와 같이 줄을 끊는 글자마다 끊고 숨은 글자는 표시로 (`CommandWrap.visibleLines`),
    /// 빈 줄은 뺀다.
    static func commandLines(_ command: String) -> [String] {
        CommandWrap.visibleLines(command).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// 승인 행의 미리보기 — 무엇을 하려는지 한 줄과 그 대상 한 줄(고정폭). 전부는 대화의 카드가 보인다.
    static func approvalPreview(_ presentation: ApprovalPresentation, subject: String) -> (line: String, code: String?) {
        let line = "\(subject): \(presentation.action)"
        guard let block = presentation.blocks.first else { return (line, nil) }
        switch block {
        case .command(let command):
            let lines = commandLines(command)
            return (line, lines.first.map { $0 + (lines.count > 1 ? " …" : "") })
        // 경로 · 대상 · 값도 명령처럼 줄 끊는 글자 · 숨은 글자를 표시로 (`CommandWrap.visibleLine`).
        case .diff(let path, let lines):
            let added = lines.filter { $0.kind == .added }.count
            let removed = lines.filter { $0.kind == .removed }.count
            return (line, "\(CommandWrap.visibleLine(path))  +\(added) −\(removed)")
        case .content(let path, _, let count):
            return (line, "\(CommandWrap.visibleLine(path))  \(count)줄")
        case .target(let target):
            return (line, CommandWrap.visibleLine(target))
        case .fields(let fields):
            return (line, fields.first.map { "\(CommandWrap.visibleLine($0.name)): \(CommandWrap.visibleLine($0.value))" })
        case .text(let text):
            return (line, commandLines(text).first)
        }
    }

    /// 질문을 현황에서 답할 수 있으면 고를 답들. 항목이 하나이고 · 비밀 입력이 아니고 · 고를 답이 있을 때만 (나머지는 대화에서).
    static func questionOptions(_ question: UserQuestion) -> [String]? {
        guard question.items.count == 1, let item = question.items.first, !item.isSecret, !item.options.isEmpty else { return nil }
        return item.options
    }

    // MARK: 최근 끝난 실행 · 오늘

    struct FinishedRun: Identifiable, Equatable, Sendable {
        var runID: String
        var threadID: String
        var title: String
        var project: String
        var provider: AgentProvider
        var state: RunState
        var endedAt: Date
        var durationMs: Int?
        var newTokens: Int?
        var cost: Double?
        /// 메뉴바 "확인 필요" 에 남은 실행 (그 대화를 아직 열지 않았다).
        var needsCheck = false

        var id: String { runID }
    }

    /// 결과 열의 글 — "완료" · "오류 · 확인 필요" · "사용 한도 도달".
    static func resultText(_ run: FinishedRun) -> String {
        let name = run.state == .cancelled ? "중단됨" : run.state.koreanName
        return run.needsCheck ? name + " · 확인 필요" : name
    }

    /// 끝난 실행 표에 둘 것 — 최근 것 먼저, `limit` 개까지. 인계 전달 실행도 둔다 (받는 쪽이 일한 실행이다).
    static func recent(_ runs: [FinishedRun], limit: Int = 8) -> [FinishedRun] {
        Array(runs.sorted { $0.endedAt > $1.endedAt }.prefix(limit))
    }

    /// "오늘 끝난 실행" 칸 — "18 · 새 토큰 312만 · $6.40 API 환산". 새 토큰 · 비용을 아는 실행이 없으면 수만.
    static func todayText(_ runs: [FinishedRun]) -> String {
        var parts = ["\(runs.count)"]
        let tokens = runs.compactMap(\.newTokens)
        if !tokens.isEmpty { parts.append("새 토큰 " + DisplayFormat.tokens(tokens.reduce(0, +))) }
        let costs = runs.compactMap(\.cost)
        if !costs.isEmpty { parts.append(DisplayFormat.cost(costs.reduce(0, +)) + " API 환산") }
        return parts.joined(separator: " · ")
    }

    /// 아무것도 돌지 않을 때의 한 줄 — "마지막 실행 11:48 · 오늘 끝난 실행 18 · 확인할 것 없음".
    static func emptyLine(lastEnded: Date?, today: [FinishedRun], calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if let lastEnded { parts.append("마지막 실행 " + clock(lastEnded, calendar: calendar)) }
        parts.append("오늘 끝난 실행 \(today.count)")
        let checks = today.filter(\.needsCheck).count
        parts.append(checks > 0 ? "확인 필요 \(checks)" : "확인할 것 없음")
        return parts.joined(separator: " · ")
    }

    /// 시각 "11:48" (오늘이 아니면 "10월 8일 11:48").
    static func clock(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = calendar.dateComponents([.hour, .minute], from: date)
        let hm = String(format: "%02d:%02d", time.hour ?? 0, time.minute ?? 0)
        guard !calendar.isDate(date, inSameDayAs: now) else { return hm }
        let day = calendar.dateComponents([.month, .day], from: date)
        return "\(day.month ?? 0)월 \(day.day ?? 0)일 " + hm
    }

    /// 한도 칸의 계정 하나 옆 — "실행 중 4" (0 이면 "실행 중 0").
    static func runningText(_ count: Int) -> String { "실행 중 \(count)" }

    /// 한도 줄이 없는데 도는 Antigravity (허용한 프로젝트가 없어 한도를 읽지 않았다 — `LimitsService.antigravityEnabled`).
    static let noLimitsText = "이 에이전트의 사용 한도는 읽지 않았습니다."

    /// 좁은 칸 (인스펙터를 연 작은 창) — 한 줄 행 · 한도 칸 숨김. 칸 폭 기준.
    static let compactWidth: Double = 640
}
