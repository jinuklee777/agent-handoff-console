import Foundation

/// Claude Code stream-json 의 줄을 메인 흐름 · 하위 에이전트 흐름으로 나누고, 실행의 끝을 판정한다.
///
/// 실측(`scripts/probe/claude-background`, Claude Code 2.1.270):
/// - 하위 에이전트 안의 `assistant` · `user` 에는 `parent_tool_use_id`(= 띄운 Agent 호출의 tool_use id)가 붙는다.
///   하위의 글 조각(stream_event)은 없고, 하위의 최종 답은 메인의 Agent `tool_result` 로만 온다.
///   워크플로 안 에이전트는 `task_progress` 만 낸다.
/// - 작업은 `system/task_started` → `task_progress`(초당 여러 번) → `task_updated` → `task_notification` 으로 알린다
///   (포그라운드 Agent 도). 남은 백그라운드 작업의 **전체 목록**은 `background_tasks_changed` 다 — 끝의 기준이다.
/// - 백그라운드 작업이 남아도 `result` 가 먼저 온다. 메인이 띄운 백그라운드 작업이 끝나면 CLI 가 스스로 후속 턴을 연다
///   (`task_notification` → `system/init`(같은 session_id) → 답 → `result`). 하위가 띄운 작업의 알림은 열지 않는다.
/// - `modelUsage` · `total_cost_usd` 는 **프로세스 누적**이다 — 마지막 `result` 하나만 쓴다 (합치지 않는다).
/// - 목록은 잠깐 비었다가 다시 찰 수 있다 (t5: `stop_task` 로 빈 목록 → 10ms 뒤 하위가 깨어나 같은 task_id 로 다시 시작) →
///   빈 목록은 `emptyListDebounce` 동안 그대로일 때만 끝으로 본다.
/// - 기다리는 중 `interrupt` 는 작업을 모두 멈추고 `result` 를 내지 않는다 (t6) → 목록이 비면 취소로 끝낸다.
/// - `ambient` · `skip_transcript` 작업(아티팩트 감시 `monitor_ws` · fork 작업자 등, 2.1.276 스키마)은 일이 아니다 —
///   끝나도 후속 턴을 기다리지 않고, 화면에 내지 않는다. 남은 작업 목록(`background_tasks_changed`)에서는 목록 항목에
///   `ambient` 가 붙은 것만 빼고 기다리지 않는다 (`skip_transcript` 만 붙은 작업이 목록에 있으면 기다린다).
///   감시는 스스로 끝나지 않는다.
/// - 메인 턴이 도는 중에 끝난 메인 작업의 알림은 CLI 가 그 턴에 흡수할 수 있다 (`absorbed_mid_turn`) — 그러면 후속 턴이
///   열리지 않는다. 그래서 턴 중의 알림은 후속 턴 안전장치(15초)가 아니라 빈 목록 디바운스로 본다.
///
/// 프로세스 · 스트림 · 시계와 무관한 값 형식이다. 어댑터는 줄을 하나씩 넣고(`handle`), `recheck` 를 받으면 그만큼 뒤에
/// `tick` 을 부르고, 돌려받은 `Action` 대로만 움직인다. 실측 기록을 그대로 넣어 시험한다
/// (`scripts/inttest/ClaudeReplayTests.swift`).
struct ClaudeTurnTracker: Sendable {
    enum Action: Sendable {
        /// 그대로 낸다.
        case emit(AgentEvent)
        /// 메인 턴이 끝났고 남은 작업(`remaining` 개)을 기다린다 → `AgentEvent.turnSettled`. 프로세스를 살려 둔다.
        case settle(remaining: Int)
        /// `after` 초 뒤에 `tick` 을 불러 달라 (빈 목록 디바운스 · 후속 턴 안전장치). 늦게 불러도 되고, 일찍 부르면
        /// `tick` 이 남은 만큼 다시 부탁한다.
        case recheck(after: TimeInterval)
        /// 실행의 끝. 한 번만 온다.
        case finish(AgentTurnResult)
    }

    /// 작업 하나 (task_id 단위).
    private struct Job: Sendable {
        var info: SubAgentInfo
        /// 하위 에이전트가 띄운 작업 — 끝나도 메인 후속 턴이 열리지 않는다.
        var ownedBySubagent: Bool
        /// `ambient` · `skip_transcript` 작업 — 일로 세지 않고 화면에 내지 않는다.
        var hidden: Bool
    }

    /// 목록이 이만큼 비어 있어야 끝으로 본다 (다시 차는 경우 — t5).
    static let emptyListDebounce: TimeInterval = 1.5
    /// 메인이 띄운 백그라운드 작업이 끝났는데 후속 턴이 이만큼 열리지 않으면 마지막 결과로 끝낸다 (안전장치).
    static let followUpGrace: TimeInterval = 15
    /// 기다리는 중 사용자가 멈춘 실행의 `terminalReason`.
    static let interruptedReason = "background_interrupted"
    /// 하위에게 준 요청(하위 흐름의 첫 줄)의 최대 길이.
    static let promptLimit = 1000
    /// `recheck` 를 부탁한 만큼 정확히 지나 부른 `tick` 이 부동소수 오차로 빠지지 않게.
    private static let clockSlack: TimeInterval = 0.001
    /// 때가 되기 전의 `tick` 이 다시 부탁하는 최소 간격 (잦은 깨우기를 막는다).
    static let minRecheck: TimeInterval = 0.05
    /// 실패로 끝낼 때 오류 글에 싣는 stderr 끝부분의 길이.
    private static let stderrTailLimit = 2000

    let waitForBackground: Bool
    let startedAt: Date

