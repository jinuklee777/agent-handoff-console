import Foundation

// 분할 화면의 칸 머리와 툴바 "응답 필요" 가 보이는 상태 — 순수 판정 (화면 · 실행기 · 저장을 모른다).
// 입력은 `AppModel.paneStatusInput(for:)` 이 실행기 · 대화 상자 · 자동 작업에서 모아 넣는다. 문구 · 우선순위 · 강조 여부는 여기 한 곳이다.

/// 칸 머리 하나가 보는 사실.
struct PaneStatusInput: Equatable, Sendable {
    /// 이 대화에서 지금 도는 실행의 상태. 없으면 nil.
    var runState: RunState?
    /// 도는 실행이 자동 작업의 검토 레인의 것이다 (내부 대화).
    var reviewing = false
    var pendingApprovals = 0
    var pendingQuestions = 0
    /// 메인 턴을 마치고 남은 하위 작업 · 백그라운드 명령을 기다린다.
    var waitingOnBackground = false
    var unfinishedSubAgents = 0
    /// 도는 실행이 없을 때 보일, 마지막으로 끝난 실행.
    var lastRunState: RunState?
    var lastRunEndedAt: Date?
    /// 이 대화(부모)의 자동 작업이 사람을 기다린다.
    var orchestration: OrchestrationAttention?
    /// 같은 폴더에서 다른 대화의 쓰기 실행이 함께 돈다 (실행 전후 비교는 양쪽 다 "겹침"으로 남는다).
    var sharesFolder = false
    /// 인계 카드가 사람의 검토를 기다린다 — 게이트가 막음 · 보내지 못함 · 전달 미확인 · 받는 계정 해제 · 낡음
    /// (사람이 스스로 멈춘 카드는 빼고 — `HandoffCard.attention`).
    var handoffReview = false
    /// 자동 인계 카운트다운이 돈다.
    var handoffCountdown = false
    /// 자동 인계가 같은 Codex 의 다른 계정을 골라, 카운트다운 뒤 그 계정에서 같은 세션을 이어 간다 (인계 카드 대신 —
    /// `AppModel.codexSwitchCountdowns`). 자동 인계 카운트다운과 같은 무게: 보이되 답을 기다리지는 않는다.
    var codexSwitchCountdown = false
    /// 인계 초안 카드가 있다 — 사람이 연 것이거나 사람이 카운트다운을 멈춘 것. 답을 기다리는 것은 아니다.
    var handoffDraft = false
    /// 인계 초안을 만드는 중이다.
    var handoffPreparing = false
    /// 인계 카드를 보내는 중이다 (점유한 뒤 전달 실행이 시작되기 전 — 지문 · 받는 계정의 모델 목록 · 실행 전 스냅샷을 기다린다).
    /// 전달 실행이 시작되면 `runState == .handoffSending` 이 같은 문구를 낸다.
    var handoffSending = false

    /// 사람이 멈추지 않으면 스스로 움직이는 카운트다운이 돈다 (자동 인계 · 다른 계정에서 이어 가기) — 답을 꼭 받아야 하는 것은 아니지만
    /// 사이드바 행 · Dock 배지는 답을 기다리는 것과 같은 모양으로 센다 (멈출 수 있게).
    var countingDown: Bool { handoffCountdown || codexSwitchCountdown }
}

