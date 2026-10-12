import Foundation

/// 입력창의 "/" 목록 한 줄 — CLI 가 알려 준 명령 · 스킬 (`SlashCommands`). 앱을 다시 켜도 바로 보이게 저장한다 (설정 `slash_commands`).
struct SlashCommand: Hashable, Codable, Sendable {
    /// "/" (Codex 는 "$") 뒤에 칠 이름.
    var name: String
    var description: String
    /// 인수 안내 ("[issue description]") — 없으면 빈 글.
    var argumentHint: String = ""
    /// 같은 명령의 다른 이름 (Claude 의 `aliases` — "/cost" → usage).
    var aliases: [String] = []
    /// Codex 스킬의 SKILL.md 경로 — 보낼 때 `{"type":"skill"}` 입력으로 넘긴다. Claude 는 nil.
    var path: String?
}

/// 보낼 때 Codex 에 함께 넘길 스킬 (`turn/start` 의 입력 `{"type":"skill","name","path"}`).
struct SkillMention: Hashable, Sendable {
    var name: String
    var path: String
}

/// 입력창 "/" 목록의 키 — 에이전트 · Codex 계정 · 대화가 일하는 폴더 (폴더마다 `.claude/skills` · 저장소 스킬이 다르다).
struct SlashCommandKey: Hashable, Codable, Sendable {
    var provider: AgentProvider
    /// Codex 계정 ID (Claude 는 빈 글 — `AgentScope` 와 같다).
    var accountID: String
    var folder: String
}

/// 한 에이전트 · 계정 · 폴더의 목록. 받지 못했으면 `message` 에 까닭.
struct SlashCommandList: Sendable {
    var commands: [SlashCommand] = []
    var fetchedAt: Date?
    var message: String?
}

/// 입력창의 "/" 목록 — **순수 판정**(검증 하네스가 컴파일)과 CLI 조회.
///
/// - Claude: `claude -p` (stream-json) 에 `initialize` 제어 요청만 보내면 응답의 `commands` 에 명령 · 스킬이 이름 · 설명 · 인수 안내와
///   함께 온다 — 모델을 부르지 않고 0.3초 남짓 (2026-10-07 실측, claude 2.1.292). 그 폴더의 `.claude/skills` · 플러그인 스킬도 들어 있다.
///   보낼 때는 글 그대로 — 맨 앞의 "/이름 인수" 를 CLI 가 스킬 · 명령으로 펼친다 (같은 날 실측: stream-json 의 사용자 메시지로도 펼쳐진다).
///   실행마다 어댑터가 보내는 같은 `initialize` 의 응답도 목록으로 받아 둔다 (`AgentEvent.slashCommands` — 따로 띄우지 않는다).
/// - Codex: app-server 의 `skills/list` (폴더마다). Codex 의 스킬 표시는 "$이름" 이고, 앱이 보낼 때 글 속 "$이름" 마다
///   `{"type":"skill","name","path"}` 입력을 덧붙인다 (`codexMentions` → `CodexAdapter.turnParams`). Codex 의 "/" 명령은 TUI 의 것이라 없다.
/// - Antigravity: 목록이 없다.
enum SlashCommands {
    /// 앱에서 쓸 수 없거나 앱이 따로 맡는 Claude 명령 — 목록에서 뺀다.
    /// 터미널 전용(`init` 의 `terminal_slash_commands`: color · focus · reload-plugins · doctor)과, 앱이 턴마다 정하는 것(모델 · 강도 ·
    /// fast — 다음 턴에 앱이 다시 넘겨 되돌아간다)과 세션을 바꾸는 clear(앱은 세션 ID 로 이어 간다 — 새 대화는 ⌘N).
    static let claudeHidden: Set<String> = ["color", "focus", "reload-plugins", "doctor", "clear", "model", "effort", "fast"]

    /// 목록이 오래됐다고 보는 시간 — 스킬을 새로 깔았을 수 있다. 목록을 열 때 이보다 오래됐으면 뒤에서 다시 받는다.
    static let staleAfter: TimeInterval = 300

    // MARK: 해석

