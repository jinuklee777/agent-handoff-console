import Foundation

/// 앱 종료(⌘Q · 메뉴바 "앱 종료") 확인 창의 글 — 순수 판정 (검증 하네스가 컴파일한다). 창을 띄우고 단추를 읽는 일은
/// `AppDelegate.applicationShouldTerminate` 가 한다.
///
/// - 결과 위주로 쓴다: 무엇이 멈추고 무엇이 사라지고 무엇이 남는가. 문장마다 형식 하나 — 조각을 이어 붙이지 않는다.
/// - **기본 단추(Return)는 취소다.** 되돌릴 수 없는 쪽(멈추고 종료)은 두 번째 단추이고 파괴적 동작으로 표시한다.
struct QuitConfirmation: Equatable, Sendable {
    struct Facts: Equatable, Sendable {
        /// 도는 에이전트 실행 수 (대화들 + 자동 작업의 검토).
        var running = 0
        /// 메인 턴을 마치고 기다리는 실행들의 남은 백그라운드 작업 수.
        var background = 0
        /// 인계 카드(준비 중 포함) 수 · 그중 자동 인계 카운트다운.
        var cards = 0
        var countdowns = 0
        /// 자동으로 다른 Codex 계정에서 같은 세션을 이어 가려던 카운트다운 수 (`AppModel.codexSwitchCountdowns` — 인계 카드가 아니다).
        /// 확인창을 띄우기 전에 멈추므로(`suspendHandoffsForQuit`) 그 전에 센다 (`AppModel.quitFacts`). 종료를 취소해도 다시 걸지 않는다 —
        /// 한도 줄 · 입력창의 에이전트 칩에서 사람이 고른다.
        var codexSwitches = 0
        /// 터미널 탭에서 명령(자식 프로세스)이 도는 셸 수.
        var busyShells = 0
        /// ↵ 를 눌렀지만 아직 실행으로 시작되지 않은 메시지 수 (모델 목록 확인 · 시작 준비 — chr-9).
        var sending = 0
        /// 앱이 대신 돌리는 git · 독립 작업 폴더 명령 수 (원격 받기 · 업로드 · 합치기 · 준비 명령 …).
        var appCommands = 0
    }

    var title: String
    var lines: [String]
    var confirmTitle: String
    var cancelTitle = "취소"

    var informativeText: String { lines.joined(separator: "\n") }

    /// 물을 것이 없으면 nil — 곧바로 끝낸다.
    static func make(_ facts: Facts) -> QuitConfirmation? {
        // 다른 계정에서 이어 가려던 카운트다운만 있어도 묻는다 — 자동 인계 카운트다운(인계 카드)과 같은 무게. 끄면 그 일이 일어나지 않는다.
        guard facts.running > 0 || facts.cards > 0 || facts.codexSwitches > 0 || facts.busyShells > 0 || facts.sending > 0
                || facts.appCommands > 0
        else { return nil }
        var lines: [String] = []
        let title: String
        let confirm: String
        if facts.running > 0 {
            switch (facts.running > 1, facts.background > 0) {
            case (false, false): title = "실행 중인 에이전트를 멈추고 종료할까요?"
            case (true, false): title = "실행 중인 에이전트 \(facts.running)개를 멈추고 종료할까요?"
            case (false, true): title = "실행 중인 에이전트와 백그라운드 작업 \(facts.background)개를 멈추고 종료할까요?"
            case (true, true):
                title = "실행 중인 에이전트 \(facts.running)개와 백그라운드 작업 \(facts.background)개를 멈추고 종료할까요?"
            }
            confirm = "멈추고 종료"
            lines.append("에이전트 실행을 멈추고 앱이 띄운 CLI 프로세스를 정리한 뒤 종료합니다.")
            lines.append("정리하지 못한 프로세스가 남으면 끝내기 전에 한 번 더 묻습니다.")
        } else if facts.cards > 0 {
            title = facts.cards > 1 ? "넘기지 않은 인계 카드 \(facts.cards)개를 버리고 종료할까요?"
                                    : "넘기지 않은 인계 카드를 버리고 종료할까요?"
            confirm = "종료"
        } else if facts.codexSwitches > 0 {
            title = facts.codexSwitches > 1 ? "대화 \(facts.codexSwitches)개를 다른 계정에서 이어 가지 않고 종료할까요?"
                                            : "다른 계정에서 이어 가지 않고 종료할까요?"
            confirm = "종료"
        } else if facts.sending > 0 {
            title = "보내는 중인 메시지를 보내지 않고 종료할까요?"
            confirm = "종료"
        } else if facts.appCommands > 0 {
            title = "앱이 git 명령을 실행하고 있습니다. 종료할까요?"
            confirm = "종료"
        } else {
            title = "터미널 탭에서 명령이 돌고 있습니다. 종료할까요?"
            confirm = "종료"
        }
        if facts.sending > 0 {
            lines.append("아직 시작되지 않은 메시지는 보내지 않고 입력창에 되돌려 둡니다 — 다시 켜면 그대로 있습니다.")
        }
        if facts.appCommands > 0 {
            lines.append("앱이 실행 중인 git · 독립 작업 폴더 명령이 중간에 끊깁니다 — 다시 켠 뒤 변경사항 탭에서 저장소 상태를 확인하세요.")
        }
        if facts.cards > 0 {
            lines.append(facts.countdowns > 0
                ? "대화 끝의 인계 카드 \(facts.cards)개가 사라집니다 — 자동 인계 카운트다운 \(facts.countdowns)개는 멈춰 두었습니다."
                : "대화 끝의 인계 카드 \(facts.cards)개가 사라집니다 — 넘기지 않은 인계 문서는 남지 않습니다.")
            lines.append("걸어 둔 메시지는 다시 켜면 멈춘 채로 남습니다.")
        }
        if facts.codexSwitches > 0 {
            // 확인창보다 먼저 멈췄다 (`suspendHandoffsForQuit`) — 취소해도 다시 걸지 않는다.
            lines.append(facts.codexSwitches > 1
                ? "자동으로 다른 계정에서 같은 세션을 이어 가려던 카운트다운 \(facts.codexSwitches)개를 멈췄습니다 — "
                    + "한도 줄이나 입력창의 에이전트 칩에서 직접 이어 갈 수 있습니다."
                : "자동으로 다른 계정에서 같은 세션을 이어 가려던 카운트다운을 멈췄습니다 — "
                    + "한도 줄이나 입력창의 에이전트 칩에서 직접 이어 갈 수 있습니다.")
        }
        if facts.busyShells > 0 {
            lines.append(facts.busyShells > 1 ? "터미널 탭의 셸 \(facts.busyShells)개에서 도는 명령도 함께 끝납니다."
                                              : "터미널 탭의 셸에서 도는 명령도 함께 끝납니다.")
        }
        return QuitConfirmation(title: title, lines: lines, confirmTitle: confirm)
    }

    /// 실행을 거둔 뒤 정리를 확인하지 못했을 때의 두 번째 확인.
    static let cleanupUnconfirmed = QuitConfirmation(
        title: "앱이 띄운 프로세스가 남아 있을 수 있습니다",
        lines: ["에이전트 CLI 가 끝났는지 확인하지 못했습니다. 그 실행의 인계 기록은 '전달 여부 미확인' 으로 남겼습니다.",
                "그래도 종료할까요?"],
        confirmTitle: "그래도 종료")
}