struct PaneStatus: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        /// 끝난 실행 · 중단 — 흐리게.
        case quiet
        /// 도는 중.
        case active
        /// 사람이 볼 것 (승인 · 질문 · 자동 작업 · 한도 · 전달 미확인).
        case attention
        /// 실패.
        case danger
    }

    var text: String
    /// 좁은 칸의 짧은 문구 (`PaneHeaderDensity.compact`).
    var shortText: String
    var tone: Tone
    /// 사람의 답을 기다린다 — 칸 머리를 강조하고 툴바 "응답 필요" 에 센다.
    var needsResponse: Bool
    var help: String

    /// 인계를 보내는 중 — 카드가 보내는 중일 때와 전달 실행이 돌 때가 같은 문구.
    static let sendingHandoff = PaneStatus(text: "인계 보내는 중", shortText: "인계", tone: .active, needsResponse: false,
                                           help: "인계를 보내는 중입니다")

    /// 인계 카드 상태의 도움말 — 카드는 그 대화의 끝에 있다. 사이드바 행 · 칸 머리가 같이 쓰므로 분할과 무관한 말로 쓴다
    /// ("칸" 은 분할하지 않은 화면에 없다).
    static let handoffHelp = "대화 끝의 인계 카드에서 확인하세요"

    /// 보일 상태. 실행 기록이 없는 대화면 nil (머리에 상태를 두지 않는다).
    /// 우선순위: 승인 → 질문 → 인계 검토 · 실패 → 자동 작업이 기다림 → 자동 인계 카운트다운 · 다른 계정에서 이어 가기 카운트다운 →
    /// 도는 실행 → 인계 초안 → 마지막으로 끝난 실행.
    static func make(_ input: PaneStatusInput, now: Date = Date()) -> PaneStatus? {
        if input.pendingApprovals > 0 {
            let count = input.pendingApprovals > 1 ? " \(input.pendingApprovals)" : ""
            return PaneStatus(text: "승인 대기" + count, shortText: "승인" + count, tone: .attention, needsResponse: true,
                              help: "이 대화의 실행이 승인을 기다립니다 — 대화 끝의 승인 카드에서 답하세요")
        }
        if input.pendingQuestions > 0 {
            return PaneStatus(text: "질문 대기", shortText: "질문", tone: .attention, needsResponse: true,
                              help: "에이전트가 묻고 있습니다 — 대화 끝의 질문 카드에서 답하세요")
        }
        if input.handoffReview {
            return PaneStatus(text: "인계 검토 필요", shortText: "인계 검토", tone: .attention, needsResponse: true,
                              help: handoffHelp)
        }
        if let attention = input.orchestration {
            let (text, short) = orchestrationText(attention)
            return PaneStatus(text: text, shortText: short, tone: .attention, needsResponse: true,
                              help: "자동 작업이 사람을 기다립니다 — 입력창 위 작업 카드에서 답하세요")
        }
        if input.handoffCountdown {
            return PaneStatus(text: "자동 인계 대기", shortText: "인계", tone: .attention, needsResponse: false,
                              help: "잠시 뒤 다른 에이전트로 자동 인계합니다 — " + handoffHelp)
        }
        // 같은 무게 — 다만 인계가 아니다: 같은 Codex 세션을 다른 계정에서 이어 간다 (`CodexAccountSwitch`).
        if input.codexSwitchCountdown {
            return PaneStatus(text: CodexAccountSwitch.waitingText, shortText: CodexAccountSwitch.waitingShortText,
                              tone: .attention, needsResponse: false, help: CodexAccountSwitch.waitingHelp)
        }
        if input.handoffSending {
            return sendingHandoff
        }
        if let state = input.runState, state.isActive {
            if input.reviewing {
                return PaneStatus(text: "검토 중", shortText: "검토", tone: .active, needsResponse: false,
                                  help: "자동 작업의 검토가 도는 중입니다")
            }
            switch state {
            case .starting:
                return PaneStatus(text: "시작 중", shortText: "시작", tone: .active, needsResponse: false, help: "실행을 시작하는 중입니다")
            case .interrupting:
                return PaneStatus(text: "중단 중", shortText: "중단", tone: .active, needsResponse: false, help: "실행을 멈추는 중입니다")
            case .handoffSending:
                return sendingHandoff
            default:
                if input.waitingOnBackground {
                    // 턴 머리줄 · 상태 줄과 같은 이름 (`SubAgentDigest.waitingText`).
                    let count = input.unfinishedSubAgents
                    return PaneStatus(text: SubAgentDigest.waitingText(count: count),
                                      shortText: SubAgentDigest.waitingShortText(count: count), tone: .active,
                                      needsResponse: false, help: SubAgentDigest.waitingHelp)
                }
                return PaneStatus(text: "실행 중", shortText: "실행", tone: .active, needsResponse: false, help: "에이전트가 실행 중입니다")
            }
        }
        if input.handoffDraft {
            return PaneStatus(text: "인계 초안", shortText: "인계", tone: .quiet, needsResponse: false, help: handoffHelp)
        }
        if input.handoffPreparing {
            return PaneStatus(text: "인계 초안 만드는 중", shortText: "인계", tone: .quiet, needsResponse: false, help: handoffHelp)
        }
        guard let last = input.lastRunState, last.isTerminal else { return nil }
        let ago = input.lastRunEndedAt.map { " · " + ChangesState.relativeTime($0, now: now) } ?? ""
        switch last {
        case .completed:
            return PaneStatus(text: "완료" + ago, shortText: "완료", tone: .quiet, needsResponse: false, help: "마지막 실행이 끝났습니다")
        case .cancelled:
            return PaneStatus(text: "중단됨" + ago, shortText: "중단됨", tone: .quiet, needsResponse: false, help: "마지막 실행을 멈췄습니다")
        case .failed:
            return PaneStatus(text: "오류" + ago, shortText: "오류", tone: .danger, needsResponse: false,
                              help: "마지막 실행이 오류로 끝났습니다 — 대화 끝의 안내를 보세요")
        case .rateLimited:
            return PaneStatus(text: "한도 도달" + ago, shortText: "한도", tone: .attention, needsResponse: false,
                              help: "사용 한도에 닿아 멈췄습니다 — 다른 에이전트에게 이어 맡길 수 있습니다")
        case .handoffDeliveryUnknown:
            return PaneStatus(text: "전달 여부 미확인", shortText: "미확인", tone: .attention, needsResponse: false,
                              help: "인계가 전달됐는지 확인하지 못했습니다 — 앱은 다시 보내지 않습니다. 이 대화에 받는 쪽의 응답이 있는지 보세요")
        default:
            return nil
        }
    }

    private static func orchestrationText(_ attention: OrchestrationAttention) -> (String, String) {
        switch attention {
        case .planApproval: return ("계획 승인 대기", "계획 승인")
        case .clarification: return ("자동 작업이 묻습니다", "질문")
        case .blocked: return ("자동 작업 막힘", "막힘")
        case .deliveryUnknown: return ("전달 여부 확인 필요", "확인 필요")
        case .finalVerificationFailed: return ("최종 검증 실패", "검증 실패")
        case .budgetExhausted: return ("시도 횟수 소진", "시도 소진")
        case .planningFailed: return ("계획 실패", "계획 실패")
        }
    }
}

