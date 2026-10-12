import Foundation

/// Codex CLI 어댑터 (`codex app-server --stdio`, JSON-RPC over stdio).
///
/// 흐름: initialize → initialized → thread/start | thread/resume → turn/start
///       → 알림 소비 → turn/completed
/// 서버가 보내는 요청(method + id)은 승인/입력 요청이며 반드시 응답해야 한다.
/// 하위 에이전트 스레드의 알림도 같은 연결로 온다 — 메인 · 하위 구분과 실행의 끝(백그라운드 작업 기다리기)은
/// `CodexTurnTracker` 가 정하고, 이 어댑터는 그 동작대로 내고 · 기다리고 · 넣고 · 끝낸다.
///
/// 검증 환경: codex-cli 0.153.4 (2026-09-09). 하위 에이전트 · 백그라운드 명령은 0.154.0 (2026-09-23).
final class CodexAdapter: AgentAdapter, @unchecked Sendable {
    let provider: AgentProvider = .codex

    private let executablePath: String
    private let environment: [String: String]
    private let sandboxMode: String       // read-only | workspace-write | danger-full-access
    private let approvalPolicy: String    // untrusted | on-request | never
    /// 스레드에 넘기는 개발자 지시 (`toolUseInstruction`). 계정의 config.toml 에 사용자가 직접 둔
    /// `developer_instructions` 가 있으면 nil — 그것을 덮지 않는다.
    private let developerInstructions: String?

    private let lock = UnfairLock()
    /// 트래커의 판정과 그 동작을 내는 순서를 맞춘다. 읽기 루프와 중단(다른 스레드)이 각자 잠금 안에서 판정하고
    /// 잠금 밖에서 내면, 나중에 판정한 묶음(끝)이 먼저 나가 앞선 묶음이 버려지거나 뒤집힌다.
    /// 판정 전에 잡고 `perform` 이 돌아올 때까지 쥔다. 항상 `lock` 보다 먼저 잡는다 — `perform` 은 주입 RPC 를
    /// 따로 돌리고 곧바로 돌아오므로 RPC 를 기다리는 동안 쥐지 않는다. 재진입 불가 (`perform` 안에서 잡지 않는다).
    private let emitOrder = UnfairLock()
    /// 넣기(`thread/inject_items`)와 그 뒤의 끝. 끝나면 스스로 비운다. `requestInterrupt` 가 비워질 때까지 기다린 뒤
    /// 돌아온다 — 앱 종료는 그 뒤에 곧바로 app-server 를 끈다(`RunSession.shutdownForQuit`). `lock` 안에서 읽고 쓴다.
    private var pendingInjection: Task<Void, Never>?
    private var proc: ManagedProcess?
    private var continuation: AsyncStream<AgentEvent>.Continuation?
    private var runID = ""
    private var startedAt = Date()

    private var nextRequestID = 0
    private var pendingRPC: [Int: (String, CheckedContinuation<Result<[String: Any], Error>, Never>)] = [:]
    private var finishedEmitted = false
    private var interruptRequested = false
    private var interruptSent = false
    private var userCancelled = false
    private var stderrBuffer = ""

    /// 서버 요청 ID → 요청 종류. 늦은 응답 무효화를 위해 종료 시 비운다.
    private var liveServerRequests: [String: (method: String, params: [String: Any])] = [:]
    /// itemId → item 스냅샷. 승인 요청에 상세 정보를 붙이기 위해 보관한다.
    private var itemSnapshots: [String: [String: Any]] = [:]

    /// 메인 · 하위 스레드 구분과 실행의 끝 판정. 메인 스레드 · 메인 턴 · 모델 · 메인의 글 · 스레드별 사용량을 가진다.
    /// 값 형식이라 잠금 안에서 바꾸고, 돌려받은 동작은 잠금 밖에서 한다 (`perform`).
    private var tracker = CodexTurnTracker(waitForBackground: false)

    /// `thread/inject_items` 응답 제한. 모델 호출이 없어 곧바로 답한다 (c17: 10ms).
    private static let injectTimeout: TimeInterval = 20
    /// 사람이 멈출 때(앱 종료 포함)의 제한 — `requestInterrupt` 가 넣기를 기다리므로 짧게 둔다.
    /// 이미 도는 넣기(제한 `injectTimeout`)도 이만큼만 기다린다.
    private static let interruptInjectTimeout: TimeInterval = 5

    init(executablePath: String, environment: [String: String],
         sandboxMode: String = "workspace-write", approvalPolicy: String = "on-request") {
        self.executablePath = executablePath
        self.environment = environment
        self.sandboxMode = sandboxMode
        self.approvalPolicy = approvalPolicy
        let home = environment["CODEX_HOME"] ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
        let config = try? String(contentsOfFile: (home as NSString).appendingPathComponent("config.toml"), encoding: .utf8)
        self.developerInstructions = Self.configDefinesDeveloperInstructions(config ?? "") ? nil : Self.toolUseInstruction
    }

    /// `gpt-6-luna` 를 low 로 쓰면 한국어 요청에서 셸 도구를 쓰지 않고 "파일을 찾을 수 없습니다" · "이 환경에서는 읽을 수 없습니다"라고
    /// 답하곤 했다 — 읽지도 않고 "읽어 확인했습니다"라고 지어낸 적도 있다 (2026-09-30 실측: Codex 자체의 `codex exec` 에서도 0/5,
    /// 같은 요청을 영어로 · gpt-5.6-luna 로는 성공). 이 한 줄을 개발자 지시로 주면 5/5. 모델 동작이지만, 사람이
    /// 고른 강도에서 앱이 틀린 답을 내면 안 되므로 앱이 막는다.
    static let toolUseInstruction = "You can read files and run commands in the workspace with your shell tool. "
        + "Never say you cannot see, find, or access a file before checking it with a command."

