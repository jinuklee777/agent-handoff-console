#if DEBUG
import Foundation

/// 화면 확인용 가짜 어댑터 (`-preview.action subagents` — AHC_OFFLINE=1 · 임시 DB · 임시 폴더 프로젝트에서만, `ContentView`).
///
/// 메인이 하위 에이전트 둘을 띄우고 하나가 끝난 뒤 메인 턴을 마친다 — 남은 하나를 기다리는 상태(`turnSettled`)에서 머문다.
/// 기다리는 동안 남은 하위는 1초마다 진행(마지막 도구 · 토큰 · 도구 수)을 알리고, 흐르는 글(Codex 하위처럼)을 조금 낸다.
/// 대기 중 머리글 · 입력창 · 카드 · 에이전트 탭을 실제 실행기(`RunSession`)를 거쳐 찍으려는 것이다. CLI 를 부르지 않는다.
/// 사람이 멈추면(⌘.) 취소로, 남은 하위를 멈추면(에이전트 탭의 "멈추기") 완료로 끝난다.
final class PreviewSubAgentAdapter: AgentAdapter, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = UnfairLock()
    private var continuation: AsyncStream<AgentEvent>.Continuation?
    private var interrupted = false
    private var stopIDs: Set<String> = []
    private var finished = false

    init(provider: AgentProvider) { self.provider = provider }

    var currentPID: Int32? { nil }

    func start(_ request: AgentTurnRequest) -> AsyncStream<AgentEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            self.lock.withLock { self.continuation = continuation }
            Task { await self.play(request) }
        }
    }

    private func play(_ request: AgentTurnRequest) async {
        let started = Date()
        let login = request.workingDirectory.appendingPathComponent("Moa/Login/LoginView.swift").path
        emit(.sessionEstablished(sessionID: "preview-subagents", model: request.model ?? "preview", cliVersion: nil))
        emit(.assistantMessage("두 하위 에이전트에게 나눠 맡기겠습니다 — 하나는 문구를 쓰는 곳을 찾고, 하나는 로그인 화면을 고칩니다."))
        emit(.toolStarted(id: "toolu_find", name: "Agent",
                          detail: #"{"description":"오류 문구 쓰는 곳 찾기","subagent_type":"Explore","run_in_background":true}"#))
        emit(.toolStarted(id: "toolu_fix", name: "Agent",
                          detail: #"{"description":"로그인 화면 문구 정리","subagent_type":"general-purpose","run_in_background":true}"#))
        var find = SubAgentInfo(id: "toolu_find", taskID: "task_find", kind: .agent, title: "오류 문구 쓰는 곳 찾기",
                                detail: "Explore", isBackground: true, startedAt: started)
        var fix = SubAgentInfo(id: "toolu_fix", taskID: "task_fix", kind: .agent, title: "로그인 화면 문구 정리",
                               detail: "general-purpose", isBackground: true, startedAt: started.addingTimeInterval(0.2))
        emit(.subAgent(find))
        emit(.subAgent(fix))
        emit(.toolFinished(id: "toolu_find", name: "도구 결과", output: "Async agent launched", isError: false))
        emit(.toolFinished(id: "toolu_fix", name: "도구 결과", output: "Async agent launched", isError: false))
        emit(.subAgentEvent(agentID: "toolu_find", event: .notice("요청: 로그인 오류 문구를 쓰는 파일을 모두 찾아라")))
        emit(.subAgentEvent(agentID: "toolu_fix", event: .notice("요청: LoginView 의 오류 문구를 같은 말투로 고쳐라")))
        emit(.subAgentEvent(agentID: "toolu_find", event: .toolStarted(id: "toolu_f1", name: "Grep",
                                                                        detail: #"{"pattern":"로그인에 실패","path":"Moa"}"#)))
        emit(.subAgentEvent(agentID: "toolu_fix", event: .toolStarted(id: "toolu_x1", name: "Read",
                                                                       detail: "{\"file_path\":\"\(login)\"}")))
        emit(.subAgentEvent(agentID: "toolu_find", event: .toolFinished(id: "toolu_f1", name: "도구 결과",
                                                                         output: "Moa/Login/LoginView.swift:42\nMoa/Auth/AuthViewModel.swift:88",
                                                                         isError: false)))
        emit(.subAgentEvent(agentID: "toolu_fix", event: .toolFinished(id: "toolu_x1", name: "도구 결과",
                                                                        output: "40\tText(\"로그인에 실패했어요\")", isError: false)))
        emit(.subAgentEvent(agentID: "toolu_fix", event: .toolStarted(
            id: "toolu_x2", name: "Edit",
            detail: "{\"file_path\":\"\(login)\",\"old_string\":\"로그인에 실패했어요\",\"new_string\":\"로그인하지 못했습니다\"}")))
        emit(.subAgentEvent(agentID: "toolu_fix", event: .toolFinished(id: "toolu_x2", name: "도구 결과",
                                                                        output: "The file has been updated.", isError: false)))
        let answer = "두 곳에서 씁니다 — `Moa/Login/LoginView.swift` 42행, `Moa/Auth/AuthViewModel.swift` 88행."
        emit(.subAgentEvent(agentID: "toolu_find", event: .assistantMessage(answer)))
        find.status = .completed
        find.endedAt = Date()
        find.summary = answer
        find.toolUses = 2
        find.totalTokens = 9_800
        emit(.subAgent(find))
        emit(.assistantMessage("찾는 쪽은 끝났고, 고치는 쪽이 끝나면 정리해 드리겠습니다."))
        emit(.turnSettled(remaining: 1))

        let live = ["`LoginView.swift` 의 오류 문구 세 곳 중 ", "두 곳을 \"~하지 못했습니다\" 말투로 바꿨고, ",
                    "남은 한 곳을 확인하는 중입니다."]
        let tools = ["Read", "Edit", "Bash"]
        var tick = 0
        while true {
            if isInterrupted {
                fix.status = .stopped
                fix.endedAt = Date()
                emit(.subAgent(fix))
                finish(AgentTurnResult(state: .cancelled, terminalReason: "background_interrupted",
                                       sessionID: "preview-subagents"))
                return
            }
            if isStopRequested(fix.id) {
                fix.status = .stopped
                fix.endedAt = Date()
                emit(.subAgent(fix))
                finish(AgentTurnResult(state: .completed, terminalReason: "completed", sessionID: "preview-subagents",
                                       resultText: "찾는 쪽은 끝났고, 고치는 쪽이 끝나면 정리해 드리겠습니다."))
                return
            }
            fix.lastToolName = tools[tick % tools.count]
            fix.totalTokens = 14_200 + tick * 380
            fix.toolUses = 3 + tick / 2
            fix.progress = "문구 바꾸는 중"
            emit(.subAgent(fix))
            if tick < live.count { emit(.subAgentEvent(agentID: fix.id, event: .assistantDelta(live[tick]))) }
            tick += 1
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func respond(approvalID: String, decision: ApprovalDecision) async {}
    func respond(questionID: String, answers: [String: String]) async {}
    func requestInterrupt() async { lock.withLock { interrupted = true } }
    func shutdown() async -> Bool { true }

    func stopSubAgent(id: String) async -> Bool {
        lock.withLock { _ = stopIDs.insert(id) }
        return true
    }

    // MARK: 도우미

    private var isInterrupted: Bool { lock.withLock { interrupted } }
    private func isStopRequested(_ id: String) -> Bool { lock.withLock { stopIDs.contains(id) } }

    private func emit(_ event: AgentEvent) {
        let continuation = lock.withLock { self.continuation }
        continuation?.yield(event)
    }

    private func finish(_ result: AgentTurnResult) {
        let continuation: AsyncStream<AgentEvent>.Continuation? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            return self.continuation
        }
        continuation?.yield(.finished(result))
        continuation?.finish()
    }
}
#endif
