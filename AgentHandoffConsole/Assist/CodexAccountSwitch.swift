import Foundation

/// Codex 계정끼리 바꾸기 — 대화의 Codex 세션을 **그대로** 다른 계정의 인증으로 이어 간다. 인계가 아니다: 받는 쪽도 그 대화의 Codex 이고
/// 같은 CLI 세션을 재개하며(`RunSession.send` → `CodexRunHome`) 인계 문서가 없다. 순수 판정과 글 — 앱 쪽은 `App/AppModel+CodexSwitch.swift`.
///
/// 입구: 입력창 칩 메뉴의 다른 Codex 계정 행(칩만 바꾼다 — 다음 메시지부터, `ContinueChoice.Action.switchAccount`), 한도 도달 줄의
/// 받는 쪽이 다른 Codex 계정이면 [… 에서 이어 가기](바꾸고 이어 가기 메시지를 보낸다), 한도 임박 제안 줄이면 같은 단추(바꾸기만 — 대화가
/// 멈추지 않았다), 자동 인계가 다른 Codex 계정을 고르면 카운트다운 뒤 바꾸고 이어 간다 (`Countdown`). Codex 계정끼리는 인계 카드를
/// 만들지 않는다 (`notHandoff`).
enum CodexAccountSwitch {
    /// 같은 Codex 의 다른 계정인가 — 인계 대신 계정 바꾸기. 두 쪽 모두 등록된 계정 ID 로 맞춘 값을 넘긴다 (`AppModel.normalizedHandoffAgent`).
    static func isSwitch(from source: HandoffSource.Agent, to target: HandoffSource.Agent) -> Bool {
        source.provider == .codex && target.provider == .codex && source.codexAccountID != target.codexAccountID
    }

    /// 이어 가기 메시지 — 같은 세션이 재개되므로 앞의 요청과 한도로 멈춘 자리를 CLI 세션이 안다 (API 크레딧 이어 가기와 같은 글).
    static let prompt = ClaudeAPIContinue.prompt

    /// 단추 — "Codex · 계정 2 에서 이어 가기" (이름 뒤 조사는 받침과 무관한 꼴).
    static func title(name: String) -> String { "\(name) 에서 이어 가기" }

    // MARK: 칩 메뉴

    /// 칩 메뉴 행 아래 작은 글.
    static let rowSubtitle = "같은 세션을 이 계정으로 이어 갑니다 — 인계하지 않습니다"
    /// 칩 메뉴 행의 도움말.
    static func rowHelp(name: String) -> String {
        "다음 메시지부터 \(name) 에서 실행합니다. 이 대화의 Codex 세션을 그대로 이어 가므로 지금까지의 대화를 압니다 — 인계 문서를 "
            + "만들지 않습니다."
    }

    /// Codex 계정끼리는 인계하지 않는다 — 카드의 받는 쪽 바꾸기 · 인계 준비가 이 까닭으로 막는다.
    static let notHandoff = ContinueChoice.Unavailable(
        meta: "계정만 바꾸면 됨",
        help: "Codex 계정끼리는 인계하지 않습니다 — 입력창의 에이전트 칩에서 계정을 바꾸면 이 대화의 Codex 세션을 그대로 이어 갑니다")
    static let notHandoffText = "Codex 계정끼리는 인계하지 않습니다 — 입력창의 에이전트 칩에서 계정을 바꾸면 이 대화의 Codex 세션을 그대로 "
        + "이어 갑니다."

    // MARK: 계정을 바꾼 뒤의 안내 (입력창 위)

    /// 칩에서 계정을 바꾼 뒤. `carries` — 이 대화에 이어 갈 Codex 세션이 있다.
    static func switchedNote(from previous: String, to next: String, carries: Bool) -> String {
        carries
            ? "Codex 계정을 바꿨습니다: \(previous) → \(next). 이 대화의 Codex 세션을 그대로 이어 갑니다 — 다음 메시지부터 \(next) 에서 실행합니다."
            : "Codex 계정을 바꿨습니다: \(previous) → \(next). 다음 메시지부터 \(next) 에서 실행합니다."
    }

    // MARK: 한도 줄 · 제안 줄

    /// 한도 도달 줄의 권유 문장. `confirmed` — 받는 계정의 로그인 · 한도 여유가 30분 안에 확인됐다.
    static func limitAdvice(name: String, confirmed: Bool, loginUnknown: Bool) -> String {
        if !confirmed { return "\(name) 에서 같은 세션을 이어 가 볼 수 있습니다 (받는 계정 상태 미확인)." }
        if loginUnknown { return "\(name) 에서 같은 세션을 이어 갈 수 있습니다 (로그인 미확인)." }
        return "\(name) 에서 같은 세션을 이어 갈 수 있습니다."
    }

