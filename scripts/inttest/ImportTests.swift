import Foundation

/// Claude Code · Codex 기록 가져오기 (`Import/SessionImport.swift`): 두 jsonl 형식의 요약 · 대화 파싱, 폴더 선별, 저장 · 중복 방지.
/// 고정 입력은 실제 파일에서 본 줄의 형식을 줄여 적은 것이다. 세션 ID · 시각은 지어낸 값이다 (실제 세션의 것을 쓰지 않는다).
enum ImportTests {
    static func run(_ t: TestKit) async {
        await claudeParsing(t)
        await claudeTaskNotification(t)
        await claudeQueuedNotification(t)
        await claudeMetaLines(t)
        await claudeSubAgents(t)
        await codexParsing(t)
        await folderSelection(t)
        await storeRoundTrip(t)
        await streamingSummary(t)
        await scanProgressAndStop(t)
        await importStops(t)
    }

    // MARK: 고정 입력

    static let claudeSession = "b1c2d3e4-0000-4000-8000-000000000004"
    static let claudeLines = """
    {"type":"queue-operation","operation":"enqueue","timestamp":"2026-01-15T01:28:39.065Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000004","content":"첫 요청"}
    {"parentUuid":null,"isSidechain":false,"type":"user","uuid":"u1","timestamp":"2026-01-15T01:28:39.151Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000004","cwd":"/Users/me/demo-project","version":"2.1.270","message":{"role":"user","content":"첫 요청<system-reminder>숨김</system-reminder>"}}
    {"type":"custom-title","customTitle":"발표 자료 수정","sessionId":"b1c2d3e4-0000-4000-8000-000000000004"}
    {"isSidechain":false,"type":"assistant","uuid":"a1","timestamp":"2026-01-15T01:28:45.602Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000004","cwd":"/Users/me/demo-project","message":{"role":"assistant","model":"claude-fable-5-1","content":[{"type":"thinking","thinking":"…"},{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/Users/me/demo-project/README.md"}}]}}
    {"isSidechain":false,"type":"user","uuid":"u2","timestamp":"2026-01-15T01:28:48.653Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000004","cwd":"/Users/me/demo-project","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"# README\\n본문"}]}}
    {"isSidechain":false,"type":"assistant","uuid":"a2","timestamp":"2026-01-15T01:28:50.000Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000004","cwd":"/Users/me/demo-project","message":{"role":"assistant","model":"claude-fable-5-1","content":[{"type":"text","text":"README 를 읽었습니다."}]}}
    {"isSidechain":true,"type":"user","uuid":"s1","timestamp":"2026-01-15T01:28:51.000Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000004","message":{"role":"user","content":"서브에이전트 프롬프트"}}
    {"isSidechain":false,"type":"user","uuid":"u3","timestamp":"2026-01-15T01:30:00.000Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000004","cwd":"/Users/me/demo-project","message":{"role":"user","content":"<command-name>/usage</command-name>"}}
    {"isSidechain":false,"type":"user","uuid":"u4","timestamp":"2026-01-15T01:31:00.000Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000004","cwd":"/Users/me/demo-project","message":{"role":"user","content":[{"type":"text","text":"두 번째 요청"}]}}
    {"isSidechain":false,"type":"assistant","uuid":"a3","timestamp":"2026-01-15T01:31:05.000Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000004","cwd":"/Users/me/demo-project","message":{"role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"끝."}]}}
    """

    /// 백그라운드 Agent 하나 (실측 t2 의 모양): 요청 → Agent 호출 → `async_launched` 결과 → "launched" → 끝 알림(`origin` task-notification)
    /// → CLI 가 스스로 연 후속 턴의 답. 하위의 기록은 `<세션>/subagents/agent-a961.jsonl` 에 따로 있다.
    static let claudeBackgroundSession = "b1c2d3e4-0000-4000-8000-000000000001"
    static let claudeBackgroundLines = """
    {"parentUuid":null,"isSidechain":false,"type":"user","uuid":"u1","timestamp":"2026-09-22T12:13:36.660Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000001","cwd":"/Users/me/probe","version":"2.1.270","message":{"role":"user","content":"백그라운드로 beta.txt 를 읽게 해"}}
    {"isSidechain":false,"type":"assistant","uuid":"a1","timestamp":"2026-09-22T12:13:40.168Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000001","cwd":"/Users/me/probe","message":{"role":"assistant","model":"claude-sonnet-5","content":[{"type":"tool_use","id":"toolu_bg1","name":"Agent","input":{"description":"slow read","prompt":"beta.txt 를 읽어라","subagent_type":"general-purpose","run_in_background":true}}]}}
    {"isSidechain":false,"type":"user","uuid":"u2","timestamp":"2026-09-22T12:13:40.203Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000001","cwd":"/Users/me/probe","message":{"role":"user","content":[{"tool_use_id":"toolu_bg1","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully."}]}]},"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"a961"}}
    {"isSidechain":false,"type":"assistant","uuid":"a2","timestamp":"2026-09-22T12:13:41.260Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000001","cwd":"/Users/me/probe","message":{"role":"assistant","model":"claude-sonnet-5","content":[{"type":"text","text":"launched"}]}}
    {"isSidechain":false,"type":"user","uuid":"u3","timestamp":"2026-09-22T12:13:45.960Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000001","cwd":"/Users/me/probe","origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification>\\n<task-id>a961</task-id>\\n<tool-use-id>toolu_bg1</tool-use-id>\\n<status>completed</status>\\n<summary>Agent slow read finished</summary>\\n<result>beta first line</result>\\n</task-notification>"}}
    {"isSidechain":false,"type":"assistant","uuid":"a3","timestamp":"2026-09-22T12:13:47.850Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000001","cwd":"/Users/me/probe","message":{"role":"assistant","model":"claude-sonnet-5","content":[{"type":"text","text":"bg-done: beta first line"}]}}
    """

