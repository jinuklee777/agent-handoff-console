import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 채움 상자 입력창 (본문 단과 같은 740pt). 테두리 · 그림자 없이 옅은 면(`Theme.well`)으로만 구분한다.
///
/// 위: 글. 빈 입력창이 화면을 차지하지 않도록 한 줄에서 시작해 내용만큼 자란다.
/// 아래: 글자만 있는 선택기 둘(제공자 메뉴 · 모델 칩 "모델 · 강도")과 보내기 원 하나. 제공자 메뉴가 Codex 계정과
/// 이어 가기(기록이 있으면 다른 에이전트 = 인계 초안 카드, "맥락 없이 바꾸기" 는 칩만)까지 품는다 — 한 번에 하나만 활성이라
/// 셋을 늘 세그먼트로 보일 이유가 없다. 추론 강도는 모델 칩의 팝오버 강도 목록에서 고른다 (CLI가 실제 지원하는 MAX와 ULTRA를
/// 구분해 보여준다).
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let thread: ConversationThread
    /// 포커스 칸의 입력창인지. 분할 화면에서 ⌘↵ 는 포커스 칸의 입력창만 건다 (칸마다 걸면 어느 칸이 받을지 알 수 없다).
    var isFocusedPane = true

    @State private var flash = false
    @State private var effectTrigger = 0
    /// MAX · ULTRA 를 막 골랐다 — 테두리 · 불티 · 칩의 불꽃 글자가 몇 초만 움직인다. 평소에는 멈춘 테두리 (매 프레임 다시 그리지 않게 — chat-9).
    @State private var celebrating = false
    @State private var celebrationSerial = 0
    /// 실행 중 빈 입력창에서 esc 를 한 번 눌렀다 — 한 번 더 누르면 멈춘다 (`ComposerEscape`, chat-29).
    @State private var escapeArmedAt: Date?
    /// IME 조합 중(marked text)이면 텍스트 뷰의 글 전체 (조합 중인 글자 포함), 아니면 nil. 한글을 조합하는 동안 초안(binding)은
    /// 확정 전의 값에 머문다 — 그 사이 입력창이 다시 그려지면 SwiftUI 의 TextEditor 가 binding 값으로 글을 되돌려 **조합이 지워진다**
    /// (2026-09-28 실측). 그래서 조합 중에는 binding 이 이 값을 돌려준다 (`text`). 플레이스홀더 · 키 안내 · 보내기 원도 이 값을 본다.
    @State private var composing: String?
    /// 보내기 원을 눌렀는데 조합 중이면 텍스트 뷰에 조합 확정을 시킨다 (`ComposerReturnKey.commitSerial`).
    @State private var commitSerial = 0
    /// 이미지를 입력창 위로 끌고 있다 (놓을 수 있다는 점선 테두리).
    @State private var dropTargeted = false
    /// "/" 목록에서 고른 줄 (맞는 것 가운데 몇 번째). 찾을 말이 바뀌면 처음으로.
    @State private var slashSelection = 0
    /// esc 로 닫은 "/" 목록 — 글이 "/" 꼴을 벗어날 때까지 다시 띄우지 않는다.
    @State private var slashDismissed = false
    /// 고른 명령으로 입력창 글을 바꾸라는 요청 (번호가 오를 때마다 한 번 — 텍스트 뷰에서 바꿔 캐럿이 끝에 가고 되돌리기에 남는다).
    @State private var replaceSerial = 0
    @State private var replaceText = ""

    private var provider: AgentProvider { thread.preferredProvider }
    /// 인계 카드(준비 · 전달 중 포함)가 있으면 그 보류 — 입력창은 받는 쪽을 보인다 (C2). 저장된 칩은 전달이 확인될 때 옮긴다.
    private var hold: QueueHold? { model.queueHolds[thread.id] }
    /// 모델 칩 · 승인 칩 · 보내기 원이 받는 쪽 값을 보일 보류 — 전달 여부 미확인 카드면 nil (그 카드로는 인계가 끝나지 않는다 —
    /// 자리 글처럼 받는 쪽을 약속하지 않고, 닫으면 다음 메시지가 갈 저장된 칩의 값을 보인다).
    private var receiverHold: QueueHold? { model.isHandoffDeliveryUnknown(threadID: thread.id) ? nil : hold }
    /// 모델 칩 · 승인 칩 · 보내기 원이 보이는 에이전트 — 보류 중이면 받는 쪽.
    private var shownProvider: AgentProvider { receiverHold?.target.provider ?? provider }
    /// 모델 칩이 그리는 대화 — 보류 중이면 받는 쪽 계정(scope)으로 (카드의 받는 모델과 같은 값). 선택은 이 대화에 저장된다.
    private var pickerThread: ConversationThread {
        guard let target = receiverHold?.target, target.provider == .codex, let account = target.codexAccountID else { return thread }
        var receiver = thread
        receiver.codexAccountID = account
        return receiver
    }
    private var selection: ModelSelection { thread.selection(for: shownProvider) }

    private var isUltra: Bool { EffortScale.tier(of: selection.effort ?? "") == .ultra }
    private var hasSpecialEffect: Bool { EffortScale.isSpecial(selection.effort) }
    private var specialColor: Color { isUltra ? Theme.ultra : Theme.flame }
    private var specialLight: Color { isUltra ? Theme.ultraLight : Theme.flameAmber }
    private var specialPale: Color { isUltra ? Theme.ultraPale : Theme.flamePale }
    private var specialWell: Color { isUltra ? Theme.ultraWell : Theme.flameWell }

    /// 입력창의 글. 조합 중이면 텍스트 뷰가 가진 글(조합 중인 글자 포함)을 돌려준다 — TextEditor 가 다시 그려질 때 binding 과
    /// 텍스트 뷰의 글이 같아 조합을 건드리지 않는다. 쓰기는 확정된 글만 온다 (SwiftUI 는 조합 중에 binding 을 쓰지 않는다).
    private var text: Binding<String> {
        Binding(get: { composing ?? model.composerDraft(for: thread.id) },
                set: { model.updateComposerDraft($0, for: thread.id) })
    }

    /// 화면 판정에 쓰는 글 (조합 중인 글자 포함).
    private var effectiveText: String { text.wrappedValue }

    /// 붙인 이미지 (보낼 때 함께 간다).
    private var attachments: [ImageAttachment] { model.attachments(threadID: thread.id) }

    /// 보낼 것이 있다 — 글이나 이미지.
    private var hasContent: Bool {
        !effectiveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ComposerQueueList(threadID: thread.id)
            ComposerAttachmentStrip(threadID: thread.id)
            if let content = slashContent {
                SlashCommandMenu(provider: shownProvider, content: content,
                                 selection: min(slashSelection, max(content.matches.count - 1, 0)),
                                 onPick: { pickSlash($0) })
            }
            prompt
            controls
        }
        // "/" 를 치면 그 에이전트 · 폴더의 목록을 받는다 (없거나 오래됐을 때만 — 받는 동안에도 지난 목록이 보인다).
        .task(id: rawSlashQuery == nil ? nil : slashKey) {
            guard rawSlashQuery != nil, let key = slashKey else { return }
            await model.refreshSlashCommandsIfStale(key)
        }
        // esc 로 닫은 것은 글이 "/" 꼴을 벗어날 때 풀린다 — 닫아서 nil 이 된 `slashQuery` 가 아니라 글의 꼴을 본다.
        .onChange(of: rawSlashQuery) { _, query in
            slashSelection = 0
            if query == nil { slashDismissed = false }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.capsuleRadius))
        .background { capsuleBackground }
        .overlay { border }
        // 이미지는 입력창 어디에 놓아도 받는다 (글 칸 위에 놓은 파일은 텍스트 뷰가 먼저 받아 `ComposerReturnKey` 가 가로챈다).
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { acceptDrop($0) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Theme.Metric.capsuleRadius)
                    .strokeBorder(Theme.brand(provider), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if hasSpecialEffect && !reduceMotion && celebrating {
                SparkField(color: specialLight).offset(y: -54)
            }
        }
        .sensoryFeedback(.levelChange, trigger: effectTrigger)
        .task(id: escapeArmedAt) {
            // 두 번째 esc 를 기다리는 시간이 지나면 안내를 거둔다.
            guard escapeArmedAt != nil else { return }
            try? await Task.sleep(for: .seconds(ComposerEscape.window))
            if !Task.isCancelled { escapeArmedAt = nil }
        }
    }

    // MARK: 추론 강도

    /// 모델 칩 팝오버(강도 목록 · ↑ ↓ · 기본값으로 되돌리기)가 부르는 단 하나의 길. 모델은 그대로 두고 강도만 바꾼다.
    /// 연출은 사용자가 고를 때만 한 번 일어난다 — xhigh 는 테두리 amber 깜빡임, MAX · ULTRA 는 촉각 + 효과음(설정이 켜져 있을 때).
    /// 같은 값을 다시 고르는 일은 팝오버가 걸러서 오지 않는다 (팝오버는 저장 전의 방금 고른 값과 비교한다 — 여기서 저장된 값과
    /// 다시 비교하면, 빨리 → ← 를 눌렀을 때 ← 가 아직 저장되지 않은 옛 값과 같다고 버려진다).
    /// 모델은 여기서 채우지 않는다 — 그린 때의 선택으로 채우면 방금 누른 모델 행을 덮는다 (`AppModel.setEffort` 가 그 순간의 모델을 읽는다).
    private func chooseEffort(_ effort: String?) {
        let account = pickerThread.codexAccountID
        Task { await model.setEffort(effort, for: shownProvider, threadID: thread.id, accountID: account) }
        switch EffortScale.effect(choosing: effort) {
        case .flash:
            withAnimation(.easeOut(duration: 0.12)) { flash = true }
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                withAnimation(.easeIn(duration: 0.3)) { flash = false }
            }
        case .special:
            effectTrigger += 1
            if model.ultraSoundEnabled { NSSound(named: "Hero")?.play() }
            // 연출은 고른 순간 몇 초만 — 그 뒤로는 멈춘 테두리 (TimelineView 가 매 프레임 입력창을 다시 그린다).
            celebrationSerial += 1
            let serial = celebrationSerial
            celebrating = true
            Task {
                try? await Task.sleep(for: .seconds(3.2))
                if celebrationSerial == serial { celebrating = false }
            }
        case .none:
            break
        }
    }

    // MARK: 프롬프트

    private var prompt: some View {
        let shown = effectiveText
        return HStack(alignment: .top, spacing: 0) {
            // 숨긴 Text 가 높이를 정하고, 편집기는 그 위에 겹친다 (한 줄에서 시작해 자란다). 상자는 8줄 남짓에서 멈추므로 앞부분만
            // 잰다 — 수천 줄을 붙여도 키마다 글 전체를 배치하지 않게 (chat-20).
            let probe = ComposerText.heightProbe(shown)
            Text(probe.isEmpty ? " " : probe + " ")
                .font(Theme.body)
                .lineSpacing(4)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .topLeading)
                .hidden()
                .frame(maxHeight: 190)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: text)
                            .font(Theme.body)
                            .lineSpacing(4)
                            .foregroundStyle(Theme.ink)
                            .scrollContentBackground(.hidden)
                            // 상자를 넘치는 긴 글이면 스크롤 막대를 보인다 — 붙인 글이 얼마나 긴지 보이게.
                            .scrollIndicators(ComposerText.overflows(shown) ? .automatic : .never)
                            .autocorrectionDisabled()
                            .accessibilityLabel("메시지")
                            // ↵ 는 보내기, ⇧↵ · ⌥↵ 는 줄바꿈 (아래 `ComposerReturnKey`).
                            .background(ComposerReturnKey(draft: text.wrappedValue, commitSerial: commitSerial,
                                                          takesInitialFocus: isFocusedPane,
                                                          focusSerial: model.composerFocusRequest
                                                              .flatMap { $0.threadID == thread.id ? $0.serial : nil } ?? 0,
                                                          focusRequestedAt: model.composerFocusRequest?.requestedAt,
                                                          onFocusTaken: { model.consumeComposerFocus(serial: $0) },
                                                          onSend: { send($0) },
                                                          onComposition: { value in if composing != value { composing = value } },
                                                          onAttach: { files, data in
                                                              model.attachImages(files: files, data: data, threadID: thread.id)
                                                          },
                                                          onEscape: { handleEscape(textEmpty: $0) },
                                                          replaceSerial: replaceSerial, replaceText: replaceText,
                                                          onSlashKey: { handleSlashKey($0) }))
                        if shown.isEmpty {
                            Text(placeholder)
                                .font(Theme.body)
                                .foregroundStyle(Theme.slate2)
                                .lineLimit(2)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                }
        }
        .padding(.horizontal, 11)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    // MARK: 조작

    /// 조작 줄은 한 줄이다. 본문이 좁으면(인스펙터가 열린 최소 본문 460 에서 상자 안 폭은 약 380) `ViewThatFits` 가
    /// 전체 → 압축 → 최소 순으로 **이상적 폭이 들어가는 첫 단계**를 고른다 — 글자("Antigravity" · 계정 이름)가 두 줄로
    /// 접히지 않게 (2026-09-14 결함). 최소 단계마저 안 들어가면 모델 이름이 줄임표로 줄어들고, 나머지는 고정 폭이다.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controlsRow(.full)
            controlsRow(.compact)
            controlsRow(.minimal)
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 9)
    }

    private func controlsRow(_ density: ComposerDensity) -> some View {
        HStack(spacing: 2) {
            // 이미지 붙이기 (자동 작업은 이미지를 받지 않는다).
            if !isAuto {
                IconButton(systemName: "paperclip", size: 12.5, color: Theme.slate,
                           help: "이미지 붙이기 — ⌘V · 입력창에 끌어 놓기도 됩니다") { pickImages() }
            }
            ProviderMenu(thread: thread, density: density)
            if isAuto {
                // 모델은 작업마다 배정 정책이 고른다.
                if density != .minimal {
                    Text("작업마다 담당을 배정")
                        .font(Theme.ui(.callout)).foregroundStyle(Theme.slate2).lineLimit(1).padding(.leading, 4)
                }
            } else {
                // 인계 카드가 있으면 받는 쪽의 모델 · 승인 정책 (받는 쪽 scope 의 값 — 카드의 받는 모델과 같다).
                ModelPicker(provider: shownProvider, thread: pickerThread, density: density, celebrating: celebrating,
                            chooseEffort: chooseEffort)
                    .fixedSize(horizontal: density != .minimal, vertical: true)
                // Antigravity 는 승인을 묻지 않는다 — 고를 것이 없다.
                if shownProvider != .gemini {
                    ApprovalModeChip(threadID: thread.id, provider: shownProvider, density: density)
                }
            }
            Spacer(minLength: 6)
            if escapeArmedAt != nil && threadBusy {
                // 실행 중 빈 입력창의 esc 한 번 — 어느 밀도에서든 보인다 (잠깐이다).
                Text(density == .minimal ? "esc 한 번 더" : "esc 를 한 번 더 누르면 멈춥니다")
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.amberText)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, 6)
            } else if density == .full {
                if (threadBusy || hold != nil || model.isSending(threadID: thread.id)) && hasContent && !isAuto {
                    Text("↵ 대기열에 추가")
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate2)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.trailing, 8)
                } else if threadBusy {
                    // 실행의 하위 작업 진행은 초당 여러 번 바뀐다 — 그 값은 이 작은 뷰에서만 읽는다 (입력창 전체를 다시 그리지 않게).
                    RunningKeyHint(threadID: thread.id)
                        .padding(.trailing, 8)
                } else if let hint = keyHint {
                    Text(hint)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate2)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.trailing, 8)
                }
            }
            sendButton
        }
    }

    /// 보내기 원 옆의 단축키 안내. 글이 있으면 보내기 · 줄바꿈, 비어 있으면 없음 (실행 중의 안내는 `RunningKeyHint`).
    private var keyHint: String? {
        hasContent ? "↵ 보내기 · ⇧↵ 줄바꿈" : nil
    }

    /// 이 대화에 실행이 돌고 있다 (다른 대화의 실행은 이 입력창을 막지 않는다).
    private var threadBusy: Bool { model.runner.isBusy(threadID: thread.id) }

    /// 빈 입력창의 자리 글: 보내는 중이면 그 단계 ("보내는 중…" · "모델 목록을 확인하는 중…"), 인계 보류면 받는 쪽, 승인 · 질문
    /// 카드가 떠 있으면 카드에 먼저 답하라고 (여기 쓴 글은 실행이 끝난 뒤 간다 — chat-4), 아니면 "<에이전트> 에게 메시지…".
    private var placeholder: String {
        if let stage = model.sendingThreads[thread.id] { return stage.placeholder }
        if let hold { return holdPlaceholder(hold) }
        if let session = model.runner.session(threadID: thread.id),
           !session.pendingApprovals.isEmpty || !session.pendingQuestions.isEmpty {
            return "위 카드에 먼저 답하세요 — 여기 쓴 글은 실행이 끝난 뒤 보냅니다"
        }
        return "\(provider.displayName) 에게 메시지…"
    }

    /// 입력창의 esc — 실행 중이고 입력창이 비었을 때만, 두 번 누르면 멈춘다 (`ComposerEscape`). 처리했으면 true (텍스트 뷰의 기본 동작을 하지 않는다).
    private func handleEscape(textEmpty: Bool) -> Bool {
        switch ComposerEscape.action(textEmpty: textEmpty && composing == nil, running: threadBusy, armedAt: escapeArmedAt) {
        case .ignore:
            escapeArmedAt = nil
            return false
        case .arm:
            escapeArmedAt = Date()
            return true
        case .interrupt:
            escapeArmedAt = nil
            Task { await model.runner.interrupt(threadID: thread.id) }
            return true
        }
    }

    // MARK: "/" 목록

    /// 목록의 키 — 보내기 원이 보이는 에이전트(인계 보류면 받는 쪽)와 그 계정, 이 대화의 폴더. 자동 작업 · Antigravity 는 없다.
    private var slashKey: SlashCommandKey? {
        isAuto ? nil : model.slashCommandKey(thread: pickerThread, provider: shownProvider)
    }

    /// 입력창 글이 "/이름" 꼴이면 찾을 말 (Codex 는 "$이름" 도). 자동 작업이면 nil.
    private var rawSlashQuery: String? {
        isAuto ? nil : SlashCommands.query(in: effectiveText, provider: shownProvider)
    }

    /// 목록을 띄울 찾을 말 — esc 로 닫았으면 nil.
    private var slashQuery: String? { slashDismissed ? nil : rawSlashQuery }

    /// 목록에 보일 것. 받은 목록에 맞는 것이 없으면 닫는다 (↵ 는 그대로 보낸다). 목록이 비었으면 받는 중 · 받지 못한 까닭 ·
    /// 쓸 수 있는 스킬이 없다는 한 줄.
    private var slashContent: SlashMenuContent? {
        guard let query = slashQuery, let key = slashKey else { return nil }
        let list = model.slashCommandLists[key]
        let loading = model.loadingSlashCommands.contains(key)
        let matches = SlashCommands.matches(list?.commands ?? [], query: query)
        if !matches.isEmpty { return SlashMenuContent(matches: matches, loading: loading, note: nil) }
        guard list?.commands.isEmpty ?? true else { return nil }
        if loading || list == nil { return SlashMenuContent(matches: [], loading: true, note: nil) }
        let empty = shownProvider == .codex ? "이 폴더에서 쓸 수 있는 Codex 스킬이 없습니다." : "쓸 수 있는 명령 · 스킬이 없습니다."
        return SlashMenuContent(matches: [], loading: false, note: list?.message ?? empty)
    }

    /// 입력창 텍스트 뷰가 먼저 묻는 키 — 목록이 받았으면 true (텍스트 뷰는 아무것도 하지 않는다). 고를 줄이 없으면 ↵ · ↑ ↓ 는 받지 않는다.
    private func handleSlashKey(_ key: ComposerSlashKey) -> Bool {
        guard let content = slashContent else { return false }
        let count = content.matches.count
        switch key {
        case .dismiss:
            slashDismissed = true
            return true
        case .up, .down:
            guard count > 0 else { return false }
            let current = min(slashSelection, count - 1)
            slashSelection = key == .down ? (current + 1) % count : (current - 1 + count) % count
            return true
        case .accept:
            guard count > 0 else { return false }
            pickSlash(content.matches[min(slashSelection, count - 1)])
            return true
        }
    }

    /// 고른 명령을 입력창에 넣는다 ("/이름 " · Codex 는 "$이름 ") — 뒤에 인수를 이어 치면 된다.
    private func pickSlash(_ command: SlashCommand) {
        replaceText = SlashCommands.inserted(command, provider: shownProvider)
        replaceSerial += 1
    }

    /// 보류 중인 입력창의 자리 글 — 전달 여부 미확인 카드면 받는 쪽에게 간다고 약속하지 않는다 (그 카드로는 인계가 끝나지 않는다).
    /// 자동 인계 카운트다운 중이면 걸면 카운트다운이 멈춘다는 것까지 말한다 (`enqueueMessage` → `pauseCountdown`).
    private func holdPlaceholder(_ hold: QueueHold) -> String {
        if model.isHandoffDeliveryUnknown(threadID: thread.id) { return HandoffCardText.unknownComposerPlaceholder }
        let target = model.handoffPartyName(hold.target)
        // 넘긴 뒤 받는 쪽이 인계 문서로 일하는 중 — 준비 · 카드 단계와 다르다 (받는 쪽이 이미 일하고 있다).
        if model.deliveringHandoffs[thread.id] != nil { return HandoffCardText.deliveringComposerPlaceholder(target: target) }
        return model.handoffCards[thread.id]?.isCountingDown == true
            ? HandoffCardText.countdownComposerPlaceholder(target: target)
            : HandoffCardText.composerPlaceholder(target: target)
    }

    /// 보류 중 대기열 단추의 도움말 — 자리 글과 같은 사실 (미확인 · 전달 중 · 카운트다운 · 카드).
    private var holdSendHelp: String {
        if model.isHandoffDeliveryUnknown(threadID: thread.id) {
            return "대기열에 추가 (↵) — 전달 여부 미확인 카드를 닫으면 걸어 둔 메시지는 멈춥니다"
        }
        guard let hold else { return "대기열에 추가 (↵)" }
        return "대기열에 추가 (↵) — " + holdPlaceholder(hold)
    }

    /// ⌘↵ 를 입력창이 갖는가 — 커밋 칸 · 인계 카드 안에 포커스가 있으면 그쪽이 갖는다 (`ChangesState.returnKeyOwner`).
    private var ownsReturnKey: Bool {
        isFocusedPane && ChangesState.returnKeyOwner(commitFieldFocused: model.commitFieldFocused,
                                                     cardFieldFocused: model.handoffCardFocusThreadID != nil) == .composer
    }

    @ViewBuilder
    private var sendButton: some View {
        if threadBusy {
            // 실행 중에 쓴 글은 대기열로 — 끝나면 차례로 간다 (자동 작업은 대기열을 쓰지 않는다).
            if hasContent && !isAuto {
                Button { send() } label: {
                    Image(systemName: "text.append")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Theme.card))
                        .overlay(Circle().strokeBorder(Theme.hair))
                }
                .buttonStyle(.plain)
                // 쉬는 때 · 인계 보류 때와 같이 ⌘↵ 도 건다 (chat-17).
                .keyboardShortcut(ownsReturnKey ? KeyboardShortcut(.return, modifiers: .command) : nil)
                .help("대기열에 추가 (↵ · ⌘↵) — 지금 실행이 끝나면 이어서 보냅니다")
                .accessibilityLabel("대기열에 추가")
                .padding(.trailing, 4)
            }
            RunStopButton(threadID: thread.id)
        } else if hold != nil {
            // 인계 카드가 있는 동안 쓴 글은 대기열로 — 인계가 확인되면 받는 쪽에게 간다 (실행이 없어도).
            Button { send() } label: {
                Image(systemName: "text.append")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.card))
                    .overlay(Circle().strokeBorder(Theme.hair))
                    .opacity(hasContent ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(ownsReturnKey ? KeyboardShortcut(.return, modifiers: .command) : nil)
            .disabled(!hasContent)
            .help(holdSendHelp)
            .accessibilityLabel("대기열에 추가")
        } else {
            let empty = !hasContent
            // 보낸 메시지가 아직 시작되지 않았다 (모델 목록 확인 · 시작 전 스냅샷) — runner 는 아직 쉬고 있다. 원 안에 도는 링을 두고
            // 흐리게 둔다 (`AppModel.sendingThreads`). 그 사이 쓴 글은 ↵ 로 대기열에 건다.
            let stage = model.sendingThreads[thread.id]
            let starting = model.isStartingRun(threadID: thread.id) || stage != nil
            // 보내기 원은 제공자 색 (MAX · ULTRA 는 그 연출색). Codex 의 잉크는 다크에서 밝은 잉크가 되므로 글자는 `onInk`.
            let fill = hasSpecialEffect ? specialColor : Theme.brand(shownProvider)
            let glyph = shownProvider == .codex && !hasSpecialEffect ? Theme.onInk : Color.white
            Button { send() } label: {
                ZStack {
                    Circle().fill(fill)
                    if starting {
                        SpinningLayer(content: .ring(color: glyph, lineWidth: 1.5, trim: 0.7), period: 0.9)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(glyph)
                    }
                }
                .frame(width: 26, height: 26)
                .opacity(starting ? 0.55 : (empty ? 0.3 : 1))
            }
            .buttonStyle(.plain)
            // 변경사항 탭의 커밋 메시지 칸 · 인계 카드 안에 포커스가 있으면 ⌘↵ 는 그쪽이 받는다. 둘이 동시에 단축키를 갖지 않는다
            // (`ChangesState.returnKeyOwner`). 어느 쪽이 먼저 잡는지 AppKit 에 맡기지 않는다.
            .keyboardShortcut(ownsReturnKey ? KeyboardShortcut(.return, modifiers: .command) : nil)
            .disabled(empty || starting)
            .help(stage?.placeholder ?? (starting ? "에이전트 실행을 시작하는 중입니다" : "보내기 (↵ · 줄바꿈은 ⇧↵)"))
            .accessibilityLabel(starting ? "보내는 중" : "보내기")
        }
    }

    /// 보내기 버튼 · ⌘↵ · ↵ (`ComposerReturnKey`) 가 부르는 한 길. 이 대화에 실행이 돌거나 시작하는 중이면 대기열에 건다
    /// (끝나면 차례로 간다 — `AppModel.continueQueue`). 자동 작업을 고른 대화는 대기열을 쓰지 않는다.
    /// `value` 는 텍스트 뷰가 그 순간 가진 글 — IME 가 방금 확정한 글자가 초안(binding)에 아직 반영되지 않았을 수 있어,
    /// 초안을 그 값으로 맞춘 뒤 보낸다 (보낸 뒤 초안 비우기가 같은 값을 비교한다).
    private func send(_ value: String? = nil) {
        // 인계 카드(준비 · 전달 중 포함)가 있으면 실행이 없어도 대기열에 건다 — 인계가 확인되면 받는 쪽에게 간다 (C2).
        // 앞서 보낸 메시지가 아직 시작되지 않았어도(모델 목록 확인 · 시작 전 스냅샷) 새로 쓴 글은 대기열로 간다.
        let busy = threadBusy || model.isStartingRun(threadID: thread.id) || model.isSending(threadID: thread.id) || hold != nil
        if busy && isAuto { return }
        var value = value ?? model.composerDraft(for: thread.id)
        // 보내기 원 · ⌘↵ 로 왔는데 한글 조합 중이면 조합을 확정시키고 화면에 보이는 글(조합 중인 글자 포함)을 보낸다.
        if let composing, !composing.isEmpty {
            value = composing
            commitSerial += 1
            self.composing = nil
        }
        let images = attachments
        let blank = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !blank || !images.isEmpty else { return }
        // 이미지만 보낼 때 글은 비운다 (공백 · 줄바꿈만 있던 글을 보내지 않게).
        if blank { value = "" }
        if model.composerDraft(for: thread.id) != value { model.updateComposerDraft(value, for: thread.id) }
        // 승인 · 질문 카드가 떠 있는데 답처럼 보이는 글(y · 1 …)이면 걸기 전에 한 번 확인한다 (chat-4) — 글은 입력창에 남는다.
        if busy, hold == nil, model.needsReplyConfirmation(value, threadID: thread.id) { return }
        // 보냈으면 위로 올려 읽던 중이어도 맨 아래로 간다.
        model.threadStates[thread.id]?.requestScrollToBottom()
        if busy {
            model.enqueueMessage(value, images: images, threadID: thread.id)
            model.clearComposerDraft(value, for: thread.id)
            model.clearAttachments(threadID: thread.id)
            return
        }
        #if DEBUG
        // 화면 확인용 실행은 CLI 를 부르지 않는다 — 보냈다는 기록만 남기고 초안을 비운다 (`-preview.typeKeys` 확인용).
        if AppModel.offlinePreview {
            SplitDividerSweep.log("SEND \"\(value)\"")
            model.clearComposerDraft(value, for: thread.id)
            return
        }
        #endif
        // 누르는 순간 입력창을 비운다 — "보내는 중" 이 보이고, 시작하는 사이 다시 누른 ↵ 가 같은 부탁을 대기열에 복제하지 않는다
        // (chat-1). 보내지 못하면 되돌린다 — 그 사이 새로 쓴 글이 있으면 덮지 않는다 (이유는 입력창 바로 위의 안내에).
        let auto = isAuto
        // 자리를 지금 잡는다 — 다음 런루프에 도는 보내기 전에 누른 ↵ 도 대기열로 간다.
        if !auto, !model.reserveSend(threadID: thread.id) {
            model.enqueueMessage(value, images: images, threadID: thread.id)
            model.clearComposerDraft(value, for: thread.id)
            model.clearAttachments(threadID: thread.id)
            return
        }
        model.clearComposerDraft(value, for: thread.id)
        if !auto { for image in images { model.removeAttachment(image.id, threadID: thread.id) } }
        Task {
            // "자동"을 고른 대화면 에이전트 하나로 보내지 않고 자동 작업을 시작한다 (계획 → 배정 → 실행 → 검증).
            let accepted = auto ? await model.startOrchestration(request: value, threadID: thread.id)
                                : await model.send(value, provider: provider, threadID: thread.id, images: images, reserved: true)
            guard !accepted else { return }
            if model.composerDraft(for: thread.id).isEmpty { model.updateComposerDraft(value, for: thread.id) }
            if !auto { model.restoreAttachments(images, threadID: thread.id) }
        }
    }

    // MARK: 이미지 붙이기

    /// 📎: 파일을 골라 붙인다 (여러 장).
    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "메시지에 붙일 이미지를 고르세요"
        let threadID = thread.id
        panel.begin { response in
            guard response == .OK else { return }
            model.attachImages(files: panel.urls, threadID: threadID)
        }
    }

    /// 입력창에 놓은 것: 이미지 파일은 **놓는 순간** 읽는다(화면 캡처 썸네일의 임시 파일은 곧 지워진다), 이미지 데이터(브라우저에서
    /// 끈 이미지 등)는 그대로. 이미지가 아닌 파일(로그 · PDF …)은 글 칸에 놓았을 때처럼 경로를 글로 넣는다 — 놓는 자리에 따라 결과가
    /// 다르지 않게, 점선만 뜨고 아무 일도 없지 않게 (chat-12).
    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let threadID = thread.id
        let model = self.model
        var accepted = false
        for item in providers {
            if item.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = item.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    guard ImageAttachments.isImageFile(url), let data = try? Data(contentsOf: url) else {
                        let path = url.path
                        Task { @MainActor in model.appendToComposerDraft(path, threadID: threadID) }
                        return
                    }
                    let name = url.lastPathComponent
                    Task { @MainActor in model.attachImages(data: [data], names: [name], threadID: threadID) }
                }
            } else if item.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                item.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    let name = item.suggestedName ?? "끌어 놓은 이미지"
                    Task { @MainActor in model.attachImages(data: [data], names: [name], threadID: threadID) }
                }
            }
        }
        return accepted
    }

    /// 이 대화의 다음 메시지가 자동 작업으로 가는지. 자동 작업을 꺼 두면 항상 false.
    private var isAuto: Bool {
        model.orchestrationSettings.enabled && model.orchestrationAutoThreadIDs.contains(thread.id)
    }

    // MARK: 상자

    /// 평소엔 옅은 면 하나. MAX · ULTRA 일 때만 연출색 번짐이 붙는다.
    @ViewBuilder
    private var capsuleBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metric.capsuleRadius)
        if hasSpecialEffect {
            shape.fill(Theme.well)
                .shadow(color: specialColor.opacity(0.20), radius: 17, y: 10)
                .shadow(color: specialLight.opacity(0.18), radius: 26)
        } else {
            shape.fill(Theme.well)
        }
    }

    /// 평소엔 테두리가 없다. xhigh 를 고르면 잠깐 amber 로 깜빡이고, MAX · ULTRA 는 연출색 테두리 — 고른 순간 몇 초만 돌고
    /// (`celebrating`) 그 뒤로는 멈춘 그라데이션이다. 도는 동안은 `TimelineView(.animation)` 이 매 프레임 입력창을 다시 그린다 —
    /// 실행이 없어도 MAX 인 칸마다 그랬다 (chat-9).
    @ViewBuilder
    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metric.capsuleRadius)
        if hasSpecialEffect {
            if reduceMotion || !celebrating {
                shape.strokeBorder(LinearGradient(colors: [specialLight, specialColor],
                                                  startPoint: .leading, endPoint: .trailing), lineWidth: 1.5)
            } else {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let angle = Angle.degrees(t.truncatingRemainder(dividingBy: 2.6) / 2.6 * 360)
                    shape.strokeBorder(
                        AngularGradient(colors: [specialLight, specialColor, specialPale,
                                                 specialColor, specialLight],
                                        center: .center, angle: angle),
                        lineWidth: 1.5)
                }
            }
        } else if flash {
            shape.strokeBorder(Theme.amber, lineWidth: 1.5)
        }
    }
}

