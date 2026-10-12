import Foundation

// 입력창 · 보내기 · 대기열의 순수 판정과 글 (SwiftUI 없이 — 검증 하네스가 컴파일한다).
// 앱 쪽은 `AppModel.send` · `AppModel+Composer` · `UI/Composer.swift` · `UI/ComposerAccessories.swift`.

// MARK: - 보내기 전 에이전트 준비 상태 (onb-4)

/// 보내기 전에 본 에이전트의 준비 상태 — 쓸 수 없다고 **확인된** 상태(설치 안 됨 · 지정한 경로 오류 · 로그인 안 됨)만 막고,
/// 그에 맞는 할 일과 단추를 준다. 확인 전 · 로그인 모름은 보낸다 (CLI 가 스스로 확인한다). 모델 목록보다 먼저 본다 —
/// 설치되지 않은 에이전트로 보내면 "모델을 선택하세요" 가 먼저 떠 엉뚱한 일을 시켰다.
enum SendReadiness {
    /// 안내의 단추가 여는 곳.
    enum Destination: Equatable, Sendable {
        /// 도움말 > 시작 점검… (설치 · 로그인 안내와 명령).
        case firstRunCheck
        /// 설정 > 에이전트 (실행 파일 경로 · Codex 계정의 로그인 명령).
        case agentSettings
        /// 설정 > 인계 (이어 받을 순서 — "받음" 을 끈 에이전트, hand-4).
        case handoffSettings
    }

    struct Block: Equatable, Sendable {
        var text: String
        var actionTitle: String
        var opens: Destination
    }

    /// 막아야 하는 상태인가.
    static func blocks(_ readiness: AgentReadiness) -> Bool {
        readiness == .notInstalled || readiness == .pathInvalid || readiness == .notLoggedIn
    }

    /// 막을 때의 안내. `accountLabel` 은 Codex 계정이 둘 이상일 때의 계정 이름 (로그인은 계정마다 따로다).
    static func block(provider: AgentProvider, readiness: AgentReadiness, accountLabel: String? = nil) -> Block? {
        let name = provider == .claude ? "Claude Code" : provider.displayName
        switch readiness {
        case .notInstalled:
            return Block(text: "이 Mac 에서 \(name) 실행 파일을 찾지 못해 보내지 않았습니다. 설치한 뒤 다시 보내세요 — 설치 방법은 시작 점검에 있습니다.",
                         actionTitle: "시작 점검 열기", opens: .firstRunCheck)
        case .pathInvalid:
            return Block(text: "설정에서 지정한 \(name) 실행 파일을 실행할 수 없어 보내지 않았습니다. 설정 > 에이전트의 ‘실행 파일’에서 경로를 고치거나 자동으로 찾게 되돌리세요.",
                         actionTitle: "설정 열기", opens: .agentSettings)
        case .notLoggedIn where provider == .codex:
            let who = accountLabel.map { "Codex 계정 \($0)" } ?? "Codex"
            return Block(text: "\(who) 에 로그인되어 있지 않아 보내지 않았습니다. 터미널에서 로그인한 뒤 다시 보내세요 — 명령은 설정 > 에이전트의 계정 줄에 있습니다.",
                         actionTitle: "설정 열기", opens: .agentSettings)
        case .notLoggedIn:
            return Block(text: "\(name) 에 로그인되어 있지 않아 보내지 않았습니다. 터미널에서 claude 를 실행해 로그인한 뒤 다시 보내세요.",
                         actionTitle: "시작 점검 열기", opens: .firstRunCheck)
        case .ready, .loginUnknown, .checking:
            return nil
        }
    }

