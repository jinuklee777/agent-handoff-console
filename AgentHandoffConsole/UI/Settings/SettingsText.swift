import Foundation

// 설정 창의 글 가운데 판정이 섞인 것 — 순수 (SwiftUI 없이 — 검증 하네스가 컴파일한다). 화면은 같은 폴더의 탭 파일들.

/// CLI 버전 원문을 짧게: "2.1.283 (Claude Code)" → "v2.1.283", "codex-cli 0.157.1" → "v0.157.1".
/// 카드 머리에 이름(Claude Code)이 이미 있어, 원문을 그대로 두면 이름이 두 번 보였다 (set-23).
enum AgentVersionText {
    static func short(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        // 숫자.숫자(.숫자…) 와 그 뒤에 붙은 -beta · +build 같은 꼬리.
        if let range = raw.range(of: #"\d+(\.\d+)+([-+][0-9A-Za-z.-]+)?"#, options: .regularExpression) {
            return "v" + String(raw[range])
        }
        return raw
    }
}

/// 설정 > 에이전트의 "실행 파일" 줄 — 펼침 머리의 요약과 펼친 칸의 상태 한 줄.
enum ExecutablePathText {
    /// 머리의 요약. 다시 확인하는 동안은 옛 결과를 새 경로와 섞어 보이지 않는다 (set-1 — 맞는 파일을 골라도 "실행할 수 없음",
    /// 틀린 경로에도 옛 경로가 "· 직접 지정" 으로 붙어 보였다).
    static func summary(status: CLIStatus?, override: String, checking: Bool) -> String {
        if checking { return "확인 중" }
        guard let status else { return "확인 전" }
        let custom: Bool = !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 찾았는데 돌지 않는 파일(지정한 경로 · 자동으로 찾은 파일 모두)은 "실행할 수 없음", 어디서도 찾지 못했으면 "찾지 못함".
        guard status.isUsable, let resolved = status.resolvedPath else {
            return custom || status.resolvedPath != nil ? "실행할 수 없음" : "찾지 못함"
        }
        let shown: String = (resolved as NSString).abbreviatingWithTildeInPath
        let source: String = custom ? "직접 지정" : "자동으로 찾음"
        return shown + " · " + source
    }

    /// 펼친 칸의 상태 한 줄 — 경로 · 버전 · 오류.
    static func statusLine(_ status: CLIStatus?, checking: Bool) -> String {
        if checking { return "확인 중…" }
        guard let status else { return "확인 전" }
        if let error = status.error, status.resolvedPath == nil { return error }
        var line: String = status.resolvedPath ?? "경로 미확인"
        if let version = status.version { line += " · " + version }
        if let error = status.error { line += " · " + error }
        return line
    }

    /// 칸에 적은 경로를 저장할 값으로 — 앞뒤 공백을 떼고 `~` 를 푼다 (`~` 를 그대로 두면 실행 파일을 찾지 못했다).
    static func normalized(_ typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return (trimmed as NSString).expandingTildeInPath
    }
}

/// 실행 파일 칸의 편집 상태 — 칸의 글(`draft`)과 그 글을 마지막으로 맞춘 경로(`synced`). 편집이 끝날 때(↵ · 칸을 떠남 · [찾기…] ·
/// 탭을 닫음 · 그 에이전트의 다시 확인이 시작됨) **사람이 칸의 글을 고쳤을 때만** 경로를 바꾼다.
///
/// set-n1: 예전에는 편집이 끝날 때마다 칸의 글을 다시 써 넣었다. macOS 에서는 ↵ 뒤에도 칸이 포커스를 갖고 단추를 눌러도 포커스가 옮지
/// 않아, [자동으로 찾기로 되돌리기] 가 경로를 비운 뒤에도 칸에는 틀린 경로가 남았고, 칸을 떠나거나 창을 닫으면 그 경로가 다시 저장됐다.
/// 밖에서 경로가 바뀌면(되돌리기) 칸이 늘 따라간다 — 치던 글이 있어도 사람이 누른 단추가 이긴다.
struct ExecutablePathField: Equatable {
    /// 칸에 보이는 글.
    var draft: String
    /// 칸의 글을 마지막으로 맞춘 경로 (설정에 저장된 값과 같다).
    private(set) var synced: String

