import Foundation

// 사용법: inttest [offline|workspace|handoffcard|approvalcards|codexswitch|overview|slash|claudeapi|titles|agylimits|orbs]
//                  — CLI 를 부르지 않는다 (offline 과 그 일부)
//        inttest [live|all|env|stream|approval|interrupt|child|handoff|resume|limits|account|accountswitch|coordinator|model
//                 |turnoptions|orchestration|gemini|geminilarge|antigravity|autohandoff|multirun|background|staleresume|releasefix]
//                  — 실제 CLI 를 부른다 (대부분 구독 사용량을 쓴다)
//        inttest migrate <db경로>   실제 DB 사본에 마이그레이션을 적용해 결과를 확인한다
let rawArgs = CommandLine.arguments.dropFirst()

// 옵션: --codex-model=<id> --codex-effort=<강도> --claude-model=<별칭> --claude-effort=<강도> --skip-gemini --autohandoff-only=F,G
// 한도 사용을 줄이려고 가벼운 모델로 실제 CLI 검증을 돌릴 때 쓴다.
for arg in rawArgs {
    if arg.hasPrefix("--codex-model=") {
        LiveTests.codexModelOverride = String(arg.dropFirst("--codex-model=".count))
    } else if arg.hasPrefix("--codex-effort=") {
        LiveTests.codexEffortOverride = String(arg.dropFirst("--codex-effort=".count))
    } else if arg.hasPrefix("--claude-model=") {
        LiveTests.claudeModelOverride = String(arg.dropFirst("--claude-model=".count))
    } else if arg.hasPrefix("--claude-effort=") {
        LiveTests.claudeEffortOverride = String(arg.dropFirst("--claude-effort=".count))
    } else if arg == "--skip-gemini" {
        LiveTests.skipGemini = true
    } else if arg.hasPrefix("--autohandoff-only=") {
        LiveTests.autoHandoffOnly = Set(arg.dropFirst("--autohandoff-only=".count).split(separator: ",").map(String.init))
    }
}

let args = rawArgs.filter { !$0.hasPrefix("--") }
let selection = Set(args.isEmpty ? ["offline"] : args.map { $0.lowercased() })
let wantsAll = selection.contains("all")
let wantsLive = wantsAll || selection.contains("live")

func want(_ name: String) -> Bool { wantsAll || selection.contains(name) }

// 지정한 DB 에 마이그레이션을 적용한다. 실제 데이터 사본으로 확인할 때 쓴다.
// 앱이 쓰는 코드 경로를 그대로 쓴다 (Store.bootstrap → Migrations.migrate).
if selection.contains("migrate") {
    guard CommandLine.arguments.count > 2 else {
        print("사용법: inttest migrate <db경로>")
        exit(2)
    }
    let url = URL(fileURLWithPath: CommandLine.arguments[2])
    let store = Store(databaseURL: url)
    do {
        try await store.db.open()
        let before = try await store.db.userVersion()
        try await store.bootstrap()
        let after = try await store.db.userVersion()
        print("스키마 버전: \(before) → \(after)")
        let threads = try await store.allThreads()
        let runs = try await store.allRuns()
        let handoffs = try await store.allHandoffs()
        let accounts = try await store.codexAccounts()
        print("스레드 \(threads.count) · 실행 \(runs.count) · 인계 \(handoffs.count) "
              + "· 등록된 Codex 계정 \(accounts.count)")
        for t in threads {
            print("  스레드 '\(t.title)' → codex 계정 \(t.codexAccountID)")
        }
        for s in try await store.sessions(threadID: threads.first?.id ?? "") {
            print("  세션 \(s.provider.rawValue) 계정=\(s.accountID.isEmpty ? "(없음)" : s.accountID) "
                  + "cliSessionID=\(s.cliSessionID ?? "없음")")
        }
        await store.db.close()
        exit(0)
    } catch {
        print("마이그레이션 실패: \(error)")
        exit(1)
    }
}