// MARK: - MAX / ULTRA 연출

/// 시머 글자 (불꽃 그라데이션이 흐른다).
struct ShimmerText: View {
    let text: String
    let colors: [Color]
    var animate = true

    var body: some View {
        if animate {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.9) / 1.9
                label(phase: phase)
            }
        } else {
            label(phase: 0.5)
        }
    }

    private func label(phase: Double) -> some View {
        let x = CGFloat(phase * 2.2 - 1.1)
        return Text(text).foregroundStyle(
            LinearGradient(colors: colors,
                           startPoint: UnitPoint(x: x, y: 0.5), endPoint: UnitPoint(x: x + 1.1, y: 0.5)))
    }
}

/// 캡슐 윗선에서 떠오르는 불티. 누르거나 가리지 않는다.
private struct SparkField: View {
    let color: Color

    private struct Spark {
        let x: CGFloat
        let delay: Double
        let size: CGFloat
    }

    private let sparks = [
        Spark(x: 0.14, delay: 0, size: 4.5), Spark(x: 0.27, delay: 0.45, size: 4.5),
        Spark(x: 0.41, delay: 0.9, size: 3), Spark(x: 0.56, delay: 1.3, size: 4.5),
        Spark(x: 0.68, delay: 0.2, size: 3), Spark(x: 0.79, delay: 1.7, size: 4.5),
        Spark(x: 0.88, delay: 0.7, size: 3),
    ]

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { gc, size in
                let t = context.date.timeIntervalSinceReferenceDate
                for spark in sparks {
                    let p = ((t - spark.delay).truncatingRemainder(dividingBy: 2.3) + 2.3)
                        .truncatingRemainder(dividingBy: 2.3) / 2.3
                    let opacity: Double
                    if p < 0.14 { opacity = p / 0.14 }
                    else if p < 0.72 { opacity = 1 - (p - 0.14) / 0.58 * 0.35 }
                    else { opacity = 0.65 * (1 - (p - 0.72) / 0.28) }
                    let scale = 0.55 - 0.35 * p
                    let r = spark.size * scale / 2
                    let center = CGPoint(x: size.width * spark.x, y: size.height - 2 - 50 * p)
                    gc.opacity = opacity
                    gc.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                            with: .color(color))
                }
            }
        }
        .frame(height: 56)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 조작 줄 밀도