    private(set) var sessionID: String?
    /// `system/init` 의 모델. 대표 모델을 고를 때 먼저 본다.
    private(set) var initModel: String?
    /// 메인 메시지의 모델. 하위의 메시지로 바꾸지 않는다.
    private(set) var mainModel: String?
    /// 메인 턴이 도는 중 (첫 턴 · CLI 가 연 후속 턴).
    private(set) var turnActive = true
    /// 메인 턴은 끝났고 남은 작업을 기다리는 중.
    private(set) var isSettled = false
    private(set) var isFinished = false
    private(set) var userCancelled = false
    /// 메인이 띄운 백그라운드 작업이 끝났다 — CLI 가 곧 후속 턴을 연다.
    private(set) var awaitingFollowUp = false
    /// 메인 턴이 도는 중에 메인 작업이 끝났다 — CLI 가 그 턴에 흡수했으면 후속 턴이 없다 (디바운스만 기다린다).
    private(set) var notifiedDuringTurn = false
    /// 마지막 `result` 의 해석 (누적 사용량).
    private(set) var lastResult: AgentTurnResult?
    /// 남은 백그라운드 작업 — CLI 가 보고한 전체 목록의 task_id (순서 그대로).
    private(set) var backgroundTaskIDs: [String] = []

    private var sawInit = false
    /// 한 번이라도 기다렸는가 (걸린 시간을 실행 시작부터 잰다).
    private var everSettled = false
    private var firstStructuredOutput: String?
    private var lastMainText: String?
    private var jobs: [String: Job] = [:]
    private var jobOrder: [String] = []
    /// 작업 id(`SubAgentInfo.id` = 띄운 호출의 tool_use id) → task_id.
    private var taskIDByAgent: [String: String] = [:]
    /// 요청 줄을 이미 낸 하위 에이전트 → 그 요청 (포그라운드 Agent 는 같은 글을 `user` 로 한 번 더 보낸다 — t1 · t4).
    private var promptByAgent: [String: String] = [:]
    /// 하위 안의 도구 호출 id → 그 메시지의 `parent_tool_use_id`.
    private var parentOf: [String: String] = [:]
    /// 기다리는 중 목록이 빈 때 (디바운스).
    private var quietSince: Date?
    /// 후속 턴을 기다리기 시작한 때 (안전장치).
    private var awaitingSince: Date?
    /// 마지막 `result` 뒤에 하위 작업이 진행되거나 끝났다 — 그 사용량은 마지막 결과에 없다 (결과 없이 끝내면 미확정).
    private var workAfterResult = false
    /// 이미 알린 모르는 `task_*` 이벤트 (실행마다 한 번).
    private var unknownTaskSubtypes: Set<String> = []
    /// 실패를 알린 훅 이름 (실행마다 한 번 — 도구마다 도는 훅이 줄줄이 쌓이지 않게).
    private var failedHooks: Set<String> = []
    /// 이번 실행이 띄우지 않은 작업의 알림을 봤다 — 이어받은 세션에 남아 있던 백그라운드 작업. CLI 는 그 알림을 한 턴으로
    /// **먼저** 처리하고 result 를 낸 뒤에 우리 메시지를 처리한다 (2026-09-29 실측, `scripts/probe` 밖에서 재현 — 그 result 에서
    /// 실행을 끝내 사진을 붙인 메시지가 처리되지 않고 버려졌다).
    private(set) var staleNotificationSeen = false
    /// 우리 메시지의 턴이 열렸다 — CLI 가 그 메시지를 되돌려 줬다 (`--replay-user-messages`, 처리하는 턴 안에서 온다).
    private(set) var ownTurnStarted = false
    /// 끼어든 턴의 result 뒤 우리 턴을 기다린다 (`followUpGrace` 안에 열리지 않으면 실패로 끝낸다 — 되돌림을 모르는 CLI 대비).
    private(set) var awaitingOwnTurn = false
    private var awaitingOwnSince: Date?

    /// 지금 도는 턴은 남은 알림의 턴이다 — 그 글은 우리 답이 아니다.
    private var inStaleTurn: Bool { staleNotificationSeen && !ownTurnStarted }

    init(waitForBackground: Bool, startedAt: Date = Date()) {
        self.waitForBackground = waitForBackground
        self.startedAt = startedAt
    }

    // MARK: - 조회

    /// 하위 작업 (시작 순).
    var subAgents: [SubAgentInfo] { jobOrder.compactMap { jobs[$0].flatMap { $0.hidden ? nil : $0.info } } }

    /// 멈출 수 있는 작업이면 그 task_id (`stop_task` 에 쓴다). `id` 는 `SubAgentInfo.id`.
    func stoppableTaskID(forAgent id: String) -> String? {
        guard let taskID = taskIDByAgent[id], let job = jobs[taskID], !job.hidden, job.info.canStop else { return nil }
        return taskID
    }

    /// 이 도구 호출을 낸 하위 에이전트의 id 와 이름 (승인 요청용). 메인의 호출이면 nil.
    /// 승인 요청(`can_use_tool`)은 그 호출의 `assistant` 줄보다 늦게 온다 (t3).
    func subAgentOwner(toolUseID: String?) -> (id: String, name: String)? {
        guard let toolUseID, let parent = parentOf[toolUseID] else { return nil }
        let id = nearestAgent(from: parent) ?? parent
        let name = taskIDByAgent[id].flatMap { jobs[$0]?.info.title } ?? Self.defaultTitle(.agent)
        return (id, name)
    }

    // MARK: - 줄

