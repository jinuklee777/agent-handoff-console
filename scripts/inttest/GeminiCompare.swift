import Foundation

/// 실제 대화 1개로 규칙 초안과 Gemini 정리본을 나란히 만든다.
///
///     inttest geminicompare <handoff.sqlite3 | codex-rollout.jsonl> [--thread=<ID>] [--model=<slug>]
///                           [--repo=<경로> --base=<rev> --head=<rev>] [--out=<폴더>] [--dry-run]
///
/// - 앱 DB 는 **사본**을 열어 읽는다 (마이그레이션이 원본을 고쳐 쓰지 않게). 스레드를 안 주면 이벤트가 가장 많은 것.
///   설정의 프로젝트별 Gemini 전송 끄기를 따른다.
/// - Codex 세션 기록(`~/.codex/sessions/…/rollout-*.jsonl`)은 앱 이벤트로 바꿔 넣는다. 앱 DB 가 없는 Mac 용.
/// - 결과(`rule.md`, `gemini.md`, `gemini-input.txt`, `metrics.txt`)에는 대화 내용이 들어 있으므로
///   저장소 밖(기본 `build/geminicompare`, Git 제외)에 둔다.
/// - 실제 대화(마스킹 후 최대 15만 바이트)가 Antigravity CLI 로 전송된다.
///   `--dry-run` 은 보내지 않고 규칙 초안과 보낼 입력(`gemini-input.txt`)만 만든다. 먼저 이것으로 내용을 확인한다.
enum GeminiCompare {
    struct Options {
        var source: String
        var threadID: String?
        var model: String?
        var repo: String?
        var base: String?
        var head: String?
        var out: String
        var dryRun = false
    }

    static func options(_ arguments: [String]) -> Options? {
        guard let index = arguments.firstIndex(where: { $0.lowercased() == "geminicompare" }),
              arguments.count > index + 1 else { return nil }
        var o = Options(source: arguments[index + 1],
                        out: FileManager.default.currentDirectoryPath + "/build/geminicompare")
        for a in arguments {
            if a.hasPrefix("--thread=") { o.threadID = String(a.dropFirst("--thread=".count)) }
            if a.hasPrefix("--model=") { o.model = String(a.dropFirst("--model=".count)) }
            if a.hasPrefix("--repo=") { o.repo = String(a.dropFirst("--repo=".count)) }
            if a.hasPrefix("--base=") { o.base = String(a.dropFirst("--base=".count)) }
            if a.hasPrefix("--head=") { o.head = String(a.dropFirst("--head=".count)) }
            if a.hasPrefix("--out=") { o.out = String(a.dropFirst("--out=".count)) }
            if a == "--dry-run" { o.dryRun = true }
        }
        return o
    }

    struct Source {
        var thread: ConversationThread
        var project: Project
        var events: [ThreadEvent]
        var runs: [Run]
        var previous: HandoffPacket?
        var git: GitSnapshot
        var from: AgentProvider
        var to: AgentProvider
        var label: String
    }