/// 입력창 조작 줄의 밀도 (`ComposerView.controls`). 좁은 본문에서 한 줄을 지키기 위해 단계별로 글자를 줄인다.
enum ComposerDensity: CaseIterable {
    /// 제공자 로고 + 이름(+ 계정) · 모델 · 강도 · ↵ 안내.
    case full
    /// ↵ 안내 없음.
    case compact
    /// 제공자는 로고만 · 모델 이름은 줄임표로 줄어들 수 있다.
    case minimal
}

// MARK: - 제공자 메뉴

/// 다음 메시지를 보낼 에이전트 — **칩 = 이어 가기** (B 설계 C3). 글자만 있는 칩을 누르면 팝오버: 맨 위 "자동"(자동 작업을 켰을 때),
/// 에이전트 행(Codex 는 계정마다), 아래 "맥락 없이 바꾸기". 행을 누르면 무엇을 하는지는 순수 판정 `ContinueChoice` 가 정하고
/// `AppModel.performContinueChoice` 가 잇는다:
/// - 기록이 있는 대화에서 보내는 쪽이 아닌 에이전트 = "Codex 에게 이어 맡기기" — **인계 초안 카드를 먼저 보여 준다**(규칙 초안만,
///   넘기기 전에는 아무것도 실행되지 않는다). 보내는 쪽 행은 칩만 되돌린다. 칩만 바꾸는 것은 "맥락 없이 바꾸기".
/// - 기록이 없거나 인계할 수 없는 대화(끝나지 않은 자동 작업)는 지금처럼 칩만 바꾼다.
/// - 인계 카드가 있으면 행은 그 카드를 다룬다 — 받는 쪽 = 카드로 가기, 보내는 쪽 = 카드 거두기, 다른 쪽 = 받는 쪽 바꾸기.
///   준비 · 보내는 중 · 전달 중에는 모두 끈다.
/// 시스템 `Menu` 를 쓰지 않는다 — 항목마다 로고 · 계정 · 사용률 · 부제를 나란히 놓으려면 행을 직접 그려야 한다.
///
/// 같은 Codex 의 다른 계정 행은 인계하지 않고 계정만 바꾼다 — 이 대화의 Codex 세션을 그 계정의 인증으로 그대로 이어 간다
/// (`ContinueChoice.Action.switchAccount`, `CodexAccountSwitch`).
struct ProviderMenu: View {
    @Environment(AppModel.self) private var model
    let thread: ConversationThread
    var density: ComposerDensity = .full

