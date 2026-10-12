import Foundation

// 승인 카드에 보일 내용. 도구 입력(JSON)을 사람이 읽는 모양으로 푼다. SwiftUI 에 의존하지 않아 검증 하네스에서도 컴파일된다.

/// 승인 요청 하나를 카드로 보일 모양: 무엇을 하려는지 한 문장 · 설명 · 본문 블록들 · 결정 단추의 모양.
/// 입력을 해석하지 못하면 어댑터가 만든 글(`ApprovalRequest.detail`)을 그대로 보인다 — 지어내지 않는다.
struct ApprovalPresentation: Hashable {
    /// "명령을 실행하려고 합니다" — 카드 제목은 "<누가> 가 " 뒤에 붙인다.
    var action: String
    /// 에이전트가 붙인 설명 (Bash `description` · 하위 에이전트 설명 · Codex 사유). 없으면 nil.
    var summary: String?
    var blocks: [Block]
    /// 명령이 도는 폴더 — 프로젝트 폴더와 다를 때만.
    var workingDirectory: String?
    /// 되돌릴 수 없는 명령이면 그 까닭 — 카드가 경고 줄 · 위험 색 테두리를 두고 "이번 실행 동안 허용" 을 숨긴다.
    var risk: CommandRisk? = nil
    /// MCP 입력 요청의 입력 칸. 칸이 없는 요청(확인만 받는 것)이면 nil.
    var form: ElicitationForm? = nil
    /// 주 단추의 글 — "허용", MCP 입력 요청은 "보내기"(칸이 있으면) · "수락".
    var primaryTitle = "허용"
    /// "이번 실행 동안 허용" 을 보일지 (`offersSessionScope(_:risk:)`).
    var offersSessionScope = false
    /// 그 단추가 무엇을 언제까지 묻지 않는지 — 카드에 보이는 한 줄. 단추가 없으면 nil.
    var sessionScopeNote: String? = nil
    /// "사유 적기" 를 보일지 — MCP 입력 요청은 거절 사유를 보낼 곳이 없어 숨긴다.
    var offersReason = true
    /// 거절 사유 칸의 자리 글 — 사유가 어디까지 가는지 (Claude 는 에이전트에게, Codex 는 기록에만).
    var reasonPlaceholder = "거절 사유 — 에이전트에게 전달됩니다"
    /// 거절 단추의 글 — 에이전트의 질문(Claude `AskUserQuestion`)은 칸에 적은 글이 답이라 "적은 답 보내기".
    var denyTitle = "거절"
    /// 사유 칸을 처음부터 펼친다 (칸의 글이 곧 답인 요청).
    var revealsReason = false
    /// 에이전트의 질문에 답하는 카드 — 그 단추 · ⌥⌘⌫ · 칸의 ↵ 는 거절이 아니라 답을 보낸다 (`denyDecision`).
    var answersQuestion = false

    /// 거절 단추(질문 카드는 "적은 답 보내기") · ⌥⌘⌫ · 칸의 ↵ 가 보낼 결정. 질문 카드는 적은 글이 답이다 — 비었으면 보낼 것이
    /// 없다 (nil — 단추를 끈다). 답 없이 이어 가려면 "답 없이 진행", 멈추려면 "거절 후 중단".
    func denyDecision(_ text: String) -> ApprovalDecision? {
        guard answersQuestion else { return .deny(text) }
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? nil : .answer(answer)
    }

    enum Block: Hashable {
        /// 셸 명령 (여러 줄일 수 있다).
        case command(String)
        /// 파일 편집: 경로 · 줄들 (지운 줄 · 더한 줄 · 그대로인 줄).
        case diff(path: String, lines: [DiffLine])
        /// 새로 쓰거나 덮어쓰는 파일: 경로 · 내용 · 줄 수.
        case content(path: String, text: String, lineCount: Int)
        /// 한 줄짜리 대상 (읽을 파일 · 찾을 패턴 · 주소 · 검색어).
        case target(String)
        /// 이름: 값 목록 (MCP 도구 · 모르는 도구의 입력).
        case fields([Field])
        /// 여러 줄 글 (계획 · 하위 에이전트에게 줄 지시 · 해석하지 못한 원문).
        case text(String)
    }

    struct Field: Hashable {
        var name: String
        var value: String
    }

    struct DiffLine: Hashable {
        enum Kind: Hashable { case removed, added, context }
        var kind: Kind
        var text: String
    }

    // MARK: 만들기

    static func make(_ request: ApprovalRequest, projectPath: String?) -> ApprovalPresentation {
        var shown = body(request, projectPath: projectPath)
        // 되돌릴 수 없는 명령 — Claude Bash · Codex 명령. 명령이 도는 폴더 기준으로 "프로젝트 폴더 밖" 을 본다.
        if let input = request.input.flatMap({ JSONUtil.object($0) }),
           request.kind == .command || (request.kind == .tool && request.toolName == "Bash"),
           let command = nonEmpty(input["command"] as? String) {
            let cwd = nonEmpty(input["cwd"] as? String) ?? projectPath
            shown.risk = CommandRisk.assess(ExecutionParser.displayCommand(command), workingDirectory: cwd)
        }
        shown.offersSessionScope = offersSessionScope(request, risk: shown.risk)
        shown.sessionScopeNote = shown.offersSessionScope ? sessionScopeNote(request.kind) : nil
        switch request.kind {
        case .elicitation:
            shown.primaryTitle = shown.form == nil ? "수락" : "보내기"
            shown.offersReason = false
        default:
            break
        }
        if shown.revealsReason {
            shown.reasonPlaceholder = "답 — \(request.provider.displayName) 에게 전달됩니다"
        } else if request.provider == .codex {
            shown.reasonPlaceholder = "거절 사유 — 대화 기록에만 남습니다 (Codex 에는 전달되지 않습니다)"
        } else {
            shown.reasonPlaceholder = "거절 사유 — \(request.provider.displayName) 에게 전달됩니다"
        }
        return shown
    }

    /// "이번 실행 동안 허용" 을 보일지: Codex 의 명령 · 파일 변경 · 권한 요청만 (Claude 는 허용과 같고, MCP 입력 요청에는 뜻이 없다).
    /// 되돌릴 수 없는 명령이면 숨긴다 — 같은 명령을 다시 물을 때 한 번 더 보게.
    static func offersSessionScope(_ request: ApprovalRequest, risk: CommandRisk?) -> Bool {
        guard ApprovalDecision.offersSessionScope(request.provider), risk == nil else { return false }
        switch request.kind {
        case .command, .fileChange, .permissions: return true
        case .tool, .elicitation: return false
        }
    }

    /// "이번 실행 동안 허용" 이 실제로 하는 일 (Codex `acceptForSession` — Codex 의 선택지 "don't ask again for this command ·
    /// these files in this session"). 앱은 턴마다 app-server 를 새로 띄우므로 그 세션은 **이번 실행**이다.
    static func sessionScopeNote(_ kind: ApprovalKind) -> String? {
        switch kind {
        case .command: return "같은 명령은 이번 실행이 끝날 때까지 다시 묻지 않습니다. 다음 메시지부터는 다시 묻습니다."
        case .fileChange: return "이 파일들의 변경은 이번 실행이 끝날 때까지 다시 묻지 않습니다. 다음 메시지부터는 다시 묻습니다."
        case .permissions: return "이 권한을 이번 실행이 끝날 때까지 씁니다. 다음 메시지부터는 다시 묻습니다."
        case .tool, .elicitation: return nil
        }
    }

    private static func body(_ request: ApprovalRequest, projectPath: String?) -> ApprovalPresentation {
        let input = request.input.flatMap { JSONUtil.object($0) }
        let fallback = ApprovalPresentation(action: fallbackAction(request), summary: nil,
                                            blocks: request.detail.isEmpty ? [] : [.text(request.detail)])
        guard let input else { return fallback }
        switch request.kind {
        case .tool: return claudeTool(request.toolName, input: input, projectPath: projectPath)
        case .command: return codexCommand(input, projectPath: projectPath) ?? fallback
        case .fileChange: return codexFileChange(input, projectPath: projectPath) ?? fallback
        case .permissions:
            return ApprovalPresentation(action: "권한을 더 요청합니다", summary: nonEmpty(request.title),
                                        blocks: fieldsBlock(input).map { [$0] } ?? fallback.blocks)
        case .elicitation:
            return elicitation(input)
        }
    }

    /// MCP 입력 요청: 서버의 말 · 서버 이름 · (주소를 여는 요청이면) 주소 · 입력 칸. 요청 모양은 실측하지 않았다 —
    /// 맨 위와 `request` 안을 함께 찾고, 아무것도 못 읽으면 원문의 이름: 값을 보인다.
    private static func elicitation(_ input: [String: Any]) -> ApprovalPresentation {
        let request = (input["request"] as? [String: Any]) ?? [:]
        let message = nonEmpty(request["message"] as? String) ?? nonEmpty(input["message"] as? String)
        let server = nonEmpty(input["serverName"] as? String) ?? nonEmpty(input["server_name"] as? String)
            ?? nonEmpty(request["serverName"] as? String)
        let url = nonEmpty(request["url"] as? String) ?? nonEmpty(input["url"] as? String)
        let form = ElicitationForm.parse(input)
        var blocks: [Block] = []
        if let server { blocks.append(.fields([Field(name: "서버", value: server)])) }
        if let url { blocks.append(.target(url)) }
        if message == nil, form == nil, url == nil {
            if let raw = fieldsBlock(input, skipping: ["message", "serverName", "server_name", "threadId", "turnId"]) {
                blocks.append(raw)
            }
        }
        return ApprovalPresentation(action: "MCP 서버가 입력을 요청합니다", summary: message, blocks: blocks, form: form)
    }

