import Foundation

/// 가짜 어댑터. 정해 둔 순서대로 이벤트를 흘려보내 CLI · 네트워크 없이 `RunCoordinator` 의 실행 흐름을 돌린다.
/// `RunCoordinator.adapterFactory` 로 넣는다. 앱에는 들어가지 않는다.
final class ScriptedAgentAdapter: AgentAdapter, @unchecked Sendable {

    enum Step {
        case emit(AgentEvent)
        /// 이 승인 요청에 응답이 올 때까지 멈춘다 (요청 이벤트는 앞의 `emit` 으로 보낸다).
        case waitApproval(id: String)
        /// 중단 요청이 올 때까지 멈춘다.
        case waitInterrupt
        /// 잠깐 일하는 척한다 (중단 요청이 오면 바로 깬다).
        case delay(milliseconds: Int)
        /// 검증이 `signal(_:)` 로 이 이름을 부를 때까지 멈춘다 (중단 요청이 와도 깬다).
        /// 백그라운드 작업이 언제 끝나는지 · 후속 턴이 언제 열리는지를 검증이 정할 때 쓴다.
        case waitSignal(String)
        case finish(AgentTurnResult)
    }

    let provider: AgentProvider
    private var steps: [Step]
    /// 요청을 보고 대본을 정한다 (계획 · 실행 · 검토 턴을 한 가짜로 받을 때).
    private let script: (@Sendable (AgentTurnRequest) -> [Step])?
    private let lock = UnfairLock()
    private var continuation: AsyncStream<AgentEvent>.Continuation?
    private var receivedRequests: [AgentTurnRequest] = []
    private var approvalDecisions: [String: ApprovalDecision] = [:]
    private var interrupted = false
    private var finished = false
    private var didShutdown = false
    private var signals: Set<String> = []
    private var stopRequests: [String] = []
    private var acceptsStop = true
    private var knownUsage: TurnUsage?
    private var shutdownGate: String?
    private var shutdownResult = true
    /// `stopSubAgent` 가 돌려줄 값 (작업 하나 멈추기를 제공하는 제공자처럼). 기본은 보냈다고 답한다.
    var stopSubAgentAccepts: Bool {
        get { lock.lock(); defer { lock.unlock() }; return acceptsStop }
        set { lock.lock(); acceptsStop = newValue; lock.unlock() }
    }
    /// 결과 없이 끊길 때 실행기가 남길 사용량 (`AgentAdapter.lastKnownUsage`). 검증이 정한다.
    var lastKnownUsage: TurnUsage? {
        get { lock.lock(); defer { lock.unlock() }; return knownUsage }
        set { lock.lock(); knownUsage = newValue; lock.unlock() }
    }
    /// 이름을 주면 `shutdown` 이 `signal(_:)` 로 그 이름을 받을 때까지 멈춘다 (실행기가 끝내는 도중에 끼어드는 요청을 볼 때).
    var shutdownWaitsFor: String? {
        get { lock.lock(); defer { lock.unlock() }; return shutdownGate }
        set { lock.lock(); shutdownGate = newValue; lock.unlock() }
    }
    /// `shutdown` 이 돌려줄 값. false 면 프로세스 종료를 확인하지 못한 것처럼 답한다.
    var shutdownSucceeds: Bool {
        get { lock.lock(); defer { lock.unlock() }; return shutdownResult }
        set { lock.lock(); shutdownResult = newValue; lock.unlock() }
    }

    init(provider: AgentProvider, steps: [Step]) {
        self.provider = provider
        self.steps = steps
        self.script = nil
    }

    init(provider: AgentProvider, script: @escaping @Sendable (AgentTurnRequest) -> [Step]) {
        self.provider = provider
        self.steps = []
        self.script = script
    }

    /// 한 번의 응답으로 끝나는 턴.
    static func replying(_ text: String, provider: AgentProvider = .claude, sessionID: String = "fake-session",
                         structuredOutput: String? = nil) -> ScriptedAgentAdapter {
        var result = AgentTurnResult(state: .completed, terminalReason: "completed", sessionID: sessionID,
                                     resultText: text)
        result.structuredOutput = structuredOutput
        return ScriptedAgentAdapter(provider: provider, steps: [
            .emit(.sessionEstablished(sessionID: sessionID, model: "fake-model", cliVersion: "0.0-fake")),
            .emit(.assistantMessage(text)),
            .finish(result),
        ])
    }