    static func run(_ t: TestKit, _ o: Options) async {
        await t.group("Gemini 요약 품질 비교")
        let outDir = URL(fileURLWithPath: o.out, isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let loaded: Source?
        if o.source.hasSuffix(".jsonl") {
            loaded = await fromCodexRollout(o)
        } else {
            loaded = await fromDatabase(t, o, outDir: outDir)
        }
        guard let source = loaded else {
            await t.check("기록 불러오기", false, o.source)
            return
        }
        await t.check("기록 불러오기", !source.events.isEmpty,
                      "\(source.label) · 이벤트 \(source.events.count)건")

        // ① 규칙 초안 — 앱의 prepareHandoff 와 같은 입력
        let baseSeq = source.events.map(\.seq).max() ?? 0
        var rule = HandoffPacketBuilder.build(.init(
            thread: source.thread, project: source.project, fromProvider: source.from, toProvider: source.to,
            events: source.events, runs: source.runs, lastConfirmedPacket: source.previous,
            git: source.git, baseSeq: baseSeq))
        rule.summarySource = "rule"
        let ruleText = HandoffPacketBuilder.render(rule, threadTitle: source.thread.title,
                                                   projectPath: source.project.path)

        // ② Gemini 정리 → ③ 앱 검증 → ④ 병합
        let prompt = GeminiAssistInputBuilder.build(
            thread: source.thread, project: source.project, events: source.events, runs: source.runs,
            previousPacket: source.previous, rulePacket: rule, git: source.git)
        let service = GeminiAssistService(environment: CLIEnvironment())
        let models = await service.models()
        let model = o.model
            ?? models.first(where: { $0.hasPrefix("gemini-") && $0.contains("flash-low") })
            ?? models.first(where: { $0.hasPrefix("gemini-") })
        var metrics: [String] = [
            "원본: \(source.label)",
            "이벤트: \(source.events.count)건 (사용자 \(source.events.filter { $0.kind == .userMessage }.count), "
                + "에이전트 \(source.events.filter { $0.kind == .agentMessage }.count), "
                + "명령 \(source.events.filter { $0.kind == .commandExecution }.count), "
                + "파일 변경 \(source.events.filter { $0.kind == .fileChange }.count))",
            "Gemini 입력: \(prompt.utf8.count) 바이트 (\(prompt.count)자)"
                + (prompt.range(of: #"오래된 \d+건 생략"#, options: .regularExpression)
                    .map { " · " + prompt[$0] } ?? ""),
            "규칙 초안: \(ruleText.count)자 · \(ruleText.utf8.count) 바이트",
            "모델: \(model ?? "agy 기본")",
        ]
        try? prompt.write(to: outDir.appendingPathComponent("gemini-input.txt"), atomically: true, encoding: .utf8)
        try? ruleText.write(to: outDir.appendingPathComponent("rule.md"), atomically: true, encoding: .utf8)
        if o.dryRun {
            for line in metrics { await t.note(line) }
            await t.note("--dry-run: Gemini 로 보내지 않았습니다. 결과 폴더: \(outDir.path)")
            return
        }

        let started = Date()
        do {
            let response = try await service.summarize(prompt: prompt, model: model)
            let elapsed = Date().timeIntervalSince(started)
            let validated = GeminiAssistValidator.validate(response.summary, events: source.events)
            let merged = GeminiAssistValidator.merge(validated, into: rule, model: response.model)
            let geminiText = HandoffPacketBuilder.render(merged, threadTitle: source.thread.title,
                                                         projectPath: source.project.path)
            try? geminiText.write(to: outDir.appendingPathComponent("gemini.md"), atomically: true, encoding: .utf8)
            if let raw = try? JSONEncoder().encode(response.summary) {
                try? raw.write(to: outDir.appendingPathComponent("gemini-raw.json"))
            }
            let s = response.summary, v = validated.summary
            metrics += [
                "Gemini 정리본: \(geminiText.count)자 · \(geminiText.utf8.count) 바이트",
                String(format: "Gemini 응답 시간: %.1f초", elapsed),
                "Gemini 토큰: 입력 \(response.usage.inputTokens) · 출력 \(response.usage.outputTokens) "
                    + "(추론 \(response.usage.thinkingTokens)) · 합계 \(response.usage.totalTokens)",
                "항목 (검증 전 → 후): 진행 \(s.progress.count)→\(v.progress.count), "
                    + "다음 행동 \(s.nextActions.count)→\(v.nextActions.count), "
                    + "결정 \(s.decisions.count)→\(v.decisions.count), "
                    + "실패 \(s.failedAttempts.count)→\(v.failedAttempts.count), "
                    + "주의 \(s.cautions.count)→\(v.cautions.count)",
                "검증 경고: \(validated.warnings.count)건",
            ] + validated.warnings.map { "  - \($0)" }
            await t.check("Gemini 정리 성공", true, String(format: "%.1f초", elapsed))
            await t.check("검증 뒤 다음 행동 남음", !v.nextActions.isEmpty,
                          v.nextActions.map(\.text).joined(separator: " | "))
        } catch {
            metrics.append("Gemini 실패: \(error.localizedDescription)")
            await t.check("Gemini 정리 성공", false, error.localizedDescription)
        }
        let report = metrics.joined(separator: "\n")
        try? report.write(to: outDir.appendingPathComponent("metrics.txt"), atomically: true, encoding: .utf8)
        for line in metrics { await t.note(line) }
        await t.note("결과 폴더: \(outDir.path)")
    }

    // MARK: - 앱 DB (사본)

    private static func fromDatabase(_ t: TestKit, _ o: Options, outDir: URL) async -> Source? {
        let copy = outDir.appendingPathComponent("handoff-copy.sqlite3")
        try? FileManager.default.removeItem(at: copy)
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: o.source), to: copy)
        } catch {
            await t.note("DB 사본을 만들지 못했습니다: \(error.localizedDescription)")
            return nil
        }
        let store = Store(databaseURL: copy)
        defer { Task { await store.db.close() } }
        guard (try? await store.bootstrap()) != nil else { return nil }
        let threads = (try? await store.allThreads()) ?? []
        var chosen = threads.first { $0.id == o.threadID }
        if chosen == nil {
            var best = 0
            for thread in threads {
                let count = ((try? await store.events(threadID: thread.id)) ?? []).count
                if count > best { best = count; chosen = thread }
            }
        }
        guard let thread = chosen,
              let project = ((try? await store.projects()) ?? []).first(where: { $0.id == thread.projectID })
        else { return nil }
        if let raw = try? await store.setting("gemini_excluded_projects"),
           let excluded = try? JSONDecoder().decode(Set<String>.self, from: Data(raw.utf8)),
           excluded.contains(project.id) {
            await t.note("프로젝트 '\(project.name)' 은 Gemini 전송이 꺼져 있어 비교하지 않습니다.")
            return nil
        }
        let handoffs = (try? await store.handoffs(threadID: thread.id)) ?? []
        let previous = handoffs.last { $0.deliveryState == .delivered }
        let previousPacket = previous.flatMap {
            try? JSONDecoder().decode(HandoffPacket.self, from: Data($0.draftJSON.utf8))
        }
        let all = (try? await store.events(threadID: thread.id)) ?? []
        let scoped = all.filter { $0.seq > (previous?.baseSeq ?? 0) }
        let runs = ((try? await store.runs(threadID: thread.id)) ?? [])
            .filter { $0.startedAt >= (previous?.createdAt ?? .distantPast) }
        let env = await CLIEnvironment().childEnvironment()
        let git = await GitInspector.snapshot(at: project.url, environment: env)
        return Source(thread: thread, project: project,
                      events: scoped.isEmpty ? Array(all.suffix(80)) : scoped, runs: runs,
                      previous: previousPacket, git: git, from: thread.preferredProvider,
                      to: thread.preferredProvider.other,
                      label: "앱 DB 스레드 '\(thread.title)' (git 은 현재 상태)")
    }

    // MARK: - Codex 세션 기록

    private static func fromCodexRollout(_ o: Options) async -> Source? {
        guard let text = try? String(contentsOfFile: o.source, encoding: .utf8) else { return nil }
        let imported = CodexRolloutImporter.events(text, threadID: "compare")
        let cwd = o.repo ?? imported.cwd ?? FileManager.default.currentDirectoryPath
        let project = Project(id: "compare", name: (cwd as NSString).lastPathComponent, path: cwd)
        let thread = ConversationThread(id: "compare", projectID: project.id,
                                        title: "Codex 세션 " + ((o.source as NSString).lastPathComponent))
        var git = GitSnapshot()
        let env = await CLIEnvironment().childEnvironment()
        if let base = o.base, let head = o.head {
            // 기록이 끝난 시점의 작업 트리를 커밋 두 개로 재현한다 (이후 작업이 섞이지 않게).
            git.isRepository = true
            git.branch = "main"
            if case .success(let names) = await CLIEnvironment.captureOutput(
                executable: "/usr/bin/git", arguments: ["diff", "--name-status", base, head],
                environment: env, workingDirectory: URL(fileURLWithPath: cwd), timeout: 30) {
                for line in names.split(separator: "\n") {
                    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    if parts[0] == "A" { git.untracked.append(parts[1]) } else { git.unstaged.append(parts[1]) }
                }
            }
            if case .success(let diff) = await CLIEnvironment.captureOutput(
                executable: "/usr/bin/git", arguments: ["diff", "--no-color", base, head],
                environment: env, workingDirectory: URL(fileURLWithPath: cwd), timeout: 30) {
                git.diffExcerpt = JSONUtil.truncate("# unstaged\n" + diff, max: HandoffPacketBuilder.diffCharLimit)
            }
        } else {
            git = await GitInspector.snapshot(at: URL(fileURLWithPath: cwd), environment: env)
        }
        return Source(thread: thread, project: project, events: imported.events, runs: [],
                      previous: nil, git: git, from: .codex, to: .claude,
                      label: "Codex 세션 기록 \((o.source as NSString).lastPathComponent)")
    }
}