    /// 입력창의 에이전트 표시에 붙일 지금의 상태 (보내기 전에 보이게 — 점검표가 사라진 뒤에도). 쓸 수 있으면 nil.
    static func notice(provider: AgentProvider, readiness: AgentReadiness, accountLabel: String? = nil) -> String? {
        let name = provider == .claude ? "Claude Code" : provider.displayName
        switch readiness {
        case .notInstalled:
            return "이 Mac 에서 \(name) 실행 파일을 찾지 못했습니다. 설치 방법은 도움말 > 시작 점검에 있습니다."
        case .pathInvalid:
            return "설정에서 지정한 \(name) 실행 파일을 실행할 수 없습니다 (설정 > 에이전트)."
        case .notLoggedIn where provider == .codex:
            return (accountLabel.map { "Codex 계정 \($0)" } ?? "Codex") + " 에 로그인되어 있지 않습니다 (설정 > 에이전트의 계정 줄)."
        case .notLoggedIn:
            return "\(name) 에 로그인되어 있지 않습니다. 터미널에서 claude 를 실행해 로그인하세요."
        case .ready, .loginUnknown, .checking:
            return nil
        }
    }
}

// MARK: - 보내는 중 (chat-1 · onb-1)

/// 입력창에서 보낸 메시지가 실행으로 시작되기 전의 단계 — 입력창이 "보내는 중" 을 보이고, 그동안 다시 보내지 않는다.
enum SendStage: Equatable, Sendable {
    /// 막힌 데가 없는지 보는 중.
    case preparing
    /// 모델 목록을 받는 중 (첫 폴더를 연 직후 · 시작 때의 조회와 겹쳤다).
    case checkingModels
    /// 실행 전 작업 폴더를 찍고 에이전트를 띄우는 중.
    case starting

    /// 입력창의 자리 글 (글을 비운 자리에 보인다).
    var placeholder: String {
        switch self {
        case .preparing: return "보내는 중…"
        case .checkingModels: return "모델 목록을 확인하는 중… 확인되면 보냅니다"
        case .starting: return "에이전트를 시작하는 중…"
        }
    }
}

// MARK: - 대기열 (chat-28 · chat-4)

/// 대기열에서 막 뺀 메시지 — 몇 초 동안 되돌릴 수 있다 (`AppModel.undoQueueRemoval`). 멈춤 이유도 함께 되돌린다
/// (마지막 메시지를 빼면 멈춤 이유가 지워진다 — 되돌린 메시지가 멈춤 이유 없이 남으면 보낼 단추가 없다).
struct RemovedQueuedMessage: Equatable, Sendable {
    var message: QueuedMessage
    var index: Int
    var pauseReason: String?
    var at: Date = Date()
}

enum QueueRules {
    /// 실행이 끝난 뒤 되돌린 메시지의 멈춤 이유 (conv-5) — 보내려면 [이어서 보내기].
    static let restoredAfterRunPause = "실행이 끝난 뒤 되돌려 멈췄습니다"

    /// 실행이 정상으로 끝나지 않아 대기열을 멈춘 이유 — 상태마다 문장 하나 (조사가 이름에 따라 바뀌지 않게).
    static func pauseReason(after state: RunState) -> String {
        switch state {
        case .failed: return "실행이 실패해 보내지 않았습니다"
        case .cancelled, .interrupting: return "실행을 멈춰 보내지 않았습니다"
        case .rateLimited: return "사용 한도에 닿아 보내지 않았습니다"
        case .handoffDeliveryUnknown: return "인계의 전달 여부를 확인하지 못해 보내지 않았습니다"
        default: return "실행이 끝나지 않은 채 멈춰 보내지 않았습니다"
        }
    }

    /// 앞서 보낸 메시지가 시작되지 못했다 — 그동안 걸어 둔 메시지는 기다릴 실행이 없다.
    static let previousSendFailed = "앞 메시지를 보내지 못해 멈췄습니다 — 입력창 위의 안내를 확인하세요"

    /// 대기열에서 뺀 메시지를 되돌릴 수 있는 시간 (초).
    static let undoWindow: TimeInterval = 6

