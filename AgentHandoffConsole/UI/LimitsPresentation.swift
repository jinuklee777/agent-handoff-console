import Foundation

/// 툴바 한도 칩 · 한도 팝오버 · 메뉴바 · 설정의 Codex 계정 줄이 쓰는 한도 글 — 순수 판정 (SwiftUI 없이 — 검증 하네스가 컴파일한다).
///
/// 값이 없을 때 **아직 읽지 않음**(첫 프로젝트 뒤로 미룬 Claude 조회 · 설정에서 끈 조회 · 차례가 오지 않음 · 읽는 중)과
/// **읽었는데 값을 얻지 못함**(실패)을 가른다. 둘 다 `LimitStatus.noData` 라서, 예전에는 미룬 조회도 "정보 없음 · 한도 정보를
/// 가져오지 못했습니다" 로 보였다 (조회한 적이 없으면 `fetchedAt` 이 nil 이다). 칩의 숫자에는 % 를 붙이고, 창 이름(5시간 등)은
/// 도움말 · 접근성 글에 적는다.
enum LimitsPresentation {

    /// 한 계정(제공자)의 한도를 지금 어떻게 말할지.
    enum State: Equatable {
        /// 사용률을 아는 구간이 있다 — 칩은 다 찬 계정 전체 창이 있으면 그것을, 아니면 첫 것(대개 짧은 창)을 (`chipWindow`).
        case value(LimitWindow)
        /// 아직 읽지 않았다 — 실패가 아니다.
        case pending(Pending)
        /// 값 없이 알게 된 문제 (로그인 · 한도 도달 · 일시적 제한 · 네트워크 · 원인 미확인).
        case problem(LimitStatus, message: String?)
        /// 읽었지만 값을 얻지 못했다 (CLI 를 찾지 못함 · 형식이 바뀜 등).
        case unavailable(message: String?)

        var hasValue: Bool {
            if case .value = self { return true }
            return false
        }
    }

    enum Pending: Equatable {
        /// 지금 읽는 중.
        case checking
        /// 새 사용자 — Claude 조회(`claude -p` 세션)를 첫 프로젝트 뒤로 미뤘다 (`AppModel.deferredClaudeStartup`).
        case afterFirstProject
        /// 설정 > 에이전트 > Claude Code 의 "앱을 열 때 사용 한도 확인" 을 껐다 — 대화가 끝나면 읽는다.
        case startupCheckOff
        /// 그 밖 — 아직 차례가 오지 않았다.
        case notYet
    }

    /// 화면이 모아 넘기는 사실 (`AppModel.limitContext(for:)`). 미룸 · 설정은 Claude 에만 있다.
    struct Context: Equatable, Sendable {
        var refreshing = false
        var deferredUntilProject = false
        var startupCheckOff = false
    }

    static func state(_ snapshot: LimitSnapshot, context: Context = Context(), now: Date = Date()) -> State {
        if let window = chipWindow(snapshot, now: now) { return .value(window) }
        switch snapshot.status {
        case .ok, .noData:
            if context.refreshing { return .pending(.checking) }
            // 조회한 적이 있으면(시각 · 까닭이 있다) 실패다 — 미룬 조회와 섞지 않는다.
            guard snapshot.fetchedAt == nil, snapshot.message == nil else { return .unavailable(message: snapshot.message) }
            // 설정에서 껐으면 첫 프로젝트 뒤에도 앱이 스스로 읽지 않는다 — 미룸보다 먼저 말한다.
            if context.startupCheckOff { return .pending(.startupCheckOff) }
            if context.deferredUntilProject { return .pending(.afterFirstProject) }
            return .pending(.notYet)
        default:
            return .problem(snapshot.status, message: snapshot.message)
        }
    }

