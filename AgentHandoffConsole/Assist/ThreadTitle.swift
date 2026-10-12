import Foundation

/// 대화 제목: 첫 메시지를 보내는 순간의 제목(첫 줄)과, 첫 턴이 끝난 뒤 작은 모델에게 받는 짧은 요약 제목.
///
/// Claude · Codex 앱의 짧은 제목은 그 앱이 모델을 한 번 더 불러 만든다 — 이 앱이 쓰는 `claude -p` · `codex app-server` 는 제목을
/// 만들지 않는다 (2026-10-07 확인: Claude 는 대화형 · 데스크톱 세션 기록에만 `ai-title` 줄, Codex 는 Codex 앱이 연 스레드에만
/// `session_index.jsonl` 의 `thread_name`, app-server 에는 이름을 붙이는 `thread/name/set` 만 있다). 그래서 앱이 직접 묻는다.
/// 요약은 **그 대화가 이미 쓰던 제공자에게만** 보낸다 — 새로 다른 회사로 나가는 내용이 없게. 판정 · 글은 순수, 묻기는 `summarize`.
enum ThreadTitle {
    /// 첫 메시지를 보내는 순간 붙이는 제목: 빈 줄과 태그로 감싼 덧붙은 맥락(`<recommended_plugins> … </recommended_plugins>` —
    /// 가져온 Codex 기록에서 그 머리 줄이 제목이 됐다)을 건너뛴 첫 줄에서 머리 기호를 떼고 34자. 쓸 줄이 없으면 "새 대화".
    static func fromMessage(_ prompt: String) -> String {
        let lines = prompt.split(whereSeparator: \.isNewline).map { line in
            line.trimmingCharacters(in: CharacterSet(charactersIn: "#*-` ").union(.whitespacesAndNewlines))
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.isEmpty { index += 1; continue }
            if isTagLine(line) {
                // 여는 태그면 닫는 태그까지 통째로 건너뛴다 (닫는 태그가 없으면 그 줄만).
                if !line.hasPrefix("</"), let name = tagName(line),
                   let close = lines[(index + 1)...].firstIndex(where: { $0 == "</\(name)>" }) {
                    index = close + 1
                } else {
                    index += 1
                }
                continue
            }
            return line.count > 34 ? String(line.prefix(34)) + "…" : line
        }
        return "새 대화"
    }

    /// 태그 줄의 이름 — `<name attr="…">` 의 name.
    private static func tagName(_ line: String) -> String? {
        let inner = line.dropFirst().dropLast()
        let name = inner.prefix { !$0.isWhitespace && $0 != "/" }
        return name.isEmpty ? nil : String(name)
    }

    /// `<…>` 하나로만 된 줄 — 여는 · 닫는 태그.
    static func isTagLine(_ line: String) -> Bool {
        guard line.hasPrefix("<"), line.hasSuffix(">"), line.count >= 3 else { return false }
        return !line.dropFirst().dropLast().contains { $0 == "<" || $0 == ">" }
    }

    /// 지금 제목이 앱이 첫 메시지로 붙인 그대로인가 — 사람이 이름을 바꿨으면 요약으로 덮지 않는다 (스키마를 바꾸지 않고 판정한다).
    /// 첫 메시지가 글 없이 이미지뿐이었으면 앱은 "이미지" 로 붙였다.
    static func isAutomatic(_ title: String, firstMessage: String) -> Bool {
        title == fromMessage(firstMessage.isEmpty ? "이미지" : firstMessage)
    }

    /// 요약 모델에게 주는 지시 (Claude 는 시스템 프롬프트, Codex 는 프롬프트 머리).
    static let instruction = """
        You write a short title for a conversation between a user and a coding agent. \
        Reply with only the title: a noun phrase of at most 20 characters, in the same language as the user message, \
        with no quotes, no trailing punctuation, no explanation. Do not use any tools.
        """

    /// 첫 메시지 · 첫 답에서 넣을 최대 글자 수.
    static let messageLimit = 1_400
    static let answerLimit = 600