    init(path: String = "") {
        draft = path
        synced = path
    }

    /// 사람이 칸의 글을 고쳤는가 (앞뒤 공백 · `~` 는 고친 것으로 보지 않는다).
    var isEdited: Bool { ExecutablePathText.normalized(draft) != ExecutablePathText.normalized(synced) }

    /// 밖에서 경로가 바뀌었다 ([자동으로 찾기로 되돌리기] · 다른 창) — 칸도 그 값으로.
    mutating func pathChanged(to path: String) {
        guard path != synced else { return }
        draft = path
        synced = path
    }

    /// 편집이 끝났다: 고친 글이 있으면 저장할 경로(다듬은 값)를 돌려주고, 없으면 nil — 칸에 남은 옛 글로 경로를 다시 쓰지 않는다.
    /// `current` 는 지금 저장된 경로 — 밖에서 바뀐 값을 칸이 아직 받지 못했으면(되돌리기와 같은 화면 갱신에서 불렸다 — 되돌리기도 다시
    /// 확인을 시작한다) 그 값이 이긴다: 칸을 그 값으로 맞추고 nil.
    mutating func commit(current: String) -> String? {
        guard current == synced else {
            pathChanged(to: current)
            return nil
        }
        guard isEdited else {
            draft = synced   // 공백만 덧붙였으면 칸을 저장된 값으로
            return nil
        }
        let value = ExecutablePathText.normalized(draft)
        draft = value
        synced = value
        return value
    }
}

/// 설정 > 일반 · 고급 · 에이전트의 고정 글 가운데 실제 동작을 말하는 것 (시험이 동작과 함께 본다).
/// 긴 글은 문장마다 줄을 나눠 배열로 잇는다 — `+` 로 여러 리터럴을 이으면 컴파일러의 타입 추론이 무거워진다.
enum SettingsText {
    /// "알림 받기" 의 설명 — 앱이 앞에 있고 그 대화가 화면(메인 창의 칸)에 보이면 알리지 않는다 (`NotificationGate.decide` 의 `.onScreen`,
    /// 점검표 ② 와 같은 사실). 예전 설명은 이 규칙을 말하지 않아, 화면을 보며 기다린 사람은 알림이 고장 났다고 여겼다 (set-n10).
    static let notificationsNote: String = [
        "실행이 끝났을 때, 승인이 필요할 때, 사용 한도에 닿았을 때 알려 줍니다.",
        "앱이 앞에 있고 그 대화가 화면에 보이면 알리지 않습니다.",
    ].joined(separator: " ")

    /// "Mac 에 로그인하면 열기" — 앱은 로그인 항목에 스스로 넣지 않는다. 단추는 시스템 설정을 열기만 한다 (set-3 · txt-13).
    static let loginItemsNote: String = "시스템 설정의 로그인 항목을 엽니다. ‘로그인 시 열기’ 목록의 ＋ 를 눌러 이 앱을 추가하세요."

    /// 메뉴바에 보일 한도 (`AppModel.menuBarHiddenLimits` · `MenuBarLimits`) — 숨겨도 그대로인 것을 함께.
    static let menuBarLimitsNote: String = [
        "끈 계정 · 구간은 메뉴바 팝오버에서만 숨깁니다. 툴바의 한도 칩과, 한도에 닿았을 때 메뉴바의 ‘확인 필요’ 는 그대로입니다.",
        "구간(5시간 · 7일 등)은 한도를 한 번 읽은 뒤에 여기 나타나고, 새로 생긴 계정 · 구간은 처음엔 보입니다.",
    ].joined(separator: " ")