/// 칸 머리가 한 줄에 무엇을 넣을지 — 칸 너비로 고른다 (네 칸 · 좁은 창에서 제목이 먼저 줄고, 그다음 프로젝트 · 긴 문구를 뺀다).
enum PaneHeaderDensity: Equatable, Sendable {
    /// 프로젝트(보일 때) · 긴 상태 · 같은 폴더 표시.
    case full
    /// 프로젝트를 뺀다.
    case medium
    /// 짧은 상태만.
    case compact

    static func forWidth(_ width: Double) -> PaneHeaderDensity {
        if width >= 560 { return .full }
        if width >= 380 { return .medium }
        return .compact
    }

    /// 칸에 열린 대화들의 프로젝트가 둘 이상일 때만 머리에 프로젝트를 적는다 (다 같으면 툴바 부제로 충분하다).
    static func showsProject(paneProjectIDs: [String?]) -> Bool {
        Set(paneProjectIDs.compactMap { $0 }).count > 1
    }
}

/// 툴바 "응답 필요" 의 한 줄.
struct ResponseNeeded: Equatable, Identifiable, Sendable {
    var threadID: String
    var title: String
    var provider: AgentProvider
    /// 무엇을 기다리나 (`PaneStatus.text`).
    var what: String
    var id: String { threadID }

    /// 보일 목록: 포커스 대화는 뺀다 (그 카드가 이미 앞에 있다). 칸에 열린 순서가 먼저, 그다음 나머지(받은 순서 그대로).
    static func ordered(_ items: [ResponseNeeded], paneThreadIDs: [String?], focusedThreadID: String?) -> [ResponseNeeded] {
        let others = items.filter { $0.threadID != focusedThreadID }
        func rank(_ item: ResponseNeeded) -> Int {
            paneThreadIDs.firstIndex(where: { $0 == item.threadID }) ?? paneThreadIDs.count
        }
        return others.enumerated().sorted { lhs, rhs in
            let (left, right) = (rank(lhs.element), rank(rhs.element))
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// 칩 글자. 한 곳이면 무엇을 기다리는지까지.
    static func chipTitle(_ items: [ResponseNeeded]) -> String {
        items.count == 1 ? "응답 필요 · \(items[0].what)" : "응답 필요 \(items.count)"
    }
}
