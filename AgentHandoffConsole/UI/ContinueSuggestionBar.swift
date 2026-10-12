import SwiftUI

/// 한도 임박 "이어 가기" 제안 자리 (B 설계 C4) — 포커스 칸의 입력창 바로 위 (자동 작업 카드와 같은 자리, 둘은 함께 뜨지 않는다).
/// 판정은 순수 `ContinueSuggestion.evaluate`, 사실 모으기는 `AppModel.continueSuggestion`. 60초마다 다시 판정한다 — 확인한 지
/// 30분 · 초기화 시각 · "나중에" 가 지나면 사라지거나 다시 보인다. 판정이 대상의 한도 · 로그인이 오래돼 판단하지 못했다고
/// 하면 새로 읽기를 부른다 (`AppModel.refreshStaleContinueTargets` — 한도는 강제 아닌 새로 읽기, 로그인은 로그인만, 같은 대상은 5분에 한 번).
/// 제안이 없으면 높이 0 의 자리만 둔다 (입력창 위 간격을 만들지 않는다 — 간격은 줄이 스스로 갖는다).
struct ContinueSuggestionSlot: View {
    @Environment(AppModel.self) private var model
    let thread: ConversationThread
    /// 좁은 칸 (네 칸) — 짧은 글 · 단추 하나부터 맞춰 본다.
    let compact: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let evaluation = model.continueSuggestion(for: thread, now: context.date)
            Group {
                if let suggestion = evaluation.suggestion {
                    ContinueSuggestionBar(thread: thread, suggestion: suggestion, compact: compact, now: context.date)
                        .padding(.bottom, 8)
                } else {
                    Color.clear.frame(height: 0)
                }
            }
            .task(id: evaluation.stale) { model.refreshStaleContinueTargets(evaluation.stale) }
        }
    }
}

/// 제안 한 줄 — 로고 · "Claude 5시간 사용률 81% · 20:30 초기화"(시각을 모르면 "초기화 시각 미확인") · 사용률 막대 · [나중에] ·
/// [API 크레딧으로 계속] · [Codex 에게 이어 맡기기]. 이어 맡기기는 규칙 초안 카드(origin `.suggestion`)를 대화 끝에 놓는다 — 넘기기
/// 전에는 아무것도 실행되지 않는다. 대상이 같은 Codex 의 다른 계정이면 [Codex · 계정 2 에서 이어 가기] — 칩(계정)만 바꾼다
/// (`AppModel.switchCodexAccount`, 같은 세션). API 크레딧은 이 대화의 "API 크레딧으로 실행" 을 켜기만 한다 (`AppModel.switchToClaudeAPI` —
/// 같은 Claude 세션, 다음 메시지부터). 둘 중 권할 수 있는 것만 보인다 (`ContinueSuggestion.target` · `offersAPICredit`).
/// 색은 사용률 막대만 앰버 (주의 정도의 약한 강조), 줄 바탕은 보통 카드 (색은 판단이 필요한 것에만).
/// 좁으면 짧은 글(`shortHeadline`) → 단추들(+ 닫기 기호) → 단추 하나 순으로 줄인다 (`ViewThatFits`).
struct ContinueSuggestionBar: View {
    @Environment(AppModel.self) private var model
    let thread: ConversationThread
    let suggestion: ContinueSuggestion
    let compact: Bool
    let now: Date

