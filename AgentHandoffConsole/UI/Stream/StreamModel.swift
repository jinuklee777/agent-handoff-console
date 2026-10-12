import Foundation

// 대화 스트림을 화면 행으로 바꾸는 순수 로직. SwiftUI 에 의존하지 않아 검증 하네스에서도 컴파일된다.

// MARK: - 실행 기록 항목

/// 에이전트가 실행한 명령·파일 편집·도구 호출 하나.
/// 같은 도구 호출의 시작/완료 이벤트는 한 항목으로 합친다 (먼저 나온 자리에 나중 값을 쓴다).
struct ExecutionEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case command(CommandInfo)
        case fileEdit(FileEditInfo)
        case tool(ToolInfo)
        case reasoning(String)
        case approval(title: String, detail: String)
        case decision(String)
        /// 에이전트의 질문 — 답했으면 글에 "→ 답" 이 함께 있다 (`UserQuestion.recordText`, `questionAnswered`).
        case question(String)
        case note(title: String, text: String)
    }

    var id: String
    var kind: Kind
    var provider: AgentProvider?
    var createdAt: Date
    /// 이 도구 · 명령 행이 하위 작업(하위 에이전트 · 워크플로 · 백그라운드 명령)을 띄웠으면 그 요약.
    /// 화면은 이런 행들을 "하위 에이전트 N" 카드로 묶어 그린다 (`ExecutionSegment`).
    var subagent: SubAgentDigest? = nil
    /// 아직 결정이 없는 승인 요청 행 (`.approval`). 도는 실행이면 승인 카드가 같은 것을 보이므로 실행 기록에서는 감춘다
    /// (`StreamBuilder` — 같은 명령이 기록 · 요청 줄 · 카드에 세 번 보이지 않게).
    var awaitingDecision = false
    /// 답한 질문 (`.question`) — 볼 것이 끝났다. 답하지 않은 질문은 접힌 블록에서도 보인다 (`ExecutionFold.isPinned`).
    var questionAnswered = false
    /// 승인 요청 · 결정 행이 가리키는 도구 호출. 같은 블록에 그 도구 행이 있으면 펼친 블록에서 따로 그리지 않는다 — 결정은 그 행의
    /// 승인 표시(거절함 · 승인 대기 · 실행 안 됨)가 말한다 (`ExecutionFold.absorbedIDs`).
    var toolUseID: String? = nil
}

/// 승인 요청과 이어진 도구 행의 상태 (`ApprovalTrail` 로 정한다).
enum ApprovalMark: Hashable {
    /// 승인 카드가 떠 있다 — 아직 실행되지 않았다 ("실행 중" 이 아니다).
    case awaiting
    /// 사람이(또는 무인 실행의 앱이) 거절했다. 오류가 아니다. 사유는 거절과 함께 준 글 (없으면 nil).
    case denied(reason: String?)
    /// 결정 없이 닫혔다 — CLI 가 요청을 거둠 · 물은 하위 작업이 끝남 · 작업 멈춤. 실행되지 않았다.
    case withdrawn
    /// 에이전트의 질문(`AskedQuestion`)에 사람이 적은 답을 보냈다 — 거절이 아니다. CLI 가 그 답을 오류 결과로 돌려줘도 오류가 아니다.
    case answered(String?)

    /// 끝났고 실행 결과가 없는 호출이다 (거절 · 거둠 · 질문에 답함) — 실행 중도 오류도 아니고, 결과 줄은 결과가 아니다.
    var isClosed: Bool {
        switch self {
        case .awaiting: return false
        case .denied, .withdrawn, .answered: return true
        }
    }

    /// 행의 상태 글 (대화의 실행 기록 · 터미널 탭이 같은 말을 쓴다).
    var label: String {
        switch self {
        case .awaiting: return "승인 대기"
        case .denied: return "거절함"
        case .withdrawn: return "실행 안 됨"
        case .answered: return "답함"
        }
    }

    /// 복사 · 손쉬운 사용의 글 — 거절 사유 · 보낸 답까지 ("답함 · B 방식으로").
    var copyText: String {
        switch self {
        case .denied(let reason?): return label + " · 사유: " + reason
        case .answered(let answer?): return label + " · " + answer
        default: return label
        }
    }
}

struct CommandInfo: Hashable {
    /// 셸 래퍼(`/bin/zsh -lc '…'`)를 벗긴 표시용 명령.
    var command: String
    var rawCommand: String
    var output: String?
    /// CLI 가 보고한 종료 코드. Claude Bash 도구는 종료 코드를 주지 않으므로 nil 이다.
    var exitCode: Int?
    /// CLI 가 오류로 표시했는지 (Claude `is_error`, Codex `failed`). 사람이 거절한 것은 오류가 아니다 (`approval`).
    var reportedError: Bool
    var running: Bool
    var cwd: String?
    /// 끝났지만 스스로 끝난 것이 아니다 — 중단 · 취소 (Codex `interrupted` — 실행을 멈추며 함께 멈춘 백그라운드 명령).
    /// "완료" 로 보이지 않게 따로 둔다.
    var stopped = false
    /// 실행은 끝났는데 이 호출의 결과를 받지 못했다 (`ExecutionParser.settlingUnfinished`). "실행 중" 도 "완료" 도 아니다.
    var unfinished = false
    /// 승인 대기 · 거절함 · 거둠 (승인 요청과 이어진 호출만).
    var approval: ApprovalMark? = nil
    /// CLI 가 준 이 명령의 작업 설명 (Claude Bash 의 `description` — "Run test suite"). 없으면 nil — 명령을 보고 지어내지 않는다.
    /// 펼친 실행 기록의 단계 한 줄 · 실행 중 상태 줄이 명령 원문 대신 쓴다 (`ExecutionFold.step`).
    var label: String? = nil

    var failed: Bool {
        if approval?.isClosed == true { return false }
        return reportedError || (exitCode.map { $0 != 0 } ?? false)
    }
}

struct FileEditInfo: Hashable {
    var paths: [String]
    var diff: String?
    /// 관찰한 diff 로 센 줄 수 (Claude 편집 요청은 바꾸기 전 · 뒤를 줄 단위로 견준 수 — `ApprovalPresentation.changeCounts`).
    /// 형식을 모르면 nil (0 으로 채우지 않는다).
    var added: Int?
    var removed: Int?
    var running: Bool
    var reportedError: Bool
    /// 실행은 끝났는데 이 편집의 결과를 받지 못했다.
    var unfinished = false
    /// 승인 대기 · 거절함 · 거둠. 승인 대기면 줄 수는 "예정" 이다.
    var approval: ApprovalMark? = nil
}

struct ToolInfo: Hashable {
    var name: String
    var summary: String
    var output: String?
    var reportedError: Bool
    var running: Bool
    /// 실행은 끝났는데 이 호출의 결과를 받지 못했다.
    var unfinished = false
    /// 승인 대기 · 거절함 · 거둠.
    var approval: ApprovalMark? = nil
}

enum ExecutionParser {
    static let outputMarker = "\n\n--- 출력 ---\n"
    static let fileEditTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// 멈춤으로 보이는 명령 상태 (끝났지만 성공도 오류도 아니다).
    static let stoppedCommandStatuses: Set<String> = ["interrupted", "cancelled", "canceled", "stopped", "killed"]

    /// 실행 기록 이벤트들을 화면 항목으로 바꾼다. `subAgents` 는 하위 작업 id → 요약 — 그 작업을 띄운 도구 · 명령 행에 붙인다.
    static func entries(from events: [ThreadEvent], projectPath: String?,
                        subAgents: [String: SubAgentDigest] = [:]) -> [ExecutionEntry] {
        var order: [String] = []
        var byKey: [String: ExecutionEntry] = [:]
        var lastReasoningKey: String?

        func put(_ key: String, _ entry: ExecutionEntry) {
            if byKey[key] == nil { order.append(key) }
            byKey[key] = entry
        }

        for event in events {
            let toolKey = event.toolUseID ?? event.id
            if event.kind != .agentReasoning { lastReasoningKey = nil }

            switch event.kind {
            case .commandExecution:
                let payload = JSONUtil.object(event.payloadJSON ?? "") ?? [:]
                let (command, output) = splitCommandText(event.text)
                let status = payload["status"] as? String ?? ""
                // Codex `declined` = 승인 요청이 거절됐다 (사람 · 무인 실행의 앱). 오류가 아니다 — 사유는 결정 행에서 (아래).
                let info = CommandInfo(
                    command: displayCommand(command), rawCommand: command,
                    output: output, exitCode: JSONUtil.int(payload["exitCode"]),
                    reportedError: status == "failed",
                    running: status == "inProgress", cwd: payload["cwd"] as? String,
                    stopped: stoppedCommandStatuses.contains(status),
                    approval: status == "declined" ? .denied(reason: nil) : nil)
                put("cmd:\(toolKey)", ExecutionEntry(id: "cmd:\(toolKey)", kind: .command(info),
                                                     provider: event.provider, createdAt: event.createdAt))

            case .fileChange:
                let payload = JSONUtil.object(event.payloadJSON ?? "") ?? [:]
                let status = payload["status"] as? String ?? ""
                let parts = event.text.components(separatedBy: "\n\n")
                let paths = (parts.first ?? "").split(separator: "\n").map {
                    relativize(String($0), to: projectPath)
                }
                let diff = parts.count > 1 ? parts.dropFirst().joined(separator: "\n\n") : nil
                let stats = diff.flatMap(diffStats)
                let info = FileEditInfo(paths: paths, diff: diff, added: stats?.added, removed: stats?.removed,
                                        running: status == "inProgress", reportedError: status == "failed",
                                        approval: status == "declined" ? .denied(reason: nil) : nil)
                put("file:\(toolKey)", ExecutionEntry(id: "file:\(toolKey)", kind: .fileEdit(info),
                                                      provider: event.provider, createdAt: event.createdAt))

            case .toolRequest:
                let key = "tool:\(toolKey)"
                put(key, ExecutionEntry(id: key, kind: requestKind(name: event.title, input: event.text,
                                                                   projectPath: projectPath),
                                        provider: event.provider, createdAt: event.createdAt))

            case .toolResult:
                let key = "tool:\(toolKey)"
                let isError = event.title.hasSuffix("— 오류")
                if var existing = byKey[key] {
                    existing.kind = merge(result: event.text, isError: isError, into: existing.kind)
                    byKey[key] = existing
                } else {
                    let name = isError ? String(event.title.dropLast(" — 오류".count)) : event.title
                    let info = ToolInfo(name: name, summary: firstLine(event.text, max: 80),
                                        output: event.text, reportedError: isError, running: false)
                    put(key, ExecutionEntry(id: key, kind: .tool(info), provider: event.provider,
                                            createdAt: event.createdAt))
                }

            case .agentReasoning:
                // --include-partial-messages 로 조각이 여러 이벤트로 온다. 이어진 조각은 하나로 합친다.
                if let key = lastReasoningKey, case .reasoning(let accumulated)? = byKey[key]?.kind {
                    byKey[key]?.kind = .reasoning(mergeReasoning(accumulated, event.text))
                } else {
                    let key = "reason:\(event.id)"
                    put(key, ExecutionEntry(id: key, kind: .reasoning(event.text), provider: event.provider,
                                            createdAt: event.createdAt))
                    lastReasoningKey = key
                }

            case .approvalRequest:
                put("appr:\(event.id)", ExecutionEntry(id: "appr:\(event.id)",
                                                       kind: .approval(title: event.title, detail: event.text),
                                                       provider: event.provider, createdAt: event.createdAt,
                                                       toolUseID: event.toolUseID))
            case .approvalDecision:
                put("dec:\(event.id)", ExecutionEntry(id: "dec:\(event.id)", kind: .decision(event.text),
                                                      provider: event.provider, createdAt: event.createdAt,
                                                      toolUseID: event.toolUseID))
            case .userQuestion:
                put("q:\(event.id)", ExecutionEntry(id: "q:\(event.id)", kind: .question(event.text),
                                                    provider: event.provider, createdAt: event.createdAt,
                                                    questionAnswered: event.isAnsweredQuestion))
            default:
                put("note:\(event.id)", ExecutionEntry(id: "note:\(event.id)",
                                                       kind: .note(title: event.title, text: event.text),
                                                       provider: event.provider, createdAt: event.createdAt))
            }
        }
        var result = order.compactMap { byKey[$0] }
        markApprovals(&result, trail: ApprovalTrail(events))
        guard !subAgents.isEmpty else { return result }
        for index in result.indices {
            switch result[index].kind {
            case .tool, .command:
                if let digest = subAgents[toolKey(of: result[index].id)] { result[index].subagent = digest }
            default:
                break
            }
        }
        return result
    }

    /// 끝난 실행의 기록에 결과 없이 남은 호출을 "실행 중" 에서 "결과 미확인" 으로 바꾼다 — 끝난 턴에 링이 영영 돌지 않게.
    /// 결과가 다른 블록으로 갈라진 기록도 여기로 온다: 9-23 이전의 가져오기는 이미지 결과 뒤에 CLI 가 넣는 안내 줄(`isMeta`)을
    /// 사람의 메시지로 넣어, 요청과 결과가 서로 다른 턴에 들어갔다.
    /// 승인을 기다리던 호출은 결정 없이 실행이 끝났다 — 실행되지 않았으므로 "결과 미확인" 이 아니라 거둠(`withdrawn`)이다.
    static func settlingUnfinished(_ entries: [ExecutionEntry]) -> [ExecutionEntry] {
        entries.map { entry in
            var out = entry
            switch entry.kind {
            case .command(var info) where info.approval == .awaiting:
                info.running = false
                info.approval = .withdrawn
                out.kind = .command(info)
            case .fileEdit(var info) where info.approval == .awaiting:
                info.running = false
                info.approval = .withdrawn
                out.kind = .fileEdit(info)
            case .tool(var info) where info.approval == .awaiting:
                info.running = false
                info.approval = .withdrawn
                out.kind = .tool(info)
            case .command(var info) where info.running:
                info.running = false
                info.unfinished = true
                out.kind = .command(info)
            case .fileEdit(var info) where info.running:
                info.running = false
                info.unfinished = true
                out.kind = .fileEdit(info)
            case .tool(var info) where info.running:
                info.running = false
                info.unfinished = true
                out.kind = .tool(info)
            default:
                break
            }
            return out
        }
    }

