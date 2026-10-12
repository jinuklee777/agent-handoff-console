import Foundation

// 인계 카드 (B 설계 C1) — 대화 끝에 놓이는 인계 초안의 상태 · 막힘 판정 · 카드가 말할 글. **순수 값**이다:
// 화면(SwiftUI) · 실행기 · 저장을 모른다 (검증 하네스가 컴파일한다). 상태를 바꾸는 동작은 `AppModel+Handoff`,
// 그리는 곳은 `UI/HandoffCardView`. 판정은 열거형(`Phase` · `Origin` · `Review`)으로 하고 화면 글로 하지 않는다.

/// 인계 초안 — 보낼 내용의 유일한 출처 (패킷 · 받는 쪽에게 가는 글 · 대상 · 계정 · 경고).
struct HandoffDraft: Identifiable, Sendable {
    var id: String { handoff.id }
    var handoff: Handoff
    var packet: HandoffPacket
    /// 받는 쪽에게 갈 글. 사람이 카드에서 고칠 수 있다 (넘길 때 작성 줄 · 덧붙인 말이 더해진다).
    var editedText: String
    /// 앱이 패킷으로 그린 글 — `editedText` 와 다르면 사람이 고친 것이다.
    var renderedText: String
    var threadTitle: String
    var geminiRequested = false
    var validationWarnings: [String] = []
    /// Gemini 로 정리하려 했지만 하지 못했다 (그 까닭) — 문서는 앱이 정리한 것이다. 검증 경고가 아니다: 자동 인계를 막지 않는다.
    var geminiFailure: String?

    init(handoff: Handoff, packet: HandoffPacket, text: String, threadTitle: String,
         geminiRequested: Bool = false, validationWarnings: [String] = []) {
        self.handoff = handoff
        self.packet = packet
        self.editedText = text
        self.renderedText = text
        self.threadTitle = threadTitle
        self.geminiRequested = geminiRequested
        self.validationWarnings = validationWarnings
    }

    /// 사람이 문서를 고쳤다 (카드는 요약 대신 "직접 고친 문서를 보냅니다").
    var isEdited: Bool { editedText != renderedText }

    var source: HandoffSource.Agent {
        HandoffSource.Agent(provider: handoff.fromProvider,
                            codexAccountID: handoff.fromProvider == .codex ? handoff.fromAccountID : nil)
    }
    var target: HandoffSource.Agent {
        HandoffSource.Agent(provider: handoff.toProvider,
                            codexAccountID: handoff.toProvider == .codex ? handoff.toAccountID : nil)
    }
}

/// 대화 끝의 인계 카드 하나. 여러 대화가 함께 카드를 가진다 (`AppModel.handoffCards`, 대화 ID → 카드).
/// 화면 상태(체크 · 펼침 · 덧붙인 말 · 문서 편집)도 여기 둔다 — 뷰의 `@State` 는 칸이 다시 만들어질 때 사라진다.
struct HandoffCard: Identifiable, Sendable {
    enum Phase: Equatable, Sendable {
        /// 사람이 넘길 수 있다 (확인 체크 뒤).
        case ready
        /// 자동 인계 카운트다운. 끝나면 사람 검토 없이 넘긴다.
        case countingDown(deadline: Date, delay: Int)
        /// 보내는 중 — 되돌릴 수 없는 지점. 취소 · 편집 · 다른 보내기를 받지 않는다.
        case sending
        /// 보내지 못했다 (시작 전 실패 · 받는 쪽이 받지 못함). 같은 행을 다시 보낼 수 있다.
        case failed(String)
        /// 전달 여부 미확인 — 보낼 수 없는 카드 (앱은 다시 보내지 않는다).
        case unknown
    }

    /// 카드가 생긴 까닭. 머리 문장을 정한다.
    enum Origin: Equatable, Sendable {
        /// ⇧⌘H · 메뉴바.
        case manual
        /// 사용 한도에 닿았다 (자동 인계 · 한도 줄의 인계).
        case limitReached(scope: AgentScope, resetsAt: Date?)
        /// 한도 75% 이어 가기 제안 (C4).
        case suggestion(scope: AgentScope, peak: Double, windowLabel: String?)
        /// 입력창 칩에서 다른 에이전트를 골랐다 (C3).
        case chip

        /// 처음 초안에 Gemini 정리를 붙이는가 (설정이 켜져 있을 때). 칩 · 제안은 **규칙 초안만** — 고르자마자 기록을 Google 로
        /// 보내지 않고 바로 보이게 (정리는 카드의 [Gemini 로 다시 정리] 로만). 수동 · 한도는 설정대로.
        var draftsWithGemini: Bool {
            switch self {
            case .manual, .limitReached: return true
            case .suggestion, .chip: return false
            }
        }
    }

    /// 사람이 봐야 하는 까닭.
    enum Review: Equatable, Sendable {
        /// 자동 인계의 게이트가 막았다 (이유들).
        case automaticBlocked([String])
        /// 사람이 카운트다운을 멈췄다 — 이후로는 확인 체크 길로 보낸다. 답을 기다리는 카드가 아니다.
        case pausedByHuman
        /// 보내지 못했다.
        case deliveryFailed(String)
        /// 받는 Codex 계정의 등록이 해제됐다 (계정 이름).
        case accountRemoved(String)
        /// 초안 이후 폴더 · 파일 상태가 바뀌었다.
        case stale(String)
    }

    /// 초안을 만든 때의 폴더 상태. 넘길 때 · 타이머가 울릴 때 다시 재서 다르면 보내지 않는다 (`Review.stale`).
    struct Fingerprint: Equatable, Sendable {
        var folderPath: String
        var lastRunID: String?
        /// git HEAD + 변경 파일 목록의 해시. 저장소가 아니면(또는 git 을 못 찾으면) nil.
        var gitState: String?
    }

    /// 받는 쪽이 이어 갈 세션 — 받는 쪽 줄이 사실대로 말한다.
    enum Session: Equatable, Sendable {
        /// 이 대화에서 받는 쪽 제공자가 쓰던 CLI 세션을 이어 간다 (Codex 는 받는 계정과 상관없이 대화의 세션).
        case resumes
        /// 새 세션에서 이 문서로 시작한다.
        case fresh
    }

    /// 받는 쪽에 대해 앱이 확인한 사실 (확인한 때와 함께). 모르는 것은 nil — ✓ 를 붙이지 않는다.
    struct ReceiverFacts: Equatable, Sendable {
        var cliUsable: Bool?
        var authenticated: Bool?
        var authCheckedAt: Date?
        var session: Session = .fresh
    }