    private static func fallbackAction(_ request: ApprovalRequest) -> String {
        switch request.kind {
        case .tool: return "도구를 쓰려고 합니다: \(request.toolName)"
        case .command: return "명령을 실행하려고 합니다"
        case .fileChange: return "파일을 고치려고 합니다"
        case .permissions: return "권한을 더 요청합니다"
        case .elicitation: return "MCP 서버가 입력을 요청합니다"
        }
    }

    // MARK: Claude 도구

    private static func claudeTool(_ name: String, input: [String: Any], projectPath: String?) -> ApprovalPresentation {
        func string(_ key: String) -> String? { nonEmpty(input[key] as? String) }
        func path(_ key: String) -> String? { string(key).map { ExecutionParser.relativize($0, to: projectPath) } }

        switch name {
        case "Bash":
            let background = input["run_in_background"] as? Bool == true
            return ApprovalPresentation(action: background ? "명령을 백그라운드에서 실행하려고 합니다" : "명령을 실행하려고 합니다",
                                        summary: string("description"),
                                        blocks: string("command").map { [.command($0)] } ?? [])
        case "Edit":
            let file = path("file_path") ?? "파일"
            let lines = diffLines(old: input["old_string"] as? String ?? "", new: input["new_string"] as? String ?? "")
            let all = input["replace_all"] as? Bool == true
            return ApprovalPresentation(action: "파일을 고치려고 합니다", summary: all ? "같은 글을 모두 바꿉니다" : nil,
                                        blocks: [.diff(path: file, lines: lines)])
        case "MultiEdit":
            let file = path("file_path") ?? "파일"
            let edits = input["edits"] as? [[String: Any]] ?? []
            var lines: [DiffLine] = []
            for (index, edit) in edits.enumerated() {
                if index > 0 { lines.append(DiffLine(kind: .context, text: "⋯")) }
                lines += diffLines(old: edit["old_string"] as? String ?? "", new: edit["new_string"] as? String ?? "")
            }
            return ApprovalPresentation(action: "파일을 고치려고 합니다",
                                        summary: edits.count > 1 ? "\(edits.count)곳을 바꿉니다" : nil,
                                        blocks: [.diff(path: file, lines: lines)])
        case "Write":
            let text = input["content"] as? String ?? ""
            return ApprovalPresentation(action: "파일을 쓰려고 합니다", summary: nil,
                                        blocks: [.content(path: path("file_path") ?? "파일", text: text,
                                                          lineCount: ExecutionParser.lineCount(text))])
        case "NotebookEdit":
            let text = input["new_source"] as? String ?? ""
            return ApprovalPresentation(action: "노트북을 고치려고 합니다", summary: nil,
                                        blocks: [.content(path: path("notebook_path") ?? "노트북", text: text,
                                                          lineCount: ExecutionParser.lineCount(text))])
        case "Read":
            return ApprovalPresentation(action: "파일을 읽으려고 합니다", summary: nil,
                                        blocks: path("file_path").map { [.target($0)] } ?? [])
        case "Glob", "Grep", "LS":
            let target = [string("pattern"), path("path"), string("glob")].compactMap { $0 }.joined(separator: "  ")
            return ApprovalPresentation(action: "파일을 찾아보려고 합니다", summary: nil,
                                        blocks: target.isEmpty ? [] : [.target(target)])
        case "WebFetch":
            return ApprovalPresentation(action: "웹 페이지를 가져오려고 합니다", summary: string("prompt"),
                                        blocks: string("url").map { [.target($0)] } ?? [])
        case "WebSearch":
            return ApprovalPresentation(action: "웹을 검색하려고 합니다", summary: nil,
                                        blocks: string("query").map { [.target($0)] } ?? [])
        case "Task", "Agent":
            return ApprovalPresentation(action: "하위 에이전트를 띄우려고 합니다", summary: string("description"),
                                        blocks: string("prompt").map { [.text($0)] } ?? [])
        case "ExitPlanMode":
            return ApprovalPresentation(action: "계획을 마치고 실행하려고 합니다", summary: nil,
                                        blocks: string("plan").map { [.text($0)] } ?? [])
        case "Workflow":
            return ApprovalPresentation(action: "워크플로를 실행하려고 합니다", summary: string("description"),
                                        blocks: string("script").map { [.text($0)] } ?? [])
        case AskedQuestion.claudeToolName:
            // 고른 답을 Claude 에게 돌려주는 길(`updatedInput` 의 답)은 실측 전이다 — 질문을
            // 읽기 좋게 보이고, 확인된 길로 답하게 한다: 적은 답은 그 도구의 결과로 Claude 에게 간다 (`ApprovalDecision.answer` —
            // 기록은 거절이 아니라 답). 허용은 답 없이 원래 입력을 돌려줄 뿐이라 단추 이름을 그대로 적는다.
            let blocks: [Block]
            if let questions = askedQuestions(input) {
                blocks = questions.map { Block.text($0) }
            } else {
                blocks = fieldsBlock(input).map { [$0] } ?? []
            }
            let summary = "이 앱은 아직 고른 답을 Claude 에게 바로 돌려주지 못합니다. 아래 칸에 답을 적어 '적은 답 보내기' 를 누르면 "
                + "그 글이 이 질문의 답으로 Claude 에게 전달됩니다."
            var shown = ApprovalPresentation(action: "질문하려고 합니다", summary: summary, blocks: blocks)
            shown.primaryTitle = "답 없이 진행"
            shown.denyTitle = "적은 답 보내기"
            shown.revealsReason = true
            shown.answersQuestion = true
            return shown
        default:
            if let mcp = mcpName(name) {
                return ApprovalPresentation(action: "MCP 도구를 쓰려고 합니다: \(mcp.tool)", summary: mcp.server,
                                            blocks: fieldsBlock(input).map { [$0] } ?? [])
            }
            return ApprovalPresentation(action: "도구를 쓰려고 합니다: \(name)", summary: nil,
                                        blocks: fieldsBlock(input).map { [$0] } ?? [])
        }
    }

    /// Claude `AskUserQuestion` 의 입력(`questions: [{question, header, options: [{label, description}], multiSelect}]`)을
    /// 질문마다 읽기 좋은 글로. 모양이 다르면 nil (이름: 값으로 보인다).
    static func askedQuestions(_ input: [String: Any]) -> [String]? {
        guard let questions = input["questions"] as? [[String: Any]], !questions.isEmpty else { return nil }
        let texts: [String] = questions.compactMap { question in
            guard let text = nonEmpty(question["question"] as? String) else { return nil }
            var lines = [nonEmpty(question["header"] as? String).map { "\($0) — \(text)" } ?? text]
            for (index, option) in ((question["options"] as? [[String: Any]]) ?? []).enumerated() {
                let label = nonEmpty(option["label"] as? String) ?? "선택지 \(index + 1)"
                lines.append("  \(index + 1). \(label)" + (nonEmpty(option["description"] as? String).map { " — \($0)" } ?? ""))
            }
            if question["multiSelect"] as? Bool == true { lines.append("  (여러 개 고를 수 있음)") }
            return lines.joined(separator: "\n")
        }
        return texts.isEmpty ? nil : texts
    }

    /// `mcp__<서버>__<도구>` → 서버 · 도구. 서버 이름이 식별자(UUID 모양)면 서버는 빼고 도구만.
    static func mcpName(_ name: String) -> (server: String?, tool: String)? {
        guard name.hasPrefix("mcp__") else { return nil }
        let parts = name.dropFirst("mcp__".count).components(separatedBy: "__")
        guard parts.count >= 2, let tool = parts.last, !tool.isEmpty else { return nil }
        let server = parts.dropLast().joined(separator: "__")
        let looksLikeID = server.count >= 32 && server.allSatisfy { $0.isHexDigit || $0 == "-" }
        return (looksLikeID || server.isEmpty ? nil : server.replacingOccurrences(of: "_", with: " "), tool)
    }

    // MARK: Codex

    private static func codexCommand(_ input: [String: Any], projectPath: String?) -> ApprovalPresentation? {
        guard let command = nonEmpty(input["command"] as? String) else { return nil }
        let cwd = nonEmpty(input["cwd"] as? String)
        return ApprovalPresentation(action: "명령을 실행하려고 합니다", summary: nonEmpty(input["reason"] as? String),
                                    blocks: [.command(ExecutionParser.displayCommand(command))],
                                    workingDirectory: cwd == projectPath ? nil : cwd)
    }

    private static func codexFileChange(_ input: [String: Any], projectPath: String?) -> ApprovalPresentation? {
        guard let changes = input["changes"] as? [[String: Any]], !changes.isEmpty else { return nil }
        let blocks: [Block] = changes.map { change in
            let path = ExecutionParser.relativize(change["path"] as? String ?? "파일", to: projectPath)
            return .diff(path: path, lines: unifiedDiffLines(change["diff"] as? String ?? ""))
        }
        return ApprovalPresentation(action: changes.count > 1 ? "파일 \(changes.count)개를 고치려고 합니다" : "파일을 고치려고 합니다",
                                    summary: nonEmpty(input["reason"] as? String), blocks: blocks)
    }

    // MARK: 도우미

    /// 바꾸기 전 · 뒤 글을 줄로 (Claude Edit 는 바꿀 부분만 준다). 줄 단위로 견줘(LCS) 그대로인 줄은 문맥, 바뀐 곳은 지운 줄 다음
    /// 더한 줄 — Edit 의 `old_string` 에는 찾을 자리를 가리려고 바뀌지 않는 줄이 섞인다. 실행 기록의 편집 행 수도 같은 셈이다
    /// (`changeCounts`).
    static func diffLines(old: String, new: String) -> [DiffLine] {
        lineDiff(old: lines(old), new: lines(new))
    }