    /// stream-json 한 줄. `control_request` · `control_response` · `rate_limit_event` 는 어댑터가 다룬다 (빈 배열).
    mutating func handle(_ obj: [String: Any], now: Date = Date()) -> [Action] {
        guard !isFinished else { return [] }
        var actions: [Action]
        switch obj["type"] as? String {
        case "system": actions = system(obj, now: now)
        case "stream_event": actions = streamEvent(obj)
        case "assistant": actions = assistant(obj)
        case "user": actions = user(obj)
        case "result": return result(obj, now: now)
        default: return []
        }
        if !isFinished { actions += waitCheck(now: now) }
        return actions
    }

    /// 사용자가 멈췄다. 기다리는 중이고 남은 작업이 없으면 곧바로 끝낸다. 남은 작업이 있으면 안내만 — 어댑터가
    /// `interrupt` 를 보내고, 목록이 비면 끝난다 (CLI 는 result 를 내지 않는다 — t6). 메인 턴이 도는 중이면 빈 배열
    /// (그 턴의 result 가 취소로 끝낸다).
    mutating func interrupt(now: Date = Date()) -> [Action] {
        userCancelled = true
        // 남은 알림의 턴 뒤 우리 턴을 기다리던 중 — 도는 턴이 없으니 곧바로 끝낸다.
        if awaitingOwnTurn && !turnActive && !isFinished {
            awaitingOwnTurn = false
            return finishCancelled(reason: Self.interruptedReason, now: now)
        }
        guard isSettled, !isFinished, !turnActive else { return [] }
        if backgroundTaskIDs.isEmpty { return finishCancelled(reason: Self.interruptedReason, now: now) }
        return [.emit(.notice("백그라운드 작업 \(backgroundTaskIDs.count)개를 함께 멈춥니다."))]
    }

    /// `recheck` 로 부탁한 때가 지났다. 기다리는 중 목록이 그대로 비어 있으면 끝낸다.
    /// 때가 되기 전이면 남은 만큼 다시 부탁한다 — 어댑터의 잠(`Task.sleep`)은 벽시계와 다른 시계라 일찍 깰 수 있고,
    /// 빈 배열을 돌려주면 다시 보기가 끊겨 실행이 끝나지 않는다.
    mutating func tick(now: Date = Date()) -> [Action] {
        if awaitingOwnTurn, !isFinished {
            if let wait = Self.remaining(&awaitingOwnSince, grace: Self.followUpGrace, now: now) {
                return [.recheck(after: wait)]
            }
            return ownTurnMissing("남은 알림을 처리한 뒤 이번 메시지의 턴이 \(Int(Self.followUpGrace))초 안에 열리지 않았습니다",
                                  now: now)
        }
        guard isSettled, !isFinished, !turnActive, backgroundTaskIDs.isEmpty else { return [] }
        if awaitingFollowUp {
            if let wait = Self.remaining(&awaitingSince, grace: Self.followUpGrace, now: now) {
                return [.recheck(after: wait)]
            }
            var actions: [Action] = [.emit(.notice(
                "백그라운드 작업은 끝났지만 후속 턴이 \(Int(Self.followUpGrace))초 안에 열리지 않아 마지막 응답으로 끝냅니다."))]
            actions += finish(merged(now: now), now: now)
            return actions
        }
        if let wait = Self.remaining(&quietSince, grace: Self.emptyListDebounce, now: now) {
            return [.recheck(after: wait)]
        }
        return finish(merged(now: now), now: now)
    }

    /// 프로세스가 끝났거나 출력이 닫혔다 (`status` 는 종료 코드, 출력만 닫혔으면 nil). 결과가 없으면 빈 배열 — 어댑터가
    /// 지금처럼 처리한다. 기다리는 중이면 마지막 결과로 끝낸다 (`exit_N` 실패로 만들지 않는다 — t7). 후속 턴 도중이면
    /// 그 턴의 답을 받지 못했으므로 실패다. 어느 쪽이든 마지막 결과 뒤의 사용량은 모르므로 미확정.
    /// `stderr` 는 마지막 결과 · 후속 턴 시작 뒤의 것만 넘긴다 (어댑터가 자른다 — 앞 턴의 줄로 실패를 분류하지 않게).
    mutating func processEnded(status: Int32?, signaled: Bool = false, stderr: String = "",
                               now: Date = Date()) -> [Action] {
        guard !isFinished, lastResult != nil else { return [] }
        if userCancelled { return finishCancelled(reason: Self.interruptedReason, now: now) }
        let code = status.map { " (코드 \($0)\(signaled ? ", 시그널" : ""))" } ?? ""
        if awaitingOwnTurn || inStaleTurn {
            return ownTurnMissing("남은 알림만 처리하고 claude 프로세스가 종료되었습니다\(code)", now: now)
        }
        var result = merged(now: now)
        result.usage?.confirmed = false
        guard turnActive else {
            var actions: [Action] = [.emit(.notice(
                "claude 프로세스가 백그라운드 작업을 기다리는 중 종료되었습니다\(code). 마지막 응답으로 끝냅니다."))]
            actions += finish(result, now: now)
            return actions
        }
        let message = "후속 턴 도중 claude 프로세스가 종료되었습니다\(code)"
        result.state = .failed
        result.terminalReason = status.map { "exit_\($0)" } ?? "stream_closed"
        result.isError = true
        result.errorMessage = Self.tail(stderr, max: Self.stderrTailLimit) ?? message
        result.limitStatus = ErrorClassifier.classify(stderr)
        result.structuredOutput = nil
        var actions: [Action] = [.emit(.notice("\(message). 실패로 끝냅니다."))]
        actions += finish(result, now: now)
        return actions
    }

    /// 중단 요청에 응답이 없어 프로세스를 정리했다 (어댑터의 8초 감시). 받은 결과가 있으면 그 사용량을 싣는다.
    mutating func cancel(reason: String, now: Date = Date()) -> [Action] {
        guard !isFinished else { return [] }
        return finishCancelled(reason: reason, now: now)
    }