    /// 메인이 도는 중(여기선 Bash 대기)에 끝난 백그라운드 Agent 둘: 끝 알림이 사용자 줄 없이 `attachment`(`queued_command`)로만 남는다.
    /// 두 번째 알림의 `prompt` 는 text 블록. 하위 기록 안(사이드체인)의 알림은 메인의 것이 아니다.
    static let claudeQueuedLines = """
    {"parentUuid":null,"isSidechain":false,"type":"user","uuid":"u1","timestamp":"2026-09-22T13:00:00.000Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000002","cwd":"/Users/me/probe","message":{"role":"user","content":"백그라운드 둘을 띄우고 기다려"}}
    {"isSidechain":false,"type":"assistant","uuid":"a1","timestamp":"2026-09-22T13:00:02.000Z","message":{"role":"assistant","model":"claude-sonnet-5","content":[{"type":"tool_use","id":"toolu_q1","name":"Agent","input":{"description":"read alpha","prompt":"alpha","run_in_background":true}},{"type":"tool_use","id":"toolu_q2","name":"Agent","input":{"description":"read beta","prompt":"beta","run_in_background":true}}]}}
    {"isSidechain":false,"type":"user","uuid":"u2","timestamp":"2026-09-22T13:00:02.100Z","message":{"role":"user","content":[{"tool_use_id":"toolu_q1","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully."}]}]},"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"q1"}}
    {"isSidechain":false,"type":"user","uuid":"u3","timestamp":"2026-09-22T13:00:02.200Z","message":{"role":"user","content":[{"tool_use_id":"toolu_q2","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully."}]}]},"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"q2"}}
    {"isSidechain":false,"type":"assistant","uuid":"a2","timestamp":"2026-09-22T13:00:03.000Z","message":{"role":"assistant","model":"claude-sonnet-5","content":[{"type":"tool_use","id":"toolu_s1","name":"Bash","input":{"command":"sleep 20"}}]}}
    {"isSidechain":false,"type":"attachment","uuid":"n1","timestamp":"2026-09-22T13:00:10.000Z","attachment":{"type":"queued_command","commandMode":"task-notification","prompt":"<task-notification>\\n<task-id>q1</task-id>\\n<tool-use-id>toolu_q1</tool-use-id>\\n<status>completed</status>\\n<summary>Agent read alpha completed</summary>\\n</task-notification>"}}
    {"isSidechain":false,"type":"attachment","uuid":"n2","timestamp":"2026-09-22T13:00:15.000Z","attachment":{"type":"queued_command","commandMode":"task-notification","prompt":[{"type":"text","text":"<task-notification>\\n<task-id>q2</task-id>\\n<tool-use-id>toolu_q2</tool-use-id>\\n<status>failed</status>\\n</task-notification>"}]}}
    {"isSidechain":true,"agentId":"q2","type":"attachment","uuid":"n3","timestamp":"2026-09-22T13:00:16.000Z","attachment":{"type":"queued_command","commandMode":"task-notification","prompt":"<task-notification>\\n<tool-use-id>toolu_q2</tool-use-id>\\n<status>completed</status>\\n</task-notification>"}}
    {"isSidechain":false,"type":"user","uuid":"u4","timestamp":"2026-09-22T13:00:23.000Z","message":{"role":"user","content":[{"tool_use_id":"toolu_s1","type":"tool_result","content":"(no output)"}]}}
    {"isSidechain":false,"type":"assistant","uuid":"a3","timestamp":"2026-09-22T13:00:25.000Z","message":{"role":"assistant","model":"claude-sonnet-5","content":[{"type":"text","text":"하나는 끝, 하나는 실패."}]}}
    """

    /// CLI 가 끼워 넣은 사용자 줄(`isMeta`): 모델이 부른 스킬의 명령 · 본문, 이미지 크기 안내, 이어가기 안내.
    /// 사람이 친 `/tidy src 폴더` 는 명령 줄 뒤 펼침 줄(`isMeta`)에서 명령 글로 턴을 연다. `/usage` 는 출력이 뒤따라 턴이 아니다.
    static let claudeMetaSession = "c3d4e5f6-0000-4000-8000-000000000003"
    static let claudeMetaLines = """
    {"parentUuid":null,"isSidechain":false,"type":"user","uuid":"m1","timestamp":"2026-09-22T14:00:00.000Z","sessionId":"c3d4e5f6-0000-4000-8000-000000000003","cwd":"/Users/me/probe","version":"2.1.270","message":{"role":"user","content":"스킬로 정리해"}}
    {"isSidechain":false,"type":"assistant","uuid":"m2","timestamp":"2026-09-22T14:00:02.000Z","message":{"role":"assistant","model":"claude-sonnet-5","content":[{"type":"tool_use","id":"toolu_sk","name":"Skill","input":{"skill":"tidy"}}]}}
    {"isSidechain":false,"type":"user","uuid":"m3","timestamp":"2026-09-22T14:00:02.100Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_sk","content":"Launching skill: tidy"}]}}
    {"isSidechain":false,"type":"user","uuid":"m4","timestamp":"2026-09-22T14:00:02.110Z","isMeta":true,"sourceToolUseID":"toolu_sk","message":{"role":"user","content":"<command-message>tidy</command-message>\\n<command-name>tidy</command-name>"}}
    {"isSidechain":false,"type":"user","uuid":"m5","timestamp":"2026-09-22T14:00:02.120Z","isMeta":true,"sourceToolUseID":"toolu_sk","message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /Users/me/.claude/skills/tidy\\n\\n# Tidy\\n정리하는 법"}]}}
    {"isSidechain":false,"type":"assistant","uuid":"m6","timestamp":"2026-09-22T14:00:05.000Z","message":{"role":"assistant","model":"claude-sonnet-5","content":[{"type":"text","text":"정리했습니다."}]}}
    {"isSidechain":false,"type":"user","uuid":"m7","timestamp":"2026-09-22T14:01:00.000Z","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AA=="}},{"type":"text","text":"이 그림 봐"}]}}
    {"isSidechain":false,"type":"user","uuid":"m8","timestamp":"2026-09-22T14:01:00.010Z","isMeta":true,"message":{"role":"user","content":"[Image: original 3000x1788, displayed at 2000x1192.]"}}
    {"isSidechain":false,"type":"assistant","uuid":"m9","timestamp":"2026-09-22T14:01:03.000Z","message":{"role":"assistant","model":"claude-sonnet-5","content":[{"type":"text","text":"봤습니다."}]}}
    {"isSidechain":false,"type":"user","uuid":"m10","timestamp":"2026-09-22T14:02:00.000Z","message":{"role":"user","content":"<command-name>/usage</command-name>\\n<command-message>usage</command-message>\\n<command-args></command-args>"}}
    {"isSidechain":false,"type":"user","uuid":"m11","timestamp":"2026-09-22T14:02:00.010Z","message":{"role":"user","content":"<local-command-stdout>한도 표시</local-command-stdout>"}}
    {"isSidechain":false,"type":"user","uuid":"m12","timestamp":"2026-09-22T14:02:30.000Z","isMeta":true,"message":{"role":"user","content":"Continue from where you left off."}}
    {"isSidechain":false,"type":"assistant","uuid":"m13","timestamp":"2026-09-22T14:02:31.000Z","message":{"role":"assistant","model":"claude-sonnet-5","content":[{"type":"text","text":"이어서."}]}}
    {"isSidechain":false,"type":"user","uuid":"m14","timestamp":"2026-09-22T14:03:00.000Z","sessionId":"c3d4e5f6-0000-4000-8000-000000000003","cwd":"/Users/me/probe","message":{"role":"user","content":"<command-message>tidy</command-message>\\n<command-name>/tidy</command-name>\\n<command-args>src 폴더</command-args>"}}
    {"isSidechain":false,"type":"user","uuid":"m15","timestamp":"2026-09-22T14:03:00.010Z","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /Users/me/.claude/skills/tidy\\n\\n# Tidy\\n\\nARGUMENTS: src 폴더"}]}}
    {"isSidechain":false,"type":"assistant","uuid":"m16","timestamp":"2026-09-22T14:03:04.000Z","message":{"role":"assistant","model":"claude-sonnet-5","content":[{"type":"text","text":"src 를 정리했습니다."}]}}
    """

