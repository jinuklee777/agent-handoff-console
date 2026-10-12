import Foundation

/// Antigravity CLI(`agy`) 어댑터 — Gemini 를 작업 에이전트로 쓴다.
///
/// 흐름: stdin 에 `{"event":"user","message":{"content":…}}` 한 줄 → stdout 이벤트 소비 → `result` 로 종료.
/// 세션은 `result.conversation_id` 를 저장했다가 다음 턴에 `--conversation <id>` 로 잇는다.
///
/// **승인을 앱이 받을 수 없다** (2026-09-12 실측, agy 1.2.1):
/// 헤드리스는 권한을 물을 방법이 없어 승인이 필요한 도구를 자동 거절하거나 시간 제한까지 멈춘다.
/// `permissions.allow` 설정도 헤드리스에서는 무시된다 (공식 이슈 #548).
/// 그래서 이 어댑터는 `--dangerously-skip-permissions` 로만 동작하며,
/// **호출자가 프로젝트별로 명시적으로 허용했을 때만** 실행해야 한다 (`AppModel.antigravityAllowed`).
/// 실행된 도구·명령은 이벤트로 그대로 대화에 남긴다 (사전 승인 대신 사후 기록).
///
/// 검증 환경: Antigravity CLI 1.2.1 (2026-09-12). 모델 · 강도 · `/boost` 조합은 1.2.2 로 다시 실측했다 (2026-09-14, `plan`).
final class AntigravityAdapter: AgentAdapter, @unchecked Sendable {
    let provider: AgentProvider = .gemini

    /// 강도 선택지에 넣는 값 (화면 이름 ULTRA). `low|medium|high` 는 `--effort`, `boost` 는 **High + 프롬프트 앞 `/boost`**.
    static let boostEffort = "boost"

    /// 강도를 고르지 않았을 때 넘기는 값이자 ULTRA 가 함께 넘기는 강도 (사용자 결정 2026-09-14: "기본은 무조건 high").
    /// agy 는 제품군을 `--effort` 없이 주면 `/boost` 를 붙여도 거부했다 — 제품군에 쓸 기본 강도를 주지 않는다
    /// (1.2.2 실측 `gemini-3.8-flash`, docs/CLI프로토콜.md). 그래서 앱이 이 값을 넘기고, 화면에도 CLI 기본값이 아니라 High 로 보인다.
    static let defaultEffort = "high"

    private let executablePath: String
    private let environment: [String: String]
    private let cliVersion: String?
    /// 셸 명령의 파일 쓰기를 막는다 (실측: `--sandbox` 에서 `echo > file` 이 거부됨).
    private let sandbox: Bool
    private let printTimeout: String

    private let lock = UnfairLock()
    private var proc: ManagedProcess?
    private var continuation: AsyncStream<AgentEvent>.Continuation?
    private var runID = ""
    private var startedAt = Date()
    private var conversationID: String?
    private var model: String?
    private var finishedEmitted = false
    private var userCancelled = false
    private var turnUsage = TurnUsage()
    private var sawAnyUsage = false
    private var stderrBuffer = ""
    /// 이 턴에 넘긴 ULTRA 표기 ("--effort high + 프롬프트 앞 /boost"). ULTRA 가 아니면 nil — 첫 안내에 남긴다.
    private var ultraSent: String?
    /// step_index → (도구 이름, 시작 시 파라미터). 완료 이벤트에 짝을 맞춘다.
    private var activeTools: [Int: (name: String, parameters: [String: Any])] = [:]
    /// step_index → 그 응답 단계에서 받은 글. agy 1.3.2 부터 stream-json 이 응답 단계(`agent_response`)의 `text_delta` 로 본문을
    /// 조각조각(증분) 흘려 보낸다 — 조각은 흐르는 글로 넘기고, 단계가 끝나면(DONE) 그 단계의 글을 한 메시지로 확정한다.
    private var responseText: [Int: String] = [:]
    /// 이 턴에 흐르는 글을 받았다 — 마지막 `result.response` 를 다시 내지 않는다 (받지 않은 옛 agy 는 그것만 낸다).
    private var streamedResponse = false