    // MARK: - system

    private mutating func system(_ obj: [String: Any], now: Date) -> [Action] {
        let subtype = obj["subtype"] as? String ?? ""
        switch subtype {
        case "init":
            return initialized(obj)
        case "task_started":
            return taskStarted(obj, now: now)
        case "task_progress":
            return taskProgress(obj)
        case "task_updated":
            return taskUpdated(obj, now: now)
        case "task_notification":
            return taskNotification(obj, now: now)
        case "background_tasks_changed":
            // ambient 작업은 일이 아니다 (감시는 끝나지 않는다). 표시가 바뀌면 목록을 다시 보낸다 — 매번 거르면 된다.
            // 목록 항목의 `ambient` 만 본다 — `skip_transcript` 만 붙은 작업은 남겨 기다린다.
            let tasks = obj["tasks"] as? [[String: Any]] ?? []
            backgroundTaskIDs = tasks.filter { ($0["ambient"] as? Bool) != true }.compactMap { $0["task_id"] as? String }
            return markListedBackground()
        case "hook_response":
            return hookResponse(obj)
        case "task_summary":
            // 지금 하는 일을 한 줄로 요약한 진행 문구 — 작업의 수명 이벤트가 아니다 (2.1.270 번들 스키마: `detail` 은 글 또는 null,
            // null 은 쉴 때 지움). 끝 판정에는 쓰지 않고 실행 중 상태 줄에만 넘긴다.
            return [.emit(.progressSummary(CLINoticeText.firstLine(obj["detail"] as? String, max: 120)))]
        case "compact_boundary":
            return [.emit(.notice("대화 압축(compact)이 수행되었습니다."))]
        default:
            // CLI 가 바뀌어 모르는 작업 이벤트가 생기면 버리지 않고 진단으로 남긴다 (실행마다 종류별 한 번 — 대화에는 보이지 않는다).
            guard subtype.hasPrefix("task_"), unknownTaskSubtypes.insert(subtype).inserted else { return [] }
            return [.emit(.diagnostic("알 수 없는 작업 이벤트: \(subtype)"))]
        }
    }

