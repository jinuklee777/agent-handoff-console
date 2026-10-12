import Foundation

// MARK: - 이어 가기: 한도 임박 제안 (C4) · 칩 = 이어 가기 (C3) · 사용자 메모 (C1) — 순수 판정

enum ContinueTests {

    static func run(_ t: TestKit) async {
        await suggestion(t)
        await apiCreditSuggestion(t)
        await staleTargets(t)
        await limitLine(t)
        await limitLineEmpty(t)
        await choice(t)
        await userMemo(t)
        await limitSpans(t)
        await previewFacts(t)
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let claude = HandoffSource.Agent(provider: .claude, codexAccountID: nil)
    static let codexA = HandoffSource.Agent(provider: .codex, codexAccountID: "acct-a")
    static let codexB = HandoffSource.Agent(provider: .codex, codexAccountID: "acct-b")

    static func snapshot(_ provider: AgentProvider, account: String = "", fetched: TimeInterval = -60,
                         _ windows: [LimitWindow]) -> LimitSnapshot {
        var snap = LimitSnapshot(provider: provider, accountID: account)
        snap.status = .ok
        snap.windows = windows
        snap.fetchedAt = now.addingTimeInterval(fetched)
        return snap
    }

    static func window(_ label: String, _ used: Double?, span: Int?, resets: TimeInterval? = 3600, model: String? = nil) -> LimitWindow {
        LimitWindow(label: label, utilization: used, resetsAt: resets.map { now.addingTimeInterval($0) }, model: model, spanMinutes: span)
    }

    static func target(_ agent: HandoffSource.Agent, _ title: String, _ snap: LimitSnapshot,
                       cli: Bool = true, auth: Bool = true, loginStale: Bool = false,
                       refreshable: Bool = true) -> ContinueSuggestionTarget {
        ContinueSuggestionTarget(agent: agent, title: title, cliUsable: cli, authenticated: auth, limit: snap,
                                 loginStale: loginStale, limitRefreshable: refreshable)
    }

    static func input(source: LimitSnapshot?, targets: [ContinueSuggestionTarget], chip: HandoffSource.Agent = claude,
                      sourceAgent: HandoffSource.Agent = claude, runs: Bool = true, hidden: Bool = false,
                      dismissals: [ContinueSuggestion.DismissKey: ContinueSuggestion.Dismissal] = [:]) -> ContinueSuggestionInput {
        ContinueSuggestionInput(chip: chip, source: sourceAgent, hasWorkedRuns: runs, hidden: hidden,
                                sourceLimit: source, targets: targets, dismissals: dismissals, now: now)
    }

    /// API 크레딧으로 계속 (`ClaudeAPIContinue`) — 제안 줄이 이어 맡기기와 함께 · 혼자 권한다. API 로 실행하는 대화는 구독 사용률과 무관.
    static func apiCreditSuggestion(_ t: TestKit) async {
        await t.group("이어 가기 제안: API 크레딧으로 계속")
        let hot = snapshot(.claude, [window("5시간", 0.81, span: 300)])
        let cool = snapshot(.codex, account: "acct-a", [window("5시간", 0.12, span: 300)])
        var withAPI = input(source: hot, targets: [target(codexA, "Codex", cool)])
        withAPI.apiCreditAvailable = true
        let both = ContinueSuggestion.evaluate(withAPI).suggestion
        await t.check("이어 맡길 대상과 API 크레딧을 함께 권한다", both?.target == codexA && both?.offersAPICredit == true)
        var alone = input(source: hot, targets: [target(codexA, "Codex", cool, cli: false)])
        alone.apiCreditAvailable = true
        let apiOnly = ContinueSuggestion.evaluate(alone).suggestion
        await t.check("받을 에이전트가 없어도 API 크레딧만 권한다 (이어 맡기기 단추 없음)",
                      apiOnly != nil && apiOnly?.target == nil && apiOnly?.offersAPICredit == true && apiOnly?.actionTitle == nil)
        await t.check("API 크레딧이 없고 대상도 없으면 제안하지 않는다 (예전과 같다)",
                      ContinueSuggestion.evaluate(input(source: hot, targets: [target(codexA, "Codex", cool, cli: false)])).suggestion == nil)
        var staleFirst = input(source: hot, targets: [target(codexA, "Codex", snapshot(.codex, account: "acct-a", fetched: -3600,
                                                                                         [window("5시간", 0.12, span: 300)]))])
        staleFirst.apiCreditAvailable = true
        let waiting = ContinueSuggestion.evaluate(staleFirst)
        await t.check("앞 순서 대상을 새로 읽는 동안에도 API 크레딧은 권하고, 새로 읽을 곳도 알린다",
                      waiting.suggestion?.target == nil && waiting.suggestion?.offersAPICredit == true
                        && waiting.stale.limits == [.codex("acct-a")], "\(waiting)")
        var byAPI = withAPI
        byAPI.sourceUsesAPI = true
        await t.check("이 대화가 이미 API 로 실행하면 구독 사용률 제안은 없다", ContinueSuggestion.evaluate(byAPI).suggestion == nil)
        let notCrossed = snapshot(.claude, [window("5시간", 0.40, span: 300)])
        var low = input(source: notCrossed, targets: [])
        low.apiCreditAvailable = true
        await t.check("문턱 아래면 API 크레딧이 있어도 제안하지 않는다", ContinueSuggestion.evaluate(low).suggestion == nil)

        await t.group("이어 가기 대상: API 크레딧으로 받는 Claude")
        var capped = snapshot(.claude, [window("5시간", 1.0, span: 300)])
        capped.status = .subscriptionCap
        var apiClaude = target(claude, "Claude", capped, auth: false, loginStale: true)
        apiClaude.apiCredit = true
        let codexHot = snapshot(.codex, account: "acct-a", [window("5시간", 0.85, span: 300)])
        let fromCodex = input(source: codexHot, targets: [apiClaude], chip: codexA, sourceAgent: codexA)
        await t.equal("판단할 것이 없다 (로그인 · 구독 한도를 새로 읽지 않는다)", ContinueSuggestion.state(of: apiClaude, now: now), .known)
        await t.check("Codex 85% → 구독 한도인 Claude 라도 API 크레딧이면 권한다",
                      ContinueSuggestion.evaluate(fromCodex).suggestion?.target == claude)
        await t.equal("한도 줄: 확인된 받는 쪽", ContinueSuggestion.limitLineChoice([apiClaude], source: codexA, now: now).target, claude)
        await t.equal("한도 줄 대비책: 한도 도달로 빼지 않는다",
                      ContinueSuggestion.limitLineFallback([apiClaude], source: codexA, preferred: nil, now: now), claude)
        var subClaude = apiClaude
        subClaude.apiCredit = false
        await t.check("구독이면 그대로 건너뛴다 (방금 확인한 한도 도달)",
                      ContinueSuggestion.limitLineFallback([subClaude], source: codexA, preferred: nil, now: now) == nil
                        && ContinueSuggestion.limitLineEmpty([subClaude], excluded: [], source: codexA, now: now)
                            == .capped(["Claude"], resetsAt: now.addingTimeInterval(3600)))
    }

    static func suggestion(_ t: TestKit) async {
        await t.group("이어 가기 제안: 판정")
        let hot = snapshot(.claude, [window("5시간", 0.81, span: 300), window("7일", 0.40, span: 10080)])
        let cool = snapshot(.codex, account: "acct-a", [window("5시간", 0.12, span: 300), window("7일", 0.30, span: 10080)])
        let codex = target(codexA, "Codex", cool)

        let shown = ContinueSuggestion.evaluate(input(source: hot, targets: [codex])).suggestion
        await t.check("짧은 창 81% · 대상 여유 → 제안", shown != nil && shown?.target == codexA && shown?.span == .short)
        await t.equal("줄 글 (사용률 · 초기화 시각)", shown?.headline(sourceName: "Claude", resetText: "20:30"),
                      "Claude 5시간 사용률 81% · 20:30 초기화")
        await t.equal("초기화 시각을 모르면 지어내지 않는다", shown?.headline(sourceName: "Claude", resetText: nil),
                      "Claude 5시간 사용률 81% · 초기화 시각 미확인")
        await t.equal("단추 글은 조사가 바뀌지 않는 꼴", shown?.actionTitle, "Codex 에게 이어 맡기기")

        // 창 이름이 출처마다 달라도("현재 세션" ↔ "5시간") 같은 창으로 다룬다 — 길이로 가른다.
        let usage = snapshot(.claude, [window("현재 세션", 0.80, span: 300, resets: nil)])
        let byUsage = ContinueSuggestion.evaluate(input(source: usage, targets: [codex])).suggestion
        await t.check("/usage 의 '현재 세션' (초기화 시각 없음)도 짧은 창", byUsage?.span == .short)
        await t.equal("창 이름은 길이로 — 출처에 따라 '현재 세션' 으로 바뀌지 않는다", byUsage?.shortHeadline(sourceName: "Claude"),
                      "Claude 5시간 사용률 80%")
        var unknownLogin = target(codexA, "Codex", cool, auth: false)
        unknownLogin.loginUnknown = true
        let tagged = ContinueSuggestion.evaluate(input(source: hot, targets: [unknownLogin])).suggestion
        await t.check("로그인 모름인 대상도 권한다 — 그 사실을 함께 (칩 메뉴 · 카드와 같은 판정)",
                      tagged?.target == codexA && tagged?.targetLoginUnknown == true)
        let key = ContinueSuggestion.DismissKey(scope: .claude, span: .short)
        let dismissed = [key: ContinueSuggestion.Dismissal(utilization: 0.80, at: now.addingTimeInterval(-60), resetsAt: nil)]
        await t.check("'나중에' 는 창 이름이 바뀌어도 지킨다 (현재 세션 → 5시간)",
                      ContinueSuggestion.evaluate(input(source: hot, targets: [codex], dismissals: dismissed)).suggestion == nil)
        let crossed = snapshot(.claude, [window("5시간", 0.92, span: 300)])
        await t.check("'나중에' 뒤 90% 를 넘으면 다시", ContinueSuggestion.evaluate(
            input(source: crossed, targets: [codex], dismissals: dismissed)).suggestion != nil)
        let old = [key: ContinueSuggestion.Dismissal(utilization: 0.80, at: now.addingTimeInterval(-6 * 3600), resetsAt: nil)]
        await t.check("'나중에' 는 5시간 뒤 끝난다", ContinueSuggestion.evaluate(
            input(source: hot, targets: [codex], dismissals: old)).suggestion != nil)

        // 미룰 때의 초기화 시각이 지나면 다시 · Codex 처럼 같은 창의 초기화 시각이 1초 흔들려도 미룬 것은 그대로.
        let withReset = [key: ContinueSuggestion.Dismissal(utilization: 0.81, at: now.addingTimeInterval(-60),
                                                            resetsAt: now.addingTimeInterval(-1))]
        await t.check("'나중에' 는 그 창이 초기화되면 끝난다", ContinueSuggestion.evaluate(
            input(source: hot, targets: [codex], dismissals: withReset)).suggestion != nil)
        let jitter = [key: ContinueSuggestion.Dismissal(utilization: 0.81, at: now.addingTimeInterval(-60),
                                                         resetsAt: now.addingTimeInterval(3599))]
        await t.check("초기화 시각이 1초 늦게 와도 '나중에' 는 그대로 (같은 창)", ContinueSuggestion.evaluate(
            input(source: hot, targets: [codex], dismissals: jitter)).suggestion == nil)
        let both = snapshot(.claude, [window("5시간", 0.81, span: 300), window("7일", 0.92, span: 10080, resets: 4 * 86400)])
        await t.check("5시간을 미뤄도 7일이 90% 를 넘으면 7일로 제안", ContinueSuggestion.evaluate(
            input(source: both, targets: [codex], dismissals: dismissed)).suggestion?.span == .long)

        // 긴 창은 문턱이 높다.
        let weekly = snapshot(.claude, [window("7일", 0.80, span: 10080, resets: 4 * 86400)])
        await t.check("7일 창 80% 는 제안하지 않는다 (긴 창은 90%)",
                      ContinueSuggestion.evaluate(input(source: weekly, targets: [codex])).suggestion == nil)
        let weeklyHot = snapshot(.claude, [window("7일", 0.91, span: 10080, resets: 4 * 86400)])
        await t.check("7일 창 91% 는 제안", ContinueSuggestion.evaluate(input(source: weeklyHot, targets: [codex])).suggestion?.span == .long)
        let unknownSpan = snapshot(.claude, [window("1차", 0.80, span: nil)])
        await t.check("길이를 모르는 창은 긴 창으로 (조용한 쪽)",
                      ContinueSuggestion.evaluate(input(source: unknownSpan, targets: [codex])).suggestion == nil)

        // 숨김 · 조건.
        await t.check("칩 ≠ 보내는 쪽이면 숨긴다 (보내는 쪽이 대상이 되어 '같은 에이전트' 오류가 나지 않게)",
                      ContinueSuggestion.evaluate(input(source: hot, targets: [codex], chip: codexA)).suggestion == nil)
        await t.check("실행 기록이 없으면 숨긴다", ContinueSuggestion.evaluate(input(source: hot, targets: [codex], runs: false)).suggestion == nil)
        await t.check("숨김 사실이 있으면 숨긴다", ContinueSuggestion.evaluate(input(source: hot, targets: [codex], hidden: true)).suggestion == nil)
        var capped = hot
        capped.status = .subscriptionCap
        await t.check("한도에 닿은 뒤는 제안이 아니다 (한도 줄이 인계를 권한다)",
                      ContinueSuggestion.evaluate(input(source: capped, targets: [codex])).suggestion == nil)
        let staleSource = snapshot(.claude, fetched: -40 * 60, [window("5시간", 0.81, span: 300)])
        await t.check("보내는 쪽 한도가 30분보다 오래되면 숨긴다",
                      ContinueSuggestion.evaluate(input(source: staleSource, targets: [codex])).suggestion == nil)
        let passed = snapshot(.claude, [window("5시간", 0.81, span: 300, resets: -10)])
        await t.check("초기화가 지난 창은 보지 않는다",
                      ContinueSuggestion.evaluate(input(source: passed, targets: [codex])).suggestion == nil)
        let modelOnly = snapshot(.claude, [window("이번 주 (Fable)", 0.95, span: 10080, model: "Fable")])
        await t.check("모델 하나의 한도는 세지 않는다",
                      ContinueSuggestion.evaluate(input(source: modelOnly, targets: [codex])).suggestion == nil)
        let noData = snapshot(.claude, [window("5시간", nil, span: 300)])
        await t.check("사용률을 모르면 제안하지 않는다", ContinueSuggestion.evaluate(input(source: noData, targets: [codex])).suggestion == nil)

        // 대상.
        let staleTarget = target(codexA, "Codex", snapshot(.codex, account: "acct-a", fetched: -9 * 3600, [window("5시간", 0.10, span: 300)]))
        let evaluation = ContinueSuggestion.evaluate(input(source: hot, targets: [staleTarget]))
        await t.check("오래된 대상 한도로는 제안하지 않고 새로 읽을 곳으로 알린다",
                      evaluation.suggestion == nil && evaluation.stale == ContinueSuggestion.Stale(limits: [.codex("acct-a")]))
        let freshSecond = target(codexB, "Codex · 둘째", snapshot(.codex, account: "acct-b", [window("5시간", 0.05, span: 300)]))
        let ordered = ContinueSuggestion.evaluate(input(source: hot, targets: [staleTarget, freshSecond]))
        await t.check("앞 순서 대상이 오래됐으면 뒤 대상을 권하지 않고 그것부터 새로 읽는다",
                      ordered.suggestion == nil && ordered.stale == ContinueSuggestion.Stale(limits: [.codex("acct-a")]))
        let antigravity = target(HandoffSource.Agent(provider: .gemini, codexAccountID: nil), "Antigravity", LimitSnapshot(provider: .gemini))
        await t.equal("한도를 읽을 수 없는 Antigravity 는 대상도 · 새로 읽을 곳도 아니다",
                      ContinueSuggestion.evaluate(input(source: hot, targets: [antigravity, codex])).suggestion?.target, codexA)
        let hotterTarget = target(codexA, "Codex", snapshot(.codex, account: "acct-a", [window("5시간", 0.85, span: 300)]))
        await t.check("대상이 더 차 있으면 권하지 않는다",
                      ContinueSuggestion.evaluate(input(source: hot, targets: [hotterTarget])).suggestion == nil)
        let loggedOut = target(codexA, "Codex", cool, auth: false)
        let second = target(codexB, "Codex · 둘째", snapshot(.codex, account: "acct-b", [window("5시간", 0.05, span: 300)]))
        await t.equal("로그인을 확인하지 못한 대상은 건너뛰고 다음 순서",
                      ContinueSuggestion.evaluate(input(source: hot, targets: [loggedOut, second])).suggestion?.target, codexB)
        let selfTarget = target(claude, "Claude", cool)
        await t.check("보내는 쪽은 대상이 아니다", ContinueSuggestion.evaluate(input(source: hot, targets: [selfTarget])).suggestion == nil)
    }

    /// 오래된 로그인 · 앱이 읽지 않는 한도 — 판단하지 못한 대상을 건너뛰지 않고 새로 읽을 곳으로, 영영 막지는 않게.
    static func staleTargets(_ t: TestKit) async {
        await t.group("이어 가기 제안: 오래된 로그인 · 읽지 않는 한도")
        let hotCodex = snapshot(.codex, account: "acct-a", [window("5시간", 0.80, span: 300)])
        let coolClaude = snapshot(.claude, [window("5시간", 0.10, span: 300), window("7일", 0.20, span: 10080)])
        let coolB = snapshot(.codex, account: "acct-b", [window("5시간", 0.05, span: 300)])
        func codexSource(_ targets: [ContinueSuggestionTarget]) -> ContinueSuggestion.Evaluation {
            ContinueSuggestion.evaluate(input(source: hotCodex, targets: targets, chip: codexA, sourceAgent: codexA))
        }
        let fresh = codexSource([target(claude, "Claude", coolClaude), target(codexB, "Codex · 둘째", coolB)])
        await t.equal("Codex 80% → 로그인 · 한도가 확인된 Claude 에게", fresh.suggestion?.target, claude)
        let oldLogin = codexSource([target(claude, "Claude", coolClaude, auth: false, loginStale: true),
                                    target(codexB, "Codex · 둘째", coolB)])
        await t.check("Claude 로그인 사실이 오래됐으면 건너뛰지 않고 그것부터 다시 확인 (둘째를 권하지 않는다)",
                      oldLogin.suggestion == nil && oldLogin.stale == ContinueSuggestion.Stale(logins: [.claude]), "\(oldLogin)")
        let staleClaude = snapshot(.claude, fetched: -2 * 3600, [window("5시간", 0.10, span: 300)])
        let both = codexSource([target(claude, "Claude", staleClaude, auth: false, loginStale: true)])
        await t.equal("로그인 · 한도가 함께 오래됐으면 둘 다", both.stale, ContinueSuggestion.Stale(limits: [.claude], logins: [.claude]))
        let unknownNow = codexSource([target(claude, "Claude", coolClaude, auth: false), target(codexB, "Codex · 둘째", coolB)])
        await t.equal("방금 확인한 '모름' · '로그인 안 됨' 은 건너뛴다 (실패하는 확인이 다음 순서를 영영 막지 않게)",
                      unknownNow.suggestion?.target, codexB)
        let neverRead = snapshot(.claude, fetched: 0, [])
        var unread = neverRead
        unread.fetchedAt = nil
        let notRefreshable = codexSource([target(claude, "Claude", unread, refreshable: false), target(codexB, "Codex · 둘째", coolB)])
        await t.check("앱이 스스로 읽지 않는 Claude 한도(설정을 끔)는 기다리지 않고 건너뛴다 — 새로 읽을 곳도 아니다",
                      notRefreshable.suggestion?.target == codexB && notRefreshable.stale.isEmpty, "\(notRefreshable)")
        let refreshable = codexSource([target(claude, "Claude", unread), target(codexB, "Codex · 둘째", coolB)])
        await t.equal("읽어도 되면 그것부터 새로 읽는다", refreshable.stale, ContinueSuggestion.Stale(limits: [.claude]))

        await t.group("이어 가기 제안: [나중에] 도움말")
        func made(_ used: Double, resets: TimeInterval?) -> ContinueSuggestion? {
            ContinueSuggestion.evaluate(input(source: snapshot(.claude, [window("5시간", used, span: 300, resets: resets)]),
                                              targets: [target(codexA, "Codex", snapshot(.codex, account: "acct-a",
                                                                                         [window("5시간", 0.1, span: 300)]))])).suggestion
        }
        await t.equal("90% 아래 · 초기화 시각을 안다 → 세 조건",
                      made(0.81, resets: 3600)?.laterHelp, "이 계정의 5시간 한도는 사용률이 90% 를 넘거나 초기화되거나 5시간이 지나면 다시 알립니다")
        await t.equal("초기화 시각을 모르면 초기화 조건은 없다 (Claude /usage 의 '현재 세션')",
                      made(0.81, resets: nil)?.laterHelp, "이 계정의 5시간 한도는 사용률이 90% 를 넘거나 5시간이 지나면 다시 알립니다")
        await t.equal("이미 90% 를 넘었으면 구간 조건은 없다",
                      made(0.92, resets: 3600)?.laterHelp, "이 계정의 5시간 한도는 초기화되거나 5시간이 지나면 다시 알립니다")
        let weekly = ContinueSuggestion.evaluate(input(source: snapshot(.claude, [window("이번 주", 0.93, span: 10080, resets: nil)]),
                                                       targets: [target(codexA, "Codex", snapshot(.codex, account: "acct-a",
                                                                                                  [window("5시간", 0.1, span: 300)]))])).suggestion
        await t.equal("긴 창(늘 90% 이상) · 초기화 시각 모름 → 5시간만", weekly?.laterHelp, "이 계정의 7일 한도는 5시간이 지나면 다시 알립니다")
    }

    /// 한도 도달 줄의 받는 쪽 — 대비책(반대편)과 기대값이 달라 고르기가 실제로 일했는지 가려지는 배치로.
    static func limitLine(_ t: TestKit) async {
        await t.group("한도 줄의 받는 쪽: 판정")
        let capped: LimitSnapshot = {
            var snap = snapshot(.codex, account: "acct-a", [window("5시간", 1.0, span: 300)])
            snap.status = .subscriptionCap
            return snap
        }()
        let coolB = snapshot(.codex, account: "acct-b", [window("5시간", 0.05, span: 300)])
        let coolClaude = snapshot(.claude, [window("5시간", 0.10, span: 300)])
        let next = ContinueSuggestion.limitLineChoice([target(codexA, "Codex", capped), target(codexB, "Codex · 둘째", coolB)],
                                                      source: claude, now: now)
        await t.equal("첫 대상이 한도에 닿았으면 다음 순서 (고른 것 — 정하지 못함이 아니다)", next.target, codexB)
        let none = ContinueSuggestion.limitLineChoice([target(codexA, "Codex", capped)], source: claude, now: now)
        await t.check("확인된 대상이 없으면 정하지 않는다 (부른 쪽이 대비책을 고른다)", none.target == nil && none.stale.isEmpty)
        var unknownLogin = target(codexB, "Codex · 둘째", coolB, auth: false)
        unknownLogin.loginUnknown = true
        let tagged = ContinueSuggestion.limitLineChoice([unknownLogin], source: claude, now: now)
        await t.check("로그인 모름인 대상도 고른다 — 그 사실을 함께 (모든 입구가 같은 판정)", tagged.target == codexB && tagged.loginUnknown)

        await t.group("한도 줄의 대비책: 받을 수 없다고 확인된 에이전트는 권하지 않는다")
        var uninstalled = target(codexA, "Codex", coolB, cli: false)
        uninstalled.knownUnusable = true
        await t.check("반대편이 설치 안 됨 · 로그인 안 됨이면 권하지 않는다 (다른 대상도 없으면 nil)",
                      ContinueSuggestion.limitLineFallback([uninstalled], source: claude, preferred: codexA, now: now) == nil)
        var notLoggedIn = target(codexB, "Codex · 둘째", coolB, auth: false)
        notLoggedIn.knownUnusable = true
        let fresh = target(codexB, "Codex · 둘째", coolB, auth: false)
        await t.equal("반대편을 권할 수 없으면 순서의 다른 대상 (받을 수 없다고 확인되지 않은 것)",
                      ContinueSuggestion.limitLineFallback([uninstalled, fresh], source: claude, preferred: codexA, now: now), codexB)
        await t.check("방금 확인한 한도 도달도 권하지 않는다",
                      ContinueSuggestion.limitLineFallback([target(codexA, "Codex", capped)], source: claude, preferred: codexA, now: now) == nil
                        && ContinueSuggestion.limitLineFallback([notLoggedIn], source: claude, preferred: nil, now: now) == nil)
        await t.equal("목록에 없는 반대편(계정 목록을 읽기 전)은 받을 수 없다고 확인된 것이 아니다",
                      ContinueSuggestion.limitLineFallback([], source: claude, preferred: codexA, now: now), codexA)
        let usesClaude = ContinueSuggestion.limitLineChoice([target(claude, "Claude", coolClaude), target(codexB, "Codex · 둘째", coolB)],
                                                            source: codexA, now: now)
        let noClaudeLogin = ContinueSuggestion.limitLineChoice([target(claude, "Claude", coolClaude, auth: false),
                                                                target(codexB, "Codex · 둘째", coolB)], source: codexA, now: now)
        await t.check("로그인이 확인된 Claude 를 고르고, 로그인을 빼면 둘째 (대조)",
                      usesClaude.target == claude && noClaudeLogin.target == codexB)
        let oldLogin = ContinueSuggestion.limitLineChoice([target(claude, "Claude", coolClaude, auth: false, loginStale: true),
                                                           target(codexB, "Codex · 둘째", coolB)], source: codexA, now: now)
        await t.check("Claude 로그인 사실이 오래됐으면 둘째로 건너뛰지 않고 정하지 않은 채 다시 확인",
                      oldLogin.target == nil && oldLogin.stale == ContinueSuggestion.Stale(logins: [.claude]), "\(oldLogin)")
        let oldLimit = snapshot(.claude, fetched: -3 * 3600, [window("5시간", 0.10, span: 300)])
        let staleLimit = ContinueSuggestion.limitLineChoice([target(claude, "Claude", oldLimit), target(codexB, "Codex · 둘째", coolB)],
                                                            source: codexA, now: now)
        await t.check("몇 시간 전 한도로 고르지 않는다 (제안과 같은 30분)",
                      staleLimit.target == nil && staleLimit.stale == ContinueSuggestion.Stale(limits: [.claude]), "\(staleLimit)")
    }

    /// 한도 줄이 권할 받는 쪽이 없을 때의 까닭 (hand-4 · set-n4) — 설정에서 "받지 않음" 으로 뺐다 · 받는 쪽도 한도 · 쓸 수 없음.
    static func limitLineEmpty(_ t: TestKit) async {
        await t.group("한도 줄: 받는 쪽이 없는 까닭 — 설정에서 뺌 · 받는 쪽도 한도 · 쓸 수 없음")
        let cool = snapshot(.codex, account: "acct-a", [window("5시간", 0.10, span: 300)])
        let capped: LimitSnapshot = {
            var snap = snapshot(.codex, account: "acct-b", [window("5시간", 1.0, span: 300, resets: 2 * 3600)])
            snap.status = .subscriptionCap
            return snap
        }()
        var uninstalled = target(codexA, "Codex", cool, cli: false)
        uninstalled.knownUnusable = true
        let excludedCodex = target(codexA, "Codex", cool)
        typealias Empty = ContinueSuggestion.LimitLineEmpty
        await t.equal("받을 수 있는 Codex 를 '받지 않음' 으로 뺐다 — 설치 · 로그인이 아니라 설정을 가리킨다",
                      ContinueSuggestion.limitLineEmpty([], excluded: [excludedCodex], source: claude, now: now), Empty.excluded(["Codex"]))
        await t.equal("뺀 대상이 설치 안 됨이면 뺀 것은 까닭이 아니다 — 쓸 수 없음",
                      ContinueSuggestion.limitLineEmpty([], excluded: [uninstalled], source: claude, now: now), Empty.unavailable)
        let cappedTarget = target(codexB, "Codex · 둘째", capped)
        let cappedEmpty = ContinueSuggestion.limitLineEmpty([cappedTarget, uninstalled], excluded: [], source: claude, now: now)
        await t.equal("받는 쪽도 방금 한도에 닿았다 — 그 이름과 초기화 시각",
                      cappedEmpty, Empty.capped(["Codex · 둘째"], resetsAt: now.addingTimeInterval(2 * 3600)))
        await t.equal("뺀 대상도 방금 한도면 한도가 까닭이다 (다시 켜도 받을 수 없다)",
                      ContinueSuggestion.limitLineEmpty([], excluded: [target(codexB, "Codex · 둘째", capped)], source: claude, now: now),
                      Empty.capped(["Codex · 둘째"], resetsAt: now.addingTimeInterval(2 * 3600)))
        await t.equal("보내는 쪽 · Antigravity 는 세지 않는다 — 나머지가 쓸 수 없으면 설치 · 로그인 안내",
                      ContinueSuggestion.limitLineEmpty([target(claude, "Claude", cool), uninstalled], excluded: [],
                                                        source: claude, now: now), Empty.unavailable)
        let excludedText: String = ContinueSuggestion.limitLineEmptyText(.excluded(["Codex"]), now: now)
        await t.check("뺀 경우의 글: 설정 > 인계와 입력창의 에이전트 메뉴를 말하고, 설치 · 로그인을 말하지 않는다",
                      excludedText.contains("설정 > 인계") && excludedText.contains("에이전트 메뉴") && !excludedText.contains("설치"),
                      excludedText)
        let cappedText: String = ContinueSuggestion.limitLineEmptyText(cappedEmpty, now: now)
        await t.check("한도인 경우의 글: 이름 · 사용 한도 · 초기화 시각", cappedText.contains("Codex · 둘째 도 사용 한도에 닿았습니다")
                        && cappedText.contains(HandoffCardText.resetClock(now.addingTimeInterval(2 * 3600), now: now)), cappedText)
        await t.check("쓸 수 없는 경우의 글은 예전 그대로 (설치하거나 로그인)",
                      ContinueSuggestion.limitLineEmptyText(.unavailable).contains("설치하거나 로그인하면"))
        let banner = AutomaticHandoffGate.noTargetNotice(excludedNames: ["Claude"])
        let missing = AutomaticHandoffGate.noTargetNotice(excludedNames: [])
        await t.check("자동 인계: 뺀 에이전트만 남았으면 'CLI 를 찾지 못했다' 가 아니라 설정 > 인계로",
                      banner.opens == .handoffSettings && banner.text.contains("Claude 에게는") && !banner.text.contains("CLI")
                        && missing.opens == .firstRunCheck && missing.text.contains("CLI 를 찾지 못했습니다"), banner.text)
    }

    static let gemini = HandoffSource.Agent(provider: .gemini, codexAccountID: nil)

    static func choice(_ t: TestKit) async {
        await t.group("에이전트 칩 = 이어 가기: 판정")
        func input(chip: HandoffSource.Agent = claude, source: HandoffSource.Agent = claude, runs: Bool = true,
                   loaded: Bool = true, busy: Bool = false, card: HandoffSource.Agent? = nil, hasCard: Bool = false,
                   allowed: Bool = true, resumable: Set<String> = []) -> ContinueChoiceInput {
            ContinueChoiceInput(chip: chip, source: source, hasWorkedRuns: runs, loaded: loaded, busy: busy,
                                cardTarget: card, hasCard: hasCard || card != nil, handoffAllowed: allowed, resumableKeys: resumable)
        }
        await t.equal("기록이 있으면 다른 에이전트 = 이어 맡기기", ContinueChoice.action(for: codexA, input()), .continueWith)
        await t.equal("지금 칩", ContinueChoice.action(for: claude, input()), .current)
        await t.equal("칩만 다른 곳에 가 있으면 보내는 쪽 행은 되돌리기",
                      ContinueChoice.action(for: claude, input(chip: codexA)), .revertChip)
        await t.equal("칩만 다른 곳에 가 있으면 그 칩 행 = 이어 맡기기 (보내는 쪽의 맥락을 넘길 곳)",
                      ContinueChoice.action(for: codexA, input(chip: codexA)), .continueWith)
        await t.equal("기록이 없으면 칩만 바꾼다", ContinueChoice.action(for: codexA, input(runs: false)), .switchChip)
        await t.equal("인계할 수 없는 대화(자동 작업)는 칩만", ContinueChoice.action(for: codexA, input(allowed: false)), .switchChip)
        await t.equal("칸을 다 읽기 전에는 막는다 (기록이 없어 보여 칩만 바뀌지 않게)",
                      ContinueChoice.action(for: codexA, input(loaded: false)), .disabled(.loading))
        await t.equal("실행 중이면 이어 맡기기를 막는다", ContinueChoice.action(for: codexA, input(busy: true)), .disabled(.busy))
        await t.equal("실행 중이어도 칩만 되돌리기는 된다 (다음 메시지부터)",
                      ContinueChoice.action(for: claude, input(chip: codexA, busy: true)), .revertChip)
        await t.equal("카드의 받는 쪽 = 그 카드로", ContinueChoice.action(for: codexA, input(card: codexA)), .showCard)
        await t.equal("카드가 있을 때 셋째 = 받는 쪽 바꾸기", ContinueChoice.action(for: codexB, input(card: codexA)), .replaceCardTarget)
        await t.equal("카드가 있을 때 보내는 쪽 = 카드 거두기", ContinueChoice.action(for: claude, input(card: codexA)), .cancelCard)
        var locked = input(card: codexA)
        locked.cardLocked = true
        await t.equal("인계를 보내는 중이면 모든 행을 끈다", [ContinueChoice.action(for: claude, locked), ContinueChoice.action(for: codexA, locked)],
                      [.disabled(.locked), .disabled(.locked)])
        await t.check("보내는 중에는 '인계 없이 바꾸기' 도 끈다", !ContinueChoice.plainSwitchEnabled(locked))
        await t.check("카드가 있으면 '인계 없이 바꾸기' 를 끈다",
                      !ContinueChoice.plainSwitchEnabled(input(card: codexA)) && ContinueChoice.plainSwitchEnabled(input()))
        var unknown = input(card: codexA)
        unknown.cardUnknown = true
        await t.equal("전달 여부 미확인 카드: 받는 쪽은 카드로 · 보내는 쪽은 닫기 · 셋째는 끈다 (다시 보내지 않는다)",
                      [ContinueChoice.action(for: codexA, unknown), ContinueChoice.action(for: claude, unknown),
                       ContinueChoice.action(for: codexB, unknown)],
                      [.showCard, .cancelCard, .disabled(.cardUnknown)])
        await t.equal("미확인 카드의 닫기 부제는 '넘기지 않습니다' 라 하지 않는다",
                      ContinueChoice.subtitle(for: .cancelCard, unknown), "전달 여부를 확인하지 못한 카드를 닫습니다")
        var summarizing = input(card: codexA)
        summarizing.cardSummarizing = true
        await t.equal("Gemini 로 다시 정리하는 중에는 받는 쪽을 바꾸지 않는다 (카드의 '바꾸기' 와 같다)",
                      ContinueChoice.action(for: codexB, summarizing), .disabled(.summarizing))

        await t.group("에이전트 칩 = 이어 가기: 쓸 수 없는 에이전트 · 계정")
        var blocked = input()
        let notLoggedIn = ContinueChoice.handoffBlock(.notLoggedIn, provider: .codex)!
        blocked.switchBlocks = [gemini.key: ContinueChoice.antigravityNotAllowed]
        blocked.handoffBlocks = [codexB.key: notLoggedIn]
        await t.equal("허용하지 않은 Antigravity: 이어 맡기기 · 칩 바꾸기 모두 끈다 (행 오른쪽에 '설정에서 허용 필요')",
                      [ContinueChoice.action(for: gemini, blocked), ContinueChoice.plainSwitchAction(for: gemini, blocked)],
                      [.disabled(.unavailable(ContinueChoice.antigravityNotAllowed)), .disabled(.unavailable(ContinueChoice.antigravityNotAllowed))])
        await t.equal("로그인 안 됨이 확인된 Codex 계정: 이어 맡기기는 끄고 칩만 바꾸기는 둔다",
                      [ContinueChoice.action(for: codexB, blocked), ContinueChoice.plainSwitchAction(for: codexB, blocked)],
                      [.disabled(.unavailable(notLoggedIn)), .switchChip])

        await t.group("에이전트 칩 = 이어 가기: 받는 쪽 준비 상태 (모든 입구가 같은 판정)")
        let uninstalled = ContinueChoice.switchBlock(.notInstalled, provider: .codex)
        await t.check("설치 안 됨 · 실행 불가: 이어 맡기기도 바꾸기도 막는다 (도움말은 시작 점검 · 설정으로)",
                      uninstalled?.meta == "설치 안 됨" && uninstalled?.help.contains("시작 점검") == true
                        && ContinueChoice.handoffBlock(.notInstalled, provider: .codex) == uninstalled
                        && ContinueChoice.switchBlock(.pathInvalid, provider: .claude)?.meta == "실행 불가")
        await t.check("로그인 안 됨: 이어 맡기기만 막는다 (Claude 는 로그인 명령까지) · 바꾸기는 막지 않는다",
                      notLoggedIn.meta == "로그인 필요" && ContinueChoice.switchBlock(.notLoggedIn, provider: .codex) == nil
                        && ContinueChoice.handoffBlock(.notLoggedIn, provider: .claude)?.help.contains(AgentSetupGuide.claudeLoginCommand) == true)
        await t.check("로그인 모름(파일이 아닌 자격 저장소 등)은 막지 않고 꼬리표만 — 점검표의 황색 통과와 같다",
                      ContinueChoice.handoffBlock(.loginUnknown, provider: .codex) == nil
                        && ContinueChoice.readinessTag(.loginUnknown, provider: .codex) == ContinueChoice.loginUnknownTag
                        && ContinueChoice.readinessTag(.loginUnknown, provider: .gemini) == nil
                        && ContinueChoice.handoffBlock(.checking, provider: .codex) == nil)
        var notInstalled = input()
        notInstalled.switchBlocks = [codexB.key: uninstalled!]
        notInstalled.handoffBlocks = [codexB.key: uninstalled!]
        await t.equal("설치 안 된 에이전트: 이어 맡기기 행은 끄고(까닭 '설치 안 됨') '맥락 없이 바꾸기' 에는 다시 놓지 않는다",
                      [ContinueChoice.action(for: codexB, notInstalled) == .disabled(.unavailable(uninstalled!)),
                       ContinueChoice.plainSwitchAgents([claude, codexA, codexB, gemini], notInstalled).contains(codexB)],
                      [true, false])
        var noHistoryBlocked = blocked
        noHistoryBlocked.hasWorkedRuns = false
        await t.equal("기록이 없는 대화의 Antigravity 칩 바꾸기도 끈다", ContinueChoice.action(for: gemini, noHistoryBlocked),
                      .disabled(.unavailable(ContinueChoice.antigravityNotAllowed)))
        var cardBlocked = blocked
        cardBlocked.cardTarget = codexA
        cardBlocked.hasCard = true
        await t.equal("카드의 받는 쪽을 허용하지 않은 Antigravity 로 바꾸지 않는다", ContinueChoice.action(for: gemini, cardBlocked),
                      .disabled(.unavailable(ContinueChoice.antigravityNotAllowed)))
        await t.check("끈 까닭: 메뉴 전체 것은 머리 한 줄로, 행 하나의 것은 그 행에",
                      Block.loading.isMenuWide && Block.busy.isMenuWide && Block.locked.isMenuWide
                        && !Block.unavailable(ContinueChoice.antigravityNotAllowed).isMenuWide
                        && !Block.cardOpen.isMenuWide)
        await t.equal("행 하나의 까닭은 그 행 오른쪽의 짧은 글이 있다 · 메뉴 전체 것은 없다 (머리 줄이 말한다)",
                      [Block.cardOpen.meta, Block.unavailable(ContinueChoice.antigravityNotAllowed).meta,
                       Block.busy.meta, Block.loading.meta],
                      ["인계 카드가 있음", "설정에서 허용 필요", nil, nil])
        await t.check("메뉴 머리 줄이 말하지 않는 카드 있음(인계 없이 바꾸기)은 메뉴 전체 까닭이 아니다",
                      ContinueChoice.menuNote(input(card: codexA)) == nil && ContinueChoice.plainSwitchBlock(input(card: codexA)) == .cardOpen)

        await t.group("에이전트 칩 = 이어 가기: 인계 없이 바꾸기")
        await t.check("묶음은 기록이 있고 인계할 수 있는 대화에만 (아니면 위 행이 이미 칩만 바꾼다)",
                      ContinueChoice.showsPlainSwitch(input()) && !ContinueChoice.showsPlainSwitch(input(runs: false))
                        && !ContinueChoice.showsPlainSwitch(input(allowed: false)) && !ContinueChoice.showsPlainSwitch(input(loaded: false)))
        let agents = [claude, codexA, codexB, gemini]
        await t.equal("지금 칩은 빼고 나머지", ContinueChoice.plainSwitchAgents(agents, input()), [codexA, codexB, gemini])
        await t.equal("칩만 되돌리는 보내는 쪽은 위 행에 있으니 빼고 (같은 뜻이 두 번 나오지 않게)",
                      ContinueChoice.plainSwitchAgents(agents, input(chip: codexA)), [codexB, gemini])
        await t.equal("칩만 바꾸기 행", [ContinueChoice.plainSwitchAction(for: codexA, input()), ContinueChoice.plainSwitchAction(for: claude, input())],
                      [.switchChip, .current])
        await t.equal("실행 중에도 Codex 계정을 바꾼다 (세션은 대화의 것 하나 — 다음 메시지부터) · 다른 에이전트로도 바꾼다",
                      [ContinueChoice.action(for: codexB, input(chip: codexA, source: codexA, busy: true)),
                       ContinueChoice.plainSwitchAction(for: claude, input(chip: codexA, source: codexA, busy: true))],
                      [.switchAccount, .switchChip])
        await t.equal("카드가 있으면 칩만 바꾸기를 끈 까닭", ContinueChoice.plainSwitchAction(for: codexB, input(card: codexA)), .disabled(.cardOpen))

        let withSession = input(resumable: [claude.key])
        await t.check("세션이 있으면: 이전 세션을 이어 간다 — 그 뒤 일은 모른다",
                      ContinueChoice.plainSwitchSubtitle(for: claude, name: "Claude", withSession)?.contains("이전 세션을 이어 갑니다") == true)
        await t.check("세션이 없으면: 새 세션 — 지금까지의 대화를 모른다",
                      ContinueChoice.plainSwitchSubtitle(for: codexA, name: "Codex", input())?.hasPrefix("새 세션으로 시작합니다") == true)
        await t.check("Codex 는 어느 계정이든 이 대화의 Codex 세션을 이어 간다 (계정이 달라도)",
                      ContinueChoice.plainSwitchSubtitle(for: codexB, name: "Codex · 둘째", input(resumable: [codexB.key]))
                        == "이 대화의 Codex 세션을 이어 갑니다 — 그 뒤에 다른 에이전트가 한 일은 모릅니다")
        await t.equal("보내는 쪽이 Codex 면 같은 Codex 의 다른 계정은 '맥락 없이 바꾸기' 에 두지 않는다 (위 행이 계정만 바꾼다)",
                      ContinueChoice.plainSwitchAgents(agents, input(chip: codexA, source: codexA)), [claude, gemini])

        await t.group("에이전트 칩 = 이어 가기: 같은 Codex 의 다른 계정 = 계정만 바꾸기 (인계 없음)")
        let codexSource = input(chip: codexA, source: codexA)
        await t.equal("다른 계정 행 = 계정 바꾸기 · 지금 계정 = 지금 칩",
                      [ContinueChoice.action(for: codexB, codexSource), ContinueChoice.action(for: codexA, codexSource)],
                      [.switchAccount, .current])
        await t.equal("칩을 다른 계정으로 바꿔 둔 뒤: 그 계정 = 지금 칩 · 보내는 쪽 계정 = 칩만 되돌리기",
                      [ContinueChoice.action(for: codexB, input(chip: codexB, source: codexA)),
                       ContinueChoice.action(for: codexA, input(chip: codexB, source: codexA))],
                      [.current, .revertChip])
        await t.check("계정 바꾸기 행은 이어 맡기기 행이 아니다 (글 · 화살표)", !ContinueChoice.continues(codexB, codexSource))
        await t.equal("카드가 있는 동안은 계정도 바꾸지 않는다",
                      ContinueChoice.action(for: codexB, input(chip: codexA, source: codexA, card: claude)), .disabled(.cardOpen))
        var codexBlocked = codexSource
        codexBlocked.switchBlocks = [codexB.key: ContinueChoice.switchBlock(.notInstalled, provider: .codex)!]
        await t.check("바꿀 수도 없는 계정(CLI 없음)은 끈다",
                      ContinueChoice.action(for: codexB, codexBlocked) == .disabled(.unavailable(codexBlocked.switchBlocks[codexB.key]!)))
        await t.equal("계정 바꾸기 행의 부제 · 앱의 동작",
                      [ContinueChoice.subtitle(for: .switchAccount, codexSource) ?? "",
                       ContinueChoice.effect(of: .switchAccount, agent: codexB) == .chooseAgent(codexB) ? "chooseAgent" : "?"],
                      [CodexAccountSwitch.rowSubtitle, "chooseAgent"])
        await t.check("같은 Codex 의 다른 계정 판정 — 같은 계정 · 다른 제공자는 아니다",
                      CodexAccountSwitch.isSwitch(from: codexA, to: codexB) && !CodexAccountSwitch.isSwitch(from: codexA, to: codexA)
                        && !CodexAccountSwitch.isSwitch(from: claude, to: codexB) && !CodexAccountSwitch.isSwitch(from: codexA, to: claude))
        await t.check("기록이 없는 대화는 부제 없음", ContinueChoice.plainSwitchSubtitle(for: codexA, name: "Codex", input(runs: false)) == nil)

        await t.group("에이전트 칩 = 이어 가기: 글 · 머리 줄")
        await t.equal("이어 맡기기 행 글 · 부제", [ContinueChoice.continueTitle(name: "Codex · 둘째"),
                                                ContinueChoice.subtitle(for: .continueWith, input())],
                      ["Codex · 둘째 에게 이어 맡기기", "넘기기 전에 인계 문서를 먼저 보여 줍니다"])
        await t.check("이어 맡기기 행 = 기록이 있고 보내는 쪽 · 카드의 받는 쪽이 아닌 행 (지금 끈 행이어도)",
                      ContinueChoice.continues(codexA, input()) && ContinueChoice.continues(codexA, input(busy: true))
                        && !ContinueChoice.continues(claude, input()) && !ContinueChoice.continues(codexA, input(runs: false))
                        && !ContinueChoice.continues(codexA, input(card: codexA)) && ContinueChoice.continues(codexB, input(card: codexA)))
        await t.equal("머리 줄: 실행 중 · 백그라운드 수", ContinueChoice.menuNote(input(busy: true), busyNote: " (백그라운드 작업 2개)"),
                      "실행이 끝나면 이어 맡길 수 있습니다 (백그라운드 작업 2개)")
        await t.check("머리 줄: 평소 · 기록 없음 · 카드에는 없다 (행의 부제가 말한다)",
                      ContinueChoice.menuNote(input()) == nil && ContinueChoice.menuNote(input(runs: false, busy: true)) == nil
                        && ContinueChoice.menuNote(input(card: codexA)) == nil)
        await t.equal("머리 줄: 읽는 중 · 보내는 중", [ContinueChoice.menuNote(input(loaded: false)), ContinueChoice.menuNote(locked)],
                      [Block.loading.message, Block.locked.message])
        await t.equal("칩 바꾸기 도움말은 조사가 바뀌지 않는 꼴", ContinueChoice.help(for: .switchChip, name: "Antigravity"),
                      "다음 메시지를 Antigravity 에게 보냅니다.")
        await t.equal("끈 행의 도움말 = 그 까닭", ContinueChoice.help(for: .disabled(.busy), name: "Codex"), Block.busy.message)
        await t.equal("'자동' 을 고른 대화의 지금 칩 행은 자동을 푼다고 말한다",
                      [ContinueChoice.help(for: .current, name: "Claude", autoSelected: true), ContinueChoice.help(for: .current, name: "Claude")],
                      ["자동 작업을 풀고 다음 메시지를 Claude 에게 보냅니다.", "다음 메시지는 지금처럼 Claude 에게 갑니다."])

        await t.group("에이전트 칩 = 이어 가기: 판정 → 앱의 동작")
        await t.equal("판정마다 앱이 할 일",
                      [ContinueChoice.effect(of: .switchChip, agent: codexA), ContinueChoice.effect(of: .revertChip, agent: claude),
                       ContinueChoice.effect(of: .continueWith, agent: codexA), ContinueChoice.effect(of: .showCard, agent: codexA),
                       ContinueChoice.effect(of: .replaceCardTarget, agent: codexB), ContinueChoice.effect(of: .cancelCard, agent: claude),
                       ContinueChoice.effect(of: .current, agent: claude), ContinueChoice.effect(of: .disabled(.busy), agent: codexA)],
                      [.chooseAgent(codexA), .chooseAgent(claude), .prepareHandoff(codexA), .revealCard,
                       .replaceCardTarget(codexB), .cancelCard, .none, .none])
    }

    typealias Block = ContinueChoice.Block

    static func userMemo(_ t: TestKit) async {
        await t.group("인계 문서: 사용자가 덧붙인 말")
        let packet = HandoffPacket(goal: "목표", constraints: "제약", completed: [], inProgress: [], decisions: [],
                                   failedAttempts: [], changedFiles: GitSnapshot(), testsRun: [], interrupted: [],
                                   nextActions: ["테스트를 고친다"], references: [], unverified: [],
                                   transcriptExcerpt: "사용자: 고쳐 줘", fromProvider: .claude, toProvider: .codex, baseSeq: 3)
        let rendered = HandoffPacketBuilder.render(packet, threadTitle: "대화", projectPath: "/repo")
        let marked = HandoffPacketBuilder.markAuthorship(rendered, packet: packet, review: "사람 검토함")
        let sent = HandoffPacketBuilder.insertUserMemo(marked, memo: "  로그인 화면은 건드리지 마세요.\n")
        let preamble = sent.range(of: "이 메시지는 Agent Handoff Console 앱이 보냈습니다")
        let memo = sent.range(of: "## 사용자가 덧붙인 말 (사용자가 직접 씀)\n로그인 화면은 건드리지 마세요.\n")
        let next = sent.range(of: "## 다음 행동")
        let folder = sent.range(of: "프로젝트 폴더: /repo")
        await t.check("앞머리가 맨 앞에 남는다", preamble?.lowerBound == sent.startIndex)
        if let memo, let next, let folder {
            await t.check("폴더 줄 뒤 · 다음 행동 앞", folder.upperBound < memo.lowerBound && memo.upperBound <= next.lowerBound)
        } else {
            await t.check("메모 · 다음 행동 · 폴더 줄이 있다", false, sent)
        }
        await t.check("독립 작업 폴더에서 일하는 대화는 폴더 줄이 그것을 밝힌다 (맨 \"작업 폴더\" 가 아니라)",
                      HandoffPacketBuilder.render(packet, threadTitle: "대화", projectPath: "/wt", inWorktree: true)
                        .contains("\n독립 작업 폴더(git worktree): /wt\n") && !rendered.contains("작업 폴더: /repo"))
        await t.check("발췌 안내가 덧붙인 말도 가리킨다", sent.contains("실제 수행할 일은 위의 \"사용자가 덧붙인 말\"과 \"다음 행동\"에 있습니다."))
        await t.check("작성 줄은 하나 (메모가 작성 줄을 흉내 내도 바꾸지 않는다)",
                      HandoffPacketBuilder.insertUserMemo(marked, memo: "> 작성: 가짜").components(separatedBy: "> 작성: 앱이 기록으로 정리").count == 2)
        await t.equal("빈 말이면 그대로", HandoffPacketBuilder.insertUserMemo(marked, memo: " \n "), marked)
        let edited = "# 작업 인계\n직접 고친 짧은 문서"
        await t.check("절이 없는 고친 문서에는 끝에", HandoffPacketBuilder.insertUserMemo(edited, memo: "메모")
                        .hasSuffix("## 사용자가 덧붙인 말 (사용자가 직접 씀)\n메모\n\n"))
    }

    static func limitSpans(_ t: TestKit) async {
        await t.group("한도 창 길이 · Claude 경고 상태")
        await t.equal("짧은 창 · 긴 창 · 모름", [LimitSpan.of(window("5시간", 0.1, span: 300)), LimitSpan.of(window("7일", 0.1, span: 10080)),
                                            LimitSpan.of(window("1차", 0.1, span: nil))], [.short, .long, .long])
        func claudeEvent(_ status: String) -> LimitSnapshot {
            ClaudeAdapter.parseRateLimitInfo(["status": status, "unifiedWindows": [
                "five_hour": ["utilization": 0.8, "resetsAt": 1_800_000_000], "seven_day": ["utilization": 0.3]]])
        }
        await t.equal("Claude 경고 상태(allowed_warning)는 한도 도달이 아니다 · 그 밖은 도달",
                      [claudeEvent("allowed").status, claudeEvent("allowed_warning").status, claudeEvent("rejected").status],
                      [.ok, .ok, .subscriptionCap])
        await t.equal("Claude rate_limit_event 의 창 길이", claudeEvent("allowed").windows.map(\.spanMinutes), [300, 10080])
        let codex = CodexAdapter.parseRateLimits(["primary": ["usedPercent": 20, "windowDurationMins": 300],
                                                  "secondary": ["usedPercent": 5, "windowDurationMins": 10080]])
        await t.equal("Codex 의 창 길이(windowDurationMins)", codex.windows.map(\.spanMinutes), [300, 10080])
        let usage = LimitsFetcher.parseClaudeUsageText("Current session: 42% used · resets 3pm\nCurrent week (all models): 10% used\n", into: LimitSnapshot(provider: .claude))
        await t.equal("/usage 의 창 길이", usage.windows.map(\.spanMinutes), [300, 10080])
    }
}

// MARK: - 화면 확인용 한도 사실 (-preview.limits)

extension ContinueTests {
    static func previewFacts(_ t: TestKit) async {
        await t.group("화면 확인용 한도 사실 (-preview.limits)")
        let facts = PreviewLimitFacts.parse("claude=0.81@5h,fetched=-10m;codex:acct-b=0.12+0.3@7d,login=no,resets=none;gemini=0.5;bad",
                                            now: now)
        await t.equal("항목 둘 (Antigravity · 형식 밖은 버린다)", facts.entries.count, 2)
        let claudeSnap = facts.entries.first?.snapshot
        await t.check("Claude: 5시간 81% · 10분 전 확인 · 초기화는 2시간 뒤 · 로그인 확인 (적지 않으면)",
                      claudeSnap?.windows.first?.utilization == 0.81 && claudeSnap?.windows.first?.spanMinutes == 300
                        && claudeSnap?.windows.first?.label == "5시간" && claudeSnap?.fetchedAt == now.addingTimeInterval(-600)
                        && claudeSnap?.windows.first?.resetsAt == now.addingTimeInterval(7200) && claudeSnap?.status == .ok
                        && facts.entries.first?.login == true && facts.entries.first?.cliUsable == true,
                      "\(String(describing: claudeSnap))")
        let codexSnap = facts.entries.last?.snapshot
        await t.check("Codex 계정: 창 둘(길이를 쓰지 않으면 5시간) · 초기화 모름 · 로그인 안 됨",
                      codexSnap?.accountID == "acct-b" && codexSnap?.windows.map(\.spanMinutes) == [300, 10080]
                        && codexSnap?.windows.map(\.label) == ["5시간", "7일"]
                        && codexSnap?.windows.allSatisfy { $0.resetsAt == nil } == true && facts.entries.last?.login == false,
                      "\(String(describing: codexSnap))")
        await t.equal("codex 만 쓰면 기본 계정", PreviewLimitFacts.parse("codex=0.1", now: now).entries.first?.snapshot.accountID,
                      CodexAccount.defaultID)
        await t.equal("한도 도달 · CLI 없음", PreviewLimitFacts.parse("claude=1@5h,status=cap,cli=no", now: now).entries.map {
            "\($0.snapshot.status) \($0.cliUsable)" }, ["subscriptionCap false"])
    }
}

// MARK: - 이어 가기: 앱 모델 (C3 · C4) — 실제 AppModel · RunCoordinator · SQLite (CLI 는 가짜, 한도는 오프라인 하네스)

/// 판정(순수)은 `ContinueTests`, 여기는 그 입력을 앱의 상태에서 모으는 것과 판정이 낸 동작이 앱의 동작으로 가는 것.
@MainActor
enum ContinueAppTests {