    /// 요약에 넣는 글 (순수): 첫 사용자 메시지와 첫 답의 앞부분을 비밀값을 가리고(`SecretMasker`, 최선 노력) 잘라 표시로 감싼다.
    static func input(firstMessage: String, firstAnswer: String?) -> String {
        var text = "<user message>\n" + clipped(SecretMasker.mask(firstMessage), messageLimit) + "\n</user message>"
        if let answer = firstAnswer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
            text += "\n\n<agent answer (beginning)>\n" + clipped(SecretMasker.mask(answer), answerLimit) + "\n</agent answer (beginning)>"
        }
        return text
    }

    private static func clipped(_ text: String, _ limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }

    /// 모델의 답을 제목으로 다듬는다 (순수): 첫 줄 · 앞뒤 따옴표 · "Title:" 머리 · 끝 마침표를 떼고, 비었거나 40자가 넘으면 nil
    /// (지시를 따르지 않은 답 — 첫 메시지 제목을 그대로 둔다).
    static func cleaned(_ raw: String) -> String? {
        guard var line = raw.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        for prefix in ["Title:", "title:", "제목:"] where line.hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        let quotes = CharacterSet(charactersIn: "\"'`“”‘’「」『』*")
        line = line.trimmingCharacters(in: quotes.union(.whitespaces))
        while let last = line.last, ".。!！?？".contains(last) { line.removeLast() }
        line = line.trimmingCharacters(in: quotes.union(.whitespaces))
        guard !line.isEmpty, line.count <= 40 else { return nil }
        return line
    }

    /// Codex 에게 물을 모델 — 그 계정이 받는 모델 가운데 가장 작은 계열(`luna`)의 최신. 없으면 nil (CLI 기본 모델, 낮은 강도).
    static func codexModel(from identifiers: [String]) -> String? {
        identifiers
            .compactMap { id in ModelCatalog.codexFamily(of: id).map { (id, $0.family, $0.version) } }
            .filter { $0.1 == "luna" }
            .max { $0.2.lexicographicallyPrecedes($1.2) }?
            .0
    }

    /// 묻는 데 필요한 것.
    struct Request: Sendable, Equatable {
        var provider: AgentProvider
        /// `input(firstMessage:firstAnswer:)` 의 글.
        var input: String
        /// Codex 의 모델 (`codexModel`) — nil 이면 CLI 기본.
        var codexModel: String?
        /// 이 대화의 Claude 는 API 키로 실행한다 (모델 칩의 "API 크레딧으로 실행") — 제목도 같은 길로 묻는다 (`environment(_:for:apiKey:)`).
        var viaClaudeAPI = false
    }

    /// 제목을 물을 자식 환경 (순수). API 키로 실행하는 대화면 대화 실행과 같은 `ClaudeAPIKey.environment` 를 거친다 — 구독 로그인으로
    /// 가면 구독 한도에 닿은 대화(API 크레딧으로 계속)나 키만 쓰는 사람은 늘 실패했고, 여유가 있으면 구독 사용량을 썼다.
    /// 그런 대화인데 키를 읽지 못하면 nil — 묻지 않는다 (구독으로 보내지 않는다).
    static func environment(_ base: [String: String], for request: Request, apiKey: String?) -> [String: String]? {
        guard request.provider == .claude, request.viaClaudeAPI else { return base }
        guard let apiKey, !apiKey.isEmpty else { return nil }
        return ClaudeAPIKey.environment(base, apiKey: apiKey)
    }

    /// 실제 CLI 에게 묻는다. 대화 기록 · 사용자의 세션 목록에 남지 않게 부른다 — Claude 는 `--no-session-persistence`(도구 없음 ·
    /// MCP 없음 · 생각 끔 — 켜 두면 Haiku 가 4천 토큰을 생각해 40초 걸렸다, 2026-10-07 실측. 끄면 1초 · 출력 10토큰),
    /// Codex 는 `exec --ephemeral`(읽기 전용 · 낮은 강도, 8초 · 2.7천 토큰). 입력은 stdin 으로 (`ps` 에 보이지 않게).
    /// 작업 폴더는 빈 중립 폴더 — 프로젝트의 CLAUDE.md · AGENTS.md 를 읽지 않는다. 실패 · 시간 초과면 nil.
    static func summarize(_ request: Request, executable: String, environment: [String: String]) async -> String? {
        let arguments: [String]
        let stdin: String
        let timeout: TimeInterval
        switch request.provider {
        case .claude:
            arguments = ["-p", "--model", "haiku", "--no-session-persistence", "--tools", "", "--strict-mcp-config",
                         "--output-format", "json", "--settings", #"{"alwaysThinkingEnabled":false}"#,
                         "--system-prompt", instruction]
            stdin = request.input
            timeout = 30
        case .codex:
            arguments = ["exec", "--ephemeral", "--skip-git-repo-check", "-s", "read-only", "--color", "never",
                         "-c", #"model_reasoning_effort="low""#]
                + (request.codexModel.map { ["-m", $0] } ?? []) + ["-"]
            stdin = instruction + "\n\n" + request.input
            timeout = 45
        case .gemini:
            return nil
        }
        let result = await CLIEnvironment.captureOutput(executable: executable, arguments: arguments,
                                                        environment: environment,
                                                        workingDirectory: CLIEnvironment.neutralWorkingDirectory(),
                                                        stdinLines: [stdin], timeout: timeout)
        guard case .success(let raw) = result else { return nil }
        return title(fromOutput: raw, provider: request.provider)
    }

    /// CLI 의 출력에서 제목 (순수): Claude 는 `--output-format json` 의 `result`(오류 결과는 버린다), Codex 는 stdout 의 마지막 답.
    static func title(fromOutput raw: String, provider: AgentProvider) -> String? {
        switch provider {
        case .claude:
            guard let object = JSONUtil.object(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  object["is_error"] as? Bool != true,
                  let text = object["result"] as? String else { return nil }
            return cleaned(text)
        case .codex:
            return cleaned(raw)
        case .gemini:
            return nil
        }
    }
}