    /// 칩 · 도움말이 보일 창: 다 찬 계정 전체 창(모델 하나의 한도는 빼고, 초기화 시각이 지난 창도 뺀다)이 있으면 그것, 아니면 사용률을
    /// 아는 첫 계정 전체 창(대개 짧은 창). 주간 한도가 찼는데 5시간 창의 "12%" 를 보통 색으로 보이면 보내도 되는 줄 알았다 — 보내면 곧바로
    /// 한도 도달로 멈춘다 (chr-6, 메뉴바는 같은 때 "사용 한도에 닿았습니다"). 계정 전체 창이 없으면(Antigravity — 창이 모두 모델 묶음의
    /// 것이다) 가장 많이 쓴 창 — 한 숫자로 가장 빠듯한 곳을 말한다 (묶음마다는 팝오버에).
    static func chipWindow(_ snapshot: LimitSnapshot, now: Date = Date()) -> LimitWindow? {
        let known = snapshot.windows.filter { $0.utilization != nil }
        return known.first { isFull($0, now: now) } ?? known.first { $0.model == nil }
            ?? known.max { ($0.utilization ?? 0) < ($1.utilization ?? 0) }
    }

    /// 다 찬 계정 전체 창인가 — 모델 하나의 한도(`LimitWindow.model`)는 다른 모델을 쓸 수 있어 세지 않는다 (`reachedAccountWideCap` 과 같은
    /// 기준). 초기화 시각이 지났으면 이미 풀린 창이다.
    static func isFull(_ window: LimitWindow, now: Date = Date()) -> Bool {
        guard window.model == nil, (window.utilization ?? 0) >= 1 else { return false }
        return window.resetsAt.map { $0 > now } ?? true
    }

    /// 칩에 경고 기호를 함께 그릴 상태인가 — 값이 있어도 한도에 닿았으면(계정 전체 창이 다 참 · CLI 가 한도 도달 · 제한을 알림)
    /// 숨기지 않는다 (chr-6). 아직 읽지 않았거나 읽지 못한 것은 경고 기호가 아니라 "—" 다.
    static func chipWarns(_ state: State, snapshot: LimitSnapshot, now: Date = Date()) -> Bool {
        switch state {
        case .value(let window): return isFull(window, now: now) || snapshot.status == .subscriptionCap || snapshot.status == .throttled
        case .problem: return true
        case .pending, .unavailable: return false
        }
    }

    // MARK: 글

    /// 칩의 숫자 — "16%" (쓴 비율이다. % 를 빼면 남은 것인지 쓴 것인지 알 수 없었다).
    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    /// 칩에 쓰는 짧은 글: 값이 있으면 "16%", 아직 모르거나 읽지 못했으면 "—", 문제면 nil (칩은 경고 기호를 그린다).
    static func chipText(_ state: State) -> String? {
        switch state {
        case .value(let window):
            guard let utilization = window.utilization else { return "—" }
            return percent(utilization)
        case .pending, .unavailable: return "—"
        case .problem: return nil
        }
    }

    /// 팝오버 · 메뉴바 머리의 상태 이름.
    static func statusName(_ state: State, snapshot: LimitSnapshot) -> String {
        switch state {
        case .value: return snapshot.status.koreanName
        case .pending(.checking): return "확인 중"
        case .pending: return "확인 전"
        case .problem(let status, _): return status.koreanName
        case .unavailable: return LimitStatus.noData.koreanName
        }
    }

    /// 경고색으로 보일 상태인가 (색만으로 말하지 않는다 — 늘 상태 이름과 함께). 아직 읽지 않은 것은 경고가 아니다.
    static func isWarning(_ state: State, snapshot: LimitSnapshot) -> Bool {
        switch state {
        case .value: return snapshot.status != .ok
        case .pending: return false
        case .problem, .unavailable: return true
        }
    }