    /// 대화 제목 자동 요약 (`AppModel.autoThreadTitles` · `ThreadTitle`) — 무엇을 어디로 보내는지 그대로.
    static let autoTitlesTitle: String = "대화 제목 자동 요약"
    static let autoTitlesNote: String = [
        "새 대화의 첫 답이 끝나면 그 대화의 에이전트에게 짧은 제목을 한 번 묻습니다 (Claude 는 Haiku, Codex 는 가장 작은 모델).",
        "첫 메시지와 첫 답의 앞부분만 보내고, 사용 한도를 조금 씁니다.",
        "직접 바꾼 이름은 그대로 둡니다.",
    ].joined(separator: " ")

    /// 가장 높은 추론 강도(MAX · ULTRA)를 고를 때의 효과음 (예전 이름 "MAX · ULTRA 효과음" — 무엇인지 알 수 없었다, H14).
    static let effortSoundTitle: String = "가장 높은 추론 강도를 고를 때 효과음"
    static let effortSoundNote: String = [
        "입력창의 모델 선택에서 추론 강도를 MAX 나 ULTRA(가장 깊이 생각하는 단계)로 올리면 짧은 소리를 냅니다.",
        "화면의 연출은 시스템 설정의 ‘동작 줄이기’를 따릅니다.",
    ].joined(separator: " ")

    /// 독립 작업 폴더를 두는 곳의 설명 (set-17).
    static let worktreeLocationNote: String = [
        "독립 작업 폴더는 대화마다 따로 쓰는 git worktree 입니다. 같은 프로젝트의 여러 대화가 서로의 파일을 덮지 않습니다.",
        "위치를 바꾸면 새로 만드는 독립 작업 폴더부터 그곳에 만들고, 이미 있는 것은 옮기지 않습니다.",
        "정리하지 않은 독립 작업 폴더는 디스크를 차지합니다 — 다 쓴 대화는 변경사항 탭에서 정리하세요.",
        "만든 뒤 실행할 준비 명령은 프로젝트 설정(사이드바의 프로젝트 메뉴)에서 정합니다.",
    ].joined(separator: " ")

    /// 고른 위치에 만들면 프로젝트 저장소 안에 생긴다 — 받지 않은 까닭 (ws-2).
    static func worktreeLocationConflict(chosen: String, project: String) -> String {
        "\(chosen) 에 두면 프로젝트 \(project) 의 독립 작업 폴더가 그 저장소 안에 생겨 커밋에 섞입니다. 저장소 밖의 폴더를 고르세요 — 위치는 바꾸지 않았습니다."
    }

    /// 설정 > 에이전트 맨 위의 한 줄.
    static let agentsIntro: String = [
        "이 Mac 에 설치된 에이전트 CLI 를 확인해 상태를 보입니다.",
        "설치하거나 로그인한 뒤에는 카드의 ↻ 로 그 에이전트만 다시 확인합니다.",
    ].joined(separator: " ")

    /// Codex 승인의 "자세히" 설명 — 앱은 config.toml 의 값 대신 이 값을 넘긴다 (set-12).
    static let codexRawApprovalNote: String = [
        "codex 의 --sandbox · --ask-for-approval 값과 같습니다 — 앱은 config.toml 의 sandbox_mode · approval_policy 대신 이 값을 넘깁니다.",
        "위 네 가지에 없는 조합이면 ‘직접 설정’으로 보입니다.",
        "앱은 Codex 자체의 권한 · 샌드박스 정책을 우회하거나 끄지 않습니다.",
    ].joined(separator: " ")