    static let claudeSubAgentLines = """
    {"parentUuid":null,"isSidechain":true,"agentId":"a961","type":"user","uuid":"s1","timestamp":"2026-09-22T12:13:40.172Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000001","cwd":"/Users/me/probe","message":{"role":"user","content":"beta.txt 를 읽어라"}}
    {"isSidechain":true,"agentId":"a961","type":"attachment","uuid":"s1b","timestamp":"2026-09-22T12:13:40.179Z","attachment":{"type":"date","date":"2026-09-22"}}
    {"isSidechain":true,"agentId":"a961","type":"assistant","uuid":"s2","timestamp":"2026-09-22T12:13:42.557Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000001","message":{"role":"assistant","model":"claude-sonnet-5","content":[{"type":"thinking","thinking":""},{"type":"tool_use","id":"toolu_r1","name":"Read","input":{"file_path":"/Users/me/probe/beta.txt"}}]}}
    {"isSidechain":true,"agentId":"a961","type":"user","uuid":"s3","timestamp":"2026-09-22T12:13:42.584Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000001","message":{"role":"user","content":[{"tool_use_id":"toolu_r1","type":"tool_result","content":"1\\tbeta first line"}]}}
    {"isSidechain":true,"agentId":"a961","type":"assistant","uuid":"s4","timestamp":"2026-09-22T12:13:45.897Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000001","message":{"role":"assistant","model":"claude-sonnet-5","content":[{"type":"text","text":"beta first line"}]}}
    """
    static let claudeSubAgentMeta = """
    {"agentType":"general-purpose","description":"slow read","toolUseId":"toolu_bg1","spawnDepth":1,"requestShape":"background","requestNonInteractive":true}
    """
    /// 워크플로 안의 에이전트 (`subagents/workflows/wf_*/`) — meta 에 호출 id 가 없다. 옮기지 않는다.
    static let claudeWorkflowAgentLines = """
    {"parentUuid":null,"isSidechain":true,"agentId":"w1","type":"user","uuid":"w1u","timestamp":"2026-09-22T12:13:43.000Z","sessionId":"b1c2d3e4-0000-4000-8000-000000000001","cwd":"/Users/me/probe","message":{"role":"user","content":"워크플로 안의 요청"}}
    """
    static let claudeWorkflowAgentMeta = """
    {"agentType":"workflow-subagent","description":"read:alpha.txt","workflowPhase":"Summarize","spawnDepth":1,"requestShape":"foreground"}
    """

    static let codexLines = """
    {"timestamp":"2026-01-15T00:39:55.209Z","type":"session_meta","payload":{"session_id":"c0dec0de-0005","id":"c0dec0de-0005","timestamp":"2026-01-15T00:39:53.721Z","cwd":"/Users/me/demo-project","cli_version":"0.153.4"}}
    {"timestamp":"2026-01-15T00:39:55.300Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<app-context>앱 맥락</app-context>"}]}}
    {"timestamp":"2026-01-15T00:39:55.400Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>환경</environment_context>"}]}}
    {"timestamp":"2026-01-15T00:39:55.733Z","type":"world_state","payload":{"full":true,"state":{"collaboration_mode":{"mode":"default","model":"gpt-6-astra"}}}}
    {"timestamp":"2026-01-15T00:39:55.967Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"um1","content":[{"type":"text","text":"광고 영상 만들어줘"}]}}}
    {"timestamp":"2026-01-15T00:40:01.234Z","type":"response_item","payload":{"type":"function_call","name":"js","call_id":"call_1","arguments":"{\\"code\\":\\"1\\"}"}}
    {"timestamp":"2026-01-15T00:40:02.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"exec-1","command":["/bin/zsh","-lc","rg --files | head -3"],"cwd":"file:///Users/me/demo-project","status":"completed","exit_code":0,"aggregated_output":"a\\nb\\nc\\n"}}}
    {"timestamp":"2026-01-15T00:40:03.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"McpToolCall","id":"exec-2","server":"codex_app","tool":"load","arguments":{},"status":"completed","result":{"content":[{"type":"text","text":"ok"}]}}}}
    {"timestamp":"2026-01-15T00:40:04.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","id":"exec-3","status":"completed","changes":{"/Users/me/demo-project/a.py":{"type":"add","content":"print(1)"}}}}}
    {"timestamp":"2026-01-15T00:40:05.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning","id":"rs1","summary_text":[],"raw_content":[]}}}
    {"timestamp":"2026-01-15T00:40:06.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"am1","content":[{"type":"Text","text":"만들었습니다."}]}}}
    {"timestamp":"2026-01-15T00:48:59.491Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","error":{"message":"You've hit your usage limit."}}}
    """