    /// 구간이 하나도 없을 때 팝오버 · 메뉴바에 보일 설명.
    static func note(_ state: State) -> String? {
        switch state {
        case .value: return nil
        case .pending(.checking): return "한도를 확인하는 중입니다."
        case .pending(.afterFirstProject): return "아직 확인하지 않았습니다 — 첫 프로젝트를 연 뒤에 확인합니다."
        case .pending(.startupCheckOff):
            return "앱을 열 때는 확인하지 않게 해 두었습니다 (설정 > 에이전트). 대화가 끝나면 확인하고, ‘새로고침’으로 지금 확인할 수 있습니다."
        case .pending(.notYet): return "아직 확인하지 않았습니다. ‘새로고침’으로 지금 확인할 수 있습니다."
        case .problem(_, let message), .unavailable(let message): return message ?? "한도 정보를 가져오지 못했습니다."
        }
    }

    /// 짧은 상태 (설정의 Codex 계정 줄 오른쪽). 값이 있으면 nil — 막대가 말한다.
    static func shortStatus(_ state: State) -> String? {
        switch state {
        case .value: return nil
        case .pending(.checking): return "한도 확인 중"
        case .pending: return "한도 확인 전"
        case .problem(let status, _): return status.koreanName
        case .unavailable: return "한도 정보 없음"
        }
    }

    /// 칩 도움말 · 접근성 글의 한 줄 — "Claude · 5시간 한도 16% 사용 · 14:20 확인". 다 찬 계정 전체 창이면 "이번 주 한도 도달 ·
    /// 20:30 초기화 · 14:20 확인" (chr-6), 창은 덜 찼는데 CLI 가 한도 도달 · 제한을 알렸으면 그 상태 이름을 덧붙인다 (`status`).
    static func line(name: String, state: State, fetchedAt: Date?, status: LimitStatus = .ok, now: Date = Date()) -> String {
        let body: String
        switch state {
        case .value(let window) where isFull(window, now: now):
            var text: String = "\(window.label) 한도 도달"
            if let reset = window.resetsAt { text += " · " + HandoffCardText.resetClock(reset, now: now) + " 초기화" }
            if let fetchedAt { text += " · " + checked(fetchedAt, now: now) }
            body = text
        case .value(let window):
            var used: String = "정보 없음"
            if let utilization = window.utilization { used = percent(utilization) }
            var text: String = "\(window.label) 한도 \(used) 사용"
            if status == .subscriptionCap || status == .throttled { text += " · " + status.koreanName }
            if let fetchedAt { text += " · " + checked(fetchedAt, now: now) }
            body = text
        case .pending(.checking): body = "한도 확인 중"
        case .pending(.afterFirstProject): body = "한도 확인 전 — 첫 프로젝트를 연 뒤 확인합니다"
        case .pending(.startupCheckOff): body = "한도 확인 전 — 대화가 끝나면 확인합니다"
        case .pending(.notYet): body = "한도 확인 전"
        case .problem(let status, _): body = status.koreanName
        case .unavailable: body = "한도를 읽지 못했습니다"
        }
        return "\(name) · \(body)"
    }

    /// "14:20 확인" (오늘이 아니면 "10월 2일 14:20 확인" — 시각은 인계 카드 머리와 같은 형식).
    static func checked(_ date: Date, now: Date = Date()) -> String {
        "\(HandoffCardText.resetClock(date, now: now)) 확인"
    }

    /// 팝오버 아래 — 한도를 언제 다시 읽는지. 실행이 끝날 때마다 그 계정을 다시 읽고(`AppModel.runCoordinator(_:didFinish:…)`),
    /// 같은 계정은 1분에 한 번까지다 (`LimitsService.minInterval`). 실행 중에는 CLI 가 알려 주는 값으로 바뀐다.
    static let refreshRule: String = "에이전트가 답을 마칠 때마다 그 계정의 한도를 다시 확인합니다 (1분에 한 번까지)."

    // MARK: 칩 · 팝오버의 줄