    /// 기본 추론 강도의 설명 — 새로 정하는 대화(이어받을 대화가 없는 새 대화 · 처음 쓰는 에이전트)에만 쓰이고, 이미 쓴 대화는 이 값을
    /// 바꿔도 그대로다: 강도는 대화를 만들 때 · 처음 보낼 때 그 대화에 정해 두고, 설정을 바꾸기 전에 강도가 빈 옛 대화도 정해 둔다
    /// (`AppModel.pinEffectiveSelection` · `setDefaultEffort`). set-n2: 예전 설명은 "처음 쓸 때만" 이었는데 실제로는 강도를 고르지 않은
    /// 모든 대화(열린 대화 포함)가 따라가, MAX 로 바꾸면 열린 대화가 모르는 사이 MAX 로 보냈다.
    static func defaultEffortNote(provider: AgentProvider) -> String {
        var lines: [String] = ["높을수록 깊이 생각하지만 느려지고 사용 한도를 더 씁니다."]
        if provider == .codex {
            lines.append("‘모델 기본값’은 Codex 설정 파일(config.toml)에 적어 둔 강도를, 없으면 모델마다 정해진 강도를 씁니다.")
            lines.append("고른 강도를 그 모델이 받지 않으면 같은 차례로 다음 값을 씁니다.")
        }
        lines.append("새 대화는 마지막에 쓴 대화의 모델 · 강도를 이어받고, 이어받을 대화가 없을 때만 이 값으로 시작합니다.")
        lines.append("이미 쓴 대화는 이 값을 바꿔도 그대로입니다 — 대화마다 입력창의 모델에서 바꿉니다.")
        return lines.joined(separator: " ")
    }

    /// Antigravity 가 설치되지 않았을 때 — agy 는 인계 문서를 Gemini 로 다듬을 때도 쓴다 (설정 > 인계가 이 카드로 보낸다, set-14).
    static let antigravityMissingNote: String = [
        "Antigravity CLI(agy)는 가벼운 작업을 Antigravity 에게 맡기거나 인계 문서를 Gemini 로 다듬을 때만 필요합니다.",
        "설치한 뒤 위의 ↻ 를 누르세요. 이미 설치했다면 아래 ‘실행 파일’에서 위치를 지정합니다.",
    ].joined(separator: " ")

    /// Codex 계정 추가 시트의 설명 — 앱은 없는 폴더만 700 으로 만들고, 있는 폴더의 권한은 바꾸지 않는다 (set-13).
    static let codexAccountAddNote: String = [
        "계정 하나는 CODEX_HOME 폴더 하나입니다.",
        "없는 폴더를 적으면 앱이 그 폴더를 만들고(나만 읽고 쓸 수 있게 — 권한 700), 이미 있는 폴더는 권한을 바꾸지 않고 그대로 씁니다.",
        "등록한 뒤 보이는 로그인 명령을 터미널에서 실행하면 그 폴더에 로그인됩니다. 이미 로그인해 둔 폴더를 그대로 등록해도 됩니다.",
    ].joined(separator: " ")

    /// 설정 > 에이전트 > Claude Code 의 API 키 (Max · Team 플랜의 월 API 크레딧 — `ClaudeAPIKey`).
    static let claudeAPIKeyTitle: String = "API 키 (월 API 크레딧)"

    /// 그 줄의 설명 — 키를 어디서 얻고, 어느 실행에 쓰는지.
    static let claudeAPIKeyNote: String = [
        "Max · Team 플랜의 월 API 크레딧을 쓰려면 claude.ai > 설정 > 결제에서 Claude Console 조직을 연결하고 그 조직에서 만든 키를 넣으세요.",
        "모델 칩에서 ‘\(ClaudeAPIKey.toggleTitle)’ 을 켠 대화에만 씁니다.",
    ].joined(separator: " ")

    /// 도움말 (?) — 키를 두는 곳 · 넣는 곳 · 크레딧이 떨어지면.
    static let claudeAPIKeyHelp: String = [
        "키는 이 Mac 의 키체인에만 두고, 켠 대화의 Claude 실행 환경에만 ANTHROPIC_API_KEY 로 넣습니다. 대화 기록 · 인계 문서 · 로그에는 남기지 않습니다.",
        "끈 대화와 터미널의 claude 는 지금처럼 구독 로그인으로 갑니다.",
        "크레딧이 떨어지면 구독으로 넘어가지 않고 요청이 멈추며, 남은 크레딧은 다음 달로 넘어가지 않습니다.",
        "키체인 허락을 물으면 ‘항상 허용’ 을 누르세요.",
    ].joined(separator: " ")

