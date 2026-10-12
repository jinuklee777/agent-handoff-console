import Foundation

// 이 Mac 에 남아 있는 Claude Code · Codex 세션 기록을 앱의 프로젝트 · 스레드 · 실행 · 이벤트로 옮긴다.
//
// - Claude Code: `~/.claude/projects/<경로를 -로 바꾼 이름>/<세션 UUID>.jsonl` — 줄마다 `type`(user · assistant · custom-title …),
//   `cwd`, `sessionId`, `timestamp`. 메시지는 `message.content` (문자열 또는 text · tool_use · tool_result · thinking 블록).
//   Agent 도구로 띄운 하위의 기록은 `<세션 UUID>/subagents/agent-*.jsonl` (+ `.meta.json`) 에 따로 있다.
// - Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` — 첫 줄 `session_meta`(id · cwd · cli_version), 이후
//   `event_msg`(item_completed 의 UserMessage · AgentMessage · CommandExecution · FileChange · McpToolCall, task_started · task_complete),
//   `response_item`(옛 기록의 message · function_call), `token_usage_record`.
//
// 가져온 스레드는 CLI 세션 ID 를 `AgentSession.cliSessionID` 에 두어 다음 메시지가 그 세션을 이어간다 (Claude `--resume`, Codex `thread/resume`).
// 사용량 · 비용은 옮기지 않는다 (가격표 기준 환산이 아닌 값을 앱의 기록으로 만들지 않는다). 모르는 값은 채우지 않는다.

// MARK: - 스캔 결과

/// 세션 파일 하나의 요약 (목록 · 선별용). 대화 본문은 가져올 때 `Transcript` 로 다시 읽는다.
struct ImportedSessionSummary: Identifiable, Hashable, Sendable {
    var provider: AgentProvider
    var cliSessionID: String
    var fileURL: URL
    var cwd: String
    /// Claude 의 custom-title 또는 첫 사용자 메시지 첫 줄. 없으면 nil.
    var title: String?
    var startedAt: Date
    var updatedAt: Date
    /// 사용자 메시지 수. 0 이면 가져올 대화가 없다 (`/usage` 만 친 세션 등).
    var userMessages: Int
    var cliVersion: String?

    var id: String { provider.rawValue + ":" + cliSessionID }
}

/// 작업 폴더 하나와 그 안에서 열렸던 세션들.
struct ImportFolder: Identifiable, Hashable, Sendable {
    var path: String
    var exists: Bool
    var isGitRepository: Bool
    var sessions: [ImportedSessionSummary]
    /// 자동 선별 결과 (`SessionImportScanner.isRecommended`).
    var recommended: Bool

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent }
    var claudeCount: Int { sessions.filter { $0.provider == .claude }.count }
    var codexCount: Int { sessions.filter { $0.provider == .codex }.count }
    var updatedAt: Date { sessions.map(\.updatedAt).max() ?? .distantPast }
}

// MARK: - 스캔