    /// 칩 · 팝오버의 한 줄 (Claude 하나 + 등록된 Codex 계정마다 + Antigravity 를 허용한 프로젝트가 있으면 Antigravity).
    struct Entry: Identifiable, Equatable {
        var id: String { snapshot.provider.rawValue + "|" + snapshot.accountID }
        let snapshot: LimitSnapshot
        /// 도움말 · 접근성의 이름 — "Claude" · "Codex" · 계정이 둘 이상이면 "Codex · 업무용".
        let name: String
        /// 칩 · 팝오버에 함께 적는 계정 이름 (계정이 둘 이상일 때만).
        let accountLabel: String?
        let state: State
    }

    /// 칩 · 팝오버에 둘 제공자인가. 이 Mac 에서 CLI 를 찾지 못했거나(설치 안 됨) 지정한 경로를 실행할 수 없으면 뺀다 —
    /// 쓰지 않는 에이전트의 흐린 로고 · "로그인 안 됨" 이 고칠 일처럼 보이지 않게. 아직 확인하기 전(nil)은 둔다.
    static func shows(_ status: CLIStatus?) -> Bool { status?.isUsable ?? true }

    /// 값이 하나도 없으면 칩 앞에 "한도" 를 적는다 — 흐린 로고 둘만으로는 무엇인지 알 수 없었다.
    static func needsCaption(_ entries: [Entry]) -> Bool { !entries.contains { $0.state.hasValue } }

    /// 칩의 도움말 — 줄마다 하나, 끝에 "눌러서 자세히 보기".
    static func chipHelp(_ entries: [Entry], now: Date = Date()) -> String {
        var rows: [String] = entryLines(entries, now: now)
        rows.append("눌러서 자세히 보기")
        return rows.joined(separator: "\n")
    }

    /// 칩의 접근성 이름.
    static func accessibility(_ entries: [Entry], now: Date = Date()) -> String {
        let joined: String = entryLines(entries, now: now).joined(separator: ", ")
        return "한도: " + joined
    }

    private static func entryLines(_ entries: [Entry], now: Date) -> [String] {
        entries.map { (entry: Entry) -> String in
            line(name: entry.name, state: entry.state, fetchedAt: entry.snapshot.fetchedAt, status: entry.snapshot.status, now: now)
        }
    }
}

// MARK: - 메뉴바에 보일 한도

/// 메뉴바 팝오버에 보일 한도 고르기 (설정 > 일반 > 메뉴바). 계정이 늘고 구간(5시간 · 7일 · 모델 묶음)이 쌓이면 팝오버가 화면보다
/// 길어졌다. **숨긴 것만** 저장한다 — 새로 등록한 계정 · 새로 생긴 구간은 처음엔 보인다. 툴바 칩 · 한도 팝오버 · 메뉴바의
/// "확인 필요"(한도에 닿은 계정)는 이 설정과 상관없이 그대로다.
///
/// 키: 계정 하나는 `Entry.id`("claude|" · "codex|<계정 ID>" · "gemini|"), 구간 하나는 그 뒤에 "|" 와 구간 이름 ("claude||이번 주").
/// 구간 이름은 CLI 가 주는 대로라 이름이 바뀌면 새 구간으로 보인다.
enum MenuBarLimits {
    /// 팝오버의 계정 하나와 보일 구간.
    struct Row: Identifiable, Equatable {
        var id: String { entry.id }
        let entry: LimitsPresentation.Entry
        let windows: [LimitWindow]
    }

    static func entryKey(_ entry: LimitsPresentation.Entry) -> String { entry.id }

    static func windowKey(_ entry: LimitsPresentation.Entry, _ window: LimitWindow) -> String {
        entry.id + "|" + window.id
    }

    /// 보일 줄. 숨긴 계정은 빼고, 남은 계정은 숨긴 구간을 뺀다. 구간이 있었는데 모두 숨겼으면 계정째 뺀다 (머리만 남으면 군더더기다).
    /// 아직 구간이 없는 계정(읽기 전 · 읽지 못함)은 그 사실을 말해야 하므로 남긴다.
    static func visible(_ entries: [LimitsPresentation.Entry], hidden: Set<String>) -> [Row] {
        entries.compactMap { entry -> Row? in
            guard !hidden.contains(entryKey(entry)) else { return nil }
            let windows = entry.snapshot.windows.filter { !hidden.contains(windowKey(entry, $0)) }
            if windows.isEmpty, !entry.snapshot.windows.isEmpty { return nil }
            return Row(entry: entry, windows: windows)
        }
    }