    /// 카드의 주의 단계 — 칸 머리 · 응답 필요 · Dock · 색이 쓴다.
    enum Attention: Equatable, Sendable {
        /// 사람이 봐야 한다 (게이트 막힘 · 실패 · 미확인 · 계정 해제 · 낡음).
        case review
        /// 자동 인계 카운트다운.
        case countdown
        /// 수동 카드 · 사람이 멈춘 카드 · 보내는 중 — 답을 기다리는 것은 아니다.
        case draft
    }

    var draft: HandoffDraft
    var phase: Phase = .ready
    var origin: Origin
    var review: Review?
    /// 자동 인계가 만든 카드 (사람이 연 것이 아니다) — 스크롤 · 기록 문구가 다르다.
    var automatic = false
    /// 받는 쪽에게 덧붙일 말 — 넘길 때 문서에 넣는다 (`HandoffPacketBuilder.insertUserMemo`). `Handoff.note` 와 다른 칸.
    var userMemo = ""
    /// [덧붙일 말로 옮기기] 로 대기열에서 옮겨 온 메시지의 원본 — 넘기지 않고 카드가 사라지면(취소 · 미확인 닫기 · 앱 종료) 대기열에
    /// 멈춘 채로 되돌린다 (hand-2: 흔적 없이 사라졌다). 넘기면 덧붙일 말로 갔으니 버린다.
    var movedMessages: [QueuedMessage] = []
    var confirmed = false
    var editorOpen = false
    /// 문서 전문을 읽기로 펼쳤다 (고치기는 `editorOpen`).
    var documentShown = false
    /// Gemini 로 다시 정리하는 중 — 보내기를 막는다.
    var summarizing = false
    /// 좁은 칸에서 펼쳤다.
    var expanded = false
    /// 덧붙일 말 칸에 키보드 포커스를 달라는 요청 (⇧⌘H · 메뉴바로 카드에 왔다). 카드가 포커스를 주고 지운다 — 칸이 다시 그려질 때
    /// 입력창의 포커스를 다시 빼앗지 않게 한 번만.
    var memoFocusPending = false
    /// 받는 쪽 사실을 다시 확인하는 중 (검토 카드의 [다시 확인]).
    var recheckingReceiver = false
    var lastError: String?
    var fingerprint: Fingerprint?
    var receiver = ReceiverFacts()

    var id: String { draft.id }
    var threadID: String { draft.handoff.threadID }
    var targetProvider: AgentProvider { draft.handoff.toProvider }
    var sourceProvider: AgentProvider { draft.handoff.fromProvider }

    init(draft: HandoffDraft, origin: Origin, automatic: Bool = false) {
        self.draft = draft
        self.origin = origin
        self.automatic = automatic
    }

    var isCountingDown: Bool { if case .countingDown = phase { return true } else { return false } }
    var isSending: Bool { phase == .sending }
    var isFailed: Bool { if case .failed = phase { return true } else { return false } }

    /// 보내기를 점유할 수 있다 (`AppModel.beginSend`): 넘길 수 있는 단계이고 재정리 중이 아니다.
    var canBeginSend: Bool {
        guard !summarizing else { return false }
        switch phase {
        case .ready, .countingDown, .failed: return true
        case .sending, .unknown: return false
        }
    }

    /// 낡은 카드 (다시 만들어야 넘길 수 있다).
    var isStale: Bool { if case .stale = review { return true } else { return false } }

    var attention: Attention {
        switch phase {
        case .countingDown: return .countdown
        case .failed, .unknown: return .review
        case .sending: return .draft
        case .ready:
            switch review {
            case .automaticBlocked?, .deliveryFailed?, .accountRemoved?, .stale?: return .review
            case .pausedByHuman?, nil: return .draft
            }
        }
    }

    /// 승인 카드와 같은 바탕을 쓰는가 — 카운트다운 · 사람이 멈추지 않은 검토 · 실패 카드만 (색은 판단이 필요한 것에만).
    var highlighted: Bool { attention != .draft }

    /// "내용을 확인했습니다" 체크를 보이는가. 접힌 카드(좁은 칸)에서는 보이지 않는다 — 요약 · 받는 모델 · 막은 이유를 보지 않은 채
    /// 체크하고 넘기지 않게 (펼치면 보인다).
    func showsConfirm(folded: Bool) -> Bool {
        !folded && !isCountingDown && !isSending && phase != .unknown && !isStale
    }

    /// 접힌 카드의 주 단추를 [펼쳐서 확인] 으로 둘까 — 확인 체크가 펼친 뒤에만 있어 [넘기기] 가 꺼진 까닭이 화면에 없을 때.
    func foldedNeedsExpand(folded: Bool) -> Bool {
        folded && !confirmed && showsConfirm(folded: false)
    }

    /// 접힌 카드가 사실 줄 대신 보일 막은 이유 (게이트가 막은 자동 인계의 첫 이유). 펼친 카드는 이유를 모두 그린다.
    var foldedReviewReason: String? {
        guard phase == .ready, case .automaticBlocked(let reasons)? = review else { return nil }
        return reasons.first
    }

    /// 사람이 [넘기기] 로 보낼 수 있다 (막힘은 따로 — `HandoffSendBlock`). [넘기기] 단추를 켤지 이것으로 본다.
    var sendableByHuman: Bool {
        guard confirmed, !summarizing, !isStale else { return false }
        switch phase {
        case .ready, .failed: return true
        case .countingDown, .sending, .unknown: return false
        }
    }
}

// MARK: - 보내기를 막는 것

/// 카드의 보내기를 막는 사실. 카드 안의 막힘 이유와 `AppModel.deliverHandoff` 가 **같은 판정**(`HandoffSendBlock.first`)을 쓴다.
struct HandoffSendFacts: Equatable, Sendable {
    var summarizing = false
    /// 같은 대화의 초안을 다시 만드는 중 (바꾸기 · 다시 만들기).
    var remaking = false
    var stale = false
    var receiverAccountMissing = false
    var sameAccount = false
    /// 받는 쪽을 쓸 수 없다고 **확인됐다** — CLI 설치 안 됨 · 실행 불가 · 로그인 안 됨 (`ContinueChoice.handoffBlock` 의 도움말).
    /// 확인하지 않은 것 · 로그인 "모름" 은 막지 않는다 (점검표의 황색 통과와 같다).
    var receiverUnavailable: String?
    var antigravityNotAllowed = false
    var antigravityRefreshing = false
    /// Antigravity 로 보낼 수 없는 선택의 이유 (`AntigravityAdapter.TurnBlock.message`).
    var antigravityBlock: String?
    var runActive = false
    /// 메인 턴을 마치고 백그라운드 작업을 기다리면 그 수 (`SubAgentDigest.waitingNote`).
    var runWaitingNote = ""
    var starting = false
    var unterminated = false
    var reviewing = false
    /// 도는 앱의 git 명령 이름.
    var gitOperation: String?
    /// 도는 독립 작업 폴더 명령 ("만드는" · "합치는" …).
    var worktreeOperation: String?
    /// 작업 폴더가 지워졌다 (`AppModel.worktreeProblem`).
    var worktreeProblem: String?
}

