import Foundation

// README 소개 이미지용 임시 DB (make.sh 가 앱의 비 UI 소스와 함께 컴파일한다). 앱의 실제 저장 · 인계 · 실행 전후 비교 코드를 그대로 쓴다.
// 사용법: AHC_DATABASE_PATH=<임시 DB> seed <full|handoff|agents> <시나리오 폴더 (scenario.sh 결과)>
//   full    : Claude 작업 → 한도 도달 → Codex 로 인계 → Codex 가 이어서 끝냄 (moa-ios 에 단계 A · B 적용)
//   handoff : Claude 가 한도에 닿은 직후까지 (단계 A 만) — 대화 끝의 인계 카드(-preview.action handoff:codex)를 찍는다
//   agents  : full + "푸시 알림 딥링크" 스레드에 세 에이전트가 번갈아 일한 짧은 대화 (그 스레드를 선택)
// 인계 문서는 앱의 prepareHandoff 와 같은 재료로 HandoffPacketBuilder 가 만든다 (Gemini 보조 없음).
guard CommandLine.arguments.count >= 3,
      !(ProcessInfo.processInfo.environment["AHC_DATABASE_PATH"] ?? "").isEmpty else {
    print("사용법: AHC_DATABASE_PATH=<임시 DB> seed <full|handoff|agents> <시나리오 폴더>")
    exit(2)
}
let variant = CommandLine.arguments[1]
let root = CommandLine.arguments[2]
let ios = root + "/moa-ios"
let env = ProcessInfo.processInfo.environment

let store = Store(databaseURL: Store.defaultDatabaseURL())
try await store.bootstrap()

// MARK: - 도우미

@discardableResult
func sh(_ args: [String], cwd: String? = nil) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    var e = env
    e["GIT_CONFIG_GLOBAL"] = "/dev/null"; e["GIT_CONFIG_NOSYSTEM"] = "1"
    p.environment = e
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try? p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// 단계 폴더의 파일을 작업 폴더로 복사한다. 돌려주는 값 = (상대 경로, 바꾸기 전 내용 · 없으면 nil).
func apply(stage: String) -> [(String, String?)] {
    let base = root + "/stages/" + stage
    var changed: [(String, String?)] = []
    let files = sh(["find", ".", "-type", "f"], cwd: base).split(separator: "\n")
        .map { String($0.dropFirst(2)) }.sorted()
    for rel in files {
        let dst = ios + "/" + rel
        let before = try? String(contentsOfFile: dst, encoding: .utf8)
        try? FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: dst)
        try? FileManager.default.copyItem(atPath: base + "/" + rel, toPath: dst)
        changed.append((rel, before))
    }
    return changed
}

/// 파일 하나의 통합 diff (Codex fileChange 형식처럼 hunk 만).
func unifiedDiff(_ rel: String, before: String?) -> String {
    let tmp = NSTemporaryDirectory() + "readme-before-\(UUID().uuidString)"
    try? (before ?? "").write(toFile: tmp, atomically: true, encoding: .utf8)
    let raw = sh(["git", "diff", "--no-index", "--no-color", "-U3", tmp, ios + "/" + rel])
    try? FileManager.default.removeItem(atPath: tmp)
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
    guard let start = lines.firstIndex(where: { $0.hasPrefix("@@") }) else { return raw }
    let header = before == nil ? "--- /dev/null\n+++ b/\(rel)\n" : "--- a/\(rel)\n+++ b/\(rel)\n"
    return header + lines[start...].joined(separator: "\n").trimmingCharacters(in: .newlines)
}

func snapshot() async -> RunSnapshotRead {
    await RunFileSnapshot.capture(at: URL(fileURLWithPath: ios), environment: env).read
}