    static let codexOldLines = """
    {"timestamp":"2025-11-18T00:05:25.798Z","type":"session_meta","payload":{"id":"c0dec0de","cwd":"/Users/me/old","cli_version":"0.144.5","timestamp":"2025-11-18T00:05:07.637Z"}}
    {"timestamp":"2025-11-18T00:05:26.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"옛 형식 요청"}]}}
    {"timestamp":"2025-11-18T00:05:27.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","call_id":"c1","arguments":"{\\"cmd\\":\\"ls\\"}"}}
    {"timestamp":"2025-11-18T00:05:28.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"a b"}}
    {"timestamp":"2025-11-18T00:05:29.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"옛 형식 응답"}]}}
    """

    // MARK: Claude

    static func claudeParsing(_ t: TestKit) async {
        await t.group("가져오기 · Claude Code 파싱")
        let data = Data(claudeLines.utf8)
        let url = URL(fileURLWithPath: "/tmp/\(claudeSession).jsonl")
        let summary = ClaudeTranscript.summary(of: data, fileURL: url)
        await t.check("요약: cwd · 세션 ID · custom-title · 사용자 메시지 2 (사이드체인 · 슬래시 명령 제외)",
                      summary?.cwd == "/Users/me/demo-project" && summary?.cliSessionID == claudeSession
                          && summary?.title == "발표 자료 수정" && summary?.userMessages == 2 && summary?.cliVersion == "2.1.270",
                      "\(String(describing: summary))")
        let transcript = ClaudeTranscript.transcript(of: data)
        await t.check("턴 2개, 첫 턴에 system-reminder 를 뗀 사용자 글", transcript.turns.count == 2 && transcript.turns[0].userText == "첫 요청", "\(transcript.turns.map(\.userText))")
        let first = transcript.turns.first?.events ?? []
        await t.check("첫 턴 이벤트: tool_use → toolRequest(Read) · tool_result → toolResult(Read) · text → agentMessage, thinking 제외",
                      first.map(\.kind) == [.toolRequest, .toolResult, .agentMessage] && first[0].title == "Read" && first[1].title == "Read"
                          && first[1].toolUseID == "toolu_1" && first[2].text == "README 를 읽었습니다.",
                      "\(first.map { "\($0.kind) \($0.title)" })")
        await t.check("모델은 턴마다 (fable → opus), 마지막 모델이 대화 모델",
                      transcript.turns[0].model == "claude-fable-5-1" && transcript.turns[1].model == "claude-opus-5" && transcript.model == "claude-opus-5")
        await t.check("첫 턴 끝 시각은 마지막 이벤트 시각", transcript.turns[0].endedAt > transcript.turns[0].startedAt)
    }

    /// 백그라운드 작업의 끝 알림으로 CLI 가 연 후속 턴은 사람의 메시지 · 새 실행이 아니다 — 앞 턴에 붙는다.
    static func claudeTaskNotification(_ t: TestKit) async {
        await t.group("가져오기 · Claude 백그라운드 끝 알림")
        let data = Data(claudeBackgroundLines.utf8)
        let url = URL(fileURLWithPath: "/tmp/\(claudeBackgroundSession).jsonl")
        let summary = ClaudeTranscript.summary(of: data, fileURL: url)
        await t.check("요약: 사용자 메시지 1 (끝 알림은 세지 않는다), 제목은 사람의 요청",
                      summary?.userMessages == 1 && summary?.title == "백그라운드로 beta.txt 를 읽게 해", "\(String(describing: summary))")
        let transcript = ClaudeTranscript.transcript(of: data)
        let events = transcript.turns.first?.events ?? []
        await t.check("턴 1개 — 후속 턴의 답이 첫 턴에 붙는다",
                      transcript.turns.count == 1 && events.filter { $0.kind == .agentMessage }.map(\.text) == ["launched", "bg-done: beta first line"],
                      "\(transcript.turns.map(\.userText)) \(events.map { "\($0.kind) \($0.text.prefix(20))" })")
        await t.check("첫 턴 끝 시각은 후속 답의 시각까지 늘어난다",
                      transcript.turns.first?.endedAt == TranscriptSupport.date("2026-09-22T12:13:47.850Z"))
        await t.check("하위의 끝: 알림의 <status> (async_launched 결과는 끝이 아니다)",
                      transcript.subAgentEndings == ["toolu_bg1": .completed], "\(transcript.subAgentEndings)")
        // `origin` 이 없는 옛 형식도 접두어로 거른다.
        let old: [String: Any] = ["type": "user", "message": ["role": "user", "content": "<task-notification>\n<task-id>x</task-id>\n</task-notification>"]]
        await t.check("origin 없는 옛 형식의 끝 알림도 사람의 글이 아니다", ClaudeTranscript.userText(old) == nil)
    }