// 앱을 처음 열었을 때 바로 쓸 수 있도록 프로젝트/스레드를 하나 등록한다.
if selection.contains("seed") {
    let store = Store(databaseURL: Store.defaultDatabaseURL())
    try await store.bootstrap()
    // 폴더는 'seed' 다음의 첫 비 '--' 인수 (플래그를 먼저 써도 "--models" 를 폴더로 등록하지 않게). 없으면 지금 폴더.
    let path = args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath
    let existing = try await store.projects()
    let project: Project
    if let found = existing.first(where: { $0.path == path }) {
        project = found
        print("이미 등록된 프로젝트: \(project.name)")
    } else {
        project = Project(name: (path as NSString).lastPathComponent, path: path,
                          sortOrder: existing.count)
        try await store.upsertProject(project)
        print("프로젝트 등록: \(project.name) — \(path)")
    }
    let threads = try await store.threads(projectID: project.id)
    if threads.isEmpty {
        var thread = ConversationThread(projectID: project.id, title: "첫 스레드")
        thread.goal = "여기에 이 스레드의 현재 목표를 적으세요. 인계 초안에 항상 포함됩니다."
        thread.pinnedNotes = "여기에 제약과 변경 금지 사항을 적으세요."
        try await store.upsertThread(thread)
        print("스레드 생성: \(thread.title)")
    }
    // `--threads=<개수>` — 사이드바의 3개 제한 · "더보기" · 접기를 볼 때. 첫 스레드 뒤에 "스레드 2", "스레드 3", … 을 더한다.
    if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--threads=") }),
       let count = Int(arg.dropFirst("--threads=".count)), count > 1,
       !(ProcessInfo.processInfo.environment["AHC_DATABASE_PATH"] ?? "").isEmpty {
        let current = try await store.threads(projectID: project.id).count
        for n in (current + 1)...max(count, current + 1) where n <= count {
            let extra = ConversationThread(projectID: project.id, title: "스레드 \(n)")
            try await store.upsertThread(extra)
        }
        print("스레드 \(count)개로 채움")
    }
    // 화면 확인용 (scripts/preview/capture.sh 의 SEED_ARGS). **`AHC_DATABASE_PATH` 로 연 DB 에만** 쓴다 — 기본 DB(실제 기록)에
    // 고정 목록을 넣으면 앱이 다시 조회할 때까지(Antigravity 는 하루) 그 목록을 보여 주고, 선택은 실제 스레드를 바꾼다.
    let previewDatabase = !(ProcessInfo.processInfo.environment["AHC_DATABASE_PATH"] ?? "").isEmpty
    let previewArguments = CommandLine.arguments.filter {
        $0 == "--models" || $0 == "--codex-accounts" || $0 == "--handoff" || $0 == "--history" || $0 == "--execlog"
            || $0 == "--codex-history"
            || $0.hasPrefix("--selection=")
            || $0.hasPrefix("--events=") || $0.hasPrefix("--threads=")
            || $0.hasPrefix("--orchestration=") || $0.hasPrefix("--panes=") || $0.hasPrefix("--subagents=")
    }
    if !previewArguments.isEmpty && !previewDatabase {
        print("\(previewArguments.joined(separator: " ")) 는 AHC_DATABASE_PATH 로 연 임시 DB 에만 씁니다 — 건너뜀")
    }
    // `--models`: 모델 목록 캐시. 오프라인 미리보기(AHC_OFFLINE=1)는 목록을 조회하지 않으므로, CLI 가 주는 형식의 **고정 응답**을
    // 앱의 해석기(parseClaudeModelResponse · parseCodexModels · parseGeminiModelResponse)로 읽어 넣는다.
    // Claude 응답은 OfflineTests 의 실측 응답과 같고, Codex 모델별 강도 · Antigravity 목록은 화면 확인용 고정 값이다.
    if previewDatabase, CommandLine.arguments.contains("--models") {
        let claudeJSON = #"""
        {"is_error": false, "subtype": "success",
         "result": "Current model: `Opus 5` (effort: high)\nUsage: /model <name>. Available: sonnet, opus, haiku, fable, best, sonnet[1m], opus[1m], fable[1m], opusplan, default, or a full model ID."}
        """#
        let claude = ModelCatalog.parseClaudeModelResponse(claudeJSON, into: ModelCatalogSnapshot(provider: .claude))
        func efforts(_ values: [String]) -> [[String: Any]] { values.map { ["reasoningEffort": $0] } }
        let codex = ModelCatalog.parseCodexModels([
            ["id": "gpt-6-astra", "displayName": "GPT-6 Astra",
             "supportedReasoningEfforts": efforts(["low", "medium", "high", "xhigh", "max", "ultra"])],
            ["id": "gpt-6-sol", "displayName": "GPT-6 Sol",
             "supportedReasoningEfforts": efforts(["low", "medium", "high", "xhigh", "max", "ultra"])],
            ["id": "gpt-6-luna", "displayName": "GPT-6 Luna",
             "supportedReasoningEfforts": efforts(["low", "medium", "high", "xhigh", "max"])],
            ["id": "gpt-5.6-sol", "displayName": "GPT-5.6 Sol", "isDefault": true,
             "supportedReasoningEfforts": efforts(["low", "medium", "high", "xhigh"])],
            ["id": "gpt-5.6-terra", "displayName": "GPT-5.6 Terra",
             "supportedReasoningEfforts": efforts(["low", "medium", "high"])],
            ["id": "gpt-5.6-luna", "displayName": "GPT-5.6 Luna", "supportedReasoningEfforts": efforts(["low", "medium"])],
            ["id": "gpt-5.5", "displayName": "GPT-5.5", "supportedReasoningEfforts": efforts(["low", "medium", "high"])],
        ])
        let gemini = ModelCatalog.parseGeminiModelResponse(
            ["gemini-3.8-flash-low\tGemini 3.8 Flash (Low)", "gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)",
             "gemini-3.8-flash-high\tGemini 3.8 Flash (High)", "gemini-3.1-pro-low\tGemini 3.1 Pro (Low)",
             "gemini-3.1-pro-high\tGemini 3.1 Pro (High)"].joined(separator: "\n"),
            into: ModelCatalogSnapshot(provider: .gemini))
        try await store.replaceModelOptions(claude.options, scope: .claude)
        try await store.replaceModelOptions(codex, scope: .codex(CodexAccount.defaultID))
        try await store.replaceModelOptions(gemini.options, scope: .gemini)
        print("모델 목록 캐시: Claude \(claude.options.count) · Codex \(codex.count) · Antigravity \(gemini.options.count)")
    }
    // `--events=<개수>` — 첫 스레드에 대화 행을 넣는다 (긴 단어 · 코드 줄 · 접힌 도구 결과가 섞인 화면 확인용 고정 문장).
    // 구분선 드래그 재현(`-preview.sweepDivider`)처럼 본문에 실제 행이 있어야 하는 확인에 쓴다.
    if previewDatabase, let spec = CommandLine.arguments.first(where: { $0.hasPrefix("--events=") }),
       let count = Int(spec.dropFirst("--events=".count)), count > 0,
       let thread = try await store.threads(projectID: project.id).first {
        let longToken = String(repeating: "handoff_console_unbroken_identifier_", count: 4)
        for index in 0..<count {
            let event: ThreadEvent
            switch index % 4 {
            case 0:
                event = ThreadEvent(threadID: thread.id, kind: .userMessage,
                                    text: "\(index + 1)번째 요청: 변경사항 탭의 커밋 목록을 다시 확인하고 정리해 주세요.")
            case 1:
                event = ThreadEvent(threadID: thread.id, kind: .agentMessage, provider: .claude,
                                    text: "확인했습니다. 관련 식별자는 `\(longToken)\(index)` 이고, 아래 파일을 봅니다.\n\n```swift\nlet value = WorkspaceModel.shared.refreshGit(project: selectedProject, branch: currentBranch, includingUntracked: true) // \(index)\n```")
            case 2:
                event = ThreadEvent(threadID: thread.id, kind: .toolResult, provider: .claude, title: "Read ChangesPane.swift",
                                    text: (1...40).map { "line \($0): \(longToken)" }.joined(separator: "\n"))
            default:
                event = ThreadEvent(threadID: thread.id, kind: .commandExecution, provider: .claude, title: "git status --porcelain=v2",
                                    text: "1 .M N... 100644 100644 100644 abc def Moa/Auth/AuthViewModel.swift")
            }
            _ = try await store.appendEvent(event)
        }
        print("대화 행 \(count)개 추가")
    }
    // `--handoff` — 첫 스레드(가장 먼저 만든 것 — `--panes=` 의 첫 칸 · 포커스 칸)에 Claude 가 일한 기록: 끝난 실행 하나(파일 편집)와
    // 사용 한도에 닿아 멈춘 실행 하나(테스트 실패 · 한도 안내). 인계 카드는 기록이 있는 대화에만 놓인다 — 앱의
    // `-preview.action handoff…` 와 함께 쓴다.
    if previewDatabase, CommandLine.arguments.contains("--handoff"),
       var thread = try await store.threads(projectID: project.id).min(by: { $0.createdAt < $1.createdAt }) {
        thread.title = "로그인 401 재시도 처리"
        thread.goal = "토큰이 만료되면 한 번 갱신하고 다시 시도 — 실패하면 로그아웃"
        thread.preferredProvider = .claude
        try await store.upsertThread(thread)
        let session = try await store.ensureSession(threadID: thread.id, provider: .claude, accountID: "")
        let now = Date()
        let first = Run(threadID: thread.id, sessionID: session.id, provider: .claude,
                        requestText: "토큰이 만료되면 AuthViewModel 에서 한 번 갱신하고 다시 시도하게 해 줘.", state: .completed,
                        startedAt: now.addingTimeInterval(-900), endedAt: now.addingTimeInterval(-840),
                        terminalReason: "completed", model: "claude-opus-5-5")
        try await store.insertRun(first)
        func add(_ run: Run, _ kind: EventKind, _ title: String = "", _ text: String, payload: String? = nil, ago: Double) async throws {
            _ = try await store.appendEvent(ThreadEvent(threadID: thread.id, runID: run.id, kind: kind,
                                                        provider: kind == .userMessage ? nil : .claude, title: title, text: text,
                                                        payloadJSON: payload, createdAt: now.addingTimeInterval(-ago)))
        }
        try await add(first, .userMessage, "사용자", first.requestText, ago: 900)
        try await add(first, .fileChange, "Moa/Auth/AuthViewModel.swift", "Moa/Auth/AuthViewModel.swift",
                      payload: #"{"status":"completed"}"#, ago: 870)
        try await add(first, .agentMessage, "Claude",
                      "`AuthViewModel.refresh()` 에 한 번 다시 시도를 넣고, 갱신이 실패하면 `signOut()` 을 부르게 했습니다.", ago: 845)
        let second = Run(threadID: thread.id, sessionID: session.id, provider: .claude,
                         requestText: "로그인 화면에도 갱신 중 표시를 붙이고 테스트도 돌려 줘.", state: .rateLimited,
                         startedAt: now.addingTimeInterval(-300), endedAt: now.addingTimeInterval(-240),
                         terminalReason: "rate_limited", model: "claude-opus-5-5", errorMessage: "Claude usage limit reached.")
        try await store.insertRun(second)
        try await add(second, .userMessage, "사용자", second.requestText, ago: 300)
        try await add(second, .fileChange, "Moa/Login/LoginView.swift", "Moa/Login/LoginView.swift",
                      payload: #"{"status":"completed"}"#, ago: 280)
        try await add(second, .commandExecution, "swift test --filter AuthTests",
                      "swift test --filter AuthTests\n\n--- 출력 ---\nTest Case 'AuthTests.testRefreshRetriesOnce' failed",
                      payload: #"{"status":"failed","exitCode":1}"#, ago: 260)
        try await add(second, .error, LimitStatus.subscriptionCap.koreanName, "Claude usage limit reached. 20:30 에 초기화됩니다.", ago: 245)
        print("인계 기록: 끝난 실행 1 · 한도로 멈춘 실행 1")
    }
    // `--history` — 첫 스레드에 Claude 가 일한 기록: 끝난 실행 둘 (한도 안내 없이 — 마지막 메인 이벤트가 한도 안내면 이어 가기 제안이
    // 숨는다). 이어 가기 제안 줄(`-preview.limits`) · 칩 메뉴의 이어 맡기기 행(`-preview.action providerMenu`)을 볼 때.
    if previewDatabase, CommandLine.arguments.contains("--history"),
       var thread = try await store.threads(projectID: project.id).min(by: { $0.createdAt < $1.createdAt }) {
        thread.title = "로그인 401 재시도 처리"
        thread.goal = "토큰이 만료되면 한 번 갱신하고 다시 시도 — 실패하면 로그아웃"
        thread.preferredProvider = .claude
        try await store.upsertThread(thread)
        let session = try await store.ensureSession(threadID: thread.id, provider: .claude, accountID: "")
        let now = Date()
        func add(_ run: Run, _ kind: EventKind, _ title: String = "", _ text: String, payload: String? = nil, ago: Double) async throws {
            _ = try await store.appendEvent(ThreadEvent(threadID: thread.id, runID: run.id, kind: kind,
                                                        provider: kind == .userMessage ? nil : .claude, title: title, text: text,
                                                        payloadJSON: payload, createdAt: now.addingTimeInterval(-ago)))
        }
        let first = Run(threadID: thread.id, sessionID: session.id, provider: .claude,
                        requestText: "토큰이 만료되면 AuthViewModel 에서 한 번 갱신하고 다시 시도하게 해 줘.", state: .completed,
                        startedAt: now.addingTimeInterval(-1500), endedAt: now.addingTimeInterval(-1440),
                        terminalReason: "completed", model: "claude-opus-5-5")
        try await store.insertRun(first)
        try await add(first, .userMessage, "사용자", first.requestText, ago: 1500)
        try await add(first, .fileChange, "Moa/Auth/AuthViewModel.swift", "Moa/Auth/AuthViewModel.swift",
                      payload: #"{"status":"completed"}"#, ago: 1470)
        try await add(first, .agentMessage, "Claude",
                      "`AuthViewModel.refresh()` 에 한 번 다시 시도를 넣고, 갱신이 실패하면 `signOut()` 을 부르게 했습니다.", ago: 1445)
        let second = Run(threadID: thread.id, sessionID: session.id, provider: .claude,
                         requestText: "로그인 화면에도 갱신 중 표시를 붙이고 테스트도 돌려 줘.", state: .completed,
                         startedAt: now.addingTimeInterval(-420), endedAt: now.addingTimeInterval(-300),
                         terminalReason: "completed", model: "claude-opus-5-5")
        try await store.insertRun(second)
        try await add(second, .userMessage, "사용자", second.requestText, ago: 420)
        try await add(second, .fileChange, "Moa/Login/LoginView.swift", "Moa/Login/LoginView.swift",
                      payload: #"{"status":"completed"}"#, ago: 390)
        try await add(second, .commandExecution, "swift test --filter AuthTests",
                      "swift test --filter AuthTests\n\n--- 출력 ---\nExecuted 6 tests, with 0 failures",
                      payload: #"{"status":"completed","exitCode":0}"#, ago: 330)
        try await add(second, .agentMessage, "Claude",
                      "로그인 화면에 갱신 중 표시를 붙였고 `AuthTests` 6개가 모두 통과했습니다. 다음은 토큰 갱신 실패 화면을 다듬을 차례입니다.",
                      ago: 305)
        print("Claude 기록: 끝난 실행 2")
    }
    // `--codex-history` — 첫 스레드에 Codex(기본 계정)가 일한 기록: 끝난 실행 하나, 칩도 Codex. 보내는 쪽이 Codex 일 때의 칩 메뉴
    // (`--codex-accounts` 와 함께 — 다른 계정 행 = "같은 세션을 이 계정으로 이어 갑니다") · 계정 바꾸기 카운트다운(`-preview.codexSwitch YES`)을 볼 때.
    if previewDatabase, CommandLine.arguments.contains("--codex-history"),
       var thread = try await store.threads(projectID: project.id).min(by: { $0.createdAt < $1.createdAt }) {
        thread.title = "결제 웹훅 재시도"
        thread.preferredProvider = .codex
        thread.codexAccountID = CodexAccount.defaultID
        try await store.upsertThread(thread)
        let session = try await store.ensureSession(threadID: thread.id, provider: .codex)
        let now = Date()
        var run = Run(threadID: thread.id, sessionID: session.id, provider: .codex,
                      requestText: "결제 웹훅이 실패하면 지수 백오프로 세 번까지 다시 보내게 해 줘.", state: .completed,
                      startedAt: now.addingTimeInterval(-600), endedAt: now.addingTimeInterval(-540),
                      terminalReason: "completed", model: "gpt-5.6-sol")
        run.codexAccountID = CodexAccount.defaultID
        try await store.insertRun(run)
        _ = try await store.appendEvent(ThreadEvent(threadID: thread.id, runID: run.id, kind: .userMessage, title: "사용자",
                                                    text: run.requestText, createdAt: now.addingTimeInterval(-600)))
        _ = try await store.appendEvent(ThreadEvent(threadID: thread.id, runID: run.id, kind: .agentMessage, provider: .codex,
                                                    text: "`WebhookSender` 에 지수 백오프(1 · 2 · 4초)로 세 번까지 다시 보내게 했습니다.",
                                                    createdAt: now.addingTimeInterval(-545)))
        print("Codex 기록: 끝난 실행 1")
    }
    // `--execlog` — 첫 스레드에 실행 기록이 긴 대화: Claude 실행 하나(읽기 · 검색 · 설명이 붙은 명령 · 실패한 테스트 · 다시 돌려 통과)와
    // Codex 실행 하나(추론 요약의 머리 · 명령 · 실패 · 멈춘 명령). 실행 기록 접기(`ExecutionFold`)의 화면 확인용.
    if previewDatabase, CommandLine.arguments.contains("--execlog"),
       var thread = try await store.threads(projectID: project.id).min(by: { $0.createdAt < $1.createdAt }) {
        thread.title = "빌드 경고 정리와 테스트"
        thread.preferredProvider = .claude
        try await store.upsertThread(thread)
        let claudeSession = try await store.ensureSession(threadID: thread.id, provider: .claude, accountID: "")
        let codexSession = try await store.ensureSession(threadID: thread.id, provider: .codex, accountID: "")
        let now = Date()
        func add(_ run: Run, _ kind: EventKind, _ title: String = "", _ text: String, tool: String? = nil,
                 payload: String? = nil, ago: Double) async throws {
            _ = try await store.appendEvent(ThreadEvent(threadID: thread.id, runID: run.id, kind: kind,
                                                        provider: kind == .userMessage ? nil : run.provider, title: title,
                                                        text: text, payloadJSON: payload, toolUseID: tool,
                                                        createdAt: now.addingTimeInterval(-ago)))
        }
        func bash(_ run: Run, _ id: String, _ command: String, _ description: String, output: String, error: Bool = false,
                  ago: Double) async throws {
            try await add(run, .toolRequest, "Bash", JSONUtil.prettyString(["command": command, "description": description]),
                          tool: id, ago: ago)
            try await add(run, .toolResult, error ? "Bash — 오류" : "Bash", output, tool: id, ago: ago - 2)
        }
        let claude = Run(threadID: thread.id, sessionID: claudeSession.id, provider: .claude,
                         requestText: "빌드 경고를 정리하고 테스트까지 돌려 줘.", state: .completed,
                         startedAt: now.addingTimeInterval(-1800), endedAt: now.addingTimeInterval(-1500),
                         terminalReason: "completed", model: "claude-opus-5-5")
        try await store.insertRun(claude)
        try await add(claude, .userMessage, "사용자", claude.requestText, ago: 1800)
        try await add(claude, .toolRequest, "Read", #"{"file_path":"\#(project.path)/Package.swift"}"#, tool: "r1", ago: 1795)
        try await add(claude, .toolResult, "Read", "// swift-tools-version: 6.0\nimport PackageDescription", tool: "r1", ago: 1794)
        try await add(claude, .toolRequest, "Grep", #"{"pattern":"deprecated","path":"\#(project.path)/Moa"}"#, tool: "g1", ago: 1790)
        try await add(claude, .toolResult, "Grep", "Moa/Auth/AuthViewModel.swift:42\nMoa/Login/LoginView.swift:18", tool: "g1", ago: 1789)
        try await bash(claude, "b1", "git status --short && git log --oneline -3", "Check working tree and recent commits",
                       output: " M Moa/Auth/AuthViewModel.swift\n57d83be docs: 계획\n488e8c7 docs: 후보", ago: 1785)
        try await add(claude, .agentMessage, "Claude", "경고 3개를 찾았습니다. 고친 뒤 빌드와 테스트를 확인하겠습니다.", ago: 1780)
        try await add(claude, .toolRequest, "Edit", JSONUtil.prettyString([
            "file_path": "\(project.path)/Moa/Auth/AuthViewModel.swift", "old_string": "let a = 1\nold()", "new_string": "let a = 1\nnew()"]),
                      tool: "e1", ago: 1760)
        try await add(claude, .toolResult, "Edit", "ok", tool: "e1", ago: 1759)
        try await bash(claude, "b2", "xcodebuild -project Moa.xcodeproj -scheme Moa -configuration Debug build 2>&1 | grep -E \"warning:|error:|BUILD\"",
                       "Verify build", output: "** BUILD SUCCEEDED **", ago: 1740)
        try await bash(claude, "b3", "swift test 2>&1 | grep -E \"✘|error:|Test run with\" | head -15", "Run test suite",
                       output: "✘ Test refreshRetriesOnce() recorded an issue at AuthTests.swift:88\nTest run with 51 tests failed after 4.2 seconds with 1 issue.",
                       error: true, ago: 1700)
        try await add(claude, .toolRequest, "Edit", JSONUtil.prettyString([
            "file_path": "\(project.path)/Moa/Auth/AuthViewModel.swift", "old_string": "retry(0)", "new_string": "retry(1)"]),
                      tool: "e2", ago: 1650)
        try await add(claude, .toolResult, "Edit", "ok", tool: "e2", ago: 1649)
        try await bash(claude, "b4", "swift test 2>&1 | grep -E \"✘|error:|Test run with\" | head -15", "Re-run test suite",
                       output: "Test run with 51 tests passed after 4.0 seconds.", ago: 1600)
        try await add(claude, .agentMessage, "Claude",
                      "실패한 `refreshRetriesOnce` 를 고쳤고, 다시 돌려 51개 모두 통과했습니다.", ago: 1520)

        let codex = Run(threadID: thread.id, sessionID: codexSession.id, provider: .codex,
                        requestText: "린트도 확인해 줘.", state: .completed,
                        startedAt: now.addingTimeInterval(-600), endedAt: now.addingTimeInterval(-420),
                        terminalReason: "completed", model: "gpt-6-sol")
        try await store.insertRun(codex)
        func command(_ id: String, _ text: String, output: String, status: String, exit: Int?, ago: Double) async throws {
            var fields: [String: Any] = ["status": status, "cwd": project.path]
            if let exit { fields["exitCode"] = exit }
            let payload = JSONUtil.string(fields)
            try await add(codex, .commandExecution, text, text + ExecutionParser.outputMarker + output, tool: id, payload: payload, ago: ago)
        }
        try await add(codex, .userMessage, "사용자", codex.requestText, ago: 600)
        try await add(codex, .agentReasoning, "", "**Inspecting lint configuration**", ago: 590)
        try await command("c1", "rg -n \"swiftlint\" .swiftlint.yml Package.swift", output: ".swiftlint.yml:1:disabled_rules:",
                          status: "completed", exit: 0, ago: 585)
        try await add(codex, .agentReasoning, "", "**Inspecting lint configuration**\n**Running strict lint checks**", ago: 570)
        try await command("c2", "swiftlint lint --strict --quiet", output: "Moa/Login/LoginView.swift:18:5: error: Line Length Violation",
                          status: "failed", exit: 2, ago: 560)
        try await command("c3", "swiftlint lint --strict --quiet Moa/Login", output: "", status: "interrupted", exit: nil, ago: 500)
        try await add(codex, .agentMessage, "Codex", "LoginView.swift 18행이 줄 길이 규칙에 걸립니다. 고칠까요?", ago: 425)
        print("실행 기록: Claude 실행 1 · Codex 실행 1")
    }
    // `--selection=<claude|codex|gemini>:<모델 ID>:<강도>` — 첫 스레드가 보낼 에이전트와 그 선택. 강도가 비면 nil (CLI 기본값).
    if previewDatabase, let spec = CommandLine.arguments.first(where: { $0.hasPrefix("--selection=") }),
       var thread = try await store.threads(projectID: project.id).first {
        let parts = spec.dropFirst("--selection=".count).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let provider = parts.first.flatMap(AgentProvider.init(rawValue:)) else {
            FileHandle.standardError.write(Data("--selection 의 제공자는 claude|codex|gemini 중 하나입니다: \(spec)\n".utf8))
            exit(2)
        }
        let model = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        let effort = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        thread.preferredProvider = provider
        thread.setSelection(ModelSelection(model: model, effort: effort), for: provider)
        try await store.upsertThread(thread)
        print("선택: \(provider.rawValue) · \(model ?? "모델 기본") · \(effort ?? "강도 기본(nil)")")
    }
    // `--orchestration=<running|approval|blocked|clarify>` — 첫 스레드에 자동 작업을 그 상태로 넣는다 (작업 카드 확인용).
    // 자동 작업 설정도 켠다 (입력창의 "자동"). 상태는 화면용으로 직접 적는다 — 전이 규칙을 거치지 않는다.
    if previewDatabase, let spec = CommandLine.arguments.first(where: { $0.hasPrefix("--orchestration=") }),
       let thread = try await store.threads(projectID: project.id).first {
        let mode = String(spec.dropFirst("--orchestration=".count))
        var settings = OrchestrationSettings()
        settings.enabled = true
        try await store.setSetting(OrchestrationSettings.storageKey, String(data: try JSONEncoder().encode(settings), encoding: .utf8)!)
        func planned(_ id: String, _ title: String, _ kind: TaskKind, _ difficulty: Int, _ deps: [String], optional: Bool = false) -> PlannedTask {
            PlannedTask(id: id, title: title, specification: title + " — 목적 · 입력 · 산출물", kind: kind, difficulty: difficulty,
                        dependsOn: deps, acceptance: ["완료 조건"], verification: "inttest offline", paths: [], optional: optional)
        }
        var plan = OrchestrationPlan(goal: "설정 창을 여닫을 때 나는 크래시를 고치고 회귀 테스트를 추가", assumptions: [], openQuestions: [],
                                     needsDecomposition: true, infoSufficient: mode != "clarify",
                                     tasks: [planned("t1", "크래시 재현 조건과 로그 확보", .debug, 3, []),
                                             planned("t2", "설정 창의 생성 · 해제 경로에서 원인 수정", .debug, 4, ["t1"]),
                                             planned("t3", "여닫기 반복 회귀 테스트 추가", .implement, 2, ["t2"]),
                                             planned("t4", "검증 기록 문서에 원인과 수정 요약", .implement, 1, ["t3"], optional: true)],
                                     finalAcceptance: ["설정 창을 50번 여닫아도 크래시가 없다"])
        if mode == "clarify" { plan.openQuestions = ["크래시 로그나 재현 절차가 있나요?", "어느 macOS 버전에서 나나요?"] }
        var job = OrchestrationJob(projectID: project.id, parentThreadID: thread.id, request: plan.goal)
        job.state = .planning
        try await store.insertOrchestrationJob(job)
        job.activePlanVersion = 1
        job.state = mode == "approval" ? .ready : (mode == "clarify" ? .awaitingUser : .ready)
        let tasks = OrchestrationTask.make(from: plan, jobID: job.id, planVersion: 1)
        try await store.installOrchestrationPlan(job: job, plan: plan, tasks: tasks, plannerRunID: nil, cause: "화면 확인용")
        if mode == "running" || mode == "blocked" {
            // 계획 · 검토 담당의 내부 대화 — 작업 카드의 "계획 기록 · 검토 기록" 줄을 볼 수 있게 (검토단이면 제공자마다 하나).
            for (role, provider, title) in [("planner", AgentProvider.claude, "계획"), ("reviewer", .claude, "검토 · Claude Sonnet"),
                                            ("reviewer", .codex, "검토 · Codex Terra")] {
                var inner = ConversationThread(projectID: project.id, title: title + " — " + plan.goal.prefix(40))
                inner.orchestrationJobID = job.id
                inner.orchestrationRole = role
                inner.preferredProvider = provider
                try await store.upsertThread(inner)
            }
            func attempt(_ task: OrchestrationTask, _ n: Int, _ kind: AttemptKind, _ profile: String, _ state: AttemptState,
                         _ failure: FailureClass? = nil) -> OrchestrationAttempt {
                OrchestrationAttempt(taskID: task.id, jobID: job.id, number: n, kind: kind, profileID: profile, generation: 0,
                                     state: state, failureClass: failure)
            }
            let second: AttemptState = mode == "running" ? .running : .failed
            try await store.applyOrchestration(OrchestrationChanges(cause: "화면 확인용", newAttempts: [
                attempt(tasks[0], 1, .first, "claude-sonnet", .succeeded),
                attempt(tasks[1], 1, .first, "claude-opus", .failed, .verificationFailed),
                attempt(tasks[1], 2, .retry, "claude-opus", second, mode == "running" ? nil : .environment),
            ]), jobID: job.id)
            try await store.db.run("UPDATE orchestration_task SET state = 'succeeded' WHERE id = ?;", [.text(tasks[0].id)])
            try await store.db.run("UPDATE orchestration_task SET state = ?, blocked_reason = ? WHERE id = ?;",
                                   [.text(mode == "running" ? "running" : "blocked"),
                                    mode == "running" ? .null : .text("환경 문제 (권한 · 인증 · 도구): Claude 로그인이 필요합니다"),
                                    .text(tasks[1].id)])
            try await store.db.run("UPDATE orchestration_job SET state = ? WHERE id = ?;",
                                   [.text(mode == "running" ? "running" : "awaitingUser"), .text(job.id)])
        }
        for line in ["자동 작업을 시작합니다. 먼저 계획을 세웁니다.", "계획을 세웠습니다 — 작업 4개:\n1. 크래시 재현 조건과 로그 확보\n2. 설정 창의 생성 · 해제 경로에서 원인 수정\n3. 여닫기 반복 회귀 테스트 추가\n4. 검증 기록 문서에 원인과 수정 요약"] {
            _ = try await store.appendEvent(ThreadEvent(threadID: thread.id, kind: .systemNotice, title: "자동 작업", text: line,
                                                        payloadJSON: JSONUtil.string(["type": "orchestration", "jobID": job.id])))
        }
        print("자동 작업(\(mode)) 추가: \(job.id)")
    }
    // `--panes=<2|4>` — 분할 화면. 앞에서부터 그 수만큼의 스레드를 칸에 연다 (`--threads=` 로 스레드를 먼저 채운다). 마지막 칸은
    // 빈 칸으로 둔다 (빈 칸 안내를 보려고). 둘째 스레드부터는 짧은 대화를 넣어 칸마다 다른 내용이 보이게 한다.
    if previewDatabase, let spec = CommandLine.arguments.first(where: { $0.hasPrefix("--panes=") }),
       let count = Int(spec.dropFirst("--panes=".count)), count == 2 || count == 4 {
        let threads = try await store.threads(projectID: project.id).sorted { $0.createdAt < $1.createdAt }
        var ids: [String?] = threads.prefix(count - 1).map { Optional($0.id) }
        ids += Array(repeating: nil, count: count - ids.count)
        for (index, thread) in threads.prefix(count - 1).enumerated() where index > 0 {
            _ = try await store.appendEvent(ThreadEvent(threadID: thread.id, kind: .userMessage, title: "사용자",
                                                        text: "\(index + 1)번 칸의 요청: 로그인 화면의 오류 문구를 정리해 주세요."))
            _ = try await store.appendEvent(ThreadEvent(threadID: thread.id, kind: .agentMessage, provider: index % 2 == 0 ? .claude : .codex,
                                                        title: index % 2 == 0 ? "Claude" : "Codex",
                                                        text: "확인했습니다. `LoginView.swift` 의 문구 세 곳을 같은 말투로 맞췄습니다."))
        }
        try await store.setSetting("pane_layout", count == 2 ? PaneLayout.twoColumns.rawValue : PaneLayout.fourGrid.rawValue)
        try await store.setSetting("pane_threads", String(data: try JSONEncoder().encode(ids), encoding: .utf8)!)
        try await store.setSetting("pane_focused", "0")
        print("분할 화면 \(count)칸: \(ids.compactMap { $0 }.count)개 대화 + 빈 칸")
    }
    // `--subagents=done` — 첫 스레드에 하위 작업을 띄운 **끝난** 실행 하나를 넣는다 (대화의 "하위 에이전트 N" 카드 · 인스펙터
    // "에이전트" 탭 확인용). Claude 식: 메인의 Agent 호출 둘(앵커) · 하위마다 부모 표시가 붙은 흐름 · 끝난 하위 상태 행, 그리고
    // 앱이 끝을 보고받지 못한 백그라운드 명령 하나(끝난 실행 안의 `running` → "끝나지 않음"). 실행은 끝난 상태로만 저장한다
    // (활성으로 저장하면 이전 실행 정리 안내가 뜬다). 기다리는 중의 화면은 앱의 `-preview.action subagents` 로 본다.
    // 쉼표로 여럿: `--subagents=done,fanout`. `fanout` 은 아래.
    let subAgentSeeds = Set((CommandLine.arguments.first { $0.hasPrefix("--subagents=") }?
        .dropFirst("--subagents=".count).split(separator: ",").map(String.init)) ?? [])
    if previewDatabase, subAgentSeeds.contains("done"), let thread = try await store.threads(projectID: project.id).first {
        let now = Date()
        let session = try await store.ensureSession(threadID: thread.id, provider: .claude, accountID: "")
        let run = Run(threadID: thread.id, sessionID: session.id, provider: .claude,
                      requestText: "로그인 오류 문구를 정리하고 쓰는 곳을 모두 찾아 줘", state: .completed,
                      startedAt: now.addingTimeInterval(-240), endedAt: now.addingTimeInterval(-30),
                      terminalReason: "completed", model: "claude-opus-5")
        try await store.insertRun(run)
        var clock = -240.0
        func add(_ kind: EventKind, _ title: String = "", _ text: String, parent: String? = nil, toolUseID: String? = nil,
                 payload: String? = nil, id: String? = nil) async throws {
            clock += 4
            var event = ThreadEvent(threadID: thread.id, runID: run.id, kind: kind, provider: kind == .userMessage ? nil : .claude,
                                    title: title, text: text, payloadJSON: payload, toolUseID: toolUseID,
                                    createdAt: now.addingTimeInterval(clock))
            if let id { event.id = id }
            if let parent { event.payloadJSON = ThreadEvent.payload(payload, taggingParent: parent) }
            _ = try await store.appendEvent(event)
        }
        func status(_ info: SubAgentInfo) async throws {
            try await add(.subAgent, info.title, info.summary ?? "", payload: info.jsonString,
                          id: ThreadEvent.subAgentEventID(runID: run.id, agentID: info.id))
        }
        let login = (path as NSString).appendingPathComponent("Moa/Login/LoginView.swift")
        try await add(.userMessage, "사용자", "로그인 화면의 오류 문구를 정리하고, 같은 문구를 쓰는 곳을 모두 찾아 줘. 둘로 나눠서 해 줘.")
        // 테스트는 뒤에서 돌려 두고 (앱이 끝을 보고받지 못한 채 실행이 끝났다 — 끝나지 않음), 하위 에이전트 둘에게 나눠 맡긴다.
        try await add(.toolRequest, "Bash", #"{"command":"swift test --filter LoginTests","run_in_background":true,"description":"로그인 테스트"}"#,
                      toolUseID: "toolu_tests")
        try await add(.toolResult, "도구 결과", "Command running in background with ID: bash_1", toolUseID: "toolu_tests")
        try await status(SubAgentInfo(id: "toolu_tests", taskID: "bash_1", kind: .shell, title: "swift test --filter LoginTests",
                                      detail: "로그인 테스트", isBackground: true, startedAt: now.addingTimeInterval(-232)))
        try await add(.agentMessage, "Claude", "테스트를 뒤에서 돌려 두고, 두 하위 에이전트에게 나눠 맡기겠습니다 — 하나는 문구를 쓰는 곳을 찾고, 하나는 로그인 화면을 고칩니다.")
        try await add(.toolRequest, "Agent", #"{"description":"오류 문구 쓰는 곳 찾기","subagent_type":"Explore","prompt":"로그인 오류 문구를 쓰는 파일을 모두 찾아라"}"#,
                      toolUseID: "toolu_find")
        try await add(.toolRequest, "Agent", #"{"description":"로그인 화면 문구 정리","subagent_type":"general-purpose","prompt":"LoginView 의 오류 문구를 같은 말투로 고쳐라"}"#,
                      toolUseID: "toolu_fix")
        let findAnswer = "세 곳에서 씁니다.\n\n- `Moa/Login/LoginView.swift` 42 · 57행\n- `Moa/Auth/AuthViewModel.swift` 88행"
        let fixAnswer = "`LoginView.swift` 의 오류 문구 세 곳을 \"~하지 못했습니다\" 말투로 맞췄습니다."
        try await status(SubAgentInfo(id: "toolu_find", taskID: "task_find", kind: .agent, title: "오류 문구 쓰는 곳 찾기",
                                      detail: "Explore", isBackground: false, status: .completed,
                                      startedAt: now.addingTimeInterval(-212), endedAt: now.addingTimeInterval(-150),
                                      totalTokens: 18_400, toolUses: 3, summary: findAnswer, model: "claude-haiku-4-5-20251001"))
        try await status(SubAgentInfo(id: "toolu_fix", taskID: "task_fix", kind: .agent, title: "로그인 화면 문구 정리",
                                      detail: "general-purpose", isBackground: false, status: .completed,
                                      startedAt: now.addingTimeInterval(-208), endedAt: now.addingTimeInterval(-96),
                                      totalTokens: 26_900, toolUses: 4, summary: fixAnswer, model: "claude-opus-5"))
        try await add(.systemNotice, "안내", "요청: 로그인 오류 문구를 쓰는 파일을 모두 찾아라", parent: "toolu_find")
        try await add(.systemNotice, "안내", "요청: LoginView 의 오류 문구를 같은 말투로 고쳐라", parent: "toolu_fix")
        try await add(.toolRequest, "Grep", #"{"pattern":"로그인에 실패","path":"Moa"}"#, parent: "toolu_find", toolUseID: "toolu_f1")
        try await add(.toolRequest, "Read", "{\"file_path\":\"\(login)\"}", parent: "toolu_fix", toolUseID: "toolu_x1")
        try await add(.toolResult, "도구 결과", "Moa/Login/LoginView.swift:42\nMoa/Login/LoginView.swift:57\nMoa/Auth/AuthViewModel.swift:88",
                      parent: "toolu_find", toolUseID: "toolu_f1")
        try await add(.toolResult, "도구 결과", "40\tText(\"로그인에 실패했어요\")", parent: "toolu_fix", toolUseID: "toolu_x1")
        try await add(.toolRequest, "Read", #"{"file_path":"Moa/Auth/AuthViewModel.swift"}"#, parent: "toolu_find", toolUseID: "toolu_f2")
        try await add(.toolResult, "도구 결과", "88\terror = \"로그인에 실패했어요\"", parent: "toolu_find", toolUseID: "toolu_f2")
        try await add(.toolRequest, "Edit", "{\"file_path\":\"\(login)\",\"old_string\":\"로그인에 실패했어요\",\"new_string\":\"로그인하지 못했습니다\"}",
                      parent: "toolu_fix", toolUseID: "toolu_x2")
        try await add(.toolResult, "도구 결과", "The file has been updated.", parent: "toolu_fix", toolUseID: "toolu_x2")
        try await add(.toolRequest, "Bash", #"{"command":"git diff --stat"}"#, parent: "toolu_fix", toolUseID: "toolu_x3")
        try await add(.toolResult, "도구 결과", " Moa/Login/LoginView.swift | 6 +++---", parent: "toolu_fix", toolUseID: "toolu_x3")
        try await add(.agentMessage, "Claude", findAnswer, parent: "toolu_find")
        try await add(.toolResult, "도구 결과", findAnswer, toolUseID: "toolu_find")
        try await add(.agentMessage, "Claude", fixAnswer, parent: "toolu_fix")
        try await add(.toolResult, "도구 결과", fixAnswer, toolUseID: "toolu_fix")
        try await add(.agentMessage, "Claude", "정리했습니다. 문구를 쓰는 곳은 세 곳이고, `LoginView.swift` 의 세 문구를 같은 말투로 바꿨습니다. `AuthViewModel.swift` 88행은 다음에 맞추면 됩니다.")
        try await store.upsertUsage(UsageRecord(runID: run.id, threadID: thread.id, provider: .claude, model: "claude-opus-5",
                                                inputTokens: 1_820, cacheReadTokens: 41_200, cacheWriteTokens: 3_400,
                                                outputTokens: 2_610, durationMs: 210_000, costUSD: 0.41, costSource: .cliReported))
        print("하위 작업이 있는 끝난 실행 추가: \(run.id)")
    }
    // `--subagents=fanout` — 백그라운드 하위 에이전트 다섯이 저마다 앞에서 `sleep 10` 을 돌리고(CLI 는 이 셸도 작업으로 알린다 —
    // 목록 · 카드에 따로 나오지 않아야 한다), 여섯째가 뒤에서 도는 셸을 띄운 끝난 실행 (2026-09-24 실측 모양). 에이전트 탭의
    // 목록이 세로로 길어져 스크롤되는지, 하위가 띄운 백그라운드 명령이 그 하위 아래에 들어가는지 본다. `done` 과 함께 주면
    // 실행 머리도 보인다.
    if previewDatabase, subAgentSeeds.contains("fanout"), let thread = try await store.threads(projectID: project.id).first {
        let now = Date()
        let session = try await store.ensureSession(threadID: thread.id, provider: .claude, accountID: "")
        let run = Run(threadID: thread.id, sessionID: session.id, provider: .claude,
                      requestText: "하위 에이전트 다섯을 띄워 저마다 10초 기다리게 해 줘", state: .completed,
                      startedAt: now.addingTimeInterval(-20), endedAt: now.addingTimeInterval(-2),
                      terminalReason: "completed", model: "claude-sonnet-5")
        try await store.insertRun(run)
        var clock = -20.0
        func add(_ kind: EventKind, _ title: String = "", _ text: String, parent: String? = nil, toolUseID: String? = nil,
                 payload: String? = nil, id: String? = nil) async throws {
            clock += 0.2
            var event = ThreadEvent(threadID: thread.id, runID: run.id, kind: kind, provider: kind == .userMessage ? nil : .claude,
                                    title: title, text: text, payloadJSON: payload, toolUseID: toolUseID,
                                    createdAt: now.addingTimeInterval(clock))
            if let id { event.id = id }
            if let parent { event.payloadJSON = ThreadEvent.payload(payload, taggingParent: parent) }
            _ = try await store.appendEvent(event)
        }
        func status(_ info: SubAgentInfo) async throws {
            try await add(.subAgent, info.title, info.summary ?? "", payload: info.jsonString,
                          id: ThreadEvent.subAgentEventID(runID: run.id, agentID: info.id))
        }
        try await add(.userMessage, "사용자", run.requestText)
        let agents = (1...5).map { ("toolu_wait\($0)", "10초 대기 테스트 \($0)") } + [("toolu_sleeper", "뒤에서 40초 기다리기")]
        for (id, title) in agents {
            try await add(.toolRequest, "Agent", "{\"description\":\"\(title)\",\"subagent_type\":\"general-purpose\",\"run_in_background\":true}",
                          toolUseID: id)
            try await add(.toolResult, "도구 결과", "Async agent launched successfully.", toolUseID: id)
        }
        try await add(.agentMessage, "Claude", "하위 에이전트 여섯을 뒤에서 띄웠습니다. 끝나면 정리하겠습니다.")
        for (index, (id, title)) in agents.enumerated() {
            let start = now.addingTimeInterval(-19 + Double(index) * 0.8)
            let end = start.addingTimeInterval(index == 5 ? 15 : 12)
            let shellID = "\(id)_bash"
            let background = index == 5
            try await add(.systemNotice, "안내", "요청: \(background ? "40초 걸리는 명령을 뒤에서 돌려 두고 끝나면 알려라" : "10초 기다린 뒤 끝났다고 답하라")",
                          parent: id)
            let input = background ? #"{"command":"sleep 40","description":"Sleep for 40 seconds","run_in_background":true}"#
                                   : (index < 2 ? #"{"command":"sleep 10"}"# : #"{"command":"sleep 10","description":"Sleep for 10 seconds"}"#)
            try await add(.toolRequest, "Bash", input, parent: id, toolUseID: shellID)
            try await add(.toolResult, "도구 결과", background ? "Command running in background with ID: b_sleeper" : "(Bash completed with no output)",
                          parent: id, toolUseID: shellID)
            try await status(SubAgentInfo(id: shellID, taskID: "b\(index)", kind: .shell,
                                          title: background || index >= 2 ? "Sleep for \(background ? 40 : 10) seconds" : "sleep 10",
                                          ownerID: id, isBackground: background, status: .completed,
                                          startedAt: start.addingTimeInterval(1), endedAt: end.addingTimeInterval(-1)))
            let answer = background ? "40초 명령이 끝났습니다." : "에이전트 \(index + 1) 완료"
            try await add(.agentMessage, "Claude", answer, parent: id)
            try await status(SubAgentInfo(id: id, taskID: "a\(index)", kind: .agent, title: title, detail: "general-purpose",
                                          isBackground: true, status: .completed, startedAt: start, endedAt: end,
                                          lastToolName: "Bash", totalTokens: 52_000 + index * 9_300, toolUses: 1, summary: answer,
                                          model: background ? "claude-sonnet-5" : (index % 2 == 0 ? "claude-haiku-4-5-20251001" : nil)))
        }
        try await add(.agentMessage, "Claude", "여섯 하위 에이전트가 모두 끝났습니다. 다섯은 10초씩 기다렸고, 하나는 뒤에서 40초 명령을 돌렸습니다.")
        try await store.upsertUsage(UsageRecord(runID: run.id, threadID: thread.id, provider: .claude, model: "claude-sonnet-5",
                                                inputTokens: 900, cacheReadTokens: 431_100, cacheWriteTokens: 22_200,
                                                outputTokens: 1_400, durationMs: 18_000, costUSD: 0.12, costSource: .cliReported))
        print("하위 에이전트 여섯 · 앞에서 돈 셸 다섯이 있는 끝난 실행 추가: \(run.id)")
    }
    // `--codex-accounts`: 두 번째 Codex 계정을 등록한다 (입력창의 계정 칩 · 인계 메뉴의 계정 대상을 볼 때). 홈은 임시 폴더 안의
    // 빈 폴더라 "로그인 필요" 계정으로 보인다. 기본 계정 행은 앱이 시작할 때 스스로 보장한다.
    if previewDatabase, CommandLine.arguments.contains("--codex-accounts") {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ahc-preview/codex-home-2").path
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let account = CodexAccount(id: "codex-preview-2", label: "계정2", homePath: home, sortOrder: 1)
        try await store.upsertCodexAccount(account)
        print("Codex 계정 추가: \(account.label) — \(home)")
    }
    await store.db.close()
    print("DB: \(Store.defaultDatabaseURL().path)")
    exit(0)
}

let t = TestKit()

print("Agent Handoff Console — 통합 검증")
print("실행 선택: \(selection.sorted().joined(separator: ", "))")
if let model = LiveTests.codexModelOverride {
    print("Codex 모델 지정: \(model)"
          + (LiveTests.codexEffortOverride.map { " · 추론 강도 \($0)" } ?? ""))
}
print("")

// 실제 대화 1개로 규칙 초안 vs Gemini 정리본 비교 (실제 대화가 Antigravity CLI 로 전송된다).
if let compare = GeminiCompare.options(Array(CommandLine.arguments.dropFirst())) {
    await GeminiCompare.run(t, compare)
}

// `inttest importscan` — 이 Mac 의 실제 Claude Code · Codex 기록을 훑어 폴더 목록과 걸린 시간을 찍는다 (읽기만 한다).
if want("importscan") {
    let started = Date()
    let folders = SessionImportScanner.scan()
    let elapsed = Date().timeIntervalSince(started)
    print(String(format: "스캔 %.1f초 — 폴더 %d개 (선별 %d개), 세션 %d개", elapsed, folders.count,
                 folders.filter(\.recommended).count, folders.reduce(0) { $0 + $1.sessions.count }))
    for folder in folders where folder.recommended {
        print("  \(folder.name)  claude \(folder.claudeCount) · codex \(folder.codexCount)  \(folder.path)")
    }
}

// 점검표의 화면 확인용 가드 확인 (`FirstRunTests.offlineGuards` 가 AHC_OFFLINE=1 로 이 실행 파일을 다시 띄운다).
if selection.contains("firstrunoffline") {
    await FirstRunTests.offlineProbe()
    exit(0)
}

if want("offline") || wantsAll {
    // 오프라인 시험은 실제 CLI 의 한도를 읽지 않는다 — 앱 모델이 실행 뒤에 부르는 한도 조회를 정해 둔 값(여유 있음)으로.
    TestEnv.offlineHarness(true)
    await OfflineTests.run(t)
    await WorkspaceTests.run(t)
    await GeminiAssistTests.run(t)
    await GitWriteTests.run(t)
    await ComposerTests.run(t)
    await MarkdownTests.run(t)
    await ImportTests.run(t)
    await MigrationTests.run(t)
    await TurnOptionsTests.run(t)
    await CodexReplayTests.run(t)
    await ClaudeReplayTests.run(t)
    await AntigravityStreamTests.run(t)
    await OrchestrationTests.run(t)
    await OrchestrationPolicyTests.run(t)
    await OrchestrationCoordinatorTests.run(t)
    await OrchestrationAppTests.run(t)
    await MultiRunAppTests.run(t)
    await PaneStatusTests.run(t)
    await OverviewTests.run(t)
    await FirstRunTests.run(t)
    await StreamFoldTests.run(t)
    await TypeScaleLintTests.run(t)
    await HandoffSafetyTests.run(t)
    await HandoffCardTests.run(t)
    await LimitLineTests.run(t)
    await AntigravityLimitsTests.run(t)
    await ContinueTests.run(t)
    await ContinueAppTests.run(t)
    await SubAgentRunTests.run(t)
    await SubAgentUITests.run(t)
    await ComposerFlowTests.run(t)
    await ThreadTitleTests.run(t)
    await SlashCommandTests.run(t)
    await ClaudeAPITests.run(t)
    await CodexSwitchTests.run(t)
    await OrbTests.run(t)
    await WorktreeTests.run(t)
    await ProcessTreeTests.run(t)
    TestEnv.offlineHarness(false)
}

// 입력창 "/" 목록만 (오프라인 묶음의 일부 — 고치는 동안 빨리 돌려 볼 때). offline 과 같은 하네스.
if want("slash") && !want("offline") {
    TestEnv.offlineHarness(true)
    await SlashCommandTests.run(t)
    TestEnv.offlineHarness(false)
}

// Claude API 키(월 API 크레딧)만 (오프라인 묶음의 일부 — 고치는 동안 빨리 돌려 볼 때). offline 과 같은 하네스.
if want("claudeapi") && !want("offline") {
    TestEnv.offlineHarness(true)
    await ClaudeAPITests.run(t)
    TestEnv.offlineHarness(false)
}

// Codex 계정끼리 바꾸기(같은 세션을 다른 계정으로)만 (오프라인 묶음의 일부 — 고치는 동안 빨리 돌려 볼 때). offline 과 같은 하네스.
if want("codexswitch") && !want("offline") {
    TestEnv.offlineHarness(true)
    await CodexSwitchTests.run(t)
    await MigrationTests.run(t)
    TestEnv.offlineHarness(false)
}

// 대화 제목 · 물려받은 환경만 (오프라인 묶음의 일부 — 고치는 동안 빨리 돌려 볼 때). offline 과 같은 하네스.
if want("titles") && !want("offline") {
    TestEnv.offlineHarness(true)
    await ThreadTitleTests.run(t)
    await OfflineTests.shellEnvironment(t)
    TestEnv.offlineHarness(false)
}

// 변경사항 · git · 독립 작업 폴더만 (오프라인 묶음의 일부 — 고치는 동안 빨리 돌려 볼 때). offline 과 같은 하네스.
if want("workspace") && !want("offline") {
    TestEnv.offlineHarness(true)
    await WorkspaceTests.run(t)
    await GitWriteTests.run(t)
    await WorktreeTests.run(t)
    await TypeScaleLintTests.run(t)
    TestEnv.offlineHarness(false)
}

// 인계 카드 · 대기열 보류 · 이어 가기만 (오프라인 묶음의 일부 — 고치는 동안 빨리 돌려 볼 때). offline 과 같은 하네스
// (실제 CLI · 한도를 부르지 않는다).
if want("handoffcard") && !want("offline") {
    TestEnv.offlineHarness(true)
    await HandoffSafetyTests.run(t)
    await HandoffCardTests.run(t)
    await LimitLineTests.run(t)
    await ContinueTests.run(t)
    await ContinueAppTests.run(t)
    await ComposerFlowTests.run(t)
    await PaneStatusTests.run(t)
    TestEnv.offlineHarness(false)
}

// Antigravity 한도(`agy -p /usage`)만 (오프라인 묶음의 일부 — 고치는 동안 빨리 돌려 볼 때). offline 과 같은 하네스.
if want("agylimits") && !want("offline") {
    TestEnv.offlineHarness(true)
    await AntigravityLimitsTests.run(t)
    TestEnv.offlineHarness(false)
}

// 에이전트 현황(가운데 칸 "현황")만 (오프라인 묶음의 일부 — 고치는 동안 빨리 돌려 볼 때).
if want("overview") && !want("offline") {
    TestEnv.offlineHarness(true)
    await OverviewTests.run(t)
    TestEnv.offlineHarness(false)
}

// 점 구의 레이어 칠하기 = 원본 렌더만 (오프라인 묶음의 일부).
// 승인 · 질문 카드와 도구 행의 승인 상태만 (오프라인 묶음의 일부 — 고치는 동안 빨리 돌려 볼 때).
// ("approval" 은 실제 CLI 를 부르는 묶음이라 이름을 따로 둔다.)
if want("approvalcards") && !want("offline") {
    TestEnv.offlineHarness(true)
    await ComposerFlowTests.run(t)
    await StreamFoldTests.run(t)
    await TurnOptionsTests.run(t)
    await SubAgentUITests.run(t)
    await ComposerTests.run(t)
    TestEnv.offlineHarness(false)
}

if want("orbs") && !want("offline") {
    await OrbTests.run(t)
}

if want("gemini") {
    await GeminiAssistTests.live(t)
}

if want("geminilarge") {
    await GeminiAssistTests.liveLarge(t)
}

// Antigravity 작업 에이전트 실측 (임시 프로젝트에서 파일 편집 1회 + 세션 재개 1회).
if want("antigravity") || wantsLive {
    await AntigravityLiveTests.run(t)
}

// 실제 AppModel 로 한도 도달 흉내 → 자동 인계 전 과정. Claude(haiku)로 짧은 전송 1회.
if want("autohandoff") || wantsLive {
    await AutoHandoffLiveTests.run(t)
}

// 여러 대화의 동시 실행 실측: 같은 폴더의 Claude 둘 · Claude + Codex · 같은 Codex 계정 둘 (haiku · gpt-5.6-luna low). 실제 한도를 쓴다.
// `live` 에는 넣지 않았다 — `inttest multirun` 으로만 돈다.
if selection.contains("multirun") {
    await MultiRunLiveTests.run(t)
}

// 하위 에이전트 · 백그라운드 작업 실측: Claude 백그라운드 Agent 의 후속 턴 · 대기 중 중단,
// Codex 하위 에이전트(메인이 기다림 · 기다리지 않음). **실제 CLI 를 부르고 구독 한도를 쓴다** (haiku · gpt-5.6-luna low, astra 는 쓰지 않는다).
// `live` · `all` 에는 넣지 않았다 — `inttest background` 로만 돈다.
if selection.contains("background") {
    await BackgroundLiveTests.run(t)
}

// 이어받은 세션에 남은 작업 알림 실측 (haiku 짧은 두 턴). `inttest staleresume` 으로만 돈다.
if selection.contains("staleresume") {
    await StaleResumeLiveTests.run(t)
}

// 공개 전 결함 수정(2026-10-09)의 실측 — 남는 백그라운드 명령 · 독립 작업 폴더 정리 뒤 이어 묻기 · 제목 요약의 자격.
// **실제 CLI 를 부르고 구독 한도를 쓴다** (haiku · gpt-5.6-luna low). `inttest releasefix` 로만 돈다.
if selection.contains("releasefix") {
    await ReleaseFixLiveTests.run(t)
} else if selection.contains("orphans") {
    await ReleaseFixLiveTests.runOrphans(t)
}

let liveGroups = ["env", "stream", "approval", "interrupt", "child", "handoff",
                  "resume", "limits", "coordinator", "model", "account", "accountswitch", "turnoptions", "orchestration"]
let anyLive = wantsLive || liveGroups.contains { want($0) }

if anyLive {
    let cli = await TestEnv.resolveCLI()
    guard let claude = cli.claude, let codex = cli.codex else {
        await t.check("CLI 실행 파일 탐색", false,
                      "claude=\(cli.claude ?? "없음") codex=\(cli.codex ?? "없음")")
        _ = await t.summary()
        exit(1)
    }
    let root = try TestEnv.makeTempProject("live")
    print("임시 테스트 프로젝트: \(root.path)\n")
    let env = LiveTests.Env(claude: claude, codex: codex, env: cli.env, root: root)

    if want("env") || wantsLive { await LiveTests.environmentChecks(t, env) }
    if want("limits") || wantsLive { await LiveTests.limits(t, env) }
    if want("account") || wantsLive { await LiveTests.codexAccounts(t, env) }
    if want("stream") || wantsLive { await LiveTests.streamingAndResume(t, env) }
    if want("approval") || wantsLive { await LiveTests.approvals(t, env) }
    if want("interrupt") || wantsLive { await LiveTests.interrupts(t, env) }
    if want("child") || wantsLive { await LiveTests.childProcesses(t, env) }
    if want("resume") || wantsLive { await LiveTests.resumeFailure(t, env) }
    if want("handoff") || wantsLive { await LiveTests.handoffRoundTrip(t, env) }
    if want("model") || wantsLive { await LiveTests.modelSelection(t, env) }
    if want("coordinator") || wantsLive { await CoordinatorTests.run(t, env) }
    if want("turnoptions") || wantsLive { await TurnOptionsLiveTests.run(t, env) }
    if want("orchestration") || wantsLive { await OrchestrationLiveTests.run(t, env) }
    if want("accountswitch") || wantsLive { await AccountLiveTests.run(t, env) }

    print("\n임시 프로젝트 유지: \(root.path)")
}

let ok = await t.summary()
exit(ok ? 0 : 1)