    /// 승인 요청과 이어진 호출에 승인 대기 · 거절함 · 거둠 · 답함을 붙인다 (`ApprovalTrail` — 도구 호출 ID 로 잇는다).
    /// 거절된 호출의 오류 결과는 오류가 아니다: Claude 는 거절된 도구에 거절 사유를 `is_error` 결과로 돌려준다.
    /// 사유는 결정 행의 것(사람이 적은 글)을, 옛 행이면 그 오류 결과의 글을 쓴다 (앱이 넣은 기본 문구는 사유가 아니다).
    /// 질문(`AskedQuestion`)에 적은 답은 거절이 아니라 답함이다 — 답이 거절로 적힌 옛 행도 `ApprovalTrail` 이 답으로 읽었다.
    static func markApprovals(_ entries: inout [ExecutionEntry], trail: ApprovalTrail) {
        guard !trail.decisions.isEmpty || !trail.openRequestIDs.isEmpty else { return }
        for index in entries.indices {
            let entry = entries[index]
            if case .approval = entry.kind {
                let eventID = String(entry.id.dropFirst("appr:".count))
                entries[index].awaitingDecision = trail.openRequestIDs.contains(eventID)
                continue
            }
            let key = toolKey(of: entry.id)
            let mark: ApprovalMark?
            if trail.awaitingToolUseIDs.contains(key) {
                mark = .awaiting
            } else if let resolution = trail.byToolUseID[key] {
                let decision = resolution.info.decision
                if decision == .answered {
                    mark = .answered(resolution.info.answer)
                } else if decision.isDenial {
                    let stored = resolution.info.reason
                    // 새 행은 사유가 없으면 없는 것이다 (결과의 글은 앱의 기본 문구). 옛 행은 결과의 글이 사유다.
                    let legacy = resolution.info.requestID == nil ? deniedOutput(entry.kind) : nil
                    mark = .denied(reason: stored ?? legacy)
                } else if decision.isWithdrawal {
                    mark = .withdrawn
                } else {
                    mark = nil
                }
            } else {
                mark = nil
            }
            guard let mark else { continue }
            switch entry.kind {
            case .command(var info):
                info.approval = mark
                if mark == .awaiting { info.running = true } else { info.running = false; info.reportedError = false }
                entries[index].kind = .command(info)
            case .fileEdit(var info):
                info.approval = mark
                if mark == .awaiting { info.running = true } else { info.running = false; info.reportedError = false }
                entries[index].kind = .fileEdit(info)
            case .tool(var info):
                info.approval = mark
                if mark == .awaiting { info.running = true } else { info.running = false; info.reportedError = false }
                entries[index].kind = .tool(info)
            default:
                break
            }
        }
    }

    /// 옛 행: 거절된 호출의 오류 결과 글 (Claude 는 거절 사유를 결과로 돌려준다). 앱의 기본 문구
    /// (`ApprovalDecisionInfo.defaultDenyMessages`) · 빈 글이면 nil.
    private static func deniedOutput(_ kind: ExecutionEntry.Kind) -> String? {
        let output: String?
        switch kind {
        case .command(let info): output = info.reportedError ? info.output : nil
        case .tool(let info): output = info.reportedError ? info.output : nil
        default: output = nil
        }
        return ApprovalDecisionInfo.meaningful(output)
    }

    /// 항목 ID(`tool:<id>` · `cmd:<id>` …)의 도구 호출 ID 부분.
    static func toolKey(of entryID: String) -> String {
        guard let colon = entryID.firstIndex(of: ":") else { return entryID }
        return String(entryID[entryID.index(after: colon)...])
    }

    /// 에이전트별로 이 스레드에서 편집한 파일 (프로젝트 기준 경로).
    static func touchedFiles(in events: [ThreadEvent], projectPath: String?) -> [String: Set<AgentProvider>] {
        var out: [String: Set<AgentProvider>] = [:]
        for entry in entries(from: events.filter { $0.kind == .fileChange || $0.kind == .toolRequest },
                             projectPath: projectPath) {
            guard case .fileEdit(let info) = entry.kind, let provider = entry.provider else { continue }
            for path in info.paths where !path.hasPrefix("/") {
                out[path, default: []].insert(provider)
            }
        }
        return out
    }