    private var sourceName: String { model.handoffPartyName(suggestion.source) }
    /// 초기화 시각 — 카드 머리 · 한도 줄(`HandoffCardText.resetPhrase`)과 같은 `resetClock` 표기 (오늘이면 "20:30", 아니면 "10월 2일 20:30").
    /// 모르면 nil.
    private var resetText: String? { suggestion.window.resetsAt.map { HandoffCardText.resetClock($0, now: now) } }
    private var headline: String { suggestion.headline(sourceName: sourceName, resetText: resetText) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if !compact { line(headline, meter: 44) }
            line(suggestion.shortHeadline(sourceName: sourceName), meter: 28)
            if suggestion.target != nil && suggestion.offersAPICredit { minimal(both: true) }
            minimal(both: false)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hair))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("이어 가기 제안: \(headline)")
    }

    private func line(_ text: String, meter: CGFloat) -> some View {
        HStack(spacing: 9) {
            BrandMark(provider: suggestion.source.provider, size: 13)
            Text(text)
                .font(Theme.ui(.callout))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .fixedSize()
                .help(headline)
            LimitMeter(fraction: suggestion.utilization, width: meter, tint: Theme.amber)
            Spacer(minLength: 8)
            laterButton
            if suggestion.offersAPICredit { apiButton(compressible: false) }
            if suggestion.target != nil { actionButton(compressible: false) }
        }
    }

    /// 좁을 때 — 로고와 "사용률 81%" 만 (수가 잘리지 않게, 창 이름 · 초기화 시각은 도움말), [나중에] 는 닫기 기호로. `both` 가 아니면
    /// 단추 하나만 — 이어 맡길 대상이 있으면 그것 (API 크레딧은 모델 칩에서도 켤 수 있다).
    private func minimal(both: Bool) -> some View {
        HStack(spacing: 8) {
            BrandMark(provider: suggestion.source.provider, size: 13)
            Text(suggestion.usageText)
                .font(Theme.ui(.callout))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .fixedSize()
                .help(headline)
            Spacer(minLength: 6)
            // 마지막 단계라 더 좁으면 단추 글이 줄어든다 (수 · 닫기는 남는다).
            if both {
                apiButton(compressible: false)
                actionButton(compressible: false)
            } else if suggestion.target != nil {
                actionButton(compressible: true)
            } else {
                apiButton(compressible: true)
            }
            IconButton(systemName: "xmark", size: 10, help: "나중에 — \(laterHelp)") { dismiss() }
                .accessibilityLabel("나중에")
        }
    }

    private var laterButton: some View {
        Button("나중에") { dismiss() }
            .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
            .fixedSize()
            .help(laterHelp)
    }

    /// "나중에" 가 언제 끝나는지 — 이 제안에서 일어날 수 있는 조건만 (`ContinueSuggestion.laterHelp`).
    private var laterHelp: String { suggestion.laterHelp }

    private func actionButton(compressible: Bool) -> some View {
        let title = suggestion.actionTitle ?? ""
        return Button {
            Task { await model.acceptContinueSuggestion(suggestion, threadID: thread.id) }
        } label: {
            Text(HandoffCardText.keepingParticle(title)).lineLimit(1)
        }
        .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 11))
        .fixedSize(horizontal: !compressible, vertical: false)
        .help(actionHelp)
        .accessibilityLabel(title)
    }

    /// [API 크레딧으로 계속] — 이 대화의 "API 크레딧으로 실행" 을 켠다 (보낼 것은 없다 — 다음 메시지부터).
    private func apiButton(compressible: Bool) -> some View {
        Button {
            model.switchToClaudeAPI(threadID: thread.id)
        } label: {
            Text(ClaudeAPIContinue.title).lineLimit(1)
        }
        .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 11))
        .fixedSize(horizontal: !compressible, vertical: false)
        .help(ClaudeAPIContinue.switchHelp)
    }

    /// 단추의 도움말 — 무엇이 되는지 (앱이 정리한 문서의 카드 · 넘기기 전에는 아무것도 실행되지 않는다). 받는 쪽의 로그인을 확인하지
    /// 못했으면 그 사실도 (권하되 단정하지 않는다).
    private var actionHelp: String {
        if suggestion.switchesCodexAccount {
            return CodexAccountSwitch.suggestionHelp(name: suggestion.targetTitle, loginUnknown: suggestion.targetLoginUnknown)
        }
        let base = "현재 맥락을 \(suggestion.targetTitle) 에게 넘길 인계 문서(앱이 정리)를 대화 끝의 카드로 만듭니다. "
            + "내용을 확인하고 넘기기를 눌러야 전송됩니다."
        return suggestion.targetLoginUnknown ? base + " 받는 쪽의 로그인은 확인하지 못했습니다." : base
    }

    private func dismiss() {
        model.dismissContinueSuggestion(suggestion, now: Date())
    }
}
