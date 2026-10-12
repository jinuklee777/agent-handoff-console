import SwiftUI

/// 대화 끝의 인계 자리 (B 설계 C1) — 스트림의 승인 · 질문(`pending`) 뒤, 바닥 여백 앞. 준비 중이면 한 줄, 준비가 지난 일이 됐으면
/// "다시 만들기", 카드가 있으면 카드. 상태 · 동작은 `AppModel+Handoff`, 값 · 글은 `App/HandoffCard.swift`.
struct HandoffCardSlot: View {
    @Environment(AppModel.self) private var model
    let thread: ConversationThread
    /// 칸이 작다 (네 칸) — 카드를 접어서 보인다.
    let compact: Bool

    var body: some View {
        if let card = model.handoffCards[thread.id] {
            HandoffCardView(thread: thread, card: card, compact: compact)
                .padding(.top, Theme.Metric.turnGap)
        } else if model.handoffPreparations[thread.id] != nil {
            preparing
                .padding(.top, Theme.Metric.turnGap)
        } else if model.handoffOutdated[thread.id] != nil {
            outdated
                .padding(.top, Theme.Metric.turnGap)
        }
    }

    private var preparing: some View {
        HStack(spacing: 9) {
            InkSpinner(color: Theme.slate)
            Text(HandoffCardText.preparingText)
                .font(Theme.ui(.callout))
                .foregroundStyle(Theme.slate)
            Spacer(minLength: 8)
            Button(HandoffCardText.cancelTitle) { model.cancelHandoff(threadID: thread.id, origin: .card) }
                .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hair))
        .accessibilityElement(children: .combine)
    }

    private var outdated: some View {
        HStack(spacing: 10) {
            Text(HandoffCardText.preparationOutdated)
                .font(Theme.ui(.callout))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(HandoffCardText.remakeTitle) { Task { await model.remakeHandoff(threadID: thread.id) } }
                .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 11))
            Button(HandoffCardText.closeTitle) { model.dismissOutdatedHandoff(threadID: thread.id) }
                .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hair))
    }
}