    /// 지금 있는 것 가운데 숨긴 줄의 수 — 숨긴 계정은 하나로, 보이는 계정은 숨긴 구간마다 하나로 센다 (팝오버 아래 "숨긴 한도 N개").
    static func hiddenCount(_ entries: [LimitsPresentation.Entry], hidden: Set<String>) -> Int {
        entries.reduce(0) { count, entry in
            if hidden.contains(entryKey(entry)) { return count + 1 }
            return count + entry.snapshot.windows.filter { hidden.contains(windowKey(entry, $0)) }.count
        }
    }

    /// 팝오버 아래의 설정 단추 글.
    static func settingsTitle(hiddenCount: Int) -> String {
        hiddenCount > 0 ? "보일 한도 고르기… (숨김 \(hiddenCount)개)" : "보일 한도 고르기…"
    }

    /// 모두 숨겼을 때 한도 자리에 남기는 한 줄 — 비워 두면 한도가 없는 줄 안다.
    static let allHiddenNote: String = "메뉴바에 보일 한도를 모두 숨겼습니다."
}

// MARK: - 앱의 사실 모으기

extension AppModel {
    /// 한도 글의 사실 — 읽는 중인지, (Claude) 첫 프로젝트 뒤로 미뤘는지 · 앱을 열 때의 확인을 껐는지.
    func limitContext(for scope: AgentScope) -> LimitsPresentation.Context {
        var context = LimitsPresentation.Context(refreshing: limits.isRefreshing.contains(scope))
        if scope.provider == .claude {
            context.deferredUntilProject = deferredClaudeStartup
            context.startupCheckOff = !startupFetchClaudeLimits
        }
        return context
    }

    /// 툴바 한도 칩 · 팝오버에 둘 줄 — Claude 와 등록된 Codex 계정마다, 이 Mac 에서 쓸 수 있는(또는 아직 확인하기 전인) 제공자만
    /// (`LimitsPresentation.shows`). Antigravity 는 허용한 프로젝트가 있을 때만 (`LimitsService.antigravityEnabled` — 그때만 읽는다).
    var limitEntries: [LimitsPresentation.Entry] {
        var entries: [LimitsPresentation.Entry] = []
        if LimitsPresentation.shows(cliStatus[.claude]) {
            let snapshot: LimitSnapshot = limits.claude
            let state: LimitsPresentation.State = LimitsPresentation.state(snapshot, context: limitContext(for: snapshot.scope))
            entries.append(LimitsPresentation.Entry(snapshot: snapshot, name: AgentProvider.claude.displayName,
                                                    accountLabel: nil, state: state))
        }
        if LimitsPresentation.shows(cliStatus[.codex]) {
            let multiple: Bool = accounts.hasMultiple
            for account in accounts.accounts {
                let snapshot: LimitSnapshot = limits.codex(account.id)
                let state: LimitsPresentation.State = LimitsPresentation.state(snapshot, context: limitContext(for: account.scope))
                let label: String? = multiple ? account.label : nil
                var name: String = AgentProvider.codex.displayName
                if let label { name += " · " + label }
                entries.append(LimitsPresentation.Entry(snapshot: snapshot, name: name, accountLabel: label, state: state))
            }
        }
        if limits.antigravityEnabled, LimitsPresentation.shows(cliStatus[.gemini]) {
            let snapshot: LimitSnapshot = limits.gemini
            let state: LimitsPresentation.State = LimitsPresentation.state(snapshot, context: limitContext(for: snapshot.scope))
            entries.append(LimitsPresentation.Entry(snapshot: snapshot, name: AgentProvider.gemini.displayName,
                                                    accountLabel: nil, state: state))
        }
        return entries
    }
}