    /// 훅의 결과 (`hook_name` · `hook_event` · `output` · `stdout` · `stderr` · `exit_code` · `outcome` — 2.1.270 번들 스키마).
    /// 실패(`outcome: error`, 또는 outcome 이 없는 옛 CLI 의 0 아닌 종료 코드)만 사람이 할 일로 — 같은 훅은 실행마다 한 번.
    /// 성공한 훅의 출력과 두 번째부터의 실패는 진단이다 (턴마다 답 위에 훅 글이 쌓이던 것).
    private mutating func hookResponse(_ obj: [String: Any]) -> [Action] {
        var name: String = "훅"
        if let given = obj["hook_name"] as? String, !given.isEmpty { name = given }
        var event: String?
        if let given = obj["hook_event"] as? String, !given.isEmpty { event = given }
        let exitCode: Int? = JSONUtil.int(obj["exit_code"])
        let outcome: String? = obj["outcome"] as? String
        // 훅이 남긴 글 — stderr · output · stdout 중 처음 비지 않은 것.
        var output: String?
        for key in ["stderr", "output", "stdout"] {
            guard let text = obj[key] as? String else { continue }
            let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                output = trimmed
                break
            }
        }
        let failed: Bool = outcome == "error" || (outcome == nil && (exitCode ?? 0) != 0)
        if failed, failedHooks.insert(name).inserted {
            let text: String = CLINoticeText.hookFailed(name: name, event: event, message: CLINoticeText.firstLine(output),
                                                        exitCode: exitCode)
            return [.emit(.attention(text))]
        }
        guard failed || output != nil else { return [] }
        var label: String = name
        if let event { label += " (\(event))" }
        if let outcome { label += " · \(outcome)" }
        let body: String = JSONUtil.truncate(output ?? "출력 없음", max: 400)
        return [.emit(.diagnostic("훅 \(label): \(body)"))]
    }

    /// 첫 init 은 세션 수립. 결과 뒤의 init 은 CLI 가 스스로 연 후속 턴 (같은 session_id — 같은 실행의 연장).
    private mutating func initialized(_ obj: [String: Any]) -> [Action] {
        let sid = obj["session_id"] as? String
        let m = obj["model"] as? String
        if let m { initModel = m }
        turnActive = true
        var actions: [Action] = []
        // 세션 수립은 처음 한 번 — 후속 턴의 init 이 세션 · 모델을 다시 적지 않게. 세션이 바뀌었을 때만 다시.
        if let sid, sid != sessionID {
            sessionID = sid
            actions.append(.emit(.sessionEstablished(sessionID: sid, model: m, cliVersion: nil)))
        }
        guard sawInit else {
            sawInit = true
            if let servers = obj["mcp_servers"] as? [[String: Any]], !servers.isEmpty {
                // 이름이 있다는 이유만으로 정상 작동한다고 표시하지 않는다. CLI 가 보고한 status 를 그대로 진단으로 남기고,
                // 사람이 할 일(인증 필요 · 연결 실패)만 대화에 한 줄로 — 첫 init 하나라 실행마다 한 번이다.
                var reported: [(name: String, status: String)] = []
                for server in servers {
                    let name: String = server["name"] as? String ?? "?"
                    let status: String = server["status"] as? String ?? "미확인"
                    reported.append((name: name, status: status))
                }
                actions.append(.emit(.diagnostic(CLINoticeText.mcpSummary(reported))))
                func names(_ status: String) -> [String] {
                    var seen = Set<String>()
                    var out: [String] = []
                    for server in reported where server.status == status && seen.insert(server.name).inserted {
                        out.append(server.name)
                    }
                    return out
                }
                let needsAuth = names("needs-auth"), failed = names("failed")
                if !needsAuth.isEmpty { actions.append(.emit(.attention(CLINoticeText.mcpNeedsAuth(needsAuth)))) }
                if !failed.isEmpty { actions.append(.emit(.attention(CLINoticeText.mcpFailed(failed)))) }
            }
            return actions
        }
        // 결과 전에 되풀이된 init 은 후속 턴이 아니다.
        guard lastResult != nil else { return actions }
        isSettled = false
        awaitingFollowUp = false
        notifiedDuringTurn = false
        quietSince = nil
        awaitingSince = nil
        actions.append(.emit(.followUpTurnStarted))
        return actions
    }

    private mutating func taskStarted(_ obj: [String: Any], now: Date) -> [Action] {
        guard let taskID = obj["task_id"] as? String else { return [] }
        if var job = jobs[taskID] {
            // 끝났던 작업이 다시 깼다 (t5 · t8: 하위가 띄운 셸이 끝나 하위가 이어 간다) — 같은 행을 다시 실행 중으로.
            job.info.status = .running
            job.info.endedAt = nil
            job.info.summary = nil
            jobs[taskID] = job
            guard !job.hidden else { return [] }
            noteWorkAfterResult()
            return [.emit(.subAgent(job.info))]
        }
        let toolUseID = obj["tool_use_id"] as? String ?? taskID
        let kind = Self.kind(obj["task_type"] as? String)
        // 하위가 띄운 작업(셸 등)의 tool_use_id 는 하위 안의 호출이다 — 그 부모를 따라 올라가 하위 에이전트를 찾는다.
        let owner = parentOf[toolUseID].map { nearestAgent(from: $0) ?? $0 }
        let description = (obj["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let info = SubAgentInfo(
            id: toolUseID, taskID: taskID, kind: kind, title: description ?? Self.defaultTitle(kind),
            detail: (obj["subagent_type"] as? String) ?? (obj["workflow_name"] as? String),
            ownerID: owner,
            // 워크플로는 is_backgrounded 를 싣지 않는다 (t3) — 목록에 있으면 백그라운드다.
            isBackground: (obj["is_backgrounded"] as? Bool) ?? backgroundTaskIDs.contains(taskID),
            startedAt: now)
        let hidden = Self.isHousekeeping(obj)
        jobs[taskID] = Job(info: info,
                           ownedBySubagent: (obj["owned_by_subagent"] as? Bool ?? false) || owner != nil,
                           hidden: hidden)
        jobOrder.append(taskID)
        taskIDByAgent[toolUseID] = taskID
        guard !hidden else { return [] }
        noteWorkAfterResult()
        var actions: [Action] = [.emit(.subAgent(info))]
        // 하위에게 준 요청 (하위 흐름의 첫 줄). 백그라운드 Agent 는 이것 말고는 요청을 보내지 않는다 (t2 · t5).
        // 워크플로의 prompt 는 스크립트라 넣지 않는다 (t3).
        if kind == .agent, let text = obj["prompt"] as? String, let event = Self.prompt(text) {
            promptByAgent[toolUseID] = Self.trimmed(text)
            actions.append(.emit(.subAgentEvent(agentID: toolUseID, event: event)))
        }
        return actions
    }

    /// 진행만 바뀐다 (초당 여러 번). 저장할지는 받는 쪽이 `differsForStorage` 로 정한다.
    private mutating func taskProgress(_ obj: [String: Any]) -> [Action] {
        guard let taskID = obj["task_id"] as? String, var job = jobs[taskID] else { return [] }
        if let d = obj["description"] as? String, !d.isEmpty { job.info.progress = d }
        if let tool = obj["last_tool_name"] as? String, !tool.isEmpty { job.info.lastToolName = tool }
        Self.applyUsage(obj["usage"], to: &job.info)
        jobs[taskID] = job
        guard !job.hidden else { return [] }
        noteWorkAfterResult()
        return [.emit(.subAgent(job.info))]
    }

    private mutating func taskUpdated(_ obj: [String: Any], now: Date) -> [Action] {
        guard let taskID = obj["task_id"] as? String, var job = jobs[taskID],
              let status = Self.status((obj["patch"] as? [String: Any])?["status"] as? String),
              status != job.info.status else { return [] }
        job.info.status = status
        job.info.endedAt = status.isFinished ? now : nil
        jobs[taskID] = job
        return job.hidden ? [] : [.emit(.subAgent(job.info))]
    }

    private mutating func taskNotification(_ obj: [String: Any], now: Date) -> [Action] {
        guard let taskID = obj["task_id"] as? String else { return [] }
        // 이번 실행이 띄우지 않은 작업 — 이어받은 세션에 남아 있던 것. 그 알림의 턴이 우리 메시지보다 먼저 돈다.
        guard var job = jobs[taskID] else {
            guard !ownTurnStarted, !staleNotificationSeen else { return [] }
            staleNotificationSeen = true
            return [.emit(.notice("이어받은 세션에 남아 있던 백그라운드 작업의 알림을 CLI 가 먼저 처리합니다 — 이번 메시지는 그 다음에 갑니다."))]
        }
        // 알림은 작업의 끝이다. 모르는 상태는 성공으로 치지 않는다.
        let status = Self.status(obj["status"] as? String).flatMap { $0.isFinished ? $0 : nil } ?? .stopped
        job.info.status = status
        job.info.endedAt = job.info.endedAt ?? now
        if let summary = obj["summary"] as? String, !summary.isEmpty { job.info.summary = summary }
        Self.applyUsage(obj["usage"], to: &job.info)
        jobs[taskID] = job
        guard !job.hidden else { return [] }
        noteWorkAfterResult()
        // 메인이 띄운 백그라운드 작업의 끝은 메인 후속 턴을 연다. 사용자가 멈춘 실행 · 일이 아닌 작업은 기다리지 않는다.
        // 메인 턴이 도는 중이면 CLI 가 그 턴에 흡수할 수 있다 (후속 턴 없음) — 따로 적어 두고 디바운스로 본다.
        if job.info.isBackground && !job.ownedBySubagent && !userCancelled && !Self.isHousekeeping(obj) {
            if turnActive { notifiedDuringTurn = true } else { awaitingFollowUp = true }
        }
        return [.emit(.subAgent(job.info))]
    }

    /// 목록에 있는 작업은 백그라운드다 (포그라운드로 시작했다가 넘어간 작업 · 표시가 없는 작업).
    private mutating func markListedBackground() -> [Action] {
        var actions: [Action] = []
        for taskID in backgroundTaskIDs {
            guard var job = jobs[taskID], !job.hidden, !job.info.isBackground else { continue }
            job.info.isBackground = true
            jobs[taskID] = job
            actions.append(.emit(.subAgent(job.info)))
        }
        return actions
    }

    // MARK: - 메시지

    private mutating func streamEvent(_ obj: [String: Any]) -> [Action] {
        guard let ev = obj["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
              let delta = ev["delta"] as? [String: Any] else { return [] }
        let parent = Self.parent(obj)
        if let text = delta["text"] as? String, !text.isEmpty {
            // 남은 알림의 턴에서 흐르는 글은 우리 답이 아니다 — 끝난 글만 안내로 남긴다 (`assistant`).
            if parent == nil && inStaleTurn { return [] }
            return route([.assistantDelta(text)], parent: parent)
        }
        if let thinking = delta["thinking"] as? String, !thinking.isEmpty {
            return route([.reasoning(thinking)], parent: parent)
        }
        return []
    }

    private mutating func assistant(_ obj: [String: Any]) -> [Action] {
        guard let message = obj["message"] as? [String: Any] else { return [] }
        let parent = Self.parent(obj)
        // 대표 모델은 메인의 것만 — 하위가 다른 모델이어도 바꾸지 않는다. 하위의 모델은 그 하위의 작업 행에 적는다
        // (에이전트 탭 · 카드가 누가 무엇으로 일했는지 보인다). `<synthetic>` 같은 CLI 내부 이름은 모델이 아니다.
        if parent == nil, let m = message["model"] as? String { mainModel = m }
        var modelActions: [Action] = []
        if let parent, let m = message["model"] as? String, !m.isEmpty, !m.hasPrefix("<"),
           let taskID = taskIDByAgent[parent], var job = jobs[taskID], job.info.model != m {
            job.info.model = m
            jobs[taskID] = job
            if !job.hidden { modelActions.append(.emit(.subAgent(job.info))) }
        }
        guard let content = message["content"] as? [[String: Any]] else { return modelActions }
        var events: [AgentEvent] = []
        for block in content {
            switch block["type"] as? String {
            case "tool_use":
                let id = block["id"] as? String ?? UUID().uuidString
                if let parent { parentOf[id] = parent }
                events.append(.toolStarted(id: id, name: block["name"] as? String ?? "도구",
                                           detail: JSONUtil.truncate(JSONUtil.prettyString(block["input"] ?? [:]),
                                                                     max: 4000)))
            case "text":
                guard let text = block["text"] as? String, !text.isEmpty else { continue }
                // 남은 알림의 턴에 한 말 — 우리 답으로 보이지 않게 안내 한 줄로.
                if parent == nil && inStaleTurn {
                    events.append(.notice("남은 작업 알림에 대한 응답: \(JSONUtil.truncate(text, max: 300))"))
                    continue
                }
                if parent == nil { lastMainText = text }
                events.append(.assistantMessage(text))
            case "thinking":
                guard let text = block["thinking"] as? String, !text.isEmpty else { continue }
                events.append(.reasoning(text))
            default:
                break
            }
        }
        return modelActions + route(events, parent: parent)
    }

    private mutating func user(_ obj: [String: Any]) -> [Action] {
        guard let message = obj["message"] as? [String: Any] else { return [] }
        let parent = Self.parent(obj)
        // CLI 가 되돌려 준 우리 메시지 — 그 턴이 열렸다. 글은 이미 기록했으니 내지 않는다.
        if obj["isReplay"] as? Bool == true {
            if parent == nil {
                ownTurnStarted = true
                awaitingOwnTurn = false
                awaitingOwnSince = nil
            }
            return []
        }
        if let parent, let text = message["content"] as? String {
            return route(childText(text, parent: parent, obj: obj).map { [$0] } ?? [], parent: parent)
        }
        guard let content = message["content"] as? [[String: Any]] else { return [] }
        var events: [AgentEvent] = []
        for block in content {
            switch block["type"] as? String {
            case "tool_result":
                let id = block["tool_use_id"] as? String ?? ""
                let isError = block["is_error"] as? Bool ?? false
                var text = ""
                if let s = block["content"] as? String {
                    text = s
                } else if let arr = block["content"] as? [[String: Any]] {
                    text = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if text.isEmpty { text = JSONUtil.prettyString(arr) }
                }
                events.append(.toolFinished(id: id, name: "도구 결과",
                                            output: JSONUtil.truncate(text, max: 20000), isError: isError))
            case "text":
                // 하위 안의 사용자 글. 메인의 사용자 글(스킬 본문 등)은 지금처럼 버린다.
                guard let parent, let text = block["text"] as? String,
                      let event = childText(text, parent: parent, obj: obj) else { continue }
                events.append(event)
            default:
                break
            }
        }
        return route(events, parent: parent)
    }

    /// 하위 안의 사용자 글 하나: 처음 것은 요청(하위 흐름의 첫 줄), 이미 낸 요청과 같은 글(포그라운드의 되풀이)은 버리고,
    /// 중단 표시(t6)는 "중단됨", 그 밖은 그대로 안내. CLI 가 만든 글(`isSynthetic` · `isMeta` — 스킬 본문 등)은 버린다.
    private mutating func childText(_ text: String, parent: String, obj: [String: Any]) -> AgentEvent? {
        guard obj["isSynthetic"] as? Bool != true, obj["isMeta"] as? Bool != true else { return nil }
        let body = Self.trimmed(text)
        guard !body.isEmpty else { return nil }
        if body.hasPrefix("[Request interrupted") { return .notice("중단됨") }
        let agent = nearestAgent(from: parent) ?? parent
        guard let shown = promptByAgent[agent] else {
            promptByAgent[agent] = body
            return Self.prompt(body)
        }
        return shown == body ? nil : .notice(JSONUtil.truncate(body, max: Self.promptLimit))
    }

    /// 부모가 없으면 메인 흐름, 있으면 그 하위 에이전트의 흐름으로. 숨긴 작업(`ambient` · `skip_transcript`)의 글은 버린다.
    private func route(_ events: [AgentEvent], parent: String?) -> [Action] {
        guard let parent else { return events.map { .emit($0) } }
        let agent = nearestAgent(from: parent) ?? parent
        if let taskID = taskIDByAgent[agent], jobs[taskID]?.hidden == true { return [] }
        return events.map { .emit(.subAgentEvent(agentID: agent, event: $0)) }
    }

    /// 부모 표를 따라 올라가 처음 만나는 에이전트 작업의 id. 셸은 메시지를 담지 않으므로 건너뛴다.
    private func nearestAgent(from id: String) -> String? {
        var cursor: String? = id
        var hops = 0
        while let current = cursor, hops < 64 {
            if let taskID = taskIDByAgent[current], jobs[taskID]?.info.kind != .shell { return current }
            cursor = parentOf[current]
            hops += 1
        }
        return nil
    }

    // MARK: - result · 끝

    private mutating func result(_ obj: [String: Any], now: Date) -> [Action] {
        turnActive = false
        // 새 누적 사용량 — 그 전의 하위 작업이 쓴 것까지 들어 있다.
        workAfterResult = false
        let interpretation = ClaudeAdapter.interpretResult(
            obj, userCancelled: userCancelled, fallbackModel: mainModel ?? initModel, startedAt: startedAt,
            preferredModel: initModel)
        var actions: [Action] = interpretation.notices.map { .emit(.notice($0)) }
        var result = interpretation.result
        result.sessionID = sessionID ?? result.sessionID
        // 남은 알림의 턴이 끝났다 — 우리 메시지는 그 다음 턴에 간다. 끝내지 않고 기다린다 (오류 · 취소면 그대로 끝낸다).
        if inStaleTurn && result.state == .completed && !userCancelled {
            if lastResult == nil { lastResult = result }
            awaitingOwnTurn = true
            awaitingOwnSince = now
            return actions + [.recheck(after: Self.followUpGrace)]
        }
        if firstStructuredOutput == nil { firstStructuredOutput = result.structuredOutput }
        lastResult = result
        // 턴 중에 끝난 메인 작업 — 흡수되지 않았으면 CLI 가 곧(~100ms) 후속 턴을 연다. 디바운스 동안 기다려 본다.
        let notified = notifiedDuringTurn
        notifiedDuringTurn = false

        let remaining = backgroundTaskIDs.count
        if waitForBackground && result.state == .completed && !userCancelled
            && (remaining > 0 || awaitingFollowUp || notified) {
            isSettled = true
            everSettled = true
            actions.append(.settle(remaining: remaining))
            actions += waitCheck(now: now)
            return actions
        }
        // 기다리지 않는다. 오류 · 한도 · 취소는 바로 끝 (한도 도달이 후속 턴에서 와도 끝낸다 → 자동 인계가 돈다).
        if remaining > 0 {
            actions.append(.emit(.notice("백그라운드 작업 \(remaining)개가 실행과 함께 멈췄습니다")))
        }
        actions += finish(merged(now: now), now: now)
        return actions
    }

    /// 기다리는 중 목록 · 후속 턴 상태가 바뀌었을 때: 곧바로 끝낼지, 얼마 뒤 다시 볼지.
    private mutating func waitCheck(now: Date) -> [Action] {
        guard isSettled, !isFinished, !turnActive, backgroundTaskIDs.isEmpty else {
            quietSince = nil
            awaitingSince = nil
            return []
        }
        // 사용자가 멈췄고 작업이 모두 멈췄다 — CLI 는 result 를 내지 않는다 (t6).
        if userCancelled { return finishCancelled(reason: Self.interruptedReason, now: now) }
        if awaitingFollowUp {
            quietSince = nil
            guard awaitingSince == nil else { return [] }
            awaitingSince = now
            return [.recheck(after: Self.followUpGrace)]
        }
        awaitingSince = nil
        guard quietSince == nil else { return [] }
        quietSince = now
        return [.recheck(after: Self.emptyListDebounce)]
    }

    /// 끝낼 때의 결과: 마지막 `result` 의 해석 (사용량 · 비용은 프로세스 누적이라 그것 하나만 쓴다 — 합치지 않는다).
    /// 글은 마지막 메인 답, 구조화 응답은 처음 온 것, 걸린 시간은 기다렸으면 실행 시작부터.
    /// 그 결과 뒤에 하위 작업이 진행 · 끝났으면 (디바운스 · 안전장치 · 종료로 끝낼 때) 사용량은 미확정.
    private func merged(now: Date) -> AgentTurnResult {
        var result = lastResult ?? AgentTurnResult(state: .completed, sessionID: sessionID)
        if result.resultText == nil { result.resultText = lastMainText }
        if let first = firstStructuredOutput { result.structuredOutput = first }
        if everSettled { result.usage?.durationMs = Int(now.timeIntervalSince(startedAt) * 1000) }
        if workAfterResult { result.usage?.confirmed = false }
        return result
    }

    /// 메인 턴이 끝난 뒤(결과를 받고 기다리는 중) 보이는 하위 작업이 움직였다.
    private mutating func noteWorkAfterResult() {
        if !turnActive && lastResult != nil { workAfterResult = true }
    }

    /// `since` 부터 `grace` 가 아직 지나지 않았으면 남은 시간 (`minRecheck` ~ `grace`), 지났으면 nil.
    /// 시계가 뒤로 갔거나 재기 시작한 때가 없으면 지금부터 다시 잰다.
    private static func remaining(_ since: inout Date?, grace: TimeInterval, now: Date) -> TimeInterval? {
        guard let start = since, now >= start else {
            since = now
            return grace
        }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed < grace - clockSlack else { return nil }
        return min(max(grace - elapsed, minRecheck), grace)
    }

    /// 남은 알림의 턴만 돌고 우리 메시지의 턴은 열리지 않았다 — 메시지가 처리되지 않았으므로 실패로 끝낸다 (다시 보내게).
    private mutating func ownTurnMissing(_ reason: String, now: Date) -> [Action] {
        awaitingOwnTurn = false
        var result = merged(now: now)
        result.state = .failed
        result.terminalReason = "own_turn_missing"
        result.isError = true
        result.errorMessage = "\(reason). 이번 메시지는 처리되지 않았습니다 — 다시 보내 주세요."
        result.usage?.confirmed = false
        result.structuredOutput = nil
        return [.emit(.notice(result.errorMessage ?? reason))] + finish(result, now: now)
    }

    private mutating func finishCancelled(reason: String, now: Date) -> [Action] {
        userCancelled = true
        var result = merged(now: now)
        result.state = .cancelled
        result.terminalReason = reason
        result.isError = false
        result.errorMessage = nil
        result.limitStatus = nil
        result.structuredOutput = nil
        // 멈춘 실행의 사용량은 확정이 아니다 (마지막 결과 뒤에 쓴 것이 빠져 있다).
        result.usage?.confirmed = false
        return finish(result, now: now)
    }

    private mutating func finish(_ result: AgentTurnResult, now: Date) -> [Action] {
        var actions = closeRunning(now: now)
        isFinished = true
        actions.append(.finish(result))
        return actions
    }

    /// 끝나지 않은 작업을 멈춤으로 닫는다 — 실행이 끝나면 프로세스와 함께 멈춘다.
    private mutating func closeRunning(now: Date) -> [Action] {
        var actions: [Action] = []
        for taskID in jobOrder {
            guard var job = jobs[taskID], job.info.status == .running else { continue }
            job.info.status = .stopped
            job.info.endedAt = now
            jobs[taskID] = job
            if !job.hidden { actions.append(.emit(.subAgent(job.info))) }
        }
        return actions
    }

    // MARK: - 도우미

    private static func parent(_ obj: [String: Any]) -> String? {
        guard let p = obj["parent_tool_use_id"] as? String, !p.isEmpty else { return nil }
        return p
    }

    private static func prompt(_ text: String) -> AgentEvent? {
        let body = trimmed(text)
        guard !body.isEmpty else { return nil }
        return .notice("요청: \(JSONUtil.truncate(body, max: promptLimit))")
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 글의 끝부분 (원인은 대개 마지막 줄에 있다). 비었으면 nil.
    private static func tail(_ text: String, max: Int) -> String? {
        let body = trimmed(text)
        guard !body.isEmpty else { return nil }
        return body.count > max ? "…" + String(body.suffix(max)) : body
    }

    /// 일이 아닌 작업 (CLI 스키마: "hosts should exclude them from activity indicators" · "hide this from the inline transcript").
    private static func isHousekeeping(_ obj: [String: Any]) -> Bool {
        obj["ambient"] as? Bool == true || obj["skip_transcript"] as? Bool == true
    }

    private static func applyUsage(_ any: Any?, to info: inout SubAgentInfo) {
        guard let usage = any as? [String: Any] else { return }
        if let n = JSONUtil.int(usage["total_tokens"]) { info.totalTokens = n }
        if let n = JSONUtil.int(usage["tool_uses"]) { info.toolUses = n }
    }

    static func kind(_ taskType: String?) -> SubAgentInfo.Kind {
        switch taskType {
        case "local_agent": return .agent
        case "local_workflow": return .workflow
        case "local_bash": return .shell
        default: return .other
        }
    }

    private static func defaultTitle(_ kind: SubAgentInfo.Kind) -> String {
        switch kind {
        case .agent: return "하위 에이전트"
        case .workflow: return "워크플로"
        case .shell: return "백그라운드 셸"
        case .other: return "백그라운드 작업"
        }
    }

    /// `task_updated.patch.status` · `task_notification.status` → 상태. 모르는 값은 nil.
    static func status(_ raw: String?) -> SubAgentInfo.Status? {
        switch raw {
        case "running", "pending": return .running
        case "completed", "success": return .completed
        case "failed", "error": return .failed
        case "killed", "stopped", "cancelled", "canceled": return .stopped
        default: return nil
        }
    }
}