/// 인계 카드 (목업 calm-2): 머리(까닭 · 카운트다운 링) · 받는 쪽 줄(로고 · 이름 · 계정 · 모델 · 확인한 사실 · 세션 · 바꾸기) ·
/// 문서 머리 · 요약(받는 문서의 절 순서) · 덧붙일 말 · 경고 · 단추 · 확인 체크 · 막힘 이유.
/// 좁은 칸(네 칸)에서는 접어서 머리 · 사실 한 줄 · 다음 행동 한 줄 · 단추만 보이고 "펼치기" 로 연다.
/// 포커스를 빼앗지 않는다. esc 를 걸지 않는다 (입력창의 한글 후보 지우기를 빼앗는다).
struct HandoffCardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let thread: ConversationThread
    let card: HandoffCard
    let compact: Bool

    private enum Field: Hashable { case memo, document }
    @FocusState private var focus: Field?
    @State private var width: CGFloat = 700
    /// 고친 문서를 Gemini 정리본으로 바꿀지 묻는 중.
    @State private var confirmingGemini = false

    private var targetName: String {
        model.handoffPartyName(card.draft.target, label: card.draft.packet.toAccountLabel)
    }
    private var sourceName: String {
        model.handoffPartyName(card.draft.source, label: card.draft.packet.fromAccountLabel)
    }
    private var narrow: Bool { compact || width < 470 }
    private var folded: Bool { narrow && !card.expanded }
    private var block: HandoffSendBlock? { card.isSending ? nil : model.handoffSendBlock(threadID: thread.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if card.phase != .unknown {
                if folded {
                    foldedSummary
                } else {
                    reviewReasons
                    receiverBox
                    document
                    if card.editorOpen { editor }
                    if card.phase != .sending { memo }
                    warnings
                }
            }
            // 확인 체크는 [넘기기] 보다 앞에 — 읽는 순서대로 "확인 → 넘기기" (꺼진 단추를 먼저 보고 멈추지 않게).
            confirmRow
            actions
            footer
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card.highlighted ? Theme.approvalWell : Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(card.highlighted ? Theme.approvalBorder : Theme.hair))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { PreviewCardFrame.record($0) }
        #endif
        .onChange(of: focus) { _, field in
            // 덧붙일 말 칸에 포커스가 들어오면 카운트다운이 멈춘다 (글자 변경이 아니라 포커스로 — 한글 조합 중에는 변경이 오지 않는다).
            model.setHandoffCardFocus(threadID: thread.id, focused: field != nil, pausesCountdown: field == .memo)
        }
        .onDisappear { model.setHandoffCardFocus(threadID: thread.id, focused: false) }
        // ⇧⌘H · 메뉴바로 카드에 왔다 — 덧붙일 말 칸에 키보드 포커스 (⌘↵ 한 번 = 확인, 한 번 더 = 넘기기). 펼친 직후라 칸이 생긴 뒤에 준다.
        .onChange(of: card.memoFocusPending, initial: true) { _, pending in
            guard pending else { return }
            model.consumeHandoffMemoFocus(threadID: thread.id)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                focus = .memo
            }
        }
        .confirmationDialog(HandoffCardText.geminiReplacesEditsHelp, isPresented: $confirmingGemini) {
            Button(HandoffCardText.geminiTitle) { Task { await model.requestSummaryAssist(threadID: thread.id) } }
            Button("그만두기", role: .cancel) {}
        }
        .onChange(of: card.isCountingDown, initial: true) { _, counting in
            guard counting, case .countingDown(let deadline, _) = card.phase else { return }
            let seconds = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
            AccessibilityNotification.Announcement(HandoffCardText.announcement(seconds: seconds, target: targetName)).post()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("인계 카드")
    }

    // MARK: 머리

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    BrandMark(provider: headerProvider, size: 13)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    // 좁은 칸에서 "Codex" / "에게" 로 꺾이지 않게 이름과 조사를 붙여 둔다 (`keepingParticle`).
                    Text(HandoffCardText.keepingParticle(headline))
                        .font(Theme.ui(.body, .semibold))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if card.isCountingDown {
                    // 남은 초는 오른쪽 링 하나만 센다 — 같은 수를 두 번 보이지 않고, 틱마다 바뀌는 표시를 줄인다.
                    Text(HandoffCardText.keepingParticle(HandoffCardText.countdownSubline(target: targetName)))
                        .font(Theme.ui(.callout, .semibold))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let subline = HandoffCardText.subline(card, target: targetName) {
                    Text(HandoffCardText.keepingParticle(subline))
                        .font(Theme.ui(.callout))
                        .foregroundStyle(card.highlighted ? Theme.ink2 : Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if case .countingDown(let deadline, let delay) = card.phase {
                CountdownRing(deadline: deadline, delay: delay, reduceMotion: reduceMotion)
            } else if card.isSending {
                InkSpinner(color: Theme.slate).padding(.top, 4)
            }
        }
    }

    /// 한도 · 제안은 보내는 쪽의 일, 수동 · 칩은 받는 쪽에게 맡기는 일. 전달 미확인은 받는 쪽의 일이다.
    private var headerProvider: AgentProvider {
        if card.phase == .unknown { return card.targetProvider }
        switch card.origin {
        case .limitReached, .suggestion: return card.sourceProvider
        case .manual, .chip: return card.targetProvider
        }
    }

    /// 한도 머리의 초기화 사실은 한도 줄과 같은 규칙 (`HandoffCardText.resetPhrase`) — 지금 스냅샷이 먼저, 만들 때 적어 둔 값은
    /// 지금 다 찬 창이 없을 때만 (지났으면 지난 사실로). 앱이 시각을 모르는데 CLI 의 한도 문구가 시각을 말하면 그 원문을 가리킨다.
    /// 전달 여부 미확인 카드는 그 사실이 머리다 (한도 이야기보다 먼저).
    private var headline: String {
        if card.phase == .unknown { return HandoffCardText.unknownHeadline(target: targetName) }
        var reset: String?
        if case .limitReached(let scope, let resetsAt) = card.origin {
            let snapshot = model.limits.snapshot(scope)
            let phrase = HandoffCardText.resetPhrase(current: snapshot.capResetsAt(), fixed: resetsAt,
                                                     releasedSince: HandoffCardText.released(snapshot, since: card.draft.handoff.createdAt))
            reset = HandoffCardText.resetPhrase(phrase, rawText: model.limitNoticeText(threadID: thread.id))
        }
        return HandoffCardText.headline(origin: card.origin, source: sourceName, target: targetName, reset: reset, folded: folded)
    }

    /// 게이트가 막은 이유들 (자동 인계가 스스로 보내지 않은 까닭)과 이유마다의 다음 행동 — 받는 쪽을 확인하지 못했으면 [받는 쪽 다시
    /// 확인] · 로그인 명령, 받는 쪽도 한도면 바꾸기 ▾ 로, 그리고 넘겨도 되는지의 판단 기준 한 줄 (hnd-10).
    @ViewBuilder
    private var reviewReasons: some View {
        if case .automaticBlocked(let reasons)? = card.review, card.phase == .ready, !reasons.isEmpty {
            let kinds = reasons.map(AutomaticHandoffGate.kind(of:))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                    Text(reason)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let judgement = AutomaticHandoffGate.judgement(reasons) {
                    Text(judgement)
                        .font(Theme.ui(.caption, .medium))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if kinds.contains(.receiverUnchecked) || kinds.contains(.receiverCapped) {
                    recheckButton
                }
                if reasons.contains(AutomaticHandoffGate.reasonLogin), let command = receiverLoginCommand {
                    CopyableCommand(command: command)
                        .frame(maxWidth: 420, alignment: .leading)
                }
            }
            .leadingRule(Theme.amber, width: 2, gap: 11)
        }
    }

    /// 받는 쪽의 CLI · 로그인 · 한도를 새로 읽는다 (`AppModel.recheckHandoffReceiver`).
    private var recheckButton: some View {
        Button(card.recheckingReceiver ? "받는 쪽 확인하는 중…" : "받는 쪽 다시 확인") {
            Task { await model.recheckHandoffReceiver(threadID: thread.id) }
        }
        .buttonStyle(ChipButtonStyle(height: 24, horizontalPadding: 10))
        .fixedSize()
        .disabled(card.recheckingReceiver || card.isSending)
        .help("받는 쪽의 CLI · 로그인 · 사용 한도를 지금 다시 확인합니다 (자동으로 넘기지는 않습니다)")
    }

    /// 받는 쪽의 로그인 명령 — 앱은 실행하지 않고 복사만 한다. Antigravity 는 없다.
    private var receiverLoginCommand: String? {
        switch card.targetProvider {
        case .claude: return AgentSetupGuide.claudeLoginCommand
        case .codex:
            return CodexAccountInspector.loginCommand(
                home: model.accounts.accountOrDefault(card.draft.target.codexAccountID ?? CodexAccount.defaultID).homePath)
        case .gemini: return nil
        }
    }

    // MARK: 받는 쪽

    private var receiverBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    receiverIdentity
                    Spacer(minLength: 8)
                    facts
                    changeMenu
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        receiverIdentity
                        Spacer(minLength: 8)
                        changeMenu
                    }
                    facts
                }
            }
            Text(HandoffCardText.session(card.receiver.session, target: targetName))
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate)
            // 넘기기는 맥락만 전하는 것이 아니다 — 받는 쪽이 곧바로 일을 시작한다 (그 승인 방식과 함께, hnd-7).
            Text(HandoffCardText.startsImmediately(policy: receiverPolicy.title))
                .font(Theme.ui(.caption))
                .foregroundStyle(receiverPolicy.caution ? Theme.ink2 : Theme.slate)
                .fixedSize(horizontal: false, vertical: true)
                .help(receiverPolicy.detail)
            // 받을 모델 · 강도 — 입력창과 같은 모델 칩 (Claude · Codex · Antigravity 모두). 고르면 이 대화의 그 에이전트 선택을 바꾸고
            // (Codex 는 받는 계정의 목록으로 — 입력창이 카드 동안 보이는 것과 같은 값) 카운트다운을 멈춘다. 전달 직전
            // `pinEffectiveSelection` 이 이 값을 그대로 쓴다.
            HStack(spacing: 8) {
                Text("받는 모델")
                    .font(Theme.ui(.caption, .medium))
                    .foregroundStyle(Theme.slate)
                ModelPicker(provider: card.targetProvider, thread: receiverPickerThread,
                            chooseEffort: { effort in
                                let provider = card.targetProvider, account = receiverPickerThread.codexAccountID
                                Task { await model.setEffort(effort, for: provider, threadID: thread.id, accountID: account) }
                            })
                Spacer(minLength: 0)
            }
            .disabled(card.isSending)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hair))
    }

    private var receiverIdentity: some View {
        HStack(spacing: 7) {
            Text("받는 쪽")
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate)
            BrandMark(provider: card.targetProvider, size: 13)
            Text(targetName)
                .font(Theme.ui(.callout, .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
        .fixedSize()
    }

    /// 받는 쪽의 한도 — Antigravity 는 받는 모델이 쓰는 묶음(Gemini · Claude · GPT)의 창만 (`LimitSnapshot.scoped(toAntigravityModel:)`).
    private func receiverLimit(_ scope: AgentScope) -> LimitSnapshot {
        let snapshot = model.limits.snapshot(scope)
        guard card.targetProvider == .gemini else { return snapshot }
        return snapshot.scoped(toAntigravityModel: model.effectiveSelection(for: thread, provider: .gemini).model)
    }

    /// 받는 모델 칩이 그리는 대화 — 받는 쪽이 Codex 면 받는 계정(scope)으로 (입력창의 `ComposerView.pickerThread` 와 같은 값).
    private var receiverPickerThread: ConversationThread {
        guard card.targetProvider == .codex else { return thread }
        var receiver = thread
        receiver.codexAccountID = card.draft.handoff.toAccountID
        return receiver
    }

    /// 앱이 확인한 사실 — 확인한 것에만 ✓, 문제는 황색, 모르는 것은 그대로 적는다. 나이("방금" · "3분 전")가 흐르게 이 줄만
    /// 30초마다 다시 그린다 (칸 머리의 "n분 전" 과 같은 주기).
    private var facts: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            factRow(factList(now: context.date))
        }
    }

    private func factRow(_ list: [HandoffCardText.Fact]) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(list.enumerated()), id: \.offset) { _, fact in
                HStack(spacing: 4) {
                    switch fact.tone {
                    case .good:
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.slate)
                    case .bad:
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 9.5)).foregroundStyle(Theme.amber)
                    case .unknown:
                        EmptyView()
                    }
                    Text(fact.text)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(fact.tone == .bad ? Theme.ink2 : Theme.slate)
                        .lineLimit(1)
                }
                .fixedSize()
            }
        }
    }

    private func factList(now: Date) -> [HandoffCardText.Fact] {
        let target = card.draft.target
        let scope = target.provider == .codex ? AgentScope.codex(target.codexAccountID ?? "") : AgentScope(provider: target.provider, accountID: "")
        // 이 대화의 API 크레딧으로 받는 Claude — 구독 로그인 · 구독 한도는 이 인계와 무관하다.
        if model.receivesWithClaudeAPI(target, threadID: thread.id) {
            return [HandoffCardText.cliFact(provider: target.provider, usable: card.receiver.cliUsable),
                    HandoffCardText.apiCreditFact].compactMap { $0 }
        }
        return [HandoffCardText.cliFact(provider: target.provider, usable: card.receiver.cliUsable),
                HandoffCardText.loginFact(provider: target.provider, authenticated: card.receiver.authenticated,
                                          checkedAt: card.receiver.authCheckedAt, now: now),
                HandoffCardText.limitFact(provider: target.provider, limit: receiverLimit(scope), now: now)].compactMap { $0 }
    }

    /// 받는 쪽의 승인 방식 — 입력창 승인 칩과 같은 말 (`ApprovalPolicyText`). 받는 에이전트(제공자)가 바뀌면 자동 승인은 넘길 때 꺼진다.
    private var receiverPolicy: ApprovalPolicyText {
        if card.targetProvider == card.sourceProvider, model.isAutoApproving(threadID: thread.id) { return .autoApproval }
        return ApprovalPolicyText.policy(provider: card.targetProvider, claudePermissionMode: model.claudePermissionMode,
                                         codexApprovalPolicy: model.codexApprovalPolicy, codexSandboxMode: model.codexSandboxMode)
    }

    /// 받는 쪽 바꾸기 — 덧붙인 말을 옮겨 초안을 다시 만든다 (카운트다운은 먼저 멈춘다). 쓸 수 없는 대상은 칩 메뉴와 같은 판정으로
    /// 끄고 그 까닭을 항목에 적는다 (`AppModel.handoffTargetBlock` — 허용 필요 · 설치 안 됨 · 로그인 필요). 고를 대상이 하나도 없으면 끈다.
    private var changeMenu: some View {
        let targets = changeTargets
        let selectable = targets.contains { $0.block == nil }
        return Menu {
            ForEach(targets) { target in
                Button(target.label) {
                    Task {
                        await model.replaceHandoffTarget(threadID: thread.id, to: target.agent.provider,
                                                         toAccountID: target.agent.provider == .codex ? target.agent.codexAccountID : nil)
                    }
                }
                .disabled(target.block != nil)
                .help(target.block?.help ?? "")
            }
        } label: {
            HStack(spacing: 4) {
                Text(HandoffCardText.changeTitle).font(Theme.ui(.callout))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Theme.ink2)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(GhostChipStyle(height: 22, horizontalPadding: 6))
        .fixedSize()
        .disabled(card.isSending || card.summarizing || model.handoffPreparations[thread.id] != nil || !selectable)
        .help(selectable ? "받는 쪽을 바꿔 초안을 다시 만듭니다 — 덧붙인 말은 옮겨 갑니다"
                         : "바꿀 수 있는 받는 쪽이 없습니다 — " + (targets.first?.block?.help ?? "다른 에이전트가 없습니다"))
    }

    private struct ChangeTarget: Identifiable {
        var id: String { agent.key }
        var agent: HandoffSource.Agent
        var title: String
        var block: ContinueChoice.Unavailable?
        var tag: String?

        /// 메뉴 항목 글 — 끈 까닭 · 꼬리표를 이름 옆에 ("Antigravity — 설정에서 허용 필요").
        var label: String {
            if let block { return "\(title) — \(block.meta)" }
            if let tag { return "\(title) · \(tag)" }
            return title
        }
    }

    /// 보내는 쪽 · 지금 받는 쪽을 뺀 대상 (칩 메뉴와 같은 목록 — Codex 는 계정마다).
    private var changeTargets: [ChangeTarget] {
        let source = card.draft.source
        let current = card.draft.target
        return model.continueMenuAgents.filter { $0 != source && $0 != current }.map { agent in
            ChangeTarget(agent: agent, title: model.handoffPartyName(agent),
                         block: model.handoffTargetBlock(agent, thread: thread), tag: model.handoffTargetTag(agent, threadID: thread.id))
        }
    }

    // MARK: 문서

    private var document: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(HandoffCardText.documentHeader(target: targetName, gemini: card.draft.packet.summarySource == "gemini",
                                                    tokens: Fmt.tokens(CostCalculator.roughTokenEstimate(card.draft.editedText))))
                    .font(Theme.ui(.caption))
                    .foregroundStyle(card.draft.validationWarnings.isEmpty ? Theme.slate : Theme.amberText)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if !card.editorOpen {
                    Button(card.documentShown ? "전문 접기" : "전문 보기 ›") {
                        model.setHandoffDocumentShown(!card.documentShown, threadID: thread.id)
                    }
                    .buttonStyle(TextButtonStyle(color: Theme.ink2, font: Theme.ui(.caption)))
                }
            }
            // Gemini 로 정리하지 못했다 (agy 없음 · 오류) — 문서는 앱이 정리한 것이다. 쓸 수 없으면 그 까닭을 한 줄로 (단추는 숨긴다).
            if let note = card.draft.geminiFailure ?? model.geminiUnavailableNote(projectID: thread.projectID) {
                Text(note)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if card.draft.isEdited {
                Text(HandoffCardText.editedNote)
                    .font(Theme.ui(.callout))
                    .foregroundStyle(Theme.ink2)
            } else {
                summaryGrid(HandoffCardSummary.rows(card.draft.packet, memo: card.userMemo))
            }
            if card.documentShown && !card.editorOpen {
                ExpandableMono(text: card.draft.editedText, previewLines: 18, color: Theme.slate)
                    .padding(10)
                    .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.codeBorder))
            }
        }
    }

    private func summaryGrid(_ rows: [HandoffCardSummary.Row]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.label)
                        .font(Theme.ui(.callout))
                        .foregroundStyle(row.warn ? Theme.amberText : Theme.slate)
                        .gridColumnAlignment(.leading)
                        .fixedSize()
                    Text(row.text)
                        .font(Theme.ui(.callout))
                        .foregroundStyle(row.warn ? Theme.ink2 : Theme.ink2)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// 문서 열어 고치기 — 카드 안에서 펼친다 (열면 카운트다운이 멈춘다).
    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("보내기 전에 꼭 필요한 경우에만 고치세요. 기본 초안은 그대로 보내도 됩니다.")
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate)
            TextEditor(text: Binding(get: { card.draft.editedText },
                                     set: { model.setHandoffEditedText($0, threadID: thread.id) }))
                .font(Theme.mono(.caption))
                .scrollContentBackground(.hidden)
                .plainTextInput()
                .focused($focus, equals: .document)
                .frame(minHeight: 220, maxHeight: 420)
                .padding(8)
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.codeBorder))
                .disabled(card.isSending)
                .accessibilityLabel("받는 쪽에게 가는 문서")
        }
    }

    // MARK: 덧붙일 말

    private var memo: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate2)
                TextField(HandoffCardText.memoPlaceholder(target: targetName, countingDown: card.isCountingDown),
                          text: Binding(get: { card.userMemo }, set: { model.setHandoffMemo($0, threadID: thread.id) }),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(.callout))
                    .lineLimit(1...5)
                    .focused($focus, equals: .memo)
                    .accessibilityLabel("\(targetName) 에게 덧붙일 말")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 36)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focus == .memo ? Theme.slate3 : Theme.hair))
            taskHint
        }
    }

    /// 다음 행동을 앱이 찾지 못했을 때 (hnd-6): 입력창에 걸어 둔 메시지가 있으면 그것을 덧붙일 말로 옮길지 바로 고르게 하고 (할 일을 적을
    /// 곳을 하나로 — 따로 한 턴을 쓰지 않는다), 둘 다 비었으면 받는 쪽이 지시를 기다린다고 알린다. 문서를 직접 고쳤으면 말하지 않는다.
    @ViewBuilder
    private var taskHint: some View {
        if HandoffCardSummary.nextActionUnknown(card.draft.packet), !card.draft.isEdited, !card.isSending {
            let held = model.heldMessagesForMemo(threadID: thread.id)
            if !held.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        heldNote(held.count)
                        Spacer(minLength: 6)
                        moveHeldButton
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        heldNote(held.count)
                        moveHeldButton
                    }
                }
            } else if card.userMemo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.amber)
                    Text(HandoffCardText.noTaskHint)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func heldNote(_ count: Int) -> some View {
        Text(HandoffCardText.heldMessagesNote(count: count))
            .font(Theme.ui(.caption))
            .foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var moveHeldButton: some View {
        Button(HandoffCardText.moveHeldToMemoTitle) { model.moveHeldMessagesToMemo(threadID: thread.id) }
            .buttonStyle(ChipButtonStyle(height: 24, horizontalPadding: 10))
            .fixedSize()
            .help(HandoffCardText.moveHeldToMemoHelp)
    }

    @ViewBuilder
    private var warnings: some View {
        if !card.draft.validationWarnings.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                SectionLabel("Gemini 검증 경고", color: Theme.amberText)
                ForEach(card.draft.validationWarnings, id: \.self) { warning in
                    Text(warning)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .leadingRule(Theme.amber, width: 2, gap: 11)
        }
    }

    // MARK: 접힌 카드 (좁은 칸)

    private var foldedSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                BrandMark(provider: card.targetProvider, size: 11)
                Text(targetName)
                    .font(Theme.ui(.callout, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if card.foldedReviewReason == nil {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let first = factList(now: context.date).first {
                            Text(first.text)
                                .font(Theme.ui(.caption))
                                .foregroundStyle(first.tone == .bad ? Theme.amberText : Theme.slate)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                // 펼치기는 이 줄 끝에 — 좁은 칸에서 줄 하나를 아낀다 (접기는 펼친 카드의 바닥에).
                expandButton
            }
            // 게이트가 막은 자동 인계: 머리 아래 줄이 "아래 이유" 라고 하므로 첫 이유를 사실 줄 대신 보인다 (나머지는 펼치면).
            if let reason = card.foldedReviewReason {
                Text(reason)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .leadingRule(Theme.amber, width: 2, gap: 9)
            }
            if let next = HandoffCardSummary.rows(card.draft.packet, memo: card.userMemo).first {
                Text(card.draft.isEdited ? HandoffCardText.editedNote : next.text)
                    .font(Theme.ui(.callout))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    // MARK: 단추

    @ViewBuilder
    private var actions: some View {
        switch card.phase {
        case .unknown:
            // 할 수 있는 일: 이 대화에 받는 쪽의 응답이 없으면 닫고 다시 만들기 (넘기는 것은 다시 사람의 확인으로), 받았으면 닫기.
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(HandoffCardText.remakeUnknownTitle) { Task { await model.remakeUnknownHandoff(threadID: thread.id) } }
                    .buttonStyle(ChipButtonStyle(height: 27, horizontalPadding: 13))
                    .fixedSize()
                    .disabled(model.handoffPreparations[thread.id] != nil)
                    .help(HandoffCardText.remakeUnknownHelp)
                Button(HandoffCardText.closeTitle) { model.cancelHandoff(threadID: thread.id, origin: .card) }
                    .buttonStyle(ChipButtonStyle(height: 27, horizontalPadding: 13))
                    .fixedSize()
                    .help(HandoffCardText.closeUnknownHelp)
            }
        default:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    primaryButtons
                    apiContinueButton
                    secondaryButtons
                    Spacer(minLength: 8)
                    cancelButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        primaryButtons
                        apiContinueButton
                    }
                    HStack(spacing: 8) {
                        secondaryButtons
                        Spacer(minLength: 8)
                        cancelButton
                    }
                }
            }
            .background { returnKeyButton }
        }
    }

    /// 카드 안에 포커스가 있으면 ⌘↵ 는 카드의 것 — 넘길 수 없으면 아무것도 하지 않는다 (보이지 않는 입력창의 대기열로 새지 않게).
    private var returnKeyOwner: ChangesState.ReturnKeyOwner {
        ChangesState.returnKeyOwner(commitFieldFocused: model.commitFieldFocused,
                                    cardFieldFocused: model.handoffCardFocusThreadID == thread.id)
    }

    /// 카드의 ⌘↵ (hnd-18) — 확인 전이면 확인 체크, 확인했으면 넘기기 (`AppModel.handoffReturnKey`). 키보드만으로 확인하고 넘길 수 있게
    /// 단추와 따로 둔다 (꺼진 [넘기기] 에 단축키를 걸면 확인 전에는 아무 일도 일어나지 않았다). 보이지 않는다.
    @ViewBuilder
    private var returnKeyButton: some View {
        if returnKeyOwner == .handoff, card.showsConfirm(folded: false) {
            Button("") {
                Task {
                    if await model.handoffReturnKey(threadID: thread.id) == .confirmed {
                        AccessibilityNotification.Announcement(HandoffCardText.confirmedAnnouncement(target: targetName)).post()
                    }
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var primaryButtons: some View {
        if card.isCountingDown {
            Button {
                Task { await model.sendHandoffNow(threadID: thread.id) }
            } label: {
                Text(HandoffCardText.sendNowTitle)
            }
            .buttonStyle(InkButtonStyle(height: 28))
            .fixedSize()
            .disabled(block != nil)
            .help("기다리지 않고 지금 \(targetName) 에게 넘깁니다 — 기록에는 \"자동 인계 · 사람 검토 없음\" 으로 남습니다")
            .accessibilityLabel("지금 \(targetName) 에게 넘기기")
            Button(HandoffCardText.pauseTitle) { model.pauseCountdown(threadID: thread.id) }
                .buttonStyle(ChipButtonStyle(height: 28, horizontalPadding: 12))
                .fixedSize()
                .help("카운트다운을 멈추고 확인한 뒤 넘깁니다")
        } else if card.isStale {
            Button(HandoffCardText.remakeTitle) { Task { await model.remakeHandoff(threadID: thread.id) } }
                .buttonStyle(InkButtonStyle(height: 28))
                .fixedSize()
                .disabled(model.handoffPreparations[thread.id] != nil)
                .help("지금 폴더 · 대화 상태로 초안을 다시 만듭니다 — 덧붙인 말은 옮겨 갑니다")
        } else if card.foldedNeedsExpand(folded: folded) {
            // 접힌 카드에서는 확인 체크가 펼친 뒤에만 있다 — 꺼진 [넘기기] 대신 무엇을 해야 하는지 보이는 단추를 둔다.
            Button(HandoffCardText.expandToConfirmTitle) { model.setHandoffExpanded(true, threadID: thread.id) }
                .buttonStyle(InkButtonStyle(height: 28))
                .fixedSize()
                .help("펼쳐서 내용을 확인하고 체크하면 \(targetName) 에게 넘길 수 있습니다")
        } else {
            let sendable = card.sendableByHuman && block == nil
            Button {
                Task { await model.sendHandoff(threadID: thread.id) }
            } label: {
                HStack(spacing: 7) {
                    if card.isSending { InkSpinner() }
                    Text(card.isSending ? (HandoffCardText.subline(card, target: targetName) ?? "")
                                        : HandoffCardText.sendTitle(target: targetName))
                    if returnKeyOwner == .handoff && sendable {
                        Text("⌘↵").font(Theme.mono(.caption)).opacity(0.6)
                    }
                }
            }
            .buttonStyle(InkButtonStyle(height: 28))
            .fixedSize()
            .disabled(!sendable)
            .help(card.confirmed ? "\(targetName) 에게 넘깁니다 — 받는 쪽은 받자마자 일을 시작합니다"
                  : (folded ? "펼쳐서 내용을 확인하고 체크하면 넘길 수 있습니다"
                            : "\"\(HandoffCardText.confirmTitle)\" 를 체크하면 넘길 수 있습니다"))
            .accessibilityLabel(HandoffCardText.sendTitle(target: targetName))
        }
    }

    /// [API 크레딧으로 계속] — 보내는 쪽 Claude 가 구독 한도에 닿아 생긴 카드(자동 카운트다운 · 검토 포함)에서, 인계 대신 같은 Claude
    /// 세션을 API 크레딧으로 이어 간다 (`AppModel.continueWithClaudeAPI` — 카드를 거두고 켜고 보낸다). 카운트다운은 바꾸지 않는다.
    /// 키가 없거나 이미 API 로 실행하는 대화면 없다 (`ClaudeAPIContinue.offer`).
    @ViewBuilder
    private var apiContinueButton: some View {
        if case .limitReached = card.origin, card.sourceProvider == .claude,
           model.claudeAPIContinueOffer(threadID: thread.id, provider: .claude) == .available {
            Button(ClaudeAPIContinue.title) { Task { await model.continueWithClaudeAPI(threadID: thread.id) } }
                .buttonStyle(ChipButtonStyle(height: 28, horizontalPadding: 12))
                .fixedSize()
                .disabled(card.isSending || model.runner.isBusy(threadID: thread.id))
                .help(ClaudeAPIContinue.cardHelp)
        }
    }

    /// 문서 열어 고치기 · Gemini 로 다시 정리 — 접힌 카드에서는 펼친 뒤에 보인다. Gemini 단추는 쓸 수 있을 때만 (다듬기를 고르지
    /// 않았거나 agy 가 없으면 숨긴다 — 쓸 수 없는 까닭은 문서 머리 아래 한 줄이 말한다).
    @ViewBuilder
    private var secondaryButtons: some View {
        if !folded {
            Button(card.editorOpen ? HandoffCardText.editCloseTitle : HandoffCardText.editTitle) {
                model.setHandoffEditorOpen(!card.editorOpen, threadID: thread.id)
            }
            .buttonStyle(ChipButtonStyle(height: 28, horizontalPadding: 12))
            .fixedSize()
            .disabled(card.isSending)
            if model.geminiResummaryAvailable(projectID: thread.projectID) || card.summarizing {
                Button(card.summarizing ? HandoffCardText.geminiRunningTitle : HandoffCardText.geminiTitle) {
                    // 사람이 고친 문서는 정리본으로 바뀐다 — 먼저 묻는다.
                    if card.draft.isEdited { confirmingGemini = true } else {
                        Task { await model.requestSummaryAssist(threadID: thread.id) }
                    }
                }
                .buttonStyle(ChipButtonStyle(height: 28, horizontalPadding: 12))
                .fixedSize()
                .disabled(card.isSending || card.summarizing)
                .help(card.draft.isEdited ? HandoffCardText.geminiReplacesEditsHelp : HandoffCardText.geminiHelp)
            }
        }
    }

    /// "내용을 확인했습니다" — [넘기기] 보다 앞에 둔다. 카드 안에 포커스가 있으면 ⌘↵ 로도 체크한다 (그 안내를 곁에).
    @ViewBuilder
    private var confirmRow: some View {
        // 접힌 카드는 체크를 보이지 않는다 — 펼쳐 요약 · 받는 쪽 · 막은 이유를 본 뒤에 확인한다.
        if card.showsConfirm(folded: folded) {
            HStack(spacing: 8) {
                Toggle(HandoffCardText.confirmTitle,
                       isOn: Binding(get: { card.confirmed }, set: { model.setHandoffConfirmed($0, threadID: thread.id) }))
                    .toggleStyle(.checkbox)
                    .font(Theme.ui(.caption, .semibold))
                    .foregroundStyle(Theme.ink2)
                    .help(HandoffCardText.confirmKeyHelp)
                if returnKeyOwner == .handoff && !card.confirmed {
                    Text(HandoffCardText.confirmKeyHint)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate2)
                }
            }
        }
    }

    private var cancelButton: some View {
        Button(HandoffCardText.cancelTitle) { model.cancelHandoff(threadID: thread.id, origin: .card) }
            .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.callout)))
            .fixedSize()
            .disabled(card.isSending)
            .help(HandoffCardText.cancelHelp)
    }

    // MARK: 바닥 — 확인 · 막힘 · 오류 · 펼치기

    /// 카드의 마지막 오류 — 머리 아래 줄(실패 까닭)이 이미 말한 것은 다시 적지 않는다.
    private var errorText: String? {
        guard let error = card.lastError else { return nil }
        if case .failed(let reason) = card.phase, reason == error { return nil }
        if case .deliveryFailed(let reason)? = card.review, reason == error { return nil }
        return error
    }

    @ViewBuilder
    private var footer: some View {
        let blockText = block.flatMap { $0 == .stale ? nil : $0.message }
        if blockText != nil || errorText != nil || (narrow && card.expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if let blockText {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.amber)
                        Text(blockText)
                            .font(Theme.ui(.caption))
                            .foregroundStyle(Theme.slate)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // 받는 쪽을 쓸 수 없다고 확인됐다 — 설치 · 로그인한 뒤 다시 확인하면 풀린다 (자동으로는 다시 재지 않는다).
                    if case .receiverUnavailable? = block {
                        HStack(spacing: 8) {
                            recheckButton
                            if card.receiver.authenticated == false, let command = receiverLoginCommand {
                                CopyableCommand(command: command).frame(maxWidth: 360, alignment: .leading)
                            }
                        }
                    }
                }
                if let error = errorText {
                    Text(error)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if narrow && card.expanded { expandButton }
            }
        }
    }

    private var expandButton: some View {
        Button(card.expanded ? HandoffCardText.collapseTitle : HandoffCardText.expandTitle) {
            model.setHandoffExpanded(!card.expanded, threadID: thread.id)
        }
        .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
        .fixedSize()
    }
}

