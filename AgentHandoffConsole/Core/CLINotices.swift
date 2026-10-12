import Foundation

// CLI 가 내는 안내의 두 갈래 — 대화에 보이지 않는 **진단**과 **사람이 할 일**. 어댑터가 `AgentEvent.diagnostic` · `.attention` 으로
// 내고, 실행기(`RunSession`)가 `.systemNotice` 로 저장하며 payload 에 표시를 단다 (스키마 변경 없음). 대화 스트림(`StreamBuilder`)은
// 진단을 빼고(턴 바닥글을 펼치면 보인다), 사람이 할 일은 실행 기록 블록 밖의 한 줄로 보인다. 인계 문서 · Gemini 입력도 진단을 쓰지
// 않는다. 턴마다 답 위에 CLI 명령줄 · MCP 준비 · 훅 출력이 쌓이던 것 (첫 사용자 시험 H4).

extension ThreadEvent {
    /// 진단 표시 (payload 의 키, 값 true): CLI 실행 명령줄 · app-server 시작 · 준비된 MCP 서버 · 모르는 CLI 이벤트 · stderr ·
    /// 성공한 훅의 출력.
    static let diagnosticKey = "ahc.diagnostic"
    /// 사람이 할 일 표시 (payload 의 키, 값 true): 훅 실패 · MCP 서버 인증 필요 · 연결 실패.
    static let attentionKey = "ahc.attention"
    static let diagnosticTitle = "진단"
    static let attentionTitle = "확인 필요"

    /// 표시를 달기 전(앱을 업데이트하기 전)의 기록에 같은 안내가 "안내" 로 남아 있다 — 그 글의 앞부분.
    static let legacyDiagnosticPrefixes: [String] = [
        "claude 실행: ", "claude stderr: ", "codex app-server 시작", "처리하지 않는 제어 요청: ", "처리하지 않는 Codex 요청: ",
        "Codex 알림: ", "알 수 없는 작업 이벤트: ", "MCP 서버 ", "훅: ", "중단 요청을 보냈습니다.",
    ]

    /// 대화에 보이지 않는 진단 행인가 — 표시가 있거나, 표시를 달기 전 기록의 같은 안내.
    var isDiagnostic: Bool {
        // 표시가 붙은 행은 종류와 관계없이 진단이다 (맨 위 키로만 — 도구 출력 안의 같은 글자는 세지 않는다).
        if let json = payloadJSON, json.contains("\"\(Self.diagnosticKey)\""),
           let flag = JSONUtil.object(json)?[Self.diagnosticKey], !(flag is NSNull), (flag as? Bool) != false {
            return true
        }
        guard kind == .systemNotice, title == "안내", runID != nil else { return false }
        return Self.legacyDiagnosticPrefixes.contains { text.hasPrefix($0) }
    }

    /// 사람이 할 일을 알리는 행인가.
    var isAttention: Bool {
        kind == .systemNotice && payloadJSON?.contains("\"\(Self.attentionKey)\"") == true
    }

    /// 진단 · 할 일 행의 payload — 표시 하나 (하위 에이전트 안의 것이면 부모 표시도).
    static func noticePayload(_ key: String, taggingParent parent: String? = nil) -> String {
        let marker: [String: Any] = [key: true]
        guard let parent else { return JSONUtil.string(marker) }
        return payload(marker, taggingParent: parent)
    }
}

/// 사람이 할 일이 있는 CLI 상태의 글 — 짧게, 무엇이 안 되는지와 어디서 푸는지. 이름을 넣는 글이라 이름 뒤에 조사를 두지 않는다.
enum CLINoticeText {
    /// Claude init 의 MCP 서버 목록 → 진단 한 줄. CLI 가 보고한 상태를 그대로 적는다 (이름만으로 정상이라 단정하지 않는다).
    static func mcpSummary(_ servers: [(name: String, status: String)]) -> String {
        var pairs: [String] = []
        for server in servers { pairs.append(server.name + "=" + server.status) }
        let list: String = pairs.joined(separator: ", ")
        return "MCP 서버 상태(CLI 보고): \(list)"
    }

    /// 인증이 필요해 도구를 쓸 수 없는 서버 (Claude `needs-auth`).
    static func mcpNeedsAuth(_ names: [String]) -> String {
        let list: String = names.joined(separator: ", ")
        return "MCP 서버 인증 필요: \(list) — 이 서버의 도구는 쓸 수 없습니다 (쓰려면 터미널의 claude 에서 /mcp)"
    }

    /// 연결하지 못한 서버. `detail` 은 CLI 가 준 오류 첫 줄.
    static func mcpFailed(_ names: [String], detail: String? = nil) -> String {
        let list: String = names.joined(separator: ", ")
        guard let detail else { return "MCP 서버 연결 실패: \(list)" }
        return "MCP 서버 연결 실패: \(list) — \(detail)"
    }

    /// 실패한 훅. `message` 는 훅이 남긴 글의 첫 줄 (없으면 종료 코드).
    static func hookFailed(name: String, event: String?, message: String?, exitCode: Int?) -> String {
        var what: String = "원인 미확인"
        if let message {
            what = message
        } else if let exitCode {
            what = "종료 코드 \(exitCode)"
        }
        var label: String = name
        if let event { label += " (\(event))" }
        return "훅 실패: \(label) — \(what)"
    }

    /// 여러 줄 글의 첫 줄 (공백을 다듬고 `max` 자까지). 비었으면 nil.
    static func firstLine(_ text: String?, max: Int = 200) -> String? {
        guard let text else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line: String = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.count <= max { return line }
            return String(line.prefix(max)) + "…"
        }
        return nil
    }
}