/// Codex 세션 기록(rollout JSONL)을 앱 이벤트로 바꾼다. 비교 도구 전용.
/// 암호화된 추론과 시스템이 끼워 넣은 메시지는 뺀다.
enum CodexRolloutImporter {
    static func events(_ text: String, threadID: String) -> (events: [ThreadEvent], cwd: String?) {
        var events: [ThreadEvent] = []
        var cwd: String?
        var pending: [String: ThreadEvent] = [:]
        var order: [String] = []
        func append(_ event: ThreadEvent) {
            var e = event
            e.seq = Int64(events.count + 1)
            events.append(e)
        }
        for line in text.split(separator: "\n") {
            guard let object = JSONUtil.object(String(line)) else { continue }
            let payload = object["payload"] as? [String: Any] ?? [:]
            switch object["type"] as? String {
            case "session_meta":
                cwd = payload["cwd"] as? String
            case "compacted":
                let summary = payload["message"] as? String ?? ""
                append(ThreadEvent(threadID: threadID, kind: .systemNotice, provider: .codex,
                                   title: "대화 압축", text: summary.isEmpty ? "(요약 없음)" : summary))
            case "response_item":
                switch payload["type"] as? String {
                case "message":
                    let role = payload["role"] as? String
                    let body = texts(payload["content"]).joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !body.isEmpty else { continue }
                    if role == "user", !body.hasPrefix("<"), !body.hasPrefix("# AGENTS.md") {
                        append(ThreadEvent(threadID: threadID, kind: .userMessage, provider: .codex, text: body))
                    } else if role == "assistant" {
                        append(ThreadEvent(threadID: threadID, kind: .agentMessage, provider: .codex, text: body))
                    }
                case "custom_tool_call", "function_call":
                    guard let callID = payload["call_id"] as? String else { continue }
                    let name = payload["name"] as? String ?? "도구"
                    let input = payload["input"] as? String ?? payload["arguments"] as? String ?? ""
                    pending[callID] = callEvent(name: name, input: input, threadID: threadID, cwd: cwd)
                    order.append(callID)
                case "custom_tool_call_output", "function_call_output":
                    guard let callID = payload["call_id"] as? String, var event = pending.removeValue(forKey: callID)
                    else { continue }
                    let output = (payload["output"] as? String) ?? texts(payload["output"]).joined(separator: "\n")
                    if event.kind == .commandExecution {
                        event.text += "\n\n--- 출력 ---\n" + output
                        if let code = exitCode(output) {
                            event.payloadJSON = JSONUtil.line(["status": "completed", "exitCode": code])
                        }
                    } else if event.kind == .toolResult {
                        event.text += "\n" + output
                    }
                    append(event)
                default:
                    continue
                }
            default:
                continue
            }
        }
        // 출력 없이 끝난 호출(기록이 끊긴 지점)도 남긴다.
        for id in order { if let event = pending[id] { append(event) } }
        return (events, cwd)
    }