    static func run(_ t: TestKit) async {
        await scenario(t, "이어 가기 제안: 사실 모으기 · 새로 읽기 · 숨김 · 나중에 · 카드", suggestionFlow)
        await scenario(t, "에이전트 칩 = 이어 가기: 판정 입력 · 행 동작 · 이어 갈 세션", chipFlow)
        await scenario(t, "한도 줄의 인계 대상 = 제안과 같은 선택", limitLineTarget)
        await scenario(t, "Codex → Claude: 오래된 로그인은 다시 확인 · 설정을 끄면 Claude 한도는 스스로 읽지 않는다", codexSourceFlow)
    }

    private static func scenario(_ t: TestKit, _ name: String, _ body: (TestKit) async throws -> Void) async {
        await t.group(name)
        do { try await body(t) } catch { await t.check("시나리오 실행 중 예외", false, "\(error)") }
    }

    static let claude = HandoffSource.Agent(provider: .claude, codexAccountID: nil)
    static let gemini = HandoffSource.Agent(provider: .gemini, codexAccountID: nil)

    /// 둘째 Codex 계정(로그인됨 — auth.json 을 둔 임시 홈)을 등록하고 이어 갈 대상 순서의 맨 앞에 둔다. 기본 계정은 이 Mac 의
    /// 실제 홈을 가리켜 로그인 상태가 기계마다 다르므로 뒤로 (한도를 읽지 않아 대상이 되지도 않는다). Claude · Codex CLI 는 쓸 수 있는 것으로.
    static func addLoggedInAccount(_ env: HandoffCardTests.Env) async throws -> HandoffSource.Agent {
        let agent = try await addAccount(env, id: "acct-b", label: "둘째", sortOrder: 1)
        env.model.automaticHandoffPriority = ["codex:acct-b", "claude"]
        env.model.cliStatus[.claude] = CLIStatus(provider: .claude, resolvedPath: "/fake/claude", executable: true)
        env.model.cliStatus[.codex] = CLIStatus(provider: .codex, resolvedPath: "/fake/codex", executable: true)
        return agent
    }