    /// 실행 하나의 기록에 남은 편집 경로 (프로젝트 기준, 경로 순) — 실행 전후 비교를 못 한 실행의 "관찰된 편집".
    /// 메인 흐름과 그 실행의 하위 에이전트 안의 편집을 함께 센다 (하위의 이벤트도 부모의 실행 ID 를 단다).
    /// 대화 스트림의 카드 · 변경사항 탭의 점 · 올릴 파일이 이것 하나로 센다.
    static func observedEdits(in events: [ThreadEvent], runID: String, projectPath: String?) -> [String] {
        touchedFiles(in: events.filter { $0.runID == runID }, projectPath: projectPath)
            .keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: 해석 도우미

    static func splitCommandText(_ text: String) -> (String, String?) {
        guard let range = text.range(of: outputMarker) else { return (text, nil) }
        let output = String(text[range.upperBound...])
        return (String(text[..<range.lowerBound]), output.isEmpty ? nil : output)
    }

    /// `/bin/zsh -lc 'git status'` → `git status`. 알 수 없는 형태는 그대로 둔다.
    static func displayCommand(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let shells = ["/bin/zsh", "/bin/bash", "/bin/sh", "/usr/bin/env zsh", "/usr/bin/env bash",
                      "zsh", "bash", "sh"]
        outer: for shell in shells {
            for flag in [" -lc ", " -c "] where s.hasPrefix(shell + flag) {
                s = String(s.dropFirst((shell + flag).count))
                break outer
            }
        }
        if s.count >= 2, let first = s.first, first == s.last, first == "'" || first == "\"" {
            s = String(s.dropFirst().dropLast())
            if first == "'" { s = s.replacingOccurrences(of: "'\\''", with: "'") }
        }
        return s
    }

    /// unified diff 의 추가·삭제 줄 수. diff 표식이 없으면 형식을 모르는 것으로 보고 nil.
    static func diffStats(_ diff: String) -> (added: Int, removed: Int)? {
        var added = 0, removed = 0, sawMarker = false
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
                sawMarker = true
            } else if line.hasPrefix("+") {
                added += 1
            } else if line.hasPrefix("-") {
                removed += 1
            }
        }
        return sawMarker ? (added, removed) : nil
    }

    static func relativize(_ path: String, to project: String?) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard let project, !project.isEmpty else { return trimmed }
        let base = project.hasSuffix("/") ? project : project + "/"
        return trimmed.hasPrefix(base) ? String(trimmed.dropFirst(base.count)) : trimmed
    }

    static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    static func firstLine(_ text: String, max: Int) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        return line.count > max ? String(line.prefix(max)) + "…" : line
    }

    /// Claude 도구 요청을 명령·파일 편집·일반 도구로 나눈다.
    static func requestKind(name: String, input: String, projectPath: String?) -> ExecutionEntry.Kind {
        let object = JSONUtil.object(input)
        func field(_ key: String) -> String? {
            if let value = object?[key] as? String { return value }
            // 입력이 길어 잘린 JSON 이면 정규식으로 값만 찾는다.
            let pattern = "\"\(key)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
                  let range = Range(match.range(at: 1), in: input) else { return nil }
            return String(input[range]).replacingOccurrences(of: "\\/", with: "/")
        }

        if name == "Bash", let command = field("command") {
            let label = field("description").map { firstLine($0.trimmingCharacters(in: .whitespacesAndNewlines), max: 80) }
            return .command(CommandInfo(command: command, rawCommand: command, output: nil, exitCode: nil,
                                        reportedError: false, running: true, cwd: nil,
                                        label: label?.isEmpty == false ? label : nil))
        }
        if fileEditTools.contains(name), let path = field("file_path") ?? field("notebook_path") {
            var added: Int?, removed: Int?
            // 바꾸기 전 · 뒤를 줄 단위로 견줘 실제로 바뀐 줄만 센다 — 승인 카드의 "+a −r" 과 같은 셈 (`changeCounts`).
            switch name {
            case "Edit":
                if let old = object?["old_string"] as? String, let new = object?["new_string"] as? String {
                    (added, removed) = ApprovalPresentation.changeCounts(old: old, new: new)
                }
            case "MultiEdit":
                if let edits = object?["edits"] as? [[String: Any]] {
                    let counts = edits.map {
                        ApprovalPresentation.changeCounts(old: $0["old_string"] as? String ?? "", new: $0["new_string"] as? String ?? "")
                    }
                    added = counts.reduce(0) { $0 + $1.added }
                    removed = counts.reduce(0) { $0 + $1.removed }
                }
            case "Write":
                // 덮어쓴 경우 지운 줄 수는 알 수 없다.
                if let content = object?["content"] as? String { added = lineCount(content) }
            default:
                break
            }
            return .fileEdit(FileEditInfo(paths: [relativize(path, to: projectPath)], diff: nil,
                                          added: added, removed: removed, running: true, reportedError: false))
        }

        let summary: String
        switch name {
        case "Read", "LS":
            summary = relativize(field("file_path") ?? field("path") ?? "", to: projectPath)
        case "Grep", "Glob":
            summary = [field("pattern"), field("path").map { relativize($0, to: projectPath) }]
                .compactMap { $0 }.joined(separator: "  ")
        case "WebFetch":
            summary = field("url") ?? ""
        case "WebSearch":
            summary = field("query") ?? ""
        case "Task", "Agent":
            summary = field("description") ?? ""
        case "Workflow":
            // 입력은 스크립트 하나다 (`{"script": "export const meta = { name: …, description: … } …"}`) — 첫 줄은 코드다.
            let label = field("description") ?? field("name") ?? field("workflow_name")
                ?? scriptMeta("name", in: object?["script"] as? String ?? input)
                ?? scriptMeta("description", in: object?["script"] as? String ?? input)
            summary = label.map { "워크플로 · " + firstLine($0, max: 80) } ?? "워크플로"
        case "TodoWrite":
            let count = (object?["todos"] as? [Any])?.count
            summary = count.map { "할 일 \($0)개" } ?? ""
        case AskedQuestion.claudeToolName:
            // 무엇을 물었는지 — 입력 JSON 첫 줄이 아니라 첫 질문 (답은 승인 표시의 "답함" 줄에).
            summary = firstLine(AskedQuestion.texts(in: object).first ?? field("question") ?? "", max: 80)
        default:
            // 입력이 길어 잘린 JSON 이면 첫 줄은 "{" 뿐이다 — 첫 문자열 값을 찾고, 그것도 없으면 이름만 보인다.
            let value = object.flatMap { obj in obj.keys.sorted().lazy.compactMap { obj[$0] as? String }.first }
                ?? (object == nil ? firstStringValue(in: input) : nil)
            let line = firstLine(value ?? input, max: 80)
            summary = line.allSatisfy { "{}[] \t".contains($0) } ? "" : line
        }
        return .tool(ToolInfo(name: name, summary: summary, output: nil, reportedError: false, running: true))
    }

    /// 워크플로 스크립트의 `meta = { name: '…', description: '…' }` 값. 잘린 입력(JSON 이스케이프 그대로)에서도 찾는다.
    static func scriptMeta(_ key: String, in script: String) -> String? {
        guard let meta = script.range(of: "meta") else { return nil }
        let pattern = "\\b\(key)\\s*:\\s*\\\\?['\"`]([^'\"`\\\\\\n]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(meta.lowerBound..., in: script)
        guard let match = regex.firstMatch(in: script, range: range),
              let value = Range(match.range(at: 1), in: script) else { return nil }
        let text = script[value].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// 잘린 JSON 글에서 처음 나오는 문자열 값 (닫는 따옴표가 잘렸어도). 이스케이프한 줄바꿈 앞까지. 없으면 nil.
    static func firstStringValue(in input: String) -> String? {
        let pattern = "\"[^\"\\\\]*\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let range = Range(match.range(at: 1), in: input) else { return nil }
        let raw = String(input[range])
        let line = raw.components(separatedBy: "\\n").first ?? raw
        let text = line.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\/", with: "/")
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func merge(result: String, isError: Bool, into kind: ExecutionEntry.Kind) -> ExecutionEntry.Kind {
        switch kind {
        case .command(var info):
            info.output = result.isEmpty ? nil : result
            info.reportedError = isError
            info.running = false
            return .command(info)
        case .fileEdit(var info):
            info.reportedError = isError
            info.running = false
            return .fileEdit(info)
        case .tool(var info):
            info.output = result.isEmpty ? nil : result
            info.reportedError = isError
            info.running = false
            return .tool(info)
        default:
            return kind
        }
    }

    /// 조각이면 이어 붙이고, 전체 본문이 다시 오면 그것으로 바꾼다.
    static func mergeReasoning(_ accumulated: String, _ incoming: String) -> String {
        if incoming.count >= accumulated.count,
           incoming.hasPrefix(accumulated.prefix(min(40, accumulated.count))) {
            return incoming
        }
        if accumulated.hasSuffix(incoming) { return accumulated }
        return accumulated + incoming
    }
}

// MARK: - 스트림 행

struct AgentTurnHeader: Hashable {
    var runID: String
    var provider: AgentProvider
    var time: Date
}

struct RelayRow: Hashable {
    var event: ThreadEvent
    var handoff: Handoff?
    /// 스레드 안 인계 순번 (1부터).
    var number: Int
    /// 대상 실행이 끝난 뒤 남긴 전달 상태 기록.
    var received: ThreadEvent?
}

/// 턴 바닥글 위의 "이번 실행에서 바뀐 파일" 카드 (실행 전후 비교 요약 이벤트 하나).
struct RunChangesRow: Hashable {
    var runID: String
    var changes: RunFileChanges
    /// 실행 전후 비교를 하지 못했을 때 그 실행의 기록에서 본 편집 경로 (프로젝트 기준, 경로 순). 비교했으면 비어 있다.
    var observedPaths: [String] = []
}

enum StreamRow: Identifiable, Hashable {
    case user(ThreadEvent)
    case agentHeader(AgentTurnHeader)
    case agentMessage(ThreadEvent)
    case execution(id: String, entries: [ExecutionEntry])
    case runChanges(RunChangesRow)
    /// `filesUnchanged` — 실행 전후를 비교했고 단서 없이 바뀐 파일이 없다. 카드 대신 바닥글 끝에 적는다.
    case turnFooter(runID: String, filesUnchanged: Bool = false)
    case relay(RelayRow)
    case alert(ThreadEvent)
    case notice(ThreadEvent)

    var id: String {
        switch self {
        case .user(let e), .agentMessage(let e), .alert(let e), .notice(let e): return e.id
        case .agentHeader(let h): return "header-\(h.runID)"
        case .execution(let id, _): return id
        case .runChanges(let r): return "changes-\(r.runID)"
        case .turnFooter(let runID, _): return "footer-\(runID)"
        case .relay(let r): return "relay-\(r.event.id)"
        }
    }
}

enum StreamBuilder {
    static func isExecutionLog(_ event: ThreadEvent) -> Bool {
        switch event.kind {
        case .commandExecution, .toolResult, .fileChange, .toolRequest, .agentReasoning,
             .approvalRequest, .approvalDecision, .userQuestion:
            return true
        case .systemNotice:
            return event.runID != nil
        default:
            return false
        }
    }

    /// 이벤트를 턴 단위 행으로 묶는다.
    ///
    /// 한 실행(run)의 에이전트 행 앞에 머리글을 한 번, 끝에 사용량 줄(바닥글)을 한 번 둔다.
    /// 실행 기록은 규칙선 블록 하나(`.execution`)다 — 화면은 한 줄 요약으로 접어 시작한다 (`ExecutionFold`).
    /// 인계는 스트림에 남는 한 줄(릴레이)이다.
    /// 실행 전후 비교 요약(`RunFileChanges` 이벤트)은 실행 기록 블록에 섞지 않고 그 실행의 바닥글 바로 위 카드로 둔다.
    ///
    /// 하위 에이전트 안의 일과 하위 상태 행(`isMainStream` 이 아닌 것)은 행으로 만들지 않는다. `subAgents`(하위 id → 요약)는
    /// 그 하위를 띄운 메인의 도구 · 명령 행에 붙는다 — 화면은 그 행들을 카드 하나로 묶는다.
    ///
    /// CLI 진단(`ThreadEvent.isDiagnostic` — 실행 명령줄 · app-server 시작 · MCP 준비 · 모르는 CLI 이벤트)은 행으로 만들지 않는다
    /// (그 실행의 머리글 · 바닥글은 연다 — 바닥글을 펼치면 진단이 보인다). 사람이 할 일(`isAttention` — 훅 실패 · MCP 인증 필요)은
    /// 실행 기록 블록 밖의 안내 한 줄이다 — 블록이 접혀도 숨지 않고, 블록을 펼친 채 붙잡지 않는다. 같은 글은 대화에서 가장 최근
    /// 것 하나만 (실행마다 같은 MCP 서버가 인증을 기다리면 턴마다 같은 줄이 쌓였다).
    /// `subAgentEvents`(하위 id → 흐름)는 비교하지 못한 실행의 "관찰된 편집" 에만 쓴다 — 하위가 고친 파일도 그 실행의 편집이다
    /// (`events` 에 섞여 온 하위 이벤트도 센다).
    static func rows(events allEvents: [ThreadEvent], runs: [String: Run], handoffs: [Handoff],
                     projectPath: String?, subAgents: [String: SubAgentDigest] = [:],
                     subAgentEvents: [String: [ThreadEvent]] = [:]) -> [StreamRow] {
        build(events: allEvents, runs: runs, handoffs: handoffs, projectPath: projectPath, subAgents: subAgents,
              subAgentEvents: subAgentEvents).rows
    }

    /// `rows` + 비교하지 못한 실행들 (행 캐시가 그 실행들의 하위 흐름이 자랄 때만 다시 묶으려고 받는다).
    static func build(events allEvents: [ThreadEvent], runs: [String: Run], handoffs: [Handoff],
                      projectPath: String?, subAgents: [String: SubAgentDigest] = [:],
                      subAgentEvents: [String: [ThreadEvent]] = [:]) -> (rows: [StreamRow], uncomparedRuns: Set<String>) {
        let events = gatheringAnchorUpdates(allEvents.filter(\.isMainStream), anchors: Set(subAgents.keys))
        var rows: [StreamRow] = []
        var log: [ThreadEvent] = []
        var openRun: String?
        var headerShown = Set<String>()
        var relayCount = 0
        // 사람이 할 일은 같은 글을 대화에서 한 번 — 가장 최근 것 하나만 (최근 행만 그려도 보이게).
        var latestAttention: [String: String] = [:]
        for event in events where event.isAttention { latestAttention[event.text] = event.id }

        let handoffByToken = Dictionary(handoffs.map { ($0.localToken, $0) }, uniquingKeysWith: { a, _ in a })
        var receivedByToken: [String: ThreadEvent] = [:]
        var sentTokens = Set<String>()
        // 실행마다 하나인 실행 전후 비교 요약. 자리는 이벤트 순서가 아니라 그 실행의 바닥글 위다.
        var changesByRun: [String: RunFileChanges] = [:]
        var summaryIDs = Set<String>()
        for event in events {
            if RunFileChanges.mayBeSummary(event), let runID = event.runID,
               let changes = RunFileChanges.decode(event) {
                changesByRun[runID] = changes
                summaryIDs.insert(event.id)
                continue
            }
            guard let token = token(of: event) else { continue }
            if event.kind == .handoffReceived { receivedByToken[token] = event }
            if event.kind == .handoffSent { sentTokens.insert(token) }
        }
        // 비교하지 못한 실행은 그 실행의 기록에 남은 편집으로 대신한다 ("관찰된 편집 n건"). 그 실행들의 편집 이벤트만 모은다 —
        // 메인 흐름과 하위 에이전트 안 모두 (변경사항 탭의 점 · 올릴 파일과 같은 기준, `ExecutionParser.observedEdits`).
        let observedRuns = Set(changesByRun.filter { !$0.value.compared }.keys)
        var observedEvents: [String: [ThreadEvent]] = [:]
        if !observedRuns.isEmpty {
            let children = allEvents.filter { $0.kind != .subAgent && $0.parentAgentID != nil }
            for flow in [events, children] + Array(subAgentEvents.values) {
                for event in flow where event.kind == .fileChange || event.kind == .toolRequest {
                    guard let runID = event.runID, observedRuns.contains(runID) else { continue }
                    observedEvents[runID, default: []].append(event)
                }
            }
        }
        func changesRow(_ runID: String) -> StreamRow? {
            guard let changes = changesByRun[runID] else { return nil }
            if changes.compared { return .runChanges(RunChangesRow(runID: runID, changes: changes)) }
            let observed = ExecutionParser.observedEdits(in: observedEvents[runID] ?? [], runID: runID,
                                                         projectPath: projectPath)
            // 비교도 못 하고 본 편집도 없으면 보여줄 사실이 없다.
            return observed.isEmpty ? nil
                : .runChanges(RunChangesRow(runID: runID, changes: changes, observedPaths: observed))
        }

        func flushLog() {
            guard let first = log.first else { return }
            var entries = ExecutionParser.entries(from: log, projectPath: projectPath, subAgents: subAgents)
            log = []
            // 끝난 실행에 결과 없이 남은 호출은 "실행 중" 이 아니다.
            let finished = openRun.flatMap { runs[$0] }?.state.isTerminal == true
            if finished {
                entries = ExecutionParser.settlingUnfinished(entries)
            } else {
                // 도는 실행의 아직 답하지 않은 승인 요청 줄은 감춘다 — 대화 끝의 승인 카드가 같은 것을 보이고, 도구 행은 "승인 대기".
                entries.removeAll { $0.awaitingDecision }
                guard !entries.isEmpty else { return }
            }
            rows.append(.execution(id: "exec-\(first.id)", entries: entries))
        }
        // 비교했고 단서 없이 바뀐 파일이 없으면 카드를 두지 않고 바닥글 끝에 "바뀐 파일 없음" 으로 (턴마다 빈 줄이 쌓이지 않게).
        func appendRunEnd(_ runID: String) {
            let unchanged = changesByRun[runID]?.unchangedWithoutCaveats == true
            if !unchanged, let row = changesRow(runID) { rows.append(row) }
            rows.append(.turnFooter(runID: runID, filesUnchanged: unchanged))
        }
        func closeRun() {
            flushLog()
            if let runID = openRun { appendRunEnd(runID) }
            openRun = nil
        }
        func enterRun(_ event: ThreadEvent) {
            guard let runID = event.runID, let provider = event.provider,
                  !headerShown.contains(runID) else { return }
            closeRun()
            headerShown.insert(runID)
            rows.append(.agentHeader(AgentTurnHeader(runID: runID, provider: runs[runID]?.provider ?? provider,
                                                     time: event.createdAt)))
            openRun = runID
        }

        for event in events {
            if summaryIDs.contains(event.id) {
                // 요약만 있고 다른 기록이 없는 실행이면 (보여줄 카드가 있을 때) 그 실행의 머리글 · 바닥글을 연다.
                if let runID = event.runID, !headerShown.contains(runID), changesRow(runID) != nil { enterRun(event) }
                continue
            }
            if event.isDiagnostic {
                // 보이지 않는 진단. 그 실행의 머리글 · 바닥글만 연다 — 다른 기록이 없어도 턴의 끝(바닥글)은 남게.
                if event.runID != nil { enterRun(event) }
                continue
            }
            if event.isAttention {
                enterRun(event)
                guard latestAttention[event.text] == event.id else { continue }
                flushLog()
                rows.append(.notice(event))
                continue
            }
            switch event.kind {
            case .userMessage:
                closeRun()
                rows.append(.user(event))
            case .handoffSent:
                closeRun()
                relayCount += 1
                let token = token(of: event)
                rows.append(.relay(RelayRow(event: event, handoff: token.flatMap { handoffByToken[$0] },
                                            number: relayCount,
                                            received: token.flatMap { receivedByToken[$0] })))
            case .handoffReceived:
                // 릴레이 줄이 전달 상태를 보여주므로 짝이 있으면 따로 그리지 않는다.
                if let token = token(of: event), sentTokens.contains(token) { continue }
                flushLog()
                rows.append(.notice(event))
            case .agentMessage:
                enterRun(event)
                flushLog()
                rows.append(.agentMessage(event))
            case .error, .rateLimitNotice:
                enterRun(event)
                flushLog()
                rows.append(.alert(event))
            default:
                if isExecutionLog(event) {
                    enterRun(event)
                    log.append(event)
                } else {
                    flushLog()
                    rows.append(.notice(event))
                }
            }
        }
        flushLog()
        if let runID = openRun, runs[runID]?.state.isTerminal == true { appendRunEnd(runID) }
        return (rows, observedRuns)
    }

    static func token(of event: ThreadEvent) -> String? {
        JSONUtil.object(event.payloadJSON ?? "")?["localToken"] as? String
    }

    // MARK: 하위 에이전트

    /// 하위 작업의 앵커(그 작업을 띄운 도구 · 명령 행)에 늦게 온 갱신을 앵커 자리로 옮긴다. Codex 는 하위가 끝날 때 앵커의 결과를,
    /// 백그라운드 명령이 끝날 때 그 명령의 완료를 메인 응답보다 뒤에 낸다 — 그대로 두면 응답 아래에 같은 행이 따로 생기고
    /// 처음 행은 "실행 중" 으로 남는다. 순서 말고는 바꾸지 않는다.
    static func gatheringAnchorUpdates(_ events: [ThreadEvent], anchors: Set<String>) -> [ThreadEvent] {
        guard !anchors.isEmpty else { return events }
        func anchorKey(_ event: ThreadEvent) -> String? {
            switch event.kind {
            case .toolRequest, .toolResult, .commandExecution:
                return event.toolUseID.flatMap { anchors.contains($0) ? $0 : nil }
            default:
                return nil
            }
        }
        var groups: [String: [ThreadEvent]] = [:]
        for event in events { if let key = anchorKey(event) { groups[key, default: []].append(event) } }
        guard groups.values.contains(where: { $0.count > 1 }) else { return events }
        var placed = Set<String>()
        var out: [ThreadEvent] = []
        out.reserveCapacity(events.count)
        for event in events {
            guard let key = anchorKey(event) else { out.append(event); continue }
            if placed.insert(key).inserted { out.append(contentsOf: groups[key] ?? [event]) }
        }
        return out
    }

    /// 대화의 하위 작업 요약 (하위 id → 요약). 저장된 상태 행 · 하위 흐름 · 실행 상태로 만든다.
    /// `liveRunIDs` 는 지금 세션이 도는 실행 — 주면 여기에 없는 실행은 끝난 것으로 본다 (`SubAgentDigest.runFinished`).
    /// 앞에서 돈 셸(`SubAgentInfo.isInternalStep`)은 뺀다 — 그 명령 행은 카드가 아니라 보통 명령 행으로 남는다.
    static func subAgentDigests(infos: [String: SubAgentInfo], runIDs: [String: String],
                                events: [String: [ThreadEvent]], runs: [String: Run],
                                projectPath: String?, liveRunIDs: Set<String>? = nil) -> [String: SubAgentDigest] {
        var out: [String: SubAgentDigest] = [:]
        for (id, info) in infos where !info.isInternalStep {
            let runID = runIDs[id]
            out[id] = SubAgentDigest.make(info: info, runID: runID,
                                          runFinished: SubAgentDigest.runFinished(runID, runs: runs, liveRunIDs: liveRunIDs),
                                          events: events[id] ?? [], projectPath: projectPath)
        }
        return out
    }

    /// 이미 만든 행의 하위 요약만 바꾼다 (하위가 일해도 메인 행을 다시 묶지 않게). 요약이 새로 붙는 행은 없다 —
    /// 하위 id 집합이 바뀌면 `rows` 로 다시 묶는다.
    static func attaching(_ digests: [String: SubAgentDigest], to rows: [StreamRow]) -> [StreamRow] {
        rows.map { row in
            guard case .execution(let id, var entries) = row else { return row }
            var changed = false
            for index in entries.indices where entries[index].subagent != nil {
                let digest = digests[ExecutionParser.toolKey(of: entries[index].id)]
                if digest != entries[index].subagent { entries[index].subagent = digest; changed = true }
            }
            return changed ? .execution(id: id, entries: entries) : row
        }
    }

    /// 인스펙터 "에이전트" 탭의 한 하위 흐름: 응답과 실행 기록만 (머리글 · 바닥글 · 경고 행 없음 — 하위의 이벤트는 부모의
    /// 실행 ID 를 달고 있어, 머리글을 두면 부모 실행 전체의 사용량이 보인다). 하위의 오류와 받은 요청은 기록 안의 한 줄로.
    static func subAgentRows(events: [ThreadEvent], projectPath: String?,
                             subAgents: [String: SubAgentDigest] = [:]) -> [StreamRow] {
        var rows: [StreamRow] = []
        var log: [ThreadEvent] = []
        func flush() {
            guard let first = log.first else { return }
            rows.append(.execution(id: "exec-\(first.id)",
                                   entries: ExecutionParser.entries(from: log, projectPath: projectPath, subAgents: subAgents)))
            log = []
        }
        let events = gatheringAnchorUpdates(events.filter { $0.kind != .subAgent && !$0.isDiagnostic },
                                            anchors: Set(subAgents.keys))
        for event in events {
            switch event.kind {
            case .agentMessage:
                flush()
                rows.append(.agentMessage(event))
            case .error, .rateLimitNotice:
                var note = event
                note.kind = .systemNotice
                note.title = event.title.isEmpty ? "오류" : "오류 · \(event.title)"
                log.append(note)
            case .userMessage:
                var note = event
                note.kind = .systemNotice
                note.title = "요청"
                log.append(note)
            case .handoffSent, .handoffReceived:
                continue
            default:
                log.append(event)
            }
        }
        flush()
        return rows
    }
}

// MARK: - 하위 에이전트 요약

/// 메인 흐름에서 하위 작업을 띄운 행에 붙는 요약 — 카드의 한 줄. 저장된 기록으로 만든다 (살아 있는 실행이면 화면이
/// `RunSession.subAgents` 의 진행을 덧씌운다).
struct SubAgentDigest: Hashable, Identifiable {
    var info: SubAgentInfo
    var runID: String?
    /// 띄운 실행이 끝났다. 끝난 실행 안의 `running` 은 끝을 보고받지 못한 것이다 (앱 종료 · 충돌).
    var runFinished: Bool
    /// 하위 안에서 부른 도구 · 명령 · 파일 변경 수 (CLI 가 센 값이 있으면 그것).
    var toolCount: Int
    /// 하위의 마지막 일 한 줄 (마지막 응답 첫 줄 · 도구 · 명령 · 편집). 모르면 nil.
    var lastLine: String?

    var id: String { info.id }
    /// 실행은 끝났는데 이 작업은 끝을 보고받지 못했다.
    var isUnfinished: Bool { info.status == .running && runFinished }
    /// 화면에 보일 상태 — 끝나지 않은 채 실행이 끝났으면 멈춤.
    var effectiveStatus: SubAgentInfo.Status { isUnfinished ? .stopped : info.status }
    var isRunning: Bool { effectiveStatus == .running }
    var statusText: String { Self.statusText(info.status, unfinished: isUnfinished) }

    /// 띄운 실행이 끝났는가: 저장된 상태가 끝남이거나, 살아 있는 실행 목록(`liveRunIDs`)을 받았는데 거기 없다
    /// (충돌 · 강제 종료 뒤 DB 에는 `running` 으로 남은 실행 — 사람이 "정리" 를 누르기 전까지). 목록을 모르면(nil) 상태만 본다.
    static func runFinished(_ runID: String?, runs: [String: Run], liveRunIDs: Set<String>?) -> Bool {
        guard let runID else { return liveRunIDs != nil }
        if runs[runID]?.state.isTerminal == true { return true }
        guard let liveRunIDs else { return false }
        return !liveRunIDs.contains(runID)
    }

    /// 이 작업을 띄운 메인의 명령 행(백그라운드 명령의 앵커)에 작업의 상태를 입힌다. Claude 의 앵커 결과는 "뒤에서 시작함"
    /// 확인일 뿐이라(`Command running in background with ID: …`), 행만 보면 도는 명령도 "완료" 로 보인다 — 상태는 CLI 가
    /// 작업으로 보고한 것(`info.status`)을 따른다. 끝나지 않은 채 실행이 끝났으면 멈춤.
    func applyingStatus(to entries: [ExecutionEntry]) -> [ExecutionEntry] {
        entries.map { entry in
            guard case .command(var command) = entry.kind else { return entry }
            switch effectiveStatus {
            case .running:
                command.running = true
                command.stopped = false
            case .stopped:
                command.running = false
                command.stopped = true
                command.exitCode = nil
            case .completed:
                command.running = false
                command.stopped = false
            case .failed:
                command.running = false
                command.stopped = false
                command.reportedError = true
            }
            var out = entry
            out.kind = .command(command)
            return out
        }
    }

    static func make(info: SubAgentInfo, runID: String?, runFinished: Bool, events: [ThreadEvent],
                     projectPath: String?) -> SubAgentDigest {
        var keys = Set<String>()
        for event in events {
            switch event.kind {
            case .toolRequest, .commandExecution, .fileChange:
                keys.insert(event.toolUseID ?? event.id)
            default:
                break
            }
        }
        var last: String?
        for event in events.reversed() {
            if let line = oneLine(event, projectPath: projectPath) { last = line; break }
        }
        return SubAgentDigest(info: info, runID: runID, runFinished: runFinished,
                              toolCount: info.toolUses ?? keys.count, lastLine: last)
    }

    /// 하위의 이벤트 하나를 "지금 하는 일" 한 줄로. 결과 · 추론 · 승인 같은 것은 nil (앞의 일을 본다).
    static func oneLine(_ event: ThreadEvent, projectPath: String?) -> String? {
        let line: String?
        switch event.kind {
        case .agentMessage:
            line = firstPlainLine(event.text)
        case .toolRequest:
            switch ExecutionParser.requestKind(name: event.title, input: event.text, projectPath: projectPath) {
            case .command(let info): line = "$ " + info.command
            case .fileEdit(let info): line = "편집 " + (info.paths.first ?? "")
            case .tool(let info): line = info.summary.isEmpty ? info.name : "\(info.name) \(info.summary)"
            default: line = nil
            }
        case .commandExecution:
            line = "$ " + ExecutionParser.displayCommand(ExecutionParser.splitCommandText(event.text).0)
        case .fileChange:
            let first = event.text.components(separatedBy: "\n").first ?? ""
            line = "편집 " + ExecutionParser.relativize(first, to: projectPath)
        case .systemNotice:
            // CLI 진단은 "지금 하는 일" 이 아니다.
            line = event.isDiagnostic ? nil : firstPlainLine(event.text)
        case .error:
            line = "오류 · " + ExecutionParser.firstLine(event.text, max: 110)
        default:
            line = nil
        }
        guard let line else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
    }

    /// 글의 첫 줄을 Markdown 표식 없이 (카드의 "지금 하는 일" 한 줄 — 본문처럼 그리지 않고 글자로만 보인다).
    /// 빈 줄 · 코드 울타리(```) 줄은 건너뛴다. 없으면 nil.
    static func firstPlainLine(_ text: String?) -> String? {
        guard let text else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { continue }
            let plain = plainMarkdown(trimmed)
            if !plain.isEmpty { return plain }
        }
        return nil
    }

    /// 한 줄의 인라인 Markdown 을 걷어 낸다: 줄 앞 표식(제목 `#` · 목록 `-`/`*`/`+`/`1.` · 인용 `>`), 코드 `` ` ``,
    /// 굵게 `**`/`__`, 취소선 `~~`, 링크 · 그림 `[글](주소)` → 글. 한 글자 강조(`*`/`_`)는 파일 이름(`fix_messages`)을
    /// 깨뜨릴 수 있어 그대로 둔다.
    static func plainMarkdown(_ line: String) -> String {
        var s = Substring(line.trimmingCharacters(in: .whitespaces))
        // 줄 앞 표식 — 인용은 겹칠 수 있다.
        while s.hasPrefix(">") { s = s.dropFirst().drop(while: { $0 == " " }) }
        if let hashes = s.firstIndex(where: { $0 != "#" }), hashes != s.startIndex, s[hashes] == " " {
            s = s[hashes...].drop(while: { $0 == " " })
        }
        for marker in ["- [ ] ", "- [x] ", "- ", "* ", "+ "] where s.hasPrefix(marker) {
            s = s.dropFirst(marker.count).drop(while: { $0 == " " })
            break
        }
        if let dot = s.firstIndex(where: { !$0.isNumber }), dot != s.startIndex, s[dot] == "." || s[dot] == ")",
           s[s.index(after: dot)...].first == " " {
            s = s[s.index(after: dot)...].drop(while: { $0 == " " })
        }
        var out = String(s)
        // 링크 · 그림: [글](주소) → 글
        if out.contains("](") {
            var result = ""
            var rest = Substring(out)
            while let open = rest.firstIndex(of: "[") {
                guard let close = rest[open...].firstIndex(of: "]"),
                      rest.index(after: close) < rest.endIndex, rest[rest.index(after: close)] == "(",
                      let end = rest[close...].firstIndex(of: ")") else { break }
                var before = rest[..<open]
                if before.hasSuffix("!") { before = before.dropLast() }
                result += before + rest[rest.index(after: open)..<close]
                rest = rest[rest.index(after: end)...]
            }
            out = result + rest
        }
        for token in ["**", "__", "~~", "`"] { out = out.replacingOccurrences(of: token, with: "") }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// 화면에 보이는 상태: 저장된 상태 + "결과 미확인"(실행은 끝났는데 끝을 보고받지 못함 — 끝난 실행의 도구 행과 같은 말,
    /// `UnfinishedResultLabel`). 선언 순서가 카드 머리의 순서다.
    enum DisplayState: CaseIterable {
        case completed, running, stopped, unfinished, failed
    }

    static func displayState(_ status: SubAgentInfo.Status, unfinished: Bool = false) -> DisplayState {
        if unfinished { return .unfinished }
        switch status {
        case .running: return .running
        case .completed: return .completed
        case .stopped: return .stopped
        case .failed: return .failed
        }
    }

    static func statusText(_ state: DisplayState) -> String {
        switch state {
        case .completed: return "완료"
        case .running: return "진행 중"
        case .stopped: return "멈춤"
        case .unfinished: return "결과 미확인"
        case .failed: return "실패"
        }
    }

    static func statusText(_ status: SubAgentInfo.Status, unfinished: Bool = false) -> String {
        statusText(displayState(status, unfinished: unfinished))
    }

    static func kindName(_ kind: SubAgentInfo.Kind) -> String {
        switch kind {
        case .agent: return "하위 에이전트"
        case .workflow: return "워크플로"
        case .shell: return "백그라운드 명령"
        case .other: return "하위 작업"
        }
    }

    /// 카드 머리: 종류가 하나면 그 이름, 섞였으면 "하위 작업" + 수.
    static func groupTitle(_ digests: [SubAgentDigest]) -> String {
        let kinds = Set(digests.map(\.info.kind))
        let name = kinds.count == 1 ? kindName(kinds.first!) : "하위 작업"
        return "\(name) \(digests.count)"
    }

    /// "1 완료 · 1 진행 중" — 없는 상태는 뺀다. 표시 글이 아니라 상태로 센다 (글을 번역해도 개수가 사라지지 않게).
    static func countsText(_ digests: [SubAgentDigest]) -> String {
        let states = digests.map { displayState($0.info.status, unfinished: $0.isUnfinished) }
        return DisplayState.allCases.compactMap { state in
            let n = states.filter { $0 == state }.count
            return n > 0 ? "\(n) \(statusText(state))" : nil
        }.joined(separator: " · ")
    }

    /// 끝난 실행에 끝을 보고받지 못한 작업의 도움말 (카드 줄 · 에이전트 탭).
    static let unfinishedHelp = "실행은 끝났지만 이 작업이 끝났다는 보고를 받지 못했습니다 (앱 종료 · 충돌 등)"

    // MARK: 기다림의 이름 — 메인 턴(에이전트의 답)이 끝난 뒤 남은 하위 작업은 어디서나 "백그라운드 작업 N개" 다.
    // 머리줄 · 칸 머리 · 상태 줄 · 메뉴바 · 잠금 문구가 같은 말을 쓴다 (짧은 자리는 "백그라운드 N"). "메인 턴" · "하위 N" 같은
    // 안쪽 구조의 말은 화면에 쓰지 않는다.

    /// 기다리는 동안의 상태 글 (턴 머리줄 · 칸 머리): "백그라운드 작업 N개 기다리는 중". 시계는 대화 끝의 상태 줄 하나에만 있다 —
    /// 같은 기다림에 시계 둘이 서로 다른 값을 보이지 않게.
    static func waitingText(count: Int) -> String {
        count > 0 ? "백그라운드 작업 \(count)개 기다리는 중" : "백그라운드 작업 기다리는 중"
    }

    /// 좁은 칸 머리의 짧은 글: "백그라운드 N" (남은 수가 0 인 틈에는 "대기").
    static func waitingShortText(count: Int) -> String {
        count > 0 ? "백그라운드 \(count)" : "대기"
    }

    /// 기다리는 동안의 도움말 (칸 머리).
    static let waitingHelp = "에이전트의 답은 끝났고 남은 백그라운드 작업이 끝나기를 기다립니다 (⌘. 로 모두 멈춤)"

    /// 인스펙터 "에이전트" 탭의 고른 하위 머리의 둘째 줄 (상태 글 뒤): 종류 · 백그라운드 · 경과 · 처리 토큰(새 토큰을 알면
    /// 함께) · 도구 수 · 부모. 처리 토큰은 캐시까지 센 양이다 (`TokenShare`).
    /// 백그라운드 명령은 이름에 이미 "백그라운드" 가 있어 다시 붙이지 않는다.
    /// `formatTokens` 는 토큰 수의 글 (기본은 화면 공용 형식 `DisplayFormat.tokens`).
    /// `share` 는 그 실행에서의 몫("22%") — 처리 토큰 바로 뒤에 붙인다 (줄 끝에서 잘리지 않게).
    static func detailFacts(_ info: SubAgentInfo, elapsedSeconds: Int?, parent: String?,
                            formatTokens: (Int) -> String = DisplayFormat.tokens, share: String? = nil) -> String {
        var parts = [kindName(info.kind)]
        if info.isBackground && info.kind != .shell { parts.append("백그라운드") }
        if let elapsedSeconds { parts.append(DisplayFormat.elapsed(seconds: elapsedSeconds)) }
        if let tokens = info.totalTokens, tokens > 0 {
            var notes: [String] = []
            if let new = info.newTokens { notes.append("새 \(formatTokens(new))") }
            if let share { notes.append("실행의 \(share)") }
            parts.append("처리 \(formatTokens(tokens))" + (notes.isEmpty ? "" : " (\(notes.joined(separator: " · ")))"))
        }
        if let uses = info.toolUses, uses > 0 { parts.append("도구 \(uses)") }
        if let parent { parts.append("부모: \(parent)") }
        return parts.joined(separator: " · ")
    }

    /// 입력창 보내기 원 옆 안내 (기다리는 중). 남은 작업이 0 이어도 기다릴 수 있다 — 마지막 작업이 끝난 뒤 주입 · 후속 턴을
    /// 기다리는 짧은 틈 — 그때는 수를 빼고 "백그라운드" 만.
    static func waitingKeyHint(count: Int) -> String {
        (count > 0 ? "백그라운드 \(count)" : "백그라운드") + " · ⌘. 중단"
    }

    /// 메뉴바 실행 목록의 대기 글 (위와 같은 틈에는 수 대신 "기다리는 중").
    static func waitingMenuText(count: Int) -> String {
        count > 0 ? "백그라운드 작업 \(count)개" : "백그라운드 기다리는 중"
    }

    /// 자동 작업 카드의 하위 작업 상태 자리 — 그 작업의 실행이 메인 턴을 마치고 백그라운드 작업을 기다리는 중일 때.
    static func waitingTaskText(count: Int) -> String {
        count > 0 ? "백그라운드 작업 \(count)개 기다리는 중" : "백그라운드 기다리는 중"
    }

    /// 막힌 이유 뒤에 붙이는 말 — 대화의 실행이 메인 턴을 마치고 백그라운드 작업을 기다리는 중이면 " (백그라운드 작업 N개)".
    /// 기다리지 않으면 빈 글. 남은 수가 0 인 틈(마지막 작업 뒤 후속 턴 대기)에는 수 없이.
    static func waitingNote(waiting: Bool, count: Int) -> String {
        guard waiting else { return "" }
        return count > 0 ? " (백그라운드 작업 \(count)개)" : " (백그라운드 작업을 기다리는 중)"
    }

    /// 입력창 인계 목록이 막혔을 때의 한 줄 (이 대화에 실행이 돈다).
    static func handoffBusyText(waiting: Bool, count: Int) -> String {
        "실행이 끝나면 인계할 수 있습니다\(waitingNote(waiting: waiting, count: count))."
    }

    /// 입력창 중단 원의 도움말 · 접근성 이름. 기다리는 중이거나 백그라운드 작업이 남았으면 "백그라운드 작업까지",
    /// 메인 턴 중의 포그라운드 하위 에이전트만 있으면 "하위 에이전트까지", 없으면 평소 글.
    static func stopButtonText(waiting: Bool, background: Int, unfinished: Int) -> (help: String, label: String) {
        if waiting || background > 0 { return ("백그라운드 작업까지 모두 멈춥니다 (⌘.)", "백그라운드 작업까지 모두 중단") }
        if unfinished > 0 { return ("하위 에이전트까지 모두 멈춥니다 (⌘.)", "하위 에이전트까지 모두 중단") }
        return ("실행 중단 (⌘.)", "실행 중단")
    }

    /// 경과 시간 — 화면 공용 형식 (`DisplayFormat.elapsed` — "12초" · "1분 05초" · "1시간 2분"). 새 코드는 그것을 직접 부른다.
    static func clock(seconds: Int) -> String { DisplayFormat.elapsed(seconds: seconds) }

    /// 하위가 청한 승인 카드의 제목. 이름이 이미 앞에 있으면(Codex 어댑터가 붙인다) 다시 붙이지 않는다.
    static func labeled(_ title: String, agentName: String?) -> String {
        guard let name = agentName?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              !title.hasPrefix(name) else { return title }
        return "\(name): \(title)"
    }
}

/// 실행 기록 블록 안의 그릴 단위 — 항목 하나, 또는 이어진 하위 작업 행들을 묶은 카드 하나.
enum ExecutionSegment: Identifiable, Hashable {
    case entry(ExecutionEntry)
    case subAgents(id: String, entries: [ExecutionEntry])

    var id: String {
        switch self {
        case .entry(let entry): return entry.id
        case .subAgents(let id, _): return id
        }
    }

    /// 이어진 하위 작업 행(`subagent` 가 붙은 행)을 하나로 묶는다. 순서는 그대로.
    static func group(_ entries: [ExecutionEntry]) -> [ExecutionSegment] {
        var out: [ExecutionSegment] = []
        var run: [ExecutionEntry] = []
        func flush() {
            guard let first = run.first else { return }
            out.append(.subAgents(id: "agents-\(first.id)", entries: run))
            run = []
        }
        for entry in entries {
            if entry.subagent != nil { run.append(entry); continue }
            flush()
            out.append(.entry(entry))
        }
        flush()
        return out
    }
}

// MARK: - 실행 기록 접기

/// 대화 스트림의 실행 기록 블록은 세 단계다 (Claude Code 앱의 "실행됨 명령 7개 ›" 와 같은 생각):
/// 1. 접힌 한 줄 — "명령 7개 실행 · 파일 3개 읽음 · 오류 1개 ›" (`Summary`). 늘 이렇게 시작한다 — 도는 실행의 것도.
/// 2. 누르면 단계마다 한 줄 (`Step`) — 명령은 CLI 가 준 작업 설명(Claude Bash 의 `description`), 없으면 명령 첫 줄 ·
///    "읽기 · Package.swift" 같은 사실. 명령을 보고 목적을 지어내지 않는다.
/// 3. 단계 한 줄을 누르면 그 단계의 원문 · 출력 · 종료 코드 · diff.
///
/// - 오류 · 멈춤 · 결과 미확인 · 승인 대기는 접힌 줄 끝에 종류마다 개수로 (`Issue`). 그 개수를 누르면 그 단계만 펼친다 — 예전에는
///   오류 하나가 블록 전체를 펼쳐 성공한 명령과 그 출력까지 보였다.
/// - 접혀도 늘 보이는 것 (`isPinned`): 하위 작업 카드(그 자체가 요약이고 진행 · 에이전트 탭의 입구다)와 답하지 않은 질문.
/// - 지금 하는 일은 대화 끝의 실행 중 상태 줄 한 줄이 말한다 (`RunActivity`). 도구가 붙거나 끝날 때 블록이 접혔다 펴지지 않아
///   화면이 흔들리지 않는다 (접힌 줄의 수만 바뀐다).
enum ExecutionFold {
    /// 요약 끝에 개수로 세는 봐야 할 상태. 순서는 화면 순서다.
    enum Issue: Int, Hashable, CaseIterable {
        case awaiting, error, stopped, unfinished

        func text(_ count: Int) -> String {
            switch self {
            case .awaiting: return "승인 대기 \(count)개"
            case .error: return "오류 \(count)개"
            case .stopped: return "멈춤 \(count)개"
            case .unfinished: return "결과 미확인 \(count)개"
            }
        }
    }

    struct IssueCount: Hashable {
        var issue: Issue
        var count: Int
        var text: String { issue.text(count) }
    }

    struct Summary: Hashable {
        /// 종류별 수 ("명령 7개 실행 · 파일 3개 읽음 · 검색 2번").
        var text: String
        /// 봐야 할 상태의 개수 (`Issue` 순서). 없으면 빈 배열.
        var issues: [IssueCount]

        /// "오류 2개 · 멈춤 1개". 없으면 nil.
        var issueText: String? { issues.isEmpty ? nil : issues.map(\.text).joined(separator: " · ") }

        /// 스트림 선택 · 손쉬운 사용의 글.
        var plainText: String { [text, issueText].compactMap { $0 }.joined(separator: " · ") }
    }

    /// 펼친 블록의 단계 한 줄.
    struct Step: Hashable {
        /// "Run test suite" · "swift test --filter Auth" · "읽기 · Package.swift".
        var title: String
        /// 명령 원문 첫 줄이라 고정폭으로 그린다 (CLI 가 설명을 주지 않은 명령).
        var monospaced: Bool
        /// 줄 끝의 상태 — 끝났고 문제가 없으면 nil.
        var status: StepStatus?
    }

    enum StepStatus: Hashable {
        case running, awaiting, error, stopped, unfinished, denied, withdrawn, answered

        var text: String {
            switch self {
            case .running: return "실행 중"
            case .awaiting: return "승인 대기"
            case .error: return "오류"
            case .stopped: return "멈춤"
            case .unfinished: return "결과 미확인"
            case .denied: return "거절함"
            case .withdrawn: return "실행 안 됨"
            case .answered: return "답함"
            }
        }
    }

    /// 블록 하나를 어떻게 접을지.
    struct Plan: Hashable {
        /// 요약 줄. 접을 항목이 없으면(하위 작업 카드 · 답하지 않은 질문뿐) nil — 그 블록은 그대로 보인다.
        var summary: Summary?
        /// 접혀도 보이는 항목의 ID.
        var pinnedIDs: Set<String>
        /// 봐야 할 상태(`Issue`)인 항목의 ID — 요약의 개수를 누르면 이것만 펼친다.
        var issueIDs: Set<String>
        /// 그 도구 단계에 합친 승인 요청 · 결정 (`absorbedIDs`) — 어느 단계에서도 따로 그리지 않는다.
        var hiddenIDs: Set<String> = []

        /// 지금 그릴 항목 (블록의 순서대로). 다 펼쳤으면 전부, 아니면 늘 보이는 것과 (개수를 눌렀으면) 봐야 할 것.
        func visible(_ entries: [ExecutionEntry], expanded: Bool, showingIssues: Bool) -> [ExecutionEntry] {
            let shown = entries.filter { !hiddenIDs.contains($0.id) }
            if expanded || summary == nil { return shown }
            return shown.filter { pinnedIDs.contains($0.id) || (showingIssues && issueIDs.contains($0.id)) }
        }
    }

    static func plan(_ entries: [ExecutionEntry]) -> Plan {
        let hidden = absorbedIDs(entries)
        let folded = entries.filter { !isPinned($0) && !hidden.contains($0.id) }
        return Plan(summary: folded.isEmpty ? nil : summary(folded),
                    pinnedIDs: Set(entries.filter(isPinned).map(\.id)),
                    issueIDs: Set(folded.filter { issue(of: $0) != nil }.map(\.id)),
                    hiddenIDs: hidden)
    }

    /// 같은 블록의 도구 · 명령 · 편집 행을 가리키는 승인 요청 · 결정 행 — 명령 하나가 "명령 → 승인 요청 → 결정 · 허용" 세 줄이
    /// 되지 않게 그 단계에 합친다. 결정은 그 단계의 승인 표시가 말한다 (허용은 따로 적지 않는다 — 실행된 것이 곧 허용이다).
    /// 가리키는 행이 없는 요청 · 결정은 남긴다.
    static func absorbedIDs(_ entries: [ExecutionEntry]) -> Set<String> {
        var calls = Set<String>()
        for entry in entries {
            switch entry.kind {
            case .command, .fileEdit, .tool: calls.insert(ExecutionParser.toolKey(of: entry.id))
            default: break
            }
        }
        return Set(entries.filter { entry in
            switch entry.kind {
            case .approval, .decision: return entry.toolUseID.map(calls.contains) ?? false
            default: return false
            }
        }.map(\.id))
    }

    /// 접혀도 보이는 항목: 하위 작업을 띄운 행(카드로 그린다)과 답하지 않은 질문.
    static func isPinned(_ entry: ExecutionEntry) -> Bool {
        if entry.subagent != nil { return true }
        if case .question = entry.kind { return !entry.questionAnswered }
        return false
    }

    /// 항목의 봐야 할 상태. 도는 것은 상태가 아니다 (상태 줄이 말한다).
    /// 사람이 거절한 호출 · 결정 없이 거둔 호출 · 적은 답을 보낸 질문 도구는 끝난 일이다 — 오류로 세지 않는다 (`ApprovalMark`).
    static func issue(of entry: ExecutionEntry) -> Issue? {
        if let mark = approvalMark(entry.kind) { return mark == .awaiting ? .awaiting : nil }
        switch entry.kind {
        case .command(let info):
            if info.running { return nil }
            if info.unfinished { return .unfinished }
            if info.stopped { return .stopped }
            return info.failed ? .error : nil
        case .fileEdit(let info):
            if info.running { return nil }
            if info.unfinished { return .unfinished }
            return info.reportedError ? .error : nil
        case .tool(let info):
            if info.running { return nil }
            if info.unfinished { return .unfinished }
            return info.reportedError ? .error : nil
        default:
            return nil
        }
    }

    /// 단계 한 줄의 글과 상태.
    static func step(_ entry: ExecutionEntry) -> Step {
        func plain(_ title: String) -> Step { Step(title: title, monospaced: false, status: stepStatus(entry)) }
        func joined(_ head: String, _ rest: String) -> String { rest.isEmpty ? head : head + " · " + rest }
        switch entry.kind {
        case .command(let info):
            if let label = info.label { return plain(label) }
            let line = ExecutionParser.firstLine(info.command, max: 160)
            return Step(title: line.isEmpty ? "명령" : line, monospaced: !line.isEmpty, status: stepStatus(entry))
        case .fileEdit(let info):
            let path = info.paths.first ?? ""
            return plain(joined("편집", path + (info.paths.count > 1 ? " 외 \(info.paths.count - 1)개" : "")))
        case .tool(let info):
            switch toolKind(info.name) {
            case .read: return plain(joined("읽기", info.summary))
            case .search: return plain(joined("검색", info.summary))
            case .web: return plain(joined("웹", info.summary))
            case .other:
                if info.name == "TodoWrite" { return plain(joined("할 일 정리", info.summary)) }
                if let mcp = ApprovalPresentation.mcpName(info.name) { return plain(joined("MCP \(mcp.tool)", info.summary)) }
                return plain(joined(info.name, info.summary))
            }
        case .reasoning(let text):
            let line = reasoningHeadings(text).last
                ?? ExecutionParser.firstLine(text.trimmingCharacters(in: .whitespacesAndNewlines), max: 80)
            return plain(joined("추론", line))
        case .approval(let title, _): return plain(joined("승인 요청", title))
        case .decision(let text): return plain(joined("결정", text))
        case .question(let text): return plain(joined("질문", ExecutionParser.firstLine(text, max: 120)))
        case .note(let title, let text): return plain(joined(title, ExecutionParser.firstLine(text, max: 120)))
        }
    }

    /// 단계 줄 끝의 상태 — 끝났고 문제가 없으면 nil.
    static func stepStatus(_ entry: ExecutionEntry) -> StepStatus? {
        if let mark = approvalMark(entry.kind) {
            switch mark {
            case .awaiting: return .awaiting
            case .denied: return .denied
            case .withdrawn: return .withdrawn
            case .answered: return .answered
            }
        }
        if let issue = issue(of: entry) {
            switch issue {
            case .awaiting: return .awaiting
            case .error: return .error
            case .stopped: return .stopped
            case .unfinished: return .unfinished
            }
        }
        switch entry.kind {
        case .command(let info): return info.running ? .running : nil
        case .fileEdit(let info): return info.running ? .running : nil
        case .tool(let info): return info.running ? .running : nil
        default: return nil
        }
    }

    /// 추론 글의 굵은 머리 ("**Planning build checks**"). Codex 의 추론 요약은 이런 머리 줄로 온다 (2026-10 기록 2385건 모두).
    /// 줄 하나가 통째로 `**…**` 인 것만 — 문장 안의 강조는 머리가 아니다.
    static func reasoningHeadings(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap(heading).map { ExecutionParser.firstLine($0, max: 80) }
    }

    /// 추론 행에 보일 글 — 머리 줄의 `**` 를 뗀다 (Markdown 으로 그리지 않는 행이라 별표가 글자로 보였다).
    static func reasoningDisplayText(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { heading($0) ?? String($0) }.joined(separator: "\n")
    }

    /// 줄 하나가 통째로 `**…**` 이면 그 안의 글.
    private static func heading(_ raw: Substring) -> String? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.count > 4, line.hasPrefix("**"), line.hasSuffix("**") else { return nil }
        let inner = line.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
        return inner.isEmpty || inner.contains("**") ? nil : inner
    }

    /// 도구 이름의 종류 (Claude · Codex · Antigravity 의 이름을 함께 본다). 모르는 이름은 `other`.
    enum ToolKind { case read, search, web, other }

    static func toolKind(_ name: String) -> ToolKind {
        switch name {
        case "Read", "LS", "NotebookRead", "view_file", "view_file_outline", "view_code_item", "list_dir",
             "read_file", "read_many_files", "list_directory":
            return .read
        case "Grep", "Glob", "grep_search", "find_by_name", "codebase_search", "search_file_content", "glob":
            return .search
        case "WebFetch", "WebSearch", "webSearch", "read_url_content", "search_web", "web_fetch", "google_web_search":
            return .web
        default:
            return .other
        }
    }

    static func summary(_ entries: [ExecutionEntry]) -> Summary {
        var readPaths = Set<String>(), reads = 0, searches = 0, web = 0, tools = 0, subTasks = 0
        var editPaths = Set<String>(), edits = 0, commands = 0, approvals = 0, reasoning = 0, notes = 0
        // 승인 요청을 거절해 · 결정 없이 실행하지 않은 호출 — 한 일로 세지 않고 따로 센다.
        // 에이전트의 질문에 적은 답을 보낸 호출은 거절이 아니다 — 답한 질문으로 센다.
        var denied = 0, withdrawn = 0, answered = 0
        var issueCounts: [Issue: Int] = [:]
        let absorbed = absorbedIDs(entries)
        for entry in entries where !absorbed.contains(entry.id) {
            if let issue = issue(of: entry) { issueCounts[issue, default: 0] += 1 }
            if entry.subagent != nil { subTasks += 1; continue }
            if let mark = approvalMark(entry.kind), mark.isClosed {
                switch mark {
                case .denied: denied += 1
                case .answered: answered += 1
                default: withdrawn += 1
                }
                continue
            }
            switch entry.kind {
            case .command:
                commands += 1
            case .fileEdit(let info):
                edits += 1
                editPaths.formUnion(info.paths)
            case .tool(let info):
                switch toolKind(info.name) {
                case .read:
                    reads += 1
                    if !info.summary.isEmpty { readPaths.insert(info.summary) }
                case .search: searches += 1
                case .web: web += 1
                case .other: tools += 1
                }
            case .approval: approvals += 1
            case .reasoning: reasoning += 1
            case .note: notes += 1
            case .decision, .question: break
            }
        }
        var parts: [String] = []
        if commands > 0 { parts.append("명령 \(commands)개 실행") }
        if reads > 0 { parts.append(readPaths.isEmpty ? "읽기 \(reads)번" : "파일 \(readPaths.count)개 읽음") }
        if searches > 0 { parts.append("검색 \(searches)번") }
        if edits > 0 { parts.append(editPaths.isEmpty ? "편집 \(edits)번" : "파일 \(editPaths.count)개 편집") }
        if web > 0 { parts.append("웹 \(web)번") }
        if subTasks > 0 { parts.append("하위 작업 \(subTasks)개") }
        if tools > 0 { parts.append("도구 \(tools)번") }
        if approvals > 0 { parts.append("승인 요청 \(approvals)번") }
        if answered > 0 { parts.append("답한 질문 \(answered)개") }
        if denied > 0 { parts.append("거절 \(denied)번") }
        if withdrawn > 0 { parts.append("실행 안 됨 \(withdrawn)개") }
        // 일은 없고 생각 · 안내 · 결정만 있는 블록.
        if parts.isEmpty {
            parts.append(reasoning > 0 ? "추론" : notes > 0 ? "안내 \(notes)개" : "기록 \(entries.count)개")
        }
        let issues = Issue.allCases.compactMap { issue in issueCounts[issue].map { IssueCount(issue: issue, count: $0) } }
        return Summary(text: parts.joined(separator: " · "), issues: issues)
    }

    /// 도구 · 명령 · 편집 행의 승인 표시 (`ApprovalMark`). 그 밖의 행은 nil.
    static func approvalMark(_ kind: ExecutionEntry.Kind) -> ApprovalMark? {
        switch kind {
        case .command(let info): return info.approval
        case .fileEdit(let info): return info.approval
        case .tool(let info): return info.approval
        default: return nil
        }
    }
}

