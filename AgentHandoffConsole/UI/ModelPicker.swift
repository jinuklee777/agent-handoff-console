import SwiftUI

/// 모델 칩 "모델 | 강도" (캔버스 시안 B — 사용자 결정 2026-10-07. 예전의 강도 카드 · 슬라이더를 대신한다).
///
/// 누르면 팝오버. 처음은 강도 쪽: 위에 지금 모델 한 줄(누르면 모델 쪽으로), 아래 강도 목록 — 단계마다 단계 색 점 · 이름 ·
/// "기본"(고르지 않으면 보낼 단계 — `EffortScale.defaultMark`) · 고른 단계의 체크. 단계 설명은 두지 않고 한도를 크게 쓰는
/// MAX · ULTRA 만 한 줄 (`EffortScale.rowNote`). 강도를 바꾸면 고른 바탕과 체크가 새 행으로 미끄러진다 (`selectionMotion`),
/// 칩의 강도 이름도 바뀐 글자로 부드럽게 넘어간다. ↑ ↓ (← →) 로 한 단계씩.
/// 모델 쪽: 모델 목록(카탈로그 설명 · 새로고침). Claude 의 긴 문맥 별칭(`opus[1m]`)은 행이 아니라 아래 스위치 하나로 고른다
/// (`ModelCatalog.baseOptions`). 바닥 "이 대화에 적용됩니다 · 새 대화는 마지막에 쓴 모델로 시작합니다". 목록은 설치된 CLI 에서
/// 조회한 값만 쓴다. 모델을 아직 정하지 않은 대화는 보낼 때 정해질 값(이어받기 → 기본 — `AppModel.effectiveSelection`)을 보인다.
/// 고르지 않은 강도(nil)는 기본 강도의 차례(설정의 기본 강도 → Codex 는 config.toml → 그 모델의 기본 → High · Antigravity 는 High)로
/// 보인다 (`EffortScale.displayEffort` — 보내기와 같은 함수). 보낼 수 없는 선택이면 칩에 경고 · 목록 아래에 이유를 보인다
/// (`AntigravityAdapter.plan`).
struct ModelPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    let provider: AgentProvider
    let thread: ConversationThread
    /// 입력창 조작 줄의 밀도 — 가장 좁으면 짧은 이름 ("Sol · High"), 그래도 안 들어가면 강도만 (cap-8).
    var density: ComposerDensity = .full
    /// MAX 를 막 골랐다 — 칩의 불꽃 글자가 잠깐 흐른다 (평소에는 멈춘 그림 — chat-9).
    var celebrating = false
    /// 강도를 고르거나(목록 · 키) 되돌릴 때(nil). 입력창이 선택을 저장하고 연출(xhigh 깜빡임 · MAX/ULTRA 촉각 · 소리)을 한다.
    let chooseEffort: (String?) -> Void

    @State private var presented = false
    /// 팝오버의 어느 쪽인지 — 열 때마다 강도 쪽부터.
    @State private var page: Page = .effort
    /// 방금 고른 강도 — 스레드 선택에 반영될 때까지. 반영 전에 체크가 옛 행으로 튀거나, ↑ ↓ 를 빨리 두 번 누른 것이
    /// 옛 값에서 다시 계산돼 한 번으로 줄지 않게 한다. 반영되면(같은 값이 되면) 비우고, 2초 안에 반영되지 않으면 버린다(실제 값을 보인다).
    @State private var pending: PendingEffort?
    @State private var pendingSerial = 0
    @FocusState private var listFocused: Bool
    /// 고른 바탕 · 체크가 행을 옮겨 갈 때 같은 것으로 이어 그리는 이름 공간 (matchedGeometryEffect).
    @Namespace private var selectionSpace

    private enum Page { case effort, models }

    private struct PendingEffort: Equatable {
        /// nil = 기본 강도로 되돌림.
        var effort: String?
        var serial: Int
    }

    private var scope: AgentScope { thread.scope(for: provider) }
    private var catalog: ModelCatalogSnapshot? { model.modelCatalogs[scope] }
    private var options: [AgentModelOption] {
        ModelCatalog.presentableOptions(catalog?.options ?? [])
    }
    /// 보낼 때 쓸 선택 — 모델을 정해 둔 대화는 그 값, 아니면 이어받기 → 기본 (`AppModel.effectiveSelection`, 보내기 · 인계 카드와 같다).
    private var selection: ModelSelection { model.effectiveSelection(for: thread, provider: provider) }
    private var refreshing: Bool { model.refreshingModels.contains(scope) }
    /// 화면이 보여 주는 강도 — 방금 고른 값이 있으면 그것, 아니면 선택.
    private var currentEffort: String? { pending.map(\.effort) ?? selection.effort }
    /// 고르지 않은 강도를 풀 재료 (설정의 기본 강도 · Codex 계정의 config.toml).
    private var effortDefaults: EffortScale.Defaults { model.effortDefaults(provider: provider, accountID: thread.codexAccountID) }

    private var selectedOption: AgentModelOption? {
        // "default" 는 Claude 에서만 '고르지 않음' 이다. 빈 값("")은 어디서나 '고르지 않음' 이다.
        // Codex 계열 선택(`gpt-*-sol`)은 지금 목록의 그 계열 최신 행이다. Antigravity 의 고르지 않은 모델은 판정의 앱 기본 모델.
        if let id = selection.model, !id.isEmpty, !(provider == .claude && id == "default") {
            return ModelCatalog.option(for: id, in: options)
        }
        return provider == .gemini ? ModelCatalog.preferredOption(in: options) : nil
    }
    /// 모델 목록에서 고른 행 — 긴 문맥 별칭을 골랐으면 그 바탕 행.
    private var selectedRow: AgentModelOption? {
        selectedOption.map { ModelCatalog.baseOption(of: $0, in: options) }
    }

    /// 지금 모델이 받는 강도 (카탈로그 값만)와, 없으면 그 이유.
    private var availability: EffortScale.Availability {
        EffortScale.availability(provider: provider, selectedModel: selection.model, options: catalog?.options ?? [])
    }
    private var efforts: [String] { availability.efforts }
    private var steps: [EffortScale.Step] { EffortScale.steps(efforts) }
    /// 화면에 보이는 강도 = 실제로 넘길 값 (nil → 기본 강도의 차례 · Antigravity 는 High).
    private var displayedEffort: String? {
        guard provider != .gemini else {
            return EffortScale.displayEffort(provider: provider, selected: currentEffort, efforts: efforts)
        }
        return EffortScale.displayEffort(provider: provider, selected: currentEffort, availability: availability,
                                         defaults: effortDefaults)
    }
    /// Antigravity 로 보낼 값 (보내기 · 인계와 같은 판정). 그 밖의 제공자는 nil.
    private var planOutcome: AntigravityAdapter.TurnOutcome? {
        guard provider == .gemini else { return nil }
        return AntigravityAdapter.plan(model: selection.model, effort: currentEffort, options: catalog?.options ?? [])
    }
    /// Antigravity 로 보낼 수 없는 선택이면 그 이유.
    private var sendBlock: AntigravityAdapter.TurnBlock? {
        guard case .blocked(let block) = planOutcome else { return nil }
        return block
    }

    /// 강도 · 모델 선택이 바뀔 때 고른 바탕 · 체크가 옮겨 가는 움직임. 동작 줄이기면 곧바로.
    private var selectionMotion: Animation? { reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.14) }
    /// 칩의 강도 이름이 바뀔 때 (글자 · 칩 폭).
    private var chipMotion: Animation? { reduceMotion ? nil : .smooth(duration: 0.26) }

    var body: some View {
        Button { presented.toggle() } label: { chipLabel }
            .buttonStyle(GhostChipStyle(pressed: presented))
            .help(sendBlock?.message ?? EffortScale.chipHelp(provider: provider, outcome: planOutcome, effort: displayedEffort))
            .accessibilityLabel(chipAccessibilityLabel)
            // 입력창은 창 바닥에 있다 — 칩 위로 열고 화살표는 팝오버 아래쪽 (목업). 공간이 모자랄 때만 AppKit 이 뒤집는다.
            // 기준은 칩 앞쪽 끝에서 잰 고정 사각형 (화살표 = 칩 앞 50pt, 목업 pop(left=-96, arrow_left=141) 과 같은 자리).
            // 칩 전체를 기준으로 하면 강도 이름 · 새로고침 스피너로 칩 폭이 바뀔 때마다 열린 팝오버가 옆으로 움직여
            // 누르려던 행이 포인터 밑에서 빠진다 (SwiftUI 는 떠 있는 팝오버도 기준 사각형에 다시 붙인다).
            .popover(isPresented: $presented, attachmentAnchor: .rect(.rect(CGRect(x: 0, y: 0, width: 100, height: 26))),
                     arrowEdge: .top) { pickerContent }
            .onChange(of: presented) { _, open in if !open { page = .effort } }
            .onChange(of: selection.effort) { _, stored in
                if pending?.effort == stored { pending = nil }
            }
            .task(id: pending?.serial) {
                guard pending != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { pending = nil }
            }
            #if DEBUG
            .task {
                // 화면 확인용 (AHC_OFFLINE=1 일 때만): `-preview.action modelPicker` 로 이 팝오버를 연 채 시작한다.
                // `-preview.pickerPage models` 면 모델 쪽을 연다.
                guard AppModel.offlinePreview,
                      UserDefaults.standard.string(forKey: "preview.action") == "modelPicker" else { return }
                try? await Task.sleep(for: .milliseconds(900))
                if UserDefaults.standard.string(forKey: "preview.pickerPage") == "models" { page = .models }
                presented = true
            }
            #endif
    }

    // MARK: 칩

    private var chipLabel: some View {
        HStack(spacing: 6) {
            if refreshing {
                ProgressView().controlSize(.mini)
            }
            if catalog?.discovered == false {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.amber)
                    .help(catalogWarningHelp)
            } else if let sendBlock, !refreshing {
                // 이대로는 보낼 수 없다 (보내기를 누르면 같은 이유로 막힌다) — 이유는 도움말 · 팝오버 목록 아래에.
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.amber)
                    .help(sendBlock.message)
            }
            if density == .minimal {
                // 가장 좁은 입력창: 짧은 이름 · 강도 → 강도만 → 이름만. 이름이 줄임표로 사라지고 점만 남지 않게 (cap-8).
                ViewThatFits(in: .horizontal) {
                    chipText(name: shortModelName, compact: true)
                    if let label = effortLabel { effortView(label, compact: true) }
                    Text(shortModelName).lineLimit(1)
                }
            } else {
                chipText(name: modelName, compact: false)
            }
            if usesAPI {
                // API 키로 보내는 대화 — 구독 한도가 아니라 API 크레딧에서 빠진다 (`AppModel.usesClaudeAPI`).
                Text("API")
                    .font(Theme.ui(.caption, .semibold))
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.well))
                    .help("이 대화의 Claude 는 API 키로 실행합니다 — 구독 한도 대신 API 크레딧에서 빠집니다")
            }
            Text("▾").font(.system(size: 8)).foregroundStyle(Theme.slate2)
        }
        // 강도를 바꾸면 이름이 바뀐 글자로 넘어가고 칩 폭도 따라 움직인다 (뚝 바뀌지 않게).
        .contentTransition(.interpolate)
        .animation(chipMotion, value: displayedEffort)
    }

    private var effortLabel: EffortScale.Label? {
        EffortScale.label(selected: displayedEffort, efforts: efforts, provider: provider)
    }

    /// 칩의 "모델 · 강도". 모델이 강도를 받지 않으면(단계 없음 · 저장된 강도 없음) 강도 칸을 두지 않는다.
    private func chipText(name: String, compact: Bool) -> some View {
        HStack(spacing: 6) {
            // 글자색 · 크기는 `GhostChipStyle` 이 정한다 (포인터를 올리면 짙어진다).
            Text(name)
                .lineLimit(1)
                .fixedSize()
            if let label = effortLabel {
                Circle().fill(Theme.slate3).frame(width: 3, height: 3)
                effortView(label, compact: compact)
            }
        }
    }

    /// 강도 칸 — 지금 단계에 없는 값(목록이 바뀜 · 목록 · 모델을 모름)은 흐리게, 값은 숨기지 않는다 (실행 요청에 들어간다).
    private func effortView(_ label: EffortScale.Label, compact: Bool) -> some View {
        var shown = label
        if compact, label.tier != nil, let effort = displayedEffort { shown.text = EffortScale.compactName(of: effort) }
        let help: String = label.offScale ? "지금 모델의 강도 단계에 없는 값입니다 — 팝오버에서 확인하세요"
            : (sendBlock?.message ?? EffortScale.chipHelp(provider: provider, outcome: planOutcome, effort: displayedEffort))
        return EffortLabelView(label: shown, step: .callout, shimmer: !label.offScale, muted: true, animateShimmer: celebrating)
            .opacity(label.offScale ? 0.55 : 1)
            .help(help)
    }

    /// 가장 좁은 입력창의 모델 이름 ("Sol" · "Opus").
    private var shortModelName: String {
        selectedOption.map(ModelCatalog.shortName(of:)) ?? modelName
    }

    /// 목록을 확인하지 못했을 때의 경고 도움말 — 무엇을 대신 보여 주는지 사실대로 (Claude 는 대체 목록, Antigravity 는 이전에 조회한 목록).
    private var catalogWarningHelp: String {
        if catalog?.options.isEmpty ?? true { return "CLI 에서 모델 목록을 확인하지 못했습니다" }
        return provider == .gemini ? "CLI 에서 목록을 확인하지 못해 이전에 조회한 목록을 쓰고 있습니다"
            : "CLI 에서 목록을 확인하지 못해 대체 목록을 쓰고 있습니다"
    }

    /// 이 대화의 Claude 를 API 키로 보낸다 (모델 칩의 "API 크레딧으로 실행" · 키 저장됨).
    private var usesAPI: Bool { provider == .claude && model.usesClaudeAPI(threadID: thread.id) }

    private var chipAccessibilityLabel: String {
        let block = (sendBlock.map { ", 보낼 수 없음: \($0.message)" } ?? "") + (usesAPI ? ", API 크레딧으로 실행" : "")
        guard EffortScale.label(selected: displayedEffort, efforts: efforts, provider: provider) != nil else {
            return "모델 \(modelName)" + block
        }
        let value = EffortScale.accessibilityValue(selected: displayedEffort, provider: provider, efforts: efforts)
        return "모델 \(modelName), 추론 강도 \(value)" + block
    }

    private var modelName: String {
        if let selectedOption { return selectedOption.displayName }
        if selection.model == nil || (provider == .claude && selection.model == "default") {
            // 목록을 받는 중이면 고르라고 하지 않는다 — 받으면 보낼 모델이 보인다 (첫 폴더를 연 직후 — H13).
            return refreshing && options.isEmpty ? "모델 확인 중" : "모델 선택"
        }
        return ModelCatalog.unresolvedFamilyName(selection.model, listEmpty: options.isEmpty) ?? selection.model ?? "모델 선택"
    }

    // MARK: 팝오버

    private var pickerContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch page {
            case .effort: effortPage
            case .models: modelsPage
            }
            claudeAPIRow
            footer
        }
        .frame(width: 300)
        .background(Theme.paper)
    }

    // MARK: 강도 쪽

    private var effortPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            currentModelRow
                .padding(6)
            Rectangle().fill(Theme.hair).frame(height: 1)
            if let reason = availability.emptyReason {
                // 단계가 비는 이유를 가린다 — 목록을 못 읽음 · 모델을 고르지 않음 · 목록에 없는 모델 · 강도를 받지 않는 모델.
                Text(EffortScale.emptyMessage(reason))
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            } else {
                HStack(spacing: 0) {
                    SectionLabel("추론 강도")
                    Spacer(minLength: 8)
                    Text("↑ ↓ 로 옮깁니다")
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate2)
                }
                .padding(.horizontal, 16)
                .padding(.top, 9)
                .padding(.bottom, 5)
                effortList
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
            }
            effortNotice
        }
    }

    /// 지금 모델 한 줄 — 누르면 모델 쪽으로.
    private var currentModelRow: some View {
        Button { page = .models } label: {
            HStack(spacing: 10) {
                BrandMark(provider: provider, size: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(modelName)
                        .font(Theme.ui(.callout, .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    // Antigravity 는 설명이 없다 (지금처럼).
                    if provider != .gemini, let detail = selectedOption?.detail {
                        Text(detail)
                            .font(Theme.ui(.caption))
                            .foregroundStyle(Theme.slate)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 6)
                if catalog?.discovered == false {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.amber)
                        .help(catalogWarningHelp)
                }
                Text("모델 바꾸기")
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate2)
                    .fixedSize()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.control)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(PickerRowStyle(selected: false))
        .accessibilityLabel("모델 바꾸기, 지금 \(modelName)")
    }

    private var effortList: some View {
        let mark = EffortScale.defaultMark(provider: provider, availability: availability, defaults: effortDefaults)
        let separateLast = EffortScale.separatesLast(steps)
        return VStack(spacing: 1) {
            ForEach(Array(steps.enumerated()), id: \.element.effort) { index, step in
                if separateLast && index == steps.count - 1 {
                    // ULTRA(High + /boost)는 강도 단계가 아니다 — 선 하나로 떼어 둔다.
                    Rectangle().fill(Theme.hairSoft).frame(height: 1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                }
                effortRow(step, defaultHelp: step.effort == mark?.effort ? mark?.help : nil)
            }
        }
        // 고른 단계가 바뀌면(누르기 · 키 · 저장된 값) 고른 바탕 · 체크가 새 행으로 미끄러진다.
        .animation(selectionMotion, value: displayedEffort)
        // 팝오버가 열리면 바로 ↑ ↓ 가 동작하게 한다 (예전 슬라이더처럼). 값은 바꾸지 않는다.
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(.upArrow) { step(.decrease); return .handled }
        .onKeyPress(.downArrow) { step(.increase); return .handled }
        .onKeyPress(.leftArrow) { step(.decrease); return .handled }
        .onKeyPress(.rightArrow) { step(.increase); return .handled }
        .onAppear { DispatchQueue.main.async { listFocused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("추론 강도")
    }

    /// 강도 한 행 — 단계 색 점 · 이름(단계 색, MAX · ULTRA 는 글리프 + 굵게) · "기본" · (MAX · ULTRA 만) 한 줄 · 체크.
    private func effortRow(_ step: EffortScale.Step, defaultHelp: String?) -> some View {
        let isSelected = step.effort == displayedEffort
        let note = EffortScale.rowNote(of: step.effort, efforts: efforts)
        // 이름만으로 무엇이 일어나는지 알 수 없는 단계(Claude 의 ULTRA)는 포인터를 올리면 안내 (VoiceOver 에도).
        let help = EffortScale.rowHelp(of: step.effort)
        let label = EffortScale.Label(text: step.name, tier: step.tier, glyph: EffortScale.glyph(of: step.effort),
                                      offScale: false)
        return Button { choose(step.effort) } label: {
            HStack(spacing: 10) {
                EffortDot(tier: step.tier)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        EffortLabelView(label: label, step: .callout)
                        if let defaultHelp {
                            Text("기본")
                                .font(Theme.ui(.caption, .medium))
                                .foregroundStyle(Theme.slate2)
                                .padding(.horizontal, 5)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hair))
                                .help(defaultHelp)
                        }
                    }
                    if let note {
                        Text(note)
                            .font(Theme.ui(.caption))
                            .foregroundStyle(Theme.slate)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                selectionCheck(isSelected, id: "effortCheck")
            }
            .padding(.vertical, note == nil ? 0 : 5)
        }
        .buttonStyle(PickerRowStyle(selected: isSelected, minHeight: 32, highlight: selectionSpace,
                                    highlightID: "effortSelection"))
        .help(help ?? "")
        .accessibilityHint(help ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 고른 행의 체크 — 자리는 늘 잡아 두고(행 폭이 흔들리지 않게), 고른 바탕과 함께 새 행으로 옮겨 간다.
    private func selectionCheck(_ shown: Bool, id: String) -> some View {
        ZStack {
            if shown {
                Image(systemName: "checkmark")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .matchedGeometryEffect(id: id, in: selectionSpace)
            }
        }
        .frame(width: 12)
        .accessibilityHidden(true)
    }

    /// 목록 아래의 한 줄 — 보낼 수 없는 이유, 아니면 알아야 할 것만 (`EffortScale.listNote`), 되돌리기.
    @ViewBuilder
    private var effortNotice: some View {
        let text = sendBlock?.message
            ?? EffortScale.listNote(selected: currentEffort, availability: availability, provider: provider,
                                    defaults: effortDefaults)
        let offersReset = EffortScale.offersReset(provider: provider, selected: currentEffort, availability: availability)
        // Antigravity 는 강도를 고르는 순간 되돌리기가 생긴다 — 그 자리를 늘 잡아 두어 팝오버 높이가 바뀌지 않게
        // (팝오버는 칩 위에 바닥이 붙어 있어, 높이가 바뀌면 누르려던 행이 포인터 밑에서 위아래로 빠진다).
        let reserveReset = provider == .gemini && !steps.isEmpty
        if text != nil || offersReset || reserveReset {
            VStack(alignment: .leading, spacing: 6) {
                if let text {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: sendBlock != nil ? "exclamationmark.triangle" : "info.circle")
                            .font(.system(size: 10.5))
                            .foregroundStyle(sendBlock != nil ? Theme.amber : Theme.slate2)
                            .padding(.top, 1)
                        Text(text)
                            .font(Theme.ui(.caption))
                            .foregroundStyle(Theme.slate)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // 강도가 있을 때만 보인다. nil 로 돌아가는 길은 이것 하나다 (목록 · 키는 nil 로 가지 않는다).
                // Antigravity 의 nil 은 CLI 기본값이 아니라 앱 기본값(High)이라 이름이 다르고, 단계가 없으면(목록 · 모델을 모름)
                // 되돌린 뒤 다시 고를 수 없어 두지 않는다 (`EffortScale.offersReset`).
                if offersReset || reserveReset {
                    Button(EffortScale.resetTitle(provider: provider)) { choose(nil) }
                        .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption, .medium)))
                        .help(EffortScale.resetHelp(provider: provider, availability: availability))
                        .opacity(offersReset ? 1 : 0)
                        .disabled(!offersReset)
                        .allowsHitTesting(offersReset)
                        .accessibilityHidden(!offersReset)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 10)
        }
    }

    /// ↑ ↓ (← →) · VoiceOver. 다음 단계는 방금 고른 값까지 반영한 `currentEffort` 에서 계산한다 (저장 · 다시 그리기 전에
    /// 입력이 이어져도 옛 값에서 다시 계산하지 않게). Antigravity nil 은 보이는 High 에서 움직인다.
    private func step(_ direction: EffortScale.Direction) {
        if let next = EffortScale.keyStep(from: displayedEffort, direction, efforts: efforts) { choose(next) }
    }

    /// 강도를 고르는 단 하나의 길 (목록 · ↑ ↓ · 되돌리기). 같은 값은 보내지 않는다 (연출이 겹치지 않게).
    /// Antigravity 의 nil 은 High 로 보이므로, 보이는 High 를 다시 누른 것도 같은 값이다 (몰래 명시 High 로 저장하지 않는다).
    private func choose(_ effort: String?) {
        guard EffortScale.changesSelection(to: effort, current: currentEffort, displayed: displayedEffort) else { return }
        pendingSerial += 1
        pending = PendingEffort(effort: effort, serial: pendingSerial)
        chooseEffort(effort)
    }

    // MARK: 모델 쪽

    private static let rowHeight: CGFloat = 30

    private var modelsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Text("모델")
                    .font(Theme.ui(.callout, .semibold))
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 0) {
                    Button { page = .effort } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text("추론 강도")
                                .font(Theme.ui(.callout))
                        }
                        .foregroundStyle(Theme.slate)
                        .padding(.horizontal, 6)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("추론 강도로 돌아갑니다")
                    Spacer(minLength: 8)
                    IconButton(systemName: "arrow.clockwise", size: 11, help: "모델 목록 새로고침",
                               spinning: refreshing) {
                        Task { await model.refreshModelCatalog(scope, force: true) }
                    }
                    .disabled(refreshing)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, 1)

            modelList
            longContextRow
            if let notice = catalogNotice {
                Rectangle().fill(Theme.hairSoft).frame(height: 1)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: catalog?.discovered == false ? "exclamationmark.triangle" : "info.circle")
                        .foregroundStyle(catalog?.discovered == false ? Theme.amber : Theme.slate2)
                    Text(notice).foregroundStyle(Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.ui(.caption))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private var modelList: some View {
        let rows = ModelCatalog.baseOptions(options)
        Group {
            if options.isEmpty {
                Text(refreshing ? "모델 목록을 확인하는 중입니다" : "모델 목록이 없습니다 · 새로고침으로 다시 확인합니다")
                    .font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                // 행이 적으면 그 높이만, 많으면 10행 남짓에서 스크롤.
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(rows) { option in modelRow(option) }
                    }
                    .animation(selectionMotion, value: selectedRow?.identifier)
                }
                .scrollIndicators(.automatic)
                .frame(height: min(CGFloat(rows.count) * (Self.rowHeight + 1) - 1, 310))
            }
        }
        .padding(6)
    }

    private func modelRow(_ option: AgentModelOption) -> some View {
        let isSelected = option.identifier == selectedRow?.identifier
        // 고른 행이 긴 문맥 별칭이면 그 설명 ("복잡한 작업 · 긴 문맥").
        let shown = isSelected ? (selectedOption ?? option) : option
        // Antigravity 는 설명이 없다 (지금처럼). 그 밖은 카탈로그 설명, 없으면 모델 ID.
        let detail = provider == .gemini ? nil : (shown.detail ?? shown.identifier)
        // Codex 계열의 최신 — 고르면 계열 선택으로 저장돼 새 버전이 나오면 따라간다 (`ModelCatalog.selectionValue`).
        let follows = ModelCatalog.followsNewerVersions(option, in: options)
        let followsHelp = "고르면 이 계열의 새 버전이 나올 때 자동으로 바뀝니다"
        return Button {
            // 긴 문맥을 켜 둔 채 다른 모델을 고르면 그 모델의 긴 문맥 별칭으로 (없으면 그 모델).
            let keepsLong = selectedOption.map(ModelCatalog.isLongContext) ?? false
            chooseModel(keepsLong ? (ModelCatalog.longContextVariant(of: option, in: options) ?? option) : option)
        } label: {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Text(option.displayName)
                        .font(Theme.ui(.callout, isSelected ? .semibold : .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if follows {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.slate2)
                            .accessibilityLabel("새 버전 자동 적용")
                    }
                }
                .fixedSize()
                if let detail {
                    Text(detail)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Spacer(minLength: 0)
                }
                selectionCheck(isSelected, id: "modelCheck")
            }
        }
        .buttonStyle(PickerRowStyle(selected: isSelected, minHeight: Self.rowHeight, highlight: selectionSpace,
                                    highlightID: "modelSelection"))
        .help([detail ?? option.displayName, follows ? followsHelp : nil].compactMap { $0 }.joined(separator: " · "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Claude 의 긴 문맥(1M) — 바탕 모델 행 + 스위치 하나. 긴 문맥 별칭이 있는 모델이 없으면(Codex · Antigravity) 두지 않는다.
    @ViewBuilder
    private var longContextRow: some View {
        let bases = ModelCatalog.longContextBases(options)
        if !bases.isEmpty {
            let row = selectedRow
            let variant = row.flatMap { ModelCatalog.longContextVariant(of: $0, in: options) }
            let isOn = selectedOption.map(ModelCatalog.isLongContext) ?? false
            let note: String = {
                if variant != nil || isOn {
                    return bases.map(ModelCatalog.shortName(of:)).joined(separator: " · ") + " 에서 쓸 수 있습니다"
                }
                guard let row else { return "모델을 고르면 켤 수 있습니다" }
                return row.displayName + " 에는 1M 문맥이 없습니다"
            }()
            Rectangle().fill(Theme.hairSoft).frame(height: 1).padding(.horizontal, 12)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("긴 문맥 (1M)")
                        .font(Theme.ui(.callout, .medium))
                        .foregroundStyle(variant != nil || isOn ? Theme.ink : Theme.slate)
                    Text(note)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("긴 문맥 (1M)", isOn: Binding(
                    get: { isOn },
                    set: { on in
                        guard let row else { return }
                        if on, let variant { chooseModel(variant) } else if !on { chooseModel(row) }
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(variant == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
    }

    /// Claude 를 API 키로 실행 (Max · Team 플랜의 월 API 크레딧) — 이 대화만. 키가 없으면 스위치를 끄고 설정으로 가는 단추
    /// (`AppModel+ClaudeAPI` · `ClaudeAPIKey`). Codex · Antigravity 에는 두지 않는다.
    @ViewBuilder
    private var claudeAPIRow: some View {
        if provider == .claude {
            let hasKey = model.claudeAPIKeyHint != nil
            let isOn = usesAPI
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ClaudeAPIKey.toggleTitle)
                        .font(Theme.ui(.callout, .medium))
                        .foregroundStyle(hasKey ? Theme.ink : Theme.slate)
                    Text(!hasKey ? "설정 > 에이전트 > Claude Code 에 API 키를 넣으면 켤 수 있습니다"
                         : isOn ? "이 대화의 Claude 는 구독 한도 대신 API 크레딧에서 빠집니다"
                         : "켜면 이 대화만 구독 한도 대신 API 크레딧(Max · Team 월 크레딧)으로 보냅니다")
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                    if !hasKey {
                        Button("API 키 넣기…") {
                            presented = false
                            SettingsTab.select(.agents)
                            openSettings()
                        }
                        .buttonStyle(.link)
                        .font(Theme.ui(.caption))
                    }
                }
                Spacer(minLength: 8)
                Toggle(ClaudeAPIKey.toggleTitle, isOn: Binding(
                    get: { isOn },
                    set: { model.setClaudeAPI($0, threadID: thread.id) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(!hasKey)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
        }
    }

    /// 모델을 고르는 단 하나의 길 (모델 행 · 긴 문맥 스위치). 새 모델이 받지 않는 강도는 해제한다 (`effortAfterModelChange`).
    private func chooseModel(_ option: AgentModelOption) {
        let effort = EffortScale.effortAfterModelChange(current: currentEffort, supported: option.supportedEfforts)
        // 강도가 해제되면 그것도 방금 고른 값이다 (반영 전 옛 강도가 2초 동안 보이지 않게).
        if effort != currentEffort {
            pendingSerial += 1
            pending = PendingEffort(effort: effort, serial: pendingSerial)
        }
        // 이 칩이 그리는 스레드를 바꾼다 (인계 카드 · 칸마다의 입력창의 칩은 그 칸의 스레드 — 지금 고른 스레드와 다를 수 있다).
        let value = ModelCatalog.selectionValue(for: option, in: options)
        Task { await model.setModelSelection(ModelSelection(model: value, effort: effort),
                                             for: provider, threadID: thread.id) }
    }

    /// 목록을 못 읽었거나 대체 목록일 때의 안내 (지금 문구 유지).
    private var catalogNotice: String? {
        guard let catalog else { return nil }
        if !catalog.discovered {
            return catalog.message ?? "모델 목록을 확인하지 못해 대체 목록을 보여줍니다."
        }
        return catalog.options.isEmpty ? catalog.message : nil
    }

    // MARK: 바닥

    private var footer: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.slate2)
                .padding(.top, 1)
            Text("이 대화에 적용됩니다 · 새 대화는 마지막에 쓴 모델로 시작합니다")
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 9)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }
}

// MARK: - 부품

/// 강도 행 앞의 단계 색 점 (MAX · ULTRA 는 위 → 아래 그라데이션).
private struct EffortDot: View {
    let tier: EffortScale.Tier

    var body: some View {
        let colors = Theme.effortFill(tier)
        Circle()
            .fill(LinearGradient(colors: colors.count > 1 ? colors : colors + colors, startPoint: .top, endPoint: .bottom))
            .frame(width: 8, height: 8)
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }
}

/// 팝오버의 고르는 행 — 포인터를 올리면 옅은 바탕, 고른 행은 `Theme.well` 바탕. `highlight` 를 주면 고른 바탕이 그 이름 공간에서
/// 같은 id 로 이어져(matchedGeometryEffect) 고른 행이 바뀔 때 새 행으로 미끄러진다 — 움직임은 목록이 건다 (`selectionMotion`).
private struct PickerRowStyle: ButtonStyle {
    var selected: Bool
    var minHeight: CGFloat = 30
    var highlight: Namespace.ID? = nil
    var highlightID = "selection"

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, selected: selected, minHeight: minHeight, highlight: highlight,
                highlightID: highlightID)
    }

    private struct RowBody: View {
        let configuration: Configuration
        let selected: Bool
        let minHeight: CGFloat
        let highlight: Namespace.ID?
        let highlightID: String
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
                .contentShape(Rectangle())
                .background {
                    ZStack {
                        if hovering && !selected {
                            RoundedRectangle(cornerRadius: 7).fill(Theme.wellSoft)
                        }
                        if selected {
                            if let highlight {
                                RoundedRectangle(cornerRadius: 7).fill(Theme.well)
                                    .matchedGeometryEffect(id: highlightID, in: highlight)
                            } else {
                                RoundedRectangle(cornerRadius: 7).fill(Theme.well)
                            }
                        }
                    }
                }
                .opacity(configuration.isPressed ? 0.8 : 1)
                .onHover { hovering = $0 }
        }
    }
}