    /// 메인이 도는 중에 끝난 백그라운드 Agent 의 끝은 `attachment` 알림에만 있다 — 끝 상태로 읽고 턴 · 이벤트는 만들지 않는다.
    /// meta 에 `requestShape` 가 없는 옛 CLI 는 `async_launched` 결과로 백그라운드를 판정한다.
    static func claudeQueuedNotification(_ t: TestKit) async {
        await t.group("가져오기 · Claude 도는 중에 온 끝 알림 (attachment)")
        let transcript = ClaudeTranscript.transcript(of: Data(claudeQueuedLines.utf8))
        await t.check("끝 상태: 글 · text 블록 알림 모두, 사이드체인의 알림은 무시",
                      transcript.subAgentEndings == ["toolu_q1": .completed, "toolu_q2": .failed], "\(transcript.subAgentEndings)")
        let events = transcript.turns.first?.events ?? []
        await t.check("턴 1개, 알림은 이벤트가 되지 않는다",
                      transcript.turns.count == 1
                          && events.map(\.kind) == [.toolRequest, .toolRequest, .toolResult, .toolResult, .toolRequest, .toolResult, .agentMessage],
                      "\(transcript.turns.map(\.userText)) \(events.map { "\($0.kind) \($0.title)" })")
        await t.check("백그라운드 호출: async_launched 결과의 호출 id", transcript.backgroundCalls == ["toolu_q1", "toolu_q2"],
                      "\(transcript.backgroundCalls)")

        let sub = Data(claudeSubAgentLines.utf8)
        func child(_ meta: [String: Any]) -> SubAgentInfo? {
            ClaudeTranscript.subAgent(of: sub, meta: meta, endings: transcript.subAgentEndings, backgroundCalls: transcript.backgroundCalls)?.info
        }
        let old = child(["agentType": "general-purpose", "description": "read alpha", "toolUseId": "toolu_q1"])
        await t.check("requestShape 없는 meta: async_launched 였던 호출은 백그라운드, 상태는 attachment 알림의 것",
                      old?.isBackground == true && old?.status == .completed, "\(String(describing: old))")
        await t.check("requestShape 없는 meta: async_launched 가 아니면 포그라운드",
                      child(["toolUseId": "toolu_fg"])?.isBackground == false)
        await t.check("requestShape 가 있으면 그것이 우선",
                      child(["toolUseId": "toolu_q1", "requestShape": "foreground"])?.isBackground == false)
    }

    /// CLI 가 끼워 넣은 사용자 줄(`isMeta`)은 사람의 메시지 · 새 실행이 아니다. 사람이 친 슬래시 명령은 명령 글로 턴을 연다.
    static func claudeMetaLines(_ t: TestKit) async {
        await t.group("가져오기 · Claude isMeta 사용자 줄")
        let url = URL(fileURLWithPath: "/tmp/\(claudeMetaSession).jsonl")
        let transcript = ClaudeTranscript.transcript(of: Data(claudeMetaLines.utf8))
        await t.check("턴: 사람의 요청 · 그림 메시지 · 친 슬래시 명령 (스킬 본문 · 이미지 안내 · 이어가기 · /usage 는 턴이 아니다)",
                      transcript.turns.map(\.userText) == ["스킬로 정리해", "이 그림 봐", "/tidy src 폴더"], "\(transcript.turns.map(\.userText))")
        let first = transcript.turns.first?.events ?? []
        await t.check("모델이 부른 스킬의 답은 같은 턴에 (본문이 턴을 가르지 않는다)",
                      first.map(\.kind) == [.toolRequest, .toolResult, .agentMessage] && first.last?.text == "정리했습니다.",
                      "\(first.map { "\($0.kind) \($0.text.prefix(20))" })")
        await t.check("이어가기 안내 뒤의 답은 앞 턴에, 명령 턴에는 스킬의 답",
                      transcript.turns.count == 3 && transcript.turns[1].events.map(\.text) == ["봤습니다.", "이어서."]
                          && transcript.turns[2].events.map(\.text) == ["src 를 정리했습니다."])
        let summary = ClaudeTranscript.summary(of: Data(claudeMetaLines.utf8), fileURL: url)
        await t.check("요약: 사용자 메시지 3, 제목은 첫 요청", summary?.userMessages == 3 && summary?.title == "스킬로 정리해",
                      "\(String(describing: summary))")
        let meta: [String: Any] = ["type": "user", "isMeta": true, "message": ["role": "user", "content": "Base directory for this skill: /x"]]
        await t.check("isMeta 줄은 사람의 글이 아니다", ClaudeTranscript.userText(meta) == nil)

        // 슬래시 명령으로 시작한 세션: 첫 턴을 잃지 않는다.
        let commandFirst = Data(claudeMetaLines.split(separator: "\n").suffix(3).joined(separator: "\n").utf8)
        let started = ClaudeTranscript.transcript(of: commandFirst)
        let startedSummary = ClaudeTranscript.summary(of: commandFirst, fileURL: url)
        await t.check("명령으로 시작한 세션: 턴 1 (명령 글 · 답), 요약의 사용자 메시지 1 · 제목은 명령",
                      started.turns.map(\.userText) == ["/tidy src 폴더"] && started.turns.first?.events.count == 1
                          && startedSummary?.userMessages == 1 && startedSummary?.title == "/tidy src 폴더",
                      "\(started.turns.map(\.userText)) \(String(describing: startedSummary))")
    }