enum HandoffSendBlock: Equatable, Sendable {
    case summarizing
    case remaking
    case stale
    case receiverAccountMissing
    case sameAccount
    /// 받는 쪽을 쓸 수 없다 (설치 안 됨 · 실행 불가 · 로그인 안 됨이 확인됨) — 그 까닭.
    case receiverUnavailable(String)
    case antigravityNotAllowed
    case antigravityRefreshing
    case antigravity(String)
    case running(String)
    case starting
    case unterminated
    case reviewing
    case gitRunning(String)
    case worktreeOperation(String)
    case worktreeMissing(String)

    /// 막는 것 중 사람이 먼저 알아야 할 하나. 없으면 nil.
    static func first(_ f: HandoffSendFacts) -> HandoffSendBlock? {
        if f.summarizing { return .summarizing }
        if f.remaking { return .remaking }
        if f.stale { return .stale }
        if f.receiverAccountMissing { return .receiverAccountMissing }
        if f.sameAccount { return .sameAccount }
        if let problem = f.receiverUnavailable { return .receiverUnavailable(problem) }
        if f.antigravityNotAllowed { return .antigravityNotAllowed }
        if f.antigravityRefreshing { return .antigravityRefreshing }
        if let block = f.antigravityBlock { return .antigravity(block) }
        if f.runActive { return .running(f.runWaitingNote) }
        if f.starting { return .starting }
        if f.unterminated { return .unterminated }
        if f.reviewing { return .reviewing }
        if let operation = f.gitOperation { return .gitRunning(operation) }
        if let operation = f.worktreeOperation { return .worktreeOperation(operation) }
        if let problem = f.worktreeProblem { return .worktreeMissing(problem) }
        return nil
    }

    var message: String {
        switch self {
        case .summarizing: return "Gemini 가 초안을 다시 정리하는 중입니다"
        case .remaking: return "초안을 다시 만드는 중입니다"
        case .stale: return "초안 이후 폴더 · 파일 상태가 바뀌었습니다 — 다시 만들기"
        case .receiverAccountMissing: return "받는 Codex 계정이 더 이상 등록되어 있지 않습니다 — 받는 쪽을 바꾸세요"
        case .sameAccount: return "같은 계정으로는 인계할 수 없습니다 — 다른 Codex 계정을 고르세요"
        case .receiverUnavailable(let problem): return problem
        case .antigravityNotAllowed: return "이 프로젝트에서는 Antigravity 로 인계할 수 없습니다 — 프로젝트 설정에서 켜세요"
        case .antigravityRefreshing: return "Antigravity 모델 목록을 확인하는 중입니다"
        case .antigravity(let message): return message
        case .running(let note): return "이 대화에서 에이전트가 실행 중입니다\(note) — 끝나면 넘길 수 있습니다"
        case .starting: return "에이전트 실행을 시작하는 중입니다"
        case .unterminated: return "종료가 확인되지 않은 프로세스가 있습니다 — 확인한 뒤 넘기세요"
        case .reviewing: return "자동 작업의 검토가 이 폴더를 읽는 중입니다 — 끝난 뒤에 넘기세요"
        case .gitRunning(let operation): return "git 명령(\(operation))을 실행하는 중입니다 — 끝난 뒤에 넘기세요"
        case .worktreeOperation(let kind): return "독립 작업 폴더를 \(kind) 중입니다 — 끝난 뒤에 넘기세요"
        case .worktreeMissing(let problem): return problem
        }
    }

    /// 자동 전송이 이 막힘에 걸려 넘기지 않았을 때 카드에 남기는 까닭 — **지난 일**로 적는다. 막힘이 풀린 뒤에도 카드에 남으므로
    /// 현재형("…하는 중입니다")으로 굳히지 않는다. 지금의 막힘은 카드 바닥의 막힘 줄이 따로 말한다.
    var automaticSkipReason: String {
        switch self {
        case .running: return "보내려던 때 이 대화에서 에이전트가 실행 중이라 자동으로 넘기지 않았습니다"
        case .starting: return "보내려던 때 에이전트 실행을 시작하는 중이어서 자동으로 넘기지 않았습니다"
        case .reviewing: return "보내려던 때 자동 작업의 검토가 이 폴더를 읽고 있어 자동으로 넘기지 않았습니다"
        case .gitRunning(let operation): return "보내려던 때 git 명령(\(operation))이 돌고 있어 자동으로 넘기지 않았습니다"
        case .worktreeOperation(let kind): return "보내려던 때 독립 작업 폴더를 \(kind) 중이어서 자동으로 넘기지 않았습니다"
        case .summarizing, .remaking, .antigravityRefreshing:
            return "보내려던 때 초안 · 모델 목록을 확인하는 중이어서 자동으로 넘기지 않았습니다"
        case .stale, .receiverAccountMissing, .sameAccount, .receiverUnavailable, .antigravityNotAllowed, .antigravity,
             .unterminated, .worktreeMissing:
            return "자동으로 넘기지 않았습니다 — " + message
        }
    }
}

/// 대화의 인계가 어디쯤인가 — 준비 · 카드 · 전달 중 (`AppModel.handoffStage`). 이어 가기(칩 · 제안)와 진입점이 묻는다.
enum HandoffStage: Equatable, Sendable {
    case preparing, card, delivering
}

/// 준비가 끝나기 전에 그 대화에서 실행이 시작돼 버린 초안 — 카드 자리에 "다시 만들기" 를 둔다.
struct OutdatedHandoff: Equatable, Sendable {
    var target: HandoffSource.Agent
    var origin: HandoffCard.Origin
}

// MARK: - 대기열 보류 (C2)

/// 카드(준비 중 · 전달 중 포함)가 있는 대화의 대기열은 인계 뒤에 받는 쪽에게 간다 — 그때까지 보내지 않는다.
/// 멈춤 이유(`AppModel.queuePauseReasons`)와 따로다: 보류가 풀리면 받는 쪽에게 이어 보내거나(전달됨) 멈춤 이유로 바뀐다.
struct QueueHold: Equatable, Sendable {
    var source: HandoffSource.Agent
    var target: HandoffSource.Agent
}