// MARK: - 하위 작업 목록 (인스펙터 "에이전트" 탭)

struct SubAgentListItem: Identifiable, Hashable {
    var info: SubAgentInfo
    var runID: String?
    /// 지금 도는 실행의 것 — 값은 `RunSession.subAgents` 에서 왔다 (진행이 가장 새롭다).
    var isLive: Bool
    /// 띄운 실행이 끝났다 (끝난 실행 안의 `running` 은 끝나지 않은 채 멈춘 것).
    var runFinished: Bool
    /// 띄운 실행의 시작 시각 (최근 실행 먼저 놓을 때). 모르면 nil.
    var runStartedAt: Date?
    /// 목록의 들여쓰기 — 하위가 띄운 작업은 그 하위 바로 아래에 한 칸 들여 놓는다 (`SubAgentList.items`).
    var depth = 0

    var id: String { info.id }
    var isRunning: Bool { info.status == .running && !runFinished }
    var statusText: String { SubAgentDigest.statusText(info.status, unfinished: info.status == .running && runFinished) }
}

enum SubAgentList {
    /// 하위가 맡은 일 — 하위 흐름의 첫 요청. Claude 는 띄울 때의 prompt 를 "요청: …" 안내로 흐름 첫 줄에 남긴다
    /// (`ClaudeTurnTracker`), 사용자 메시지 꼴로 들어온 요청도 읽는다. 없으면 nil — Codex 하위의 요청은 app-server 가 알리지 않고,
    /// 계정 홈의 세션 파일(rollout)에도 부모의 `spawn_agent` 인수 · 하위의 NEW_TASK 메시지 모두 암호화돼 있어 읽을 수 없다 (2026-10-09 확인).
    static func assignedTask(_ events: [ThreadEvent]) -> String? {
        for event in events {
            let text: Substring
            if event.kind == .systemNotice, !event.isDiagnostic, event.text.hasPrefix(assignedTaskPrefix) {
                text = event.text.dropFirst(assignedTaskPrefix.count)
            } else if event.kind == .userMessage {
                text = Substring(event.text)
            } else {
                continue
            }
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { return body }
        }
        return nil
    }

