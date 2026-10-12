import SwiftUI

/// 자동 인계가 같은 Codex 의 다른 계정을 골랐을 때의 카운트다운 줄 (입력창 위) — 인계 카드 대신. 울리면 그 계정으로 바꿔 같은 세션에
/// 이어 가기 메시지를 보낸다 (`AppModel+CodexSwitch`). [취소] · [지금 이어 가기]. 초는 레이어 시계(`CountdownText` — 1초마다 SwiftUI 를
/// 다시 그리지 않는다). 좁으면 앞의 "… 사용 한도 도달 —" 를 뺀다.
struct CodexSwitchCountdownLine: View {
    @Environment(AppModel.self) private var model
    let thread: ConversationThread
    let countdown: CodexAccountSwitch.Countdown

    var body: some View {
        let source = model.handoffPartyName(countdown.source)
        let target = model.handoffPartyName(countdown.target)
        HStack(spacing: 9) {
            BrandMark(provider: .codex, size: 13)
            ViewThatFits(in: .horizontal) {
                message(lead: CodexAccountSwitch.countdownLead(source: source), target: target)
                message(lead: nil, target: target)
            }
            Spacer(minLength: 8)
            Button(CodexAccountSwitch.cancelTitle) { model.cancelCodexSwitchCountdown(threadID: thread.id) }
                .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
                .fixedSize()
                .help(CodexAccountSwitch.cancelHelp)
            Button(CodexAccountSwitch.continueNowTitle) {
                Task { await model.continueCodexSwitchNow(threadID: thread.id) }
            }
            .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 11))
            .fixedSize()
            .help(CodexAccountSwitch.limitHelp(name: target))
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.approvalWell, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.approvalBorder))
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("자동으로 \(target) 에서 같은 세션 이어 가기 대기")
    }

    private func message(lead: String?, target: String) -> some View {
        HStack(spacing: 4) {
            if let lead { Text(lead) }
            CountdownText(deadline: countdown.deadline, step: .callout, color: Theme.amberText) { "\($0)초" }
                .fixedSize()
            Text(CodexAccountSwitch.countdownTail(target: target))
        }
        .font(Theme.ui(.callout))
        .foregroundStyle(Theme.ink2)
        .lineLimit(1)
        .fixedSize()
    }
}