    /// Claude `initialize` 응답(`response.response`)의 `commands` → 목록. 숨길 것 · 칠 수 없는 이름(빈칸이 든 MCP 프롬프트 ·
    /// "__" 로 시작하는 내부 명령)은 뺀다. 순서는 CLI 의 것 그대로 (스킬이 앞에 온다).
    static func parseClaude(_ response: [String: Any]) -> [SlashCommand] {
        let raw = response["commands"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        return raw.compactMap { item in
            guard let name = item["name"] as? String, isTypeable(name), !name.hasPrefix("__"),
                  !claudeHidden.contains(name), seen.insert(name).inserted else { return nil }
            return SlashCommand(name: name,
                                description: oneLine(item["description"] as? String ?? ""),
                                argumentHint: (item["argumentHint"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                                aliases: (item["aliases"] as? [String] ?? []).filter(isTypeable))
        }
    }

    /// Codex `skills/list` 결과(`result`) → 켠 스킬만. 설명은 짧은 설명이 있으면 그것 (`interface.shortDescription` → `shortDescription`).
    static func parseCodexSkills(_ result: [String: Any]) -> [SlashCommand] {
        let groups = result["data"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        var out: [SlashCommand] = []
        for group in groups {
            for skill in group["skills"] as? [[String: Any]] ?? [] {
                guard (skill["enabled"] as? Bool) != false,
                      let name = skill["name"] as? String, isTypeable(name),
                      let path = skill["path"] as? String, !path.isEmpty,
                      seen.insert(name).inserted else { continue }
                let interface = skill["interface"] as? [String: Any]
                let short = (interface?["shortDescription"] as? String) ?? (skill["shortDescription"] as? String)
                let description = short.flatMap { $0.isEmpty ? nil : $0 } ?? (skill["description"] as? String ?? "")
                out.append(SlashCommand(name: name, description: oneLine(description), path: path))
            }
        }
        return out
    }

    /// 입력창에 칠 수 있는 이름 — 빈칸 · 줄바꿈이 없다.
    static func isTypeable(_ name: String) -> Bool {
        !name.isEmpty && name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    /// 여러 줄 설명을 한 줄로.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: 입력창

    /// 목록을 띄울 글자. Claude 는 "/", Codex 는 "/" · "$" (Codex 의 스킬 표시는 "$"), Antigravity 는 없다.
    static func triggers(for provider: AgentProvider) -> [Character] {
        switch provider {
        case .claude: return ["/"]
        case .codex: return ["/", "$"]
        case .gemini: return []
        }
    }

    /// 입력창 글이 목록을 띄울 꼴이면 찾을 말 — 맨 앞이 띄우는 글자이고 그 뒤에 빈칸 · 줄바꿈이 없다 (인수를 치기 시작하면 닫는다).
    /// "/Users/…" 처럼 경로를 친 것("/" 가 또 나온다)도 닫는다.
    static func query(in text: String, provider: AgentProvider) -> String? {
        guard let first = text.first, triggers(for: provider).contains(first) else { return nil }
        let rest = text.dropFirst()
        guard rest.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, !rest.contains("/") else { return nil }
        return String(rest)
    }

    /// 찾을 말에 맞는 것: 이름이 그 말로 시작 → ":" 뒤 부분(플러그인 스킬 "anthropic-skills:pdf" 의 "pdf")이 그 말로 시작 → 다른 이름이
    /// 그 말로 시작 → 이름에 그 말이 든 것. 대소문자를 가리지 않고, 같은 단계 안에서는 CLI 의 순서.
    static func matches(_ commands: [SlashCommand], query: String) -> [SlashCommand] {
        let q = query.lowercased()
        guard !q.isEmpty else { return commands }
        func tier(_ c: SlashCommand) -> Int? {
            let name = c.name.lowercased()
            if name.hasPrefix(q) { return 0 }
            if name.split(separator: ":").dropFirst().contains(where: { $0.hasPrefix(q) }) { return 1 }
            if c.aliases.contains(where: { $0.lowercased().hasPrefix(q) }) { return 2 }
            if name.contains(q) { return 3 }
            return nil
        }
        return commands.enumerated()
            .compactMap { offset, c in tier(c).map { (tier: $0, offset: offset, command: c) } }
            .sorted { ($0.tier, $0.offset) < ($1.tier, $1.offset) }
            .map(\.command)
    }

    /// 고른 것을 넣은 입력창 글 — Claude "/이름 ", Codex "$이름 " (Codex 가 알아보는 스킬 표시).
    static func inserted(_ command: SlashCommand, provider: AgentProvider) -> String {
        (provider == .codex ? "$" : "/") + command.name + " "
    }

    /// 화면에 보일 이름 ("/code-review" · "$pdf").
    static func shownName(_ command: SlashCommand, provider: AgentProvider) -> String {
        (provider == .codex ? "$" : "/") + command.name
    }

    /// 보낼 글이 Claude 의 "/명령" 인지 — 맨 앞이 "/" 이고 첫 낱말에 "/" 가 더 없다 ("/Users/…" 같은 경로는 아니다).
    /// 이 글 앞에 앱의 안내를 붙이면 CLI 가 명령으로 펼치지 않는다 (`AppModel.sendPreparing` 이 안내를 다음 턴으로 미룬다).
    static func isClaudeInvocation(_ prompt: String) -> Bool {
        guard prompt.first == "/" else { return false }
        let word = prompt.dropFirst().prefix { !$0.isWhitespace }
        guard let head = word.first, head.isLetter || head.isNumber else { return false }
        return !word.contains("/")
    }

    // MARK: Codex 스킬 표시

    /// 글 속 "$이름" 들 (이름에 쓰는 글자: 영숫자 · "-" · "_" · "." · ":").
    static func dollarTokens(in prompt: String) -> [String] {
        var tokens: [String] = []
        var index = prompt.startIndex
        while let dollar = prompt[index...].firstIndex(of: "$") {
            // 앞이 이름 글자면 표시가 아니다 ("a$b").
            if dollar > prompt.startIndex, isNameCharacter(prompt[prompt.index(before: dollar)]) {
                index = prompt.index(after: dollar)
                continue
            }
            let start = prompt.index(after: dollar)
            let end = prompt[start...].firstIndex { !isNameCharacter($0) } ?? prompt.endIndex
            if start < end { tokens.append(String(prompt[start..<end])) }
            index = end > start ? end : start
            if index == prompt.endIndex { break }
        }
        return tokens
    }

    private static func isNameCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "-" || c == "_" || c == "." || c == ":"
    }

    /// 글에 Codex 스킬일 수 있는 "$이름" 이 있는가 — 목록을 받아 둔 것이 없으면 보내기 전에 받는다.
    static func mayMentionCodexSkill(_ prompt: String) -> Bool {
        !dollarTokens(in: prompt).isEmpty
    }

    /// 글 속 "$이름" 가운데 목록에 있는 스킬 (나온 순서, 겹치지 않게). 문장 끝의 "." · ":" 는 떼고 다시 본다 ("$pdf." → pdf).
    static func codexMentions(in prompt: String, skills: [SlashCommand]) -> [SkillMention] {
        let byName = Dictionary(skills.compactMap { s in s.path.map { (s.name, $0) } }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var out: [SkillMention] = []
        for token in dollarTokens(in: prompt) {
            var name = token
            while byName[name] == nil, let last = name.last, last == "." || last == ":" { name.removeLast() }
            guard let path = byName[name], seen.insert(name).inserted else { continue }
            out.append(SkillMention(name: name, path: path))
        }
        return out
    }
}

// MARK: - CLI 조회

enum SlashCommandCatalog {
    /// Claude: `initialize` 제어 요청 하나로 받는다 (모델을 부르지 않는다). 그 폴더에서 띄워야 그 폴더의 스킬이 온다.
    /// 세션 기록은 남기지 않는다 (`--no-session-persistence`). 받으면 stdin 을 닫아 끝낸다.
    static func fetchClaude(path: String, environment: [String: String], workingDirectory: URL,
                            timeout: TimeInterval = 20) async -> SlashCommandList {
        let proc = ManagedProcess(executable: URL(fileURLWithPath: path),
                                  arguments: ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                                              "--verbose", "--no-session-persistence"],
                                  workingDirectory: workingDirectory, environment: environment)
        let stream = proc.makeStream()
        proc.launch()
        let requestID = "commands-\(UUID().uuidString)"
        let collected = UncheckedBox<[String: Any]?>(nil)
        let errorBox = UncheckedBox<String?>(nil)
        let reader = Task {
            for await out in stream {
                switch out {
                case .stdoutLine(let line):
                    guard let obj = JSONUtil.object(line), obj["type"] as? String == "control_response",
                          let response = obj["response"] as? [String: Any] else { continue }
                    if let id = response["request_id"] as? String, id != requestID { continue }
                    if response["subtype"] as? String == "error" {
                        errorBox.value = response["error"] as? String ?? "알 수 없는 오류"
                    } else {
                        collected.value = response["response"] as? [String: Any] ?? [:]
                    }
                    return
                case .stderrLine(let line):
                    if errorBox.value == nil, !line.trimmingCharacters(in: .whitespaces).isEmpty { errorBox.value = line }
                case .launchFailed(let message):
                    errorBox.value = message
                    return
                case .exited:
                    return
                }
            }
        }
        _ = proc.writeLine(JSONUtil.line([
            "type": "control_request",
            "request_id": requestID,
            "request": ["subtype": "initialize"],
        ]) ?? "")
        await race(reader, timeout: timeout)
        proc.closeStdin()
        _ = await proc.shutdown(graceSeconds: 2)
        return result(collected.value.map(SlashCommands.parseClaude), error: errorBox.value)
    }

    /// Codex: app-server 의 `skills/list` (그 폴더). 계정마다 스킬이 다를 수 있어 그 계정의 환경(`CODEX_HOME`)으로 띄운다.
    static func fetchCodex(path: String, environment: [String: String], workingDirectory: URL,
                           timeout: TimeInterval = 20) async -> SlashCommandList {
        let proc = ManagedProcess(executable: URL(fileURLWithPath: path), arguments: ["app-server", "--stdio"],
                                  workingDirectory: workingDirectory, environment: environment)
        let stream = proc.makeStream()
        proc.launch()
        let collected = UncheckedBox<[String: Any]?>(nil)
        let errorBox = UncheckedBox<String?>(nil)
        let reader = Task {
            for await out in stream {
                switch out {
                case .stdoutLine(let line):
                    guard let obj = JSONUtil.object(line), JSONUtil.int(obj["id"]) == 2 else { continue }
                    if let err = obj["error"] as? [String: Any] {
                        errorBox.value = err["message"] as? String ?? "알 수 없는 오류"
                    } else {
                        collected.value = obj["result"] as? [String: Any] ?? [:]
                    }
                    return
                case .stderrLine(let line):
                    if errorBox.value == nil, !line.trimmingCharacters(in: .whitespaces).isEmpty { errorBox.value = line }
                case .launchFailed(let message):
                    errorBox.value = message
                    return
                case .exited:
                    return
                }
            }
        }
        _ = proc.writeLine(JSONUtil.line([
            "method": "initialize",
            "params": ["clientInfo": ["name": "AgentHandoffConsole", "version": "0.1.0"]],
            "id": 1,
        ]) ?? "")
        _ = proc.writeLine(JSONUtil.line(["method": "initialized", "params": [:]]) ?? "")
        _ = proc.writeLine(JSONUtil.line([
            "method": "skills/list",
            "params": ["cwds": [workingDirectory.path]],
            "id": 2,
        ]) ?? "")
        await race(reader, timeout: timeout)
        _ = await proc.shutdown()
        return result(collected.value.map(SlashCommands.parseCodexSkills), error: errorBox.value)
    }

    /// 읽기가 끝나거나 시간이 다 될 때까지. 시간이 다 되면 읽기를 취소한다 — 출력 스트림의 `for await` 가 끝난다. (작업 묶음으로
    /// 기다리면 묶음이 `reader.value` 를 기다리는 자식이 끝나기를 기다려, 답도 끝도 없는 CLI 에서 시간 제한이 듣지 않는다.)
    private static func race(_ reader: Task<Void, Never>, timeout: TimeInterval) async {
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            reader.cancel()
        }
        await reader.value
        timer.cancel()
    }

    private static func result(_ commands: [SlashCommand]?, error: String?) -> SlashCommandList {
        if let commands { return SlashCommandList(commands: commands, fetchedAt: Date()) }
        return SlashCommandList(fetchedAt: Date(),
                                message: error.map { "목록을 받지 못했습니다: \(JSONUtil.truncate($0, max: 200))" }
                                    ?? "목록을 받지 못했습니다 (응답 없음).")
    }
}