/// 카운트다운 링 — 남은 초. 틱은 SwiftUI 밖에서 (`CountdownRingLayer` — 링의 호는 Core Animation 이 줄인다).
/// 동작 줄이기 설정이면 멈춘 링 + 수.
private struct CountdownRing: View {
    let deadline: Date
    let delay: Int
    let reduceMotion: Bool

    var body: some View {
        CountdownRingLayer(deadline: deadline, delay: delay, reduceMotion: reduceMotion)
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)
    }
}

/// 입력창 위 한 줄 — 자동 카드가 생겼는데 사람이 위로 올려 읽는 중이라 따라가지 않았을 때. 누르면 카드로 내려간다.
struct HandoffPeekLine: View {
    @Environment(AppModel.self) private var model
    let card: HandoffCard
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle().fill(Theme.amber).frame(width: 6, height: 6)
                if case .countingDown(let deadline, _) = card.phase {
                    CountdownText(deadline: deadline, color: Theme.amberText) { HandoffCardText.peekCountdown(seconds: $0) }
                } else {
                    Text(HandoffCardText.peekReview)
                }
            }
            .font(Theme.ui(.caption, .semibold))
            .foregroundStyle(Theme.amberText)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Theme.approvalWell, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.approvalBorder))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(card.isCountingDown ? "자동 인계 대기 · 카드 보기" : "인계 검토 필요 · 카드 보기")
    }
}

#if DEBUG
/// 화면 확인용 (`-preview.cardFrameFile <경로>`, `AHC_OFFLINE=1`): 인계 카드의 창 안 자리(포인트, 창의 왼쪽 위 기준)와 창 크기를
/// JSON 으로 적는다 — README 이미지(`scripts/readme-images/compose.py` 의 `card_box`)가 캡처에서 카드만 잘라 낸다.
/// 자리가 바뀔 때마다 덮어쓴다 (찍는 순간의 마지막 자리).
@MainActor
enum PreviewCardFrame {
    static func record(_ rect: CGRect) {
        guard AppModel.offlinePreview, let path = UserDefaults.standard.string(forKey: "preview.cardFrameFile"),
              let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        let frame: [String: Double] = ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height,
                                       "windowWidth": window.frame.width, "windowHeight": window.frame.height]
        guard let data = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
#endif