    @State private var presented = false
    /// 팝오버를 열 때 읽은, 이 대화에서 이어 갈 세션이 있는 에이전트 · 계정 (`AppModel.resumableAgentKeys`).
    @State private var resumableKeys: Set<String> = []
    /// "맥락 없이 바꾸기" 를 펼쳤다.
    @State private var plainExpanded = false

    private var provider: AgentProvider { thread.preferredProvider }
    private var showsAccount: Bool { provider == .codex && model.accounts.hasMultiple }
    private var current: CodexAccount { model.codexAccount(for: thread) }

    /// 자동 작업을 켜 둔 앱에서 이 대화가 "자동"을 골랐는지.
    private var isAuto: Bool {
        model.orchestrationSettings.enabled && model.orchestrationAutoThreadIDs.contains(thread.id)
    }

    /// 인계 카드(준비 · 전달 중 포함)가 있으면 그 보류 — 칩은 "Claude → Codex · 인계 대기" (C2).
    private var hold: QueueHold? { model.queueHolds[thread.id] }

    /// 지금 받는 쪽을 바꿀 수 있나 — 카드가 놓여 있고 준비 · 보내는 중 · 전달 중 · 재정리 중이 아니다 (카드의 "바꾸기" · 칩 메뉴와 같다).
    private var receiverChangeable: Bool {
        guard let card = model.handoffCards[thread.id] else { return false }
        return !card.isSending && !card.summarizing && card.phase != .unknown && model.handoffPreparations[thread.id] == nil
    }

