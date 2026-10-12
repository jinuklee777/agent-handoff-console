import Foundation

/// 자동 인계 종단 검증. 앱의 실제 `AppModel` 을 임시 DB·임시 프로젝트로 띄워
/// 한도 도달 흉내 → 대상 선택 → 초안 → (Gemini 정리) → 게이트 → 카운트다운 → 전송/취소/검토를 실제 CLI 로 돌린다.
/// 초안은 대화 끝의 인계 카드다 (B 설계 C1) — 카운트다운 · 검토 · 실패가 모두 그 대화의 카드 단계로 보인다.
///
/// 한도 도달 판정 자체(CLI 출력 → rateLimited)는 fixture 로 따로 검증한다. 여기서는 그 뒤의 흐름을 본다.
/// Codex → Claude 방향으로 흉내 내고, Claude(haiku, `--claude-model=` 로 바꿈)에 인계 전송 턴을 쓴다.
/// F: 두 대화가 함께 한도에 닿음 → 대화마다 카운트다운 → 둘 다 Claude 로 전송 (2026-09-30, 동시에 가도록 바꾼 것).
/// G: Claude → Codex 방향 (`--codex-model=` · `--codex-effort=`, 기본 gpt-5.6-luna · low) — Codex 가 인계를 받는 턴 1회.
/// 시나리오 0 은 실제 한도 그대로(받을 쪽 여유를 모르면 보내지 않음), A~E 는 Claude 한도 값을 주입해 본다.
/// Gemini 시나리오는 합성 기록만 보낸다.
enum AutoHandoffLiveTests {
    static var claudeModel: String { LiveTests.claudeModelOverride ?? "haiku" }
    static var claudeEffort: String? { LiveTests.claudeEffortOverride }
    static var codexModel: String { LiveTests.codexModelOverride ?? "gpt-5.6-luna" }
    static var codexEffort: String { LiveTests.codexEffortOverride ?? "low" }