    /// config.toml 에 `developer_instructions` 키가 있는가 (어느 표든) — 있으면 사용자의 것이라 앱의 지시로 덮지 않는다.
    static func configDefinesDeveloperInstructions(_ toml: String) -> Bool {
        toml.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("developer_instructions") && trimmed.dropFirst("developer_instructions".count)
                .trimmingCharacters(in: .whitespaces).hasPrefix("=")
        }
    }

    var currentPID: Int32? {
        lock.lock(); defer { lock.unlock() }
        guard let p = proc, p.isRunning else { return nil }
        return p.processIdentifier
    }

    /// 지금까지 받은 전 스레드 사용량 (미확정 `confirmed = false`). 받은 것이 없으면 nil.
    /// `finished` 없이 끝날 때(앱 종료) 실행이 그때까지의 사용량을 남긴다.
    var lastKnownUsage: TurnUsage? {
        lock.lock(); defer { lock.unlock() }
        return tracker.knownUsage()
    }

    // MARK: - 시작

    func start(_ request: AgentTurnRequest) -> AsyncStream<AgentEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { cont in
            self.lock.lock()
            self.continuation = cont
            self.runID = request.runID
            self.startedAt = Date()
            self.tracker = CodexTurnTracker(waitForBackground: request.waitForBackground,
                                            startedAt: self.startedAt)
            self.lock.unlock()
            Task { await self.run(request) }
        }
    }

    private func emit(_ e: AgentEvent) {
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(e)
    }

    private func run(_ request: AgentTurnRequest) async {
        // 스키마를 달라고 했는데 넘길 수 없으면 스키마 없이 돌리지 않는다. 프로세스를 띄우기 전에 끝낸다.
        if let schema = request.outputSchema, !schema.isEmpty {
            guard Self.schemaObject(schema) != nil else {
                finishOnce(AgentTurnResult(state: .failed, terminalReason: "invalid_output_schema", isError: true,
                                           errorMessage: "출력 스키마가 JSON 객체가 아닙니다."))
                return
            }
            lock.lock(); tracker.wantsStructuredOutput = true; lock.unlock()
        }
        let p = ManagedProcess(executable: URL(fileURLWithPath: executablePath),
                               arguments: ["app-server", "--stdio"],
                               workingDirectory: request.workingDirectory,
                               environment: environment)
        let stream = p.makeStream()
        lock.lock(); proc = p; lock.unlock()
        // 진단 — 대화에는 보이지 않고 턴 바닥글을 펼치면 보인다.
        emit(.diagnostic("codex app-server 시작"))
        p.launch()

        // 출력 소비 루프를 먼저 띄운다.
        let reader = Task { [weak self] in
            guard let self else { return }
            for await out in stream {
                switch out {
                case .stdoutLine(let line): self.handle(line: line)
                case .stderrLine(let line):
                    self.lock.lock(); self.stderrBuffer += line + "\n"; self.lock.unlock()
                case .launchFailed(let m):
                    self.finishOnce(AgentTurnResult(state: .failed, terminalReason: "launch_failed",
                                                    isError: true, errorMessage: "실행 실패: \(m)"))
                case .exited(let status, let signaled):
                    self.handleExit(status: status, signaled: signaled)
                }
            }
        }

        do {
            _ = try await rpc("initialize", [
                "clientInfo": ["name": "AgentHandoffConsole", "version": "0.1.0",
                               "title": "Agent Handoff Console"],
            ])
            notify("initialized", [:])

            // 세션 시작 또는 재개.
            var established: String?
            if let resume = request.resumeSessionID, !resume.isEmpty {
                do {
                    let resumeParams = Self.threadParams(for: request, sandboxMode: sandboxMode,
                                                         approvalPolicy: approvalPolicy, resume: resume,
                                                         developerInstructions: developerInstructions)
                    let result = try await rpc("thread/resume", resumeParams)
                    let thread = result["thread"] as? [String: Any]
                    established = (thread?["id"] as? String) ?? resume
                    if let m = (result["model"] as? String) ?? (thread?["model"] as? String) {
                        lock.lock(); tracker.setModel(m); lock.unlock()
                    }
                } catch {
                    if request.strictResume {
                        // 다른 계정으로 대화의 세션을 이어 가는 실행 — 새 세션으로 넘어가지 않는다 (그 계정이 맥락 없이 시작하고 대화의
                        // 세션 연결이 바뀐다). 세션은 그대로 두고 실패로 끝낸다 (`resume_failed` — `setup_failed` 와 달리 재개를 끄지 않는다).
                        finishOnce(AgentTurnResult(
                            state: .failed, terminalReason: "resume_failed", isError: true,
                            errorMessage: "이 대화의 Codex 세션을 이 계정으로 이어 가지 못했습니다 (\(error.localizedDescription)). "
                                + "세션 연결은 그대로 두었습니다 — 세션을 시작한 계정으로 되돌리면 이어 갈 수 있습니다."))
                        reader.cancel()
                        return
                    }
                    // 재개 불가 → 새 세션으로 복구한다. 파일의 실제 상태가 우선이다.
                    emit(.notice("기존 Codex 세션 재개 실패(\(error.localizedDescription)). 새 세션으로 복구합니다."))
                    established = nil
                }
            }
            if established == nil {
                let params = Self.threadParams(for: request, sandboxMode: sandboxMode,
                                               approvalPolicy: approvalPolicy, resume: nil,
                                               developerInstructions: developerInstructions)
                let result = try await rpc("thread/start", params)
                let thread = result["thread"] as? [String: Any]
                established = thread?["id"] as? String
                if let m = (result["model"] as? String) ?? (thread?["model"] as? String) {
                    lock.lock(); tracker.setModel(m); lock.unlock()
                }
            }
            guard let tid = established else {
                throw NSError(domain: "Codex", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Codex 대화 ID(thread id)를 받지 못했습니다. 다시 보내 보세요."])
            }
            lock.lock(); tracker.setMainThread(tid); let m = tracker.model; lock.unlock()
            emit(.sessionEstablished(sessionID: tid, model: m, cliVersion: nil))

            // 시작 중 중단 요청이 들어왔다면 턴을 시작하지 않는다.
            lock.lock(); let cancelBeforeTurn = interruptRequested; lock.unlock()
            if cancelBeforeTurn {
                finishOnce(AgentTurnResult(state: .cancelled,
                                           terminalReason: "cancelled_before_turn",
                                           isError: false, sessionID: tid))
                reader.cancel()
                return
            }

            let turnParams = Self.turnParams(for: request, threadID: tid)
            let turnResult = try await rpc("turn/start", turnParams)
            if let turn = turnResult["turn"] as? [String: Any], let turnID = turn["id"] as? String {
                lock.lock()
                tracker.mainTurnStarted(turnID)
                let needsInterrupt = interruptRequested && !interruptSent
                lock.unlock()
                // 응답만으로는 아직 중단할 수 없다 ("no active turn to interrupt"). `sendInterruptWhenActive` 가
                // 메인의 turn/started 알림(`interruptTarget`)을 기다렸다 보낸다.
                if needsInterrupt { Task { await self.sendInterruptWhenActive() } }
            }
        } catch {
            lock.lock(); let err = stderrBuffer; lock.unlock()
            let raw = "\(error.localizedDescription)\n\(err)"
            finishOnce(AgentTurnResult(
                state: ErrorClassifier.classify(raw) == .subscriptionCap ? .rateLimited : .failed,
                terminalReason: "setup_failed", isError: true,
                errorMessage: error.localizedDescription,
                limitStatus: ErrorClassifier.classify(raw)))
            reader.cancel()
            return
        }

        await reader.value
        streamClosed()
    }

    /// 출력이 닫힌 뒤. 백그라운드 작업을 기다리던 중이면 메인 턴의 결과로 끝낸다.
    private func streamClosed() {
        emitOrder.lock(); defer { emitOrder.unlock() }
        lock.lock(); let ended = tracker.processEnded(); let decided = tracker.isFinished; lock.unlock()
        if !ended.isEmpty { perform(ended); return }
        // 트래커가 이미 결과를 냈다 (하위의 답을 넣는 중이면 그 길이 끝낸다).
        if decided { return }
        finishOnce(AgentTurnResult(state: .failed, terminalReason: "stream_closed", isError: true,
                                   errorMessage: "codex 출력이 결과 없이 종료되었습니다."))
    }

    private func handleExit(status: Int32, signaled: Bool) {
        emitOrder.lock(); defer { emitOrder.unlock() }
        lock.lock()
        let cancelled = userCancelled
        let err = stderrBuffer
        // 대기 중인 RPC 를 모두 실패 처리해 교착을 막는다.
        let pending = pendingRPC
        pendingRPC.removeAll()
        // 백그라운드 작업을 기다리던 중이면 메인 턴의 결과로 끝낸다 (`exit_N` 실패로 만들지 않는다).
        let ended = tracker.processEnded()
        let decided = tracker.isFinished
        lock.unlock()
        for (_, entry) in pending {
            entry.1.resume(returning: .failure(NSError(
                domain: "Codex", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "app-server 종료 (코드 \(status))"])))
        }
        if !ended.isEmpty { perform(ended); return }
        // 트래커가 이미 결과를 냈다 (하위의 답을 넣는 중이면 그 길이 끝낸다).
        if decided { return }
        if cancelled {
            finishOnce(AgentTurnResult(state: .cancelled, terminalReason: "user_cancelled",
                                       isError: false))
            return
        }
        let signalNote = signaled ? ", 시그널" : ""
        let exitMessage = "codex app-server 가 종료되었습니다 (코드 \(status)\(signalNote))"
        finishOnce(AgentTurnResult(
            state: .failed, terminalReason: "exit_\(status)", isError: true,
            errorMessage: err.isEmpty ? exitMessage : err,
            limitStatus: ErrorClassifier.classify(err)))
    }

    // MARK: - JSON-RPC

    private func notify(_ method: String, _ params: [String: Any]) {
        lock.lock(); let p = proc; lock.unlock()
        if let line = JSONUtil.line(["method": method, "params": params]) { _ = p?.writeLine(line) }
    }

    @discardableResult
    private func rpc(_ method: String, _ params: [String: Any],
                     timeout: TimeInterval = 180) async throws -> [String: Any] {
        lock.lock()
        nextRequestID += 1
        let id = nextRequestID
        let p = proc
        lock.unlock()

        guard let line = JSONUtil.line(["method": method, "params": params, "id": id]) else {
            throw NSError(domain: "Codex", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "요청 직렬화 실패: \(method)"])
        }

        let responseTask = Task { () -> Result<[String: Any], Error> in
            await withCheckedContinuation { cont in
                self.lock.lock()
                self.pendingRPC[id] = (method, cont)
                self.lock.unlock()
                guard p?.writeLine(line) == true else {
                    self.lock.lock()
                    let entry = self.pendingRPC.removeValue(forKey: id)
                    self.lock.unlock()
                    entry?.1.resume(returning: .failure(NSError(
                        domain: "Codex", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "stdin 쓰기 실패: \(method)"])))
                    return
                }
            }
        }

        let timeoutTask = Task { () -> Result<[String: Any], Error> in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.lock.lock()
            let entry = self.pendingRPC.removeValue(forKey: id)
            self.lock.unlock()
            if let entry {
                entry.1.resume(returning: .failure(NSError(
                    domain: "Codex", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "\(method) 응답 시간 초과"])))
            }
            return .failure(NSError(domain: "Codex", code: -3,
                                    userInfo: [NSLocalizedDescriptionKey: "\(method) 응답 시간 초과"]))
        }

        let result = await responseTask.value
        timeoutTask.cancel()
        switch result {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }

    // MARK: - 수신 처리

    private func handle(line: String) {
        guard let obj = JSONUtil.object(line) else { return }

        // 1) 우리 요청에 대한 응답 (method 없음 + id 있음)
        if obj["method"] == nil, let idValue = obj["id"] {
            let id = (idValue as? Int) ?? (idValue as? NSNumber)?.intValue ?? -1
            lock.lock(); let entry = pendingRPC.removeValue(forKey: id); lock.unlock()
            guard let entry else { return }
            if let err = obj["error"] as? [String: Any] {
                let message = err["message"] as? String ?? "알 수 없는 오류"
                entry.1.resume(returning: .failure(NSError(
                    domain: "Codex", code: (err["code"] as? Int) ?? -1,
                    userInfo: [NSLocalizedDescriptionKey: message])))
            } else {
                entry.1.resume(returning: .success(obj["result"] as? [String: Any] ?? [:]))
            }
            return
        }

        // 2) 서버 → 클라이언트 요청 (method + id)
        if let method = obj["method"] as? String, let idValue = obj["id"] {
            handleServerRequest(method: method, id: idValue,
                                params: obj["params"] as? [String: Any] ?? [:])
            return
        }

        // 3) 알림
        if let method = obj["method"] as? String {
            handleNotification(method: method, params: obj["params"] as? [String: Any] ?? [:])
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        emitOrder.lock()
        lock.lock()
        if method == "item/started" || method == "item/updated" || method == "item/completed",
           let item = params["item"] as? [String: Any], let id = item["id"] as? String {
            itemSnapshots[id] = item
        }
        let actions = tracker.handle(method: method, params: params)
        // 먼저 들어온 중단은 메인의 turn/started 알림으로 턴을 확인한 뒤에 보낸다 ("no active turn to interrupt").
        let needsInterrupt = method == "turn/started" && tracker.isMain(threadID: params["threadId"] as? String)
            && tracker.interruptTarget != nil && interruptRequested && !interruptSent
        lock.unlock()
        perform(actions)
        emitOrder.unlock()
        if needsInterrupt { Task { await self.sendInterruptWhenActive() } }
    }

    /// 트래커가 정한 동작을 한다. `lock` 밖, `emitOrder` 안에서 부른다.
    /// 주입은 RPC 응답을 이 읽기 루프가 받아야 하므로 따로 돌리고, 그 뒤의 동작(끝)은 주입이 끝난 뒤에 한다.
    /// 그 작업은 `pendingInjection` 에 둔다 (`requestInterrupt` 가 기다린다).
    private func perform(_ actions: [CodexTurnTracker.Action],
                         injectTimeout: TimeInterval = CodexAdapter.injectTimeout) {
        for (index, action) in actions.enumerated() {
            switch action {
            case .emit(let event):
                emit(event)
            case .settle(let remaining):
                // 실행은 끝나지 않았다 — 스트림 · 프로세스를 살려 두고, 기다리는 동안 하위의 승인 요청도 받는다.
                emit(.turnSettled(remaining: remaining))
            case .inject(let items):
                let rest = Array(actions[(index + 1)...])
                let task = Task {
                    await self.inject(items, timeout: injectTimeout)
                    self.emitOrder.lock()
                    self.perform(rest)
                    self.emitOrder.unlock()
                    // 여기까지 오면 아래의 대입은 끝나 있다 — 부른 쪽이 쥔 `emitOrder` 를 위에서 기다렸다.
                    self.lock.lock(); self.pendingInjection = nil; self.lock.unlock()
                }
                lock.lock(); pendingInjection = task; lock.unlock()
                return
            case .finish(let result):
                finishOnce(result)
            }
        }
    }

    /// 메인 턴이 끝난 뒤에 끝난 하위의 답 · 백그라운드 명령의 결과를 메인 기록에 넣는다 (턴도 모델 호출도 없다 — c17).
    /// 넣었으면 하나마다 안내를 남긴다. 넣지 못해도 실행은 끝낸다.
    private func inject(_ items: [CodexTurnTracker.Injection], timeout: TimeInterval) async {
        lock.lock(); let tid = tracker.mainThreadID; lock.unlock()
        guard let tid, !items.isEmpty else { return }
        let messages: [[String: Any]] = items.map {
            ["type": "message", "role": $0.role, "content": [["type": "input_text", "text": $0.text]]]
        }
        do {
            _ = try await rpc("thread/inject_items", ["threadId": tid, "items": messages], timeout: timeout)
            for item in items { emit(.notice(item.notice)) }
        } catch {
            emit(.notice("백그라운드 작업의 결과를 대화 기록에 넣지 못했습니다(\(error.localizedDescription)). "
                         + "다음 턴의 모델은 이 결과를 모를 수 있습니다."))
        }
    }

    // MARK: - 요청 매개변수 (순수 함수 — fixture 로 검증한다)

    /// 읽기 전용 턴의 승인 정책. 승인을 물으면 사람이 샌드박스 밖 실행을 허락할 수 있으므로 묻지 않게 한다.
    static let readOnlyApprovalPolicy = "never"

    /// `thread/start` · `thread/resume` 매개변수. `resume` 이 있으면 재개다.
    ///
    /// 읽기 전용 턴은 여기서도 읽기 전용으로 연다. 턴 단위 덮어쓰기(`turnParams`)는 같은 프로세스의
    /// 이후 턴에도 남지만(실측), 앱은 턴마다 app-server 를 새로 띄우고 여기서 샌드박스를 다시 넘기므로
    /// 읽기 전용 턴 뒤에 같은 스레드를 재개한 쓰기 턴은 정상적으로 쓴다(실측).
    static func threadParams(for request: AgentTurnRequest, sandboxMode: String,
                             approvalPolicy: String, resume: String?,
                             developerInstructions: String? = nil) -> [String: Any] {
        var params: [String: Any] = [
            "cwd": request.workingDirectory.path,
            "sandbox": request.readOnly ? "read-only" : sandboxMode,
            "approvalPolicy": request.readOnly ? readOnlyApprovalPolicy : approvalPolicy,
        ]
        if let resume {
            params["threadId"] = resume
            params["excludeTurns"] = true
        }
        if let m = request.model, !m.isEmpty { params["model"] = m }
        if let developerInstructions { params["developerInstructions"] = developerInstructions }
        return params
    }

    /// `turn/start` 매개변수.
    static func turnParams(for request: AgentTurnRequest, threadID: String) -> [String: Any] {
        // 붙인 이미지는 파일 경로로 (`localImage` — app-server 가 읽는다). 글이 없으면 이미지만.
        var input: [[String: Any]] = request.prompt.isEmpty && !request.images.isEmpty
            ? [] : [["type": "text", "text": request.prompt]]
        input += request.images.map { ["type": "localImage", "path": $0.path] }
        // 글 속 "$이름" 으로 부른 스킬 — Codex TUI 처럼 글은 그대로 두고 스킬 입력을 덧붙인다 (`SlashCommands.codexMentions`).
        input += request.skills.map { ["type": "skill", "name": $0.name, "path": $0.path] }
        var params: [String: Any] = [
            "threadId": threadID,
            "input": input,
        ]
        if let m = request.model, !m.isEmpty { params["model"] = m }
        if let e = request.effort, !e.isEmpty { params["effort"] = e }
        if request.readOnly {
            params["sandboxPolicy"] = ["type": "readOnly"]
            params["approvalPolicy"] = readOnlyApprovalPolicy
        }
        if let schema = schemaObject(request.outputSchema) { params["outputSchema"] = schema }
        return params
    }

    /// 출력 스키마(JSON 글)를 객체로. 스키마를 주지 않았거나 JSON 객체가 아니면 nil.
    static func schemaObject(_ schema: String?) -> [String: Any]? {
        guard let schema, !schema.isEmpty, let data = schema.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `turn/completed` 해석. 순수 함수로 분리해 fixture 로 검증한다.
    ///
    /// - `interrupted` 는 사용자 취소이며 모델 실패가 아니다.
    /// - 중단 시 사용량은 0 이어도 미확정(`confirmed = false`)으로 둔다.
    /// Codex `TurnError.codexErrorInfo` → 한도 상태. 문자열 꼴(`usageLimitExceeded` …)과 객체 꼴(`{"httpConnectionFailed": …}`)이 있다.
    /// 모르는 값이면 nil — 글로 가른다 (`ErrorClassifier.classify`).
    static func classification(codexErrorInfo value: Any?) -> LimitStatus? {
        if let name = value as? String {
            switch name {
            case "usageLimitExceeded": return .subscriptionCap
            case "rateLimitExceeded", "serverOverloaded": return .throttled
            case "unauthorized": return .authProblem
            case "internalServerError": return .networkError
            default: return nil
            }
        }
        if let object = value as? [String: Any],
           object.keys.contains(where: { $0.hasSuffix("ConnectionFailed") || $0.hasPrefix("httpConnection") }) {
            return .networkError
        }
        return nil
    }

    static func interpretTurnCompleted(turn: [String: Any], usage baseUsage: TurnUsage,
                                       model: String?, threadID: String?, accumulatedText: String,
                                       userCancelled: Bool, sawAnyUsage: Bool,
                                       startedAt: Date) -> AgentTurnResult {
        let status = turn["status"] as? String ?? "unknown"
        var usage = baseUsage
        usage.model = model
        usage.durationMs = JSONUtil.int(turn["durationMs"])
            ?? Int(Date().timeIntervalSince(startedAt) * 1000)

        var state: RunState
        var errorMessage: String?
        var limitStatus: LimitStatus?

        switch status {
        case "completed":
            state = .completed
        case "interrupted":
            state = .cancelled
            usage.confirmed = false
        case "failed", "error":
            let raw = (turn["error"] as? [String: Any]).map { JSONUtil.string($0) }
                ?? JSONUtil.string(turn)
            let classification = Self.classification(codexErrorInfo: (turn["error"] as? [String: Any])?["codexErrorInfo"])
                ?? ErrorClassifier.classify(raw)
            limitStatus = classification
            errorMessage = ((turn["error"] as? [String: Any])?["message"] as? String) ?? raw
            state = classification == .subscriptionCap ? .rateLimited : .failed
        default:
            state = userCancelled ? .cancelled : .completed
        }
        if userCancelled && state == .completed { state = .cancelled }
        if !sawAnyUsage { usage.confirmed = false }

        return AgentTurnResult(
            state: state, terminalReason: status,
            isError: state == .failed || state == .rateLimited, errorMessage: errorMessage,
            model: usage.model, sessionID: threadID,
            resultText: accumulatedText.isEmpty ? nil : accumulatedText,
            usage: usage, limitStatus: limitStatus)
    }

    static func parseRateLimits(_ rl: [String: Any]) -> LimitSnapshot {
        var snapshot = LimitSnapshot(provider: .codex)
        snapshot.fetchedAt = Date()
        snapshot.planType = rl["planType"] as? String

        func window(_ key: String, fallbackLabel: String) -> LimitWindow? {
            guard let w = rl[key] as? [String: Any] else { return nil }
            var label = fallbackLabel
            let mins = JSONUtil.int(w["windowDurationMins"])
            if let mins {
                label = mins >= 1440 ? "\(mins / 1440)일" : "\(mins / 60)시간"
            }
            var out = LimitWindow(label: label, utilization: nil, resetsAt: nil, spanMinutes: mins)
            // 값이 없으면 utilization 을 nil 로 두어 0% 로 표시되지 않게 한다.
            if let p = JSONUtil.double(w["usedPercent"]) { out.utilization = p / 100.0 }
            if let r = JSONUtil.double(w["resetsAt"]) { out.resetsAt = Date(timeIntervalSince1970: r) }
            return out
        }
        if let w = window("primary", fallbackLabel: "1차") { snapshot.windows.append(w) }
        if let w = window("secondary", fallbackLabel: "2차") { snapshot.windows.append(w) }

        if let reached = rl["rateLimitReachedType"] as? String, !reached.isEmpty {
            snapshot.status = .subscriptionCap
            snapshot.message = "한도 도달: \(reached)"
        } else if snapshot.windows.contains(where: { $0.utilization != nil }) {
            snapshot.status = .ok
        } else {
            snapshot.status = .noData
            snapshot.rawResponse = JSONUtil.prettyString(rl)
        }
        return snapshot
    }

    // MARK: - 서버 요청 (승인 / 입력)

    private func handleServerRequest(method: String, id: Any, params: [String: Any]) {
        let key = String(describing: id)
        lock.lock()
        // 트래커가 끝을 정했으면(하위의 답을 넣는 중) 이미 끝난 실행으로 본다.
        let alive = !finishedEmitted && !tracker.isFinished
        if alive { liveServerRequests[key] = (method, params) }
        let snapshots = itemSnapshots
        // 하위 에이전트의 요청도 같은 연결로 온다 (JSON-RPC ID 는 연결 안에서 유일하니 응답은 그대로 된다).
        let owner = tracker.subAgentOwner(threadID: params["threadId"] as? String)
        lock.unlock()

        guard alive else {
            respondToServer(id: id, error: "실행이 이미 종료되었습니다.")
            return
        }

        let itemID = params["itemId"] as? String
        let snapshot = itemID.flatMap { snapshots[$0] }
        let runID = self.runID
        /// 하위가 요청했으면 제목 앞에 그 하위의 이름을 붙이고 `agentID` 를 단다.
        func approval(_ kind: ApprovalKind, toolName: String, title: String, detail: String,
                      input: [String: Any]? = nil) -> AgentEvent {
            .approvalRequested(ApprovalRequest(
                id: key, runID: runID, provider: .codex, kind: kind, toolName: toolName,
                title: owner.map { "\($0.name): \(title)" } ?? title, detail: detail,
                toolUseID: itemID, agentID: owner?.id, input: input.flatMap { JSONUtil.line($0) }))
        }

        switch method {
        case "item/commandExecution/requestApproval":
            let command = (params["command"] as? String)
                ?? (snapshot?["command"] as? String) ?? "(명령 미확인)"
            var detail = command
            if let cwd = params["cwd"] as? String { detail += "\n실행 위치: \(cwd)" }
            if let reason = params["reason"] as? String { detail += "\n사유: \(reason)" }
            var input: [String: Any] = ["command": command]
            input["cwd"] = params["cwd"] as? String
            input["reason"] = params["reason"] as? String
            emit(approval(.command, toolName: "명령 실행", title: JSONUtil.truncate(command, max: 200),
                          detail: JSONUtil.truncate(detail, max: 8000), input: input))

        case "item/fileChange/requestApproval":
            var detail = ""
            var input: [String: Any] = [:]
            if let changes = snapshot?["changes"] as? [[String: Any]] {
                let paths = changes.compactMap { $0["path"] as? String }
                detail = "변경 파일:\n" + paths.map { "  \($0)" }.joined(separator: "\n")
                let diff = changes.compactMap { $0["diff"] as? String }.joined(separator: "\n")
                if !diff.isEmpty { detail += "\n\n" + JSONUtil.truncate(diff, max: 8000) }
                input["changes"] = changes.map { change -> [String: Any] in
                    var out: [String: Any] = [:]
                    out["path"] = change["path"] as? String
                    out["diff"] = change["diff"] as? String
                    return out
                }
            } else {
                detail = JSONUtil.prettyString(params)
            }
            if let reason = params["reason"] as? String { detail += "\n사유: \(reason)" }
            input["reason"] = params["reason"] as? String
            emit(approval(.fileChange, toolName: "파일 변경", title: "파일 변경 승인 요청",
                          detail: JSONUtil.truncate(detail, max: 12000), input: input.isEmpty ? nil : input))

        case "item/permissions/requestApproval":
            var input = (params["permissions"] as? [String: Any]) ?? [:]
            if input.isEmpty { input = params }
            emit(approval(.permissions, toolName: "권한 요청",
                          title: params["reason"] as? String ?? "추가 권한 요청",
                          detail: JSONUtil.truncate(JSONUtil.prettyString(params["permissions"] ?? params),
                                                    max: 8000), input: input))

        case "item/tool/requestUserInput":
            let questions = (params["questions"] as? [[String: Any]]) ?? []
            let items: [UserQuestion.Item] = questions.map { q in
                UserQuestion.Item(
                    id: q["id"] as? String ?? UUID().uuidString,
                    header: q["header"] as? String ?? "",
                    question: q["question"] as? String ?? "",
                    options: ((q["options"] as? [[String: Any]]) ?? [])
                        .compactMap { $0["label"] as? String },
                    allowsOther: q["isOther"] as? Bool ?? false,
                    isSecret: q["isSecret"] as? Bool ?? false)
            }
            lock.lock(); liveServerRequests[key] = (method, params); lock.unlock()
            emit(.questionAsked(UserQuestion(id: key, runID: runID, provider: .codex, items: items,
                                             agentID: owner?.id)))

        case "mcpServer/elicitation/request":
            emit(approval(.elicitation, toolName: "MCP 입력 요청", title: "MCP 서버가 입력을 요청했습니다",
                          detail: JSONUtil.truncate(JSONUtil.prettyString(params), max: 8000), input: params))

        case "execCommandApproval", "applyPatchApproval":
            // 구버전 승인 경로.
            emit(approval(method == "execCommandApproval" ? .command : .fileChange,
                          toolName: method, title: "승인 요청 (\(method))",
                          detail: JSONUtil.truncate(JSONUtil.prettyString(params), max: 8000)))

        default:
            // 모르는 요청은 거절하되 원인을 (진단으로) 남긴다. 조용히 승인하지 않는다.
            emit(.diagnostic("처리하지 않는 Codex 요청: \(method) — 거절로 응답합니다."))
            lock.lock(); liveServerRequests.removeValue(forKey: key); lock.unlock()
            respondToServer(id: id, error: "이 클라이언트가 처리하지 않는 요청입니다: \(method)")
        }
    }

    /// `item/tool/requestUserInput` 의 응답 (순수 — 시험한다): 질문 ID → `{"answers": [답]}`.
    /// 설치된 codex 의 직렬화 형식 이름이 근거다 (`ToolRequestUserInputResponse { answers }` 의 값이
    /// `ToolRequestUserInputAnswer { answers }` — 글 하나가 아니다. 글을 바로 넣으면 "failed to deserialize
    /// ToolRequestUserInputResponse"). 실제 왕복은 아직 확인하지 못했다.
    static func userInputResponse(_ answers: [String: String]) -> [String: Any] {
        ["answers": answers.mapValues { ["answers": [$0]] }]
    }

    private func respondToServer(id: Any, result: [String: Any]) {
        lock.lock(); let p = proc; lock.unlock()
        if let line = JSONUtil.line(["id": id, "result": result]) { _ = p?.writeLine(line) }
    }

    private func respondToServer(id: Any, error: String) {
        lock.lock(); let p = proc; lock.unlock()
        if let line = JSONUtil.line(["id": id, "error": ["code": -32000, "message": error]]) {
            _ = p?.writeLine(line)
        }
    }

    func respond(approvalID: String, decision: ApprovalDecision) async {
        lock.lock()
        guard !finishedEmitted, let entry = liveServerRequests.removeValue(forKey: approvalID) else {
            lock.unlock()
            return   // 종료된 실행에 대한 늦은 응답은 적용하지 않는다.
        }
        lock.unlock()

        let rawID: Any = Int(approvalID) ?? approvalID

        switch entry.method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
             "execCommandApproval", "applyPatchApproval":
            // 거절 사유는 Codex 에 갈 자리가 없다 (decline · cancel 뿐) — 앱의 결정 기록에만 남는다.
            // 질문의 답(`answer`)은 Claude 의 질문 도구에만 있다 — Codex 의 질문은 `requestUserInput` 으로 온다. 오면 거절과 같다.
            let value: String
            switch decision {
            case .allow, .submit: value = "accept"
            case .allowForSession: value = "acceptForSession"
            case .deny, .answer: value = "decline"
            case .denyAndCancel: value = "cancel"
            }
            respondToServer(id: rawID, result: ["decision": value])

        case "item/permissions/requestApproval":
            switch decision {
            case .allow, .allowForSession, .submit:
                // 요청한 권한 프로필을 그대로 승인한다.
                let granted = entry.params["permissions"] as? [String: Any] ?? [:]
                respondToServer(id: rawID, result: [
                    "permissions": granted,
                    "scope": decision == .allowForSession ? "session" : "turn",
                ])
            case .deny, .denyAndCancel, .answer:
                respondToServer(id: rawID, result: ["permissions": [:], "scope": "turn"])
            }

        case "mcpServer/elicitation/request":
            switch decision {
            case .submit(let content):
                // 승인 카드의 입력 칸(`ElicitationForm`)이 채운 값 — 요청의 `requestedSchema` 이름 그대로.
                respondToServer(id: rawID, result: ["action": "accept", "content": JSONUtil.object(content) ?? [:]])
            case .allow, .allowForSession:
                // 입력 칸이 없는 요청(확인만 받는 것).
                respondToServer(id: rawID, result: ["action": "accept", "content": [:]])
            case .deny, .answer:
                respondToServer(id: rawID, result: ["action": "decline"])
            case .denyAndCancel:
                respondToServer(id: rawID, result: ["action": "cancel"])
            }

        default:
            respondToServer(id: rawID, error: "지원하지 않는 승인 종류입니다.")
        }

        emit(.approvalResolved(id: approvalID, decision: decision.koreanName))
        if case .denyAndCancel = decision { await requestInterrupt() }
    }

    func respond(questionID: String, answers: [String: String]) async {
        lock.lock()
        guard !finishedEmitted, liveServerRequests.removeValue(forKey: questionID) != nil else {
            lock.unlock(); return
        }
        lock.unlock()
        let rawID: Any = Int(questionID) ?? questionID
        respondToServer(id: rawID, result: Self.userInputResponse(answers))
        emit(.approvalResolved(id: questionID, decision: "응답 전송"))
    }

    // MARK: - 중단

    func requestInterrupt() async {
        // 이 묶음(멈춤 · 끝)이 읽기 루프가 먼저 판정한 묶음보다 앞서 나가지 않게 한다. `await` 전에 놓는다.
        emitOrder.lock()
        lock.lock()
        interruptRequested = true
        userCancelled = true
        tracker.markUserCancelled()
        // 결과가 이미 정해졌으면(하위의 답을 넣는 중) 그 길이 끝낸다.
        let decided = tracker.isFinished
        // 메인 턴이 끝나고 백그라운드 작업을 기다리는 중이면 곧바로 끝낸다. `turn/interrupt` 는 메인 턴에만 보낼 수
        // 있고(하위 턴 ID 는 -32600), 하위 턴을 멈춰도 그 명령은 계속 돈다 — app-server 를 끄면 전부 끝난다(실측).
        let settled = tracker.interruptWhileSettled()
        lock.unlock()
        if !decided && !settled.isEmpty { perform(settled, injectTimeout: Self.interruptInjectTimeout) }
        emitOrder.unlock()
        if decided || !settled.isEmpty {
            // 넣는 중이면 마칠 때까지 기다린다 — 앱 종료는 이 뒤에 곧바로 app-server 를 끄고, 끄면 넣던 글이 사라진다(c15).
            // `emitOrder` 를 놓은 뒤라 넣기 뒤의 끝(`perform`)과 엇갈리지 않는다.
            await waitForInjection(upTo: Self.interruptInjectTimeout)
            return
        }
        await sendInterruptWhenActive()
    }

    /// 넣기(와 그 뒤의 끝)가 끝날 때까지 기다린다. `seconds` 가 지나면 그대로 돌아간다 — 곧 app-server 를 끄면
    /// 넣기 RPC 는 실패로 풀리고(`handleExit`) 끝은 그 길로 난다.
    private func waitForInjection(upTo seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            lock.lock(); let injecting = pendingInjection != nil; lock.unlock()
            if !injecting { return }
            // 부른 작업이 취소돼도(앱 종료) 바쁘게 돌지 않는다.
            await uncancellableSleep(nanoseconds: 20_000_000)
        }
    }

    /// 실측에서 turn/start 응답 직후의 interrupt 는 "no active turn to interrupt" 로 실패했다.
    /// 메인 턴을 turn/started 알림으로 확인할 때까지(`interruptTarget`) 짧게 기다렸다가 보낸다.
    /// 턴 ID 는 메인 턴의 것만 쓴다.
    private func sendInterruptWhenActive() async {
        lock.lock()
        if interruptSent { lock.unlock(); return }
        lock.unlock()

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            lock.lock()
            let target = tracker.interruptTarget
            let done = finishedEmitted || tracker.isFinished
            lock.unlock()
            if done { return }
            if let target {
                lock.lock()
                if interruptSent { lock.unlock(); return }
                interruptSent = true
                lock.unlock()
                emit(.diagnostic("중단 요청을 보냈습니다."))
                do {
                    _ = try await rpc("turn/interrupt",
                                      ["threadId": target.threadID, "turnId": target.turnID], timeout: 15)
                } catch {
                    emit(.notice("중단 요청 실패: \(error.localizedDescription). 프로세스를 정리합니다."))
                    _ = await shutdown()
                    finishOnce(AgentTurnResult(state: .cancelled,
                                               terminalReason: "interrupt_failed_killed",
                                               isError: false, sessionID: target.threadID))
                }
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        // 턴이 시작되지 않았는데 중단 요청이 있으면 프로세스를 정리한다.
        lock.lock(); let done = finishedEmitted || tracker.isFinished; let tid = tracker.mainThreadID; lock.unlock()
        if !done {
            _ = await shutdown()
            finishOnce(AgentTurnResult(state: .cancelled, terminalReason: "cancelled_before_active",
                                       isError: false, sessionID: tid))
        }
    }

    private func finishOnce(_ result: AgentTurnResult) {
        lock.lock()
        guard !finishedEmitted else { lock.unlock(); return }
        finishedEmitted = true
        liveServerRequests.removeAll()
        // 트래커의 판정이 아닌 길로 끝나면 아직 도는 하위 · 명령을 멈춤으로 닫는다 (app-server 와 함께 끝난다).
        let leftovers = tracker.closeRemaining()
        let c = continuation
        lock.unlock()
        for event in leftovers { c?.yield(event) }
        c?.yield(.finished(result))
        c?.finish()
        Task { _ = await self.shutdown() }
    }

    func shutdown() async -> Bool {
        lock.lock(); let p = proc; lock.unlock()
        guard let p else { return true }
        return await p.shutdown()
    }
}