    private static func callEvent(name: String, input: String, threadID: String, cwd: String?) -> ThreadEvent {
        if input.contains("apply_patch") || input.contains("*** Begin Patch") {
            let paths = matches(#"\*\*\* (?:Update|Add|Delete) File: ([^\\\n"]+)"#, in: input)
                .map { relative($0, to: cwd) }
            return ThreadEvent(threadID: threadID, kind: .fileChange, provider: .codex,
                               title: paths.joined(separator: ", "), text: paths.joined(separator: "\n"),
                               payloadJSON: JSONUtil.line(["status": "completed"]))
        }
        // exec 도구 입력은 JS 코드다. `cmd: "…"` 와 `{"cmd":"…"}` 두 형태가 모두 나온다.
        let commands = matches(#""?cmd"?\s*:\s*"((?:[^"\\]|\\.)*)""#, in: input).map(unescape)
        if let command = commands.first {
            return ThreadEvent(threadID: threadID, kind: .commandExecution, provider: .codex,
                               title: JSONUtil.truncate(command, max: 160, marker: "…"),
                               text: commands.joined(separator: "\n"))
        }
        return ThreadEvent(threadID: threadID, kind: .toolResult, provider: .codex,
                           title: name, text: JSONUtil.truncate(input, max: 400))
    }

    private static func texts(_ value: Any?) -> [String] {
        (value as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
    }

    private static func exitCode(_ output: String) -> Int? {
        for pattern in [#""exit_code":\s*(-?\d+)"#, #"[Pp]rocess exited with code (-?\d+)"#] {
            if let value = matches(pattern, in: output).first, let code = Int(value) { return code }
        }
        return nil
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func unescape(_ js: String) -> String {
        js.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func relative(_ path: String, to cwd: String?) -> String {
        guard let cwd, path.hasPrefix(cwd + "/") else { return path }
        return String(path.dropFirst(cwd.count + 1))
    }
}