    /// 넘긴 뒤 받는 쪽이 인계 문서로 일하는 중 (전달 실행이 돈다).
    private var delivering: Bool { model.deliveringHandoffs[thread.id] != nil }
    /// 전달 여부 미확인 카드 — 받는 쪽에게 간다고 약속하지 않는다 (칩도 모델 칩처럼 저장된 에이전트를 보인다).
    private var deliveryUnknown: Bool { model.isHandoffDeliveryUnknown(threadID: thread.id) }

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 5) {
                if hold != nil, deliveryUnknown {
                    // 모델 칩 · 승인 칩이 보이는 에이전트(저장된 것)와 같은 에이전트를 보이고, 인계가 확인되지 않았다는 사실만 붙인다.
                    BrandMark(provider: provider, size: 11)
                    if density != .minimal {
                        Text(provider.displayName).lineLimit(1)
                        Text("· " + HandoffCardText.unknownChipNote).foregroundStyle(Theme.slate2).lineLimit(1)
                    }
                } else if let hold, delivering {
                    // 받는 쪽이 이미 일하고 있다 — 받는 쪽 하나와 그 사실 ("Codex · 인계받아 일하는 중").
                    BrandMark(provider: hold.target.provider, size: 11)
                    if density != .minimal {
                        Text(model.handoffPartyName(hold.target)).lineLimit(1)
                        Text("· " + HandoffCardText.composerDeliveringNote).foregroundStyle(Theme.slate2).lineLimit(1)
                    }
                } else if let hold {
                    BrandMark(provider: hold.source.provider, size: 11, opacity: 0.45)
                    Text("→").foregroundStyle(Theme.slate2)
                    BrandMark(provider: hold.target.provider, size: 11)
                    if density != .minimal {
                        Text(model.handoffPartyName(hold.target)).lineLimit(1)
                        Text("· " + HandoffCardText.composerChipNote).foregroundStyle(Theme.slate2).lineLimit(1)
                    }
                } else if isAuto {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold))
                    if density != .minimal { Text("자동").lineLimit(1) }
                } else {
                    BrandMark(provider: provider, size: 11)
                    if density != .minimal {
                        Text(provider.displayName).lineLimit(1)
                        if showsAccount {
                            Text("·").foregroundStyle(Theme.slate2)
                            Text(current.label).lineLimit(1)
                        }
                    } else if showsAccount {
                        // 가장 좁아도 계정은 남긴다 — 어느 계정의 한도 · 로그인으로 실행하는지 (cap-9).
                        Text(ComposerAccountLabel.short(current.label)).lineLimit(1)
                    }
                    if readinessNotice != nil {
                        // 쓸 수 없다고 확인된 에이전트 (설치 안 됨 · 경로 오류 · 로그인 안 됨) — 보내기 전에 보이게 (onb-4).
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.amber)
                    }
                }
                Text("▾").font(.system(size: 8)).foregroundStyle(Theme.slate2)
            }
        }
        .buttonStyle(GhostChipStyle(pressed: presented))
        .fixedSize()
        .accessibilityLabel(chipAccessibilityLabel)
        .help(hold.map { hold in
            if deliveryUnknown { return HandoffCardText.unknownChipHelp }
            if delivering { return HandoffCardText.composerDeliveringHelp(target: model.handoffPartyName(hold.target)) }
            return HandoffCardText.composerChipHelp(target: model.handoffPartyName(hold.target), changeable: receiverChangeable)
        } ?? (isAuto ? "다음 메시지를 자동 작업으로 보냅니다: 계획을 세워 작업을 나누고, 작업마다 담당 모델을 배정하고, 끝날 때마다 검증합니다."
                     : helpText))
        .popover(isPresented: $presented, arrowEdge: .top) { popover }
        #if DEBUG
        .task {
            // 화면 확인용 (AHC_OFFLINE=1 일 때만): `-preview.action providerMenu` 로 이 팝오버를 연 채 시작한다 ("맥락 없이 바꾸기" 도 펼친다).
            guard AppModel.offlinePreview,
                  UserDefaults.standard.string(forKey: "preview.action") == "providerMenu" else { return }
            try? await Task.sleep(for: .milliseconds(900))
            plainExpanded = true
            presented = true
        }
        #endif
    }

    /// 칩의 접근성 이름 — 보이는 글과 같은 사실.
    private var chipAccessibilityLabel: String {
        if let hold {
            if deliveryUnknown { return "\(provider.displayName), \(HandoffCardText.unknownChipNote)" }
            if delivering { return "\(model.handoffPartyName(hold.target)), \(HandoffCardText.composerDeliveringNote)" }
            return "인계 대기: \(model.handoffPartyName(hold.source)) 에서 \(model.handoffPartyName(hold.target)) 에게"
        }
        if isAuto { return "자동" }
        return showsAccount ? "\(provider.displayName) · \(current.label)" : provider.displayName
    }

    // MARK: 팝오버

    private var popover: some View {
        let input = model.continueChoiceInput(for: thread, resumableKeys: resumableKeys)
        let agents = model.continueMenuAgents
        let note = menuNote(input)
        return VStack(alignment: .leading, spacing: 0) {
            if let note {
                // 모든 행에 같이 걸린 까닭은 여기서 한 번만 (행마다 되풀이하지 않는다).
                Text(note)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                Rectangle().fill(Theme.hair).frame(height: 1)
            }
            if model.orchestrationSettings.enabled {
                autoRow.padding(6)
                    // 인계 카드가 있는 동안 "자동" 은 끈다 — 다음 일은 인계 뒤 받는 쪽에게 간다.
                    .disabled(hold != nil || model.hasHandoffActivity(threadID: thread.id))
                Rectangle().fill(Theme.hair).frame(height: 1)
            }
            VStack(spacing: 1) {
                ForEach(agents, id: \.self) { agent in agentRow(agent, input: input) }
            }
            .padding(6)
            if ContinueChoice.showsPlainSwitch(input) {
                Rectangle().fill(Theme.hair).frame(height: 1)
                plainSection(ContinueChoice.plainSwitchAgents(agents, input), input: input)
                    .padding(6)
            }
        }
        // "Codex · 둘째 에게 이어 맡기기" + 사용률이 한 줄에 들어가는 폭 (계정 이름이 더 길면 행 글이 두 줄로 접힌다).
        .frame(width: 360)
        .background(Theme.paper)
        .task { resumableKeys = await model.resumableAgentKeys(threadID: thread.id, agents: agents) }
    }

    /// 메뉴 머리 한 줄 — 자동 작업이 가진 대화면 그 까닭(기록이 있어도 이어 맡기지 않는다), 아니면 판정의 공통 까닭.
    private func menuNote(_ input: ContinueChoiceInput) -> String? {
        if input.loaded, input.hasWorkedRuns, let block = model.handoffOwnershipBlock(thread) { return block }
        // 메인 턴을 마치고 백그라운드 작업을 기다리는 중이면 그 수 — 답은 끝난 것처럼 보여도 실행은 돌고 있다.
        let session = model.runner.session(threadID: thread.id)
        let busyNote = session.map { SubAgentDigest.waitingNote(waiting: $0.isWaitingOnBackground, count: $0.unfinishedSubAgentCount) } ?? ""
        return ContinueChoice.menuNote(input, busyNote: busyNote)
    }

    /// 에이전트 행 하나 — 이어 맡기기 · 칩 · 카드 동작 (`ContinueChoice.action`).
    private func agentRow(_ agent: HandoffSource.Agent, input: ContinueChoiceInput) -> some View {
        let action = ContinueChoice.action(for: agent, input)
        let name = model.handoffPartyName(agent)
        let continues = ContinueChoice.continues(agent, input)
        let account = accountOfRow(agent)
        // 행 하나에 걸린 까닭(`Block.meta` — 인계 카드가 있음 · 허용 필요 · 설치 안 됨 · 로그인 필요)은 그 행 오른쪽에, 막지 않는
        // 꼬리표("로그인 미확인")가 그다음, 아니면 계정의 사용률.
        let block = rowBlock(action)
        // 계정만 바꾸는 행은 막지 않는 로그인 상태("로그인 필요")도 알린다 — 바꿔 두고 터미널에서 로그인할 수 있다.
        let switchNote = action == .switchAccount ? input.handoffBlocks[agent.key]?.meta : nil
        let meta = block?.meta ?? switchNote ?? input.tags[agent.key] ?? account.flatMap(accountMeta)
        // ⇧⌘H 는 카드로 가기 행에만 붙인다 — 같은 단축키 = 같은 동작. 카드가 없을 때 ⇧⌘H 는 Gemini 정리를 거칠 수 있는 인계
        // (origin `.manual`)라, 규칙 초안만 만드는 이어 맡기기 행(origin `.chip`)과 같은 동작이 아니다.
        let shortcut = action == .showCard
        let trailing: PopoverRow.Trailing = action == .current && !isAuto ? .check : (continues || action == .showCard ? .arrow : .none)
        // 이름과 조사를 붙여 둔다 — "Codex · 기본 계정" / "에게 이어 맡기기" 로 꺾이지 않게.
        return PopoverRow(provider: agent.provider,
                          title: continues ? HandoffCardText.keepingParticle(ContinueChoice.continueTitle(name: name))
                                           : agent.provider.displayName,
                          detail: continues ? nil : account?.label,
                          subtitle: ContinueChoice.subtitle(for: action, input),
                          meta: meta, shortcut: shortcut ? "⇧⌘H" : nil, trailing: trailing,
                          selected: input.hasCard ? agent == input.cardTarget : (!isAuto && agent == input.chip)) {
            presented = false
            Task { await model.performContinueChoice(action, agent: agent, threadID: thread.id) }
        }
        .disabled(isDisabled(action))
        .help(ContinueChoice.help(for: action, name: name, autoSelected: isAuto, cardUnknown: input.cardUnknown))
        .accessibilityHint(block?.message ?? "")
    }

    /// 끈 행의 까닭 중 행 하나에 걸린 것 (메뉴 전체의 것은 머리 줄이 말한다).
    private func rowBlock(_ action: ContinueChoice.Action) -> ContinueChoice.Block? {
        guard case .disabled(let block) = action, !block.isMenuWide else { return nil }
        return block
    }

    /// "맥락 없이 바꾸기" — 펼치면 에이전트(· 계정)마다 칩만 바꾸는 행과, 그 에이전트가 이 대화에서 무엇을 아는지 (`plainSwitchSubtitle`).
    private func plainSection(_ agents: [HandoffSource.Agent], input: ContinueChoiceInput) -> some View {
        let block = ContinueChoice.plainSwitchBlock(input)
        // 꺼졌으면 머리(화살표 · 이름)만 흐리게 — 오른쪽의 까닭("인계 카드가 있음")은 흐리지 않는다 (vis-3, `PopoverRow` 와 같다).
        let dim: Double = block == nil ? 1 : 0.45
        return VStack(alignment: .leading, spacing: 1) {
            Button { plainExpanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(plainExpanded && block == nil ? 90 : 0))
                        .foregroundStyle(Theme.slate2)
                        .frame(width: 13)
                        .opacity(dim)
                    // 위 행("… 에게 이어 맡기기" — 맥락을 문서로 넘긴다)과 대비되게: 맥락 없이 받을 에이전트만 바꾼다.
                    Text(Self.plainSwitchTitle)
                        .font(Theme.ui(.caption, .medium))
                        .foregroundStyle(Theme.slate)
                        .opacity(dim)
                    Spacer(minLength: 8)
                    // 끈 까닭이 이 묶음에만 걸린 것(카드가 있음)이면 그 까닭을, 아니면 하는 일을 (메뉴 전체의 까닭은 머리 줄이 말한다).
                    Text(block?.meta ?? "받을 에이전트만 바꿉니다")
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate2)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(PopoverRowButtonStyle())
            .disabled(block != nil)
            .help(block?.message ?? "지금까지의 맥락을 넘기지 않고 다음 메시지를 받을 에이전트만 바꿉니다")
            .accessibilityLabel(Self.plainSwitchTitle)
            .accessibilityValue(plainExpanded && block == nil ? "펼침" : "접힘")
            .accessibilityHint(block?.message ?? "")
            if plainExpanded && block == nil {
                ForEach(agents, id: \.self) { agent in plainRow(agent, input: input) }
            }
        }
    }

    static let plainSwitchTitle = "맥락 없이 바꾸기"

    /// "맥락 없이 바꾸기" 의 행 하나 — 받을 에이전트만 바꾼다 (`ContinueChoice.plainSwitchAction`). 이어 맡기기를 막는 로그인 상태는
    /// 여기서는 막지 않고 알려만 준다 (바꿔 두고 터미널에서 로그인할 수 있다).
    private func plainRow(_ agent: HandoffSource.Agent, input: ContinueChoiceInput) -> some View {
        let action = ContinueChoice.plainSwitchAction(for: agent, input)
        let name = model.handoffPartyName(agent)
        let block = rowBlock(action)
        let meta = block?.meta ?? input.handoffBlocks[agent.key]?.meta ?? input.tags[agent.key]
        return PopoverRow(provider: agent.provider, title: agent.provider.displayName, detail: accountOfRow(agent)?.label,
                          subtitle: ContinueChoice.plainSwitchSubtitle(for: agent, name: name, input), meta: meta) {
            presented = false
            Task { await model.performContinueChoice(action, agent: agent, threadID: thread.id) }
        }
        .disabled(isDisabled(action))
        .help(ContinueChoice.help(for: action, name: name, autoSelected: isAuto))
        .accessibilityHint(block?.message ?? "")
    }

    private func isDisabled(_ action: ContinueChoice.Action) -> Bool {
        if case .disabled = action { return true }
        return false
    }

    /// 계정이 둘 이상일 때 Codex 행의 계정 (행에 계정 이름 · 사용률을 붙인다).
    private func accountOfRow(_ agent: HandoffSource.Agent) -> CodexAccount? {
        guard agent.provider == .codex, model.accounts.hasMultiple else { return nil }
        return model.accounts.account(agent.codexAccountID ?? "")
    }

    /// 계정 행의 오른쪽 글 — 두 구간 중 더 많이 쓴 쪽 (값이 없으면 0% 로 쓰지 않는다). 로그인 상태는 이 글이 아니라 모든 입구가 같이
    /// 쓰는 판정(`AppModel.receiverReadiness` → 막은 까닭 · "로그인 미확인" 꼬리표)이 말한다.
    private func accountMeta(_ account: CodexAccount) -> String? {
        guard account.authStatus == .loggedIn else { return nil }
        return model.limits.codex(account.id).windows.compactMap { $0.utilization }.max().map { "사용률 \(Fmt.percent($0))" }
    }

    /// 맨 위의 "자동" 행. 에이전트를 고르면 자동은 풀린다.
    private var autoRow: some View {
        Button {
            model.orchestrationAutoThreadIDs.insert(thread.id)
            presented = false
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink).frame(width: 13)
                Text("자동").font(Theme.ui(.callout, isAuto ? .semibold : .medium)).foregroundStyle(Theme.ink)
                Text("나눠서 배정 · 검증").font(Theme.ui(.callout)).foregroundStyle(Theme.slate).lineLimit(1)
                Spacer(minLength: 8)
                if isAuto {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background { if isAuto { RoundedRectangle(cornerRadius: 6).fill(Theme.well) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("자동: 작업을 나눠 배정하고 검증")
    }

    /// 이 에이전트를 지금 쓸 수 없다고 확인됐으면 그 상태 (`SendReadiness.notice` — 보내면 같은 까닭으로 막힌다).
    private var readinessNotice: String? {
        SendReadiness.notice(provider: provider, readiness: model.sendReadiness(provider: provider, thread: thread),
                             accountLabel: showsAccount ? current.label : nil)
    }

    private var helpText: String {
        if let readinessNotice { return readinessNotice }
        switch provider {
        case .gemini:
            return "Antigravity 턴은 승인을 묻지 않고 파일을 고치고 명령을 실행합니다. "
                + "프로젝트 설정(사이드바의 프로젝트 메뉴)에서 켜야 보낼 수 있습니다."
        case .codex where showsAccount:
            return "다음 메시지를 Codex · \(current.label) (\(current.identityText)) 에게 보냅니다. "
                + "계정마다 한도가 따로이고, 계정을 바꿔도 이 대화의 Codex 세션은 이어집니다."
        default:
            return "다음 메시지를 \(provider.displayName) 에게 보냅니다. 기록이 있는 대화에서 다른 에이전트를 고르면 인계 초안을 먼저 보여 줍니다."
        }
    }
}

/// 팝오버의 한 행: 로고 · 이름 · (계정) · 오른쪽 보조 글자 · 단축키 · 끝 표시, 그 아래 작은 글(부제) 한두 줄. 포인터를 올리면 옅은 바탕.
private struct PopoverRow: View {
    /// 행 끝의 표시 — 지금 고른 것은 체크, 카드 · 인계로 이어지는 동작은 화살표.
    enum Trailing { case none, check, arrow }

    let provider: AgentProvider
    let title: String
    /// 이름 옆의 보조 이름 (Codex 계정).
    var detail: String?
    /// 이름 아래 작은 글 — 누르면 무엇이 되는지 · 그 에이전트가 이 대화에서 무엇을 아는지.
    var subtitle: String?
    var meta: String?
    var shortcut: String?
    var trailing: Trailing = .none
    var selected = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        // 꺼진 행은 이름 · 로고 · 부제만 흐리게 — 오른쪽의 까닭(`meta` — "로그인 필요" · "설정에서 허용 필요")은 흐리지 않는다.
        // 행 전체에 흐림을 걸면 까닭 글이 흰 바탕에서 1.3:1 로 읽히지 않았다 (vis-3 — 왜 못 누르는지가 도움말에만 남았다).
        let dim: Double = isEnabled ? 1 : 0.45
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                BrandMark(provider: provider, size: 13)
                    .frame(height: 16)
                    .opacity(dim)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        // 줄이지 않고 접는다 — 행 글이 곧 누르면 할 일이다 ("… 에게 이어 맡기기" 의 끝이 잘리면 뜻이 빠진다).
                        Text(title)
                            .font(Theme.ui(.callout, selected ? .semibold : .medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .opacity(dim)
                        if let detail {
                            Text(detail)
                                .font(Theme.ui(.callout))
                                .foregroundStyle(Theme.slate)
                                .lineLimit(1)
                                .opacity(dim)
                        }
                        Spacer(minLength: 8)
                        if let meta {
                            // 흐리지 않는다 — `slate2` 는 흰 바탕 4.7:1 (꺼진 행이면 이것이 그 까닭이다).
                            Text(meta)
                                .font(Theme.ui(.caption))
                                .foregroundStyle(Theme.slate2)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        if let shortcut {
                            Text(shortcut)
                                .font(Theme.mono(.caption))
                                .foregroundStyle(Theme.slate2)
                                .fixedSize()
                                .opacity(dim)
                        }
                        Group {
                            switch trailing {
                            case .check:
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.ink)
                            case .arrow:
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Theme.slate2)
                            case .none:
                                EmptyView()
                            }
                        }
                        .opacity(dim)
                    }
                    .frame(minHeight: 16)
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.ui(.caption))
                            .foregroundStyle(Theme.slate)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .opacity(dim)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, subtitle == nil ? 6 : 7)
            .frame(minHeight: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if selected { RoundedRectangle(cornerRadius: 6).fill(Theme.well) }
                else if hovering && isEnabled { RoundedRectangle(cornerRadius: 6).fill(Theme.wellSoft) }
            }
        }
        .buttonStyle(PopoverRowButtonStyle())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 팝오버 행의 단추 모양 — 꾸밈 없이 그대로 두고 누르는 동안만 옅게. 꺼진 행의 흐림은 행이 부분마다 정한다: `.plain` 은 꺼진 단추의