    @MainActor
    static func run(_ t: TestKit) async {
        await t.group("자동 인계 종단")
        let root: URL
        do {
            root = try TestEnv.makeTempProject("autohandoff")
        } catch {
            await t.check("임시 프로젝트 생성", false, "\(error)")
            return
        }
        defer { TestEnv.cleanup(root) }
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try? "# 검증용 임시 프로젝트\n".write(to: projectDir.appendingPathComponent("README.md"),
                                          atomically: true, encoding: .utf8)
        let env = await CLIEnvironment().childEnvironment()
        _ = await CLIEnvironment.captureOutput(executable: "/usr/bin/git", arguments: ["init", "-q"],
                                               environment: env, workingDirectory: projectDir, timeout: 20)

        let store = Store(databaseURL: root.appendingPathComponent("handoff.sqlite3"))
        let model = AppModel(store: store)
        await model.bootstrap()
        await t.check("앱 모델 부트스트랩", model.bootstrapError == nil, model.bootstrapError ?? "")
        guard model.bootstrapError == nil else { return }

        let project = await model.addProject(name: "autohandoff", path: projectDir.path)
        let thread = await model.addThread(projectID: project.id, title: "자동 인계 시험")
        await model.setModelSelection(ModelSelection(model: claudeModel, effort: claudeEffort), for: .claude)
        await t.note("모델: Claude \(claudeModel)\(claudeEffort.map { " · " + $0 } ?? "") · Codex \(codexModel) · \(codexEffort)")
        await setProvider(store, model, thread.id, .codex)
        model.automaticHandoffEnabled = true
        model.automaticHandoffDelay = 5
        model.geminiSummaryEnabled = false
        model.automaticHandoffPriority = ["claude"]

        await model.limits.refreshAll(force: true)
        let realClaudeLoggedIn = await model.claudeLoginCheck()
        await t.note("실제 Claude 로그인(claude auth status): \(realClaudeLoggedIn.map { $0 ? "됨" : "안 됨" } ?? "확인 불가")")
        await t.note("실제 한도 · Claude: \(describe(model.limits.snapshot(.claude)))")
        await t.note("실제 한도 · Codex 기본: "
                     + describe(model.limits.snapshot(AgentScope(provider: .codex, accountID: CodexAccount.defaultID))))

        if let only = LiveTests.autoHandoffOnly {
            await t.note("--autohandoff-only=\(only.sorted().joined(separator: ",")): A~E 를 건너뜀")
            if realClaudeLoggedIn != true { model.claudeLoginCheck = { true } }
            if only.contains("F") {
                await concurrent(t, model, store, project: project, first: thread.id, injectClaudeHeadroom: {
                    model.limits.apply(LimitSnapshot(provider: .claude, status: .ok,
                                                     windows: [LimitWindow(label: "5시간", utilization: 0.1)], fetchedAt: Date()))
                }, claudeLoggedIn: realClaudeLoggedIn == true)
            }
            if only.contains("G") { await toCodex(t, model, store, project: project) }
            await store.db.close()
            return
        }

        // MARK: 0. 실제 상태 그대로 — 받을 쪽 로그인·한도 여유를 모르면 보내지 않는다
        if !model.limits.snapshot(.claude).hasUsableData || realClaudeLoggedIn != true {
            await t.note("0. 실제 상태(Claude 로그인·한도 미확인)에서 Codex 한도 흉내 → 보내지 않고 검토 시트")
            await addUserMessage(store, model, thread.id, "다음 행동: 정보 없음 대상 시험")
            await model.simulateLimitReached(threadID: thread.id)
            let settled = await wait(150) { model.handoffCards[thread.id] != nil }
            let card = model.handoffCards[thread.id]
            let reasons = reviewReasons(card)
            await t.check("0 카운트다운 없이 검토 카드", settled && card?.isCountingDown == false && card?.attention == .review)
            await t.check("0 후보별 제외 사유 표시 (카드 안)", reasons.contains { $0.contains("Claude 제외") },
                          reasons.joined(separator: " / "))
            model.cancelHandoff(threadID: thread.id, origin: .card)
        } else {
            await t.note("0. Claude 로그인·한도가 모두 확인돼 이 시나리오를 건너뜀")
        }
        if realClaudeLoggedIn != true {
            // 취소·검토·실패·Gemini 흐름은 로그인 여부와 무관하다. A 는 실제로 로그아웃된 Claude 로 보내게 되므로
            // "인증 실패 → 전달되지 않음(다시 보낼 수 있음)"으로 기록되는지를 본다.
            await t.note("시험용: Claude 로그인 확인을 '됨'으로 대체 (실제로는 로그인 안 됨)")
            model.claudeLoginCheck = { true }
        }

        // Claude Code 2.1.233 은 헤드리스 /usage 로도, 실행 스트림으로도 구독 한도를 보고하지 않는다 (2026-09-12 실측).
        // 전송 이후 흐름을 보려고 Claude 한도에 "여유 있음" 값을 주입한다. 조회가 실패해도
        // 30분 안의 값은 유지하는 규칙(LimitsService.mergedAfterRefresh) 덕분에 게이트까지 유지된다.
        func injectClaudeHeadroom() {
            model.limits.apply(LimitSnapshot(provider: .claude, status: .ok,
                                             windows: [LimitWindow(label: "5시간", utilization: 0.1)],
                                             fetchedAt: Date()))
        }

        // MARK: A. Codex 한도 흉내 → 대상 선택(Claude) → 게이트 → 카운트다운 → 실제 전송
        await t.note("A. (Claude 한도 주입) Codex 한도 도달 흉내 → 대상 선택 → 5초 뒤 자동 전송")
        injectClaudeHeadroom()
        await addUserMessage(store, model, thread.id, readmeTask)
        var sentCount = await handoffSentCount(store, thread.id)
        if let pendingA = await simulateAndWaitPending(t, model, thread.id, label: "A") {
            await t.equal("A 선택된 대상", pendingA.draft.handoff.toProvider, .claude)
            var countdown: (deadline: Date, delay: Int)?
            if case .countingDown(let deadline, let delay) = pendingA.phase { countdown = (deadline, delay) }
            await t.check("A 카운트다운 5초", countdown?.delay == 5
                          && abs((countdown?.deadline ?? .distantPast).timeIntervalSinceNow - 5) < 2)
            await t.check("A 규칙 초안의 다음 행동",
                          pendingA.draft.packet.nextActions.contains { $0.contains("README.md 첫 줄") },
                          pendingA.draft.packet.nextActions.joined(separator: " | "))
            let deliveredA = await wait(300) {
                await denyPendingApprovals(model)
                let h = await handoff(store, thread.id, pendingA.id)
                return h?.deliveryState == .delivered || h?.deliveryState == .failed
                    || h?.deliveryState == .unknown
            }
            _ = await wait(120) { !model.runner.isBusy && model.deliveringHandoffs[thread.id] == nil }
            let handoffA = await handoff(store, thread.id, pendingA.id)
            let noteA = handoffA?.note ?? ""
            await t.check("A 기록에 사람 검토 없음 표시 유지", noteA.hasPrefix("자동 인계 · 사람 검토 없음"), noteA)
            await t.check("A 받는 쪽 문서에 작성 주체 표시",
                          handoffA?.finalText.contains("> 작성: 앱이 기록으로 정리 · 자동 인계 · 사람 검토 없음") == true)
            let threadAfterA = (try? await store.thread(id: thread.id)) ?? nil
            // 칩은 전달이 확인될 때만 받는 쪽으로 옮긴다 (B 설계 C1) — 받지 못했으면 그대로.
            await t.equal("A 스레드 제공자 (전달 확인이면 Claude, 아니면 그대로)", threadAfterA?.preferredProvider ?? .codex,
                          handoffA?.deliveryState == .delivered ? .claude : .codex)
            if realClaudeLoggedIn == true {
                await t.check("A 전달 확인", deliveredA && handoffA?.deliveryState == .delivered,
                              handoffA?.deliveryState.koreanName ?? "기록 없음")
                let eventsA = (try? await store.events(threadID: thread.id)) ?? []
                let sentIndex = eventsA.lastIndex { $0.kind == .handoffSent }
                let reply = sentIndex.flatMap { index in
                    eventsA[index...].last { $0.kind == .agentMessage && $0.provider == .claude }
                }
                await t.check("A 받는 쪽이 인계대로 일함 (README 첫 줄을 알려 줌)", followed(reply),
                              reply.map { String($0.text.prefix(160)) } ?? "응답 없음")
            } else {
                // 로그아웃된 CLI 는 "Failed to authenticate" 를 응답처럼 내보낸다. 수신으로 보면 안 된다.
                await t.equal("A 인증 실패는 전달 안 됨(다시 보낼 수 있음)",
                              handoffA?.deliveryState ?? .unknown, .failed)
                await t.check("A 인증 실패 사유 기록", noteA.contains("인증 실패로 전달되지 않았습니다"), noteA)
            }
            await t.check("A 카운트다운 끝 · 전달됐으면 카드가 없다 (받지 못했으면 다시 보낼 수 있는 실패 카드)",
                          model.handoffCards[thread.id]?.isCountingDown != true
                            && (handoffA?.deliveryState == .delivered) == (model.handoffCards[thread.id] == nil))
            model.cancelHandoff(threadID: thread.id, origin: .card)
            sentCount = await handoffSentCount(store, thread.id)
            await setProvider(store, model, thread.id, .codex)
        }

        // MARK: B. 알림의 "자동 인계 취소"
        await t.note("B. 카운트다운 중 알림 취소 버튼 → 보내지 않음")
        injectClaudeHeadroom()
        await addUserMessage(store, model, thread.id, "다음 행동: 알림 취소 시험")
        if let pendingB = await simulateAndWaitPending(t, model, thread.id, label: "B") {
            model.notifications.automaticActionHandler?(.cancel, thread.id)
            await t.check("B 알림 취소 → 카운트다운이 멈추고 검토 카드 (사람이 멈춤)",
                          model.handoffCards[thread.id]?.isCountingDown == false
                            && model.handoffCards[thread.id]?.review == .pausedByHuman)
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            let h = await handoff(store, thread.id, pendingB.id)
            await t.check("B 행 없음 (넘기기 전에는 넣지 않는다)", h == nil, h?.deliveryState.koreanName ?? "")
            await t.equal("B 전송하지 않음", await handoffSentCount(store, thread.id), sentCount)
            model.cancelHandoff(threadID: thread.id, origin: .card)
        }

        // MARK: C. 알림의 "검토"
        await t.note("C. 카운트다운 중 알림 검토 버튼 → 시트로 전환, 보내지 않음")
        injectClaudeHeadroom()
        await addUserMessage(store, model, thread.id, "다음 행동: 알림 검토 시험")
        if let pendingC = await simulateAndWaitPending(t, model, thread.id, label: "C") {
            model.notifications.automaticActionHandler?(.review, thread.id)
            await t.check("C 알림 검토 → 같은 카드가 검토로 (카운트다운 멈춤)",
                          model.handoffCards[thread.id]?.id == pendingC.id && model.handoffCards[thread.id]?.review == .pausedByHuman)
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            await t.equal("C 전송하지 않음", await handoffSentCount(store, thread.id), sentCount)
            model.cancelHandoff(threadID: thread.id, origin: .card)
        }

        // MARK: D. 카운트다운 뒤 전송 실패 → 재시도 없이 검토 시트
        await t.note("D. 카운트다운 중 대상 CLI 가 사라짐 → 전송 실패 → 검토 시트")
        injectClaudeHeadroom()
        await addUserMessage(store, model, thread.id, "다음 행동: 전송 실패 시험")
        if let pendingD = await simulateAndWaitPending(t, model, thread.id, label: "D") {
            let target = pendingD.draft.handoff.toProvider
            let missing = root.appendingPathComponent("missing/\(target.rawValue)").path
            if target == .claude { model.claudePathOverride = missing } else { model.codexPathOverride = missing }
            let failedCard = await wait(20) { model.handoffCards[thread.id]?.isFailed == true }
            let h = await handoff(store, thread.id, pendingD.id)
            await t.check("D 실패 카드 (다시 시도하지 않음)", failedCard && model.handoffCards[thread.id]?.id == pendingD.id)
            await t.equal("D 실패 기록 (다시 보낼 수 있는 상태)", h?.deliveryState ?? .unknown, .failed)
            await t.check("D 오류는 그 카드에", model.handoffCards[thread.id]?.lastError?.isEmpty == false,
                          model.handoffCards[thread.id]?.lastError ?? "")
            await t.check("D 실행 시작 안 함", !model.runner.isBusy)
            model.claudePathOverride = ""
            model.codexPathOverride = ""
            _ = await wait(5) {
                let o = await model.environment.currentOverrides()
                return (o.claudePath ?? "").isEmpty && (o.codexPath ?? "").isEmpty
            }
            model.cancelHandoff(threadID: thread.id, origin: .card)
        }
        // 전송 시작 실패도 "인계 전송" 이벤트는 먼저 남는다 (RunCoordinator.deliver). 기준을 다시 잡는다.
        sentCount = await handoffSentCount(store, thread.id)

        // MARK: E. Gemini 정리를 켠 상태
        if !LiveTests.skipGemini { await model.refreshGeminiStatus(force: true) }
        if LiveTests.skipGemini {
            await t.note("E. --skip-gemini: Gemini 시나리오를 건너뜀")
        } else if model.geminiCLIPath == nil {
            await t.note("E. agy 가 없어 Gemini 시나리오를 건너뜀")
        } else {
            await t.note("E. Gemini 정리(합성 기록) → 검증 → 게이트")
            model.geminiSummaryEnabled = true
            injectClaudeHeadroom()
            await addUserMessage(store, model, thread.id,
                                 "다음 행동: README.md 첫 줄이 '# 검증용 임시 프로젝트'인지 확인한다.")
            await model.simulateLimitReached(threadID: thread.id)
            let ready = await wait(240) { model.handoffCards[thread.id] != nil }
            let card = model.handoffCards[thread.id]
            let draft = card?.draft
            await t.check("E 초안 준비", ready && draft != nil)
            await t.check("E Gemini 요청됨", draft?.geminiRequested == true)
            await t.equal("E Gemini 정리·검증 통과", draft?.packet.summarySource ?? "없음", "gemini")
            let outcome = card?.isCountingDown == true
                ? "게이트 통과 · 카운트다운"
                : "검토 카드 · " + reviewReasons(card).joined(separator: " / ")
            await t.note("E 결과: \(outcome) · 검증 경고 \(draft?.validationWarnings.count ?? -1)건 · "
                         + "다음 행동: \(draft?.packet.nextActions.joined(separator: " | ") ?? "")")
            model.cancelHandoff(threadID: thread.id, origin: .card)
            try? await Task.sleep(nanoseconds: 6_500_000_000)
            await t.equal("E 전송하지 않음", await handoffSentCount(store, thread.id), sentCount)
        }
        model.geminiSummaryEnabled = false

        await concurrent(t, model, store, project: project, first: thread.id, injectClaudeHeadroom: injectClaudeHeadroom,
                         claudeLoggedIn: realClaudeLoggedIn == true)
        await toCodex(t, model, store, project: project)

        await store.db.close()
    }