/// 전달 실행이 도는 인계. 카드는 사라지고 스트림의 인계 줄이 이어받는다 — 입력창은 받는 쪽을 보이고 보류가 유지된다.
/// 전달 상태가 정해지면(`AppModel.resolveDelivery`) 칩을 옮기거나(전달됨) 카드를 되살린다(실패 · 미확인).
struct DeliveringHandoff: Sendable {
    var handoffID: String
    var source: HandoffSource.Agent
    var target: HandoffSource.Agent
    /// 실패 · 미확인이면 되살릴 카드 (같은 행 · 같은 localToken).
    var card: HandoffCard
    /// Antigravity 의 고르지 않은 모델을 채운 값 — 전달이 확인될 때 대화에 남긴다.
    var filledModel: String?
    var runID: String?
}

/// 대기열 보류를 푼 까닭 — 멈춤 이유의 문장을 정한다.
enum QueueHoldRelease: Equatable, Sendable {
    /// 전달이 확인됐다 — 받는 쪽에게 이어 보낸다 (멈춤 이유 없음).
    case delivered
    /// 카드를 취소했다.
    case cancelled
    /// 전달 여부 미확인 카드를 닫았다.
    case unknownClosed
    /// 초안을 만들지 못했다.
    case preparationFailed
    /// 앱 종료로 전달 실행이 끊겼다 (전달은 확인됨).
    case quitDuringDelivery
    /// 전달은 확인됐는데 그 사이 받는 Codex 계정의 등록이 해제됐다 (계정 이름) — 칩을 옮기지 않는다.
    case receiverRemoved(String)
}

/// 카드가 사라진 뒤 온 알림의 [자동 인계 취소] — 되돌릴 수 없다 (`AppModel.lateNotificationCancel`).
enum HandoffLateCancel: Equatable, Sendable {
    /// 전달 실행이 도는 중.
    case sending
    /// 이미 넘겼다.
    case delivered

    var title: String {
        switch self {
        case .sending: return "이미 보내는 중입니다"
        case .delivered: return "이미 넘겼습니다"
        }
    }
}

// MARK: - 카드가 말할 글

/// 화면 글 — 문장 하나 = 형식 문자열 하나, 조사는 이름에 따라 바뀌지 않는 꼴("에게" · 쌍점).
enum HandoffCardText {
    /// 받는 쪽 · 보내는 쪽 이름 ("Codex · 둘째 계정").
    static func partyName(_ agent: HandoffSource.Agent, accountLabel: String?) -> String {
        HandoffPacket.partyName(agent.provider, agent.provider == .codex ? accountLabel : nil)
    }

    /// 카드 머리 (origin). `reset` 은 초기화 사실 (`resetPhrase` — "20:30 초기화"), 모르면 nil ("초기화 시각 미확인").
    /// `folded`(접힌 카드)면 한도 머리는 초기화 구절을 빼고 짧게 — 좁은 칸에서 구절 중간에서 꺾이지 않게 (펼치면 보인다).
    static func headline(origin: HandoffCard.Origin, source: String, target: String, reset: String?,
                         folded: Bool = false) -> String {
        switch origin {
        case .limitReached:
            if folded { return "\(source) 사용 한도 도달" }
            return "\(source) 사용 한도에 닿았습니다 · \(reset ?? unknownReset)"
        case .suggestion(_, let peak, let label):
            // 사용률만으로는 무엇을 하는 카드인지 모른다 — 받는 쪽과 동사까지 (접힌 카드는 짧게).
            let percent = Int((peak * 100).rounded())
            let usage = label.map { $0.isEmpty ? "\(source) 사용률 \(percent)%" : "\(source) \($0) 사용률 \(percent)%" }
                ?? "\(source) 사용률 \(percent)%"
            return folded ? usage : "\(usage) — \(target) 에게 이어 맡깁니다"
        case .manual, .chip:
            return "\(target) 에게 이어서 맡깁니다"
        }
    }

    static let unknownReset = "초기화 시각 미확인"
    /// 스냅샷은 초기화 시각을 모르는데 CLI 의 한도 문구에는 시각이 적혀 있다 — "미확인" 이라 하지 않고 그 원문을 가리킨다.
    static let resetInSourceText = "초기화 시각은 원문 참고"