    /// 실제로 바뀐 줄 수 — 승인 카드의 "+a −r" 과 실행 기록의 편집 행이 같은 값을 보인다.
    static func changeCounts(old: String, new: String) -> (added: Int, removed: Int) {
        let diff = diffLines(old: old, new: new)
        return (diff.filter { $0.kind == .added }.count, diff.filter { $0.kind == .removed }.count)
    }

    private static func lines(_ text: String) -> [String] {
        text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// 줄 단위 LCS. 앞뒤의 같은 줄은 먼저 덜고, 가운데가 너무 크면(줄 수의 곱이 `lcsLimit` 넘게) 통째로 바꾼 것으로 본다.
    /// 바뀐 한 덩어리 안에서는 지운 줄을 모두 앞에, 더한 줄을 뒤에 둔다.
    static func lineDiff(old: [String], new: [String]) -> [DiffLine] {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let a = Array(old[prefix..<(old.count - suffix)])
        let b = Array(new[prefix..<(new.count - suffix)])

        var middle: [DiffLine] = []
        if a.count * b.count > lcsLimit || a.isEmpty || b.isEmpty {
            middle = a.map { DiffLine(kind: .removed, text: $0) } + b.map { DiffLine(kind: .added, text: $0) }
        } else {
            // table[i][j] = a[i...] 와 b[j...] 의 LCS 길이 (한 줄 배열로).
            let width = b.count + 1
            var table = [Int32](repeating: 0, count: (a.count + 1) * width)
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    table[i * width + j] = a[i] == b[j] ? table[(i + 1) * width + j + 1] + 1
                        : max(table[(i + 1) * width + j], table[i * width + j + 1])
                }
            }
            var i = 0, j = 0
            var removed: [DiffLine] = [], added: [DiffLine] = []
            func flush() { middle += removed + added; removed = []; added = [] }
            while i < a.count || j < b.count {
                if i < a.count, j < b.count, a[i] == b[j] {
                    flush()
                    middle.append(DiffLine(kind: .context, text: a[i]))
                    i += 1; j += 1
                } else if j >= b.count || (i < a.count && table[(i + 1) * width + j] >= table[i * width + j + 1]) {
                    removed.append(DiffLine(kind: .removed, text: a[i])); i += 1
                } else {
                    added.append(DiffLine(kind: .added, text: b[j])); j += 1
                }
            }
            flush()
        }
        return old[0..<prefix].map { DiffLine(kind: .context, text: $0) } + middle
            + old[(old.count - suffix)...].map { DiffLine(kind: .context, text: $0) }
    }

    /// LCS 표의 크기 상한 (줄 수의 곱). 넘으면 가운데를 통째로 바꾼 것으로 본다.
    static let lcsLimit = 250_000

    /// 통합 diff 를 줄로. 머리(`---` · `+++` · `diff` · `index`)는 빼고 `@@` 는 구분선으로 둔다. diff 표식이 없으면 모두 더한 줄 (새 파일).
    static func unifiedDiffLines(_ diff: String) -> [DiffLine] {
        let raw = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let marked = raw.contains { $0.hasPrefix("@@") || $0.hasPrefix("+") || $0.hasPrefix("-") }
        guard marked else { return raw.filter { !$0.isEmpty }.map { DiffLine(kind: .added, text: $0) } }
        var out: [DiffLine] = []
        for line in raw {
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                continue
            } else if line.hasPrefix("@@") {
                if !out.isEmpty { out.append(DiffLine(kind: .context, text: "⋯")) }
            } else if line.hasPrefix("+") {
                out.append(DiffLine(kind: .added, text: String(line.dropFirst())))
            } else if line.hasPrefix("-") {
                out.append(DiffLine(kind: .removed, text: String(line.dropFirst())))
            } else if !line.isEmpty {
                out.append(DiffLine(kind: .context, text: line.hasPrefix(" ") ? String(line.dropFirst()) : line))
            }
        }
        return out
    }

    /// 입력의 이름: 값 (이름순). 글 · 수 · 참거짓은 그대로, 목록 · 객체는 한 줄 JSON. 비었으면 nil.
    static func fieldsBlock(_ input: [String: Any], skipping: Set<String> = []) -> Block? {
        let fields: [Field] = input.keys.sorted().compactMap { key in
            guard !skipping.contains(key), let value = input[key] else { return nil }
            let text: String
            switch value {
            case let string as String: text = string
            // JSON 의 참거짓도 NSNumber 로 온다 — `as Bool` 은 수 0 · 1 도 받으므로 형식으로 가른다.
            case let number as NSNumber:
                text = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
            case is NSNull: return nil
            default:
                if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
                   let json = String(data: data, encoding: .utf8) { text = json } else { text = "\(value)" }
            }
            return Field(name: key, value: text)
        }
        return fields.isEmpty ? nil : .fields(fields)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - 되돌릴 수 없는 명령

/// 셸 명령이 되돌릴 수 없는 일을 하는지 — 승인 카드가 경고 줄 · 위험 색 테두리를 두고 "이번 실행 동안 허용" 을 숨긴다 (순수).
/// 오탐을 줄이게 **아는 꼴만** 잡는다: `rm -r/-f` · 프로젝트 폴더 밖을 지우는 `rm` · `git push --force/--delete` ·
/// `git reset --hard` · `git clean -f` · 변경을 버리는 `git checkout -- …/.`·`git restore` · `git branch -D` ·
/// `git stash drop/clear` · `sudo` · `chmod/chown/chgrp -R` · `dd of=` · `mkfs` · `diskutil erase…` · `shred` · `find -delete` ·
/// 내려받은 글을 바로 실행하는 꼴 — 셸 · 해석기에 흘리는 `curl … | sh` · `wget … | bash` · `curl … | python3`, 셸 코드 글이 내려받은
/// 글인 `bash -c "$(curl …)"` · `eval "$(curl …)"`, 프로세스 치환 `bash <(curl …)` · `source <(curl …)`.
/// `&&` · `;` · `|` · `$( )` 로 이은 명령과 `xargs` · `env` · `sh -c '…'` · `eval` 안도 본다. CR · CRLF · U+2028 같은 줄 끊는 글자
/// (`CommandWrap.lineBreaks`)는 줄바꿈으로 본다 — 명령 상자가 그 자리에서 줄을 끊어 보이므로, 그 뒤의 명령도 따로 본다.
/// 놓치는 꼴이 있다 — 경고가 없다고 안전한 것은 아니다.
struct CommandRisk: Hashable, Sendable {
    /// 무엇을 하는지 — "파일 · 폴더를 지웁니다".
    var what: String
    /// 잡힌 명령의 꼴 — "rm -rf".
    var command: String

    var text: String { "\(what) (\(command))" }

    /// 받은 글을 그대로 실행하는 셸 — `sh -c '…'` 의 안을 보고, 내려받은 글을 파이프로 받으면 위험으로 본다.
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash"]
    /// 스크립트 파일 없이 부르면 표준 입력을 프로그램으로 읽는 해석기 (`curl … | python3`). `-c` · `-e` · `-m` 처럼 코드나 모듈을
    /// 인수로 주면 표준 입력은 자료다 (`curl … | python3 -m json.tool`).
    static let interpreters: Set<String> = ["python", "python3", "node", "perl", "ruby"]
    /// 글을 내려받아 표준 출력으로 내는 명령.
    static let downloaders: Set<String> = ["curl", "wget"]

    static let downloadRunWhat = "내려받은 스크립트를 바로 실행합니다"

    /// `workingDirectory` 는 명령이 도는 폴더 (모르면 "프로젝트 폴더 밖" 은 판단하지 않는다).
    static func assess(_ command: String, workingDirectory: String?) -> CommandRisk? {
        assess(command, workingDirectory: workingDirectory, codeString: false)
    }

    /// `codeString` — 셸이 코드로 실행하는 글(`sh -c '…'` · `eval …` 의 인수)이다. 그 맨 앞의 치환(`$(curl …)` · `` `curl …` ``)은
    /// 내려받은 글을 코드로 실행한다.
    private static func assess(_ command: String, workingDirectory: String?, codeString: Bool) -> CommandRisk? {
        // 이 파이프라인 앞쪽에서 내려받는 명령 — 그 출력을 받는 셸은 내려받은 글을 그대로 실행한다.
        var download: String?
        // 바로 뒤 명령이 이 여는 글자(`(` · `` ` ``)로 시작하면 그 출력을 코드로 실행하는지 — 그때의 꼴 ("<(" · "$(" · "`").
        var runsNext: [Character: String] = codeString ? ["`": "`"] : [:]
        for (index, piece) in pieces(of: command).enumerated() {
            if !piece.piped { download = nil }
            let inner = innerProgram(of: piece.words[...])
            if let inner {
                if let opener = piece.opener, let form = runsNext[opener], downloaders.contains(inner.name) {
                    let shown = form == "`" ? "`\(inner.name)`" : "\(form)\(inner.name))"
                    return CommandRisk(what: downloadRunWhat, command: shown)
                }
                if let download, receivesProgram(inner.name, inner.args) {
                    return CommandRisk(what: downloadRunWhat, command: "\(download) | \(inner.name)")
                }
                if downloaders.contains(inner.name) { download = inner.name }
            }
            runsNext = substitutionRunner(piece.words, inner: inner, codeStart: codeString && index == 0)
            if let risk = assess(segment: piece.words[...], workingDirectory: workingDirectory) { return risk }
        }
        return nil
    }

    /// 파이프로 받은 글을 프로그램으로 실행하는지 — 셸(`-c` 없이) · 스크립트 인수 없는 해석기 (`-` 는 표준 입력).
    private static func receivesProgram(_ name: String, _ args: ArraySlice<String>) -> Bool {
        if shells.contains(name) { return !args.contains(where: isCommandStringFlag) }
        guard interpreters.contains(name), !args.contains(where: isCodeFlag) else { return false }
        return args.contains("-") || args.allSatisfy { $0.hasPrefix("-") }
    }

    /// 해석기의 코드 · 모듈 인수 (`python3 -c` · `-m` · `node -e` · `--print` · `perl -e` · `-E` · `ruby -e`) — 프로그램은 그 인수다.
    private static func isCodeFlag(_ arg: String) -> Bool {
        ["-c", "-m", "-e", "-E", "--eval", "--print"].contains(arg)
    }

    /// 이 명령 바로 뒤에 붙은 치환의 출력을 코드로 실행하는 꼴 — 여는 글자 → 경고의 꼴 (순수).
    /// 셸 · `source` · `.` 뒤의 `<( )` (프로세스 치환 — 셸이 그 파일을 스크립트로 읽는다), `sh -c $( )` · `eval $( )` · `eval `…``,
    /// 코드 글 맨 앞의 `$( )`.
    private static func substitutionRunner(_ words: [String], inner: (name: String, args: ArraySlice<String>)?,
                                           codeStart: Bool) -> [Character: String] {
        if codeStart, words == ["$"] { return ["(": "$("] }
        guard let inner else { return [:] }
        let operands = inner.args.filter { !$0.hasPrefix("-") }
        if shells.contains(inner.name) || inner.name == "source" || inner.name == "." {
            if inner.args.contains(where: isCommandStringFlag) {
                // `bash -c $(curl …)` · `bash -c `curl …``.
                if operands == ["$"] { return ["(": "$("] }
                return operands.isEmpty ? ["`": "`"] : [:]
            }
            return operands.isEmpty ? ["(": "\(inner.name) <("] : [:]
        }
        if inner.name == "eval" {
            if operands == ["$"] { return ["(": "$("] }
            return operands.isEmpty ? ["`": "`"] : [:]
        }
        return [:]
    }

    /// 명령 글 → 이어 붙인 명령마다의 낱말 (따옴표 · 역슬래시를 푼다). 방향 바꾸기(`>` · `<`)의 대상과 fd 숫자는 뺀다.
    static func segments(of command: String) -> [[String]] {
        pieces(of: command).map(\.words)
    }

    /// 이어 붙인 명령 하나 — 낱말들과, 앞 명령의 출력을 파이프(`|` · `|&`)로 받는지, 바로 앞이 여는 괄호 · 역따옴표 하나인지
    /// (`$(` · `<(` · `` ` `` 의 안 — 치환의 첫 명령).
    struct Piece: Hashable, Sendable {
        var words: [String]
        var piped: Bool
        var opener: Character? = nil
    }

    static func pieces(of command: String) -> [Piece] {
        var pieces: [Piece] = []
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var quote: Character?
        var escaped = false
        var redirectTarget = false
        // 앞 명령과 지금 명령 사이의 연산자 글자들 (줄바꿈 · 괄호 · 역따옴표는 빼고 센다) — "|" · "|&" 면 파이프로 받는다.
        var between = ""
        func endToken() {
            if hasToken {
                if redirectTarget { redirectTarget = false } else { tokens.append(current) }
            }
            current = ""
            hasToken = false
        }
        func endSegment(_ separator: Character) {
            endToken()
            // `<(curl …)` 의 `<` 는 방향 바꾸기가 아니라 치환이다 — 다음 낱말을 대상으로 먹지 않는다.
            redirectTarget = false
            if !tokens.isEmpty {
                let operators = between.filter { !"\n()`".contains($0) }
                let opening = between.filter { $0 != "\n" }
                pieces.append(Piece(words: tokens, piped: operators == "|" || operators == "|&",
                                    opener: opening == "(" || opening == "`" ? opening.first : nil))
                between = ""
            }
            tokens = []
            between.append(separator)
        }
        // CR · CRLF · U+2028 … 도 줄바꿈으로 — 화면이 그 자리에서 줄을 끊어 보인다 (CRLF 는 한 Character 라 그대로는 "\n" 과 같지 않다).
        for character in CommandWrap.normalizingLineBreaks(command) {
            if escaped {
                escaped = false
                // 줄 끝의 역슬래시는 줄 이음 — 빈칸과 같다.
                if character == "\n" { endToken() } else { current.append(character); hasToken = true }
                continue
            }
            if let open = quote {
                if character == open { quote = nil }
                else if character == "\\" && open == "\"" { escaped = true }
                else { current.append(character) }
                continue
            }
            switch character {
            case "\\": escaped = true; hasToken = true
            case "'", "\"": quote = character; hasToken = true
            case " ", "\t": endToken()
            // `2>&1` · `>&2` · `>|` 의 & · | 는 방향 바꾸기의 일부다 (명령을 잇지 않는다).
            case "&" where redirectTarget && !hasToken, "|" where redirectTarget && !hasToken: continue
            case "\n", ";", "&", "|", "(", ")", "`": endSegment(character)
            case ">", "<":
                // `2>/dev/null` 의 2 는 낱말이 아니다.
                if hasToken, !current.isEmpty, current.allSatisfy(\.isNumber) { current = ""; hasToken = false } else { endToken() }
                redirectTarget = true
            default:
                current.append(character)
                hasToken = true
            }
        }
        endSegment("\n")
        return pieces
    }

    /// 감싸는 명령(`sudo` · `env` · `xargs` …)과 앞의 변수 지정을 걷은 실제 프로그램 이름과 인수.
    private static func innerProgram(of segment: ArraySlice<String>) -> (name: String, args: ArraySlice<String>)? {
        let wrappers: Set<String> = ["sudo", "doas", "env", "command", "builtin", "exec", "nohup", "time", "nice", "caffeinate",
                                     "timeout", "xargs", "stdbuf"]
        var rest = segment.drop(while: isAssignment)
        while let head = rest.first {
            let name = (head as NSString).lastPathComponent
            guard wrappers.contains(name) else { return (name, rest.dropFirst()) }
            rest = unwrapped(name, Array(rest.dropFirst())).drop(while: isAssignment)
        }
        return nil
    }

    /// `sh -c '…'` 의 -c (`-lc` · `-ec` 처럼 묶인 것도).
    private static func isCommandStringFlag(_ arg: String) -> Bool {
        arg.hasPrefix("-") && !arg.hasPrefix("--") && arg.contains("c")
    }

    private static func assess(segment: ArraySlice<String>, workingDirectory: String?) -> CommandRisk? {
        var rest = segment
        // 앞의 변수 지정(FOO=bar cmd)은 건너뛴다.
        while let first = rest.first, isAssignment(first) { rest = rest.dropFirst() }
        guard let head = rest.first else { return nil }
        let program = (head as NSString).lastPathComponent
        let args = Array(rest.dropFirst())
        switch program {
        case "sudo", "doas":
            return CommandRisk(what: "관리자 권한으로 실행합니다", command: program)
        case "env", "command", "builtin", "exec", "nohup", "time", "nice", "caffeinate", "timeout", "xargs", "stdbuf":
            return assess(segment: unwrapped(program, args), workingDirectory: workingDirectory)
        case _ where shells.contains(program):
            // `sh -c '…'` 안의 명령 — 그 글은 셸이 코드로 실행한다 (맨 앞의 `$(curl …)` 도).
            if let index = args.firstIndex(where: isCommandStringFlag), index + 1 < args.count {
                return assess(args[index + 1], workingDirectory: workingDirectory, codeString: true)
            }
            return nil
        case "eval":
            // eval 은 인수를 빈칸으로 이어 다시 읽는다.
            return assess(args.joined(separator: " "), workingDirectory: workingDirectory, codeString: true)
        case "rm":
            return rm(args, workingDirectory: workingDirectory)
        case "git":
            return git(args)
        case "chmod", "chown", "chgrp":
            let recursive = args.contains { $0 == "--recursive" || (shortFlags($0)?.contains("R") ?? false) }
            return recursive ? CommandRisk(what: "폴더 안 모든 파일의 권한 · 소유자를 바꿉니다", command: "\(program) -R") : nil
        case "dd":
            return args.contains { $0.hasPrefix("of=") }
                ? CommandRisk(what: "디스크 · 파일을 그대로 덮어씁니다", command: "dd of=") : nil
        case "shred":
            return CommandRisk(what: "파일을 복구할 수 없게 지웁니다", command: "shred")
        case "diskutil":
            let erasing = ["erasedisk", "erasevolume", "partitiondisk", "zerodisk", "randomdisk", "secureerase", "reformat"]
            guard let sub = args.first, erasing.contains(sub.lowercased()) else { return nil }
            return CommandRisk(what: "디스크를 지웁니다", command: "diskutil \(sub)")
        case "find":
            if args.contains("-delete") { return CommandRisk(what: "찾은 파일을 지웁니다", command: "find -delete") }
            if let index = args.firstIndex(where: { ["-exec", "-execdir", "-ok", "-okdir"].contains($0) }) {
                let inner = args[(index + 1)...].prefix { $0 != ";" && $0 != "+" }
                return assess(segment: inner, workingDirectory: workingDirectory)
            }
            return nil
        default:
            if program == "mkfs" || program.hasPrefix("mkfs.") || program == "newfs" || program.hasPrefix("newfs_") {
                return CommandRisk(what: "디스크를 포맷합니다", command: program)
            }
            return nil
        }
    }

    /// `-rf` 같은 짧은 선택지 묶음의 글자들. 짧은 선택지가 아니면 nil.
    private static func shortFlags(_ arg: String) -> String? {
        guard arg.count > 1, arg.hasPrefix("-"), !arg.hasPrefix("--") else { return nil }
        return String(arg.dropFirst())
    }

    private static func isAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return false }
        return token[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// 감싸는 명령(`xargs -n 1 rm …` · `env FOO=1 rm …` · `timeout 10 rm …`)의 선택지를 걷고 안의 명령을.
    private static func unwrapped(_ wrapper: String, _ args: [String]) -> ArraySlice<String> {
        let takesValue: Set<String>
        switch wrapper {
        case "xargs": takesValue = ["-n", "-I", "-L", "-P", "-s", "-E", "-d", "-a", "-J", "-R", "-S"]
        case "env": takesValue = ["-u", "-C", "-S", "-P"]
        case "nice": takesValue = ["-n"]
        case "timeout": takesValue = ["-s", "-k", "--signal", "--kill-after"]
        case "sudo": takesValue = ["-u", "-g", "-C", "-D", "-h", "-p", "-R", "-r", "-T", "-t", "-U"]
        case "doas": takesValue = ["-u", "-C"]
        default: takesValue = []
        }
        var index = 0
        while index < args.count {
            let arg = args[index]
            if takesValue.contains(arg) { index += 2; continue }
            if arg.hasPrefix("-") || (wrapper == "env" && isAssignment(arg)) { index += 1; continue }
            break
        }
        // timeout 은 시간 다음이 명령이다.
        if wrapper == "timeout", index < args.count { index += 1 }
        return args[min(index, args.count)...]
    }

    private static func rm(_ args: [String], workingDirectory: String?) -> CommandRisk? {
        var recursive = false, force = false, optionsOver = false
        var targets: [String] = []
        for arg in args {
            if !optionsOver, arg == "--" { optionsOver = true; continue }
            if !optionsOver, arg.hasPrefix("--") {
                if arg == "--recursive" { recursive = true }
                if arg == "--force" { force = true }
                continue
            }
            if !optionsOver, let flags = shortFlags(arg) {
                if flags.contains("r") || flags.contains("R") { recursive = true }
                if flags.contains("f") { force = true }
                continue
            }
            targets.append(arg)
        }
        if recursive || force {
            return CommandRisk(what: "파일 · 폴더를 지웁니다", command: "rm -" + (recursive ? "r" : "") + (force ? "f" : ""))
        }
        if let outside = targets.first(where: { isOutside($0, base: workingDirectory) }) {
            return CommandRisk(what: "프로젝트 폴더 밖의 파일을 지웁니다", command: "rm \(outside)")
        }
        return nil
    }

    private static func git(_ args: [String]) -> CommandRisk? {
        // 전역 선택지(-C <폴더> · -c <키=값> · --no-pager …)를 걷고 하위 명령을 찾는다.
        var index = 0
        while index < args.count {
            let arg = args[index]
            if ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"].contains(arg) { index += 2; continue }
            if arg.hasPrefix("-") { index += 1; continue }
            break
        }
        guard index < args.count else { return nil }
        let sub = args[index]
        let rest = Array(args[(index + 1)...])
        func has(_ names: String...) -> Bool { rest.contains { names.contains($0) } }
        func hasShort(_ letter: Character) -> Bool { rest.contains { shortFlags($0)?.contains(letter) ?? false } }
        switch sub {
        case "push":
            let force = has("--force", "--mirror") || rest.contains { $0.hasPrefix("--force-with-lease") } || hasShort("f")
                || rest.contains { $0.count > 1 && $0.hasPrefix("+") }
            if force { return CommandRisk(what: "원격의 커밋을 덮어씁니다", command: "git push --force") }
            let delete = has("--delete") || hasShort("d") || rest.contains { $0.count > 1 && $0.hasPrefix(":") }
            return delete ? CommandRisk(what: "원격 브랜치를 지웁니다", command: "git push --delete") : nil
        case "reset":
            return has("--hard") ? CommandRisk(what: "커밋하지 않은 변경을 버립니다", command: "git reset --hard") : nil
        case "clean":
            return has("--force") || hasShort("f")
                ? CommandRisk(what: "추적하지 않는 파일을 지웁니다", command: "git clean -f") : nil
        case "checkout":
            let discards = has("--force", ".") || hasShort("f")
                || rest.firstIndex(of: "--").map { $0 + 1 < rest.count } == true
            return discards ? CommandRisk(what: "커밋하지 않은 변경을 버립니다", command: "git checkout") : nil
        case "restore":
            // `--staged` 만이면 올린 것을 내릴 뿐이다. 작업 폴더(기본 · --worktree)를 되돌리면 버린다.
            let staged = has("--staged") || hasShort("S")
            let worktree = has("--worktree") || hasShort("W")
            return !staged || worktree ? CommandRisk(what: "커밋하지 않은 변경을 버립니다", command: "git restore") : nil
        case "branch":
            let delete = hasShort("D") || (has("--delete") || hasShort("d")) && (has("--force") || hasShort("f"))
            return delete ? CommandRisk(what: "병합하지 않은 브랜치도 지웁니다", command: "git branch -D") : nil
        case "stash":
            guard let action = rest.first, action == "drop" || action == "clear" else { return nil }
            return CommandRisk(what: "보관한 변경을 지웁니다", command: "git stash \(action)")
        default:
            return nil
        }
    }

    /// 경로가 `base`(명령이 도는 폴더) 밖인가. 절대 경로 · `~` · `$HOME` · `..` 가 든 상대 경로만 본다 — 그냥 상대 경로는 안이다.
    /// 파일 시스템을 묻지 않는다 (심볼릭 링크는 풀지 않는다).
    static func isOutside(_ path: String, base: String?) -> Bool {
        guard let base, base.hasPrefix("/") else { return false }
        var expanded = path
        for home in ["${HOME}", "$HOME"] where expanded.hasPrefix(home) {
            expanded = NSHomeDirectory() + expanded.dropFirst(home.count)
        }
        if expanded == "~" || expanded.hasPrefix("~/") { expanded = NSHomeDirectory() + expanded.dropFirst() }
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else if expanded.hasPrefix("~") {
            return true   // 다른 사용자의 홈 (~name)
        } else if expanded.split(separator: "/").contains("..") {
            absolute = base + "/" + expanded
        } else {
            return false
        }
        let target = normalized(absolute)
        let root = normalized(base)
        return !(target == root || target.hasPrefix(root == "/" ? "/" : root + "/"))
    }

    /// `.` · `..` 를 푼 절대 경로 (파일 시스템을 묻지 않는다).
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(component)
        }
        return "/" + parts.joined(separator: "/")
    }
}