    // MARK: F. 두 대화가 함께 한도에 닿음

    /// 두 대화가 거의 함께 Codex 한도에 닿는다 → 대화마다 카운트다운 → 둘 다 Claude 로 전송 · 전달.
    /// 예전에는 준비 · 대기가 앱에 하나뿐이라 뒤의 것이 조용히 빠지거나 앞의 카운트다운을 취소했다.
    @MainActor
    private static func concurrent(_ t: TestKit, _ model: AppModel, _ store: Store, project: Project, first: String,
                                   injectClaudeHeadroom: () -> Void, claudeLoggedIn: Bool) async {
        await t.note("F. 두 대화가 함께 Codex 한도 도달 흉내 → 카운트다운 둘 → 둘 다 Claude(\(claudeModel))로 전송")
        let second = await model.addThread(projectID: project.id, title: "자동 인계 시험 2")
        await model.setModelSelection(ModelSelection(model: claudeModel, effort: claudeEffort), for: .claude, threadID: second.id)
        model.automaticHandoffPriority = ["claude"]
        let ids = [first, second.id]
        for id in ids {
            await setProvider(store, model, id, .codex)
            await addUserMessage(store, model, id, readmeTask)
        }
        injectClaudeHeadroom()
        let before = Dictionary(uniqueKeysWithValues: await asyncMap(ids) { ($0, await handoffIDs(store, $0)) })
        await model.simulateLimitReached(threadID: first)
        await model.simulateLimitReached(threadID: second.id)
        var mostPending = 0
        var newHandoffs: [String: Handoff] = [:]
        let settled = await wait(360) {
            mostPending = max(mostPending, model.handoffCards.values.filter(\.isCountingDown).count)
            await denyAllPendingApprovals(model)
            for id in ids {
                let fresh = ((try? await store.handoffs(threadID: id)) ?? []).last { !(before[id] ?? []).contains($0.id) }
                if let fresh { newHandoffs[id] = fresh }
            }
            let done = ids.allSatisfy { id in
                guard let h = newHandoffs[id] else { return false }
                return [.delivered, .failed, .unknown].contains(h.deliveryState)
            }
            return done && ids.allSatisfy { !model.runner.isBusy(threadID: $0) && model.deliveringHandoffs[$0] == nil }
        }
        let states = ids.map { newHandoffs[$0]?.deliveryState.koreanName ?? "초안 없음" }
        await t.check("F 두 대화 모두 인계 초안 → 전송까지", settled, "\(states) · 배너 \(model.banner?.text ?? "-")")
        await t.check("F 카운트다운 둘이 함께 돈 적이 있다", mostPending == 2, "최대 동시 대기 \(mostPending)")
        await t.check("F 받는 쪽은 둘 다 Claude", ids.allSatisfy { newHandoffs[$0]?.toProvider == .claude })
        if claudeLoggedIn {
            await t.check("F 둘 다 전달 확인", ids.allSatisfy { newHandoffs[$0]?.deliveryState == .delivered }, "\(states)")
            for (id, tag) in zip(ids, ["F1", "F2"]) {
                let events = (try? await store.events(threadID: id)) ?? []
                let sent = events.lastIndex { $0.kind == .handoffSent }
                let reply = sent.flatMap { i in events[i...].last { $0.kind == .agentMessage && $0.provider == .claude } }
                await t.check("\(tag) 받는 쪽(Claude)이 인계대로 일함", followed(reply),
                              reply.map { String($0.text.prefix(160)) } ?? "응답 없음")
                let run = ((try? await store.runs(threadID: id)) ?? []).last { $0.isHandoffDelivery }
                await t.note("\(tag) 받은 실행의 모델: \(run?.model ?? "?") · 상태 \(run?.state.rawValue ?? "?")")
            }
        }
        await t.check("F 카운트다운이 남지 않는다 (전달됐으면 카드도 없다)",
                      ids.allSatisfy { model.handoffCards[$0]?.isCountingDown != true }
                        && (!claudeLoggedIn || ids.allSatisfy { model.handoffCards[$0] == nil }))
        for id in ids { model.cancelHandoff(threadID: id, origin: .card) }
    }

