#if DEBUG
import Foundation

/// 화면 확인용 가짜 어댑터 (`-preview.action panes` — AHC_OFFLINE=1 · 임시 DB · 임시 폴더 프로젝트에서만, `ContentView`).
///
/// 분할 화면의 칸 머리 · 툴바 "응답 필요" 를 실제 실행기(`RunSession`)를 거쳐 찍으려고, 보낸 글의 첫 표시대로 한 가지 상태에 머문다.
/// - `[완료]` 곧바로 끝난다.
/// - `[승인]` 명령 실행 승인을 청하고 답을 기다린다 (답하면 끝난다).
/// - `[질문]` 질문을 하고 답을 기다린다 (답하면 끝난다).
/// - `[생각]` 아무것도 내지 않고 머문다 · `[명령]` · `[찾기]` 결과가 오지 않는 명령 · 찾기에 머문다 — 멈출 때까지
///   (실행 중 상태 줄의 "생각하는 중" · "명령 실행 중" · "파일 찾는 중", `-preview.action runStatus`).
/// - `[도구들]` 읽기 · 찾기 · 설명이 붙은 명령(하나는 실패)을 1초 간격으로 하나씩 돌리고, 마지막 명령에 머문다 — 멈출 때까지
///   (도는 실행의 실행 기록이 접힌 채 수만 바뀌는지 — 흔들리지 않는지, `-preview.action toolRun`).
/// - 그 밖 — 멈출 때까지 1초마다 글을 조금씩 낸다.
/// CLI 를 부르지 않는다.
final class PreviewPaneAdapter: AgentAdapter, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = UnfairLock()
    private var continuation: AsyncStream<AgentEvent>.Continuation?
    private var interrupted = false
    private var answered = false
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
        let session = "preview-panes-\(request.runID)"
        emit(.sessionEstablished(sessionID: session, model: request.model ?? "preview", cliVersion: nil))
        let prompt = request.prompt
        if prompt.hasPrefix("[완료]") {
            emit(.assistantMessage("`LoginView.swift` 의 오류 문구 세 곳을 같은 말투로 맞췄습니다."))
            finish(AgentTurnResult(state: .completed, terminalReason: "completed", sessionID: session,
                                   resultText: "문구를 맞췄습니다."))
            return
        }
        if prompt.hasPrefix("[승인]") || prompt.hasPrefix("[편집]") {
            let edit = prompt.hasPrefix("[편집]")
            emit(.assistantMessage(edit ? "오류 문구를 같은 말투로 바꾸겠습니다." : "바꾼 문구가 테스트를 깨지 않는지 확인하겠습니다."))
            let input: [String: Any] = edit
                ? ["file_path": request.workingDirectory.appendingPathComponent("Moa/Login/LoginView.swift").path,
                   "old_string": "Text(\"비밀번호가 틀렸어요\")\n    .foregroundStyle(.red)",
                   "new_string": "Text(\"비밀번호가 맞지 않습니다\")\n    .foregroundStyle(.red)"]
                : ["command": "swift test --filter LoginTests",
                   "description": "로그인 화면 테스트만 돌려 바꾼 문구가 테스트를 깨지 않는지 확인"]
            let tool = edit ? "Edit" : "Bash"
            emit(.toolStarted(id: "tool-test", name: tool, detail: JSONUtil.line(input) ?? "{}"))
            emit(.approvalRequested(ApprovalRequest(id: "preview-approval", runID: request.runID, provider: provider,
                                                    kind: provider == .codex ? .command : .tool, toolName: tool,
                                                    title: edit ? "LoginView.swift" : "swift test --filter LoginTests",
                                                    detail: JSONUtil.prettyString(input), toolUseID: "tool-test",
                                                    input: JSONUtil.line(input))))
            await waitForAnswer()
            finish(AgentTurnResult(state: isInterrupted ? .cancelled : .completed,
                                   terminalReason: isInterrupted ? "interrupted" : "completed", sessionID: session))
            return
        }
        if prompt.hasPrefix("[질문]") {
            emit(.assistantMessage("영어 화면의 문구도 같은 기준으로 맞출지 정해야 합니다."))
            emit(.questionAsked(UserQuestion(id: "preview-question", runID: request.runID, provider: provider, items: [
                .init(id: "scope", header: "범위", question: "영어 화면(`en.lproj`)의 오류 문구도 함께 맞출까요?",
                      options: ["함께 맞춘다", "한국어만"], allowsOther: false, isSecret: false),
            ])))
            await waitForAnswer()
            finish(AgentTurnResult(state: isInterrupted ? .cancelled : .completed,
                                   terminalReason: isInterrupted ? "interrupted" : "completed", sessionID: session))
            return
        }
        if prompt.hasPrefix("[도구들]") {
            let root = request.workingDirectory.path
            let steps: [(name: String, input: [String: Any], output: String, error: Bool)] = [
                ("Read", ["file_path": root + "/Moa/Login/LoginView.swift"], "1\timport SwiftUI", false),
                ("Grep", ["pattern": "errorMessage", "path": root + "/Moa"], "Moa/Login/LoginView.swift:18", false),
                ("Bash", ["command": "git status --short", "description": "Check working tree"], " M Moa/Login/LoginView.swift", false),
                ("Bash", ["command": "swift build 2>&1 | tail -3", "description": "Verify build"], "Build complete!", false),
                ("Bash", ["command": "swift test --filter LoginTests 2>&1 | tail -5", "description": "Run login tests"],
                 "✘ Test errorCopy() recorded an issue at LoginTests.swift:41", true),
                ("Read", ["file_path": root + "/Tests/LoginTests.swift"], "41\t#expect(copy == \"비밀번호가 맞지 않습니다\")", false),
            ]
            emit(.assistantMessage("로그인 화면의 오류 문구를 확인하겠습니다."))
            for (index, step) in steps.enumerated() {
                guard !isInterrupted else { break }
                emit(.toolStarted(id: "tool-\(index)", name: step.name, detail: JSONUtil.line(step.input) ?? "{}"))
                try? await Task.sleep(for: .milliseconds(1000))
                emit(.toolFinished(id: "tool-\(index)", name: step.name, output: step.output, isError: step.error))
            }
            if !isInterrupted {
                emit(.toolStarted(id: "tool-last", name: "Bash", detail: JSONUtil.line(
                    ["command": "swift test 2>&1 | tail -5", "description": "Run full test suite"]) ?? "{}"))
            }
            await waitForAnswer()
            finish(AgentTurnResult(state: .cancelled, terminalReason: "interrupted", sessionID: session))
            return
        }
        if prompt.hasPrefix("[생각]") || prompt.hasPrefix("[명령]") || prompt.hasPrefix("[찾기]") {
            if !prompt.hasPrefix("[생각]") {
                let search = prompt.hasPrefix("[찾기]")
                let input: [String: Any] = search ? ["pattern": "errorMessage", "path": "Moa"]
                                                  : ["command": "swift test --filter LoginTests"]
                emit(.toolStarted(id: "tool-wait", name: search ? "Grep" : "Bash", detail: JSONUtil.line(input) ?? "{}"))
            }
            await waitForAnswer()
            finish(AgentTurnResult(state: .cancelled, terminalReason: "interrupted", sessionID: session))
            return
        }
        if prompt.hasPrefix("[흐름]") {
            // 긴 Markdown 답을 30ms 마다 몇 글자씩 — 응답이 흐르는 동안의 맨 아래 따라가기 확인 (`-preview.action stream`).
            let paragraph = "토큰이 만료되면 `AuthViewModel` 이 갱신을 한 번 시도하고, 실패하면 로그인 화면으로 돌아가 같은 말투의 안내를 보입니다. "
            var answer = "## 로그인 흐름 정리\n\n"
            for index in 1...14 {
                answer += "\(index). " + paragraph + paragraph + "\n"
                if index % 5 == 0 { answer += "\n```swift\nfunc refresh() async throws {\n    try await session.renew()\n}\n```\n\n" }
            }
            // `-preview.streamReplay <파일>` — 실제 CLI 에서 기록한 조각을 같은 때에 같은 글로 다시 흘린다 (JSON `[[초, 글], …]` —
            // 실측 기록에서 뽑은 것). 화면 · CPU 를 실제와 같은 흐름으로 잴 때.
            if let path = UserDefaults.standard.string(forKey: "preview.streamReplay"),
               let data = FileManager.default.contents(atPath: path),
               let trace = try? JSONSerialization.jsonObject(with: data) as? [[Any]] {
                let started = ProcessInfo.processInfo.systemUptime
                var replayed = ""
                for item in trace {
                    guard !isInterrupted, let at = item.first as? Double, let text = item.last as? String else { break }
                    let wait = at - (ProcessInfo.processInfo.systemUptime - started)
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    emit(.assistantDelta(text))
                    replayed += text
                }
                finish(AgentTurnResult(state: isInterrupted ? .cancelled : .completed,
                                       terminalReason: isInterrupted ? "interrupted" : "completed", sessionID: session,
                                       resultText: replayed))
                return
            }
            // `-preview.streamPattern burst` — 조각을 크게 띄엄띄엄 (8 ~ 30글자를 0.15 ~ 0.45초마다, 네 번에 한 번은 더 쉰다):
            // 받은 대로 그리면 와르르 붙었다 멈추는 흐름을 고른 속도로 푸는지 본다 (`StreamReveal`). 기본은 9글자씩 30ms 마다.
            let burst = UserDefaults.standard.string(forKey: "preview.streamPattern") == "burst"
            var seed: UInt64 = 7
            func roll(_ range: ClosedRange<Int>) -> Int {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return range.lowerBound + Int((seed >> 33) % UInt64(range.count))
            }
            var rest = Substring(answer)
            var piece = 0
            while !rest.isEmpty, !isInterrupted {
                let size = burst ? roll(8...30) : 9
                emit(.assistantDelta(String(rest.prefix(size))))
                rest = rest.dropFirst(size)
                piece += 1
                let pause = burst ? roll(150...450) + (piece % 4 == 0 ? 500 : 0) : 30
                try? await Task.sleep(for: .milliseconds(pause))
            }
            finish(AgentTurnResult(state: isInterrupted ? .cancelled : .completed,
                                   terminalReason: isInterrupted ? "interrupted" : "completed", sessionID: session,
                                   resultText: answer))
            return
        }
        let pieces = ["`AuthViewModel.swift` 의 오류 처리를 읽는 중입니다. ", "토큰이 만료되면 ", "다시 로그인하도록 ",
                      "안내하는 흐름을 확인했고, ", "같은 말투로 바꾸는 중입니다."]
        var tick = 0
        while !isInterrupted {
            emit(.assistantDelta(pieces[tick % pieces.count]))
            tick += 1
            try? await Task.sleep(for: .seconds(1))
        }
        finish(AgentTurnResult(state: .cancelled, terminalReason: "interrupted", sessionID: session))
    }

    func respond(approvalID: String, decision: ApprovalDecision) async {
        emit(.approvalResolved(id: approvalID, decision: "\(decision)"))
        lock.withLock { answered = true }
    }

    func respond(questionID: String, answers: [String: String]) async { lock.withLock { answered = true } }
    func requestInterrupt() async { lock.withLock { interrupted = true } }
    func shutdown() async -> Bool { true }

    // MARK: 도우미

    private var isInterrupted: Bool { lock.withLock { interrupted } }

    private func waitForAnswer() async {
        while !lock.withLock({ answered || interrupted }) {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

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
