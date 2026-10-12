import Foundation

/// Claude Code CLI 어댑터.
///
/// 실행 형태: 턴 하나당 프로세스 하나.
///   claude -p --input-format stream-json --output-format stream-json --verbose
///          --include-partial-messages --permission-mode <mode> --permission-prompt-tool stdio
///          [--session-id <uuid> | --resume <uuid>]
/// 실행이 끝나면 프로세스를 종료하므로, 인계 직전에 "이전 에이전트가 파일을 계속 고칠 가능성"을
/// 프로세스 종료로 확인할 수 있다.
///
/// 메인 턴이 끝나도 백그라운드 작업(Agent · Workflow · 셸)이 남으면 `waitForBackground` 인 실행은 프로세스를 살려 두고
/// 기다린다 — CLI 가 스스로 여는 후속 턴까지 같은 실행이다. 메인 · 하위 구분과 실행의 끝은 `ClaudeTurnTracker` 가 정하고,
/// 이 어댑터는 그 동작대로 내고 · 기다리고 · 끝낸다.
///
/// 검증 환경: Claude Code 2.1.266 (2026-09-09). 하위 에이전트 · 백그라운드 작업은 2.1.270 (2026-09-22).
final class ClaudeAdapter: AgentAdapter, @unchecked Sendable {
    let provider: AgentProvider = .claude

    private let executablePath: String
    private let environment: [String: String]
    private let permissionMode: String

    private let lock = UnfairLock()
    /// 트래커의 판정과 그 동작을 내는 순서를 맞춘다. 읽기 루프 · 중단 · 다시 보기(`recheck`) · 감시가 각자 판정하고
    /// 잠금 밖에서 내면, 나중에 판정한 묶음(끝)이 먼저 나가 앞선 묶음이 버려진다.
    /// 판정 전에 잡고 `perform` 이 돌아올 때까지 쥔다. 항상 `lock` 보다 먼저 잡는다. 재진입 불가.
    private let emitOrder = UnfairLock()
    private var proc: ManagedProcess?
    private var continuation: AsyncStream<AgentEvent>.Continuation?
    private var runID: String = ""
    private var finishedEmitted = false
    private var interruptRequested = false
    private var interruptSent = false
    private var processReady = false
    /// 이번 시도에서 세션이 실제로 만들어졌는지 (재개 실패 판정용).
    private var didEstablishSession = false
    /// 한 번의 시도 결과. 재시도 사이에는 스트림을 닫지 않는다.
    private var outcome: AgentTurnResult?
    private var resumeRecoveryUsed = false
    private var userCancelled = false
    private var startedAt = Date()
    /// 살아 있는 승인 요청 하나: 허용할 때 되돌려 줄 입력과 물은 하위 에이전트 (메인이면 nil).
    private struct LiveApproval {
        var input: [String: Any]
        var agentID: String?
    }
    /// 살아 있는 승인 요청. 실행이 끝나면 비워서 늦은 응답을 무효화한다.
    /// 메인 턴이 끝나 기다리는 동안에는 비우지 않는다 — 백그라운드 하위 에이전트도 승인을 묻는다.
    private var liveApprovals: [String: LiveApproval] = [:]
    private var liveQuestions: Set<String> = []
    private var stderrBuffer = ""
    /// 마지막 `result` · 후속 턴의 init 을 받았을 때의 `stderrBuffer` 길이 (UTF-8). 후속 턴 도중 프로세스가 죽으면 이 뒤의
    /// stderr 만 원인으로 본다 — 앞 턴의 줄(이미 지나간 인증 경고 등)로 실패를 잘못 분류하지 않게.
    private var stderrMark = 0
    /// 메인 · 하위 구분과 실행의 끝 판정. 세션 · 모델 · 작업 표 · 마지막 결과를 가진다.
    /// 값 형식이라 잠금 안에서 바꾸고, 돌려받은 동작은 잠금 밖에서 한다 (`perform`).
    private var tracker = ClaudeTurnTracker(waitForBackground: false)

    init(executablePath: String, environment: [String: String], permissionMode: String = "manual") {
        self.executablePath = executablePath
        self.environment = environment
        self.permissionMode = permissionMode
    }

    var currentPID: Int32? {
        lock.lock(); defer { lock.unlock() }
        guard let p = proc, p.isRunning else { return nil }
        return p.processIdentifier
    }

    /// 지금까지 알고 있는 사용량: 마지막 `result` 의 누적값 (그 뒤에 쓴 것은 빠져 있어 미확정). 결과 전이면 nil.
    var lastKnownUsage: TurnUsage? {
        lock.lock(); defer { lock.unlock() }
        guard var usage = tracker.lastResult?.usage else { return nil }
        usage.confirmed = false
        return usage
    }

    // MARK: - 시작