    // MARK: G. Claude → Codex

    /// Claude 한도 도달 흉내 → Codex(기본 계정, `codexModel`)로 자동 전송 → Codex 가 인계를 받아 답한다.
    @MainActor
    private static func toCodex(_ t: TestKit, _ model: AppModel, _ store: Store, project: Project) async {
        await t.note("G. Claude 한도 도달 흉내 → Codex(\(codexModel) · \(codexEffort))로 자동 전송")
        let thread = await model.addThread(projectID: project.id, title: "자동 인계 시험 3")
        await model.setModelSelection(ModelSelection(model: codexModel, effort: codexEffort), for: .codex, threadID: thread.id)
        await setProvider(store, model, thread.id, .claude)
        let codexScope = AgentScope(provider: .codex, accountID: CodexAccount.defaultID)
        model.automaticHandoffPriority = [AutomaticHandoffTargets.key(.codex, CodexAccount.defaultID), "claude"]
        await model.limits.refresh(codexScope, force: true)
        await t.note("Codex 기본 계정 한도: \(describe(model.limits.snapshot(codexScope))) · 로그인 "
                     + (model.accounts.accountOrDefault(CodexAccount.defaultID).authStatus == .loggedIn ? "됨" : "안 됨"))
        await addUserMessage(store, model, thread.id, readmeTask)
        guard let pending = await simulateAndWaitPending(t, model, thread.id, label: "G") else { return }
        await t.equal("G 선택된 대상", pending.draft.handoff.toProvider, .codex)
        await t.equal("G 보내는 쪽 (한도에 걸린 실행)", pending.draft.handoff.fromProvider, .claude)
        let delivered = await wait(300) {
            await denyAllPendingApprovals(model)
            let h = await handoff(store, thread.id, pending.id)
            return [.delivered, .failed, .unknown].contains(h?.deliveryState ?? .draft)
        }
        _ = await wait(180) { !model.runner.isBusy(threadID: thread.id) && model.deliveringHandoffs[thread.id] == nil }
        let h = await handoff(store, thread.id, pending.id)
        await t.check("G 전달 확인", delivered && h?.deliveryState == .delivered,
                      "\(h?.deliveryState.koreanName ?? "기록 없음") · \(h?.note ?? "")")
        let events = (try? await store.events(threadID: thread.id)) ?? []
        let sent = events.lastIndex { $0.kind == .handoffSent }
        let reply = sent.flatMap { i in events[i...].last { $0.kind == .agentMessage && $0.provider == .codex } }
        await t.check("G 받는 쪽(Codex)이 인계대로 일함", followed(reply), reply.map { String($0.text.prefix(160)) } ?? "응답 없음")
        // 받는 쪽이 한 일 — 명령 · 승인 · 안내 (실패를 풀 때 쓴다. 시험이 끝나면 임시 DB 를 지운다).
        for event in sent.map({ Array(events[$0...]) }) ?? [] where event.kind != .userMessage {
            let text = event.text.replacingOccurrences(of: "\n", with: " ⏎ ")
            await t.note("G 기록 · \(event.kind.rawValue) · \(event.title.prefix(60)) · \(text.prefix(220))")
        }
        let run = ((try? await store.runs(threadID: thread.id)) ?? []).last { $0.isHandoffDelivery }
        await t.check("G 받은 실행의 모델", run?.model?.contains(codexModel) == true, run?.model ?? "?")
        let after = (try? await store.thread(id: thread.id)) ?? nil
        await t.equal("G 대화의 에이전트 전환", after?.preferredProvider ?? .claude, .codex)
    }