    /// 한도 문구(CLI 원문)가 초기화 시각을 말하는가 — 시각을 지어 읽지 않고 말하는지만 본다 (형식이 CLI 마다 다르다).
    static func mentionsReset(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        let lower = text.lowercased()
        return ["reset", "try again", "초기화", "다시 시도"].contains { lower.contains($0) }
            || lower.range(of: #"\b\d{1,2}(:\d{2})?\s?(am|pm)\b"#, options: .regularExpression) != nil
    }

    /// 초기화 사실 — 앱이 시각을 모르는데 원문이 시각을 말하면 원문을 가리킨다 (같은 줄에서 "미확인" 과 원문의 시각이 다투지 않게).
    static func resetPhrase(_ phrase: String, rawText: String?) -> String {
        phrase == unknownReset && mentionsReset(rawText) ? resetInSourceText : phrase
    }

    /// 좁은 칸에서 이름과 조사가 갈려 줄이 꺾이지 않게 — "Codex 에게" 의 공백을 줄바꿈 없는 공백으로 (화면에서만, 글은 그대로).
    static func keepingParticle(_ text: String) -> String {
        text.replacingOccurrences(of: " 에게", with: "\u{00A0}에게")
    }

    /// 한도 도달의 초기화 사실 — 한도 줄 · 카드 머리가 같은 형식 하나로 쓴다.
    /// - `current`: 지금 스냅샷의 다 찬 계정 전체 창이 풀리는 시각 (`LimitSnapshot.capResetsAt` — 늘 앞으로의 시각). 있으면 이것이 이긴다.
    /// - `fixed`: 카드를 만들 때 적어 둔 시각 (origin). 지금 스냅샷에 다 찬 창이 없을 때만 쓴다 — 지났으면 지난 사실로 적는다.
    /// - `releasedSince`: 한도에 닿은 뒤 풀렸다는 근거가 있다 (`released` — 이미 풀렸다, "미확인" 이 아니다).
    static func resetPhrase(current: Date?, fixed: Date?, releasedSince: Bool, now: Date = Date()) -> String {
        if let current { return "\(resetClock(current, now: now)) 초기화" }
        if let fixed, fixed <= now { return "\(resetClock(fixed, now: now)) 에 초기화됨" }
        if releasedSince { return "한도 풀림" }
        if let fixed { return "\(resetClock(fixed, now: now)) 초기화" }
        return unknownReset
    }

    /// 한도에 닿은 뒤(`since`) 한도가 풀렸다는 **근거**가 있는가. 다 찬 창이 안 보인다는 것만으로는 풀림이 아니다 — Codex 는 100% 전
    /// (98% 등)에도 `usageLimitExceeded` 를 내서, 아직 막혀 있는데 "한도 풀림" 이 떴다. 근거는 둘:
    /// - 그 뒤 같은 계정의 실행이 성공했다 (`laterSuccess` — 부르는 쪽이 실행 기록으로 안다).
    /// - 한도에 닿은 뒤 새로 읽은 스냅샷에서 계정 전체 창 하나가 **한도 시각 뒤에 다시 시작했고**(초기화 시각 − 창 길이 > `since`,
    ///   또는 적힌 초기화 시각이 한도 시각과 읽은 때 사이로 이미 지났다), 다시 시작하지 않은 창 가운데 거의 찬 것(`nearFull` 이상)이
    ///   없다 — 주간 창이 98% 면 5시간 창이 새로 시작해도 막혀 있다.
    /// 근거가 없으면 false — 부르는 쪽은 초기화 시각 · "원문 참고" · "미확인" 으로 적는다.
    static func released(_ snapshot: LimitSnapshot, since: Date, laterSuccess: Bool = false) -> Bool {
        if laterSuccess { return true }
        guard let fetchedAt = snapshot.fetchedAt, fetchedAt > since, snapshot.status == .ok, snapshot.hasUsableData,
              !snapshot.reachedAccountWideCap else { return false }
        let accountWide = snapshot.windows.filter { $0.model == nil }
        func restarted(_ window: LimitWindow) -> Bool {
            guard let resetsAt = window.resetsAt else { return false }
            if resetsAt > since && resetsAt <= fetchedAt { return true }
            guard let span = window.spanMinutes, span > 0 else { return false }
            return resetsAt.addingTimeInterval(-Double(span) * 60) > since
        }
        guard accountWide.contains(where: restarted) else { return false }
        return !accountWide.contains { !restarted($0) && ($0.utilization ?? 0) >= nearFull }
    }

    /// 이만큼 찬 창은 막고 있을 수 있다 (Codex 가 98% 에서 한도 오류를 냈다).
    static let nearFull = 0.9

    /// 초기화 시각 — 오늘이면 "20:30", 아니면 "10월 2일 20:30".
    static func resetClock(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? clock.string(from: date) : dayClock.string(from: date)
    }

    /// 카운트다운 카드의 머리 아래 줄 — 남은 초는 링이 센다 (같은 수를 두 번 보이지 않는다).
    static func countdownSubline(target: String) -> String { "카운트다운이 끝나면 \(target) 에게 넘깁니다" }

    /// 카운트다운 문장 — "9초 뒤 Codex 에게 넘깁니다" (알림 제목).
    static func countdown(seconds: Int, target: String) -> String { "\(seconds)초 뒤 \(target) 에게 넘깁니다" }

    /// 카운트다운 카드가 나타날 때 알리는 문장 (접근성).
    static func announcement(seconds: Int, target: String) -> String { "자동 인계: \(seconds)초 뒤 \(target) 에게 넘깁니다" }

    /// 입력창 위 한 줄 — 자동 카드가 생겼는데 사람이 위로 올려 읽는 중이라 따라가지 않았을 때 (`HandoffPeekLine`).
    static func peekCountdown(seconds: Int) -> String { "자동 인계 \(seconds)초 · 보기" }
    static let peekReview = "인계 검토 필요 · 보기"

    /// 머리 아래 한 줄 — 단계 · 검토 까닭. 카운트다운은 `countdown` 이 따로 말한다.
    static func subline(_ card: HandoffCard, target: String) -> String? {
        switch card.phase {
        case .sending: return "\(target) 에게 보내는 중…"
        case .unknown: return unknownCheck(target: target)
        case .failed(let reason): return "보내지 못했습니다 — \(reason)"
        case .countingDown: return nil
        case .ready: break
        }
        switch card.review {
        case .automaticBlocked(let reasons)?:
            // "아래 이유" 는 이유가 실제로 그려질 때만 (접힌 카드는 첫 이유를 보인다).
            return reasons.isEmpty ? "자동으로 넘기지 않았습니다 — 내용을 확인하고 넘기세요"
                                   : "자동으로 넘기지 않았습니다 — 아래 이유를 확인하고 넘기세요"
        case .pausedByHuman?: return "자동 인계를 멈췄습니다 — 내용을 확인하고 넘기세요"
        case .deliveryFailed(let reason)?: return "보내지 못했습니다 — \(reason)"
        case .accountRemoved(let name)?: return "받는 계정(\(name))의 등록이 해제됐습니다 — 받는 쪽을 바꾸세요"
        case .stale(let reason)?: return reason
        case nil: return nil
        }
    }

    // 전달 여부 미확인 카드 — 받는 쪽은 같은 대화 안에서 일한다. 사람이 앱 안에서 할 수 있는 확인과 다음 행동을 적는다
    // ("받는 쪽 세션" 처럼 앱에서 열 수 없는 것을 가리키지 않는다). 같은 상대는 "받는 쪽" 하나로 부른다.
    /// 머리 — 한도 · 제안 이야기보다 이것이 먼저다.
    static func unknownHeadline(target: String) -> String { "\(target) 에게 전달됐는지 확인하지 못했습니다" }
    /// 머리 아래 — 확인하는 방법.
    static func unknownCheck(target: String) -> String {
        "이 대화 위쪽에 \(target) 의 응답이 있으면 전달된 것입니다 — 없으면 [\(remakeUnknownTitle)] 로 다시 이어 맡기세요"
    }
    static let remakeUnknownTitle = "닫고 다시 만들기"
    static let remakeUnknownHelp = "이 카드를 닫고 같은 받는 쪽으로 인계 카드를 새로 만듭니다 — 받는 쪽의 응답이 대화에 없을 때만 쓰세요 (받았다면 같은 내용이 두 번 갑니다)."

    /// 앱 종료를 묻는 중 · 종료하는 중이라 보내지 않았다 (`AppModel.suspendHandoffsForQuit`).
    static let quitSuspendedReason = "앱을 종료하는 중이라 보내지 않았습니다"

    /// 낡은 카드의 까닭 (`Review.stale`).
    static let staleReason = "초안 이후 폴더 · 파일 상태가 바뀌었습니다 — 다시 만들기"
    /// 준비가 끝나기 전에 대화가 진행돼 초안을 버렸다 (카드 자리).
    static let preparationOutdated = "초안 이후 대화가 진행됐습니다 — 다시 만들기"

    static func sendTitle(target: String) -> String { "\(target) 에게 넘기기" }
    static let sendNowTitle = "지금 넘기기"
    static let pauseTitle = "멈추기"
    static let editTitle = "문서 열어 고치기"
    static let editCloseTitle = "문서 닫기"
    static let geminiTitle = "Gemini 로 다시 정리"
    static let geminiRunningTitle = "Gemini 가 정리하는 중…"
    static let cancelTitle = "취소 (넘기지 않음)"
    /// 보통 카드를 지우는 동작의 도움말 — 이름은 "취소" 하나 (칩 메뉴 · 카드 · 작업 폴더 막힘이 같은 동사). "닫기" 는 전달 여부 미확인 카드 전용.
    static let cancelHelp = "인계 카드를 취소합니다 — 넘기지 않고, 걸어 둔 메시지는 멈춘 채로 남습니다."
    /// 전달 여부 미확인 카드의 [닫기] 도움말.
    static let closeUnknownHelp = "전달 여부를 확인하지 못한 인계 카드를 닫습니다 — 걸어 둔 메시지는 멈춘 채로 남습니다."
    static let closeTitle = "닫기"
    static let remakeTitle = "다시 만들기"
    static let changeTitle = "바꾸기"
    static let confirmTitle = "내용을 확인했습니다"
    static let expandTitle = "펼치기"
    static let expandToConfirmTitle = "펼쳐서 확인"
    static let collapseTitle = "접기"
    static let editedNote = "직접 고친 문서를 보냅니다"
    static let preparingText = "인계 초안을 만드는 중…"

    // 키보드로 확인하고 넘기기 (⇧⌘H 로 카드에 오면 덧붙일 말 칸에 포커스가 온다 — ⌘↵ 한 번이 확인, 한 번 더가 넘기기).
    static let confirmKeyHint = "⌘↵ 로 확인"
    static let confirmKeyHelp = "카드 안에 포커스가 있으면 ⌘↵ 로 이 확인을 체크하고, 한 번 더 누르면 넘깁니다"
    static func confirmedAnnouncement(target: String) -> String { "내용을 확인했습니다 — ⌘↵ 를 한 번 더 누르면 \(target) 에게 넘깁니다" }

    static func memoPlaceholder(target: String, countingDown: Bool) -> String {
        countingDown ? "\(target) 에게 덧붙일 말 (선택) — 쓰기 시작하면 카운트다운이 멈춥니다"
                     : "\(target) 에게 덧붙일 말 (선택)"
    }

    /// 다음 행동을 앱이 찾지 못했는데 덧붙일 말도 비었다 — [넘기기] 곁에 (받는 쪽은 문서만 보고는 무엇을 할지 모른다).
    static let noTaskHint = "할 일을 적지 않으면 받는 쪽이 지시를 기다립니다 — 덧붙일 말에 적어 주세요"

    // 입력창에 걸어 둔 메시지를 할 일로 (다음 행동을 앱이 찾지 못했을 때 — 할 일을 적을 곳을 하나로).
    static func heldMessagesNote(count: Int) -> String {
        count == 1 ? "입력창에 걸어 둔 메시지가 있습니다 — 인계와 함께 할 일로 보낼 수 있습니다"
                   : "입력창에 걸어 둔 메시지 \(count)개가 있습니다 — 인계와 함께 할 일로 보낼 수 있습니다"
    }
    static let moveHeldToMemoTitle = "덧붙일 말로 옮기기"
    static let moveHeldToMemoHelp = "걸어 둔 메시지를 덧붙일 말 칸으로 옮깁니다 — 인계 문서와 함께 한 번에 가고, 따로 한 턴을 쓰지 않습니다 (이미지가 붙은 메시지는 그대로 둡니다)."

    /// 넘기면 무엇이 일어나는가 — 받는 쪽이 곧바로 일을 시작한다 (승인 방식과 함께, 받는 쪽 이름 없이 — 조사가 이름에 따라 바뀌지 않게).
    static func startsImmediately(policy: String) -> String {
        "넘기면 받는 쪽이 문서의 다음 행동을 바로 시작합니다 · 승인: \(policy)"
    }

    /// 문서 머리 — "Codex 에게 가는 문서 · 앱이 정리 · 약 1.2k 토큰". 정리한 쪽의 이름은 설정 > 인계와 같은 말.
    static func documentHeader(target: String, gemini: Bool, tokens: String) -> String {
        gemini ? "\(target) 에게 가는 문서 · Gemini 정리 · 앱 근거 검증 · 약 \(tokens) 토큰"
               : "\(target) 에게 가는 문서 · 앱이 정리 · 약 \(tokens) 토큰"
    }

    // [Gemini 로 다시 정리] 를 쓸 수 없을 때 (단추는 숨기고 필요한 경우만 한 줄).
    static let geminiNoCLI = "Gemini 로 다시 정리할 수 없습니다 — Antigravity CLI(agy)를 찾지 못했습니다 (설정 > 에이전트)"
    static let geminiProjectExcluded = "Gemini 로 다시 정리할 수 없습니다 — 이 프로젝트는 Gemini 전송을 껐습니다 (프로젝트 설정)"
    static let geminiHelp = "기록의 비밀값을 최선 노력으로 가려 Gemini 로 다시 정리합니다. 정리하지 못하면 지금 문서를 그대로 둡니다."
    static let geminiReplacesEditsHelp = "고친 문서가 Gemini 정리본으로 바뀝니다 — 덧붙인 말은 남고, 바뀐 문서는 다시 확인해야 넘길 수 있습니다."
    /// 정리가 실패했다 — 문서는 그대로다.
    static func geminiFailed(_ reason: String) -> String { "Gemini 로 정리하지 못했습니다 — 지금 문서를 그대로 둡니다: \(reason)" }

    static func session(_ session: HandoffCard.Session, target: String) -> String {
        switch session {
        case .resumes: return "이 대화의 \(target) 세션을 이어 갑니다"
        case .fresh: return "새 세션에서 이 문서로 시작합니다"
        }
    }

    /// 받는 쪽 사실 한 칸. `good` 이면 ✓ 를 붙일 수 있는 확인된 사실, `bad` 면 문제, 둘 다 아니면 모름.
    struct Fact: Equatable, Sendable {
        enum Tone: Equatable, Sendable { case good, bad, unknown }
        var text: String
        var tone: Tone
    }

    /// 로그인 사실 — 확인한 때와 함께. Antigravity 는 로그인 상태를 알려 주지 않아 nil.
    static func loginFact(provider: AgentProvider, authenticated: Bool?, checkedAt: Date?, now: Date = Date()) -> Fact? {
        guard provider != .gemini else { return nil }
        switch authenticated {
        case true?:
            if let checkedAt { return Fact(text: "로그인 확인 · \(ChangesState.relativeTime(checkedAt, now: now))", tone: .good) }
            return Fact(text: "로그인 확인", tone: .good)
        case false?:
            if let checkedAt { return Fact(text: "로그인 안 됨 · \(ChangesState.relativeTime(checkedAt, now: now)) 확인", tone: .bad) }
            return Fact(text: "로그인 안 됨", tone: .bad)
        case nil:
            return Fact(text: "로그인 확인 안 됨", tone: .unknown)
        }
    }

    /// 한도 사실 — 계정 전체 창 중 가장 많이 쓴 사용률과 확인한 때 (이미 초기화된 창은 빼고). Antigravity 는 받는 모델의 묶음만 남긴
    /// 스냅샷을 넘긴다 (`LimitSnapshot.scoped(toAntigravityModel:)` — 묶음 창은 계정 전체 창이 아니라 그대로면 "한도 정보 없음" 이다).
    /// ✓ 는 여유가 있을 때만 — 이어 가기 제안이 권하는 문턱(짧은 창 75%) 이상이면 곧 닿을 쪽이라 경고로 (95% 에 ✓ 를 붙이지 않는다).
    static func limitFact(provider: AgentProvider, limit: LimitSnapshot?, now: Date = Date()) -> Fact? {
        guard let limit, let fetchedAt = limit.fetchedAt else { return Fact(text: "한도 정보 없음", tone: .unknown) }
        let age = ChangesState.relativeTime(fetchedAt, now: now)
        if limit.status == .subscriptionCap || limit.status == .throttled || limit.reachedAccountWideCap {
            return Fact(text: "한도 도달 · \(age) 확인", tone: .bad)
        }
        let peak = ContinueSuggestion.accountWidePeak(limit, now: now)
        guard limit.status == .ok, let peak else { return Fact(text: "한도 정보 없음", tone: .unknown) }
        let text = "사용률 \(Int((peak * 100).rounded()))% · \(age) 확인"
        return Fact(text: text, tone: peak >= LimitSpan.short.threshold ? .bad : .good)
    }

    /// 받는 쪽 Claude 가 이 대화의 API 크레딧으로 받는다 (로그인 · 한도 사실 대신).
    static let apiCreditFact = Fact(text: "API 크레딧으로 받음", tone: .good)

    static func cliFact(provider: AgentProvider, usable: Bool?) -> Fact? {
        guard usable == false else { return nil }
        return Fact(text: "\(provider.displayName) CLI 를 실행할 수 없음", tone: .bad)
    }


    // MARK: 입력창 (C2)

    static let composerChipNote = "인계 대기"
    /// 보류 중 칩의 도움말 — 받는 쪽을 지금 바꿀 수 있을 때만 바꾸는 곳을 말한다 (준비 · 보내는 중 · 전달 중 · 재정리 중에는 바꿀 곳이 없다).
    static func composerChipHelp(target: String, changeable: Bool) -> String {
        changeable ? "인계가 끝나면 다음 메시지는 \(target) 에게 갑니다 — 받는 쪽은 대화 끝의 카드나 이 메뉴에서 바꿉니다."
                   : "인계를 준비하거나 보내는 중입니다 — 끝나면 다음 메시지는 \(target) 에게 갑니다."
    }
    static func composerPlaceholder(target: String) -> String { "인계가 끝나면 \(target) 에게 이어서 보냅니다…" }
    /// 자동 인계 카운트다운 중의 자리 글 — 걸면 카운트다운이 멈추고 사람 확인 길로 간다 (덧붙일 말 칸이 미리 알리는 것과 같다).
    static func countdownComposerPlaceholder(target: String) -> String {
        "보내면 자동 인계가 멈추고, 카드에서 확인해 넘긴 뒤 \(target) 에게 이어서 보냅니다…"
    }
    static func queueHeader(target: String) -> String { "\(target) 에게 인계한 뒤 보냅니다" }

    // 넘긴 뒤 받는 쪽이 인계 문서로 일하는 동안 (`AppModel.deliveringHandoffs`) — 준비 · 카드 단계와 구분한다. 받는 쪽이 이미 일하고 있다.
    static let composerDeliveringNote = "인계받아 일하는 중"
    static func composerDeliveringHelp(target: String) -> String {
        "\(target) 에게 인계를 넘겼고, 인계 문서로 일하는 중입니다 — 끝나면 걸어 둔 메시지를 이어서 보냅니다."
    }
    static func deliveringComposerPlaceholder(target: String) -> String {
        "\(target) 에게 넘긴 인계가 끝나면 이어서 보냅니다…"
    }
    static func deliveringQueueHeader(target: String) -> String { "\(target) 에게 넘긴 인계가 끝나면 보냅니다" }

    // 전달 여부 미확인 카드 — 이 카드로는 인계가 끝나지 않는다. 받는 쪽에게 간다고 약속하지 않고 사실만 적는다.
    static let unknownChipNote = "인계 전달 미확인"
    static let unknownComposerPlaceholder = "인계가 전달됐는지 확인하지 못했습니다 — 대화 끝의 카드를 닫으면 걸어 둔 메시지는 멈춥니다…"
    static let unknownQueueHeader = "인계 전달 미확인 — 대화 끝의 카드를 닫으면 멈춥니다"
    static let unknownChipHelp = "인계가 전달됐는지 확인하지 못했습니다 — 이 대화에 받는 쪽의 응답이 있는지 본 뒤 대화 끝의 카드를 닫으세요. "
        + "걸어 둔 메시지는 그때 멈춥니다."

    /// 보류를 푼 뒤의 멈춤 이유 — 앞 문장은 풀린 까닭, 뒤 문장은 이어서 보내면 받을 지금 칩. "맥락 없이" 는 까닭이 아니라
    /// 칩이 이 대화의 맥락을 가졌는지(`chipHasContext` — 칩이 보내는 쪽이다 · 인계를 받았다)로 붙인다.
    static func pauseReason(_ release: QueueHoldRelease, chip: String, chipHasContext: Bool) -> String? {
        let why: String
        switch release {
        case .delivered: return nil
        case .cancelled: why = "인계를 취소했습니다"
        case .unknownClosed: why = "전달 여부를 확인하지 못한 인계를 닫았습니다"
        case .preparationFailed: why = "인계 초안을 만들지 못했습니다"
        case .quitDuringDelivery: why = "앱 종료로 전달 실행이 끊겼습니다"
        case .receiverRemoved(let label): why = "받는 Codex 계정(\(label))의 등록이 해제됐습니다"
        }
        return why + " — " + continuation(chip: chip, chipHasContext: chipHasContext)
    }

    /// 앱을 다시 켰을 때 보류였던 대기열의 멈춤 이유. `chipHasContext` — 칩에게 이 대화에서 이어 갈 세션이 있다.
    static func relaunchPauseReason(chip: String, chipHasContext: Bool) -> String {
        "인계 카드가 사라졌습니다 — " + continuation(chip: chip, chipHasContext: chipHasContext)
    }

    private static func continuation(chip: String, chipHasContext: Bool) -> String {
        chipHasContext ? "이어서 보내면 \(chip) 에게 갑니다" : "이어서 보내면 \(chip) 에게 맥락 없이 갑니다"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayClock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 HH:mm"
        return f
    }()
}

// MARK: - 요약 (받는 문서의 절 순서)

/// 카드의 요약 — 받는 쪽 문서의 절 순서 그대로: 다음 행동 · 목표 · 파일 상태 · 테스트 · 확인 필요.
/// 앱이 모르는 것은 "확인 필요" 로 — 안심 문장을 짓지 않는다.
enum HandoffCardSummary {
    struct Row: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case nextAction, goal, files, tests, unverified }
        var kind: Kind
        var text: String
        /// 확인 필요 — 황색.
        var warn = false