    /// Claude 하위의 요청 안내 머리 (`ClaudeTurnTracker.prompt` 와 같은 글).
    static let assignedTaskPrefix = "요청: "

    /// 저장된 하위 작업 + 지금 도는 실행의 하위 작업. 같은 id 면 살아 있는 값이 우선이다.
    /// 최근 실행 먼저, 한 실행 안에서는 시작 순. 하위가 띄운 작업은 그 하위 바로 아래(`depth` + 1)에 둔다.
    /// 앞에서 돈 셸(`SubAgentInfo.isInternalStep` — 하위가 기다리며 돌린 명령)은 목록에 넣지 않는다.
    /// `liveRunIDs` 는 지금 세션이 도는 실행 전부 — 없으면 `liveRunID` 하나만 도는 것으로 본다.
    /// 여기에 없는 실행의 `running` 은 끝나지 않은 채 멈춘 것이다 (충돌 · 강제 종료).
    static func items(stored: [String: SubAgentInfo], runIDs: [String: String], runs: [String: Run],
                      live: [SubAgentInfo], liveRunID: String?, liveRunIDs: Set<String>? = nil) -> [SubAgentListItem] {
        let liveRuns = liveRunIDs ?? Set([liveRunID].compactMap { $0 })
        var byID: [String: SubAgentListItem] = [:]
        for (id, info) in stored {
            let runID = runIDs[id]
            let run = runID.flatMap { runs[$0] }
            byID[id] = SubAgentListItem(info: info, runID: runID, isLive: false,
                                        runFinished: SubAgentDigest.runFinished(runID, runs: runs, liveRunIDs: liveRuns),
                                        runStartedAt: run?.startedAt)
        }
        for info in live {
            byID[info.id] = SubAgentListItem(info: info, runID: liveRunID, isLive: true, runFinished: false,
                                             runStartedAt: liveRunID.flatMap { runs[$0] }?.startedAt)
        }
        func rank(_ item: SubAgentListItem) -> Date {
            if liveRunID != nil, item.runID == liveRunID { return .distantFuture }
            return item.runStartedAt ?? .distantPast
        }
        let sorted = byID.values.filter { !$0.info.isInternalStep }.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra > rb }
            if a.info.startedAt != b.info.startedAt { return a.info.startedAt < b.info.startedAt }
            return a.id < b.id
        }
        return nested(sorted)
    }

    /// 하위가 띄운 작업을 그 하위 바로 아래로 옮기고 깊이를 매긴다 (순서는 그대로 — 형제끼리는 시작 순).
    /// 띄운 하위가 목록에 없으면 제자리에 깊이 0 으로 둔다.
    private static func nested(_ items: [SubAgentListItem]) -> [SubAgentListItem] {
        let ids = Set(items.map(\.id))
        var children: [String: [SubAgentListItem]] = [:]
        var roots: [SubAgentListItem] = []
        for item in items {
            if let owner = item.info.ownerID, owner != item.id, ids.contains(owner) {
                children[owner, default: []].append(item)
            } else {
                roots.append(item)
            }
        }
        var out: [SubAgentListItem] = []
        var placed = Set<String>()
        func place(_ item: SubAgentListItem, depth: Int) {
            guard placed.insert(item.id).inserted else { return }
            var item = item
            item.depth = depth
            out.append(item)
            for child in children[item.id] ?? [] { place(child, depth: depth + 1) }
        }
        for root in roots { place(root, depth: 0) }
        // 서로를 띄운 것으로 적힌 기록(순환)이라 뿌리에서 닿지 못한 것은 끝에 그대로.
        for item in items where !placed.contains(item.id) { place(item, depth: 0) }
        return out
    }

    /// 목록 한 줄의 종류 자리: subagent_type · workflow_name · agentPath, 없으면 종류 이름 (Claude 셸의 이름은 설명이라
    /// 명령인지 알 수 있게). 하위 에이전트는 이름만으로 알 수 있어 비운다. Claude 의 기본 종류 `general-purpose` 는 줄마다
    /// 같은 말이라 뺀다.
    static func rowKindLabel(_ info: SubAgentInfo) -> String? {
        if let detail = info.detail?.trimmingCharacters(in: .whitespaces), !detail.isEmpty, detail != info.title,
           detail != "general-purpose" {
            return detail
        }
        switch info.kind {
        case .shell, .workflow, .other: return SubAgentDigest.kindName(info.kind)
        case .agent: return nil
        }
    }

    /// 모델의 화면 이름: Claude 전체 ID 는 "Opus 5", Codex 의 `gpt-<버전>-<계열>` 은 "GPT-6 Sol" 처럼, 그 밖은 그대로.
    /// 모르면 nil.
    static func modelLabel(_ model: String?) -> String? {
        guard let model = model?.trimmingCharacters(in: .whitespaces), !model.isEmpty else { return nil }
        if let claude = ModelCatalog.claudeModelName(model) { return claude }
        let parts = model.split(separator: "-").map(String.init)
        if parts.count >= 2, parts[0].lowercased() == "gpt", parts[1].first?.isNumber == true {
            let rest = parts.dropFirst(2).map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return (["GPT-" + parts[1]] + rest).joined(separator: " ")
        }
        return model
    }

    /// 이름 옆의 보조 글: 모델 · 종류 (`rowKindLabel`). 둘 다 없으면 nil.
    static func subtitle(_ info: SubAgentInfo) -> String? {
        let parts = [modelLabel(info.model), rowKindLabel(info)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 목록 한 줄의 경과 자리: "1분 05초" (모르면 빈 글). 도구 수는 고른 하위의 머리에만 둔다 — 좁은 인스펙터에서 이름 옆의
    /// 모델 · 처리 토큰 · 몫이 밀려나지 않게.
    static func rowFacts(_ info: SubAgentInfo, elapsedSeconds: Int?) -> String {
        elapsedSeconds.map { DisplayFormat.elapsed(seconds: $0) } ?? ""
    }

    /// 목록의 실행 묶음 — `items` 의 순서(최근 실행 먼저)대로 같은 실행끼리.
    struct Section: Identifiable {
        var runID: String?
        var isLive: Bool
        var runStartedAt: Date?
        var items: [SubAgentListItem]
        var id: String { runID ?? "-" }
    }

    static func sections(_ items: [SubAgentListItem]) -> [Section] {
        var out: [Section] = []
        for item in items {
            if let last = out.indices.last, out[last].runID == item.runID {
                out[last].items.append(item)
                out[last].isLive = out[last].isLive || item.isLive
            } else {
                out.append(Section(runID: item.runID, isLive: item.isLive, runStartedAt: item.runStartedAt, items: [item]))
            }
        }
        return out
    }

    /// 보여 줄 하위: 고른 것이 목록에 있으면 그것, 없으면 가장 최근에 시작한 도는 하위, 그것도 없으면 가장 최근 실행의 마지막 하위.
    /// 고르지 않았을 때는 들이지 않은 줄(`depth` 0)을 먼저 본다 — 하위가 띄운 셸은 그 하위보다 늦게 시작해 늘 "마지막" 이 된다.
    static func resolve(selected: String?, in items: [SubAgentListItem]) -> String? {
        if let selected, items.contains(where: { $0.id == selected }) { return selected }
        func latest(_ candidates: [SubAgentListItem]) -> SubAgentListItem? {
            let top = candidates.filter { $0.depth == 0 }
            return (top.isEmpty ? candidates : top).max(by: { $0.info.startedAt < $1.info.startedAt })
        }
        if let running = latest(items.filter(\.isRunning)) { return running.id }
        guard let newest = items.first else { return nil }
        return latest(items.filter { $0.runID == newest.runID })?.id
    }

    /// 백그라운드 명령을 띄운 행의 이벤트 (앵커 — 요청 · 결과 · 명령). 메인이 띄웠으면 메인 흐름에, 하위가 띄웠으면
    /// 그 하위의 흐름에 있다 (Claude 의 하위가 띄운 셸 — `owned_by_subagent`). 둘 다 본다.
    static func shellAnchorEvents(id: String, ownerID: String?, main: [ThreadEvent],
                                  flows: [String: [ThreadEvent]]) -> [ThreadEvent] {
        let owned = ownerID.flatMap { flows[$0] } ?? []
        return (main + owned).filter {
            $0.toolUseID == id && ($0.kind == .commandExecution || $0.kind == .toolRequest || $0.kind == .toolResult)
        }
    }

    /// 앵커 행을 못 찾았을 때 보일 한 줄. Codex 의 제목은 명령이라 `$` 를 붙이고, Claude 의 제목은 설명(`description`)이라
    /// 그대로 둔다.
    static func shellFallbackText(_ info: SubAgentInfo, provider: AgentProvider?) -> String {
        provider == .claude ? info.title : "$ " + info.title
    }

    /// 끝난 하위 작업의 결과를 받은 쪽: 대화의 에이전트가 띄웠으면 그 에이전트, 하위가 띄웠으면 그 하위 ("<이름> 에게 전달됨").
    /// `ownerTitle` 은 띄운 하위의 이름 (모르면 nil). "메인" 같은 안쪽 구조의 말은 쓰지 않는다.
    static func deliveredText(_ info: SubAgentInfo, ownerTitle: String?) -> String {
        guard info.ownerID != nil else { return "이 대화의 에이전트에게 전달됨" }
        guard let name = ownerTitle?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return "하위 에이전트에게 전달됨" }
        return "\(name) 에게 전달됨"
    }
}