    /// 도는 모든 실행의 승인 요청을 거절한다 (동시에 여러 실행이 돈다 — `runner.pendingApprovals` 는 가장 최근 실행의 것뿐).
    @MainActor
    private static func denyAllPendingApprovals(_ model: AppModel) async {
        for session in model.runner.activeSessions {
            for request in session.pendingApprovals {
                await model.runner.respond(approval: request, decision: .deny("검증 중에는 도구를 쓰지 않습니다."))
            }
        }
    }

    private static func handoffIDs(_ store: Store, _ threadID: String) async -> Set<String> {
        Set(((try? await store.handoffs(threadID: threadID)) ?? []).map(\.id))
    }

    private static func asyncMap<T, R>(_ items: [T], _ transform: (T) async -> R) async -> [R] {
        var out: [R] = []
        for item in items { out.append(await transform(item)) }
        return out
    }

    // MARK: - 도우미

    /// 받는 쪽에 맡길 일: 실제 작업처럼 파일을 읽어 확인할 수 있는 짧은 일. "'인계 확인'이라고만 답하라" 같은 정해진 답을
    /// 시키면 받는 모델이 문서를 주입된 글로 보고 거절하기도 해서(2026-09-30 실측) 시험이 실제 사용을 재지 못한다.
    static let readmeTask = "README.md 첫 줄을 읽고 그 줄을 그대로 한 줄로 알려 주세요. 파일은 고치지 마세요."