// MARK: - MCP 입력 요청의 입력 칸

/// MCP 입력 요청(Codex `mcpServer/elicitation/request`)의 입력 칸 — 요청의 `requestedSchema`(MCP 의 제한된 JSON 스키마:
/// 글 · 수 · 참거짓 · 하나 고르기 · 여럿 고르기)로 만든다 (순수). 요청의 모양은 실측하지 않았다 — 맨 위와 `request` 안을
/// 함께 찾는다. 칸이 없으면(확인만 받는 요청) nil 이고, 그때는 빈 내용으로 수락한다.
/// 화면의 값은 칸 이름 → 글이다: 참거짓은 "true" · "false", 여럿 고르기는 고른 값들을 줄바꿈으로 이은 글.
struct ElicitationForm: Hashable, Sendable {
    struct Option: Hashable, Sendable {
        var value: String
        var label: String
    }

    struct Field: Hashable, Sendable, Identifiable {
        enum Kind: Hashable, Sendable {
            case text
            case number(integer: Bool)
            case toggle
            case choice([Option])
            case multiChoice([Option])
        }
        var id: String
        var title: String
        var detail: String?
        var kind: Kind
        var required: Bool
        /// 화면 칸의 첫 값 (스키마의 `default`).
        var initial: String
    }

    var fields: [Field]