    func start(_ request: AgentTurnRequest) -> AsyncStream<AgentEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { cont in
            self.lock.lock()
            self.continuation = cont
            self.runID = request.runID
            self.startedAt = Date()
            self.tracker = ClaudeTurnTracker(waitForBackground: request.waitForBackground,
                                             startedAt: self.startedAt)
            self.lock.unlock()
            Task { await self.launchWithResumeRecovery(request) }
        }
    }

    private func emit(_ e: AgentEvent) {
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(e)
    }

    /// 세션 재개에 실패하면 새 세션으로 한 번 복구한다.
    /// 파일의 실제 상태가 오래된 요약보다 우선하므로, 복구된 세션은 빈 상태로 시작한다.
    private func launchWithResumeRecovery(_ request: AgentTurnRequest) async {
        var current = request
        while true {
            let result = await runOnce(current)

            lock.lock()
            let established = didEstablishSession
            let cancelled = userCancelled
            let alreadyRecovered = resumeRecoveryUsed
            lock.unlock()

            let resumeFailed = !established
                && (current.resumeSessionID?.isEmpty == false)
                && !cancelled
                && !alreadyRecovered
                && (result.state == .failed)

            guard resumeFailed else {
                finishOnce(result)
                return
            }

            emit(.notice("기존 Claude 세션(\(current.resumeSessionID ?? "")) 재개에 실패했습니다: "
                         + "\(result.errorMessage ?? result.terminalReason ?? "원인 미확인"). "
                         + "새 세션으로 복구합니다. 이전 대화는 이어지지 않으므로 "
                         + "파일의 실제 상태를 기준으로 진행하세요."))

            _ = await shutdown()
            lock.lock()
            resumeRecoveryUsed = true
            outcome = nil
            proc = nil
            processReady = false
            interruptSent = false
            stderrBuffer = ""
            stderrMark = 0
            liveApprovals.removeAll()
            // 새 프로세스 · 새 세션이다 — 작업 표 · 결과 · 첫 init 여부를 처음부터. 걸린 시간은 실행 시작부터 그대로.
            tracker = ClaudeTurnTracker(waitForBackground: current.waitForBackground, startedAt: startedAt)
            // 정리하는 동안 누른 중단은 옛 트래커에만 남았다 — 새 트래커에도 알린다 (턴 전이라 표시만 한다).
            if userCancelled { _ = tracker.interrupt() }
            lock.unlock()

            current.resumeSessionID = nil
            current.preferredNewSessionID = UUID().uuidString
        }
    }

    private func setOutcome(_ result: AgentTurnResult) {
        lock.lock()
        if outcome == nil { outcome = result }
        lock.unlock()
    }

    private func currentOutcome() -> AgentTurnResult? {
        lock.lock(); defer { lock.unlock() }
        return outcome
    }

    /// 읽기 전용 턴에서 빼는 도구 (실측: 앞의 넷을 빼면 파일을 만들라는 요청에도 쓰지 못한다 — 하위 에이전트도, t4).
    /// `Workflow` 는 넷을 빼도 남아 승인을 묻는다 (t3) — 워크플로의 에이전트가 무엇을 쓸 수 있는지 확인하지 않았으므로 뺀다.
    /// `--permission-mode plan` 은 쓰지 않는다 — 프로젝트 밖(`~/.claude/plans`)에 계획 파일을 쓰고
    /// 응답이 "ExitPlanMode 를 쓸 수 없다"는 말로 채워진다.
    static let writeTools = ["Write", "Edit", "NotebookEdit", "Bash", "Workflow"]

    /// 사용자 메시지의 `content`. 이미지가 없으면 글 그대로, 있으면 이미지 블록(base64)들 뒤에 글 블록 — 파일이 없어진 이미지는 뺀다.
    static func messageContent(prompt: String, images: [ImageAttachment]) -> Any {
        let blocks: [[String: Any]] = images.compactMap { image in
            guard let data = ImageAttachments.base64(image) else { return nil }
            return ["type": "image", "source": ["type": "base64", "media_type": image.mediaType, "data": data]]
        }
        guard !blocks.isEmpty else { return prompt }
        return prompt.isEmpty ? blocks : blocks + [["type": "text", "text": prompt]]
    }

    /// 한 턴의 CLI 인자. 프롬프트는 stdin(stream-json)으로 가므로 위치 인자가 없다.
    static func arguments(for request: AgentTurnRequest, permissionMode: String) -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            // 우리 메시지를 처리하는 턴 안에서 되돌려 받는다 — 이어받은 세션에 남은 작업 알림의 턴이 먼저 돌면
            // 그 result 를 우리 답으로 알지 않게 (`ClaudeTurnTracker.ownTurnStarted`).
            "--replay-user-messages",
            "--permission-mode", permissionMode,
        ]
        if request.routeApprovalsToApp {
            args += ["--permission-prompt-tool", "stdio"]
        }
        if let resume = request.resumeSessionID, !resume.isEmpty {
            args += ["--resume", resume]
        } else if let newID = request.preferredNewSessionID, !newID.isEmpty {
            args += ["--session-id", newID]
        }
        if let model = request.model, !model.isEmpty {
            args += ["--model", model]
        }
        if let effort = cliEffort(request.effort, workflowsAllowed: !request.readOnly && request.outputSchema == nil) {
            args += ["--effort", effort]
        }
        if let schema = request.outputSchema, !schema.isEmpty {
            args += ["--json-schema", schema]
        }
        // `--disallowedTools` 는 뒤따르는 값을 모두 도구 이름으로 삼키는 가변 인자라 맨 끝에 둔다.
        if request.readOnly {
            args += ["--disallowedTools"] + writeTools
        }
        return args
    }

    /// 넘길 `--effort` 값. 워크플로를 쓸 수 없는 턴(읽기 전용 · 구조화 응답 — 자동 작업의 계획 · 검토, `Workflow` 를 막는다)의
    /// ULTRA(`ultracode`)는 같은 강도인 xhigh 로 — 쓰지 못할 워크플로를 쓰라는 안내가 붙지 않게. 빈 값은 넘기지 않는다.
    static func cliEffort(_ effort: String?, workflowsAllowed: Bool) -> String? {
        guard let effort, !effort.isEmpty else { return nil }
        return effort == ModelCatalog.claudeUltracode && !workflowsAllowed ? "xhigh" : effort
    }

    /// 한 번의 프로세스 실행. 결과를 반환하며 스트림을 닫지 않는다.
    private func runOnce(_ request: AgentTurnRequest) async -> AgentTurnResult {
        let args = Self.arguments(for: request, permissionMode: permissionMode)

        let p = ManagedProcess(executable: URL(fileURLWithPath: executablePath),
                               arguments: args,
                               workingDirectory: request.workingDirectory,
                               environment: environment)
        let stream = p.makeStream()
        lock.lock(); proc = p; lock.unlock()

        // 진단 — 대화에는 보이지 않고 턴 바닥글을 펼치면 보인다 (턴마다 답 위에 명령줄이 쌓이던 것).
        emit(.diagnostic("claude 실행: \(args.joined(separator: " "))"))
        p.launch()

        // 초기화 제어 요청 → 사용자 메시지.
        _ = p.writeLine(JSONUtil.line([
            "type": "control_request",
            "request_id": "init-\(UUID().uuidString)",
            "request": ["subtype": "initialize"],
        ]) ?? "")

        _ = p.writeLine(JSONUtil.line([
            "type": "user",
            "session_id": request.resumeSessionID ?? "",
            "parent_tool_use_id": NSNull(),
            "message": ["role": "user", "content": Self.messageContent(prompt: request.prompt, images: request.images)],
        ]) ?? "")

        lock.lock()
        processReady = true
        let needsInterrupt = interruptRequested && !interruptSent
        lock.unlock()
        if needsInterrupt { sendInterrupt() }

        // 트래커가 끝을 정할 때까지 읽는다 — 메인 턴의 result 뒤에도 백그라운드 작업 · 후속 턴을 기다릴 수 있다.
        for await out in stream {
            switch out {
            case .stdoutLine(let line):
                handle(line: line)
            case .stderrLine(let line):
                lock.lock(); stderrBuffer += line + "\n"; lock.unlock()
                // 진단 — 실패로 끝나면 그 원인은 결과의 오류(stderr 끝부분)로 따로 보인다.
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    emit(.diagnostic("claude stderr: \(JSONUtil.truncate(line, max: 500))"))
                }
            case .launchFailed(let m):
                setOutcome(AgentTurnResult(state: .failed, terminalReason: "launch_failed",
                                           isError: true, errorMessage: "실행 실패: \(m)",
                                           limitStatus: .unknownCause))
            case .exited(let status, let signaled):
                handleExit(status: status, signaled: signaled)
            }
            if currentOutcome() != nil { break }
        }
        if let settled = currentOutcome() { return settled }
        // 결과를 받은 뒤 종료 코드 없이 출력이 닫혔다 — 기다리는 중이면 마지막 결과로, 후속 턴 도중이면 실패로 끝낸다.
        emitOrder.lock()
        lock.lock(); let ended = tracker.processEnded(status: nil, stderr: stderrSinceMark); lock.unlock()
        perform(ended, finishNow: false)
        emitOrder.unlock()
        if let settled = currentOutcome() { return settled }
        // 스트림이 닫혔는데 결과가 없으면 미확정 종료로 마감한다.
        return AgentTurnResult(
            state: .failed, terminalReason: "stream_closed", isError: true,
            errorMessage: "출력 스트림이 결과 없이 종료되었습니다.", limitStatus: .unknownCause)
    }

    private func handleExit(status: Int32, signaled: Bool) {
        emitOrder.lock()
        lock.lock()
        let cancelled = userCancelled
        let stderrText = stderrBuffer
        // 결과를 받은 뒤의 종료: 기다리는 중이면 마지막 결과로 끝내고 (`exit_N` 실패로 만들지 않는다),
        // 후속 턴 도중이면 그 턴의 답을 받지 못했으므로 실패로 끝낸다.
        let ended = tracker.processEnded(status: status, signaled: signaled, stderr: stderrSinceMark)
        let decided = tracker.isFinished
        lock.unlock()
        perform(ended, finishNow: false)
        emitOrder.unlock()
        // 트래커가 끝을 정했다 (결과 · 기다림의 끝 · 중단).
        if decided { return }
        if cancelled {
            setOutcome(AgentTurnResult(state: .cancelled, terminalReason: "user_cancelled",
                                       isError: false))
            return
        }
        let signalNote = signaled ? ", 시그널" : ""
        let message = stderrText.isEmpty
            ? "claude 프로세스가 결과 없이 종료되었습니다 (코드 \(status)\(signalNote))"
            : stderrText
        setOutcome(AgentTurnResult(state: .failed, terminalReason: "exit_\(status)",
                                   isError: true, errorMessage: message,
                                   limitStatus: ErrorClassifier.classify(stderrText)))
    }

    // MARK: - 출력 해석

    private func handle(line: String) {
        guard let obj = JSONUtil.object(line) else { return }
        let type = obj["type"] as? String ?? ""
        switch type {
        case "system", "stream_event", "assistant", "user", "result": track(obj)
        case "control_request": handleControlRequest(obj)
        case "control_cancel_request": handleControlCancel(obj)
        case "control_response": handleControlResponse(obj)
        case "rate_limit_event": handleRateLimit(obj)
        default: break
        }
    }

    /// 트래커가 해석하는 줄 (메인 · 하위 구분, 작업, 결과와 실행의 끝). 읽기 루프에서만 부른다.
    private func track(_ obj: [String: Any]) {
        let isInit = obj["type"] as? String == "system" && obj["subtype"] as? String == "init"
        emitOrder.lock()
        lock.lock()
        let actions = tracker.handle(obj)
        var needsInterrupt = false
        if isInit {
            if obj["session_id"] is String { didEstablishSession = true }
            needsInterrupt = interruptRequested && !interruptSent
        }
        // 결과 · 후속 턴의 시작: 이 뒤의 stderr 만 다음 턴의 것이다.
        if obj["type"] as? String == "result" || actions.contains(where: Self.opensFollowUp) {
            stderrMark = stderrBuffer.utf8.count
        }
        lock.unlock()
        perform(actions, finishNow: false)
        emitOrder.unlock()
        if needsInterrupt { sendInterrupt() }
    }

    private static func opensFollowUp(_ action: ClaudeTurnTracker.Action) -> Bool {
        if case .emit(.followUpTurnStarted) = action { return true }
        return false
    }

    /// 마지막 결과 · 후속 턴 시작 뒤의 stderr. `lock` 안에서 부른다. 줄 단위로 쌓으므로 자르는 곳은 줄의 경계다.
    private var stderrSinceMark: String {
        String(decoding: stderrBuffer.utf8.dropFirst(stderrMark), as: UTF8.self)
    }

    /// 트래커가 정한 동작을 한다. `lock` 밖, `emitOrder` 안에서 부른다.
    /// `finishNow` 가 false 면 끝은 결과만 정하고 읽기 루프가 멈춘 뒤 `launchWithResumeRecovery` 가 낸다 (재개 복구 판정을
    /// 거친다). 읽기 루프 밖(중단 · 다시 보기)에서는 루프가 다음 줄을 기다리고 있으므로 곧바로 낸다 — 프로세스도 그때 끈다.
    private func perform(_ actions: [ClaudeTurnTracker.Action], finishNow: Bool) {
        for action in actions {
            switch action {
            case .emit(let event):
                emit(event)
            case .settle(let remaining):
                // 실행은 끝나지 않았다 — 프로세스를 살려 두고 계속 읽는다. 기다리는 동안 하위의 승인 요청도 받는다.
                emit(.turnSettled(remaining: remaining))
            case .recheck(let after):
                scheduleRecheck(after: after)
            case .finish(let result):
                setOutcome(result)
                if finishNow { finishOnce(result) }
            }
        }
    }

    /// 빈 목록 디바운스 · 후속 턴 안전장치. 그사이 상태가 바뀌었으면 트래커가 아무것도 하지 않는다.
    private func scheduleRecheck(after seconds: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard let self else { return }
            self.emitOrder.lock()
            self.lock.lock(); let actions = self.tracker.tick(); self.lock.unlock()
            self.perform(actions, finishNow: true)
            self.emitOrder.unlock()
        }
    }

    /// 앱이 보낸 제어 요청의 응답. 작업 멈추기 · 중단이 거절되면 안내한다 (성공은 조용히 — 결과는 task_* 로 온다).
    private func handleControlResponse(_ obj: [String: Any]) {
        guard let response = obj["response"] as? [String: Any] else { return }
        let requestID = response["request_id"] as? String ?? ""
        // 초기화 응답의 명령 · 스킬 — 입력창 "/" 목록을 따로 띄우지 않고 받아 둔다 (`SlashCommandCatalog.fetchClaude` 와 같은 응답).
        if response["subtype"] as? String == "success", requestID.hasPrefix("init-") {
            if let inner = response["response"] as? [String: Any], inner["commands"] != nil {
                emit(.slashCommands(SlashCommands.parseClaude(inner)))
            }
            return
        }
        guard response["subtype"] as? String == "error" else { return }
        let message = JSONUtil.truncate((response["error"] as? String) ?? JSONUtil.string(response), max: 400)
        if requestID.hasPrefix("stop-") {
            emit(.notice("작업 멈추기 요청이 거절되었습니다: \(message)"))
        } else if requestID.hasPrefix("interrupt-") {
            emit(.notice("중단 요청이 거절되었습니다: \(message)"))
        }
    }

    private func handleControlRequest(_ obj: [String: Any]) {
        guard let requestID = obj["request_id"] as? String,
              let request = obj["request"] as? [String: Any] else { return }
        let subtype = request["subtype"] as? String ?? ""
        guard subtype == "can_use_tool" else {
            emit(.diagnostic("처리하지 않는 제어 요청: \(subtype)"))
            return
        }
        let toolName = request["tool_name"] as? String ?? "도구"
        let displayName = request["display_name"] as? String ?? toolName
        let input = request["input"] as? [String: Any] ?? [:]
        let toolUseID = request["tool_use_id"] as? String
        let description = request["description"] as? String ?? ""

        lock.lock()
        // 트래커가 끝을 정했으면 이미 끝난 실행으로 본다.
        let stillRunning = !finishedEmitted && !tracker.isFinished
        // 백그라운드 하위 에이전트도 같은 연결로 묻는다 — 그 호출의 부모를 따라가 하위를 찾는다.
        let owner = tracker.subAgentOwner(toolUseID: toolUseID)
        if stillRunning { liveApprovals[requestID] = LiveApproval(input: input, agentID: owner?.id) }
        lock.unlock()
        guard stillRunning else { return }

        let title = "\(displayName)\(description.isEmpty ? "" : " — \(description)")"
        emit(.approvalRequested(ApprovalRequest(
            id: requestID, runID: runID, provider: .claude, kind: .tool,
            toolName: toolName,
            title: owner.map { "\($0.name): \(title)" } ?? title,
            detail: JSONUtil.truncate(JSONUtil.prettyString(input), max: 8000),
            toolUseID: toolUseID, agentID: owner?.id, input: JSONUtil.line(input))))
    }

    /// CLI 가 묻던 승인을 거둬들였다 (`control_cancel_request` — 물은 하위가 멈췄거나 턴이 중단됨). 카드를 닫는다.
    /// 늦게 온 사용자 응답은 보내지 않는다.
    private func handleControlCancel(_ obj: [String: Any]) {
        guard let requestID = obj["request_id"] as? String else { return }
        lock.lock()
        let removed = liveApprovals.removeValue(forKey: requestID) != nil
        lock.unlock()
        if removed { emit(.approvalResolved(id: requestID, decision: "취소됨 (CLI)")) }
    }

    private func handleRateLimit(_ obj: [String: Any]) {
        guard let info = obj["rate_limit_info"] as? [String: Any] else { return }
        emit(.rateLimits(Self.parseRateLimitInfo(info)))
    }

    /// `rate_limit_event` 의 `rate_limit_info` 해석 (순수 — 시험한다).
    static func parseRateLimitInfo(_ info: [String: Any], now: Date = Date()) -> LimitSnapshot {
        var snapshot = LimitSnapshot(provider: .claude)
        snapshot.fetchedAt = now
        snapshot.status = .ok

        if let unified = info["unifiedWindows"] as? [String: Any] {
            // Fable 주간 한도는 여기에 오지 않는다 (2026-09-22 실측: Fable 76% 인 주에도 five_hour · seven_day 뿐).
            // 모델 한도는 `/usage` 텍스트(`LimitsFetcher`)에서만 읽는다.
            let labels: [(String, String, Int)] = [("five_hour", "5시간", 300), ("seven_day", "7일", 10080)]
            for (key, label, span) in labels {
                guard let w = unified[key] as? [String: Any] else { continue }
                var window = LimitWindow(label: label, utilization: nil, resetsAt: nil, spanMinutes: span)
                // 값이 없으면 nil 로 두어 0% 로 표시되지 않게 한다.
                window.utilization = JSONUtil.double(w["utilization"])
                if let r = JSONUtil.double(w["resetsAt"]) {
                    window.resetsAt = Date(timeIntervalSince1970: r)
                }
                snapshot.windows.append(window)
            }
        }
        if let status = info["status"] as? String {
            snapshot.message = "CLI 보고 상태: \(status)"
            // "allowed_warning"(문턱 근처 경고)은 아직 쓸 수 있다 — 한도 도달로 읽으면 받는 쪽 후보에서 빠지고 칩이 막힌다.
            if status != "allowed" && status != "allowed_warning" { snapshot.status = .subscriptionCap }
        }
        if snapshot.windows.isEmpty {
            // 형식이 바뀌었으면 0%로 표시하지 않고 원문을 남긴다.
            snapshot.status = .noData
            snapshot.rawResponse = JSONUtil.prettyString(info)
        }
        return snapshot
    }

    /// `result` 이벤트 해석. 실측에서 확인된 판정 규칙을 순수 함수로 분리해 테스트 가능하게 한다.
    ///
    /// 규칙:
    /// - 인증 실패에도 `subtype: success` 가 나온 사례가 있으므로 `is_error`,
    ///   `terminal_reason`, 오류 메시지를 함께 본다.
    /// - 사용자 중단은 `is_error: true` 로 나오지만 모델 실패가 아니다.
    /// - 중단된 응답의 `usage = 0` 은 무사용을 보장하지 않는다 → `confirmed = false`.
    /// - `usage.input_tokens` 는 캐시 토큰을 제외한 값이므로 중복 합산하지 않는다.
    /// - `modelUsage` 에는 CLI 가 내부에서 쓴 모델(Haiku 등)도 낀다 — 대표 모델은 `representativeModel`.
    /// - `modelUsage` · `total_cost_usd` 는 프로세스 누적이다. 한 실행에 result 가 여럿이면 마지막 것 하나만 쓴다
    ///   (`ClaudeTurnTracker`).
    static func interpretResult(_ obj: [String: Any], userCancelled: Bool,
                                fallbackModel: String?, startedAt: Date,
                                preferredModel: String? = nil)
        -> (result: AgentTurnResult, notices: [String]) {

        var notices: [String] = []
        let subtype = obj["subtype"] as? String ?? ""
        let isError = obj["is_error"] as? Bool ?? false
        let terminalReason = obj["terminal_reason"] as? String
        let resultText = obj["result"] as? String
        let apiErrorStatus = obj["api_error_status"]

        var usage = TurnUsage()
        usage.durationMs = JSONUtil.int(obj["duration_ms"])
            ?? Int(Date().timeIntervalSince(startedAt) * 1000)

        var reportedCost: Double?
        var resolvedModel: String?
        if let modelUsage = obj["modelUsage"] as? [String: [String: Any]], !modelUsage.isEmpty {
            resolvedModel = representativeModel(modelUsage, preferred: preferredModel)
            for (_, mu) in modelUsage.sorted(by: { $0.key < $1.key }) {
                usage.inputTokens += JSONUtil.intValue(mu["inputTokens"])
                usage.outputTokens += JSONUtil.intValue(mu["outputTokens"])
                usage.cacheReadTokens += JSONUtil.intValue(mu["cacheReadInputTokens"])
                usage.cacheWriteTokens += JSONUtil.intValue(mu["cacheCreationInputTokens"])
                // thinkingTokens 는 outputTokens 의 부분집합이므로 총합에 더하지 않는다.
                usage.reasoningTokens += JSONUtil.intValue(mu["thinkingTokens"])
                if let c = JSONUtil.double(mu["costUSD"]) { reportedCost = (reportedCost ?? 0) + c }
            }
        } else if let u = obj["usage"] as? [String: Any] {
            // usage.input_tokens 는 캐시 토큰을 제외한 값이다 (중복 합산하지 않는다).
            usage.inputTokens = JSONUtil.intValue(u["input_tokens"])
            usage.outputTokens = JSONUtil.intValue(u["output_tokens"])
            usage.cacheReadTokens = JSONUtil.intValue(u["cache_read_input_tokens"])
            usage.cacheWriteTokens = JSONUtil.intValue(u["cache_creation_input_tokens"])
            if let d = u["output_tokens_details"] as? [String: Any] {
                usage.reasoningTokens = JSONUtil.intValue(d["thinking_tokens"])
            }
            if let c = JSONUtil.double(obj["total_cost_usd"]), c > 0 { reportedCost = c }
        }
        usage.reportedCostUSD = reportedCost
        let model = resolvedModel ?? fallbackModel
        usage.model = model

        if let denials = obj["permission_denials"] as? [[String: Any]], !denials.isEmpty {
            let names = denials.compactMap { $0["tool_name"] as? String }.joined(separator: ", ")
            notices.append("승인 거절로 실행되지 않은 도구: \(names)")
        }

        var state: RunState
        var limitStatus: LimitStatus?
        var errorMessage: String?

        let abortedReasons: Set<String> = ["aborted_streaming", "aborted", "interrupted",
                                           "user_abort", "cancelled"]
        if userCancelled || abortedReasons.contains(terminalReason ?? "") {
            // 사용자 취소를 모델 실패로 집계하지 않는다.
            state = .cancelled
            usage.confirmed = false
        } else if isError || subtype.hasPrefix("error") {
            let raw = [resultText, apiErrorStatus.map { String(describing: $0) }, terminalReason]
                .compactMap { $0 }.joined(separator: " | ")
            let classification = ErrorClassifier.classify(raw)
            limitStatus = classification
            errorMessage = resultText ?? "실행이 오류로 종료되었습니다. (\(subtype))"
            state = classification == .subscriptionCap ? .rateLimited : .failed
        } else if let failure = cliFailureInSuccess(
            resultText,
            // 이 턴의 출력 — `modelUsage` 는 프로세스 누적이라 후속 턴이면 앞 턴의 출력이 섞인다. 턴별 `usage` 가 있으면 그것.
            outputTokens: (obj["usage"] as? [String: Any]).map { JSONUtil.intValue($0["output_tokens"]) } ?? usage.outputTokens) {
            limitStatus = failure
            errorMessage = resultText
            state = failure == .subscriptionCap ? .rateLimited : .failed
        } else {
            state = .completed
        }

        var result = AgentTurnResult(
            state: state, terminalReason: terminalReason ?? subtype,
            isError: state == .failed || state == .rateLimited, errorMessage: errorMessage,
            model: model, sessionID: obj["session_id"] as? String, resultText: resultText,
            usage: usage, limitStatus: limitStatus)
        // `--json-schema` 를 준 턴에만 온다 (객체). 받는 쪽이 다시 해석하도록 JSON 글로 넘긴다.
        if let structured = obj["structured_output"], !(structured is NSNull) {
            result.structuredOutput = JSONUtil.string(structured)
        }
        return (result, notices)
    }

    /// `subtype: success` · `is_error: false` 인데 실제로는 CLI 가 낸 인증 · 한도 오류인지 (실측: "Error: Not logged in. …").
    /// 모델이 쓴 답은 로그인 · 401 · 한도를 이야기해도 실패가 아니다 — 그래서 모델이 글을 쓰지 않았고(출력 토큰 0)
    /// 글이 짧을 때만 본다. 모델 답을 실패로 보면 대기열이 멈추고 자동 인계가 한도가 남은 채 시작된다.
    static func cliFailureInSuccess(_ text: String?, outputTokens: Int) -> LimitStatus? {
        guard outputTokens == 0,
              let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 400 else { return nil }
        // API 키로 실행할 때 CLI 가 모델 없이 내는 글 — 크레딧이 떨어짐 · 키가 맞지 않음. 성공으로 보면 대기열이 이어서 보낸다.
        if ClaudeAPIKey.isCreditExhausted(text) { return .unknownCause }
        if ClaudeAPIKey.isInvalidKey(text) { return .authProblem }
        let classification = ErrorClassifier.classify(text)
        return classification == .authProblem || classification == .subscriptionCap ? classification : nil
    }

    /// `modelUsage` 의 대표 모델: `preferred`(init 의 모델)가 키에 있으면 그것, 아니면 출력 토큰이 가장 많은 키
    /// (같으면 이름순). 알파벳순 첫 키를 쓰면 CLI 가 내부에서 쓴 `claude-haiku-…` 가 대표가 된다 (실측 t1~t8).
    static func representativeModel(_ modelUsage: [String: [String: Any]], preferred: String?) -> String? {
        if let preferred, modelUsage[preferred] != nil { return preferred }
        return modelUsage
            .map { (name: $0.key, output: JSONUtil.intValue($0.value["outputTokens"])) }
            .sorted { $0.output != $1.output ? $0.output > $1.output : $0.name < $1.name }
            .first?.name
    }

    private func finishOnce(_ result: AgentTurnResult) {
        lock.lock()
        guard !finishedEmitted else { lock.unlock(); return }
        finishedEmitted = true
        liveApprovals.removeAll()
        liveQuestions.removeAll()
        let c = continuation
        lock.unlock()
        c?.yield(.finished(result))
        c?.finish()
        Task { _ = await self.shutdown() }
    }

    // MARK: - 승인 / 중단

    func respond(approvalID: String, decision: ApprovalDecision) async {
        lock.lock()
        // 종료된 실행의 늦은 응답은 적용하지 않는다.
        guard !finishedEmitted, let originalInput = liveApprovals[approvalID]?.input else {
            lock.unlock()
            return
        }
        liveApprovals.removeValue(forKey: approvalID)
        let p = proc
        lock.unlock()

        let inner = Self.permissionResponse(decision, originalInput: originalInput)
        let payload: [String: Any] = [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": approvalID, "response": inner],
        ]
        if let line = JSONUtil.line(payload) { _ = p?.writeLine(line) }
        emit(.approvalResolved(id: approvalID, decision: decision.koreanName))

        if case .denyAndCancel = decision { await requestInterrupt() }
    }

    /// `can_use_tool` 에 돌려줄 결정 (순수 — 시험한다). 허용은 원래 입력 그대로, 거절은 글(없으면 앱의 기본 문장)과 함께.
    /// 질문(`AskUserQuestion`)에 적은 답은 확인된 길 — 거절의 글 자리 — 로 보낸다: Claude 는 그 글을 그 도구의 결과로 받는다
    /// (고른 답을 `updatedInput` 으로 돌려주는 길은 실측 전).
    static func permissionResponse(_ decision: ApprovalDecision, originalInput: [String: Any]) -> [String: Any] {
        switch decision {
        case .allow, .allowForSession, .submit:
            return ["behavior": "allow", "updatedInput": originalInput]
        case .deny(let message), .answer(let message):
            return ["behavior": "deny", "message": message.isEmpty ? "사용자가 거절했습니다." : message]
        case .denyAndCancel(let message):
            return ["behavior": "deny", "message": message.isEmpty ? "사용자가 거절하고 중단했습니다." : message, "interrupt": true]
        }
    }

    func respond(questionID: String, answers: [String: String]) async {
        // Claude 는 현재 검증 범위에서 별도 질문 제어 요청을 사용하지 않는다.
        _ = questionID; _ = answers
    }

    func requestInterrupt() async {
        emitOrder.lock()
        lock.lock()
        interruptRequested = true
        userCancelled = true
        // 기다리는 중이고 남은 작업이 없으면 곧바로 끝낸다. 남은 작업이 있으면 interrupt 로 모두 멈추고
        // 목록이 비면 끝난다 (실측: 이때 CLI 는 result 를 내지 않는다). 메인 턴이 도는 중이면 지금처럼.
        let actions = tracker.interrupt()
        let decided = tracker.isFinished
        let ready = processReady
        let already = interruptSent
        lock.unlock()
        perform(actions, finishNow: true)
        emitOrder.unlock()
        // 끝내면서 프로세스를 끈다 — 하위 · 셸도 함께 끝난다.
        if decided { return }
        // 시작 중이라면 프로세스가 준비되는 즉시 전송된다 (요청을 유실하지 않는다).
        if ready && !already { sendInterrupt() }
    }

    /// 작업 하나만 멈춘다 (`stop_task`). 그 작업만 멈추고 실행은 계속된다 — 결과는 `task_*` 로 온다.
    /// 하위가 띄운 셸을 멈추면 그 하위가 깨어나 이어 갈 수 있다 (t5). 보냈으면 true.
    /// 그 하위가 묻던 승인은 거절로 답하고 카드를 닫는다 — 멈추기가 거절돼도 하위가 답을 기다리며 서 있지 않게.
    func stopSubAgent(id: String) async -> Bool {
        lock.lock()
        let taskID = finishedEmitted || tracker.isFinished ? nil : tracker.stoppableTaskID(forAgent: id)
        let p = proc
        var orphaned: [String] = []
        if taskID != nil, p != nil {
            orphaned = liveApprovals.filter { $0.value.agentID == id }.map(\.key).sorted()
            for approvalID in orphaned { liveApprovals.removeValue(forKey: approvalID) }
        }
        lock.unlock()
        guard let taskID, let p else { return false }
        for approvalID in orphaned {
            let deny: [String: Any] = [
                "type": "control_response",
                "response": ["subtype": "success", "request_id": approvalID,
                             "response": ["behavior": "deny", "message": "사용자가 이 작업을 멈췄습니다."]],
            ]
            if let line = JSONUtil.line(deny) { _ = p.writeLine(line) }
            emit(.approvalResolved(id: approvalID, decision: "거절 (작업 멈춤)"))
        }
        let payload: [String: Any] = [
            "type": "control_request",
            "request_id": "stop-\(UUID().uuidString)",
            "request": ["subtype": "stop_task", "task_id": taskID],
        ]
        guard let line = JSONUtil.line(payload) else { return false }
        return p.writeLine(line)
    }

    private func sendInterrupt() {
        lock.lock()
        guard !interruptSent, let p = proc else { lock.unlock(); return }
        interruptSent = true
        lock.unlock()
        let payload: [String: Any] = [
            "type": "control_request",
            "request_id": "interrupt-\(UUID().uuidString)",
            "request": ["subtype": "interrupt"],
        ]
        if let line = JSONUtil.line(payload) { _ = p.writeLine(line) }
        emit(.diagnostic("중단 요청을 보냈습니다."))

        // 응답이 없으면 프로세스를 정리한다 (기다리는 중 목록이 비지 않을 때의 안전망이기도 하다).
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self else { return }
            self.lock.lock(); let done = self.finishedEmitted || self.tracker.isFinished; self.lock.unlock()
            if !done {
                _ = await self.shutdown()
                // 받은 결과가 있으면 그 사용량을 싣는다. 끝은 읽기 루프가 종료를 받고 낸다.
                self.emitOrder.lock()
                self.lock.lock()
                let actions = self.tracker.cancel(reason: "interrupt_timeout_killed")
                self.lock.unlock()
                self.perform(actions, finishNow: false)
                self.emitOrder.unlock()
            }
        }
    }

    func shutdown() async -> Bool {
        lock.lock(); let p = proc; lock.unlock()
        guard let p else { return true }
        return await p.shutdown()
    }
}