    /// `<세션>/subagents/agent-*.jsonl` 은 따로 된 세션이 아니다. 가져올 때 부모 세션의 Agent 호출 아래에
    /// 실행 중 앱과 같은 모양(상태 행 + 부모 표시를 단 이벤트)으로 붙인다. 워크플로 안의 에이전트는 옮기지 않는다.
    static func claudeSubAgents(_ t: TestKit) async {
        await t.group("가져오기 · Claude 하위 에이전트 기록")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ahc-import-sub-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let project = root.appendingPathComponent("claude/-Users-me-probe")
        let subagents = project.appendingPathComponent("\(claudeBackgroundSession)/subagents")
        let workflow = subagents.appendingPathComponent("workflows/wf_1")
        try? fm.createDirectory(at: workflow, withIntermediateDirectories: true)
        let files: [(URL, String)] = [
            (project.appendingPathComponent("\(claudeBackgroundSession).jsonl"), claudeBackgroundLines),
            (subagents.appendingPathComponent("agent-a961.jsonl"), claudeSubAgentLines),
            (subagents.appendingPathComponent("agent-a961.meta.json"), claudeSubAgentMeta),
            (workflow.appendingPathComponent("agent-w1.jsonl"), claudeWorkflowAgentLines),
            (workflow.appendingPathComponent("agent-w1.meta.json"), claudeWorkflowAgentMeta),
        ]
        for (url, text) in files { try? text.write(to: url, atomically: true, encoding: .utf8) }

        let folders = SessionImportScanner.scan(claudeRoot: root.appendingPathComponent("claude"),
                                                codexRoot: root.appendingPathComponent("codex"), home: "/Users/me")
        let sessions = folders.flatMap(\.sessions)
        await t.check("스캔: 하위 · 워크플로 기록은 세션으로 잡히지 않는다 (세션 1개)",
                      sessions.map(\.cliSessionID) == [claudeBackgroundSession], "\(sessions.map(\.fileURL.lastPathComponent))")

        let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
        do {
            try await store.bootstrap()
            let result = await SessionImportService.run(folders: folders, store: store, existingProjects: [])
            let projects = try await store.projects()
            let thread = try await store.threads(projectID: projects.first?.id ?? "").first
            let runs = try await store.runs(threadID: thread?.id ?? "")
            let events = try await store.events(threadID: thread?.id ?? "")
            await t.check("스레드 1 · 실행 1 (후속 턴은 같은 실행)", result.threadsAdded == 1 && runs.count == 1, "\(result) runs=\(runs.count)")
            let row = events.first { $0.kind == .subAgent }
            let info = row?.subAgentInfo
            await t.check("상태 행: 실행 중 앱과 같은 ID, 호출 id · 설명 · 종류 · 백그라운드 · 알림의 상태 · 하위의 마지막 답",
                          row?.id == ThreadEvent.subAgentEventID(runID: runs.first?.id ?? "", agentID: "toolu_bg1")
                              && info?.id == "toolu_bg1" && info?.kind == .agent && info?.title == "slow read"
                              && info?.detail == "general-purpose" && info?.isBackground == true && info?.status == .completed
                              && info?.summary == "beta first line" && info?.endedAt == TranscriptSupport.date("2026-09-22T12:13:45.897Z"),
                          "\(String(describing: info))")
            let children = events.filter { $0.parentAgentID == "toolu_bg1" }
            await t.check("하위 이벤트: 요청 안내 → Read 요청 · 결과 → 답, 모두 부모 표시 (thinking · attachment 제외)",
                          children.map(\.kind) == [.systemNotice, .toolRequest, .toolResult, .agentMessage]
                              && children[0].text == "요청: beta.txt 를 읽어라" && children[1].title == "Read" && children[2].title == "Read"
                              && children[2].toolUseID == "toolu_r1" && children.allSatisfy { $0.runID == runs.first?.id },
                          "\(children.map { "\($0.kind) \($0.title) \($0.text.prefix(20))" })")
            let main = events.filter(\.isMainStream)
            await t.check("메인 흐름은 그대로: 안내 · 사람의 요청 1 · Agent 호출 · 결과 · 답 둘 (하위 글이 섞이지 않는다)",
                          main.map(\.kind) == [.systemNotice, .userMessage, .toolRequest, .toolResult, .agentMessage, .agentMessage]
                              && main.filter { $0.kind == .agentMessage }.map(\.text) == ["launched", "bg-done: beta first line"],
                          "\(main.map { "\($0.kind) \($0.text.prefix(20))" })")
            await t.check("워크플로 안의 에이전트 기록은 옮기지 않는다", !events.contains { $0.text.contains("워크플로 안의 요청") })
            await t.check("하위 행은 시각순으로 메인 사이에 (상태 행은 Agent 호출 바로 뒤)",
                          events.firstIndex { $0.kind == .subAgent } == events.firstIndex { $0.toolUseID == "toolu_bg1" }.map { $0 + 1 })
        } catch {
            await t.check("하위 에이전트 기록 가져오기", false, "\(error)")
        }
    }

    // MARK: Codex

    static func codexParsing(_ t: TestKit) async {
        await t.group("가져오기 · Codex 파싱")
        let data = Data(codexLines.utf8)
        let summary = CodexTranscript.summary(of: data, fileURL: URL(fileURLWithPath: "/tmp/rollout.jsonl"))
        await t.check("요약: session_meta 의 id · cwd · 버전, 제목은 첫 사용자 메시지, 앱 맥락 메시지는 세지 않음",
                      summary?.cliSessionID == "c0dec0de-0005" && summary?.cwd == "/Users/me/demo-project" && summary?.cliVersion == "0.153.4"
                          && summary?.title == "광고 영상 만들어줘" && summary?.userMessages == 1, "\(String(describing: summary))")
        let transcript = CodexTranscript.transcript(of: data)
        let events = transcript.turns.first?.events ?? []
        await t.check("item_completed 기준: 명령 · MCP 요청/결과 · 파일 변경 · 응답 · 오류 (response_item function_call 은 겹치지 않게 제외, 빈 Reasoning 제외)",
                      transcript.turns.count == 1 && events.map(\.kind) == [.commandExecution, .toolRequest, .toolResult, .fileChange, .agentMessage, .error],
                      "\(events.map { "\($0.kind) \($0.title)" })")
        await t.check("명령은 zsh -lc 껍데기를 벗기고 출력 · 종료 코드 · cwd 를 payload 에",
                      events.first?.title == "rg --files | head -3" && events.first?.text.contains("--- 출력 ---\na\nb\nc") == true
                          && (JSONUtil.object(events.first?.payloadJSON ?? "")?["cwd"] as? String) == "/Users/me/demo-project"
                          && (JSONUtil.object(events.first?.payloadJSON ?? "")?["exitCode"] as? Int) == 0, "\(String(describing: events.first))")
        await t.check("파일 변경 제목은 경로, 본문에 내용", events[3].title == "/Users/me/demo-project/a.py" && events[3].text.contains("print(1)"))
        await t.check("모델은 world_state 의 collaboration_mode.model", transcript.turns.first?.model == "gpt-6-astra" && transcript.model == "gpt-6-astra")

        let old = CodexTranscript.transcript(of: Data(codexOldLines.utf8))
        let oldEvents = old.turns.first?.events ?? []
        await t.check("옛 기록(item_completed 없음): response_item 의 message · function_call · output 으로 턴을 만든다",
                      old.turns.count == 1 && old.turns[0].userText == "옛 형식 요청"
                          && oldEvents.map(\.kind) == [.toolRequest, .toolResult, .agentMessage] && oldEvents[0].title == "shell" && oldEvents[1].text == "a b",
                      "\(oldEvents.map { "\($0.kind) \($0.title)" })")
    }

    // MARK: 선별