    // MARK: 검증용 기록

    var requests: [AgentTurnRequest] { lock.lock(); defer { lock.unlock() }; return receivedRequests }
    var decisions: [String: ApprovalDecision] { lock.lock(); defer { lock.unlock() }; return approvalDecisions }
    /// `shutdown` 이 불렸다 (`shutdownWaitsFor` 로 멈춰 있어도 참).
    var wasShutDown: Bool { lock.lock(); defer { lock.unlock() }; return didShutdown }
    /// `stopSubAgent(id:)` 로 받은 하위 작업 ID, 받은 순.
    var stoppedSubAgents: [String] { lock.lock(); defer { lock.unlock() }; return stopRequests }

    /// `waitSignal(name)` 단계를 깨운다. 그 단계에 닿기 전에 불러도 된다.
    func signal(_ name: String) { lock.lock(); signals.insert(name); lock.unlock() }

    // MARK: AgentAdapter

    var currentPID: Int32? { nil }

    func start(_ request: AgentTurnRequest) -> AsyncStream<AgentEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { cont in
            self.lock.lock()
            self.continuation = cont
            self.receivedRequests.append(request)
            if let script = self.script { self.steps = script(request) }
            self.lock.unlock()
            Task { await self.play() }
        }
    }

    private func play() async {
        lock.lock(); let steps = self.steps; lock.unlock()
        for step in steps {
            if isInterrupted { break }
            switch step {
            case .emit(.approvalRequested(var request)):
                // 실제 어댑터처럼 실행 ID 를 싣는다. 코디네이터는 이 값이 지금 실행과 다르면 늦은 응답으로 보고 버린다.
                request.runID = currentRunID
                yield(.approvalRequested(request))
            case .emit(.questionAsked(var question)):
                // 질문도 같다 — 지금 실행의 것이어야 답이 간다.
                if question.runID.isEmpty { question.runID = currentRunID }
                yield(.questionAsked(question))
            case .emit(let event):
                yield(event)
            case .waitApproval(let id):
                while !isInterrupted, decision(for: id) == nil { await pause() }
                if let decision = decision(for: id) {
                    yield(.approvalResolved(id: id, decision: "\(decision)"))
                }
            case .waitInterrupt:
                while !isInterrupted { await pause() }
            case .delay(let milliseconds):
                let until = Date().addingTimeInterval(Double(milliseconds) / 1000)
                while !isInterrupted, Date() < until { await pause() }
            case .waitSignal(let name):
                while !isInterrupted, !hasSignal(name) { await pause() }
            case .finish(let result):
                finish(result)
                return
            }
        }
        finish(AgentTurnResult(state: isInterrupted ? .cancelled : .completed,
                               terminalReason: isInterrupted ? "interrupted" : "completed",
                               sessionID: "fake-session"))
    }

    func respond(approvalID: String, decision: ApprovalDecision) async {
        lock.lock(); approvalDecisions[approvalID] = decision; lock.unlock()
        if case .denyAndCancel = decision { await requestInterrupt() }
    }

    func respond(questionID: String, answers: [String: String]) async {}

    func requestInterrupt() async {
        lock.lock(); interrupted = true; lock.unlock()
    }

    func shutdown() async -> Bool {
        lock.lock(); didShutdown = true; let gate = shutdownGate; let result = shutdownResult; lock.unlock()
        if let gate { while !hasSignal(gate) { await pause() } }
        return result
    }

    func stopSubAgent(id: String) async -> Bool {
        lock.lock(); stopRequests.append(id); let accepts = acceptsStop; lock.unlock()
        return accepts
    }

    // MARK: 도우미

    private var currentRunID: String { lock.lock(); defer { lock.unlock() }; return receivedRequests.last?.runID ?? "" }
    private var isInterrupted: Bool { lock.lock(); defer { lock.unlock() }; return interrupted }
    private func decision(for id: String) -> ApprovalDecision? { lock.lock(); defer { lock.unlock() }; return approvalDecisions[id] }
    private func hasSignal(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return signals.contains(name) }
    private func pause() async { try? await Task.sleep(nanoseconds: 5_000_000) }

    private func yield(_ event: AgentEvent) {
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(event)
    }

    private func finish(_ result: AgentTurnResult) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let c = continuation
        lock.unlock()
        c?.yield(.finished(result))
        c?.finish()
    }
}