func json(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

let now = Date()
func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

// MARK: - 모델 목록 (inttest seed --models 와 같은 고정 응답을 앱의 해석기로 읽는다)

let claudeJSON = #"""
{"is_error": false, "subtype": "success",
 "result": "Current model: `Opus 5.5` (effort: high)\nUsage: /model <name>. Available: sonnet, opus, haiku, fable, best, sonnet[1m], opus[1m], fable[1m], opusplan, default, or a full model ID."}
"""#
let claudeModels = ModelCatalog.parseClaudeModelResponse(claudeJSON, into: ModelCatalogSnapshot(provider: .claude))
func efforts(_ values: [String]) -> [[String: Any]] { values.map { ["reasoningEffort": $0] } }
let codexModels = ModelCatalog.parseCodexModels([
    ["id": "gpt-6-astra", "displayName": "GPT-6 Astra",
     "supportedReasoningEfforts": efforts(["low", "medium", "high", "xhigh", "max", "ultra"])],
    ["id": "gpt-5.6-sol", "displayName": "GPT-5.6 Sol", "isDefault": true,
     "supportedReasoningEfforts": efforts(["low", "medium", "high", "xhigh"])],
    ["id": "gpt-5.6-terra", "displayName": "GPT-5.6 Terra",
     "supportedReasoningEfforts": efforts(["low", "medium", "high"])],
    ["id": "gpt-5.6-luna", "displayName": "GPT-5.6 Luna", "supportedReasoningEfforts": efforts(["low", "medium"])],
])
let geminiModels = ModelCatalog.parseGeminiModelResponse(
    ["gemini-3.8-flash-low\tGemini 3.8 Flash (Low)", "gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)",
     "gemini-3.8-flash-high\tGemini 3.8 Flash (High)", "gemini-3.1-pro-low\tGemini 3.1 Pro (Low)",
     "gemini-3.1-pro-high\tGemini 3.1 Pro (High)"].joined(separator: "\n"),
    into: ModelCatalogSnapshot(provider: .gemini))
try await store.replaceModelOptions(claudeModels.options, scope: .claude)
try await store.replaceModelOptions(codexModels, scope: .codex(CodexAccount.defaultID))
try await store.replaceModelOptions(geminiModels.options, scope: .gemini)
// 데모 Codex 계정의 이메일 · 플랜 — 앱은 id_token 을 풀지 않고 한도를 읽을 때 CLI 에게 묻는데, 오프라인 미리보기는 묻지 않는다.
// 계정 ID 가 make.sh 의 데모 auth.json(`tokens.account_id`)과 같아 앱이 켤 때 지우지 않는다. 홈은 앱이 CODEX_HOME 으로 맞춘다.
var demoCodex = CodexAccount(id: CodexAccount.defaultID, label: "기본 계정", homePath: root + "/codex-home", sortOrder: 0)
demoCodex.authStatus = .loggedIn
demoCodex.authMode = "chatgpt"
demoCodex.email = "dev@example.com"
demoCodex.planType = "pro"
demoCodex.chatgptAccountID = "acct-demo"
try await store.upsertCodexAccount(demoCodex)

// MARK: - 프로젝트 · 스레드

let pIOS = Project(name: "moa-ios", path: ios, createdAt: ago(60 * 24 * 3), sortOrder: 0)
let pServer = Project(name: "moa-server", path: root + "/moa-server", createdAt: ago(60 * 24 * 5), sortOrder: 1)
let pWeb = Project(name: "moa-web", path: root + "/moa-web", createdAt: ago(60 * 24 * 6), sortOrder: 2)
for p in [pIOS, pServer, pWeb] { try await store.upsertProject(p) }
try await store.setSetting("antigravity_allowed_projects",
                          String(decoding: try JSONEncoder().encode([pIOS.id, pServer.id, pWeb.id]), as: UTF8.self))

func thread(_ project: Project, _ title: String, _ provider: AgentProvider, updated: Double,
            goal: String = "", notes: String = "") -> ConversationThread {
    var t = ConversationThread(projectID: project.id, title: title)
    t.goal = goal
    t.pinnedNotes = notes
    t.preferredProvider = provider
    t.claudeSelection = ModelSelection(model: "opus", effort: "high")
    t.codexSelection = ModelSelection(model: "gpt-5.6-sol", effort: "high")
    t.geminiSelection = ModelSelection(model: "gemini-3.8-flash", effort: "high")
    t.createdAt = ago(updated + 90)
    t.updatedAt = ago(updated)
    return t
}

let full = variant == "full" || variant == "agents"
var tMain = thread(pIOS, "로그인 401 재시도 처리", full ? .codex : .claude, updated: full ? 2 : 24,
                   goal: "토큰이 만료돼 401 이 오면 한 번만 갱신하고 같은 요청을 다시 보낸다. 두 번째 401 은 세션 만료로 알린다.",
                   notes: "TokenStore 의 공개 API 는 바꾸지 않는다. LegacyTokenStore 는 이번 PR 에서 지우지 않는다.")
let others: [(Project, String, AgentProvider, Double)] = [
    (pIOS, "온보딩 화면 다듬기", .claude, 95),
    (pIOS, "푸시 알림 딥링크", .gemini, 60 * 5),
    (pServer, "결제 웹훅 재시도 큐", .codex, 60 * 3),
    (pServer, "주문 API 응답 캐시", .claude, 60 * 26),
    (pWeb, "랜딩 페이지 다크 모드", .gemini, 60 * 30),
]
try await store.upsertThread(tMain)
try await store.setSetting("selected_thread", tMain.id)

// MARK: - 이벤트 도우미

var clock = ago(full ? 38 : 30)
func tick(_ seconds: Double) -> Date { clock = clock.addingTimeInterval(seconds); return clock }

@discardableResult
func append(_ threadID: String, _ kind: EventKind, _ provider: AgentProvider?, run: Run?, title: String = "",
            _ text: String, payload: String? = nil, tool: String? = nil, after seconds: Double = 4) async throws -> ThreadEvent {
    try await store.appendEvent(ThreadEvent(threadID: threadID, runID: run?.id, kind: kind, provider: provider,
                                            title: title, text: text, payloadJSON: payload, toolUseID: tool,
                                            createdAt: tick(seconds)))
}

/// Claude 도구 호출 — 요청(입력 JSON) + 결과.
func claudeTool(_ run: Run, _ name: String, _ input: [String: Any], output: String, after seconds: Double = 6) async throws {
    let id = "toolu_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)
    try await append(run.threadID, .toolRequest, .claude, run: run, title: name, json(input), tool: String(id), after: seconds)
    try await append(run.threadID, .toolResult, .claude, run: run, title: name, output, tool: String(id), after: 2)
}

/// Codex 명령 실행 (app-server commandExecution 과 같은 모양).
func codexCommand(_ run: Run, _ command: String, output: String, exit: Int = 0, after seconds: Double = 8) async throws {
    let wrapped = "/bin/zsh -lc '\(command.replacingOccurrences(of: "'", with: "'\\''"))'"
    try await append(run.threadID, .commandExecution, .codex, run: run,
                     title: JSONUtil.truncate(wrapped, max: 160, marker: "…"),
                     wrapped + ExecutionParser.outputMarker + output,
                     payload: JSONUtil.line(["status": "completed", "exitCode": exit, "cwd": ios]),
                     tool: "call_" + UUID().uuidString.prefix(8), after: seconds)
}

// MARK: - 메인 스레드: Claude

let claudeSession = try await store.ensureSession(threadID: tMain.id, provider: .claude)
var run1 = Run(threadID: tMain.id, sessionID: claudeSession.id, provider: .claude,
               requestText: "로그인 401 재시도 처리해 줘. 토큰이 만료되면 한 번만 갱신하고 같은 요청을 다시 보내게.",
               state: .running, startedAt: clock.addingTimeInterval(1), model: "claude-opus-5-5")
try await store.insertRun(run1)
let snap0 = await snapshot()

try await append(tMain.id, .userMessage, nil, run: run1, run1.requestText, after: 0)
let transportBefore = try String(contentsOfFile: ios + "/Moa/Auth/AuthTransport.swift", encoding: .utf8)
let numbered = transportBefore.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
    .map { String(format: "%6d\t%@", $0.offset + 1, String($0.element)) }.joined(separator: "\n")
try await claudeTool(run1, "Read", ["file_path": ios + "/Moa/Auth/AuthTransport.swift"], output: numbered, after: 5)
try await claudeTool(run1, "Grep", ["pattern": "AuthError.unauthorized", "path": ios + "/Moa"],
                     output: "Moa/Auth/AuthTransport.swift:19:            throw AuthError.unauthorized")
try await claudeTool(run1, "Read", ["file_path": ios + "/Moa/Auth/TokenStore.swift"], output: "(TokenStore.swift 36줄)")
try await append(tMain.id, .agentMessage, .claude, run: run1,
                 "`AuthTransport.send` 는 401 을 받으면 바로 `AuthError.unauthorized` 를 던집니다. `TokenStore.refresh()` 가 이미 동시 갱신을 하나로 합치고 있으니, 401 이면 토큰을 **한 번만** 갱신하고 같은 요청을 다시 보내도록 바꾸겠습니다. 두 번째 401 은 `AuthError.sessionExpired` 로 구분합니다.",
                 after: 9)

_ = apply(stage: "A")
try await claudeTool(run1, "Edit", ["file_path": ios + "/Moa/Auth/AuthTransport.swift",
                                     "old_string": "        guard http.statusCode != 401 else {\n            throw AuthError.unauthorized\n        }\n        return data\n    }",
                                     "new_string": "        if http.statusCode == 401 {\n            try await tokens.refresh()\n            return try await retryOnce(request)\n        }\n        return data\n    }\n\n    /// 갱신한 토큰으로 한 번만 다시 보낸다. 또 401 이면 세션이 만료된 것으로 본다.\n    private func retryOnce(_ request: URLRequest) async throws -> Data {\n        let (data, response) = try await session.data(for: authorized(request))\n        guard (response as? HTTPURLResponse)?.statusCode != 401 else {\n            throw AuthError.sessionExpired\n        }\n        return data\n    }"],
                     output: "The file \(ios)/Moa/Auth/AuthTransport.swift has been updated.", after: 14)
try await claudeTool(run1, "Edit", ["file_path": ios + "/Moa/Auth/AuthError.swift",
                                     "old_string": "    case unauthorized\n}",
                                     "new_string": "    case unauthorized\n    /// 토큰을 갱신하고 다시 보냈는데도 401 — 다시 로그인해야 한다.\n    case sessionExpired\n}"],
                     output: "The file \(ios)/Moa/Auth/AuthError.swift has been updated.", after: 6)
let testsA = try String(contentsOfFile: ios + "/MoaTests/AuthRetryTests.swift", encoding: .utf8)
try await claudeTool(run1, "Write", ["file_path": ios + "/MoaTests/AuthRetryTests.swift", "content": testsA],
                     output: "File created successfully at: \(ios)/MoaTests/AuthRetryTests.swift", after: 12)
try await claudeTool(run1, "Bash", ["command": "swift test", "description": "전체 테스트 실행"],
                     output: """
                     Test Suite 'AuthRetryTests' passed at 2026-09-18 15:39:12.201.
                     \t Executed 3 tests, with 0 failures (0 unexpected) in 0.412 (0.415) seconds
                     Test Suite 'All tests' passed at 2026-09-18 15:39:12.203.
                     \t Executed 12 tests, with 0 failures (0 unexpected) in 1.873 (1.880) seconds
                     """, after: 10)
try await append(tMain.id, .agentMessage, .claude, run: run1,
                 "재시도 로직과 테스트 12개가 모두 통과했습니다. 이어서 `LoginView` 의 오류 문구를 새 흐름(세션 만료 · 잘못된 비밀번호)에 맞추겠습니다.",
                 after: 26)
try await claudeTool(run1, "Read", ["file_path": ios + "/Moa/Login/LoginViewModel.swift"], output: "(LoginViewModel.swift 28줄)", after: 5)
try await append(tMain.id, .error, .claude, run: run1, title: LimitStatus.subscriptionCap.koreanName,
                 // 초기화 시각은 원문에 두지 않는다 — 화면의 한도 줄은 앱이 확인한 시각만 적어(모르면 "초기화 시각 미확인")
                 // 원문의 시각과 나란히 서면 서로 어긋나 보인다.
                 "Claude usage limit reached.", after: 7)
run1.state = .rateLimited
run1.terminalReason = "rate_limit"
run1.endedAt = clock
try await store.updateRun(run1)
try await store.upsertUsage(UsageRecord(runID: run1.id, threadID: tMain.id, provider: .claude, model: "claude-opus-5-5",
                                        inputTokens: 18_420, cacheReadTokens: 412_800, cacheWriteTokens: 36_900,
                                        outputTokens: 9_850, durationMs: Int(clock.timeIntervalSince(run1.startedAt) * 1000),
                                        costUSD: 1.84, costSource: .cliReported, createdAt: clock))
let snap1 = await snapshot()
let changes1 = RunFileChanges.summarize(runID: run1.id, before: snap0, after: snap1)
try await store.appendEvent({ var e = changes1.event(threadID: tMain.id, provider: .claude); e.createdAt = tick(1); return e }())

// MARK: - 인계 · Codex

if full {
    // 앱의 prepareHandoff 와 같은 재료로 규칙 초안을 만든다 (Gemini 보조 없음).
    let git = await GitInspector.snapshot(at: URL(fileURLWithPath: ios), environment: env)
    let events = try await store.events(threadID: tMain.id)
    let baseSeq = try await store.maxSeq(threadID: tMain.id)
    var packet = HandoffPacketBuilder.build(HandoffPacketBuilder.Input(
        thread: tMain, project: pIOS, fromProvider: .claude, toProvider: .codex,
        fromAccountLabel: nil, toAccountLabel: nil, events: events, runs: [run1],
        lastConfirmedPacket: nil, git: git, baseSeq: baseSeq))
    packet.summarySource = "rule"
    packet.generatedAt = tick(40)
    let rendered = HandoffPacketBuilder.render(packet, threadTitle: tMain.title, projectPath: pIOS.path)
    let finalText = HandoffPacketBuilder.markAuthorship(rendered, packet: packet, review: "사람 검토함")
    var handoff = Handoff(threadID: tMain.id, fromProvider: .claude, toProvider: .codex,
                          toAccountID: CodexAccount.defaultID, baseSeq: baseSeq,
                          draftJSON: String(decoding: try JSONEncoder().encode(packet), as: UTF8.self),
                          finalText: finalText, deliveryState: .delivered, createdAt: clock, note: "사람 검토함")
    let codexSession = try await store.ensureSession(threadID: tMain.id, provider: .codex, accountID: CodexAccount.defaultID)
    var run2 = Run(threadID: tMain.id, sessionID: codexSession.id, provider: .codex, requestText: finalText,
                   state: .running, startedAt: clock.addingTimeInterval(50), model: "gpt-5.6-sol",
                   isHandoffDelivery: true, codexAccountID: CodexAccount.defaultID)
    handoff.sentAt = clock.addingTimeInterval(48)
    handoff.deliveryRunID = run2.id
    try await store.insertHandoff(handoff)
    try await store.insertRun(run2)
    try await append(tMain.id, .handoffSent, .claude, run: nil, title: "Claude → Codex 인계 전송", finalText,
                     payload: JSONUtil.line(["localToken": handoff.localToken, "baseSeq": handoff.baseSeq,
                                             "fromAccountID": "", "toAccountID": CodexAccount.defaultID]),
                     after: 48)

    try await append(tMain.id, .agentMessage, .codex, run: run2,
                     "인계 받았습니다. `AuthTransport` 재시도와 `AuthRetryTests` 는 그대로 두고, 남은 `LoginView` 오류 문구부터 새 재시도 흐름에 맞추겠습니다.",
                     after: 14)
    try await codexCommand(run2, "rg -n \"로그인에 실패\" Moa",
                           output: "Moa/Login/LoginViewModel.swift:23:            errorMessage = \"로그인에 실패했습니다.\"", after: 6)
    let changedB = apply(stage: "B")
    for (rel, before) in changedB {
        try await append(tMain.id, .fileChange, .codex, run: run2, title: ios + "/" + rel,
                         ios + "/" + rel + "\n\n" + unifiedDiff(rel, before: before),
                         payload: JSONUtil.line(["status": "completed"]),
                         tool: "call_" + UUID().uuidString.prefix(8), after: 11)
    }
    try await codexCommand(run2, "swift test",
                           output: """
                           Test Suite 'All tests' passed at 2026-09-18 15:52:40.118.
                           \t Executed 14 tests, with 0 failures (0 unexpected) in 2.104 (2.111) seconds
                           """, after: 21)
    try await append(tMain.id, .agentMessage, .codex, run: run2, """
        로그인 화면이 세션 만료와 잘못된 비밀번호를 구분해 보여 줍니다.

        - `LoginViewModel.message(for:)` 가 `AuthError` 를 문구로 바꿉니다 — 세션 만료는 "로그인이 만료됐어요. 다시 로그인해 주세요."
        - `LoginView` 는 그 문구를 비밀번호 칸 아래에 보여 줍니다.
        - 회귀 테스트 `LoginErrorMessageTests` 2개를 더했고, `swift test` 전체 14개가 통과했습니다.
        """, after: 16)
    run2.state = .completed
    run2.terminalReason = "completed"
    run2.endedAt = clock
    try await store.updateRun(run2)
    try await append(tMain.id, .handoffReceived, .codex, run: run2, title: "인계 전달 상태: 전달 확인",
                     "대상이 인계를 수신하고 응답을 시작했습니다.",
                     payload: JSONUtil.line(["localToken": handoff.localToken, "state": "delivered"]), after: 1)
    try await store.upsertUsage(UsageRecord(runID: run2.id, threadID: tMain.id, provider: .codex, model: "gpt-5.6-sol",
                                            inputTokens: 52_300, cacheReadTokens: 188_400, outputTokens: 6_420,
                                            reasoningTokens: 2_910, durationMs: Int(clock.timeIntervalSince(run2.startedAt) * 1000),
                                            costUSD: 0.61, costSource: .appCalculated, createdAt: clock))
    let snap2 = await snapshot()
    let changes2 = RunFileChanges.summarize(runID: run2.id, before: snap1, after: snap2)
    try await store.appendEvent({ var e = changes2.event(threadID: tMain.id, provider: .codex); e.createdAt = tick(1); return e }())
    try await store.upsertRating(Rating(threadID: tMain.id, handoffID: handoff.id, provider: .claude,
                                        handoffQuality: .seamless, createdAt: clock))
    try await store.upsertRating(Rating(threadID: tMain.id, runID: run2.id, provider: .codex, satisfaction: .up,
                                        createdAt: clock))
    var session = codexSession
    session.cliSessionID = UUID().uuidString.lowercased()
    session.lastDeliveredSeq = handoff.baseSeq
    try await store.upsertSession(session)
    // 커밋할 준비 — 변경을 모두 스테이지한다 (변경사항 탭의 체크).
    sh(["git", "add", "-A"], cwd: ios)
}
tMain.updatedAt = clock
try await store.upsertThread(tMain)

// MARK: - 다른 스레드 (사이드바 · 전적)

/// 한 스레드에서 세 에이전트가 번갈아 일한 짧은 대화 (에이전트 선택 팝오버를 빈 공간 위에서 찍으려고 짧게).
func seedThreeAgents(_ t: ConversationThread) async throws {
    clock = ago(52)
    let router = ios + "/Moa/App/DeepLinkRouter.swift"
    let sC = try await store.ensureSession(threadID: t.id, provider: .claude)
    var r1 = Run(threadID: t.id, sessionID: sC.id, provider: .claude,
                 requestText: "알림을 누르면 그 주문 상세로 바로 가게 딥링크를 연결해 줘.",
                 state: .running, startedAt: clock, model: "claude-opus-5-5")
    try await store.insertRun(r1)
    try await append(t.id, .userMessage, nil, run: r1, r1.requestText, after: 0)
    try await claudeTool(r1, "Read", ["file_path": router], output: "(DeepLinkRouter.swift 41줄)", after: 5)
    try await claudeTool(r1, "Edit", ["file_path": router,
                                      "old_string": "        case \"coupons\": return .coupons\n",
                                      "new_string": "        case \"coupons\": return .coupons\n        case \"orders\":\n            guard let id = url.pathComponents.dropFirst().first else { return nil }\n            return .order(id: id)\n"],
                     output: "The file \(router) has been updated.", after: 14)
    try await append(t.id, .agentMessage, .claude, run: r1,
                     "`moa://orders/{id}` 경로를 `DeepLinkRouter` 에 추가했습니다. 앱이 꺼져 있을 때 누른 알림도 첫 화면을 띄운 뒤 주문 상세로 이동합니다.",
                     after: 18)
    r1.state = .completed; r1.terminalReason = "completed"; r1.endedAt = clock
    try await store.updateRun(r1)
    try await store.upsertUsage(UsageRecord(runID: r1.id, threadID: t.id, provider: .claude, model: "claude-opus-5-5",
                                            inputTokens: 9_120, cacheReadTokens: 118_300, cacheWriteTokens: 14_200,
                                            outputTokens: 2_310, durationMs: 41_000, costUSD: 0.47,
                                            costSource: .cliReported, createdAt: clock))

    let sX = try await store.ensureSession(threadID: t.id, provider: .codex, accountID: CodexAccount.defaultID)
    var r2 = Run(threadID: t.id, sessionID: sX.id, provider: .codex, requestText: "이 경로 테스트도 채워 줘.",
                 state: .running, startedAt: tick(60), model: "gpt-5.6-sol", codexAccountID: CodexAccount.defaultID)
    try await store.insertRun(r2)
    try await append(t.id, .userMessage, nil, run: r2, r2.requestText, after: 0)
    try await codexCommand(r2, "swift test --filter DeepLinkRouterTests",
                           output: "\t Executed 5 tests, with 0 failures (0 unexpected) in 0.208 (0.211) seconds", after: 24)
    try await append(t.id, .agentMessage, .codex, run: r2,
                     "`DeepLinkRouterTests` 에 주문 · 쿠폰 · 잘못된 ID 등 5가지 경우를 더했고 모두 통과합니다.", after: 9)
    r2.state = .completed; r2.terminalReason = "completed"; r2.endedAt = clock
    try await store.updateRun(r2)
    try await store.upsertUsage(UsageRecord(runID: r2.id, threadID: t.id, provider: .codex, model: "gpt-5.6-sol",
                                            inputTokens: 14_800, cacheReadTokens: 61_200, outputTokens: 1_940,
                                            reasoningTokens: 820, durationMs: 38_000, costUSD: 0.11,
                                            costSource: .appCalculated, createdAt: clock))

    let sG = try await store.ensureSession(threadID: t.id, provider: .gemini)
    var r3 = Run(threadID: t.id, sessionID: sG.id, provider: .gemini, requestText: "알림 문구 초안 세 가지만 뽑아 줘.",
                 state: .running, startedAt: tick(50), model: "gemini-3.8-flash")
    try await store.insertRun(r3)
    try await append(t.id, .userMessage, nil, run: r3, r3.requestText, after: 0)
    try await append(t.id, .agentMessage, .gemini, run: r3, """
        1. 주문하신 상품이 출발했어요. 도착 예정 시간을 확인해 보세요.
        2. 곧 도착해요! 문 앞에서 받아 주세요.
        3. 배송이 끝났어요. 상품은 마음에 드셨나요?
        """, after: 11)
    r3.state = .completed; r3.terminalReason = "completed"; r3.endedAt = clock
    try await store.updateRun(r3)
    try await store.upsertUsage(UsageRecord(runID: r3.id, threadID: t.id, provider: .gemini, model: "gemini-3.8-flash",
                                            inputTokens: 3_400, outputTokens: 610, durationMs: 9_000, costUSD: 0.01,
                                            costSource: .appCalculated, createdAt: clock))
}

for (index, item) in others.enumerated() {
    let (project, title, provider, updated) = item
    var t = thread(project, title, provider, updated: updated)
    if variant == "agents" && title == "푸시 알림 딥링크" {
        t.updatedAt = ago(1)
        try await store.upsertThread(t)
        try await store.setSetting("selected_thread", t.id)
        try await seedThreeAgents(t)
        continue
    }
    try await store.upsertThread(t)
    let session = try await store.ensureSession(threadID: t.id, provider: provider)
    let model = provider == .claude ? "claude-opus-5-5" : (provider == .codex ? "gpt-5.6-sol" : "gemini-3.8-flash")
    for turn in 0..<(2 + index % 2) {
        let start = t.createdAt.addingTimeInterval(Double(turn) * 900 + 60)
        var run = Run(threadID: t.id, sessionID: session.id, provider: provider,
                      requestText: "\(title) — \(turn + 1)단계", state: .completed, startedAt: start,
                      endedAt: start.addingTimeInterval(180 + Double(turn * 40)), terminalReason: "completed", model: model)
        try await store.insertRun(run)
        _ = try await store.appendEvent(ThreadEvent(threadID: t.id, runID: run.id, kind: .userMessage,
                                                    text: run.requestText, createdAt: start))
        _ = try await store.appendEvent(ThreadEvent(threadID: t.id, runID: run.id, kind: .agentMessage, provider: provider,
                                                    text: "\(title) \(turn + 1)단계를 마쳤습니다.",
                                                    createdAt: start.addingTimeInterval(170)))
        try await store.upsertUsage(UsageRecord(runID: run.id, threadID: t.id, provider: provider, model: model,
                                                inputTokens: 21_000 + turn * 3_100, cacheReadTokens: 160_000 + index * 9_000,
                                                cacheWriteTokens: provider == .claude ? 12_400 : 0,
                                                outputTokens: 4_200 + index * 310, durationMs: 180_000 + turn * 40_000,
                                                costUSD: provider == .claude ? 0.92 + Double(turn) * 0.2 : 0.38 + Double(index) * 0.05,
                                                costSource: provider == .claude ? .cliReported : .appCalculated,
                                                createdAt: run.endedAt ?? start))
        if turn == 0 {
            try await store.upsertRating(Rating(threadID: t.id, runID: run.id, provider: provider,
                                                satisfaction: .up, createdAt: start))
        }
        run.state = .completed
    }
}

await store.db.close()
print("\(variant): \(Store.defaultDatabaseURL().path)")
