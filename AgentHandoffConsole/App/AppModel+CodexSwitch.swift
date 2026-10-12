import Foundation

/// Codex 계정끼리 바꾸기의 앱 쪽 — 같은 Codex 세션을 다른 계정의 인증으로 이어 간다 (인계가 아니다). 판정 · 글은 순수
/// `Assist/CodexAccountSwitch.swift`, 세션을 그 계정으로 이어 가는 실행은 `RunSession.send` → `CodexRunHome`.
///
/// 칩 메뉴의 계정 행은 `chooseAgent` 로 칩만 바꾼다 (`ContinueChoice.Action.switchAccount`). 여기는 한도 줄 · 제안 줄의 단추와 자동 인계가
/// 다른 Codex 계정을 고를 때의 카운트다운 (`codexSwitchCountdowns` — 상태는 `AppModel` 본체).
extension AppModel {

    /// 같은 Codex 의 다른 계정인가 — 두 쪽을 등록된 계정 ID 로 맞춰 본다.
    func isCodexAccountSwitch(from source: HandoffSource.Agent, to target: HandoffSource.Agent) -> Bool {
        CodexAccountSwitch.isSwitch(from: normalizedHandoffAgent(source), to: normalizedHandoffAgent(target))
    }

    /// 제안 줄의 [… 에서 이어 가기]: 칩(계정)만 바꾸고 입력창 위에 알린다 — 대화가 멈추지 않았으므로 보낼 것은 없다 (다음 메시지부터).
    func switchCodexAccount(threadID: String, accountID: String) async {
        await chooseAgent(.codex, accountID: accountID, threadID: threadID)
    }

    /// 한도 줄 · 카운트다운의 [… 에서 이어 가기]: 칩을 그 계정으로 바꾸고 같은 Codex 세션에 이어 가기 메시지를 보낸다 — 인계가 아니다
    /// (세션은 대화의 것 하나 — 다른 계정의 폴더에 있으면 이 실행만 그 계정의 인증으로 이어 간다). 한도로 멈춘 대기열은 이 실행이 정상으로
    /// 끝나면 이어서 간다 (API 크레딧 이어 가기와 같은 규칙 `ClaudeAPIContinue.clearsQueuePause`). 실행이 시작되면 true.
    @discardableResult
    func continueWithCodexAccount(threadID: String, accountID: String) async -> Bool {
        cancelCodexSwitchCountdown(threadID: threadID)
        guard let thread = allThreads().first(where: { $0.id == threadID }), handoffOwnershipBlock(thread) == nil,
              !runner.isBusy(threadID: threadID), !isStartingRun(threadID: threadID), !isSending(threadID: threadID),
              deliveringHandoffs[threadID] == nil, !hasHandoffActivity(threadID: threadID) else { return false }
        let pause = queuePauseReasons[threadID]
        await chooseAgent(.codex, accountID: accountID, threadID: threadID, announce: false)
        if ClaudeAPIContinue.clearsQueuePause(before: pause) { queuePauseReasons[threadID] = nil }
        threadStates[threadID]?.requestScrollToBottom()
        return await send(CodexAccountSwitch.prompt, provider: .codex, threadID: threadID)
    }

    // MARK: - 자동 (카운트다운)

    /// 자동 인계가 다른 Codex 계정을 골랐다 — 인계 카드 대신 카운트다운. 울리면 그 계정으로 바꾸고 같은 세션에 이어 가기 메시지를 보낸다.
    /// 인계 카드의 카운트다운과 같은 길이 · 같은 알림(취소 · 검토 단추가 이것을 멈춘다). 앱 종료를 묻는 중이면 걸지 않는다.
    func startCodexSwitchCountdown(threadID: String, source: HandoffSource.Agent, target: HandoffSource.Agent, limitRun: Run) {
        guard !handoffsSuspendedForQuit else { return }
        let delay = automaticHandoffDelay
        let countdown = CodexAccountSwitch.Countdown(source: normalizedHandoffAgent(source), target: normalizedHandoffAgent(target),
                                                     limitRunID: limitRun.id, limitRunStartedAt: limitRun.startedAt,
                                                     deadline: Date().addingTimeInterval(TimeInterval(delay)), delay: delay)
        codexSwitchCountdowns[threadID] = countdown
        let title = allThreads().first { $0.id == threadID }?.title ?? ""
        notifications.post(category: .automaticHandoff,
                           title: CodexAccountSwitch.countdownTitle(seconds: delay, target: handoffPartyName(countdown.target)),
                           body: "\(title) · 같은 Codex 세션을 이어 갑니다 — 앱이나 알림의 단추로 취소할 수 있습니다.",
                           threadID: threadID)
        codexSwitchTasks[threadID]?.cancel()
        let id = countdown.id
        codexSwitchTasks[threadID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.codexSwitchCountdownFired(threadID: threadID, id: id)
        }
    }

    /// 카운트다운을 멈춘다 — [취소] · 알림의 취소 · 검토 · 사람이 이 대화에서 보냄 · 칩을 바꿈 · 인계 카드를 엶(`prepareCard`) ·
    /// 대화 삭제 · 앱 종료.
    func cancelCodexSwitchCountdown(threadID: String) {
        codexSwitchTasks[threadID]?.cancel()
        codexSwitchTasks[threadID] = nil
        if codexSwitchCountdowns[threadID] != nil { codexSwitchCountdowns[threadID] = nil }
    }

    /// [지금 이어 가기].
    func continueCodexSwitchNow(threadID: String) async {
        guard let countdown = codexSwitchCountdowns[threadID] else { return }
        await codexSwitchCountdownFired(threadID: threadID, id: countdown.id)
    }

    #if DEBUG
    /// 화면 확인용 (`-preview.codexSwitch YES`, AHC_OFFLINE=1 전용): 선택된 대화에 다른 Codex 계정으로 이어 가는 카운트다운 줄을 놓는다
    /// (타이머 없이 60초 — 울려도 이어 가지 않는다). 칩의 계정에서 등록된 다른 계정으로.
    func previewCodexSwitchCountdown() {
        guard Self.offlinePreview, let thread = selectedThread else { return }
        let source = HandoffSource.Agent(provider: .codex, codexAccountID: thread.codexAccountID)
        guard let other = accounts.accounts.first(where: { $0.id != normalizedHandoffAgent(source).codexAccountID }) else { return }
        codexSwitchCountdowns[thread.id] = CodexAccountSwitch.Countdown(
            source: normalizedHandoffAgent(source), target: HandoffSource.Agent(provider: .codex, codexAccountID: other.id),
            limitRunID: "", limitRunStartedAt: Date(), deadline: Date().addingTimeInterval(60), delay: 60)
    }
    #endif

    /// 카운트다운이 울렸다 — 그 사이 이 대화에 새 실행이 있었으면(사람이 먼저 보냈다) 지난 일이다.
    private func codexSwitchCountdownFired(threadID: String, id: String) async {
        guard let countdown = codexSwitchCountdowns[threadID], countdown.id == id else { return }
        codexSwitchTasks[threadID]?.cancel()
        codexSwitchTasks[threadID] = nil
        let laterRun = ((try? await store.runs(threadID: threadID)) ?? [])
            .contains { $0.id != countdown.limitRunID && $0.startedAt > countdown.limitRunStartedAt }
        guard codexSwitchCountdowns[threadID]?.id == id else { return }
        codexSwitchCountdowns[threadID] = nil
        guard !laterRun, !handoffsSuspendedForQuit else { return }
        _ = await continueWithCodexAccount(threadID: threadID,
                                           accountID: countdown.target.codexAccountID ?? CodexAccount.defaultID)
    }
}