        var label: String {
            switch kind {
            case .nextAction: return "다음 행동"
            case .goal: return "목표"
            case .files: return "파일 상태"
            case .tests: return "테스트"
            case .unverified: return "확인 필요"
            }
        }
    }

    /// 문서마다 들어가는 고정 문장 — 카드의 "확인 필요" 줄에서 뺀다 (받는 문서에는 그대로 남는다).
    static let fixedUnverified: Set<String> = [
        "각 변경의 의도와 설계 근거는 앱이 판단할 수 없습니다. 필요하면 사용자가 보완하세요.",
        "이 구간에서 앱이 관찰한 테스트 실행 기록이 없습니다. (테스트를 실행했는지 여부는 미확인)",
    ]

    /// 다음 행동을 앱이 찾지 못했다 (패킷의 다음 행동이 "미확인" 하나뿐).
    static func nextActionUnknown(_ packet: HandoffPacket) -> Bool {
        !packet.nextActions.contains { !$0.hasPrefix("미확인") }
    }

    /// `memo` — 카드의 덧붙일 말. 다음 행동을 앱이 찾지 못했어도 덧붙인 말이 있으면 그것이 할 일이다 (문서에서도 그 자리를 가리킨다).
    static func rows(_ packet: HandoffPacket, memo: String = "") -> [Row] {
        var rows: [Row] = []
        let actions = packet.nextActions.filter { !$0.hasPrefix("미확인") }.map(clean)
        if let first = actions.first {
            rows.append(Row(kind: .nextAction, text: actions.count > 1 ? "\(first) 외 \(actions.count - 1)개" : first))
        } else if !memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows.append(Row(kind: .nextAction, text: "덧붙인 말을 할 일로 보냅니다"))
        } else {
            rows.append(Row(kind: .nextAction, text: "다음 행동을 앱이 찾지 못했습니다 — 덧붙일 말로 알려 주세요", warn: true))
        }
        let goalNotSet = packet.goal.hasPrefix("미확인") || packet.goal == HandoffPacketBuilder.goalNotSet
        rows.append(Row(kind: .goal, text: goalNotSet ? "목표를 적지 않았습니다 — 대화의 맥락과 파일 상태로 이어 갑니다" : packet.goal))
        rows.append(Row(kind: .files, text: files(packet.changedFiles), warn: packet.changedFiles.error != nil))
        if let last = packet.testsRun.last {
            rows.append(Row(kind: .tests, text: clean(last)))
        } else {
            rows.append(Row(kind: .tests, text: "관찰된 테스트 실행 기록 없음"))
        }
        let unverified = packet.unverified.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // 고정 문장(모든 문서에 들어간다)은 세지도 보이지도 않는다 — 판단할 것이 없는 카드에 황색 줄이 붙지 않게.
        let unique = unverified.filter { !fixedUnverified.contains($0) }
        if let first = unique.first {
            rows.append(Row(kind: .unverified, text: unique.count > 1 ? "\(unique.count)개 — \(first)" : first, warn: true))
        }
        return rows
    }

    /// 파일 상태 한 줄 — "8개 바뀜, 커밋 안 함 — a.swift · b.swift · c.swift 외 5개".
    /// git 을 돌리지 못했으면(Command Line Tools 가 없어 shim 을 고르지 않음 · status 실패) 저장소가 아니라고 단정하지 않는다 —
    /// 변경사항 탭과 같다.
    static func files(_ git: GitSnapshot) -> String {
        if let error = git.error {
            let reason = error.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return "Git 상태를 읽지 못함 — \(reason)"
        }
        guard git.isRepository else {
            return git.recentlyModified.isEmpty ? "Git 저장소가 아님 — 최근 수정 파일 없음"
                                                : "Git 저장소가 아님 — 최근 수정 파일 \(git.recentlyModified.count)개"
        }
        var seen = Set<String>()
        let paths = (git.staged + git.unstaged).map { String($0.dropFirst(2)) } + git.untracked
        let unique = paths.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return "바뀐 파일 없음" }
        let names = unique.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: " · ")
        if unique.count > 3 { return "\(unique.count)개 바뀜, 커밋 안 함 — \(names) 외 \(unique.count - 3)개" }
        return "\(unique.count)개 바뀜, 커밋 안 함 — \(names)"
    }

    /// 초안의 출처 표시 머리말을 벗긴다. 인계가 여러 번 이어지면 머리말이 겹쳐 붙으므로 반복해서 벗긴다.
    static func clean(_ value: String) -> String {
        let prefixes = ["아직 처리되지 않은 사용자 지시: ", "이어서 처리 필요: ", "사용자 지시: ", "파일 변경 적용됨(관찰): ",
                        "(이전 인계의 다음 행동) ", "(이전 인계) ", "실행됨(관찰): "]
        var text = value
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                changed = true
            }
        }
        return text
    }
}