/// 내용 전체를 한 번 더 흐려(행의 0.45 와 겹쳐 0.2 남짓) 오른쪽의 까닭 글이 흰 바탕에서 1.3:1 이었다 (vis-3).
private struct PopoverRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - ↵ 보내기

/// 입력창의 ↵ 는 보내기, ⇧↵ · ⌥↵ · ⌃↵ 는 줄바꿈.
///
/// SwiftUI `TextEditor` 뒤의 NSTextView 를 찾아 delegate 앞에 대리자(`ReturnKeyDelegate`)를 끼우고 `insertNewline:` 만 가로챈다.
/// 키 이벤트를 앞에서 잡지 않는 이유: 한글처럼 조합 중인 입력은 IME 가 ↵ 를 받아 먼저 글자를 확정한 뒤에야 `insertNewline:` 이
/// 오므로, 이 단계에서 보내야 마지막 글자가 빠지거나 따로 가지 않는다 (`onKeyPress` · NSEvent 감시는 IME 앞에서 잡는다).
/// SwiftUI 가 delegate 를 다시 걸 수 있어 `updateNSView`(초안이 바뀔 때마다) 와 배치 때 끼워져 있는지 확인한다.
private struct ComposerReturnKey: NSViewRepresentable {
    /// 값 자체는 쓰지 않는다 — 바뀔 때마다 `updateNSView` 가 불려 대리자를 확인한다.
    var draft: String
    /// 올라갈 때마다 조합 중인 글을 확정시킨다 (보내기 원을 눌렀을 때).
    var commitSerial: Int
    /// 포커스 칸의 입력창이면 처음 나타날 때 글자 입력을 받는다 (앱을 켤 때 · 대화를 고를 때). 아니면 AppKit 이 창의 첫
    /// 텍스트 칸인 사이드바 검색을 잡아, "어떤 작업을 할까요?" 에서 바로 친 글이 검색칸으로 들어간다.
    var takesInitialFocus = false
    /// 명시적인 포커스 요청의 번호 (`AppModel.requestComposerFocus` — 첫 폴더를 열고 만든 대화). 바뀌면 한 번 가져간다.
    var focusSerial = 0
    /// 그 요청의 시각 — `AppModel.composerFocusLifetime` 이 지난 요청은 가져가지 않고 버린다.
    var focusRequestedAt: Date?
    /// 요청을 받아 포커스를 가져갔다 (그 번호) — 모델이 요청을 지운다 (다시 그려질 때 또 가져가지 않게).
    var onFocusTaken: (Int) -> Void = { _ in }
    var onSend: (String) -> Void
    /// IME 조합 상태 — 조합 중이면 텍스트 뷰의 글, 아니면 nil. 글이 바뀔 때마다 알린다.
    var onComposition: (String?) -> Void
    /// 이미지를 붙였다 (⌘V · 끌어 놓기): 이미지 파일들 · 붙여넣은 이미지 데이터.
    var onAttach: ([URL], [Data]) -> Void = { _, _ in }
    /// esc (`cancelOperation:`) — 인수는 글이 비었는지. 처리했으면 true (텍스트 뷰의 기본 동작을 하지 않는다).
    var onEscape: (Bool) -> Bool = { _ in false }
    /// 올라갈 때마다 글 전체를 `replaceText` 로 바꾼다 ("/" 목록에서 고른 명령).
    var replaceSerial = 0
    var replaceText = ""
    /// "/" 목록이 먼저 받는 키 (↑ ↓ · ⇥ ↵ · esc) — 받았으면 true.
    var onSlashKey: (ComposerSlashKey) -> Bool = { _ in false }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.takesInitialFocus = takesInitialFocus
        view.focusSerial = focusSerial
        view.focusRequestedAt = focusRequestedAt
        view.onFocusTaken = onFocusTaken
        view.onSend = onSend
        view.onComposition = onComposition
        view.onAttach = onAttach
        view.onEscape = onEscape
        view.onSlashKey = onSlashKey
        view.replaceSerial = replaceSerial
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.takesInitialFocus = takesInitialFocus
        nsView.focusSerial = focusSerial
        nsView.focusRequestedAt = focusRequestedAt
        nsView.onFocusTaken = onFocusTaken
        nsView.onSend = onSend
        nsView.onComposition = onComposition
        nsView.onAttach = onAttach
        nsView.onEscape = onEscape
        nsView.onSlashKey = onSlashKey
        nsView.install()
        if nsView.commitSerial != commitSerial {
            nsView.commitSerial = commitSerial
            nsView.commitComposition()
        }
        if nsView.replaceSerial != replaceSerial {
            nsView.replaceSerial = replaceSerial
            // 화면을 그리는 도중에 글을 바꾸면 그 사이 binding 이 바뀐다 — 다음 차례에.
            let text = replaceText
            DispatchQueue.main.async { [weak nsView] in nsView?.replaceAll(with: text) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ProbeView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class ProbeView: NSView {
        var onSend: ((String) -> Void)?
        var onComposition: ((String?) -> Void)?
        var onAttach: (([URL], [Data]) -> Void)?
        var onEscape: ((Bool) -> Bool)?
        var onSlashKey: ((ComposerSlashKey) -> Bool)?
        var commitSerial = 0
        var replaceSerial = 0
        var takesInitialFocus = false
        var focusSerial = 0
        var focusRequestedAt: Date?
        var onFocusTaken: ((Int) -> Void)?
        /// 첫 포커스는 한 번만 가져간다 — 그 뒤로는 사용자가 옮긴 자리를 존중한다.
        private var tookInitialFocus = false
        /// 처리한 명시적 요청 번호.
        private var handledFocusSerial = 0
        private let proxy = ReturnKeyDelegate()
        private weak var textView: NSTextView?
        /// ⌘V 감시 (창에 있는 동안만). 이 입력창의 텍스트 뷰가 첫 응답자이고 클립보드에 이미지가 있을 때만 가로챈다.
        private var pasteMonitor: Any?

        deinit {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        }

        /// ⌘V: 텍스트 뷰는 평문만 붙인다 — 이미지 데이터는 버리고, 복사한 파일은 이름만 넣는다. 이미지면 여기서 받고, 이미지 아닌
        /// 파일(Finder 에서 복사한 PDF · 로그)은 이름 대신 경로를 글로 넣는다 (끌어 놓기와 같게 — chat-12).
        private func updatePasteMonitor() {
            if window == nil {
                if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
                pasteMonitor = nil
                return
            }
            guard pasteMonitor == nil else { return }
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let textView = self.textView, textView.window?.firstResponder === textView,
                      ComposerPaste.isPasteShortcut(event) else { return event }
                let others = ComposerPaste.otherFiles(from: .general)
                let pasted = ComposerPaste.images(from: .general)
                guard pasted != nil || !others.isEmpty else { return event }
                if let pasted { self.onAttach?(pasted.files, pasted.data) }
                if !others.isEmpty {
                    textView.insertText(others.map(\.path).joined(separator: " "), replacementRange: textView.selectedRange())
                }
                return nil
            }
        }

        /// 조합 중인 글을 문서에 남긴 채 조합을 끝낸다 — 텍스트 뷰의 marked 범위를 풀고 입력기의 조합 상태도 버린다.
        func commitComposition() {
            guard let textView, textView.hasMarkedText() else { return }
            textView.unmarkText()
            textView.inputContext?.discardMarkedText()
            onComposition?(nil)
        }

        /// 글 전체를 바꾸고 캐럿을 끝에 둔다 — 텍스트 뷰에서 바꿔 대리자 · binding 이 평소처럼 따라오고 ⌘Z 로 되돌릴 수 있다.
        func replaceAll(with text: String) {
            guard let textView else { return }
            commitComposition()
            textView.window?.makeFirstResponder(textView)
            textView.insertText(text, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
        }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updatePasteMonitor()
            // TextEditor 의 텍스트 뷰는 같은 배치 차례에 만들어진다 — 다음 런루프에서 찾는다.
            DispatchQueue.main.async { [weak self] in self?.install() }
        }

        override func layout() {
            super.layout()
            install()
        }

        /// 텍스트 뷰를 찾아 대리자를 끼운다. 이미 끼워져 있으면 아무것도 하지 않는다.
        func install() {
            proxy.onSend = { [weak self] text in self?.onSend?(text) }
            proxy.onEscape = { [weak self] empty in self?.onEscape?(empty) ?? false }
            proxy.onSlashKey = { [weak self] key in self?.onSlashKey?(key) ?? false }
            proxy.onChange = { [weak self] textView in
                self?.onComposition?(textView.hasMarkedText() ? textView.string : nil)
            }
            proxy.onAttachFiles = { [weak self] files in self?.onAttach?(files, []) }
            if textView == nil || textView?.window == nil { textView = Self.findTextView(near: self) }
            guard let textView else { return }
            if textView.delegate !== proxy {
                // 다른 입력창의 대리자가 이미 끼워진 텍스트 뷰는 남의 것이다 (분할 화면에는 입력창이 여럿이다). 그것을 또 감싸면
                // 두 대리자가 서로를 `original` 로 가리켜 `responds(to:)` 가 끝없이 돈다 (2026-09-21 네 칸에서 크래시).
                guard !(textView.delegate is ReturnKeyDelegate) else {
                    self.textView = nil
                    return
                }
                proxy.original = textView.delegate
                proxy.lastText = textView.string
                textView.delegate = proxy
            }
            // 여기부터는 이 입력창의 텍스트 뷰다 — 남의 것이면 위에서 돌아갔다 (다른 칸 입력창에 포커스를 주지 않게).
            PlainTextInput.apply(to: textView)
            if takesInitialFocus, !tookInitialFocus, let window = textView.window {
                tookInitialFocus = true
                if Self.canTakeFocus(from: window.firstResponder) { window.makeFirstResponder(textView) }
            }
            // 명시적인 요청(폴더를 막 열었다)은 지금 응답자와 상관없이 가져간다 — 폴더 고르기 창이 남긴 응답자를 따지지 않는다.
            // 요청이 오래됐으면(입력창이 늦게 그려졌다 · 나중의 배치) 가져가지 않고 버린다 — 그사이 사용자가 쓰던 칸을 지킨다.
            if focusSerial != 0, focusSerial != handledFocusSerial, let window = textView.window {
                handledFocusSerial = focusSerial
                let fresh = focusRequestedAt.map { Date().timeIntervalSince($0) <= AppModel.composerFocusLifetime } ?? false
                if fresh { window.makeFirstResponder(textView) }
                let serial = focusSerial
                // 배치 도중에는 SwiftUI 상태를 바꿀 수 없다 — 다음 차례에 알린다.
                DispatchQueue.main.async { [weak self] in self?.onFocusTaken?(serial) }
            }
        }

        /// 입력창이 처음 나타날 때 글자 입력을 가져가도 되는지: 아무것도 입력을 받고 있지 않거나(창 자신), 비어 있는
        /// 검색칸(앱을 켜면 AppKit 이 창의 첫 텍스트 칸인 사이드바 검색을 잡는다)일 때만. 그 밖의 응답자는 두어 — 사이드바
        /// 목록의 ↑↓(SwiftUI 포커스)로 대화를 훑는 중이면 다음 ↓ 가 입력창으로 가지 않게, 커밋 메시지 · 터미널에서 쓰는
        /// 중이면 빼앗지 않게, 검색어를 친 검색칸도 그대로.
        static func canTakeFocus(from responder: NSResponder?) -> Bool {
            guard let responder, !(responder is NSWindow) else { return true }
            if let textView = responder as? NSTextView { return textView.isFieldEditor && textView.string.isEmpty }
            return false
        }

        /// 이 뷰(TextEditor 의 background)에서 가장 가까운 편집용 NSTextView. 조상을 몇 단계 올라가며 자손을 찾는다.
        static func findTextView(near view: NSView) -> NSTextView? {
            var ancestor = view.superview
            var depth = 0
            while let current = ancestor, depth < 6 {
                if let found = firstTextView(in: current, excluding: view) { return found }
                ancestor = current.superview
                depth += 1
            }
            return nil
        }

        /// 필드 에디터(TextField 의 편집기)는 제외한다. 이 뷰는 자기 TextEditor 의 배경이므로 **겹쳐 있는** 텍스트 뷰만 자기 것이다 —
        /// 분할 화면의 다른 칸 입력창(이 뷰의 TextEditor 가 아직 텍스트 뷰를 만들기 전에 조상을 오르다 만날 수 있다)은 거른다.
        static func firstTextView(in view: NSView, excluding: NSView?) -> NSTextView? {
            if let textView = view as? NSTextView, !textView.isFieldEditor, textView.isEditable {
                guard let probe = excluding, probe.window != nil, textView.window === probe.window else { return textView }
                // 텍스트 뷰의 bounds 는 스크롤로 가려진 부분까지 담은 문서 전체다 — 보이는 부분(visibleRect)으로 겹침을 본다.
                let own = probe.convert(probe.bounds, to: nil), candidate = textView.convert(textView.visibleRect, to: nil)
                return own.intersects(candidate) ? textView : nil
            }
            for sub in view.subviews where sub !== excluding {
                if let found = firstTextView(in: sub, excluding: excluding) { return found }
            }
            return nil
        }
    }
}

/// NSTextView delegate 대리자. `insertNewline:` 만 처리하고 나머지 호출은 모두 원래 delegate(SwiftUI 의 것)로 넘긴다.
private final class ReturnKeyDelegate: NSObject, NSTextViewDelegate {
    weak var original: NSTextViewDelegate?
    var onSend: ((String) -> Void)?
    /// esc — 인수는 글이 비었는지 (조합 중이면 비지 않은 것으로). 처리했으면 true.
    var onEscape: ((Bool) -> Bool)?
    /// "/" 목록이 먼저 받는 키. 받았으면 true.
    var onSlashKey: ((ComposerSlashKey) -> Bool)?
    var onChange: ((NSTextView) -> Void)?
    var onAttachFiles: (([URL]) -> Void)?