    /// 키를 지울 때의 확인 글.
    static let claudeAPIKeyDeleteConfirm: String =
        "키체인에서 Claude API 키를 지울까요? Claude Console 은 만든 키를 다시 보여 주지 않으니, 다시 쓰려면 새 키를 만들어야 합니다. 켜 둔 대화는 구독으로 보냅니다."

    /// 설정 > 에이전트의 "새 대화는 자동 승인으로 시작" (기본 꺼짐 — `AppModel.newThreadsAutoApprove`).
    static let newThreadAutoApprovalTitle = "새 대화는 자동 승인으로 시작"
    static let newThreadAutoApprovalNote = "켜면 새로 만드는 대화(Claude · Codex)의 승인 칩이 \"자동 승인\" 으로 시작합니다. 이미 있는 대화는 그대로입니다. "
        + "Codex 의 권한 요청 · MCP 입력 요청 · 에이전트의 질문은 여전히 묻고, 다른 회사의 에이전트로 바꾸거나 인계로 받는 에이전트가 바뀌면 꺼집니다."
    static let newThreadAutoApprovalConfirmTitle = "새 대화를 자동 승인으로 시작할까요?"

    /// 설정 > 에이전트의 "셸의 API 키 넘기기" (onb-19).
    static let shellAuthTitle: String = "셸의 API 키를 에이전트에게 넘기기"

    /// 그 줄의 설명 — 무엇을 넘기고, 넘기면 무엇이 달라지는지.
    static let shellAuthNote: String = [
        "셸 설정(~/.zshrc 등)의 \(CLIEnvironment.authVariableNames.joined(separator: " · ")) 를 Claude Code · Codex 에게 넘깁니다.",
        "넘기면 CLI 가 구독 로그인 대신 이 키를 써서 API 요금으로 청구됩니다.",
        "프록시 · Bedrock · Vertex 설정은 이 설정과 상관없이 넘깁니다.",
    ].joined(separator: " ")

    /// 지금 셸에 있는 인증 변수와 그것이 넘어가는지 (순수).
    static func shellAuthStatus(found: [String], forwarding: Bool) -> String {
        guard !found.isEmpty else { return "지금 셸 설정에는 이 변수가 없습니다." }
        let names: String = found.joined(separator: " · ")
        return forwarding ? "지금 넘기는 변수: \(names)" : "셸 설정에 \(names) 가 있지만 넘기지 않습니다."
    }

    /// 첫 실행 점검표 ① 아래의 한 줄 — 셸에 키가 있지만 넘기지 않는다 (순수, 넘기지 않는 것이 없으면 nil).
    static func withheldAuthNote(_ withheld: [String]) -> String? {
        guard !withheld.isEmpty else { return nil }
        return "셸 설정에 \(withheld.joined(separator: " · ")) 가 있지만 에이전트에게 넘기지 않습니다 — 넘기면 구독 로그인 대신 API 요금으로 청구됩니다. "
            + "API 키로 쓰려면 설정 > 에이전트에서 ‘\(shellAuthTitle)’ 를 켜세요."
    }

    /// 정보 탭 "이 Mac 밖으로 나가는 것" 의 CLI 줄 — 한도 · 모델 목록 확인도 CLI 가 한다 (set-20).
    static let privacyCLINote: String = [
        "설치된 각 CLI(Claude Code · Codex · Antigravity)가 자기 회사 서버와 주고받습니다.",
        "앱이 사용 한도 · 모델 목록을 확인할 때도 같습니다 — Antigravity 의 사용 한도는 프로젝트에서 허용했을 때만, "
            + "모델 목록은 그때나 인계 문서를 Gemini 로 다듬기로 골랐을 때만 확인합니다.",
    ].joined(separator: " ")
}