/// Codex 토큰 사용량 누적기.
///
/// 실측 의미:
/// - `total` = 세션 누적(재개 시 이전 세션 값 포함), `last` = 마지막 API 요청 1회 사용량.
/// - 턴 사용량 = 그 턴 동안의 `last` 합계 = `total` 증가분.
/// 중복 이벤트로 인한 이중 합산을 막기 위해 `total` 이 증가할 때만 `last` 를 더한다.
/// 이렇게 하면 재개한 세션의 과거 사용량이 새 턴에 더해지지 않는다.
struct CodexUsageAccumulator {
    var lastSeenTotalTokens: Int = 0
    var usage = TurnUsage()
    var sawAnyUsage = false

    mutating func apply(_ params: [String: Any]) {
        guard let tu = params["tokenUsage"] as? [String: Any],
              let total = tu["total"] as? [String: Any],
              let last = tu["last"] as? [String: Any] else { return }
        let totalTokens = JSONUtil.intValue(total["totalTokens"])
        guard totalTokens > lastSeenTotalTokens else { return }
        lastSeenTotalTokens = totalTokens

        let input = JSONUtil.intValue(last["inputTokens"])
        let cachedIn = JSONUtil.intValue(last["cachedInputTokens"])
        let cacheWrite = JSONUtil.intValue(last["cacheWriteInputTokens"])
        // inputTokens 는 캐시 토큰을 포함하므로 순수 입력만 남긴다 (중복 계산 방지).
        usage.inputTokens += max(0, input - cachedIn - cacheWrite)
        usage.cacheReadTokens += cachedIn
        usage.cacheWriteTokens += cacheWrite
        usage.outputTokens += JSONUtil.intValue(last["outputTokens"])
        // reasoningOutputTokens 는 outputTokens 의 부분집합이므로 총합에 더하지 않는다.
        usage.reasoningTokens += JSONUtil.intValue(last["reasoningOutputTokens"])
        sawAnyUsage = true
    }
}