    /// 받는 쪽이 인계대로 일했는가 — README 첫 줄(`# 검증용 임시 프로젝트`)을 알려 줬다. 응답이 있기만 한 것으로는 모른다
    /// (거절하는 답도 응답이다).
    static func followed(_ reply: ThreadEvent?) -> Bool {
        reply?.text.contains("검증용 임시 프로젝트") == true
    }

    /// 한도 도달을 흉내 내고 그 대화의 카드가 카운트다운이 되기를 기다린다. 검토 카드로 막히면 실패로 적고 카드를 닫는다.
    @MainActor
    private static func simulateAndWaitPending(_ t: TestKit, _ model: AppModel, _ threadID: String,
                                               label: String) async -> HandoffCard? {
        await model.simulateLimitReached(threadID: threadID)
        // 대상 선택이 모든 후보의 한도를 새로 조회하므로 `claude -p /usage` 시간이 포함된다.
        _ = await wait(150) { model.handoffCards[threadID] != nil }
        guard let pending = model.handoffCards[threadID], pending.isCountingDown else {
            let reason = reviewReasons(model.handoffCards[threadID]).joined(separator: " / ")
            await t.check("\(label) 게이트 통과 → 카운트다운", false,
                          reason.isEmpty ? (model.banner?.text.replacingOccurrences(of: "\n", with: " / ") ?? "시간 초과") : reason)
            for snap in model.limits.allSnapshots {
                await t.note("한도 \(snap.provider.rawValue)/\(snap.accountID): \(describe(snap))")
            }
            model.cancelHandoff(threadID: threadID, origin: .card)
            return nil
        }
        await t.check("\(label) 게이트 통과 → 카운트다운", true)
        return pending
    }