    static func parse(_ input: [String: Any]) -> ElicitationForm? {
        let request = (input["request"] as? [String: Any]) ?? [:]
        let candidates = [input["requestedSchema"], request["requestedSchema"], input["requested_schema"], request["requested_schema"]]
        guard let schema = candidates.lazy.compactMap({ $0 as? [String: Any] }).first,
              let properties = schema["properties"] as? [String: Any], !properties.isEmpty else { return nil }
        let required = Set(schema["required"] as? [String] ?? [])
        var fields: [Field] = []
        for name in properties.keys {
            guard let property = properties[name] as? [String: Any] else { continue }
            let title = (property["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
            let detail = (property["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let kind = Self.kind(property)
            fields.append(Field(id: name, title: title, detail: detail, kind: kind, required: required.contains(name),
                                initial: initialValue(property["default"], kind: kind)))
        }
        // JSON 객체에는 순서가 없다 — 필요한 칸을 먼저, 그다음 이름 순.
        fields.sort { ($0.required ? 0 : 1, $0.id) < ($1.required ? 0 : 1, $1.id) }
        return fields.isEmpty ? nil : ElicitationForm(fields: fields)
    }

    private static func kind(_ property: [String: Any]) -> Field.Kind {
        func options(_ schema: [String: Any]) -> [Option]? {
            if let values = schema["enum"] as? [String], !values.isEmpty {
                let names = schema["enumNames"] as? [String]
                return values.enumerated().map { index, value in
                    Option(value: value, label: names.flatMap { index < $0.count ? $0[index] : nil } ?? value)
                }
            }
            let titled = (schema["oneOf"] as? [[String: Any]]) ?? (schema["anyOf"] as? [[String: Any]]) ?? []
            let found = titled.compactMap { item -> Option? in
                guard let value = item["const"] as? String else { return nil }
                return Option(value: value, label: (item["title"] as? String) ?? value)
            }
            return found.isEmpty ? nil : found
        }
        switch property["type"] as? String {
        case "boolean": return .toggle
        case "number": return .number(integer: false)
        case "integer": return .number(integer: true)
        case "array":
            if let items = property["items"] as? [String: Any], let found = options(items) { return .multiChoice(found) }
            return .text
        default:
            return options(property).map { .choice($0) } ?? .text
        }
    }

    private static func initialValue(_ value: Any?, kind: Field.Kind) -> String {
        switch (kind, value) {
        case (.toggle, let flag as Bool): return flag ? "true" : "false"
        case (.toggle, _): return "false"
        case (.multiChoice, let list as [String]): return list.joined(separator: "\n")
        case (_, let text as String): return text
        case (_, let number as NSNumber): return number.stringValue
        default: return ""
        }
    }

    /// 아직 채우지 않았거나 잘못 채운 칸 (순서대로) — 필요한 칸이 비었거나, 수 칸이 수가 아니거나, 고른 값이 선택지에 없다.
    func problems(_ values: [String: String]) -> [String] {
        fields.filter { field in
            let text = (values[field.id] ?? field.initial).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return field.required && !(field.kind == .toggle) }
            return Self.value(text, kind: field.kind) == nil
        }.map(\.id)
    }

    /// 보낼 내용 (칸 이름 → 값). 채우지 않은 선택 칸은 뺀다. 고칠 칸이 있으면 nil.
    func content(_ values: [String: String]) -> [String: Any]? {
        guard problems(values).isEmpty else { return nil }
        var out: [String: Any] = [:]
        for field in fields {
            let text = (values[field.id] ?? field.initial).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty, field.kind != .toggle { continue }
            if let value = Self.value(text.isEmpty ? "false" : text, kind: field.kind) { out[field.id] = value }
        }
        return out
    }

    /// `ApprovalDecision.submit` 에 실을 JSON 객체 글.
    func contentJSON(_ values: [String: String]) -> String? {
        content(values).flatMap { JSONUtil.line($0) }
    }

    private static func value(_ text: String, kind: Field.Kind) -> Any? {
        switch kind {
        case .text: return text
        case .toggle: return text == "true"
        case .number(let integer):
            guard let number = Double(text), number.isFinite else { return nil }
            if integer { return number.rounded() == number ? Int(number) : nil }
            return number
        case .choice(let options):
            return options.contains { $0.value == text } ? text : nil
        case .multiChoice(let options):
            let picked = text.split(separator: "\n").map(String.init)
            return picked.allSatisfy { value in options.contains { $0.value == value } } ? picked : nil
        }
    }
}

// MARK: - 승인 카드의 결정 단추 (연속 클릭 막기)

/// 승인 카드의 결정 단추가 눌림을 받는가 (순수 — 메뉴 단축키도 같은 판정을 거친다). 앞 카드를 허용하자마자 다음 카드가 같은
/// 자리에 뜨면 이어 누른 손이 확인하지 않은 다음 요청을 허용할 수 있다 — 카드가 나타난 뒤 `armDelay` 동안은 받지 않는다.
/// 한 번 눌렀으면 응답이 끝날 때까지 그 카드의 단추를 모두 받지 않는다(`responding` — 같은 응답을 두 번 보내지 않게).
enum ApprovalCardGate {
    /// 카드가 나타난 뒤 단추를 받기 시작할 때까지 (초).
    static let armDelay: TimeInterval = 0.6

    static func accepts(shownAt: Date?, now: Date, responding: Bool) -> Bool {
        guard !responding, let shownAt else { return false }
        return now.timeIntervalSince(shownAt) >= armDelay
    }

    /// 단추를 켤 때까지 남은 시간 (0 이면 이미 켜졌다).
    static func remaining(shownAt: Date?, now: Date) -> TimeInterval {
        guard let shownAt else { return armDelay }
        return max(0, armDelay - now.timeIntervalSince(shownAt))
    }
}

// MARK: - 질문 카드

extension UserQuestion {
    /// 질문 행의 글 — 항목마다 "머리말: 질문" (머리말이 없으면 질문만).
    var promptText: String {
        items.map { $0.header.isEmpty ? $0.question : "\($0.header): \($0.question)" }.joined(separator: "\n")
    }

    /// 답을 보낸 뒤의 질문 행 글 — 항목마다 질문 아래 "→ 답". 비밀 입력(`isSecret`)은 가린다.
    func recordText(answers: [String: String]) -> String {
        items.map { item in
            let ask = item.header.isEmpty ? item.question : "\(item.header): \(item.question)"
            guard let answer = answers[item.id] else { return ask }
            return ask + "\n→ " + (item.isSecret ? "(가린 답)" : answer)
        }.joined(separator: "\n")
    }
}

/// 질문 카드의 답 (순수). 선택지는 미리 고르지 않는다 — 고르지 않은 선택 · 빈 답은 보내지 않는다. "직접 입력"(`allowsOther`)을
/// 고르면 적은 글이 답이다.
enum QuestionAnswers {
    /// 선택 목록의 "직접 입력" 표시 (선택지 글과 겹치지 않는 값).
    static let otherTag = "\u{1}직접 입력"

    /// 항목 하나의 답. 아직 없으면 nil.
    static func answer(for item: UserQuestion.Item, choice: String?, text: String?) -> String? {
        let typed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if item.options.isEmpty { return typed.isEmpty ? nil : typed }
        guard let choice, !choice.isEmpty else { return nil }
        if choice == otherTag { return item.allowsOther && !typed.isEmpty ? typed : nil }
        return item.options.contains(choice) ? choice : nil
    }

    /// 아직 답하지 않은 항목 ID (순서대로).
    static func missing(_ question: UserQuestion, choices: [String: String], texts: [String: String]) -> [String] {
        question.items.filter { answer(for: $0, choice: choices[$0.id], text: texts[$0.id]) == nil }.map(\.id)
    }

    /// 보낼 답 전부 (항목 ID → 답). 하나라도 비었으면 nil.
    static func payload(_ question: UserQuestion, choices: [String: String], texts: [String: String]) -> [String: String]? {
        var out: [String: String] = [:]
        for item in question.items {
            guard let answer = answer(for: item, choice: choices[item.id], text: texts[item.id]) else { return nil }
            out[item.id] = answer
        }
        return out
    }
}

// MARK: - 명령 상자의 줄 나누기

/// 승인 카드의 명령 상자 줄 나누기 (순수 — 고정폭 글꼴의 열 수로). 명령은 **빈칸에서만** 꺾는다 — 좁은 칸에서 `--filter` 가
/// `--` 와 `filter` 로 갈라져 다른 인수처럼 읽히지 않게. 한 낱말이 한 줄보다 길면 그 낱말만 열 수에서 자른다.
/// 꺾은 줄(`continued`)은 화면이 이어지는 줄로 표시해 명령의 진짜 줄바꿈과 가른다. 복사는 원문을 쓴다.
/// 원문은 LF 뿐 아니라 줄을 끊는 글자(`lineBreaks` — CR · CRLF · U+0085 · U+2028 · U+2029 · 세로 탭 · 폼 피드)마다 끊고,
/// 보이지 않거나 글 순서를 바꾸는 글자는 표시(␍ · ⟨U+202E⟩)로 바꿔 보인다 (`visibleLines`) — 텍스트 뷰가 그 글자에서 줄을 끊거나
/// 감춰 `npm test<CR>; curl … | sh` 가 "npm test" 한 줄로 보이던 결함. 위험 판정(`CommandRisk`)도 같은 글자를 줄바꿈으로 본다.
enum CommandWrap {
    struct Line: Hashable {
        var text: String
        /// 앞 줄에서 꺾여 이어지는 줄 (원문의 줄바꿈이 아니다).
        var continued: Bool
    }

    /// 줄을 끊는 글자 — Swift · TextKit 이 줄바꿈으로 그리거나 터미널이 줄 머리로 돌아가는 글자. CRLF 는 한 번 끊는다.
    static let lineBreaks: Set<Unicode.Scalar> = ["\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"]

    /// 표시로 바꾼 글자가 있을 때 상자 아래 한 줄.
    static let markerNote = "숨은 글자를 ␍ · ⟨U+…⟩ 꼴로 바꿔 보입니다. 실행되는 명령에는 원래 글자가 있습니다 — '명령 복사' 는 원문을 복사합니다."

    static func lines(_ command: String, columns: Int) -> [Line] {
        let columns = max(columns, 8)
        var out: [Line] = []
        for line in visibleLines(command) {
            guard width(line) > columns else { out.append(Line(text: line, continued: false)); continue }
            var pieces: [String] = []
            var current = ""
            var currentWidth = 0
            // 이 줄 조각에 낱말을 하나라도 넣었는가 (빈 낱말 — 앞이나 겹친 빈칸 — 도 낱말이라 빈칸이 사라지지 않는다).
            var started = false
            for word in line.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
                let wordWidth = width(word)
                let gap = started ? 1 : 0
                if currentWidth + gap + wordWidth <= columns {
                    if started { current += " " }
                    current += word
                    currentWidth += gap + wordWidth
                    started = true
                    continue
                }
                if started { pieces.append(current) }
                // 한 줄보다 긴 낱말은 열 수에서 자른다.
                var rest = Substring(word)
                while width(String(rest)) > columns {
                    var taken = ""
                    var takenWidth = 0
                    for character in rest {
                        let w = width(character)
                        if takenWidth + w > columns { break }
                        taken.append(character)
                        takenWidth += w
                    }
                    if taken.isEmpty { taken = String(rest.prefix(1)) }
                    pieces.append(taken)
                    rest = rest.dropFirst(taken.count)
                }
                current = String(rest)
                currentWidth = width(current)
                started = true
            }
            if started || pieces.isEmpty { pieces.append(current) }
            for (index, piece) in pieces.enumerated() { out.append(Line(text: piece, continued: index > 0)) }
        }
        return out
    }

    /// 화면에 보일 원문의 줄들. 줄을 끊는 글자(`lineBreaks`)마다 끊고, LF 가 아닌 것은 그 줄 끝에 표시로 남긴다 ("npm test␍").
    /// 줄 안의 보이지 않거나 속이는 글자도 표시로 바꾼다 (`marker(for:)`).
    static func visibleLines(_ command: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var afterCR = false
        for scalar in command.unicodeScalars {
            // CRLF 는 CR 에서 이미 끊었다.
            let crlf = scalar == "\n" && afterCR
            afterCR = scalar == "\r"
            if crlf { continue }
            if lineBreaks.contains(scalar) {
                if scalar != "\n" { current += marker(for: scalar) ?? "" }
                lines.append(current)
                current = ""
            } else if let mark = marker(for: scalar) {
                current += mark
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        lines.append(current)
        return lines
    }

    /// 한 줄 자리(경고 줄 · 실행 위치)에 보일 글 — 줄을 끊는 글자도 표시로 남기고 빈칸으로 잇는다.
    static func visibleLine(_ text: String) -> String {
        visibleLines(text).joined(separator: " ")
    }

    /// 원문에 표시로 바꾸는 글자가 있는가 — 줄을 골라 복사하면 표시가 복사되므로 화면이 "명령 복사" 를 둔다.
    static func hasMarkers(_ command: String) -> Bool {
        command.unicodeScalars.contains { $0 != "\n" && marker(for: $0) != nil }
    }

    /// 그대로 그리면 보이지 않거나 · 줄을 끊거나 · 글 순서를 바꾸는 글자의 표시. 그대로 그려도 되면 nil.
    /// C0 제어 글자는 제어 그림 글자(␀ … ␟ — CR 은 ␍), DEL 은 ␡, 나머지는 ⟨U+XXXX⟩. 탭은 그대로.
    static func marker(for scalar: Unicode.Scalar) -> String? {
        switch scalar.value {
        case 0x09:
            return nil
        case 0x00...0x1F:
            return Unicode.Scalar(0x2400 + scalar.value).map { String(Character($0)) }
        case 0x7F:
            return "␡"
        case 0x80...0x9F,                          // C1 제어 글자 (U+0085 다음 줄 포함)
             0x00AD, 0x180E,                       // 보이지 않는 하이픈 · 몽골어 모음 구분
             0x061C, 0x200E, 0x200F,               // 방향 표시 (ALM · LRM · RLM)
             0x202A...0x202E, 0x2066...0x2069,     // 방향 덮어쓰기 · 격리
             0x200B...0x200D, 0x2060...0x2064, 0xFEFF, // 폭 없는 글자 · 보이지 않는 연산자 · BOM
             0x2028, 0x2029,                       // 줄 · 문단 구분
             0xE0000...0xE007F:                    // 태그 글자 (보이지 않는 ASCII)
            return "⟨U+" + String(format: "%04X", scalar.value) + "⟩"
        default:
            return nil
        }
    }

    /// 줄을 끊는 글자를 모두 LF 로 (CRLF 는 하나로) — 위험 판정이 화면과 같은 자리에서 명령을 나누게.
    static func normalizingLineBreaks(_ text: String) -> String {
        var out = ""
        var afterCR = false
        for scalar in text.unicodeScalars {
            let crlf = scalar == "\n" && afterCR
            afterCR = scalar == "\r"
            if crlf { continue }
            out.unicodeScalars.append(lineBreaks.contains(scalar) ? "\n" : scalar)
        }
        return out
    }

    /// 고정폭 글꼴에서 차지하는 열 — 넓은 글자(한글 · 한자 · 가나 · 이모지)는 2 로 센다 (넉넉히 — 줄이 넘치지 않게).
    static func width(_ text: String) -> Int { text.reduce(0) { $0 + width($1) } }

    static func width(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        return scalar.value < 0x1100 ? 1 : 2
    }
}

// MARK: - 승인 방식 문구

/// 입력창 승인 칩 · 팝오버의 문구. 대화의 자동 승인 여부와 **제공자의 실제 정책**(설정 > 에이전트의 Claude 권한 모드 ·
/// Codex 승인 정책 · 샌드박스)으로 정한다. 설정 화면의 선택지(`ClaudeApprovalPreset` · `CodexApprovalPreset`)와 같은 말을 쓴다.
/// 칩이 "묻는다"고 적었는데 CLI 가 묻지 않는 일이 없게 한다 —
/// Codex 기본값(workspace-write + on-request)은 작업 폴더 안의 편집 · 명령을 묻지 않는다.
/// 보장할 수 없는 것은 약속하지 않는다: on-request 는 Codex 가 필요하다고 판단할 때만 묻는다.
struct ApprovalPolicyText: Equatable {
    /// 칩과 팝오버 첫 행의 제목.
    var title: String
    /// 팝오버 설명 · 칩 도움말.
    var detail: String
    var systemImage: String
    /// 묻지 않고 넓게 실행한다 — 칩을 경고색으로.
    var caution: Bool = false

    /// 자동 승인(앱이 요청을 허용)을 켠 대화. 늘 사람에게 보이는 것은 `ApprovalRequest.allowsAutoApproval` 과 같은 말로.
    /// Codex 의 명령 · 파일 변경 승인은 샌드박스 밖(인터넷 · 폴더 밖)으로 나가는 요청이어도 자동 허용한다 — Codex 기본
    /// (workspace-write + on-request)이 묻는 것은 거의 그것뿐이고, 요청에는 넓히는지의 표시가 없다 (codex 0.154 스키마 —
    /// `networkApprovalContext` 만). 사용자 결정 2026-10-09: 동작은 그대로, 글을 동작에 맞춘다. 묻는 것은 `item/permissions`
    /// 의 권한 요청 · MCP 입력 요청 · 질문뿐.
    static let autoApproval = ApprovalPolicyText(
        title: "자동 승인",
        detail: "묻지 않고 허용합니다 — Codex 가 샌드박스 밖에서 실행하려는 명령(인터넷 접속 · 폴더 밖 수정)도 허용합니다. "
            + "Codex 의 권한 요청 · MCP 입력 요청 · 에이전트의 질문만 묻습니다. "
            + "인계로 받는 에이전트가 바뀌면 꺼집니다. 허용한 것은 대화 기록에 \"자동 허용\"으로 남습니다.",
        systemImage: "bolt.shield", caution: true)

    /// 자동 승인을 켜기 전의 확인 글 — 무엇이 묻지 않고 실행되는지. Codex 는 샌드박스 밖 실행도 허용된다는 것을 따로 적는다.
    static func autoApprovalConfirmation(provider: AgentProvider) -> String {
        "이 대화의 에이전트가 묻지 않고 명령을 실행하고 파일을 고칩니다. "
            + (provider == .codex ? codexOutsideSandbox + " " : "")
            + "실행 중이면 지금 떠 있는 승인도 허용됩니다."
    }

    /// 설정 "새 대화는 자동 승인으로 시작" 을 켜기 전의 확인 글 — 입력창 승인 칩의 확인(`autoApprovalConfirmation`)과 같은 말로.
    /// Claude · Codex 를 함께 켜므로 Codex 의 샌드박스 밖 실행을 늘 적는다.
    static let newThreadAutoApprovalConfirmation =
        "새로 만드는 대화의 에이전트가 묻지 않고 명령을 실행하고 파일을 고칩니다. " + codexOutsideSandbox + " "
            + "이미 있는 대화는 그대로입니다."

    private static let codexOutsideSandbox = "Codex 가 샌드박스 밖에서 실행하려는 명령(인터넷 접속 · 폴더 밖 수정)도 허용합니다."

    /// 자동 승인을 끈 대화에서 이 제공자가 실제로 묻는 방식.
    static func policy(provider: AgentProvider, claudePermissionMode: String,
                       codexApprovalPolicy: String, codexSandboxMode: String) -> ApprovalPolicyText {
        switch provider {
        case .claude:
            switch claudePermissionMode {
            case "manual", "default":
                return .init(title: "승인 묻기",
                             detail: "파일 편집 · 명령을 실행하기 전에 묻습니다. 읽기 도구 · 읽기 전용 명령과 Claude 설정에 허용해 둔 규칙은 묻지 않습니다.",
                             systemImage: "hand.raised")
            case "acceptEdits":
                // Claude Code 의 acceptEdits 는 작업 폴더 안의 파일 명령(mkdir · touch · rm · rmdir · mv · cp · sed)도 묻지 않는다.
                return .init(title: "편집은 자동",
                             detail: "파일 편집과 대화의 폴더 안의 파일 명령(mkdir · rm · mv · cp · sed 등)은 묻지 않고, 그 밖의 명령은 실행하기 전에 묻습니다.",
                             systemImage: "hand.raised", caution: true)
            case "plan":
                // 앱의 보통 턴(`--permission-prompt-tool stdio`)에서 계획 뒤 실행으로 넘어가는지는 실측하지 않았다 — 확인한 것만 적는다
                // (docs/CLI프로토콜.md: 프로젝트 쓰기는 막고 `~/.claude/plans` 에 계획 파일을 쓴다). 턴마다 `--permission-mode plan` 이라
                // 다음 메시지도 계획 모드다 (`ClaudeAdapter.arguments`).
                return .init(title: "계획만", detail: planDetail, systemImage: "hand.raised")
            default:
                return cliDefault
            }
        case .codex:
            switch (codexSandboxMode, codexApprovalPolicy) {
            case ("read-only", "never"):
                return .init(title: "읽기만",
                             detail: "Codex 는 파일을 바꾸지 못합니다 (읽기 전용 샌드박스 · 승인을 요청하지 않음).",
                             systemImage: "lock")
            case ("read-only", "on-request"), ("read-only", "untrusted"):
                // 읽기 전용 샌드박스라도 승인을 받으면 샌드박스 밖에서 실행한다 — "못 바꾼다"고 단정하지 않는다.
                return .init(title: "읽기만 · 바꾸려면 묻기",
                             detail: "샌드박스는 읽기 전용입니다. 파일을 바꾸거나 샌드박스 밖에서 실행하려면 승인을 요청하고, 허용하면 실행합니다.",
                             systemImage: "lock")
            case ("danger-full-access", "never"):
                return .init(title: "묻지 않음 · 전체 접근",
                             detail: "Codex 가 승인을 묻지 않고 샌드박스 없이 실행합니다.",
                             systemImage: "exclamationmark.shield", caution: true)
            case ("danger-full-access", "untrusted"):
                return .init(title: "전체 접근 · 승인 묻기",
                             detail: "샌드박스 없이 실행합니다. 읽기처럼 안전한 명령 외에는 실행하기 전에 묻습니다.",
                             systemImage: "exclamationmark.shield", caution: true)
            case ("danger-full-access", "on-request"):
                return .init(title: "전체 접근",
                             detail: "샌드박스 없이 실행합니다. Codex 가 필요하다고 판단할 때만 승인을 묻습니다.",
                             systemImage: "exclamationmark.shield", caution: true)
            case ("workspace-write", "never"):
                return .init(title: "묻지 않음",
                             detail: "대화의 폴더 안의 편집 · 명령을 묻지 않고 실행합니다. 샌드박스 밖으로는 나가지 못합니다.",
                             systemImage: "hand.raised.slash")
            case ("workspace-write", "on-request"):
                // 이 샌드박스는 Codex 기본으로 네트워크를 막는다 (config.toml 의 `sandbox_workspace_write.network_access` — 앱에서 실측하지
                // 않았다). 그래서 패키지 설치 · git push 같은 일은 실패하거나 승인 요청이 된다 — "묻지 않고" 만 적으면 그것을 몰랐다 (set-12).
                return .init(title: "폴더 안은 자동", detail: folderDetail, systemImage: "hand.raised")
            case ("workspace-write", "untrusted"):
                return .init(title: "승인 묻기",
                             detail: "읽기처럼 안전한 명령은 바로 실행하고, 그 밖의 명령은 실행하기 전에 묻습니다.",
                             systemImage: "hand.raised")
            default:
                return cliDefault
            }
        case .gemini:
            return .init(title: "묻지 않음",
                         detail: "Antigravity 는 승인을 묻지 않고 파일을 고치고 명령을 실행합니다.",
                         systemImage: "hand.raised.slash", caution: true)
        }
    }

    private static let cliDefault = ApprovalPolicyText(
        title: "CLI 설정대로", detail: "이 에이전트의 CLI 설정대로 승인을 묻습니다.", systemImage: "hand.raised")

    private static let planDetail: String = [
        "프로젝트 파일을 바꾸지 않고 계획만 세웁니다 (계획은 ~/.claude/plans 에 남습니다).",
        "다음 메시지도 계획 모드로 시작하니, 실행을 맡기려면 ‘승인 묻기’로 되돌리세요.",
    ].joined(separator: " ")

    private static let folderDetail: String = [
        "대화의 폴더 안에서 하는 편집 · 명령은 묻지 않고 실행합니다.",
        "네트워크(패키지 설치 · git push 등)처럼 샌드박스를 벗어나야 하는 일은 Codex 가 판단해 승인을 요청합니다.",
    ].joined(separator: " ")
}

// MARK: - 설정 > 에이전트의 승인 선택지

/// Claude 의 승인 선택지 — 저장값(`claude_permission_mode`)이 곧 선택지다. 제목은 입력창 칩과 같은 말(`ApprovalPolicyText`).
enum ClaudeApprovalPreset: String, CaseIterable, Identifiable, Sendable {
    case manual, acceptEdits, plan

    var id: String { rawValue }
    /// 앱 기본값 (`AppModel.claudePermissionMode`).
    static let standard = ClaudeApprovalPreset.manual

    /// 설정의 세그먼트에 두는 선택지 — 기본값이 맨 앞. "계획만" 은 빼고 "자세히" 안에 실험으로 둔다 (`isExperimental`).
    static var mainChoices: [ClaudeApprovalPreset] { allCases.filter { !$0.isExperimental } }

    /// 앱에서 확인하지 않은 방식 (set-7). "계획만"(`--permission-mode plan`)은 헤드리스에서 계획 뒤 실행으로 넘어가는지 실측하지 않았고,
    /// 모든 대화의 모든 메시지에 적용된다 — 안전해 보여 맨 앞에서 고르기 쉬웠다.
    var isExperimental: Bool { self == .plan }

    /// "계획만" 을 켜는 줄의 설명 — 확인한 사실과 확인하지 않은 것을 나눠 적는다.
    static let planNote: String = [
        "앱에서 아직 확인하지 않은 방식입니다.",
        "프로젝트 파일은 바꾸지 않지만, 계획을 마친 뒤 이어서 실행하는지는 확인하지 못했습니다.",
        "모든 대화의 모든 메시지에 적용됩니다.",
    ].joined(separator: " ")

    /// 저장값 → 선택지. 옛 값 "default" 는 manual 이다. 모르는 값이면 nil — 화면은 아무것도 고르지 않은 채 그 정책의 문구를 보인다.
    static func matching(_ mode: String) -> ClaudeApprovalPreset? {
        mode == "default" ? .manual : ClaudeApprovalPreset(rawValue: mode)
    }

    var title: String {
        ApprovalPolicyText.policy(provider: .claude, claudePermissionMode: rawValue,
                                  codexApprovalPolicy: "", codexSandboxMode: "").title
    }
}

/// Codex 의 승인 선택지 — 샌드박스 × 승인 정책의 아홉 조합 가운데 넷. 나머지 조합은 설정의 "자세히"(CLI 값)로만 고르고,
/// 그때는 어느 선택지도 고르지 않은 것으로 보인다 (`matching` 이 nil — 화면은 "직접 설정").
enum CodexApprovalPreset: String, CaseIterable, Identifiable, Sendable {
    case readOnly, ask, folder, fullAccess

    var id: String { rawValue }
    /// 앱 기본값 (`AppModel.codexSandboxMode` · `codexApprovalPolicy`).
    static let standard = CodexApprovalPreset.folder

    var sandbox: String {
        switch self {
        case .readOnly: return "read-only"
        case .ask, .folder: return "workspace-write"
        case .fullAccess: return "danger-full-access"
        }
    }

    var approvalPolicy: String {
        switch self {
        case .readOnly, .fullAccess: return "never"
        case .ask: return "untrusted"
        case .folder: return "on-request"
        }
    }

    /// 세그먼트의 짧은 이름. 앞의 셋은 입력창 칩의 제목과 같고, 전체 접근의 칩 제목은 "묻지 않음 · 전체 접근" 이다.
    var title: String {
        switch self {
        case .readOnly: return "읽기만"
        case .ask: return "승인 묻기"
        case .folder: return "폴더 안은 자동"
        case .fullAccess: return "전체 접근"
        }
    }

    static func matching(sandbox: String, approvalPolicy: String) -> CodexApprovalPreset? {
        allCases.first { $0.sandbox == sandbox && $0.approvalPolicy == approvalPolicy }
    }

    /// 샌드박스를 전체 접근으로 넓히는 바꿈인가 — 설정 화면이 한 번 더 확인받는다 (선택지로 고르든 CLI 값으로 고르든).
    static func needsConfirmation(fromSandbox: String, toSandbox: String) -> Bool {
        toSandbox == "danger-full-access" && fromSandbox != "danger-full-access"
    }

    /// 전체 접근으로 넓힐 때의 확인 글 — 고르려는 조합의 실제 정책(`ApprovalPolicyText`)대로 쓴다. "자세히" 에서 샌드박스만 바꾸면
    /// 승인은 그대로 묻는데도 늘 "승인을 묻지 않고" 라고 적었다 (set-11).
    static func confirmationText(sandbox: String, approvalPolicy: String) -> String {
        let policy: ApprovalPolicyText = ApprovalPolicyText.policy(provider: .codex, claudePermissionMode: "",
                                                                   codexApprovalPolicy: approvalPolicy, codexSandboxMode: sandbox)
        let parts: [String] = [
            policy.detail,
            "이 Mac 의 어느 파일에나 닿을 수 있어 파일이 지워지거나 비밀값이 밖으로 나갈 수 있습니다.",
            "다음에 보내는 메시지부터 적용됩니다.",
        ]
        return parts.joined(separator: " ")
    }
}