    static func folderSelection(_ t: TestKit) async {
        await t.group("가져오기 · 폴더 선별")
        let home = "/Users/me"
        func rec(_ path: String, exists: Bool = true, git: Bool = false, count: Int = 1) -> Bool {
            SessionImportScanner.isRecommended(path: path, exists: exists, isGit: git, sessionCount: count, home: home)
        }
        await t.check("git 저장소는 세션 1개여도 선별", rec("/Users/me/app", git: true))
        await t.check("git 아니어도 세션 2개면 선별", rec("/Users/me/notes", count: 2))
        await t.check("세션 1개 · git 아님은 제외", !rec("/Users/me/scratch"))
        await t.check("없는 폴더 제외", !rec("/Users/me/gone", exists: false, git: true))
        await t.check("루트 · 홈 · 임시 폴더 · Codex 스크래치 · 작업 트리 제외",
                      !rec("/", git: true) && !rec("/Users/me", git: true) && !rec("/var/folders/ab/x", count: 9) && !rec("/private/tmp/x", count: 3)
                          && !rec("/Users/me/Documents/Codex/2026-07-20/new-chat", count: 3) && !rec("/Users/me/app/.claude/worktrees/w1", git: true))
        await t.check("경로 정규화: /private/var → /var, 끝 / 제거",
                      SessionImportScanner.normalizedPath("/private/var/folders/x/") == "/var/folders/x" && SessionImportScanner.normalizedPath("/Users/me/app/") == "/Users/me/app")

        let a = ImportedSessionSummary(provider: .claude, cliSessionID: "c1", fileURL: URL(fileURLWithPath: "/tmp/c1"), cwd: "/Users/me/app/",
                                       title: "a", startedAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2), userMessages: 1, cliVersion: nil)
        let b = ImportedSessionSummary(provider: .codex, cliSessionID: "x1", fileURL: URL(fileURLWithPath: "/tmp/x1"), cwd: "/Users/me/app",
                                       title: "b", startedAt: Date(timeIntervalSince1970: 3), updatedAt: Date(timeIntervalSince1970: 9), userMessages: 1, cliVersion: nil)
        let empty = ImportedSessionSummary(provider: .codex, cliSessionID: "x2", fileURL: URL(fileURLWithPath: "/tmp/x2"), cwd: "/Users/me/other",
                                           title: nil, startedAt: Date(), updatedAt: Date(), userMessages: 0, cliVersion: nil)
        let folders = SessionImportScanner.group([a, b, empty], home: home, exists: { _ in true }, isGit: { _ in false })
        await t.check("같은 폴더의 두 CLI 세션이 한 폴더로, 최근 순, 대화 없는 세션은 빠짐",
                      folders.count == 1 && folders[0].path == "/Users/me/app" && folders[0].sessions.map(\.cliSessionID) == ["x1", "c1"]
                          && folders[0].claudeCount == 1 && folders[0].codexCount == 1 && folders[0].recommended, "\(folders)")
    }

    // MARK: 저장

    static func storeRoundTrip(_ t: TestKit) async {
        await t.group("가져오기 · 저장 · 중복 방지")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ahc-import-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("\(claudeSession).jsonl")
        try? claudeLines.write(to: file, atomically: true, encoding: .utf8)
        let store = Store(databaseURL: dir.appendingPathComponent("db.sqlite3"))
        do {
            try await store.bootstrap()
            guard let summary = ClaudeTranscript.summary(of: Data(claudeLines.utf8), fileURL: file) else {
                await t.check("요약", false); return
            }
            let folder = ImportFolder(path: "/Users/me/demo-project", exists: true, isGitRepository: true, sessions: [summary], recommended: true)
            let first = await SessionImportService.run(folders: [folder], store: store, existingProjects: [])
            let projects = (try? await store.projects()) ?? []
            let threads = (try? await store.threads(projectID: projects.first?.id ?? "")) ?? []
            await t.check("프로젝트 1 · 스레드 1 생성, 제목은 custom-title, 제공자 Claude, 모델은 마지막 모델",
                          first.projectsAdded == 1 && first.threadsAdded == 1 && projects.count == 1 && projects[0].path == "/Users/me/demo-project"
                              && threads.first?.title == "발표 자료 수정" && threads.first?.preferredProvider == .claude
                              && threads.first?.claudeSelection.model == "claude-opus-5", "\(first) \(threads)")
            if let thread = threads.first {
                let session = try await store.session(threadID: thread.id, provider: .claude)
                let runs = try await store.runs(threadID: thread.id)
                let events = try await store.events(threadID: thread.id)
                await t.check("세션에 CLI 세션 ID · 전달 순번은 마지막 이벤트, 실행 2개(완료), 이벤트 = 안내 1 + 턴별 사용자 1 + 기록",
                              session?.cliSessionID == claudeSession && session?.lastDeliveredSeq == Int64(events.count)
                                  && runs.count == 2 && runs.allSatisfy { $0.state == .completed } && runs[0].model == "claude-fable-5-1"
                                  && events.first?.kind == .systemNotice && events.filter { $0.kind == .userMessage }.count == 2
                                  && events.filter { $0.kind == .agentMessage }.count == 2,
                              "session=\(String(describing: session)) runs=\(runs.count) events=\(events.map(\.kind))")
                await t.check("이벤트 시각은 원본 기록의 시각", events.filter { $0.kind == .userMessage }.first.map { Calendar.current.component(.year, from: $0.createdAt) } == 2026)
            }
            let second = await SessionImportService.run(folders: [folder], store: store, existingProjects: projects)
            let threadsAfter = (try? await store.threads(projectID: projects.first?.id ?? "")) ?? []
            await t.check("다시 실행하면 같은 세션은 건너뛰고 프로젝트도 다시 만들지 않는다",
                          second.projectsAdded == 0 && second.threadsAdded == 0 && second.skippedExisting == 1 && threadsAfter.count == 1, "\(second)")
        } catch {
            await t.check("저장 왕복", false, "\(error)")
        }
    }

    // MARK: 큰 기록 (onb-18) · 멈추기 (onb-8)

    /// 요약 줄 비교용 — 키를 정렬한 JSON.
    private static func canonical(_ lines: [[String: Any]]) -> [String] {
        lines.map { line in
            let data = (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// 파일을 조금씩 읽어 고른 줄 = 통째로 읽어 고른 줄 (조각 경계 · 빈 줄 · 끝 줄바꿈 없음 · 한 줄 파일).
    static func streamingSummary(_ t: TestKit) async {
        await t.group("가져오기 · 큰 기록을 조금씩 읽는다")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ahc-import-stream-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let blank = "\n\n" + claudeLines + "\n\n"
        let noTrailingNewline = claudeLines.trimmingCharacters(in: .newlines)
        let single = #"{"type":"user","sessionId":"x","cwd":"/a","timestamp":"2026-01-15T01:28:39.151Z","message":{"role":"user","content":"하나"}}"#
        let cases: [(String, String)] = [("claude", claudeLines), ("blank", blank), ("noTrailing", noTrailingNewline),
                                         ("codex", codexLines), ("single", single)]
        var mismatches: [String] = []
        for (name, text) in cases {
            let url = dir.appendingPathComponent(name + ".jsonl")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            let markers: [String] = name == "codex" ? CodexTranscript.summaryMarkers : ClaudeTranscript.summaryMarkers
            let whole: [String] = canonical(TranscriptSupport.summaryLines(Data(text.utf8), markers: markers))
            for chunk in [7, 64, 1 << 20] {
                let streamed = TranscriptSupport.summaryLines(fileURL: url, markers: markers, chunkSize: chunk).map(canonical)
                if streamed != whole { mismatches.append("\(name)/\(chunk)") }
            }
        }
        await t.check("조각 크기와 상관없이 통째로 읽은 것과 같다", mismatches.isEmpty, mismatches.joined(separator: ", "))
        await t.check("없는 파일은 nil", TranscriptSupport.summaryLines(fileURL: dir.appendingPathComponent("없음.jsonl"),
                                                                        markers: ClaudeTranscript.summaryMarkers) == nil)
        let file = dir.appendingPathComponent("claude.jsonl")
        let fromFile = SessionImportScanner.summarize(file: file, provider: .claude)
        let fromData = ClaudeTranscript.summary(of: Data(claudeLines.utf8), fileURL: file)
        await t.check("파일 요약 = 통째로 읽은 요약 (제목 · 사용자 메시지 수 · 시각)",
                      fromFile != nil && fromFile == fromData, "\(String(describing: fromFile))")
    }

    /// 훑기의 진행 · 멈춤: 일꾼은 넷까지, 진행은 끝에 (전체, 전체), 멈추면 빈 목록.
    static func scanProgressAndStop(_ t: TestKit) async {
        await t.group("가져오기 · 훑기 진행 · 멈춤")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ahc-import-scan-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let project = root.appendingPathComponent("claude/-Users-me-demo-project")
        try? fm.createDirectory(at: project, withIntermediateDirectories: true)
        for index in 0..<12 {
            let id = String(format: "b1c2d3e4-0000-4000-8001-%012d", index)
            let text = claudeLines.replacingOccurrences(of: claudeSession, with: id)
            try? text.write(to: project.appendingPathComponent(id + ".jsonl"), atomically: true, encoding: .utf8)
        }
        let lock = NSLock()
        var reports: [(Int, Int)] = []
        let folders = SessionImportScanner.scan(claudeRoot: root.appendingPathComponent("claude"),
                                                codexRoot: root.appendingPathComponent("codex"), home: "/Users/me",
                                                progress: { done, total in lock.lock(); reports.append((done, total)); lock.unlock() })
        await t.equal("세션 12개를 모두 읽는다", folders.flatMap(\.sessions).count, 12)
        await t.check("진행: 처음 (0, 12) · 끝 (12, 12)",
                      reports.first.map { $0 == (0, 12) } == true && reports.contains { $0 == (12, 12) }, "\(reports)")
        let stopped = SessionImportScanner.scan(claudeRoot: root.appendingPathComponent("claude"),
                                                codexRoot: root.appendingPathComponent("codex"), home: "/Users/me",
                                                isStopped: { true })
        await t.check("멈추면 빈 목록", stopped.isEmpty)
    }

    /// 가져오는 중에 멈추면 세션 하나를 마친 뒤 멈추고, 그때까지 가져온 것은 남는다 (onb-8).
    static func importStops(_ t: TestKit) async {
        await t.group("가져오기 · 멈추기")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ahc-import-stop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var sessions: [ImportedSessionSummary] = []
        for index in 0..<3 {
            let id = String(format: "b1c2d3e4-0000-4000-8002-%012d", index)
            let file = dir.appendingPathComponent(id + ".jsonl")
            let text = claudeLines.replacingOccurrences(of: claudeSession, with: id)
            try? text.write(to: file, atomically: true, encoding: .utf8)
            if var summary = ClaudeTranscript.summary(of: Data(text.utf8), fileURL: file) {
                summary.startedAt = summary.startedAt.addingTimeInterval(Double(index))
                sessions.append(summary)
            }
        }
        let folder = ImportFolder(path: "/Users/me/demo-project", exists: true, isGitRepository: true, sessions: sessions, recommended: true)
        let store = Store(databaseURL: dir.appendingPathComponent("db.sqlite3"))
        do {
            try await store.bootstrap()
            // 첫 세션을 쓰기 시작할 때 사람이 [멈추기] — 그 세션은 마치고 멈춘다.
            let task = Task { () -> SessionImportResult in
                await SessionImportService.run(folders: [folder], store: store, existingProjects: []) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            let result = await task.value
            await t.check("멈춤 · 세션 하나만 가져왔다", result.cancelled && result.threadsAdded == 1, "\(result)")
            let projects = try await store.projects()
            await t.equal("그때까지 가져온 프로젝트는 남는다", projects.count, 1)

            // 시작하기 전에 멈췄으면 아무것도 쓰지 않는다 (빈 프로젝트도 없다).
            let store2 = Store(databaseURL: dir.appendingPathComponent("db2.sqlite3"))
            try await store2.bootstrap()
            let early = Task { () -> SessionImportResult in
                withUnsafeCurrentTask { $0?.cancel() }
                return await SessionImportService.run(folders: [folder], store: store2, existingProjects: [])
            }
            let none = await early.value
            let projects2 = try await store2.projects()
            await t.check("시작 전에 멈추면 아무것도 쓰지 않는다", none.cancelled && none.threadsAdded == 0 && projects2.isEmpty, "\(none)")
        } catch {
            await t.check("멈추기 시험 중 예외", false, "\(error)")
        }
    }
}