// MARK: - 누가 얼마나 처리했나 (에이전트 탭 · 하위 카드 · 턴 바닥글)

/// 한 실행 안에서 메인과 하위가 처리한 토큰의 몫. 기준은 **처리 토큰(캐시 포함)** 이다 — Claude 하위 에이전트는 CLI 가
/// 이것(`total_tokens`)만 알려 주고 새 토큰 · 캐시를 나눠 주지 않는다 (2026-10-06, `scripts/probe/claude-background/logs`).
/// 실행 전체(`UsageRecord.totalTokens` — Claude `modelUsage` · Codex 스레드 합은 하위의 것도 담는다)에서 하위 합을 빼면
/// 메인의 몫이다 (추정). 실행이 도는 중이라 전체를 모르면 메인 몫 · 비율은 모른다.
struct TokenShare: Hashable {
    /// 실행 전체의 처리 토큰. 사용량 기록이 없으면(도는 중 · 기록 없음) nil.
    var runTotal: Int?
    /// 하위마다(작업 id) 처리 토큰 — 아는 것만.
    var byAgent: [String: Int]

    var subTotal: Int { byAgent.values.reduce(0, +) }
    /// 메인의 몫 = 전체 − 하위 합 (0 아래로 내려가지 않는다). 전체를 모르면 nil.
    var main: Int? { runTotal.map { max(0, $0 - subTotal) } }
    /// 몫의 분모 — 하위 합이 전체보다 크게 보고되면(값의 뜻이 조금 달라) 하위 합.
    private var denominator: Int { max(runTotal ?? 0, subTotal) }