    /// 게이트가 막은 이유 (검토 카드).
    private static func reviewReasons(_ card: HandoffCard?) -> [String] {
        if case .automaticBlocked(let reasons)? = card?.review { return reasons }
        return []
    }

    private static func describe(_ snap: LimitSnapshot) -> String {
        let windows = snap.windows.map {
            "\($0.label)=\($0.utilization.map { String(format: "%.2f", $0) } ?? "?")"
        }
        return "\(snap.status.rawValue) · \(windows.joined(separator: ", ")) · \(snap.message ?? "")"
    }

    @MainActor
    private static func addUserMessage(_ store: Store, _ model: AppModel, _ threadID: String,
                                       _ text: String) async {
        _ = try? await store.appendEvent(ThreadEvent(threadID: threadID, kind: .userMessage,
                                                     provider: .codex, text: text))
        await model.reloadThreadData()
    }

    @MainActor
    private static func setProvider(_ store: Store, _ model: AppModel, _ threadID: String,
                                    _ provider: AgentProvider) async {
        guard var thread = (try? await store.thread(id: threadID)) ?? nil else { return }
        thread.preferredProvider = provider
        await model.updateThread(thread)
    }

    private static func handoff(_ store: Store, _ threadID: String, _ id: String) async -> Handoff? {
        ((try? await store.handoffs(threadID: threadID)) ?? []).first { $0.id == id }
    }

    private static func handoffSentCount(_ store: Store, _ threadID: String) async -> Int {
        ((try? await store.events(threadID: threadID)) ?? []).filter { $0.kind == .handoffSent }.count
    }

    /// 실행이 도구 승인을 요청하면 거절한다. 검증 중에는 파일·명령을 쓰지 않는다.
    @MainActor
    private static func denyPendingApprovals(_ model: AppModel) async {
        for request in model.runner.pendingApprovals {
            await model.runner.respond(approval: request, decision: .deny("검증 중에는 도구를 쓰지 않습니다."))
        }
    }

    @MainActor
    private static func wait(_ timeout: TimeInterval, until condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        } while Date() < deadline
        return await condition()
    }
}