enum SessionImportScanner {
    static var defaultClaudeRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    }
    static var defaultCodexRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    /// 훑기를 멈추라는 표시 (가져오기 시트를 닫으면). 여러 스레드가 읽는다.
    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    /// 한 번에 읽는 세션 파일 수 (onb-18). 예전에는 코어 수만큼의 파일을 통째로 메모리에 올렸다 — 이미지를 붙인 긴 세션은 파일 하나가
    /// 수백 MB 다. 이제 파일은 조금씩 읽고(`TranscriptSupport.summaryLines(fileURL:markers:)`) 동시에 넷까지만.
    static let concurrentReads = 4

    /// 두 CLI 의 세션 파일을 훑어 폴더별로 묶는다. 파일을 읽지 못하면 그 파일만 건너뛴다. `progress(읽은 수, 전체)` 는 여러 스레드에서
    /// 1% 마다 불린다 (순서가 바뀔 수 있다). `isStopped` 가 참이 되면 남은 파일을 읽지 않고 빈 목록을 돌려준다.
    static func scan(claudeRoot: URL = defaultClaudeRoot, codexRoot: URL = defaultCodexRoot,
                     home: String = NSHomeDirectory(),
                     progress: (Int, Int) -> Void = { _, _ in },
                     isStopped: () -> Bool = { false }) -> [ImportFolder] {
        let fm = FileManager.default
        var jobs: [(URL, AgentProvider)] = []
        if let dirs = try? fm.contentsOfDirectory(at: claudeRoot, includingPropertiesForKeys: nil) {
            for dir in dirs {
                // 한 단계만 본다 — `<세션>/subagents/**/agent-*.jsonl` 은 따로 된 세션이 아니다 (Agent 하위는 가져올 때 부모에 붙인다).
                guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
                for file in files where file.pathExtension == "jsonl" { jobs.append((file, .claude)) }
            }
        }
        if let enumerator = fm.enumerator(at: codexRoot, includingPropertiesForKeys: nil) {
            for case let file as URL in enumerator where file.pathExtension == "jsonl" { jobs.append((file, .codex)) }
        }
        // 파일이 수백 개 · 합쳐서 1GB 를 넘을 수 있다 — 일꾼 넷이 파일을 하나씩 가져가 요약에 필요한 줄만 JSON 으로 푼다.
        let total: Int = jobs.count
        progress(0, total)
        let lock = NSLock()
        var summaries: [ImportedSessionSummary] = []
        var nextIndex = 0
        var finished = 0
        let step: Int = max(1, total / 100)
        let workers: Int = max(1, min(concurrentReads, total))
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while !isStopped() {
                lock.lock()
                let index = nextIndex
                nextIndex += 1
                lock.unlock()
                guard index < total else { return }
                let (file, provider) = jobs[index]
                let summary = summarize(file: file, provider: provider)
                lock.lock()
                if let summary { summaries.append(summary) }
                finished += 1
                let done = finished
                lock.unlock()
                if done == total || done % step == 0 { progress(done, total) }
            }
        }
        if isStopped() { return [] }
        return group(summaries, home: home)
    }

    /// 파일 하나의 요약 — 파일을 통째로 읽지 않는다.
    static func summarize(file: URL, provider: AgentProvider) -> ImportedSessionSummary? {
        switch provider {
        case .claude:
            guard let lines = TranscriptSupport.summaryLines(fileURL: file, markers: ClaudeTranscript.summaryMarkers) else { return nil }
            return ClaudeTranscript.summary(lines: lines, fileURL: file)
        case .codex:
            guard let lines = TranscriptSupport.summaryLines(fileURL: file, markers: CodexTranscript.summaryMarkers) else { return nil }
            return CodexTranscript.summary(lines: lines, fileURL: file)
        case .gemini:
            return nil
        }
    }

    /// 요약을 폴더별로 묶고 선별한다 (순수).
    static func group(_ summaries: [ImportedSessionSummary], home: String,
                      exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                      isGit: (String) -> Bool = { FileManager.default.fileExists(atPath: $0 + "/.git") }) -> [ImportFolder] {
        var byPath: [String: [ImportedSessionSummary]] = [:]
        for summary in summaries where summary.userMessages > 0 {
            byPath[normalizedPath(summary.cwd), default: []].append(summary)
        }
        return byPath.map { path, sessions in
            let present = exists(path)
            let git = present && isGit(path)
            return ImportFolder(path: path, exists: present, isGitRepository: git,
                                sessions: sessions.sorted { $0.updatedAt > $1.updatedAt },
                                recommended: isRecommended(path: path, exists: present, isGit: git,
                                                           sessionCount: sessions.count, home: home))
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// `/private/var/…` 와 `/var/…` 는 같은 폴더다. 끝 `/` 는 뗀다.
    static func normalizedPath(_ path: String) -> String {
        var p = path
        if p.hasPrefix("/private/var/") { p = String(p.dropFirst("/private".count)) }
        if p.hasPrefix("/private/tmp") { p = String(p.dropFirst("/private".count)) }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// 자동 선별: 존재하고, 임시 폴더 · Codex 앱 스크래치 · 루트 · 홈 · 작업 트리가 아니며, git 저장소이거나 세션이 2개 이상.
    static func isRecommended(path: String, exists: Bool, isGit: Bool, sessionCount: Int, home: String) -> Bool {
        guard exists else { return false }
        let home = normalizedPath(home)
        if path == "/" || path == home || path == "/tmp" || path == "/private/tmp" { return false }
        if path.hasPrefix("/var/folders/") || path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") { return false }
        // Codex 앱이 대화마다 만드는 `~/Documents/Codex/2026-07-20/new-chat` 같은 스크래치 폴더.
        if path.hasPrefix(home + "/Documents/Codex/") { return false }
        if path.contains("/.claude/worktrees/") || path.contains("/.codex/") { return false }
        // 이 앱이 대화마다 만든 독립 작업 폴더 — 그 대화는 이미 앱에 있다.
        if path.contains("/.agent-handoff-console/worktrees/") { return false }
        return isGit || sessionCount >= 2
    }
}

// MARK: - 옮길 대화

/// 파일에서 읽은 대화. 턴마다 사용자 메시지 하나와 그 뒤 에이전트 기록.
struct ImportedTranscript: Sendable {
    struct Event: Sendable {
        var kind: EventKind
        var title: String
        var text: String
        var toolUseID: String?
        var payloadJSON: String?
        var createdAt: Date
    }
    struct Turn: Sendable {
        var userText: String
        var startedAt: Date
        var endedAt: Date
        var model: String?
        var events: [Event] = []
    }
    var turns: [Turn]
    var model: String?
    /// Claude: 하위 에이전트를 띄운 호출 id → 끝난 상태 (`ClaudeTranscript.attachingSubAgents` 가 상태 행에 쓴다).
    var subAgentEndings: [String: SubAgentInfo.Status] = [:]
    /// Claude: 백그라운드로 띄운 호출 id (그 도구 결과가 `async_launched`). 하위 meta 에 `requestShape` 가 없는 옛 CLI 의 판정.
    var backgroundCalls: Set<String> = []
}

/// 두 파서가 함께 쓰는 도우미.
enum TranscriptSupport {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }

    /// jsonl 을 줄마다 JSON 객체로. 깨진 줄은 건너뛴다.
    static func lines(_ data: Data) -> [[String: Any]] {
        data.split(separator: 10).compactMap { chunk in
            (try? JSONSerialization.jsonObject(with: Data(chunk))) as? [String: Any]
        }
    }

    /// 요약용: 첫 줄 · 마지막 줄과, 표시 바이트열 중 하나라도 든 줄만 JSON 으로 푼다 (수십 MB 파일의 도구 출력 줄을 건너뛴다).
    /// 결과는 (줄 순서, 객체). 첫 · 마지막 줄은 시각 · 메타를 위해 늘 포함한다.
    static func summaryLines(_ data: Data, markers: [String]) -> [[String: Any]] {
        let chunks = data.split(separator: 10)
        let needles = markers.map { Data($0.utf8) }
        var out: [[String: Any]] = []
        for (index, chunk) in chunks.enumerated() {
            let edge = index == 0 || index == chunks.count - 1
            if !edge, !needles.contains(where: { chunk.range(of: $0) != nil }) { continue }
            if let object = (try? JSONSerialization.jsonObject(with: Data(chunk))) as? [String: Any] { out.append(object) }
        }
        return out
    }

    /// `summaryLines(_:markers:)` 와 같은 줄을 파일에서 조금씩(`chunkSize`) 읽어 고른다 — 파일 전체를 메모리에 올리지 않는다 (onb-18).
    /// 붙들고 있는 것은 읽는 조각 · 아직 줄바꿈을 못 만난 앞부분 · 마지막 줄 후보 하나뿐이다. 읽지 못하면 nil.
    static func summaryLines(fileURL: URL, markers: [String], chunkSize: Int = 1 << 20) -> [[String: Any]]? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        var picker = SummaryLinePicker(markers: markers)
        var pending = Data()
        while true {
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: chunkSize), !read.isEmpty else { break }
                chunk = read
            } catch {
                return nil
            }
            pending.append(chunk)
            var start: Int = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 10) {
                picker.take(pending[start..<newline])
                start = newline + 1
            }
            pending = start == pending.startIndex ? pending : Data(pending[start...])
        }
        picker.take(pending[pending.startIndex...])
        return picker.finish()
    }

    /// 줄을 하나씩 받아 요약에 쓸 줄을 고른다 (`summaryLines(_:markers:)` 와 같은 규칙: 빈 줄은 없는 것으로 · 첫 줄 · 표시가 든 줄 ·
    /// 마지막 줄). 마지막 줄은 끝을 알 때까지 모르므로 표시 없는 줄 하나를 후보로 들고 있다가 `finish` 에서 넣는다.
    struct SummaryLinePicker {
        private let needles: [Data]
        private var out: [[String: Any]] = []
        private var count = 0
        private var trailing: Data?

        init(markers: [String]) { needles = markers.map { Data($0.utf8) } }

        mutating func take(_ line: Data.SubSequence) {
            guard !line.isEmpty else { return }
            let first = count == 0
            count += 1
            if first || needles.contains(where: { line.range(of: $0) != nil }) {
                if let object = Self.object(Data(line)) { out.append(object) }
                trailing = nil
            } else {
                trailing = Data(line)
            }
        }

        mutating func finish() -> [[String: Any]] {
            if let trailing, let object = Self.object(trailing) { out.append(object) }
            trailing = nil
            return out
        }

        private static func object(_ line: Data) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        }
    }

    static func json(_ any: Any?) -> String {
        guard let any, JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return any.map { "\($0)" } ?? "" }
        return s
    }

    /// 기록에 남기는 도구 결과 · 명령 출력의 상한. 원본 파일은 그대로 남는다.
    static let outputLimit = 4000

    static func clip(_ s: String, _ limit: Int = outputLimit) -> String {
        JSONUtil.truncate(s, max: limit)
    }

    /// 제목: 첫 줄, 60자.
    static func titleLine(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    }

    /// `<system-reminder>…</system-reminder>` 같이 CLI 가 끼워 넣은 태그 블록을 뗀다.
    static func stripTagBlocks(_ text: String, tags: [String]) -> String {
        var out = text
        for tag in tags {
            while let open = out.range(of: "<\(tag)>"), let close = out.range(of: "</\(tag)>", range: open.upperBound..<out.endIndex) {
                out.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Claude Code

enum ClaudeTranscript {
    /// 사용자가 친 메시지가 아닌 것: 슬래시 명령 기록 · 훅 출력 · 백그라운드 작업 끝 알림(`origin` 이 없는 옛 형식).
    private static let skippedUserPrefixes = ["<command-name>", "<local-command-stdout>", "<command-message>", "<local-command-caveat>",
                                              "<task-notification>"]

    /// 요약에 쓰는 줄의 표시 — 사용자 글 · 제목 줄.
    static let summaryMarkers: [String] = ["\"type\":\"custom-title\"", "\"type\":\"user\""]

    static func summary(of data: Data, fileURL: URL) -> ImportedSessionSummary? {
        summary(lines: TranscriptSupport.summaryLines(data, markers: summaryMarkers), fileURL: fileURL)
    }

    /// 고른 줄(`TranscriptSupport.summaryLines` — 첫 · 마지막 줄과 표시가 든 줄)로 요약을 짓는다.
    static func summary(lines picked: [[String: Any]], fileURL: URL) -> ImportedSessionSummary? {
        var cwd: String?, sessionID: String?, title: String?, firstUser: String?, version: String?
        var first: Date?, last: Date?, users = 0, command: String?
        // 사용자 글 · 제목 줄만 푼다. 도구 결과만 있는 user 줄(`tool_result`)은 세지 않으므로 건너뛰어도 같다.
        let lines = picked
            .filter { line in
                guard line["type"] as? String == "user", let message = line["message"] as? [String: Any] else { return true }
                return !((message["content"] as? [[String: Any]])?.allSatisfy { $0["type"] as? String == "tool_result" } ?? false)
            }
        for line in lines {
            if cwd == nil, let c = line["cwd"] as? String { cwd = c }
            if sessionID == nil, let s = line["sessionId"] as? String { sessionID = s }
            if version == nil, let v = line["version"] as? String { version = v }
            if let t = TranscriptSupport.date(line["timestamp"]) {
                if first == nil { first = t }
                last = t
            }
            switch line["type"] as? String {
            case "custom-title":
                if let t = line["customTitle"] as? String, !t.isEmpty { title = t }
            case "user":
                if line["isSidechain"] as? Bool == true { continue }
                if let text = humanText(line, after: &command), !text.isEmpty {
                    users += 1
                    if firstUser == nil { firstUser = text }
                }
            default: break
            }
        }
        guard let cwd, let sessionID = sessionID ?? Self.sessionID(from: fileURL), let first, let last else { return nil }
        return ImportedSessionSummary(provider: .claude, cliSessionID: sessionID, fileURL: fileURL, cwd: cwd,
                                      title: title ?? firstUser.map(TranscriptSupport.titleLine),
                                      startedAt: first, updatedAt: last, userMessages: users, cliVersion: version)
    }

    private static func sessionID(from url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        return UUID(uuidString: name) != nil ? name : nil
    }

    /// `message.content` 에서 사용자가 쓴 글. 도구 결과만 있는 줄은 nil.
    /// 백그라운드 작업이 끝나 CLI 가 연 후속 턴의 입력(`origin.kind` "task-notification")도 nil — 사람의 메시지가 아니다.
    /// 그 뒤의 답은 앞 턴(같은 실행)에 붙는다 (실행 중 앱도 후속 턴을 같은 실행으로 기록한다).
    /// CLI 가 끼워 넣은 줄(`isMeta` — 스킬 본문 · 이미지 크기 안내 · "Continue from where you left off.")도 nil.
    static func userText(_ line: [String: Any]) -> String? {
        guard let message = line["message"] as? [String: Any], line["isMeta"] as? Bool != true else { return nil }
        if (line["origin"] as? [String: Any])?["kind"] as? String == "task-notification" { return nil }
        guard var t = contentText(message["content"]) else { return nil }
        t = TranscriptSupport.stripTagBlocks(t, tags: ["system-reminder"])
        if skippedUserPrefixes.contains(where: { t.hasPrefix($0) }) { return nil }
        return t.isEmpty ? nil : t
    }

    /// 메인 흐름의 사용자 줄 하나 → 턴을 여는 사람의 글. `userText` 에 더해, 사람이 친 슬래시 명령(`/스킬 인수`)은
    /// 명령 줄이 아니라 바로 뒤 CLI 의 펼침 줄(`isMeta`)에서 명령 글로 턴을 연다 — 명령 줄만으로는 `/usage` 같은 앱 안 명령
    /// (다음 줄이 `<local-command-stdout>`)과 가를 수 없다. `command` 는 직전 사용자 줄이 남긴 명령이다.
    static func humanText(_ line: [String: Any], after command: inout String?) -> String? {
        let pending = command
        command = nil
        if let text = userText(line) { return text }
        if line["isMeta"] as? Bool == true { return pending }
        command = slashCommand(line)
        return nil
    }

    /// 슬래시 명령 줄(`<command-name>/이름</command-name>` · `<command-args>`) → "/이름 인수". 명령 줄이 아니면 nil.
    private static func slashCommand(_ line: [String: Any]) -> String? {
        guard let text = contentText((line["message"] as? [String: Any])?["content"]),
              let name = tagValue("command-name", in: text), !name.isEmpty else { return nil }
        let command = name.hasPrefix("/") ? name : "/" + name
        let args = tagValue("command-args", in: text) ?? ""
        return args.isEmpty ? command : command + " " + args
    }

    /// 글, 또는 text 블록들을 이은 글. 둘 다 없으면 nil.
    private static func contentText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        let parts = (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    static func transcript(of data: Data) -> ImportedTranscript {
        var turns: [ImportedTranscript.Turn] = []
        var toolNames: [String: String] = [:]
        var endings: [String: SubAgentInfo.Status] = [:]
        var launched: Set<String> = []
        var lastModel: String?, command: String?
        for line in TranscriptSupport.lines(data) {
            // 메인이 도는 중에 온 끝 알림은 사용자 줄 없이 `attachment` 로만 남는다 — 끝 상태만 읽고 턴 · 이벤트는 만들지 않는다.
            if line["type"] as? String == "attachment" {
                if line["isSidechain"] as? Bool != true, let ending = queuedNotification(line) { endings[ending.id] = ending.status }
                continue
            }
            guard let type = line["type"] as? String, type == "user" || type == "assistant",
                  line["isSidechain"] as? Bool != true,
                  let message = line["message"] as? [String: Any] else { continue }
            let at = TranscriptSupport.date(line["timestamp"]) ?? turns.last?.endedAt ?? Date()
            if type == "user" {
                if let text = humanText(line, after: &command) {
                    turns.append(ImportedTranscript.Turn(userText: text, startedAt: at, endedAt: at, model: nil))
                }
                noteSubAgentEnding(line, message: message, toolNames: toolNames, into: &endings, launched: &launched)
            } else if let model = message["model"] as? String {
                lastModel = model
                if !turns.isEmpty { turns[turns.count - 1].model = model }
            }
            let events = lineEvents(message, user: type == "user", at: at, toolNames: &toolNames)
            guard !turns.isEmpty else { continue }
            for event in events {
                turns[turns.count - 1].events.append(event)
                turns[turns.count - 1].endedAt = max(turns[turns.count - 1].endedAt, event.createdAt)
            }
        }
        return ImportedTranscript(turns: turns, model: lastModel, subAgentEndings: endings, backgroundCalls: launched)
    }

    /// 한 줄의 기록: 사용자 줄은 도구 결과, 에이전트 줄은 응답 · 도구 호출 (thinking · image 는 옮기지 않는다).
    /// 메인 · 하위 기록이 함께 쓴다 — 하위의 것은 `payload` 에 부모 표시를 넣는다.
    private static func lineEvents(_ message: [String: Any], user: Bool, at: Date, toolNames: inout [String: String],
                                   payload: String? = nil) -> [ImportedTranscript.Event] {
        var out: [ImportedTranscript.Event] = []
        for block in message["content"] as? [[String: Any]] ?? [] {
            switch (user, block["type"] as? String) {
            case (true, "tool_result"):
                let id = block["tool_use_id"] as? String
                let name = id.flatMap { toolNames[$0] } ?? "도구"
                let isError = block["is_error"] as? Bool == true
                var output = ""
                if let s = block["content"] as? String { output = s }
                else if let parts = block["content"] as? [[String: Any]] {
                    output = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                out.append(.init(kind: .toolResult, title: isError ? "\(name) — 오류" : name,
                                 text: TranscriptSupport.clip(output), toolUseID: id, payloadJSON: payload, createdAt: at))
            case (false, "text"):
                if let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(.init(kind: .agentMessage, title: "", text: text, toolUseID: nil, payloadJSON: payload, createdAt: at))
                }
            case (false, "tool_use"):
                let id = block["id"] as? String
                let name = block["name"] as? String ?? "도구"
                if let id { toolNames[id] = name }
                out.append(.init(kind: .toolRequest, title: name,
                                 text: TranscriptSupport.clip(TranscriptSupport.json(block["input"])),
                                 toolUseID: id, payloadJSON: payload, createdAt: at))
            default:
                break
            }
        }
        return out
    }

    // MARK: 하위 에이전트 기록

    /// 하위 에이전트의 끝 (띄운 Agent 호출 id → 상태): 포그라운드는 그 호출의 도구 결과, 백그라운드는 끝 알림의 `<status>`
    /// (사용자 줄 · `queuedNotification`). 알림은 같은 작업에 여러 번 올 수 있다 — 마지막 것.
    private static func noteSubAgentEnding(_ line: [String: Any], message: [String: Any], toolNames: [String: String],
                                           into endings: inout [String: SubAgentInfo.Status], launched: inout Set<String>) {
        if let ending = contentText(message["content"]).flatMap(notificationEnding) {
            endings[ending.id] = ending.status
            return
        }
        let results = (message["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "tool_result" }
        // 백그라운드로 띄운 호출의 결과(`async_launched`)는 끝이 아니다 — 백그라운드였다는 표시만 남긴다.
        if (line["toolUseResult"] as? [String: Any])?["status"] as? String == "async_launched" {
            launched.formUnion(results.compactMap { $0["tool_use_id"] as? String })
            return
        }
        for block in results {
            guard let id = block["tool_use_id"] as? String, ["Agent", "Task"].contains(toolNames[id]) else { continue }
            endings[id] = block["is_error"] as? Bool == true ? .failed : .completed
        }
    }

    /// 끝 알림 글(`<task-notification>…`) → 띄운 호출 id 와 상태. 알림이 아니거나 호출 id 가 없으면 nil (모니터의 중간 알림 등).
    /// 모르는 상태 · 끝나지 않은 상태는 성공으로 치지 않는다 (실행 중 앱과 같다).
    private static func notificationEnding(_ text: String) -> (id: String, status: SubAgentInfo.Status)? {
        guard text.hasPrefix("<task-notification>"), let id = tagValue("tool-use-id", in: text) else { return nil }
        return (id, ClaudeTurnTracker.status(tagValue("status", in: text)).flatMap { $0.isFinished ? $0 : nil } ?? .stopped)
    }

    /// 메인이 도는 중에 온 끝 알림: `attachment` 의 `queued_command` · `commandMode` "task-notification".
    /// `prompt` 는 글이거나 text 블록들이다.
    private static func queuedNotification(_ line: [String: Any]) -> (id: String, status: SubAgentInfo.Status)? {
        guard let attachment = line["attachment"] as? [String: Any], attachment["type"] as? String == "queued_command",
              attachment["commandMode"] as? String == "task-notification" else { return nil }
        return contentText(attachment["prompt"]).flatMap(notificationEnding)
    }

    /// `<이름>값</이름>` 의 값. 없으면 nil.
    private static func tagValue(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 세션 파일 옆 `<세션>/subagents/agent-*.jsonl` — Agent 도구로 띄운 하위 (포그라운드 · 백그라운드). 옆의 `.meta.json` 에
    /// 띄운 호출 id(`toolUseId`) · 설명 · 종류가 있다. 워크플로 안의 에이전트(`subagents/workflows/wf_*/`)는 옮기지 않는다 —
    /// meta 에 호출 id 가 없고, 실행 중 앱도 워크플로 안의 흐름을 받지 않는다 (워크플로는 메인의 도구 행으로 남는다).
    static func subAgentFiles(of sessionFile: URL) -> [URL] {
        let dir = sessionFile.deletingPathExtension().appendingPathComponent("subagents")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 하위 기록 하나 → 상태 정보와 부모 표시를 단 이벤트 (실행 중 앱의 저장 모양: `RunSession.record(subAgent:)` ·
    /// `handleSubAgent`). 첫 사용자 글은 "요청: …" 안내. 띄운 호출 id 를 모르거나 기록이 비었으면 nil.
    static func subAgent(of data: Data, meta: [String: Any], endings: [String: SubAgentInfo.Status], backgroundCalls: Set<String>)
        -> (info: SubAgentInfo, events: [ImportedTranscript.Event])? {
        guard let parent = meta["toolUseId"] as? String, !parent.isEmpty else { return nil }
        let tag = ThreadEvent.payload(nil, taggingParent: parent)
        var events: [ImportedTranscript.Event] = []
        var toolNames: [String: String] = [:]
        var first: Date?, last: Date?, prompted = false, answer: String?
        for line in TranscriptSupport.lines(data) {
            guard let type = line["type"] as? String, type == "user" || type == "assistant",
                  let message = line["message"] as? [String: Any],
                  let at = TranscriptSupport.date(line["timestamp"]) ?? last else { continue }
            if first == nil { first = at }
            last = at
            // 하위 안의 사용자 글: 처음 것은 요청, 뒤의 것(이어 준 메시지 · 중단 표시)은 안내. CLI 가 만든 글은 버린다.
            if type == "user", line["isSynthetic"] as? Bool != true, let text = userText(line) {
                let body = text.hasPrefix("[Request interrupted") ? "중단됨"
                    : (prompted ? "" : "요청: ") + JSONUtil.truncate(text, max: ClaudeTurnTracker.promptLimit)
                prompted = true
                events.append(.init(kind: .systemNotice, title: "안내", text: body, toolUseID: nil, payloadJSON: tag, createdAt: at))
            }
            let found = lineEvents(message, user: type == "user", at: at, toolNames: &toolNames, payload: tag)
            if let text = found.last(where: { $0.kind == .agentMessage })?.text { answer = text }
            events += found
        }
        guard let first else { return nil }
        let title = (meta["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "하위 에이전트"
        // 옛 CLI 의 meta 에는 `requestShape` 가 없다 — 그때는 메인에서 그 호출의 결과가 `async_launched` 였는지로.
        let background = (meta["requestShape"] as? String).map { $0 == "background" } ?? backgroundCalls.contains(parent)
        let info = SubAgentInfo(id: parent, kind: .agent, title: title, detail: meta["agentType"] as? String,
                                isBackground: background,
                                status: endings[parent] ?? .stopped, startedAt: first, endedAt: last,
                                summary: answer.map { TranscriptSupport.clip($0) })
        return (info, events)
    }

    /// 세션 파일 옆의 하위 기록을 그 하위를 띄운 호출이 있는 턴에 붙인다 — 상태 행 하나 + 하위 안의 이벤트를 시각순으로 섞는다
    /// (메인의 순서는 그대로). 띄운 호출을 메인 기록에서 찾지 못한 하위는 옮기지 않는다.
    static func attachingSubAgents(to transcript: ImportedTranscript, sessionFile: URL) -> ImportedTranscript {
        var out = transcript
        for file in subAgentFiles(of: sessionFile) {
            let metaURL = file.deletingPathExtension().appendingPathExtension("meta.json")
            guard let data = try? Data(contentsOf: file),
                  let meta = (try? Data(contentsOf: metaURL)).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
                  let child = subAgent(of: data, meta: meta, endings: transcript.subAgentEndings,
                                       backgroundCalls: transcript.backgroundCalls),
                  let index = out.turns.firstIndex(where: { $0.events.contains { $0.kind == .toolRequest && $0.toolUseID == child.info.id } })
            else { continue }
            let row = ImportedTranscript.Event(kind: .subAgent, title: child.info.title, text: child.info.summary ?? "",
                                               toolUseID: nil, payloadJSON: child.info.jsonString, createdAt: child.info.startedAt)
            let main = out.turns[index].events, sub = [row] + child.events
            var merged: [ImportedTranscript.Event] = [], i = 0, j = 0
            while i < main.count || j < sub.count {
                if j == sub.count || (i < main.count && main[i].createdAt <= sub[j].createdAt) { merged.append(main[i]); i += 1 }
                else { merged.append(sub[j]); j += 1 }
            }
            out.turns[index].events = merged
            out.turns[index].endedAt = max(out.turns[index].endedAt, child.info.endedAt ?? child.info.startedAt)
        }
        return out
    }
}

// MARK: - Codex

enum CodexTranscript {
    /// 요약에 쓰는 줄의 표시 — 세션 메타 · 사용자 메시지.
    static let summaryMarkers: [String] = ["\"session_meta\"", "\"UserMessage\"", "\"role\":\"user\""]

    static func summary(of data: Data, fileURL: URL) -> ImportedSessionSummary? {
        summary(lines: TranscriptSupport.summaryLines(data, markers: summaryMarkers), fileURL: fileURL)
    }

    /// 고른 줄(`TranscriptSupport.summaryLines`)로 요약을 짓는다.
    static func summary(lines: [[String: Any]], fileURL: URL) -> ImportedSessionSummary? {
        guard let meta = lines.first(where: { $0["type"] as? String == "session_meta" }),
              let payload = meta["payload"] as? [String: Any],
              let id = (payload["id"] ?? payload["session_id"]) as? String,
              let cwd = payload["cwd"] as? String else { return nil }
        // 하위 에이전트 스레드의 기록은 부모 기록을 복사해 품고 있다 — 따로 가져오면 부모 대화가 겹친다.
        guard !isSubAgentThread(payload) else { return nil }
        let started = TranscriptSupport.date(payload["timestamp"]) ?? TranscriptSupport.date(meta["timestamp"]) ?? Date()
        // 대화 전체를 파싱하지 않고 사용자 메시지만 센다 (수백 파일을 훑는 목록 단계라 빨라야 한다).
        // item_completed 의 UserMessage 가 하나라도 있으면 그것만, 없으면(옛 기록) response_item 의 user 메시지.
        var last = started, itemUsers = 0, fallbackUsers = 0, firstItem: String?, firstFallback: String?
        for line in lines {
            if let t = TranscriptSupport.date(line["timestamp"]) { last = max(last, t) }
            guard let p = line["payload"] as? [String: Any] else { continue }
            switch line["type"] as? String {
            case "event_msg":
                if p["type"] as? String == "item_completed", let item = p["item"] as? [String: Any],
                   item["type"] as? String == "UserMessage" {
                    let t = text(item["content"])
                    if !t.isEmpty, !isInjected(t) { itemUsers += 1; if firstItem == nil { firstItem = t } }
                }
            case "response_item":
                if p["type"] as? String == "message", p["role"] as? String == "user" {
                    let t = text(p["content"])
                    if !t.isEmpty, !isInjected(t) { fallbackUsers += 1; if firstFallback == nil { firstFallback = t } }
                }
            default: break
            }
        }
        let users = itemUsers > 0 ? itemUsers : fallbackUsers
        let firstUser = itemUsers > 0 ? firstItem : firstFallback
        return ImportedSessionSummary(provider: .codex, cliSessionID: id, fileURL: fileURL, cwd: cwd,
                                      title: firstUser.map(TranscriptSupport.titleLine), startedAt: started, updatedAt: last,
                                      userMessages: users, cliVersion: payload["cli_version"] as? String)
    }

    /// `session_meta.payload` 가 하위 에이전트(검토 하위 포함) 스레드의 것인가. 메인 기록은 `source` 가 글이고
    /// 부모 스레드 ID 가 없다 (실측: `thread_source` "subagent" · "guardian_review", `source.subagent`, `parent_thread_id`).
    static func isSubAgentThread(_ payload: [String: Any]) -> Bool {
        if payload["thread_source"] as? String == "subagent" { return true }
        if (payload["source"] as? [String: Any])?["subagent"] != nil { return true }
        if let parent = payload["parent_thread_id"] as? String, !parent.isEmpty { return true }
        return false
    }

    /// 앱이 끼워 넣는 맥락 메시지 (사용자가 친 것이 아니다).
    private static func isInjected(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("<app-context>") || t.hasPrefix("<environment_context>") || t.hasPrefix("<permissions")
            || t.hasPrefix("<user_instructions>") || t.hasPrefix("<INSTRUCTIONS>") || t.hasPrefix("# AGENTS.md")
    }

    private static func text(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    static func transcript(of data: Data) -> ImportedTranscript {
        var turns: [ImportedTranscript.Turn] = []
        var fallback: [ImportedTranscript.Turn] = []   // item_completed 가 없는 옛 기록용 (response_item 만으로)
        var sawItems = false
        var model: String?
        var callNames: [String: String] = [:]

        func append(_ event: ImportedTranscript.Event, to list: inout [ImportedTranscript.Turn]) {
            guard !list.isEmpty else { return }
            list[list.count - 1].events.append(event)
            list[list.count - 1].endedAt = max(list[list.count - 1].endedAt, event.createdAt)
        }

        for line in TranscriptSupport.lines(data) {
            guard let type = line["type"] as? String, let payload = line["payload"] as? [String: Any] else { continue }
            let at = TranscriptSupport.date(line["timestamp"]) ?? turns.last?.endedAt ?? Date()
            switch type {
            case "event_msg":
                switch payload["type"] as? String {
                case "item_completed":
                    guard let item = payload["item"] as? [String: Any], let kind = item["type"] as? String else { continue }
                    sawItems = true
                    switch kind {
                    case "UserMessage":
                        let t = text(item["content"])
                        if !t.isEmpty, !isInjected(t) {
                            turns.append(.init(userText: t, startedAt: at, endedAt: at, model: model))
                        }
                    case "AgentMessage":
                        let t = text(item["content"])
                        if !t.isEmpty { append(.init(kind: .agentMessage, title: "", text: t, toolUseID: nil, payloadJSON: nil, createdAt: at), to: &turns) }
                    case "CommandExecution":
                        append(commandEvent(item, at: at), to: &turns)
                    case "FileChange":
                        append(fileChangeEvent(item, at: at), to: &turns)
                    case "McpToolCall":
                        let id = item["id"] as? String
                        let name = [item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: "/")
                        append(.init(kind: .toolRequest, title: name, text: TranscriptSupport.clip(TranscriptSupport.json(item["arguments"])),
                                     toolUseID: id, payloadJSON: nil, createdAt: at), to: &turns)
                        if let result = item["result"] as? [String: Any] {
                            let out = text(result["content"])
                            append(.init(kind: .toolResult, title: name, text: TranscriptSupport.clip(out), toolUseID: id,
                                         payloadJSON: nil, createdAt: at), to: &turns)
                        } else if let error = item["error"] {
                            append(.init(kind: .toolResult, title: "\(name) — 오류", text: TranscriptSupport.clip("\(error)"), toolUseID: id,
                                         payloadJSON: nil, createdAt: at), to: &turns)
                        }
                    case "Reasoning":
                        let summary = (item["summary_text"] as? [String])?.joined(separator: "\n") ?? ""
                        if !summary.isEmpty {
                            append(.init(kind: .agentReasoning, title: "추론 요약", text: summary, toolUseID: nil, payloadJSON: nil, createdAt: at), to: &turns)
                        }
                    default:
                        break
                    }
                case "task_complete":
                    if let error = payload["error"] as? [String: Any], let message = error["message"] as? String {
                        append(.init(kind: .error, title: "오류", text: message, toolUseID: nil, payloadJSON: nil, createdAt: at), to: &turns)
                    }
                    if !turns.isEmpty { turns[turns.count - 1].endedAt = max(turns[turns.count - 1].endedAt, at) }
                case "thread_settings_applied":
                    if let settings = payload["thread_settings"] as? [String: Any], let m = settings["model"] as? String { model = m }
                default:
                    break
                }
            case "world_state":
                if let state = payload["state"] as? [String: Any], let mode = state["collaboration_mode"] as? [String: Any],
                   let m = mode["model"] as? String { model = m }
            case "turn_context":
                if let m = payload["model"] as? String { model = m }
            case "response_item":
                switch payload["type"] as? String {
                case "message":
                    let role = payload["role"] as? String
                    let t = text(payload["content"])
                    if role == "user", !t.isEmpty, !isInjected(t) {
                        fallback.append(.init(userText: t, startedAt: at, endedAt: at, model: model))
                    } else if role == "assistant", !t.isEmpty {
                        append(.init(kind: .agentMessage, title: "", text: t, toolUseID: nil, payloadJSON: nil, createdAt: at), to: &fallback)
                    }
                case "function_call", "custom_tool_call":
                    let id = payload["call_id"] as? String
                    let name = payload["name"] as? String ?? "도구"
                    if let id { callNames[id] = name }
                    let input = (payload["arguments"] as? String) ?? (payload["input"] as? String) ?? ""
                    append(.init(kind: .toolRequest, title: name, text: TranscriptSupport.clip(input), toolUseID: id, payloadJSON: nil, createdAt: at), to: &fallback)
                case "function_call_output", "custom_tool_call_output":
                    let id = payload["call_id"] as? String
                    let name = id.flatMap { callNames[$0] } ?? "도구"
                    append(.init(kind: .toolResult, title: name, text: TranscriptSupport.clip(text(payload["output"])), toolUseID: id,
                                 payloadJSON: nil, createdAt: at), to: &fallback)
                default:
                    break
                }
            default:
                break
            }
        }
        let chosen = sawItems && !turns.isEmpty ? turns : fallback
        return ImportedTranscript(turns: chosen.map { turn in
            var t = turn
            if t.model == nil { t.model = model }
            return t
        }, model: model)
    }

    private static func commandEvent(_ item: [String: Any], at: Date) -> ImportedTranscript.Event {
        var command = (item["command"] as? [String] ?? []).joined(separator: " ")
        if let parts = item["command"] as? [String], parts.count == 3, parts[1] == "-lc" { command = parts[2] }
        let output = (item["aggregated_output"] as? String) ?? (item["stdout"] as? String) ?? ""
        let exit = item["exit_code"] as? Int
        let status = item["status"] as? String ?? "completed"
        var payload: [String: Any] = ["status": exit == nil ? status : (exit == 0 ? "completed" : "failed")]
        if let exit { payload["exitCode"] = exit }
        if let cwd = item["cwd"] as? String { payload["cwd"] = cwd.replacingOccurrences(of: "file://", with: "") }
        var text = command
        if !output.isEmpty { text += "\n\n--- 출력 ---\n" + TranscriptSupport.clip(output) }
        return .init(kind: .commandExecution, title: JSONUtil.truncate(command, max: 160, marker: "…"), text: text,
                     toolUseID: item["id"] as? String, payloadJSON: JSONUtil.line(payload), createdAt: at)
    }

    private static func fileChangeEvent(_ item: [String: Any], at: Date) -> ImportedTranscript.Event {
        let changes = item["changes"] as? [String: [String: Any]] ?? [:]
        let paths = changes.keys.sorted()
        var text = paths.joined(separator: "\n")
        for path in paths {
            let change = changes[path] ?? [:]
            let kind = change["type"] as? String ?? "update"
            let body = (change["content"] as? String) ?? (change["unified_diff"] as? String) ?? ""
            if !body.isEmpty { text += "\n\n=== \(path) (\(kind))\n" + TranscriptSupport.clip(body, 2000) }
        }
        return .init(kind: .fileChange, title: paths.joined(separator: ", "), text: text, toolUseID: item["id"] as? String,
                     payloadJSON: JSONUtil.line(["status": item["status"] as? String ?? "completed"]), createdAt: at)
    }
}

// MARK: - 저장

struct SessionImportResult: Sendable {
    var projectsAdded = 0
    var threadsAdded = 0
    var skippedExisting = 0
    var skippedEmpty = 0
    var failures: [String] = []
    /// 사람이 멈췄다 (작업 취소) — 그때까지 가져온 것은 남는다.
    var cancelled = false
}

/// 선택한 폴더의 세션을 `Store` 에 쓴다. 이미 같은 CLI 세션 ID 가 있으면 건너뛴다 (두 번 실행해도 중복되지 않는다).
/// 부른 작업이 취소되면 세션 하나를 마친 뒤 멈춘다 (`SessionImportResult.cancelled` — onb-8). 세션은 한 번에 하나씩 써서 반쯤 쓴
/// 세션은 남지 않는다 (그 세션의 쓰기는 끝까지 간다).
enum SessionImportService {
    static func run(folders: [ImportFolder], store: Store, existingProjects: [Project],
                    progress: @Sendable (String) async -> Void = { _ in }) async -> SessionImportResult {
        var result = SessionImportResult()
        var projects = existingProjects
        folderLoop: for folder in folders {
            // 멈춤은 프로젝트를 등록하기 전에 본다 — 세션 없는 빈 프로젝트가 생기지 않게.
            if Task.isCancelled {
                result.cancelled = true
                break folderLoop
            }
            let project: Project
            if let existing = projects.first(where: { SessionImportScanner.normalizedPath($0.path) == folder.path }) {
                project = existing
            } else {
                let p = Project(name: folder.name, path: folder.path, sortOrder: projects.count)
                do { try await store.upsertProject(p) } catch { result.failures.append("\(folder.name): 프로젝트 등록 실패 — \(error)"); continue }
                projects.append(p)
                project = p
                result.projectsAdded += 1
            }
            for summary in folder.sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
                if Task.isCancelled {
                    result.cancelled = true
                    break folderLoop
                }
                await progress("\(folder.name) — \(summary.title ?? summary.cliSessionID)")
                do {
                    if try await store.sessionExists(cliSessionID: summary.cliSessionID) { result.skippedExisting += 1; continue }
                    guard let data = try? Data(contentsOf: summary.fileURL) else { result.failures.append("\(summary.fileURL.lastPathComponent): 읽지 못함"); continue }
                    let transcript = summary.provider == .claude
                        ? ClaudeTranscript.attachingSubAgents(to: ClaudeTranscript.transcript(of: data), sessionFile: summary.fileURL)
                        : CodexTranscript.transcript(of: data)
                    guard !transcript.turns.isEmpty else { result.skippedEmpty += 1; continue }
                    try await write(summary: summary, transcript: transcript, project: project, store: store)
                    result.threadsAdded += 1
                } catch {
                    result.failures.append("\(summary.title ?? summary.cliSessionID): \(error)")
                }
            }
        }
        return result
    }

    /// Codex 기록 파일이 있는 `CODEX_HOME` — `<홈>/sessions/YYYY/MM/DD/rollout-….jsonl` 의 `<홈>`. 그 꼴이 아니면 nil.
    static func codexHome(ofSessionFile url: URL) -> String? {
        var directory = url.deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            if directory.lastPathComponent == "sessions" { return directory.deletingLastPathComponent().path }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    /// 스레드 · 세션 · 턴마다 실행 · 이벤트. 첫 이벤트는 어디서 왔는지 남기는 안내.
    static func write(summary: ImportedSessionSummary, transcript: ImportedTranscript, project: Project, store: Store) async throws {
        let provider = summary.provider
        let title = summary.title ?? transcript.turns.first.map { TranscriptSupport.titleLine($0.userText) } ?? "가져온 세션"
        var thread = ConversationThread(projectID: project.id, title: title, preferredProvider: provider)
        thread.createdAt = summary.startedAt
        thread.updatedAt = summary.updatedAt
        if let model = transcript.model {
            switch provider {
            case .claude: thread.claudeSelection.model = model
            case .codex: thread.codexSelection.model = model
            case .gemini: break
            }
        }
        try await store.upsertThread(thread)

        // 세션은 대화의 칸 하나 (계정 칸 "") — Codex 는 기록이 있는 홈을 함께 적는다 (다른 계정으로 보내도 이 기록을 이어 간다).
        // 실행 기록의 계정은 기본 계정 (가져오는 기록은 기본 홈 `~/.codex` 의 것이다).
        let accountID = provider == .codex ? CodexAccount.defaultID : ""
        var session = AgentSession(threadID: thread.id, provider: provider,
                                   cliSessionID: summary.cliSessionID, cliVersion: summary.cliVersion)
        session.createdAt = summary.startedAt
        if provider == .codex { session.recordHome = codexHome(ofSessionFile: summary.fileURL) }
        try await store.upsertSession(session)

        let origin = provider == .claude ? "Claude Code" : "Codex"
        try await store.appendEvent(ThreadEvent(
            threadID: thread.id, kind: .systemNotice, provider: provider, title: "\(origin) 에서 가져온 세션",
            text: "\(origin) 기록 \(summary.fileURL.path) 에서 가져왔습니다. 다음 메시지는 이 세션을 이어갑니다 (세션 \(summary.cliSessionID)). "
                + "사용량 · 비용은 옮기지 않았습니다.",
            createdAt: summary.startedAt))

        for turn in transcript.turns {
            var run = Run(threadID: thread.id, sessionID: session.id, provider: provider, requestText: turn.userText,
                          state: .completed, startedAt: turn.startedAt, endedAt: turn.endedAt, model: turn.model)
            run.codexAccountID = provider == .codex ? accountID : nil
            try await store.insertRun(run)
            try await store.appendEvent(ThreadEvent(threadID: thread.id, runID: run.id, kind: .userMessage, provider: nil,
                                                    text: turn.userText, createdAt: turn.startedAt))
            for event in turn.events {
                var row = ThreadEvent(threadID: thread.id, runID: run.id, kind: event.kind, provider: provider,
                                      title: event.title, text: event.text, payloadJSON: event.payloadJSON,
                                      toolUseID: event.toolUseID, createdAt: event.createdAt)
                // 하위 상태 행은 실행 중 앱과 같은 ID (실행 · 하위 id 로 고정).
                if let info = row.subAgentInfo { row.id = ThreadEvent.subAgentEventID(runID: run.id, agentID: info.id) }
                try await store.appendEvent(row)
            }
        }
        session.lastDeliveredSeq = try await store.maxSeq(threadID: thread.id)
        try await store.upsertSession(session)
    }
}