    /// 한도 줄의 단추 도움말.
    static func limitHelp(name: String) -> String {
        "다음 메시지부터 \(name) 에서 실행하고, 같은 Codex 세션에 이어서 하라고 보냅니다 — 인계하지 않습니다."
    }

    /// 제안 줄의 단추 도움말 — 대화가 멈추지 않았으므로 바꾸기만 한다.
    static func suggestionHelp(name: String, loginUnknown: Bool) -> String {
        let base = "다음 메시지부터 \(name) 에서 실행합니다. 이 대화의 Codex 세션을 그대로 이어 갑니다 — 인계 문서를 만들지 않습니다."
        return loginUnknown ? base + " 받는 계정의 로그인은 확인하지 못했습니다." : base
    }

    // MARK: 자동 (카운트다운)

    /// 자동 인계가 다른 Codex 계정을 골랐다 — 인계 카드 대신 이 카운트다운. 울리면 칩을 그 계정으로 바꾸고 이어 가기 메시지를 보낸다.
    struct Countdown: Equatable, Sendable {
        var id = UUID().uuidString
        /// 한도에 닿은 쪽 (Codex · 계정).
        var source: HandoffSource.Agent
        /// 이어 갈 계정.
        var target: HandoffSource.Agent
        /// 한도에 닿은 실행 — 울릴 때 그 뒤에 다른 실행이 있었으면(사람이 먼저 보냈다) 이어 가지 않는다.
        var limitRunID: String
        var limitRunStartedAt: Date
        var deadline: Date
        var delay: Int
    }

    /// 카운트다운 줄의 글 — "Codex · 기본 계정 사용 한도 도달 — 10초 뒤 Codex · 계정 2 에서 같은 세션을 이어 갑니다" 의 앞뒤 (초는 레이어 시계).
    static func countdownLead(source: String) -> String { "\(source) 사용 한도 도달 —" }
    static func countdownTail(target: String) -> String { "뒤 \(target) 에서 같은 세션을 이어 갑니다" }
    /// 현황 행의 초를 센 한 줄 — "9초 뒤 Codex · 계정 2 에서 같은 세션을 이어 갑니다" (초는 레이어 시계가 바꾼다).
    static func countdownText(seconds: Int, target: String) -> String { "\(seconds)초 " + countdownTail(target: target) }
    /// 현황 행의 첫 줄.
    static func reachedText(source: String) -> String { "\(source) 의 사용 한도에 닿았습니다." }

    // 입력창 위 줄 밖에서 — 인계 카드의 자동 인계 카운트다운이 보이는 곳에 같은 무게로 보인다: 칸 머리 · 사이드바 행
    // (`PaneStatusInput.codexSwitchCountdown`), 현황(`Overview.Kind.codexSwitch`), Dock 배지 · 메뉴바(`AppModel.dockAttentionThreadIDs`),
    // 앱 종료 확인(`QuitConfirmation.Facts.codexSwitches`). 글은 "인계" 가 아니라 같은 세션을 다른 계정에서 이어 간다는 것.

    /// 칸 머리 · 사이드바 행 · 현황 행의 상태 ("자동 인계 대기" 자리).
    static let waitingText = "다른 계정에서 이어 가기 대기"
    /// 좁은 칸 머리의 짧은 글 ("인계" 자리).
    static let waitingShortText = "계정 바꿈"
    /// 칸 머리 · 사이드바 행의 도움말 — 분할하지 않은 화면에도 맞는 말로 (줄은 그 대화의 입력창 위에 있다).
    static let waitingHelp = "잠시 뒤 이 대화의 Codex 세션을 다른 계정에서 그대로 이어 갑니다 (인계하지 않습니다) — "
        + "입력창 위 줄에서 취소하거나 지금 이어 갈 수 있습니다"
    /// 사이드바 행의 카운트다운 배지 — "계정 9초" (자동 인계는 "⇄ 9초" — 인계의 기호를 쓰지 않는다).
    static func badgeText(seconds: Int) -> String { "계정 \(seconds)초" }
    /// 알림 제목.
    static func countdownTitle(seconds: Int, target: String) -> String { "\(seconds)초 뒤 \(target) 에서 이어 갑니다" }
    static let continueNowTitle = "지금 이어 가기"
    static let cancelTitle = "취소"
    static let cancelHelp = "자동으로 이어 가지 않습니다 — 한도 줄이나 입력창의 에이전트 칩에서 직접 고를 수 있습니다"
    /// 자동으로 이어 가지 못했을 때(받는 계정이 확인되지 않음 · 그 사이 사람이 보냄)의 안내 — 이유는 따로 붙인다.
    static func skippedNote(target: String, reasons: [String]) -> String {
        reasons.isEmpty ? "\(target) 에서 자동으로 이어 가지 않았습니다."
                        : "\(target) 에서 자동으로 이어 가지 않았습니다 — \(reasons.joined(separator: " "))"
    }
}