    init(executablePath: String, environment: [String: String], cliVersion: String? = nil,
         sandbox: Bool = true, printTimeout: String = "10m") {
        self.executablePath = executablePath
        self.environment = environment
        self.cliVersion = cliVersion
        self.sandbox = sandbox
        self.printTimeout = printTimeout
    }

    var currentPID: Int32? {
        lock.lock(); defer { lock.unlock() }
        guard let p = proc, p.isRunning else { return nil }
        return p.processIdentifier
    }

    // MARK: - 시작

    func start(_ request: AgentTurnRequest) -> AsyncStream<AgentEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { cont in
            self.lock.lock()
            self.continuation = cont
            self.runID = request.runID
            self.startedAt = Date()
            self.lock.unlock()
            Task { await self.run(request) }
        }
    }

    private func emit(_ e: AgentEvent) {
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(e)
    }

    /// 요청 → argv. 모델 · 강도는 `plan` 이 정한 값을 그대로 옮긴다 (RunCoordinator 가 `plan` 을 거쳐 요청을 만든다).
    static func arguments(for request: AgentTurnRequest, sandbox: Bool,
                          printTimeout: String) -> [String] {
        var args = ["--input-format", "stream-json", "--output-format", "stream-json",
                    "--add-dir", request.workingDirectory.path,
                    "--dangerously-skip-permissions",
                    "--print-timeout", printTimeout]
        if sandbox { args.append("--sandbox") }
        // 모델 슬러그에 강도가 붙어 있으면 --effort 와 함께 쓸 수 없다 (실측: conflicts 오류).
        if let model = request.model, !model.isEmpty {
            args += ["--model", model]
            if let effort = request.effort, !effort.isEmpty, effort != boostEffort,
               !Self.slugCarriesEffort(model) {
                args += ["--effort", effort]
            }
        }
        if let resume = request.resumeSessionID, !resume.isEmpty {
            args += ["--conversation", resume]
        }
        // stream-json 에서는 마지막 결과에만 적용된다 (`structured_output`).
        if let schema = request.outputSchema, !schema.isEmpty {
            args += ["--json-schema", schema]
        }
        return args
    }

    /// "gemini-3.8-flash-high" 처럼 강도가 슬러그에 포함됐는지.
    static func slugCarriesEffort(_ slug: String) -> Bool {
        ModelCatalog.antigravityEfforts.contains { slug.hasSuffix("-" + $0) }
    }

    /// boost 는 플래그가 아니라 슬래시 명령이다. 프롬프트 앞에 붙인다 (강도는 `--effort` 로 따로 — `plan`).
    static func promptText(_ request: AgentTurnRequest) -> String {
        request.boost || request.effort == boostEffort ? "/boost " + request.prompt : request.prompt
    }

    // MARK: - 보낼 값 (판정)

    /// 한 턴에 agy 로 실제로 넘기는 값.
    struct TurnPlan: Equatable, Sendable {
        var model: String
        /// `--effort`. nil 이면 넘기지 않는다 (강도를 받지 않는 모델 · 강도가 붙은 슬러그).
        var effort: String?
        /// 프롬프트 앞 `/boost ` (ULTRA).
        var boost: Bool

        /// agy 가 쓰는 강도 — `--effort` 로 넘긴 값, 없으면 슬러그에 붙은 강도 (화면 · 기록 문구용).
        var passedEffort: String? { effort ?? ModelCatalog.splitEffort(model).effort }

        /// ULTRA 로 넘기는 값 그대로 — "High + /boost", 강도를 받지 않는 모델은 "/boost". ULTRA 가 아니면 nil.
        var ultraText: String? {
            guard boost else { return nil }
            return passedEffort.map { "\(EffortScale.name(of: $0)) + /boost" } ?? "/boost"
        }
    }

    /// 보내지 않는 이유 — agy 가 거부할 것을 알거나(실측), 넘길 강도를 정할 근거가 없을 때.
    enum TurnBlock: Equatable, Sendable {
        /// 모델 목록을 아직 못 읽어 기본 모델 · 받는 강도를 모른다.
        case catalogUnknown
        /// 모델을 고르지 않았고 목록에 기본으로 쓸 Flash 제품군(High 를 받는)도 없다.
        case modelUnchosen
        /// 고른 모델이 지금 목록에 없다 — 기본값(High) · ULTRA 를 받는지 모른다.
        case modelUnlisted(String)
        /// 이 모델에는 High 가 없다 — 기본값 · ULTRA(High + /boost)를 넘길 수 없다. `ultra` 는 ULTRA 를 골랐는지.
        case noHigh(model: String, available: [String], ultra: Bool)
        /// agy 가 받는 강도(low · medium · high)가 아니다 — 옛 선택에 남은 Codex 값(xhigh · max · ultra) 등.
        case unsupportedEffort(String)
        /// 강도가 붙은 옛 슬러그(`gemini-3.8-flash-low`)에 다른 강도를 골랐다 — 슬러그와 `--effort` 는 함께 쓰면 거부된다(실측:
        /// conflicts). 슬러그 강도로 몰래 바꿔 보내지 않는다. `wanted` 는 고른 강도 (ULTRA 면 High).
        case slugConflict(model: String, carried: String, wanted: String)

        /// 배너 · 카드 · 칩 도움말에 그대로 쓰는 문장 (카드 두 줄에 들어가는 길이). 이 화면에서 할 수 있는 일만 권한다.
        var message: String {
            switch self {
            case .catalogUnknown:
                return "모델 목록을 확인하지 못해 보낼 모델 · 강도를 정할 수 없습니다. 목록을 새로고침하세요."
            case .modelUnchosen:
                return "기본으로 쓸 Flash 모델이 목록에 없습니다. 모델을 고르세요."
            case .modelUnlisted:
                return "고른 모델이 지금 목록에 없어 High 를 받는지 모릅니다. 다른 모델을 고르거나 목록을 새로고침하세요."
            case .noHigh(_, let available, let ultra):
                let list = available.map(EffortScale.name(of:)).joined(separator: " · ")
                return ultra
                    ? "이 모델에는 High 가 없어 ULTRA(High + /boost)를 쓸 수 없습니다. 강도를 고르세요 (\(list))."
                    : "이 모델에는 기본값 High 가 없어 넘길 강도를 정하지 못했습니다. 강도를 고르세요 (\(list))."
            case .unsupportedEffort(let effort):
                return "Antigravity 는 Low · Medium · High 만 받습니다. 저장된 강도(\(effort)) 대신 강도나 모델을 다시 고르세요."
            case .slugConflict(let model, let carried, let wanted):
                return "\(model) 에는 강도(\(EffortScale.name(of: carried)))가 이미 붙어 있어 "
                    + "고른 강도(\(EffortScale.name(of: wanted)))를 함께 넘길 수 없습니다. 목록에서 모델을 다시 고르세요."
            }
        }
    }

    enum TurnOutcome: Equatable, Sendable {
        case send(TurnPlan)
        case blocked(TurnBlock)
    }

    /// 목록의 강도 중 `--effort` 로 넘기는 값 (ULTRA 는 뺀다).
    static func cliEfforts(of option: AgentModelOption) -> [String] {
        option.supportedEfforts.filter { ModelCatalog.antigravityEfforts.contains($0) }
    }

    /// 스레드 선택(모델 · 강도) + `agy models` 목록 → 넘길 값. 모든 Antigravity 턴이 이 판정을 거친다
    /// (입력창 · 인계 — RunCoordinator 가 요청을 만들 때, AppModel 은 보내기 전에 같은 판정으로 이유를 보인다).
    ///
    /// 실측(agy 1.2.2, 2026-09-14, docs/CLI프로토콜.md):
    /// - `--model <제품군>` 만: `requires --effort` 로 거부 — 프롬프트가 `/boost …` 여도 같다 (모델 검증이 먼저).
    /// - `--model <제품군> --effort high` + `/boost …`: 동작 (`gemini-3.8-flash-high` 로 해석, `/boost` 확장).
    /// - `--model <강도 변형 없는 모델>` + `/boost …`: 동작 (예 `claude-sonnet-4-6`).
    ///
    /// 그래서 강도를 고르지 않았거나 ULTRA 면 그 모델이 High 를 받을 때 High 를 넘기고, 강도를 받지 않는 모델이면 넘기지 않는다.
    /// 목록으로 판단할 수 없으면(목록 없음 · 목록에 없는 모델) 짐작해 넘기지 않고 막는다. 직접 고른 강도는 그대로 넘긴다.
    /// (강도 변형이 있는 모델 가운데 거부를 실측한 것은 `gemini-3.8-flash` 뿐이다 — 나머지는 같은 규칙으로 본다.)
    static func plan(model selected: String?, effort selectedEffort: String?,
                     options: [AgentModelOption]) -> TurnOutcome {
        let listed = ModelCatalog.presentableOptions(options)
        let boost = selectedEffort == boostEffort
        let chosen = boost ? nil : selectedEffort.flatMap { $0.isEmpty ? nil : $0 }
        if let chosen, !ModelCatalog.antigravityEfforts.contains(chosen) {
            return .blocked(.unsupportedEffort(chosen))
        }
        // 모델: 고르지 않았으면 앱 기본 모델 (목록의 가장 최신 Flash 제품군 — ModelCatalog.preferredOption).
        // "default" 는 Claude 에서만 '고르지 않음' 이다 — Antigravity 의 옛 "default" 는 목록에 없는 모델로 본다 (EffortScale.availability).
        let model: String
        if let selected, !selected.isEmpty {
            model = selected
        } else if let preferred = ModelCatalog.preferredOption(in: listed) {
            model = preferred.identifier
        } else {
            return .blocked(listed.isEmpty ? .catalogUnknown : .modelUnchosen)
        }
        // 강도가 붙은 슬러그(옛 선택)는 --effort 와 함께 쓰면 거부된다 — 슬러그의 강도로 보낸다. 다른 강도(ULTRA 면 High)를
        // 골랐으면 슬러그 강도로 몰래 바꾸지 않고 막는다 (화면에 보인 강도와 실제 강도가 어긋나지 않게).
        if let carried = ModelCatalog.splitEffort(model).effort {
            if let wanted = boost ? defaultEffort : chosen, wanted != carried {
                return .blocked(.slugConflict(model: model, carried: carried, wanted: wanted))
            }
            return .send(TurnPlan(model: model, effort: nil, boost: boost))
        }
        if let chosen { return .send(TurnPlan(model: model, effort: chosen, boost: false)) }
        // 남은 경우: 강도 nil(기본값) · ULTRA — 이 모델이 High 를 받는지 목록으로 판단한다.
        guard let option = listed.first(where: { $0.identifier == model }) else {
            return .blocked(listed.isEmpty ? .catalogUnknown : .modelUnlisted(model))
        }
        let efforts = cliEfforts(of: option)
        if efforts.isEmpty { return .send(TurnPlan(model: model, effort: nil, boost: boost)) }
        guard efforts.contains(defaultEffort) else {
            return .blocked(.noHigh(model: model, available: efforts, ultra: boost))
        }
        return .send(TurnPlan(model: model, effort: defaultEffort, boost: boost))
    }

    /// ULTRA 로 보낸 턴의 기록 문구 — 실제로 넘긴 값 그대로. ULTRA 가 아니면 nil.
    static func ultraRecord(_ request: AgentTurnRequest) -> String? {
        guard request.boost || request.effort == boostEffort else { return nil }
        let effort = request.effort.flatMap { $0.isEmpty || $0 == boostEffort ? nil : $0 }
        let model = request.model ?? ""
        let passed = effort.map { !model.isEmpty && !slugCarriesEffort(model) ? "--effort \($0) + " : "" } ?? ""
        return "ULTRA 로 보냈습니다 (\(passed)프롬프트 앞 /boost)."
    }

    private func run(_ request: AgentTurnRequest) async {
        // 읽기 전용을 보장할 방법이 없다: 헤드리스는 자동 승인으로만 돌고, `--sandbox` · `--mode plan` 으로도
        // 편집 도구가 파일을 쓴다(실측). 부탁만 하고 돌리지 않는다. `RunCoordinator` 가 먼저 막지만 여기서도 막는다.
        if request.readOnly {
            finishOnce(AgentTurnResult(state: .failed, terminalReason: "read_only_unsupported", isError: true,
                                       errorMessage: "Antigravity 는 읽기 전용 턴을 보장할 수 없어 실행하지 않았습니다."))
            return
        }
        lock.lock(); ultraSent = Self.ultraRecord(request); lock.unlock()
        let args = Self.arguments(for: request, sandbox: sandbox, printTimeout: printTimeout)
        let p = ManagedProcess(executable: URL(fileURLWithPath: executablePath), arguments: args,
                               workingDirectory: request.workingDirectory, environment: environment)
        lock.lock(); proc = p; lock.unlock()
        let stream = p.makeStream()
        p.launch()

        guard let message = JSONUtil.line(["event": "user",
                                           "message": ["content": Self.promptText(request)]]) else {
            finishOnce(AgentTurnResult(state: .failed, terminalReason: "setup_failed", isError: true,
                                       errorMessage: "입력을 JSON 으로 만들지 못했습니다."))
            return
        }
        p.writeLine(message)
        p.closeStdin()

        for await out in stream {
            switch out {
            case .stdoutLine(let line):
                handle(line)
            case .stderrLine(let line):
                stderrBuffer += line + "\n"
                // 권한 자동 거절 같은 안내는 사용자에게 보여준다.
                if line.lowercased().contains("permission") || line.contains("truncated") {
                    emit(.notice("agy: " + JSONUtil.truncate(line, max: 300)))
                }
            case .exited(let status, let signaled):
                finishOnce(exitResult(status: status, signaled: signaled))
            case .launchFailed(let message):
                finishOnce(AgentTurnResult(state: .failed, terminalReason: "launch_failed",
                                           isError: true, errorMessage: message))
            }
        }
        finishOnce(exitResult(status: -1, signaled: false))
    }

    private func exitResult(status: Int32, signaled: Bool) -> AgentTurnResult {
        lock.lock()
        let cancelled = userCancelled
        let stderr = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
        if cancelled || signaled {
            var result = AgentTurnResult(state: .cancelled, terminalReason: "interrupted")
            result.usage = usageSnapshot(confirmed: false)
            return result
        }
        let message = stderr.isEmpty ? "종료 코드 \(status)" : JSONUtil.truncate(stderr, max: 400)
        let classification = ErrorClassifier.classify(message)
        var result = AgentTurnResult(
            state: classification == .subscriptionCap ? .rateLimited : .failed,
            terminalReason: "exited_without_result", isError: true, errorMessage: message,
            model: model, sessionID: conversationID, limitStatus: classification)
        result.usage = usageSnapshot(confirmed: false)
        return result
    }

    // MARK: - 이벤트 해석

    private func handle(_ line: String) {
        guard let object = JSONUtil.object(line) else { return }
        switch object["event"] as? String {
        case "init":
            handleInit(object["init"] as? [String: Any] ?? [:], conversationID: object["conversation_id"] as? String)
        case "step_update":
            handleStep(object["step_update"] as? [String: Any] ?? [:])
        case "result":
            handleResult(object["result"] as? [String: Any] ?? [:])
        default:
            break
        }
    }

    private func handleInit(_ init_: [String: Any], conversationID id: String?) {
        lock.lock()
        conversationID = id ?? conversationID
        model = init_["model"] as? String ?? model
        let sessionID = conversationID
        let currentModel = model
        let ultra = ultraSent
        lock.unlock()
        if let sessionID {
            emit(.sessionEstablished(sessionID: sessionID, model: currentModel, cliVersion: cliVersion))
        }
        // 승인을 묻지 않는다는 사실을 대화에 남긴다 (사전 승인이 아니라 사후 기록). ULTRA 면 넘긴 값도 남긴다.
        emit(.notice("Antigravity 턴은 승인을 묻지 않고 실행됩니다"
                     + (sandbox ? " (샌드박스: 셸 명령의 파일 쓰기 제한)" : " (샌드박스 없음)")
                     + ". " + (ultra.map { $0 + " " } ?? "")
                     + "실행된 도구와 명령은 아래에 그대로 기록됩니다."))
    }

    private func handleStep(_ step: [String: Any]) {
        if let id = step["conversation_id"] as? String {
            lock.lock(); conversationID = id; lock.unlock()
        }
        let index = JSONUtil.int(step["step_index"]) ?? 0
        let state = (step["state"] as? String)?.uppercased() ?? ""
        switch step["step_type"] as? String {
        case "agent_response":
            // 조각은 증분이다 — DONE 줄에도 마지막 조각이 온다 (2026-10-09 실측, agy 1.3.2: 조각 60개를 이은 글 = result.response).
            if let delta = step["text_delta"] as? String, !delta.isEmpty {
                lock.lock(); responseText[index, default: ""] += delta; streamedResponse = true; lock.unlock()
                emit(.assistantDelta(delta))
            }
            guard state == "DONE" else { return }
            if let usage = step["usage"] as? [String: Any] { addUsage(usage) }
            lock.lock(); let text = responseText.removeValue(forKey: index); lock.unlock()
            if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                emit(.assistantMessage(text))
            }
        case "tool":
            handleToolStep(step, index: index, state: state)
        default:
            break
        }
    }

    private func handleToolStep(_ step: [String: Any], index: Int, state: String) {
        let info = step["tool_info"] as? [String: Any] ?? [:]
        let name = step["tool_name"] as? String ?? info["name"] as? String ?? "도구"
        let parameters = info["parameters"] as? [String: Any] ?? [:]
        let id = "step-\(index)"
        let output = info["output"] as? String
        let errorText = (info["error"] as? [String: Any])?["message"] as? String
            ?? info["error"] as? String

        if state == "ACTIVE" {
            lock.lock(); activeTools[index] = (name, parameters); lock.unlock()
            if name == "run_command", let command = Self.commandText(parameters) {
                emit(.commandExecution(id: id, command: command, cwd: nil, output: nil,
                                       exitCode: nil, status: "inProgress"))
            } else if let paths = Self.changedPaths(name: name, parameters: parameters) {
                emit(.fileChange(id: id, paths: paths, diff: nil, status: "inProgress"))
            } else {
                emit(.toolStarted(id: id, name: name, detail: JSONUtil.string(parameters)))
            }
            return
        }
        guard state == "DONE" || state == "ERROR" else { return }
        lock.lock(); activeTools[index] = nil; lock.unlock()
        let isError = state == "ERROR"
        if name == "run_command", let command = Self.commandText(parameters) {
            // agy 는 종료 코드를 주지 않는다. 만들어내지 않고 "미확인"으로 둔다.
            emit(.commandExecution(id: id, command: command, cwd: nil,
                                   output: errorText ?? output, exitCode: nil,
                                   status: isError ? "failed" : "completed"))
        } else if let paths = Self.changedPaths(name: name, parameters: parameters) {
            emit(.fileChange(id: id, paths: paths, diff: nil,
                             status: isError ? "failed" : "completed"))
        } else {
            emit(.toolFinished(id: id, name: name, output: errorText ?? output ?? "",
                               isError: isError))
        }
    }

    static func commandText(_ parameters: [String: Any]) -> String? {
        for key in ["CommandLine", "Command", "command"] {
            if let value = parameters[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// 파일을 바꾸는 도구면 대상 경로들을 돌려준다 (실측 파라미터 이름 기준).
    static func changedPaths(name: String, parameters: [String: Any]) -> [String]? {
        let writers = ["write_to_file", "replace_file_content", "multi_replace_file_content",
                       "sed_file", "notebook_edit"]
        guard writers.contains(name) else { return nil }
        for key in ["TargetFile", "AbsolutePath", "FilePath", "file_path"] {
            if let value = parameters[key] as? String, !value.isEmpty { return [value] }
        }
        return [name]
    }

    private func handleResult(_ result: [String: Any]) {
        if let id = result["conversation_id"] as? String, !id.isEmpty {
            lock.lock(); conversationID = id; lock.unlock()
        }
        if let usage = result["usage"] as? [String: Any] { setUsage(usage) }
        let response = (result["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // 흐르는 글을 받았으면 응답 단계마다 이미 확정했다 — 같은 글을 한 번 더 내지 않는다 (끝나지 않은 단계의 글은 실행의 끝이 닫는다).
        lock.lock(); let streamed = streamedResponse; lock.unlock()
        if !streamed, let response, !response.isEmpty { emit(.assistantMessage(response)) }

        let status = (result["status"] as? String)?.uppercased() ?? ""
        let deniedCount = (result["denied_actions"] as? [Any])?.count ?? 0
        if deniedCount > 0 {
            emit(.notice("권한이 없어 거절된 도구 호출 \(deniedCount)건이 있습니다."))
        }
        lock.lock()
        let cancelled = userCancelled
        let sessionID = conversationID
        let currentModel = model
        lock.unlock()

        var state: RunState
        var terminalReason = status.lowercased()
        var errorMessage: String?
        var limitStatus: LimitStatus?
        switch status {
        case "SUCCESS":
            state = .completed
        case "CANCELED", "INTERRUPTED":
            state = .cancelled
        case "WAITING", "RUNNING":
            // 시간 제한으로 턴이 끝나지 않은 채 결과가 나온 경우.
            state = .failed
            terminalReason = "print_timeout"
            errorMessage = "시간 제한 안에 턴이 끝나지 않았습니다 (agy --print-timeout)."
        default:
            state = .failed
            let detail = (result["error"] as? String) ?? response ?? "원인 미확인"
            let classification = ErrorClassifier.classify(detail)
            limitStatus = classification
            errorMessage = detail
            if classification == .subscriptionCap { state = .rateLimited }
        }
        if cancelled { state = .cancelled; terminalReason = "interrupted" }

        var turn = AgentTurnResult(
            state: state, terminalReason: terminalReason,
            isError: state == .failed || state == .rateLimited, errorMessage: errorMessage,
            model: currentModel, sessionID: sessionID, resultText: response,
            limitStatus: limitStatus)
        if let structured = result["structured_output"], !(structured is NSNull) {
            turn.structuredOutput = JSONUtil.string(structured)
        }
        turn.usage = usageSnapshot(confirmed: state == .completed)
        finishOnce(turn)
    }

    // MARK: - 사용량

    private func addUsage(_ usage: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        // 결과 이벤트의 합계가 최종값이다. 중간 값은 더 큰 쪽만 남긴다.
        let total = JSONUtil.intValue(usage["total_tokens"])
        guard total >= turnUsage.inputTokens + turnUsage.outputTokens else { return }
        applyUsageLocked(usage)
    }

    private func setUsage(_ usage: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        applyUsageLocked(usage)
    }

    private func applyUsageLocked(_ usage: [String: Any]) {
        turnUsage.inputTokens = JSONUtil.intValue(usage["input_tokens"])
        turnUsage.outputTokens = JSONUtil.intValue(usage["output_tokens"])
        turnUsage.cacheReadTokens = JSONUtil.intValue(usage["cache_read_tokens"])
        // thinking 은 출력의 부분집합이라 총합에 더하지 않는다 (Claude 와 같은 규칙).
        turnUsage.reasoningTokens = JSONUtil.intValue(usage["thinking_tokens"])
        turnUsage.model = model
        sawAnyUsage = true
    }

    private func usageSnapshot(confirmed: Bool) -> TurnUsage? {
        lock.lock(); defer { lock.unlock() }
        guard sawAnyUsage else { return nil }
        var usage = turnUsage
        usage.confirmed = confirmed
        usage.durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        return usage
    }

    // MARK: - 승인 · 중단 · 종료

    /// 승인 요청이 오지 않는 어댑터다 (헤드리스가 묻지 못한다). 호출돼도 할 일이 없다.
    func respond(approvalID: String, decision: ApprovalDecision) async {}
    func respond(questionID: String, answers: [String: String]) async {}

    /// 중단 프로토콜이 없어 프로세스를 종료한다.
    func requestInterrupt() async {
        lock.lock()
        userCancelled = true
        let p = proc
        lock.unlock()
        _ = await p?.shutdown()
    }

    func shutdown() async -> Bool {
        lock.lock(); let p = proc; lock.unlock()
        guard let p else { return true }
        return await p.shutdown()
    }

    private func finishOnce(_ result: AgentTurnResult) {
        lock.lock()
        guard !finishedEmitted else { lock.unlock(); return }
        finishedEmitted = true
        let c = continuation
        lock.unlock()
        c?.yield(.finished(result))
        c?.finish()
        Task { _ = await self.shutdown() }
    }
}