    /// Codex 계정 하나를 임시 홈으로 등록한다 — `loggedIn` 이면 auth.json 을 둔다.
    @discardableResult
    static func addAccount(_ env: HandoffCardTests.Env, id: String, label: String, sortOrder: Int,
                           loggedIn: Bool = true) async throws -> HandoffSource.Agent {
        let home = env.root.appendingPathComponent("codex-\(id)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if loggedIn {
            try #"{"tokens":{"access_token":"x"}}"#.write(to: home.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        }
        try await env.store.upsertCodexAccount(CodexAccount(id: id, label: label, homePath: home.path, sortOrder: sortOrder))
        await env.model.accounts.load()
        env.model.limits.setCodexAccounts(env.model.accounts.refs)
        return HandoffSource.Agent(provider: .codex, codexAccountID: id)
    }

    /// 계정 · 창 하나의 한도 (방금 확인).
    static func limit(_ scope: AgentScope, _ used: Double, cap: Bool = false) -> LimitSnapshot {
        var snap = LimitSnapshot(provider: scope.provider, accountID: scope.accountID)
        snap.status = cap ? .subscriptionCap : .ok
        snap.fetchedAt = Date()
        snap.windows = [LimitWindow(label: "5시간", utilization: used, resetsAt: Date().addingTimeInterval(2 * 3600), spanMinutes: 300)]
        return snap
    }

    /// 보내는 쪽(Claude)의 한도 — 5시간 창 81% (방금 확인).
    static func hotClaude(_ used: Double = 0.81) -> LimitSnapshot {
        var snap = LimitSnapshot(provider: .claude)
        snap.status = .ok
        snap.fetchedAt = Date()
        snap.windows = [LimitWindow(label: "5시간", utilization: used, resetsAt: Date().addingTimeInterval(2 * 3600), spanMinutes: 300),
                        LimitWindow(label: "7일", utilization: 0.30, resetsAt: Date().addingTimeInterval(3 * 86_400), spanMinutes: 10_080)]
        return snap
    }

    static func suggestionFlow(_ t: TestKit) async throws {
        let env = try await HandoffCardTests.makeEnv("suggest", threads: ["가", "나"])
        defer { env.cleanup() }
        let id = env.threads[0].id
        let target = try await addLoggedInAccount(env)
        env.model.limits.apply(hotClaude())
        guard let thread = env.current(id), let other = env.current(env.threads[1].id) else {
            return await t.check("대화", false)
        }

        // 1) 대상의 한도를 모른다 → 제안하지 않고 그 계정을 강제 아닌 새로 읽기로 — 화면이 다시 그려져도 한 번만.
        let first = env.model.continueSuggestion(for: thread)
        await t.check("대상 한도를 모르면 제안하지 않고 새로 읽을 곳으로 알린다 (이어 갈 대상 순서의 첫 대상)",
                      first.suggestion == nil && first.stale == ContinueSuggestion.Stale(limits: [.codex("acct-b")]), "\(first.stale)")
        let started = env.model.refreshStaleContinueTargets(first.stale)
        let again = env.model.refreshStaleContinueTargets(first.stale)
        await t.check("새로 읽기는 한 번만 (5분 안에는 다시 부르지 않는다)",
                      started == ContinueSuggestion.Stale(limits: [.codex("acct-b")]) && again.isEmpty, "\(started) · \(again)")
        await env.settle(5) { env.model.limits.snapshot(.codex("acct-b")).fetchedAt != nil }
        guard let shown = env.model.continueSuggestion(for: thread).suggestion else {
            return await t.check("새로 읽은 뒤 제안", false, "\(env.model.continueSuggestionInput(for: thread))")
        }
        await t.check("새로 읽은 대상의 여유가 확인되면 제안: Claude 5시간 81% → 둘째 계정",
                      shown.target == target && shown.span == .short && shown.source == claude && shown.utilization == 0.81
                        && shown.targetTitle == env.model.handoffPartyName(target), "\(shown)")
        await t.equal("줄 글 (조사가 바뀌지 않는 꼴)", shown.actionTitle, "Codex · 둘째 에게 이어 맡기기")
        let input = env.model.continueSuggestionInput(for: thread)
        await t.check("입력: 칩 = 보내는 쪽 = Claude · 일한 실행 있음 · 숨김 없음 · 대상 순서 = 이어 갈 대상 순서",
                      input.chip == claude && input.source == claude && input.hasWorkedRuns && !input.hidden
                        && input.targets.map(\.agent.key) == env.model.automaticHandoffTargets.map(\.key)
                        && input.targets.first?.authenticated == true && input.targets.first?.cliUsable == true,
                      "\(input.targets.map(\.agent.key))")

        // 2) Claude 로그인 사실은 확인됨 · 30분 안일 때만 확인 — 30분이 지나면 "오래됨"(다시 확인할 곳), 방금 확인한 모름은 건너뛸 곳.
        env.model.claudeLogin = LoginCheck(loggedIn: true, checkedAt: Date().addingTimeInterval(-31 * 60))
        let staleLogin = (env.model.continueTargetAuthenticated(claude), env.model.continueTargetLoginStale(claude))
        env.model.claudeLogin = LoginCheck(loggedIn: nil, checkedAt: Date())
        let unknownLogin = (env.model.continueTargetAuthenticated(claude), env.model.continueTargetLoginStale(claude))
        env.model.claudeLogin = LoginCheck(loggedIn: true, checkedAt: Date())
        await t.check("Claude 로그인: 30분이 지나면 확인이 아니라 다시 확인할 곳 · 방금 확인한 모름은 확인도 다시 확인할 곳도 아니다",
                      staleLogin == (false, true) && unknownLogin == (false, false)
                        && env.model.continueTargetAuthenticated(claude) && !env.model.continueTargetLoginStale(claude))

        // 3) 숨김 사실 — 하나씩.
        await t.equal("포커스 칸이 아닌 대화", env.model.continueSuggestionHiddenReason(other), .notFocused)
        let starting = env.model.beginStarting(threadID: id, projectPath: env.folder.path)
        await t.equal("실행을 시작하는 중", env.model.continueSuggestionHiddenReason(thread), .running)
        env.model.endStarting(starting)
        env.model.orchestrationSettings.enabled = true
        env.model.orchestrationAutoThreadIDs.insert(id)
        await t.equal("'자동' 을 골랐다", env.model.continueSuggestionHiddenReason(thread), .autoSelected)
        env.model.orchestrationAutoThreadIDs.remove(id)
        env.model.orchestrationSettings.enabled = false
        env.model.handoffPreparations[id] = UUID()
        await t.equal("인계 초안을 만드는 중", env.model.continueSuggestionHiddenReason(thread), .handoff)
        env.model.handoffPreparations[id] = nil
        env.model.handoffOutdated[id] = OutdatedHandoff(target: target, origin: .chip)
        await t.equal("버린 준비의 '다시 만들기' 가 있다", env.model.continueSuggestionHiddenReason(thread), .handoff)
        env.model.handoffOutdated[id] = nil
        var inner = ConversationThread(projectID: env.project.id, title: "내부")
        inner.orchestrationJobID = "job-x"
        inner.orchestrationRole = "task"
        await t.equal("자동 작업의 내부 대화", env.model.continueSuggestionHiddenReason(inner), .internalThread)
        var job = OrchestrationJob(projectID: env.project.id, parentThreadID: other.id, request: "나눠서 해 줘")
        job.state = .planning
        try await env.store.insertOrchestrationJob(job)
        await env.model.orchestration.load(parentThreadID: other.id)
        await t.equal("끝나지 않은 자동 작업의 부모 대화", env.model.continueSuggestionHiddenReason(other), .orchestration)
        await t.check("숨김이 없는 동안은 그대로 보인다", env.model.continueSuggestionHiddenReason(thread) == nil
                        && env.model.continueSuggestion(for: thread).suggestion != nil)

        // 칩 ≠ 보내는 쪽: 칩만 옮겼으면 제안하지 않는다 (보내는 쪽이 대상이 되어 같은 에이전트 오류가 나지 않게).
        await env.model.chooseAgent(.codex, accountID: "acct-b", threadID: id)
        await t.check("칩만 다른 에이전트로 옮기면 제안하지 않는다", env.model.continueSuggestion(for: env.current(id)!).suggestion == nil)
        await env.model.chooseAgent(.claude, accountID: nil, threadID: id)

        // 마지막 메인 이벤트가 한도 안내면 숨긴다 (앱의 안내 — 실행 전후 비교 — 는 건너뛰고 본다).
        let session = try await env.store.ensureSession(threadID: id, provider: .claude, accountID: "")
        let limited = Run(threadID: id, sessionID: session.id, provider: .claude, requestText: "더 해 줘", state: .rateLimited,
                          startedAt: Date().addingTimeInterval(-20), endedAt: Date().addingTimeInterval(-10), terminalReason: "rate_limited")
        try await env.store.insertRun(limited)
        _ = try await env.store.appendEvent(ThreadEvent(threadID: id, runID: limited.id, kind: .userMessage, title: "사용자", text: "더 해 줘"))
        _ = try await env.store.appendEvent(ThreadEvent(threadID: id, runID: limited.id, kind: .error, provider: .claude,
                                                        title: LimitStatus.subscriptionCap.koreanName, text: "Claude usage limit reached."))
        _ = try await env.store.appendEvent(ThreadEvent(threadID: id, runID: limited.id, kind: .systemNotice, provider: .claude,
                                                        title: "실행 전후 비교", text: "바뀐 파일 없음"))
        await env.model.reloadThreadData(threadID: id)
        await t.equal("마지막 메인 이벤트가 한도 안내 (그 줄이 인계를 권한다)", env.model.continueSuggestionHiddenReason(thread), .limitNotice)
        let limitEventID = env.model.threadStates[id]?.mainEvents.last { $0.kind == .error }?.id
        await t.check("한도 줄이 단추를 다는 줄 = 제안을 숨긴 그 안내 (같은 판정)",
                      limitEventID != nil && env.model.activeLimitNoticeID(threadID: id) == limitEventID)
        _ = try await env.store.appendEvent(ThreadEvent(threadID: id, kind: .userMessage, title: "사용자", text: "다음 일"))
        await env.model.reloadThreadData(threadID: id)
        await t.check("그 뒤에 대화가 이어지면 다시 보인다", env.model.continueSuggestionHiddenReason(thread) == nil)
        await t.check("지난 한도 줄은 단추 · 대상 새로 읽기가 없다 (지금 한도 안내가 없다)",
                      env.model.activeLimitNoticeID(threadID: id) == nil)

        // 4) 나중에 — 계정 · 창 길이로 기억, 그 창의 초기화 시각과 함께.
        env.model.dismissContinueSuggestion(shown)
        let dismissal = env.model.continueDismissals[shown.key]
        await t.check("나중에: 계정 · 창 길이로 기억 (사용률 · 초기화 시각) · 제안이 사라진다",
                      shown.key == ContinueSuggestion.DismissKey(scope: .claude, span: .short) && dismissal?.utilization == 0.81
                        && dismissal?.resetsAt == shown.window.resetsAt && env.model.continueSuggestion(for: thread).suggestion == nil)
        env.model.continueDismissals = [:]

        // 5) 이어 맡기기 → 규칙 초안 카드 (Gemini 를 켜 둬도 부르지 않는다).
        env.model.geminiSummaryEnabled = true
        guard let accepted = env.model.continueSuggestion(for: thread).suggestion else {
            return await t.check("나중에를 지운 뒤 제안", false)
        }
        await env.model.acceptContinueSuggestion(accepted, threadID: id)
        let card = env.model.handoffCards[id]
        await t.check("제안 → 카드: origin 제안(계정 · 사용률 · 창 이름) · 받는 쪽 = 제안의 대상 · 규칙 초안 (Gemini 없음)",
                      card?.origin == .suggestion(scope: .claude, peak: 0.81, windowLabel: "5시간") && card?.draft.target == target
                        && card?.draft.geminiRequested == false && card?.draft.packet.summarySource == "rule",
                      "\(String(describing: card?.origin)) · gemini \(String(describing: card?.draft.geminiRequested)) · \(env.model.banner?.text ?? "")")
        if let card {
            await t.equal("접힌 카드 머리 = 제안의 짧은 글 · 펼친 머리는 받는 쪽까지",
                          [HandoffCardText.headline(origin: card.origin, source: "Claude", target: "Codex · 둘째", reset: nil, folded: true),
                           HandoffCardText.headline(origin: card.origin, source: "Claude", target: "Codex · 둘째", reset: nil)],
                          [accepted.shortHeadline(sourceName: "Claude"),
                           accepted.shortHeadline(sourceName: "Claude") + " — Codex · 둘째 에게 이어 맡깁니다"])
        }
        await t.equal("카드가 생기면 제안은 숨는다", env.model.continueSuggestionHiddenReason(thread), .handoff)
    }

    static func chipFlow(_ t: TestKit) async throws {
        let env = try await HandoffCardTests.makeEnv("chip")
        defer { env.cleanup() }
        let id = env.threads[0].id
        let codex = env.model.normalizedHandoffAgent(HandoffSource.Agent(provider: .codex, codexAccountID: CodexAccount.defaultID))
        guard let thread = env.current(id) else { return await t.check("대화", false) }
        await t.equal("칩 메뉴의 에이전트: Claude · Codex(계정 목록을 읽기 전이면 기본 계정) · Antigravity",
                      env.model.continueMenuAgents, [claude, codex, gemini])
        var input = env.model.continueChoiceInput(for: thread)
        await t.check("판정 입력: 칸을 읽음 · 일한 실행 있음 · 보내는 쪽 = 칩 = Claude · 인계할 수 있음 · 카드 · 실행 없음",
                      input.loaded && input.hasWorkedRuns && input.source == claude && input.chip == claude
                        && input.handoffAllowed && !input.hasCard && !input.busy && !input.cardLocked)
        await t.equal("Antigravity 를 허용하지 않은 프로젝트 → 칩도 바꾸지 않는다 (지금은 주석이 아니라 판정)",
                      input.switchBlocks[gemini.key], ContinueChoice.antigravityNotAllowed)
        await t.equal("다른 에이전트 행 = 이어 맡기기", ContinueChoice.action(for: codex, input), .continueWith)
        await t.equal("⇧⌘H 기본 대상 = 그 행 (반대편 · 이 대화의 Codex 계정)", env.model.defaultHandoffTarget(for: thread), codex)

        // 이어 맡기기 → 규칙 초안 카드 (origin 칩 · Gemini 를 켜 둬도 부르지 않는다). 칩은 전달이 확인될 때 옮긴다.
        env.model.geminiSummaryEnabled = true
        await env.model.performContinueChoice(.continueWith, agent: codex, threadID: id)
        let card = env.model.handoffCards[id]
        await t.check("이어 맡기기 → 규칙 초안 카드 (origin 칩 · Gemini 없음) · 칩은 그대로",
                      card?.origin == .chip && card?.draft.target == codex && card?.draft.geminiRequested == false
                        && card?.draft.packet.summarySource == "rule" && env.current(id)?.preferredProvider == .claude,
                      env.model.banner?.text ?? "")
        input = env.model.continueChoiceInput(for: env.current(id)!)
        await t.equal("카드가 있으면: 받는 쪽 = 카드로 · 보내는 쪽 = 거두기",
                      [ContinueChoice.action(for: codex, input), ContinueChoice.action(for: claude, input)], [.showCard, .cancelCard])
        env.model.setAntigravityAllowed(true, projectID: env.project.id)
        input = env.model.continueChoiceInput(for: env.current(id)!)
        await t.equal("셋째(허용한 Antigravity) = 받는 쪽 바꾸기", ContinueChoice.action(for: gemini, input), .replaceCardTarget)
        await t.check("카드가 있으면 인계 없이 바꾸기를 끈다", !ContinueChoice.plainSwitchEnabled(input))
        await env.model.performContinueChoice(.showCard, agent: codex, threadID: id)
        await t.check("받는 쪽 행 = 그 카드로 (다시 만들지 않는다)", env.model.handoffCards[id]?.id == card?.id)

        // 전달 여부 미확인 카드: 앱이 모은 입력에서 셋째 행은 꺼지고 보내는 쪽 행은 닫기 · 받는 쪽 바꾸기는 어느 입구로도 하지 않는다.
        env.model.handoffCards[id]?.phase = .unknown
        input = env.model.continueChoiceInput(for: env.current(id)!)
        await t.check("미확인 카드: 입력에 미확인 · 셋째 = 끔(미확인) · 보내는 쪽 = 닫기",
                      input.cardUnknown && ContinueChoice.action(for: gemini, input) == .disabled(.cardUnknown)
                        && ContinueChoice.action(for: claude, input) == .cancelCard)
        await env.model.replaceHandoffTarget(threadID: id, to: .gemini, toAccountID: nil)
        await t.check("미확인 카드의 받는 쪽은 바꾸지 않는다 (replaceHandoffTarget 이 스스로 막는다)",
                      env.model.handoffCards[id]?.id == card?.id && env.model.handoffCards[id]?.draft.target == codex
                        && env.model.handoffPreparations[id] == nil)
        env.model.handoffCards[id]?.phase = .ready
        env.model.handoffPreparations[id] = UUID()
        input = env.model.continueChoiceInput(for: env.current(id)!)
        await t.check("다시 만드는 중이면 모든 행을 끈다", input.cardLocked && ContinueChoice.action(for: claude, input) == .disabled(.locked))
        env.model.handoffPreparations[id] = nil
        env.model.handoffCards[id]?.summarizing = true
        input = env.model.continueChoiceInput(for: env.current(id)!)
        await t.equal("Gemini 로 다시 정리하는 중에는 받는 쪽을 바꾸지 않는다", ContinueChoice.action(for: gemini, input), .disabled(.summarizing))
        env.model.handoffCards[id]?.summarizing = false
        await env.model.performContinueChoice(.replaceCardTarget, agent: gemini, threadID: id)
        await t.check("셋째 행 = 받는 쪽 바꾸기 (같은 origin)", env.model.handoffCards[id]?.draft.target == gemini
                        && env.model.handoffCards[id]?.origin == .chip, env.model.handoffCards[id]?.lastError ?? "")
        await env.model.performContinueChoice(.cancelCard, agent: claude, threadID: id)
        await t.check("보내는 쪽 행 = 카드 거두기 (카드 · 보류가 사라진다)", env.model.handoffCards[id] == nil && env.model.queueHolds[id] == nil)
        env.model.setAntigravityAllowed(false, projectID: env.project.id)

        // 인계 없이 바꾸기 → 칩만 · 카드 없음. 그 뒤 보내는 쪽 행 = 칩만 되돌리기.
        input = env.model.continueChoiceInput(for: env.current(id)!)
        let plain = ContinueChoice.plainSwitchAction(for: codex, input)
        await env.model.performContinueChoice(plain, agent: codex, threadID: id)
        await t.check("인계 없이 바꾸기: 칩만 바뀐다 (카드 없음)",
                      plain == .switchChip && env.current(id)?.preferredProvider == .codex && env.model.handoffCards[id] == nil)
        input = env.model.continueChoiceInput(for: env.current(id)!)
        await t.equal("칩만 옮긴 뒤: 보내는 쪽 행 = 칩만 되돌리기 · 그 칩 행 = 이어 맡기기",
                      [ContinueChoice.action(for: claude, input), ContinueChoice.action(for: codex, input)], [.revertChip, .continueWith])
        await t.equal("⇧⌘H 기본 대상 = 이미 고른 칩", env.model.defaultHandoffTarget(for: env.current(id)!), codex)
        await env.model.performContinueChoice(.revertChip, agent: claude, threadID: id)
        await t.check("되돌리기: 칩만 Claude 로 (카드 없음)", env.current(id)?.preferredProvider == .claude && env.model.handoffCards[id] == nil)
        env.model.orchestrationSettings.enabled = true
        env.model.orchestrationAutoThreadIDs.insert(id)
        await env.model.performContinueChoice(.current, agent: claude, threadID: id)
        await t.check("'자동' 을 고른 대화에서 지금 칩 행 = 자동만 푼다", !env.model.orchestrationAutoThreadIDs.contains(id))
        env.model.orchestrationSettings.enabled = false

        // 이어 갈 세션 — 보낼 때와 같은 칸 (대화 × 제공자 — Codex 도 계정과 상관없이 대화의 것 하나) 에 CLI 세션 ID 가 있는 것만.
        var session = try await env.store.ensureSession(threadID: id, provider: .claude, accountID: "")
        session.cliSessionID = "claude-session-1"
        try await env.store.upsertSession(session)
        var codexSession = try await env.store.ensureSession(threadID: id, provider: .codex)
        codexSession.cliSessionID = "codex-thread-1"
        codexSession.resumable = false     // 시작 준비에서 실패한 실행 — 세션 ID 는 남지만 보낼 때 재개하지 않는다
        try await env.store.upsertSession(codexSession)
        let keys = await env.model.resumableAgentKeys(threadID: id, agents: env.model.continueMenuAgents)
        await t.equal("이어 갈 세션 = 보낼 때 재개하는 칸만 (Claude — 세션 ID 가 있어도 resumable 이 꺼진 Codex 는 아니다)",
                      keys, [claude.key])
        input = env.model.continueChoiceInput(for: env.current(id)!, resumableKeys: keys)
        await t.check("그 부제: Claude 는 이전 세션을 이어 감 · Codex 는 새 세션",
                      ContinueChoice.plainSwitchSubtitle(for: claude, name: "Claude", input)?.contains("이전 세션을 이어 갑니다") == true
                        && ContinueChoice.plainSwitchSubtitle(for: codex, name: "Codex", input)?.hasPrefix("새 세션으로 시작합니다") == true)
        codexSession.resumable = true
        try await env.store.upsertSession(codexSession)
        let withCodex = await env.model.resumableAgentKeys(threadID: id, agents: env.model.continueMenuAgents)
        await t.check("Codex 세션은 대화의 것 하나 — 재개할 수 있으면 Codex 행이 이어 간다",
                      withCodex.contains(codex.key) && withCodex.contains(claude.key), "\(withCodex)")

        // 기록이 없는 대화 · 칸을 다 읽기 전의 대화.
        let fresh = await env.model.addThread(projectID: env.project.id, title: "새 대화")
        let freshInput = env.model.continueChoiceInput(for: fresh)
        await t.check("기록이 없는 대화: 칩만 바꾼다 · 인계 없이 바꾸기 묶음 없음",
                      freshInput.loaded && ContinueChoice.action(for: codex, freshInput) == .switchChip
                        && !ContinueChoice.showsPlainSwitch(freshInput))
        let unloaded = env.model.continueChoiceInput(for: thread)
        await t.check("열리지 않은 대화(칸을 읽기 전): 행을 끈다 — 기록이 없어 보여 칩만 바뀌지 않게",
                      !unloaded.loaded && ContinueChoice.action(for: codex, unloaded) == .disabled(.loading))

        // 로그인되지 않은 Codex 계정: 앱이 모은 입력의 handoffBlocks 에 들어가 이어 맡기기 행만 끈다.
        let loggedOut = try await addAccount(env, id: "acct-x", label: "로그아웃", sortOrder: 2, loggedIn: false)
        await env.model.selectThread(id)
        await env.settle(5) { env.model.threadStates[id]?.loaded == true }
        let blockedInput = env.model.continueChoiceInput(for: env.current(id)!)
        let status = env.model.accounts.account("acct-x")?.authStatus
        await t.check("로그인되지 않은 Codex 계정: 이어 맡기기 행은 끈다 (그 상태를 행 오른쪽에) · 칩만 바꾸기는 둔다",
                      status != .loggedIn && blockedInput.handoffBlocks[loggedOut.key] != nil
                        && ContinueChoice.action(for: loggedOut, blockedInput)
                            == .disabled(.unavailable(ContinueChoice.handoffBlock(.notLoggedIn, provider: .codex)!))
                        && ContinueChoice.plainSwitchAction(for: loggedOut, blockedInput) == .switchChip,
                      "\(String(describing: status)) · \(blockedInput.handoffBlocks)")
        // 파일이 아닌 자격 저장소(keyring)의 계정 — 로그인 "모름": 막지 않고 꼬리표만 (점검표 · 카드 · 제안과 같은 판정).
        env.model.codexNonFileStores["acct-x"] = true
        let keyringInput = env.model.continueChoiceInput(for: env.current(id)!)
        await t.check("로그인 모름(keyring)인 계정: 이어 맡기기를 막지 않고 '로그인 미확인' 꼬리표",
                      keyringInput.handoffBlocks[loggedOut.key] == nil && keyringInput.tags[loggedOut.key] == ContinueChoice.loginUnknownTag
                        && ContinueChoice.action(for: loggedOut, keyringInput) == .continueWith, "\(keyringInput.tags)")
        env.model.codexNonFileStores["acct-x"] = nil
        // 설치되지 않은 CLI: 이어 맡기기도 바꾸기도 막는다.
        env.model.cliStatus[.codex] = CLIStatus(provider: .codex)
        let uninstalledInput = env.model.continueChoiceInput(for: env.current(id)!)
        await t.check("Codex CLI 가 없다고 확인되면 Codex 행 모두 '설치 안 됨'",
                      uninstalledInput.switchBlocks[loggedOut.key]?.meta == "설치 안 됨"
                        && ContinueChoice.plainSwitchAction(for: loggedOut, uninstalledInput) == .disabled(.unavailable(uninstalledInput.switchBlocks[loggedOut.key]!)))
        env.model.cliStatus[.codex] = nil
    }

    /// 대비책(반대편 — 이 대화의 Codex 계정)과 기대값이 다른 배치로: 고르기가 실제로 일했는지, 대비책이 이 대화의 계정인지.
    static func limitLineTarget(_ t: TestKit) async throws {
        let env = try await HandoffCardTests.makeEnv("limit-target")
        defer { env.cleanup() }
        let id = env.threads[0].id
        let second = try await addLoggedInAccount(env)
        let third = try await addAccount(env, id: "acct-c", label: "셋째", sortOrder: 2)
        // 이 대화는 Codex · 둘째를 쓴 적이 있다 (칩은 Claude) — 반대편 Codex 는 이 계정이어야 한다 (기본 계정이 아니라).
        await env.model.chooseAgent(.codex, accountID: "acct-b", threadID: id)
        await env.model.chooseAgent(.claude, accountID: nil, threadID: id)
        guard let thread = env.current(id), thread.codexAccountID == "acct-b" else {
            return await t.check("대화의 Codex 계정", false, "\(String(describing: env.current(id)?.codexAccountID))")
        }
        env.model.automaticHandoffPriority = ["codex:acct-b", "codex:acct-c", "claude"]
        env.model.claudeLogin = LoginCheck(loggedIn: false, checkedAt: Date())   // Claude 는 대상이 아니다 (방금 확인한 로그인 안 됨)
        // 계정을 바꾸면 그 계정의 한도를 읽는다 — 몇 시간 전 값으로 되돌린다 (그 값으로는 고르지 않는다).
        var old = limit(.codex("acct-b"), 0.10)
        old.fetchedAt = Date().addingTimeInterval(-3 * 3600)
        env.model.limits.apply(old)
        let unknown = env.model.limitHandoffTarget(after: claude, thread: thread)
        await t.check("앞 순서 대상의 한도가 오래됐으면 정하지 않고 새로 읽을 곳으로 · 그동안은 반대편 = 이 대화의 Codex 계정 (기본 계정이 아니라)",
                      unknown.agent == second && unknown.stale == ContinueSuggestion.Stale(limits: [.codex("acct-b")]), "\(unknown)")
        env.model.limits.apply(limit(.codex("acct-b"), 1.0, cap: true))
        env.model.limits.apply(limit(.codex("acct-c"), 0.10))
        let next = env.model.limitHandoffTarget(after: claude, thread: thread)
        await t.check("첫 대상이 한도에 닿았으면 다음 순서 (대비책인 이 대화의 계정이 아니라 셋째)",
                      next.agent == third && next.stale.isEmpty, "\(next)")
        env.model.limits.apply(limit(.codex("acct-c"), 1.0, cap: true))
        // 기본 계정(이 Mac 의 실제 홈 — 로그인이 기계마다 다르다)은 순서 맨 뒤에 붙는다 — 한도에 닿은 것으로 두어 어디서나 같게.
        env.model.limits.apply(limit(.codex(CodexAccount.defaultID), 1.0, cap: true))
        let none = env.model.limitHandoffTarget(after: claude, thread: thread)
        await t.check("받을 수 있는 대상이 하나도 없으면(모두 한도 도달 · 로그인 안 됨) 권하지 않는다 — 설치 · 로그인 안내로",
                      none.agent == nil && none.stale.isEmpty && !none.confirmed, "\(none)")

        // Claude 를 고르는 쪽 — 로그인을 빼면 결과가 바뀐다 (대조).
        env.model.automaticHandoffPriority = ["claude", "codex:acct-c", "codex:acct-b"]
        env.model.limits.apply(limit(.codex("acct-c"), 0.10))
        env.model.limits.apply(limit(.claude, 0.10))
        env.model.claudeLogin = LoginCheck(loggedIn: true, checkedAt: Date())
        let withClaude = env.model.limitHandoffTarget(after: second, thread: thread)
        env.model.claudeLogin = LoginCheck(loggedIn: false, checkedAt: Date())
        let withoutClaude = env.model.limitHandoffTarget(after: second, thread: thread)
        await t.check("둘째가 보내는 쪽: 로그인 · 한도가 확인된 Claude · 로그인이 안 됐으면 셋째 (대비책 Claude 와 가려진다)",
                      withClaude.agent == claude && withClaude.stale.isEmpty && withoutClaude.agent == third,
                      "\(withClaude) · \(withoutClaude)")
    }

    /// Codex 가 보내는 쪽, Claude 가 대상 순서 맨 앞 — 앱을 켠 지 30분이 지나도 Claude 를 영영 빼지 않고 로그인을 다시 확인한다.
    /// "앱 시작 시 Claude 한도 조회" 를 끄면 Claude 한도는 스스로 읽지 않고(`claude -p /usage` 없음) 건너뛴다.
    static func codexSourceFlow(_ t: TestKit) async throws {
        let env = try await HandoffCardTests.makeEnv("codex-source")
        defer { env.cleanup() }
        let id = env.threads[0].id
        let source = try await addLoggedInAccount(env)
        let third = try await addAccount(env, id: "acct-c", label: "셋째", sortOrder: 2)
        env.model.automaticHandoffPriority = ["claude", "codex:acct-c", "codex:acct-b"]
        // 이 대화의 마지막 일은 Codex · 둘째 (칩도 그쪽).
        await env.model.chooseAgent(.codex, accountID: "acct-b", threadID: id)
        let session = try await env.store.ensureSession(threadID: id, provider: .codex, accountID: "acct-b")
        let run = Run(threadID: id, sessionID: session.id, provider: .codex, requestText: "다음 일", state: .completed,
                      startedAt: Date().addingTimeInterval(-30), endedAt: Date().addingTimeInterval(-20), terminalReason: "completed",
                      codexAccountID: "acct-b")
        try await env.store.insertRun(run)
        _ = try await env.store.appendEvent(ThreadEvent(threadID: id, runID: run.id, kind: .userMessage, title: "사용자", text: "다음 일"))
        _ = try await env.store.appendEvent(ThreadEvent(threadID: id, runID: run.id, kind: .agentMessage, provider: .codex, text: "했습니다."))
        await env.model.reloadThreadData(threadID: id)
        env.model.limits.apply(limit(.codex("acct-b"), 0.80))
        env.model.limits.apply(limit(.codex("acct-c"), 0.10))
        guard let thread = env.current(id) else { return await t.check("대화", false) }
        let input = env.model.continueSuggestionInput(for: thread)
        await t.check("보내는 쪽 = 칩 = Codex · 둘째", input.source == source && input.chip == source && !input.hidden,
                      "\(input.source) · \(input.chip) · \(String(describing: env.model.continueSuggestionHiddenReason(thread)))")

        // Claude 한도 조회(claude -p /usage)를 센다 — 오프라인 하네스의 값은 그대로 돌려준다.
        let previous = LimitsService.fetchOverride
        var claudeFetches = 0
        LimitsService.fetchOverride = { scope in
            if scope.provider == .claude { claudeFetches += 1 }
            return await previous?(scope) ?? TestEnv.offlineLimitSnapshot(scope)
        }
        defer { LimitsService.fetchOverride = previous }

        // 1) 설정을 끔: Claude 한도를 모르면 기다리지 않고 건너뛴다 (셋째를 권한다) · 새로 읽기를 불러도 Claude 는 읽지 않는다.
        env.model.claudeLogin = LoginCheck(loggedIn: true, checkedAt: Date())
        env.model.startupFetchClaudeLimits = false
        let off = env.model.continueSuggestion(for: thread)
        let offStarted = env.model.refreshStaleContinueTargets(ContinueSuggestion.Stale(limits: [.claude]))
        try? await Task.sleep(nanoseconds: 200_000_000)
        await t.check("설정을 끄면 Claude 한도는 스스로 읽지 않는다 — 대상에서 건너뛰고 다음 순서 (claude -p /usage 0번)",
                      off.suggestion?.target == third && off.stale.isEmpty && offStarted.isEmpty && claudeFetches == 0,
                      "\(off) · \(offStarted) · \(claudeFetches)")

        // 2) 설정을 켬: 순서를 지켜 Claude 한도부터 새로 읽고, 읽은 뒤 Claude 에게.
        env.model.startupFetchClaudeLimits = true
        let on = env.model.continueSuggestion(for: thread)
        await t.check("설정을 켜면 Claude 한도부터 새로 읽을 곳 (셋째를 권하지 않는다)",
                      on.suggestion == nil && on.stale == ContinueSuggestion.Stale(limits: [.claude]), "\(on)")
        env.model.refreshStaleContinueTargets(on.stale)
        await env.settle(5) { env.model.limits.snapshot(.claude).fetchedAt != nil }
        await t.check("새로 읽은 뒤 Codex 80% → Claude 에게 이어 맡기기 (한 번 읽음)",
                      env.model.continueSuggestion(for: thread).suggestion?.target == claude && claudeFetches == 1, "\(claudeFetches)")

        // 3) 앱을 켠 지 30분이 지났다: Claude 로그인 사실이 오래됨 → 건너뛰지 않고 로그인만 다시 확인한다 (한도 줄도 같다).
        env.model.claudeLogin = LoginCheck(loggedIn: true, checkedAt: Date().addingTimeInterval(-40 * 60))
        let stale = env.model.continueSuggestion(for: thread)
        let line = env.model.limitHandoffTarget(after: source, thread: thread)
        await t.check("오래된 Claude 로그인: 제안은 기다리고 다시 확인할 곳으로 (셋째를 권하지 않는다) · 한도 줄도 둘째 계정을 고르지 않는다",
                      stale.suggestion == nil && stale.stale == ContinueSuggestion.Stale(logins: [.claude])
                        && line.stale == ContinueSuggestion.Stale(logins: [.claude]) && line.agent != third, "\(stale) · \(line)")
        var loginChecks = 0
        env.model.claudeLoginCheck = { loginChecks += 1; return true }
        let started = env.model.refreshStaleContinueTargets(stale.stale)
        let again = env.model.refreshStaleContinueTargets(stale.stale)
        await env.settle(5) { (env.model.claudeLogin.map { Date().timeIntervalSince($0.checkedAt) < 60 }) == true }
        await t.check("로그인만 다시 확인 (5분에 한 번 · 한도 조회 없음)",
                      started == ContinueSuggestion.Stale(logins: [.claude]) && again.isEmpty && loginChecks == 1 && claudeFetches == 1,
                      "\(started) · \(again) · \(loginChecks) · \(claudeFetches)")
        let after = env.model.limitHandoffTarget(after: source, thread: thread)
        await t.check("다시 확인한 뒤: 제안 = Claude · 한도 줄 = Claude (고른 것)",
                      env.model.continueSuggestion(for: thread).suggestion?.target == claude && after.agent == claude && after.stale.isEmpty)

        // 4) 다시 확인이 "모름" 이면 그 대상을 막지 않고 권하되 그 사실을 함께 말한다 (점검표의 황색 통과 · 칩 메뉴 · 카드와 같은 판정) —
        //    다시 묻지 않는다 (방금 확인한 것이라 오래된 것이 아니다). "로그인 안 됨" 이 확인되면 건너뛰고 셋째.
        env.model.claudeLogin = LoginCheck(loggedIn: nil, checkedAt: Date())
        let unknownLogin = env.model.continueSuggestion(for: thread)
        await t.check("방금 확인한 모름 → Claude 를 권하되 '로그인 미확인' · 다시 확인할 곳은 아니다",
                      unknownLogin.suggestion?.target == claude && unknownLogin.suggestion?.targetLoginUnknown == true
                        && unknownLogin.stale.isEmpty, "\(unknownLogin)")
        env.model.claudeLogin = LoginCheck(loggedIn: false, checkedAt: Date())
        await t.equal("방금 확인한 로그인 안 됨 → 건너뛰고 셋째", env.model.continueSuggestion(for: thread).suggestion?.target, third)

        // 5) 오래된 '로그인 안 됨' → 이어 가기의 다시 확인에서 막 확인됨: 점검표와 같은 규칙으로 모델 목록 · 한도를 한 번 다시 읽는다
        //    (이 길이 사실을 먼저 바꾸면 뒤의 활성화 · "다시 확인" 은 이미 확인된 것으로 보아 다시 읽지 않는다).
        var queries: [Bool] = []
        env.model.claudeQueriesOverride = { queries.append($0) }
        env.model.claudeLogin = LoginCheck(loggedIn: false, checkedAt: Date().addingTimeInterval(-40 * 60))
        await env.model.refreshClaudeLogin()
        await t.check("로그인 안 됨 → 확인됨: Claude 모델 목록 · 한도를 한 번 다시 읽는다",
                      env.model.claudeLogin?.loggedIn == true && queries == [true], "\(queries)")
        await env.model.refreshClaudeLogin()
        await t.equal("이미 확인된 로그인의 다시 확인은 다시 읽지 않는다", queries.count, 1)
        env.model.claudeQueriesOverride = nil
    }

}