    /// 걸어 둔 메시지를 입력창으로 되돌릴 때 이미지가 상한을 넘는가.
    static func editExceedsImageLimit(current: Int, adding: Int, limit: Int) -> Bool { current + adding > limit }

    /// 승인 · 질문을 기다리는 동안 입력창에 쓴 글이 카드에 대한 답처럼 보이는가 (CLI 습관: y · n · 1 …).
    /// 그런 글은 대기열에 걸기 전에 한 번 확인한다 — 걸어 두면 실행이 끝난 뒤 새 지시로 간다.
    static func looksLikeDecisionReply(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.count <= 4 else { return false }
        let replies: Set<String> = ["y", "n", "yes", "no", "ok", "ㅇ", "ㄴ", "ㅇㅇ", "네", "예", "응", "아니", "아니요", "허용", "거절"]
        if replies.contains(value) { return true }
        return value.allSatisfy(\.isNumber)
    }

    /// 확인을 받은 뒤 같은 글로 다시 ↵ 를 누르면 거는 시간 (초).
    static let replyConfirmWindow: TimeInterval = 8
}

// MARK: - 실행 중의 esc (chat-29)

/// 입력창의 esc — CLI 습관대로 실행을 멈추는 길. 실수로 멈추지 않게 입력창이 비어 있고 실행이 돌 때만, 두 번 눌러야 멈춘다.
enum ComposerEscape {
    enum Action: Equatable, Sendable {
        /// esc 를 원래대로 (입력창의 기본 동작).
        case ignore
        /// 한 번 더 누르면 멈춘다고 알린다.
        case arm
        /// 실행을 멈춘다.
        case interrupt
    }

    /// 두 번째 esc 를 받는 시간 (초).
    static let window: TimeInterval = 2

    static func action(textEmpty: Bool, running: Bool, armedAt: Date?, now: Date = Date()) -> Action {
        guard textEmpty, running else { return .ignore }
        if let armedAt, now.timeIntervalSince(armedAt) <= window { return .interrupt }
        return .arm
    }
}

// MARK: - 긴 글 (chat-20)

enum ComposerText {
    /// 입력창 높이를 잴 글 — 상자는 8줄 남짓(190pt)에서 멈추므로 앞부분만 잰다 (수천 줄을 붙여도 키마다 글 전체를 배치하지 않게).
    /// 앞에서부터 `maxCharacters` 글자 · `maxLines` 줄까지만 훑는다 (긴 글을 끝까지 세지 않는다).
    static func heightProbe(_ text: String, maxLines: Int = 14, maxCharacters: Int = 1600) -> String {
        var lines = 0
        var count = 0
        var end = text.startIndex
        while end < text.endIndex {
            if count >= maxCharacters { return String(text[..<end]) }
            if text[end] == "\n" {
                lines += 1
                if lines >= maxLines { return String(text[..<end]) }
            }
            end = text.index(after: end)
            count += 1
        }
        return text
    }

    /// 상자를 넘칠 만큼 긴 글인가 (스크롤 막대를 보인다). 앞의 800 글자까지만 본다.
    static func overflows(_ text: String) -> Bool {
        var lines = 0
        var count = 0
        for character in text {
            count += 1
            if count > 800 { return true }
            if character == "\n" {
                lines += 1
                if lines >= 8 { return true }
            }
        }
        return false
    }

    /// 이보다 긴 초안(UTF-8 바이트)은 키마다 저장하지 않고 잠시 모아 저장한다.
    static let coalescedDraftBytes = 40_000
}

// MARK: - 좁은 입력창의 계정 (cap-9)

enum ComposerAccountLabel {
    /// 가장 좁은 입력창에 남길 Codex 계정 이름 — 첫 낱말, 길면 앞 다섯 글자 + "…" ("기본 계정" → "기본", "work-2" → "work-2").
    static func short(_ label: String) -> String {
        let first = label.split(separator: " ").first.map(String.init) ?? label
        return first.count > 6 ? String(first.prefix(5)) + "…" : first
    }
}