    /// 파일을 끌어 놓거나 경로를 붙여넣으면 텍스트 뷰는 경로를 글로 넣는다 (화면 캡처 썸네일을 끌어 놓으면 임시 폴더 경로가 들어갔다).
    /// 넣으려는 글이 통째로 이미지 파일 경로(들)면 글 대신 이미지로 붙인다. 그 밖의 글은 원래 대리자에게 넘긴다.
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if let replacementString, !textView.hasMarkedText(), let files = ImageAttachments.imagePaths(in: replacementString) {
            onAttachFiles?(files)
            return false
        }
        return original?.textView?(textView, shouldChangeTextIn: affectedCharRange, replacementString: replacementString) ?? true
    }

    /// 글이 확정돼 바뀔 때. SwiftUI 의 원래 delegate 가 binding 을 갱신하도록 먼저 넘긴다.
    /// **조합 중(marked text)의 변화에는 오지 않는다** — 확정될 때만 온다 (2026-09-28 실측: `setMarkedText` 에는 `shouldChangeTextIn` ·
    /// 선택 변경만 오고 `textDidChange` 는 없다). 조합 중의 글은 아래 선택 변경에서 읽는다.
    func textDidChange(_ notification: Notification) {
        original?.textDidChange?(notification)
        guard let textView = notification.object as? NSTextView else { return }
        let before = lastText
        lastText = textView.string
        // 위의 `shouldChangeTextIn` 을 거치지 않고 들어온 경로도 잡는다 (끌어 놓기의 다른 길): 새로 들어온 조각이 통째로
        // 이미지 경로면 글에서 빼고 이미지로 붙인다.
        if let (range, files) = Self.insertedImagePaths(before: before, after: lastText) {
            onAttachFiles?(files)
            let inserted = (lastText as NSString).substring(with: range)
            DispatchQueue.main.async { [weak textView] in
                guard let textView, NSMaxRange(range) <= (textView.string as NSString).length,
                      (textView.string as NSString).substring(with: range) == inserted else { return }
                textView.insertText("", replacementRange: range)
            }
        }
        onChange?(textView)
    }