    /// 전체에서의 비율 (0…1). 전체를 모르거나 값이 없으면 nil.
    func fraction(_ tokens: Int?) -> Double? {
        guard runTotal != nil, let tokens, denominator > 0 else { return nil }
        return Double(tokens) / Double(denominator)
    }

    /// 실행 하나의 몫. 앞에서 돈 셸(`isInternalStep`)과 토큰을 모르는 작업은 뺀다.
    static func make(runUsage: UsageRecord?, infos: [SubAgentInfo]) -> TokenShare {
        var byAgent: [String: Int] = [:]
        for info in infos where !info.isInternalStep {
            if let tokens = info.totalTokens, tokens > 0 { byAgent[info.id] = tokens }
        }
        let total = runUsage.map(\.totalTokens).flatMap { $0 > 0 ? $0 : nil }
        return TokenShare(runTotal: total, byAgent: byAgent)
    }

    /// "42%" · 1% 아래는 "<1%" · 모르면 "—".
    static func percentText(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        if fraction > 0 && fraction < 0.005 { return "<1%" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// 실행 머리의 오른쪽: "처리 21.4만 · 메인 42% · 하위 58%". 전체를 모르면 "하위 처리 1.2만". 아무것도 모르면 nil.
    func headline() -> String? {
        if let runTotal {
            var parts = ["처리 \(DisplayFormat.tokens(max(runTotal, subTotal)))"]
            if !byAgent.isEmpty {
                parts.append("메인 \(Self.percentText(fraction(main)))")
                parts.append("하위 \(Self.percentText(fraction(subTotal)))")
            }
            return parts.joined(separator: " · ")
        }
        return byAgent.isEmpty ? nil : "하위 처리 \(DisplayFormat.tokens(subTotal))"
    }

    /// 턴 바닥글의 펼친 내역 한 줄: "처리 토큰 21.4만 — 메인 9.0만 (42%) · 하위 3개 12.4만 (58%)". 하위의 값이 없으면 nil.
    func footerLine() -> String? {
        guard !byAgent.isEmpty else { return nil }
        let sub = "하위 \(byAgent.count)개 \(DisplayFormat.tokens(subTotal))"
        guard let runTotal, let main else { return "처리 토큰 — \(sub) (메인의 몫은 실행이 끝나면 압니다)" }
        return "처리 토큰 \(DisplayFormat.tokens(max(runTotal, subTotal))) — 메인 \(DisplayFormat.tokens(main)) "
            + "(\(Self.percentText(fraction(main)))) · \(sub) (\(Self.percentText(fraction(subTotal))))"
    }

    /// 처리 토큰이 무엇인지 — 에이전트 탭 · 카드 · 바닥글의 도움말이 같은 말을 쓴다.
    static let help = "처리 토큰: 캐시에서 다시 읽은 것까지 센 양입니다 — 누가 얼마나 일했는지 견주는 값입니다. "
        + "메인의 몫은 실행 전체에서 하위의 몫을 뺀 추정입니다. 청구에 가까운 값은 턴 바닥글의 새 토큰 · API 환산 비용입니다."
}

// MARK: - 터미널 탭의 백그라운드 명령

enum TerminalCommands {
    /// 터미널 탭의 명령 행에 백그라운드 명령 작업(`.shell`)의 상태를 입힌다 — Claude 의 앵커 결과는 "뒤에서 시작함" 확인이라
    /// 행만 보면 도는 명령도 "종료 코드 미확인" 으로 끝난 것처럼 보인다. 도구 id 로 짝짓는다. 같은 id 면 살아 있는 값
    /// (`RunSession.subAgents`)이 저장된 값보다 우선이다. `liveRunIDs` 는 `SubAgentDigest.runFinished` 와 같다.
    static func applyingShellStatus(to entries: [ExecutionEntry], stored: [String: SubAgentInfo], runIDs: [String: String],
                                    runs: [String: Run], live: [SubAgentInfo], liveRunIDs: Set<String>?) -> [ExecutionEntry] {
        let liveShells = Dictionary(live.filter { $0.kind == .shell }.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        guard !liveShells.isEmpty || stored.values.contains(where: { $0.kind == .shell }) else { return entries }
        return entries.map { entry in
            guard case .command = entry.kind else { return entry }
            let id = ExecutionParser.toolKey(of: entry.id)
            let digest: SubAgentDigest
            if let info = liveShells[id] {
                digest = SubAgentDigest(info: info, runID: runIDs[id], runFinished: false, toolCount: 0, lastLine: nil)
            } else if let info = stored[id], info.kind == .shell {
                digest = SubAgentDigest(info: info, runID: runIDs[id],
                                        runFinished: SubAgentDigest.runFinished(runIDs[id], runs: runs, liveRunIDs: liveRunIDs),
                                        toolCount: 0, lastLine: nil)
            } else {
                return entry
            }
            return digest.applyingStatus(to: [entry]).first ?? entry
        }
    }
}

// MARK: - 대화 스트림 행 캐시

/// 대화 스트림 쪽 하위 작업 입력 (대화 상태 상자 `ThreadPaneModel` 의 값).
struct SubAgentStreamInput {
    var infos: [String: SubAgentInfo] = [:]
    var runIDs: [String: String] = [:]
    var events: [String: [ThreadEvent]] = [:]
    /// 위 셋이 바뀔 때마다 느는 수 (`ThreadPaneModel.subAgentRevision`). 요약을 다시 만들지를 이것으로 정한다 —
    /// 메인 글이 자랄 때마다 대화 전체의 하위 기록을 훑지 않게.
    var revision = 0
    /// 지금 세션이 도는 실행. 주면 여기에 없는 실행의 `running` 하위는 끝나지 않은 채 멈춘 것으로 본다. nil 이면 실행 상태만.
    var liveRunIDs: Set<String>? = nil
}

/// 스트리밍 중에는 흐르는 응답 하나만 바뀐다. 그때는 전체를 다시 묶지 않고 그 행만 갈아 끼운다.
/// 하위 에이전트가 일하면(하위 흐름 · 상태가 바뀌면) 요약만 다시 만들어 이미 묶은 행에 갈아 붙인다 — 메인 행을 다시 묶지 않는다.
/// `events` 는 메인 흐름(`ThreadPaneModel.mainEvents`)이다.
///
/// 흐르는 응답이 메인 흐름의 **마지막이 아닐 수 있다**: 하위가 청한 승인 · 질문, 하위가 끝날 때의 앵커 결과는 메인 글을
/// 닫지 않고 저장돼(`RunSession`) 그 뒤에 붙는다. 그래서 마지막 이벤트가 아니라 흐르는 응답(`streaming`)을 따라간다.
final class StreamRowsCache {
    private var key: Int?
    private var lastText: String?
    private var rows: [StreamRow] = []
    private var digestKey: Int?
    private var digests: [String: SubAgentDigest] = [:]
    /// 마지막으로 묶을 때 비교하지 못한 실행들. 이 실행들의 하위 흐름만 키에 넣는다 (관찰된 편집이 하위의 편집도 센다).
    private var uncomparedRuns = Set<String>()

    /// - Parameter streaming: 지금 흐르는 메인 이벤트 (`ThreadPaneModel.streamingMainEvent`). nil 이면 마지막 이벤트를 본다.
    func rows(events: [ThreadEvent], runs: [String: Run], handoffs: [Handoff], projectPath: String?,
              streaming: ThreadEvent? = nil, subAgents: SubAgentStreamInput = SubAgentStreamInput()) -> [StreamRow] {
        // 하위 요약: 하위 기록이 바뀌었거나(수정 번호) 띄운 실행의 상태 · 생사가 바뀔 때만 다시 만든다.
        var digestHasher = Hasher()
        digestHasher.combine(projectPath)
        digestHasher.combine(subAgents.revision)
        digestHasher.combine(subAgents.infos.count)
        for runID in Set(subAgents.runIDs.values).sorted() {
            digestHasher.combine(runID)
            digestHasher.combine(runs[runID]?.state)
            digestHasher.combine(subAgents.liveRunIDs?.contains(runID))
        }
        let newDigestKey = digestHasher.finalize()
        var digestsChanged = false
        if newDigestKey != digestKey {
            let fresh = StreamBuilder.subAgentDigests(infos: subAgents.infos, runIDs: subAgents.runIDs,
                                                      events: subAgents.events, runs: runs, projectPath: projectPath,
                                                      liveRunIDs: subAgents.liveRunIDs)
            digestsChanged = fresh != digests
            digests = fresh
            digestKey = newDigestKey
        }

        let target = streaming ?? events.last
        func makeKey() -> Int {
            var hasher = Hasher()
            // 하위 id 집합이 바뀌면 다시 묶는다 (요약이 붙을 행 · 앵커 행의 늦은 갱신을 모으는 것이 달라진다).
            for id in digests.keys.sorted() { hasher.combine(id) }
            hasher.combine(events.count)
            hasher.combine(events.last?.id)
            hasher.combine(events.last?.isStreaming)
            // 흐르던 응답이 끝나면(마지막 이벤트가 아니어도) 한 번 다시 묶는다.
            hasher.combine(streaming?.id)
            hasher.combine(streaming?.isStreaming)
            hasher.combine(projectPath)
            for run in runs.values.sorted(by: { $0.id < $1.id }) {
                hasher.combine(run.id)
                hasher.combine(run.state)
            }
            for handoff in handoffs {
                hasher.combine(handoff.id)
                hasher.combine(handoff.deliveryState)
            }
            // 비교하지 못한 실행이 있을 때만: 그 실행들의 하위 흐름 수 · 이벤트 수 (하위가 고친 파일도 관찰된 편집이다).
            // 없으면 하위 흐름은 키에 넣지 않는다 — 하위가 일할 때마다 메인 행을 다시 묶지 않게.
            if !uncomparedRuns.isEmpty {
                var flows = 0, total = 0
                for (id, runID) in subAgents.runIDs where uncomparedRuns.contains(runID) {
                    flows += 1
                    total += subAgents.events[id]?.count ?? 0
                }
                hasher.combine(flows)
                hasher.combine(total)
            }
            return hasher.finalize()
        }
        let newKey = makeKey()
        let text = target?.text

        if newKey == key {
            if digestsChanged { rows = StreamBuilder.attaching(digests, to: rows) }
            if text == lastText { return rows }
            // 같은 응답이 스트리밍으로 자라는 중: 그 행만 바꾼다 (뒤에서 찾는다 — 대개 마지막이거나 그 가까이).
            if let target, let index = rows.lastIndex(where: {
                if case .agentMessage(let old) = $0 { return old.id == target.id } else { return false }
            }) {
                rows[index] = .agentMessage(target)
                lastText = text
                return rows
            }
        }

        let built = StreamBuilder.build(events: events, runs: runs, handoffs: handoffs, projectPath: projectPath,
                                        subAgents: digests, subAgentEvents: subAgents.events)
        rows = built.rows
        // 비교하지 못한 실행이 새로 생겼으면 그 하위 흐름까지 넣은 키로 (다음 호출이 까닭 없이 다시 묶지 않게).
        if built.uncomparedRuns != uncomparedRuns {
            uncomparedRuns = built.uncomparedRuns
            key = makeKey()
        } else {
            key = newKey
        }
        lastText = text
        return rows
    }
}

// MARK: - 실행 중 상태 줄

/// 도는 실행이 지금 무엇을 하는지 — 대화 끝의 상태 줄(`RunStatusLine`)이 보인다. 실행 상태와 메인 흐름에 남은 이 실행의
/// 마지막 기록으로 정한다 (결과가 안 온 도구 호출 · 흐르는 응답 · 추론).
enum RunActivity: Hashable {
    case starting
    case thinking
    /// 생각하는 중인데 CLI 가 지금 하는 일을 한 줄로 정리해 줬다 (Claude `task_summary` — `RunSession.progressSummary`).
    case working(String)
    case writing
    /// 결과를 기다리는 도구 호출 — "명령 실행 중 · make test" 처럼 무엇인지까지.
    case tool(String)
    case awaitingApproval
    /// 승인은 없고 에이전트의 질문만 기다린다 (실행 상태는 승인 대기와 같은 `awaitingApproval`).
    case awaitingAnswer
    case waitingBackground(Int)
    case stopping

    /// 상태 줄의 도는 표시가 보일 일의 종류 — 글(`text`)과 같은 기록에서 정한다 (`read`). 모양은 `RunOrb` 가 고른다.
    enum Work: Hashable {
        case thinking, writing, command, editing, searching, fetching, delegating, planning, tool
        case waitingOnPerson, waitingBackground, stopping
    }

    var text: String {
        switch self {
        case .starting: return "시작하는 중"
        case .thinking: return "생각하는 중"
        case .working(let summary): return summary
        case .writing: return "답변을 쓰는 중"
        case .tool(let what): return what
        case .awaitingApproval: return "승인을 기다리는 중"
        case .awaitingAnswer: return "질문에 답을 기다리는 중"
        case .waitingBackground(let count):
            return count > 0 ? "백그라운드 작업 \(count)개를 기다리는 중" : "백그라운드 작업을 기다리는 중"
        case .stopping: return "멈추는 중"
        }
    }

    /// - Parameters:
    ///   - events: 이 대화의 메인 흐름 (순번순). 끝에서부터 이 실행(`runID`)의 기록만 본다.
    ///   - streaming: 지금 흐르는 메인 응답 (`ThreadPaneModel.streamingMainEvent`).
    ///   - questionOnly: 사람을 기다리는 것이 질문뿐이다 (승인 요청은 없다) — "승인" 이 아니라 "질문" 이라고 쓴다.
    ///   - summary: CLI 가 정리한 지금 하는 일 (`RunSession.progressSummary`). "생각하는 중" 자리에만 쓴다 — 도구 · 답변 · 승인 ·
    ///     백그라운드 대기는 그 글이 앞선다.
    static func make(state: RunState, runID: String?, waitingOnBackground: Bool, backgroundCount: Int,
                     events: [ThreadEvent], streaming: ThreadEvent?, projectPath: String?,
                     questionOnly: Bool = false, summary: String? = nil) -> RunActivity {
        read(state: state, runID: runID, waitingOnBackground: waitingOnBackground, backgroundCount: backgroundCount,
             events: events, streaming: streaming, projectPath: projectPath, questionOnly: questionOnly,
             summary: summary).activity
    }

    /// 상태 줄의 글(`activity`)과 도는 표시가 보일 일(`work`)을 함께 — 인수는 `make` 와 같다.
    static func read(state: RunState, runID: String?, waitingOnBackground: Bool, backgroundCount: Int,
                     events: [ThreadEvent], streaming: ThreadEvent?, projectPath: String?,
                     questionOnly: Bool = false, summary: String? = nil) -> (activity: RunActivity, work: Work) {
        let found = observed(state: state, runID: runID, waitingOnBackground: waitingOnBackground,
                             backgroundCount: backgroundCount, events: events, streaming: streaming, projectPath: projectPath,
                             questionOnly: questionOnly)
        guard found.activity == .thinking else { return found }
        if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return (.working(summary), found.work)
        }
        if let heading = reasoningHeading(events: events, runID: runID) { return (.working(heading), found.work) }
        return found
    }

    /// 이 실행의 가장 최근 추론 요약 머리 (Codex — "**Planning build checks**", `ExecutionFold.reasoningHeadings`).
    /// 그 뒤에 에이전트가 말했으면 지난 생각이라 nil. 머리 없는 생각(Claude)도 nil.
    static func reasoningHeading(events: [ThreadEvent], runID: String?) -> String? {
        guard let runID else { return nil }
        for event in events.reversed() {
            guard event.runID == runID else { break }
            switch event.kind {
            case .agentReasoning: return ExecutionFold.reasoningHeadings(event.text).last
            case .agentMessage, .userMessage: return nil
            default: continue
            }
        }
        return nil
    }

    /// 실행 상태 · 기록만으로 정한 글과 일.
    private static func observed(state: RunState, runID: String?, waitingOnBackground: Bool, backgroundCount: Int,
                                 events: [ThreadEvent], streaming: ThreadEvent?,
                                 projectPath: String?, questionOnly: Bool) -> (activity: RunActivity, work: Work) {
        switch state {
        case .starting: return (.starting, .thinking)
        case .interrupting: return (.stopping, .stopping)
        case .awaitingApproval: return (questionOnly ? .awaitingAnswer : .awaitingApproval, .waitingOnPerson)
        default: break
        }
        if waitingOnBackground { return (.waitingBackground(backgroundCount), .waitingBackground) }
        if let streaming, streaming.isStreaming, streaming.runID == runID { return (.writing, .writing) }
        guard let runID else { return (.thinking, .thinking) }
        var answered = Set<String>()
        for event in events.reversed() {
            guard event.runID == runID else { break }
            switch event.kind {
            case .toolResult:
                if let id = event.toolUseID { answered.insert(id) }
            case .toolRequest:
                if let id = event.toolUseID, answered.contains(id) { return (.thinking, .thinking) }
                let kind = ExecutionParser.requestKind(name: event.title, input: event.text, projectPath: projectPath)
                return (.tool(describe(kind)), work(kind))
            case .commandExecution:
                let status = JSONUtil.object(event.payloadJSON ?? "")?["status"] as? String
                guard status == "inProgress" else { return (.thinking, .thinking) }
                return (.tool(describe(.command(CommandInfo(
                    command: ExecutionParser.displayCommand(ExecutionParser.splitCommandText(event.text).0),
                    rawCommand: event.text, output: nil, exitCode: nil, reportedError: false, running: true, cwd: nil)))),
                        .command)
            case .fileChange:
                let status = JSONUtil.object(event.payloadJSON ?? "")?["status"] as? String
                guard status == "inProgress" else { return (.thinking, .thinking) }
                let path = event.text.components(separatedBy: "\n").first.map { ExecutionParser.relativize($0, to: projectPath) }
                return (.tool("파일 고치는 중" + (path.map { " · \($0)" } ?? "")), .editing)
            case .agentReasoning, .agentMessage, .userMessage:
                return (.thinking, .thinking)
            default:
                continue
            }
        }
        return (.thinking, .thinking)
    }

    /// 결과를 기다리는 호출의 일 (`describe` 와 같은 갈래).
    static func work(_ kind: ExecutionEntry.Kind) -> Work {
        switch kind {
        case .command: return .command
        case .fileEdit: return .editing
        case .tool(let info):
            switch info.name {
            case "Read", "Grep", "Glob", "LS", "WebSearch": return .searching
            case "WebFetch": return .fetching
            case "Task", "Agent", "subAgent", "Workflow": return .delegating
            case "TodoWrite": return .planning
            default: return ApprovalPresentation.mcpName(info.name) != nil ? .fetching : .tool
            }
        default:
            return .thinking
        }
    }

    /// 결과를 기다리는 호출 한 줄.
    static func describe(_ kind: ExecutionEntry.Kind) -> String {
        switch kind {
        case .command(let info):
            // CLI 가 준 작업 설명이 있으면 그것 ("Run test suite") — 명령 원문은 펼친 실행 기록에.
            let line = info.label ?? ExecutionParser.firstLine(info.command, max: 80)
            return line.isEmpty ? "명령 실행 중" : "명령 실행 중 · \(line)"
        case .fileEdit(let info):
            return "파일 고치는 중" + (info.paths.first.map { " · \($0)" } ?? "")
        case .tool(let info):
            let summary = info.summary.isEmpty ? "" : " · \(info.summary)"
            switch info.name {
            case "Read": return "파일 읽는 중" + summary
            case "Grep", "Glob", "LS": return "파일 찾는 중" + summary
            case "WebFetch": return "웹 페이지 가져오는 중" + summary
            case "WebSearch": return "웹 검색 중" + summary
            case "Task", "Agent", "subAgent": return "하위 에이전트 실행 중" + summary
            case "Workflow": return "워크플로 실행 중"
            case "TodoWrite": return "할 일 정리 중"
            default:
                if let mcp = ApprovalPresentation.mcpName(info.name) { return "MCP \(mcp.tool) 실행 중" }
                return "\(info.name) 실행 중" + summary
            }
        default:
            return "생각하는 중"
        }
    }
}

// MARK: - 턴 바닥글의 글

/// 턴 끝 바닥글(`TurnFooterRow`)의 글. 한 줄에는 걸린 시간 · 새 토큰(입력 + 출력 — 캐시 제외) · API 환산 비용만 둔다.
/// 캐시 읽기를 넣은 합계는 짧은 Haiku 턴도 "266.9k tok" 처럼 보여 실제로 쓴 양으로 읽혔다 — 캐시 · 비용 출처 · 청구가 아니라는
/// 설명은 도움말과 펼친 내역에 (첫 사용자 시험 H17 · chat-14).
enum TurnFooterText {
    /// "1분 05초 · 새 토큰 1.2만" — 비용은 `cost` 로 따로 (금액을 모르면 화면이 다른 색으로 쓴다).
    static func head(_ usage: UsageRecord) -> String {
        "\(DisplayFormat.duration(ms: usage.durationMs)) · 새 토큰 \(DisplayFormat.tokens(usage.newTokens))"
    }

    /// "API 환산 $0.12". 금액을 모르면 nil.
    static func cost(_ usage: UsageRecord) -> String? {
        usage.costUSD.map { "API 환산 \(DisplayFormat.cost($0))" }
    }

    /// 한 줄 전체 (스트림 선택 · 손쉬운 사용): "1분 05초 · 새 토큰 1.2만 · API 환산 $0.12".
    static func line(_ usage: UsageRecord) -> String {
        let money: String = cost(usage) ?? "금액 미확인"
        return "\(head(usage)) · \(money)"
    }

    /// 펼친 내역의 첫 줄: 새 토큰이 무엇의 합인지 (정확한 수).
    static func newTokensBreakdown(_ usage: UsageRecord) -> String {
        let total: String = DisplayFormat.exactTokens(usage.newTokens)
        let input: String = DisplayFormat.exactTokens(usage.inputTokens)
        let output: String = DisplayFormat.exactTokens(usage.outputTokens)
        return "새 토큰 \(total) = 입력 \(input) + 출력 \(output)"
    }

    /// 펼친 내역의 캐시 줄 — 캐시를 쓰지 않았으면 nil.
    static func cacheBreakdown(_ usage: UsageRecord) -> String? {
        guard usage.cacheReadTokens > 0 || usage.cacheWriteTokens > 0 else { return nil }
        var parts: [String] = ["캐시 읽기 \(DisplayFormat.exactTokens(usage.cacheReadTokens))"]
        if usage.cacheWriteTokens > 0 { parts.append("캐시 쓰기 \(DisplayFormat.exactTokens(usage.cacheWriteTokens))") }
        let joined: String = parts.joined(separator: " · ")
        return "\(joined) — 새 토큰에 세지 않습니다 (비용에는 들어갑니다)"
    }

    /// 비용이 무엇인지 — 도움말 · 펼친 내역이 같은 말을 쓴다.
    static let billingNote = "API 환산은 공개 API 가격표로 계산한 값입니다. 구독(Claude Max · ChatGPT Plus 등)으로 쓰면 실제로 청구되는 금액이 아닙니다."

    /// 줄에 포인터를 올리면 보이는 도움말.
    static func help(_ usage: UsageRecord?, filesUnchanged: Bool) -> String {
        var lines: [String] = []
        if let usage {
            let input: String = DisplayFormat.tokens(usage.inputTokens)
            let output: String = DisplayFormat.tokens(usage.outputTokens)
            var tokens: String = "새 토큰 = 입력 \(input) + 출력 \(output)"
            if usage.cacheReadTokens > 0 || usage.cacheWriteTokens > 0 {
                var cache: String = "캐시 읽기 \(DisplayFormat.tokens(usage.cacheReadTokens))"
                if usage.cacheWriteTokens > 0 { cache += " · 캐시 쓰기 \(DisplayFormat.tokens(usage.cacheWriteTokens))" }
                tokens += " (캐시는 빼고 셉니다 — \(cache))"
            }
            lines.append(tokens)
            lines.append(billingNote)
        }
        if filesUnchanged { lines.append("실행 전후 비교: 이번 실행에서 바뀐 파일 없음") }
        lines.append("눌러서 자세한 내역 · CLI 진단 보기")
        return lines.joined(separator: "\n")
    }
}

// MARK: - 인계 구분 줄의 글

/// 대화 스트림의 인계 구분 줄(`RelayLine`)의 글 — 영어 고정 글("HANDOFF") 없이, 받는 쪽이 일하는 동안은 "전송 중" 이 아니라
/// 받는 쪽이 일하는 중이라고 (첫 사용자 시험 H11).
enum RelayText {
    /// "⇄ 인계 #01".
    static func title(number: Int) -> String { String(format: "⇄ 인계 #%02d", number) }

    /// 상태 글. 행의 상태가 아직 전송 중(`sending`)이어도 그 인계를 전한 실행이 돌고 있으면(`receiverWorking`) 받는 쪽은 이미
    /// 인계 문서를 받아 일하는 중이다 — 행의 상태는 그 실행이 끝나야 정해진다 (`RunSession.resolveHandoffDelivery`).
    /// `files` 는 문서에 적은 바뀐 파일 수, `tokens` 는 문서 길이의 어림 (모르면 nil).
    static func status(state: HandoffDeliveryState?, receiverWorking: Bool, sameProvider: Bool,
                       files: Int, tokens: Int?) -> String {
        var parts: [String] = []
        switch state {
        case .delivered: parts.append("전달 확인")
        case .sending:
            parts.append(receiverWorking ? "받는 쪽 실행 중" : "전송 중")
            if sameProvider { parts.append("세션은 이어지지 않습니다") }
        case .unknown: return "전달 여부 미확인 — 이 대화에 받는 쪽의 응답이 있는지 보세요"
        case .failed: parts.append("전송 실패")
        case .draft: parts.append("초안")
        case nil: parts.append("전달 상태 기록 없음")
        }
        if files > 0 { parts.append("파일 \(files)개") }
        if let tokens { parts.append("약 \(DisplayFormat.tokens(tokens)) 토큰") }
        return parts.joined(separator: " · ")
    }
}