    /// 마지막으로 본 글 — 새로 들어온 조각을 가려낸다 (`textDidChange`). 끼울 때 텍스트 뷰의 글로 맞춘다.
    var lastText = ""

    /// 바뀌기 전 · 뒤 글에서 새로 들어온 조각이 통째로 이미지 경로(들)면 그 범위와 파일. 아니면 nil.
    static func insertedImagePaths(before: String, after: String) -> (NSRange, [URL])? {
        let old = before as NSString, new = after as NSString
        guard new.length > old.length else { return nil }
        var prefix = 0
        while prefix < old.length, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < old.length - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        let range = NSRange(location: prefix, length: new.length - prefix - suffix)
        guard range.length > 2, let files = ImageAttachments.imagePaths(in: new.substring(with: range)) else { return nil }
        return (range, files)
    }

    /// 선택(캐럿)이 바뀔 때 — 입력기가 조합 중인 글을 넣고 바꿀 때마다 온다 (바뀐 뒤라 `hasMarkedText` · 글이 맞다).
    /// 한글 첫 글자를 조합하는 동안 플레이스홀더 · 보내기 원이 그 글을 알아보는 길이 이것이다 (`ComposerView.composing`).
    func textViewDidChangeSelection(_ notification: Notification) {
        original?.textViewDidChangeSelection?(notification)
        if let textView = notification.object as? NSTextView { onChange?(textView) }
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // "/" 목록이 떠 있으면 ↑ ↓ · ⇥ ↵ · esc 를 먼저 받는다 (조합 중이면 입력기의 것이다).
        if !textView.hasMarkedText(),
           let key = ComposerSlashKey(selector: commandSelector,
                                      flags: NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []),
           onSlashKey?(key) == true {
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            // 수식키가 있으면 텍스트 뷰가 줄바꿈을 넣는다.
            guard flags.isDisjoint(with: [.shift, .option, .control, .command]) else { return false }
            onSend?(textView.string)
            return true
        }
        // esc: CLI 습관대로 실행을 멈추는 길 — 실행 중이고 글이 비었을 때 두 번 (`ComposerEscape`). 그 밖은 원래대로.
        if commandSelector == #selector(NSResponder.cancelOperation(_:)),
           onEscape?(textView.string.isEmpty && !textView.hasMarkedText()) == true {
            return true
        }
        return original?.textView?(textView, doCommandBy: commandSelector) ?? false
    }
}

#if DEBUG
/// `-preview.typeKeys "d k s ret"` (AHC_OFFLINE=1) — 입력창 텍스트 뷰를 첫 응답자로 만들고 키 이벤트를 넣어 ↵ 보내기를 확인한다.
/// 토큰: 한 글자(a–z · 0–9) · `sp`(공백) · `ret` · `sret`(⇧↵) · `oret`(⌥↵) · `up` · `down` · `tab` · `esc` ("/" 목록).
/// 현재 입력 소스가 한글이면 IME 조합을 거친다.
/// 토큰마다 텍스트 뷰의 글 · 조합 중 여부 · 대리자 유지 여부를 `sweep.log` 에 남긴다. 보내기는 `ComposerView.send` 가 `SEND` 줄로 남긴다.
@MainActor
enum ComposerKeyTyping {
    static func run(_ spec: String) async {
        var textView: NSTextView?
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  let root = window.contentView else { continue }
            if let found = ComposerReturnKey.ProbeView.firstTextView(in: root, excluding: nil) { textView = found; break }
        }
        guard let textView, let window = textView.window else { SplitDividerSweep.log("typeKeys: no text view"); return }
        // `-preview.activate YES` — 앱을 앞으로 가져와 창을 키 창으로 만들고 이벤트를 실제 큐로 넣는다. 그래야 IME(한글 조합)가 붙고
        // `NSApp.currentEvent` 가 그 키 이벤트가 된다 (⇧↵ 판정). 아니면 뒤에서 `keyDown` 을 직접 부른다 — IME 없이, 수식키 판정 없이.
        let activate = UserDefaults.standard.bool(forKey: "preview.activate")
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(600))
        }
        let became = window.makeFirstResponder(textView)
        SplitDividerSweep.log("typeKeys: firstResponder=\(became) active=\(NSApp.isActive) key=\(window.isKeyWindow) "
                              + "delegate=\(textView.delegate.map { String(describing: type(of: $0)) } ?? "-") "
                              + "inputSource=\(textView.inputContext?.selectedKeyboardInputSource ?? "-")")
        let codes: [Character: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
                                          "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
                                          "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35,
                                          "l": 37, "j": 38, "k": 40, "n": 45, "m": 46]
        for token in spec.split(separator: " ") {
            // `insert:/경로/a.png` — 끌어 놓기 · 붙여넣기처럼 글을 한 번에 넣는다 (`insertText` → 대리자의 `shouldChangeTextIn`).
            // 빈칸은 `%20`. 이미지 경로면 글 대신 첨부가 돼야 한다.
            if token.hasPrefix("insert:") {
                let inserted = String(token.dropFirst("insert:".count)).replacingOccurrences(of: "%20", with: " ")
                window.makeFirstResponder(textView)
                textView.insertText(inserted, replacementRange: textView.selectedRange())
                try? await Task.sleep(for: .milliseconds(300))
                SplitDividerSweep.log("typeKeys: after insert text=\"\(textView.string)\"")
                continue
            }
            // `mark:ㅅ` — 입력기가 조합 중인 글을 넣는 것과 같은 호출(`setMarkedText`)을 직접 한다. 이 Mac 의 입력 소스와 무관하게
            // 한글 첫 글자를 조합하는 상태(바인딩은 아직 빈 값)를 만든다.
            if token.hasPrefix("mark:") {
                let marked = String(token.dropFirst("mark:".count))
                window.makeFirstResponder(textView)
                textView.setMarkedText(marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0),
                                       replacementRange: NSRange(location: NSNotFound, length: 0))
                try? await Task.sleep(for: .milliseconds(300))
                SplitDividerSweep.log("typeKeys: after \(token) text=\"\(textView.string)\" marked=\(textView.hasMarkedText()) "
                                      + "proxied=\(textView.delegate is ReturnKeyDelegate) "
                                      + "delegate=\(textView.delegate.map { String(describing: type(of: $0)) } ?? "-")")
                continue
            }
            var flags: NSEvent.ModifierFlags = []
            let code: UInt16
            let chars: String
            switch token {
            case "ret": code = 36; chars = "\r"
            case "sret": code = 36; chars = "\r"; flags = .shift
            case "oret": code = 36; chars = "\n"; flags = .option
            case "sp": code = 49; chars = " "
            case "up": code = 126; chars = String(UnicodeScalar(NSUpArrowFunctionKey)!); flags = [.numericPad, .function]
            case "down": code = 125; chars = String(UnicodeScalar(NSDownArrowFunctionKey)!); flags = [.numericPad, .function]
            case "tab": code = 48; chars = "\t"
            case "esc": code = 53; chars = "\u{1b}"
            default:
                // 한글 자모 토큰(ㅇ ㅏ ㄴ …)은 2벌식 자리의 키 코드와 함께 넣는다 — 실제 타건은 입력 소스의 배열이 자모를 `characters` 에
                // 담아 오고 IME 는 그 자모를 조합한다. 로마자를 넣으면 IME 가 조합하지 않고 그대로 넣는다.
                let jamoKeys: [Character: Character] = ["ㅂ": "q", "ㅈ": "w", "ㄷ": "e", "ㄱ": "r", "ㅅ": "t", "ㅛ": "y", "ㅕ": "u", "ㅑ": "i",
                                                        "ㅐ": "o", "ㅔ": "p", "ㅁ": "a", "ㄴ": "s", "ㅇ": "d", "ㄹ": "f", "ㅎ": "g", "ㅗ": "h",
                                                        "ㅓ": "j", "ㅏ": "k", "ㅣ": "l", "ㅋ": "z", "ㅌ": "x", "ㅊ": "c", "ㅍ": "v", "ㅠ": "b",
                                                        "ㅜ": "n", "ㅡ": "m"]
                guard token.count == 1, let c = token.first, let k = codes[c] ?? jamoKeys[c].flatMap({ codes[$0] }) else {
                    SplitDividerSweep.log("typeKeys: skip \(token)"); continue
                }
                code = k; chars = String(c)
            }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                   context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                                   isARepeat: false, keyCode: code) else { continue }
                if activate { NSApp.postEvent(event, atStart: false) }
                else if type == .keyDown { textView.keyDown(with: event) } else { textView.keyUp(with: event) }
            }
            try? await Task.sleep(for: .milliseconds(150))
            SplitDividerSweep.log("typeKeys: after \(token) text=\"\(textView.string)\" marked=\(textView.hasMarkedText()) "
                                  + "proxied=\(textView.delegate is ReturnKeyDelegate)")
        }
        SplitDividerSweep.log("typeKeys: done")
    }
}
#endif

/// 실행 중 보내기 원 옆의 안내. 메인 턴을 마치고 백그라운드 작업을 기다리는 중이면 그 수와 함께.
/// 하위 작업의 진행(초당 여러 번)을 여기서만 읽는다.
private struct RunningKeyHint: View {
    @Environment(AppModel.self) private var model
    let threadID: String

    var body: some View {
        let session = model.runner.session(threadID: threadID)
        let waiting = session.map { $0.isWaitingOnBackground && $0.state != .interrupting } ?? false
        // CLI 습관대로 esc 로도 멈춘다 — 빈 입력창에서 두 번 (`ComposerEscape`).
        Text(waiting ? SubAgentDigest.waitingKeyHint(count: session?.unfinishedSubAgentCount ?? 0) : "esc 두 번 · ⌘. 중단")
            .font(Theme.ui(.caption))
            .foregroundStyle(Theme.slate2)
            .lineLimit(1)
            .fixedSize()
    }
}

/// 실행 중의 중단 원. 하위 작업이 남아 있으면 그것까지 멈춘다고 알린다 (중단은 실행 전체를 멈춘다) — 백그라운드 작업이
/// 남았는지, 메인 턴 중의 포그라운드 하위 에이전트뿐인지를 가른다.
private struct RunStopButton: View {
    @Environment(AppModel.self) private var model
    let threadID: String

    var body: some View {
        let session = model.runner.session(threadID: threadID)
        let text = SubAgentDigest.stopButtonText(waiting: session?.isWaitingOnBackground ?? false,
                                                 background: session?.unfinishedBackgroundCount ?? 0,
                                                 unfinished: session?.unfinishedSubAgentCount ?? 0)
        Button {
            Task { await model.runner.interrupt(threadID: threadID) }
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.danger))
        }
        .buttonStyle(.plain)
        // 좁은 칸에서는 "⌘. 중단" 안내가 없다 — 단축키는 도움말에 (chat-29).
        .help(text.help + " (⌘. · 빈 입력창에서 esc 두 번)")
        .accessibilityLabel(text.label)
    }
}
