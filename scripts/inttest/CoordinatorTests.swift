import Foundation

/// RunCoordinator 오케스트레이션 검증.
/// 실제 어댑터와 실제 CLI 를 사용하고, 저장 계층도 실제 SQLite 를 쓴다.
@MainActor
final class CoordinatorProbe: RunCoordinatorDelegate {
    var events: [ThreadEvent] = []
    var states: [RunState] = []
    var finished: [(Run, AgentTurnResult, UsageRecord?)] = []
    var attentions: [(String, AttentionKind)] = []
    var limits: [LimitSnapshot] = []
    var onApproval: ((ApprovalRequest, RunCoordinator) -> Void)?

    private let coordinator: RunCoordinator

    init(coordinator: RunCoordinator) {
        self.coordinator = coordinator
    }

    func runCoordinator(_ c: RunCoordinator, didUpsert event: ThreadEvent) {
        if let idx = events.firstIndex(where: { $0.id == event.id }) { events[idx] = event }
        else { events.append(event) }
        if event.kind == .approvalRequest, let request = c.pendingApprovals.last {
            onApproval?(request, c)
        }
    }
    func runCoordinator(_ c: RunCoordinator, didChangeState state: RunState, run: Run?) {
        states.append(state)
    }
    func runCoordinator(_ c: RunCoordinator, didReceive snapshot: LimitSnapshot) {
        limits.append(snapshot)
    }
    func runCoordinator(_ c: RunCoordinator, didFinish run: Run,
                        result: AgentTurnResult, usage: UsageRecord?) {
        finished.append((run, result, usage))
    }
    func runCoordinator(_ c: RunCoordinator, needsAttention title: String, body: String,
                        threadID: String, kind: AttentionKind) {
        attentions.append((title, kind))
    }

    func waitUntilIdle(timeout: TimeInterval = 240) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !coordinator.isBusy && coordinator.activeRun == nil { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }
}

enum CoordinatorTests {

    @MainActor
    static func run(_ t: TestKit, _ e: LiveTests.Env) async {
        await t.group("오케스트레이션 · 실행/인계")

        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ahc-coord-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let store = Store(databaseURL: dbURL)
        do { try await store.bootstrap() } catch {
            await t.check("저장 계층 준비", false, "\(error)")
            return
        }
        let cliEnv = CLIEnvironment()
        let coordinator = RunCoordinator(store: store, environment: cliEnv)
        coordinator.claudePermissionMode = "acceptEdits"
        coordinator.codexApprovalPolicy = "on-request"
        coordinator.codexSandboxMode = "workspace-write"
        await coordinator.loadPrices()

        let probe = CoordinatorProbe(coordinator: coordinator)
        probe.onApproval = { request, c in
            Task { await c.respond(approval: request, decision: .allow) }
        }
        coordinator.delegate = probe

        let project = Project(name: "coord", path: e.root.path)
        try? await store.upsertProject(project)
        var thread = ConversationThread(projectID: project.id, title: "오케스트레이션 검증")
        thread.goal = "handoff_state.json 을 단계별로 갱신"
        thread.pinnedNotes = "marker 값은 바꾸지 말 것"
        // 지정한 Codex 모델이 있으면 스레드 선택으로 넘긴다 (앱과 같은 경로).
        if let model = LiveTests.codexModelOverride {
            thread.codexSelection = ModelSelection(model: model,
                                                   effort: LiveTests.codexEffortOverride)
        }
        try? await store.upsertThread(thread)

        let statePath = e.root.appendingPathComponent("coord_state.json")
        try? FileManager.default.removeItem(at: statePath)
        let marker = "CO-\(Int.random(in: 1000...9999))"

        // 1) 첫 실행: Claude 가 파일 생성
        do {
            _ = try await coordinator.send(
                prompt: "\(statePath.path) 파일을 정확히 이 내용으로 만드세요: "
                    + "{\"marker\":\"\(marker)\",\"stage\":\"claude\",\"count\":1} "
                    + "끝나면 DONE 이라고만 답하세요.",
                thread: thread, project: project, provider: .claude)
        } catch {
            await t.check("첫 실행 시작", false, "\(error)")
            return
        }
        await t.check("실행 시작 시 busy 상태", coordinator.isBusy,
                      coordinator.state.koreanName)

        // 2) 같은 대화의 두 번째 실행은 거부되어야 한다 (한 대화에는 실행 하나 — 다른 대화는 함께 돈다: TurnOptionsTests 의 다중 실행)
        var rejected = false
        var rejectionMessage = ""
        do {
            _ = try await coordinator.send(prompt: "동시 실행 시도", thread: thread,
                                           project: project, provider: .codex)
        } catch {
            rejected = true
            rejectionMessage = error.localizedDescription
        }
        await t.check("같은 대화의 두 번째 실행 거부", rejected, rejectionMessage)

        let settled = await probe.waitUntilIdle()
        await t.check("첫 실행 종료", settled, "상태 \(coordinator.state.koreanName)")
        await t.check("Claude 가 파일 생성",
                      FileManager.default.fileExists(atPath: statePath.path))
        await t.equal("완료 상태 기록", coordinator.state, RunState.completed)

        // 3) 이벤트가 실행 중 점진적으로 저장됐는지
        let stored = (try? await store.events(threadID: thread.id)) ?? []
        await t.check("이벤트가 DB 에 저장됨", stored.count >= 2, "\(stored.count)건")
        await t.check("사용자 메시지 기록", stored.contains { $0.kind == .userMessage })
        await t.check("에이전트 응답 기록", stored.contains { $0.kind == .agentMessage })
        await t.check("이벤트 순번 단조 증가",
                      zip(stored, stored.dropFirst()).allSatisfy { $0.seq < $1.seq })

        // 4) 사용량과 비용이 기록됐는지
        let usage = (try? await store.usage(threadID: thread.id)) ?? []
        await t.check("턴 사용량 기록", !usage.isEmpty, "\(usage.count)건")
        if let u = usage.first {
            await t.check("비용 출처 명시", u.costSource != .unknown || u.costUSD == nil,
                          u.costSource.koreanName)
            await t.check("모델 기록", u.model != nil, u.model ?? "없음")
            await t.check("사용량 확정 표시", u.confirmed)
        }

        // 5) 세션 ID 가 (스레드, 제공자) 에 저장됐는지
        let claudeSession = try? await store.session(threadID: thread.id, provider: .claude,
                                                     accountID: "")
        await t.check("Claude 세션 ID 저장", (claudeSession?.cliSessionID?.count ?? 0) > 10)
        await t.check("CLI 버전 기록", claudeSession?.cliVersion != nil,
                      claudeSession?.cliVersion ?? "없음")

        // 6) 인계 초안 생성 (추가 모델 호출 없음)
        let allEvents = (try? await store.events(threadID: thread.id)) ?? []
        let runs = (try? await store.runs(threadID: thread.id)) ?? []
        let git = await GitInspector.snapshot(at: e.root,
                                              environment: await cliEnv.childEnvironment())
        let baseSeq = (try? await store.maxSeq(threadID: thread.id)) ?? 0
        let packet = HandoffPacketBuilder.build(HandoffPacketBuilder.Input(
            thread: thread, project: project, fromProvider: .claude, toProvider: .codex,
            events: allEvents, runs: runs, lastConfirmedPacket: nil, git: git, baseSeq: baseSeq))
        let packetText = HandoffPacketBuilder.render(packet, threadTitle: thread.title,
                                                     projectPath: project.path)
        var handoff = Handoff(threadID: thread.id, fromProvider: .claude, toProvider: .codex,
                              fromSessionID: claudeSession?.cliSessionID, baseSeq: baseSeq,
                              draftJSON: "{}",
                              finalText: packetText + "\n\n---\n## 새 지시\n"
                                + "\(statePath.path) 의 count 를 2, stage 를 codex 로 바꾸세요. "
                                + "marker 는 그대로 두세요. 끝나면 결과 JSON 만 출력하세요.")
        try? await store.insertHandoff(handoff)

        await t.check("초안 상태에서는 전송 가능", coordinator.canSend(handoff: handoff))

        // 7) 인계 전송
        do {
            _ = try await coordinator.deliver(handoff: handoff, thread: thread, project: project)
        } catch {
            await t.check("인계 전송 시작", false, "\(error)")
            return
        }
        await t.check("인계 전송 중 상태", coordinator.isBusy)

        // 8) 전송 중 중복 전송 금지
        var duplicateBlocked = false
        do {
            var reloaded = (try await store.handoffs(threadID: thread.id))
                .first { $0.id == handoff.id } ?? handoff
            reloaded.deliveryState = .sending
            _ = try await coordinator.deliver(handoff: reloaded, thread: thread, project: project)
        } catch {
            duplicateBlocked = true
        }
        await t.check("전송 중 인계 중복 전송 차단", duplicateBlocked)

        let delivered = await probe.waitUntilIdle(timeout: 300)
        await t.check("인계 전송 실행 종료", delivered)

        // 9) 전달 상태 판정
        let handoffs = (try? await store.handoffs(threadID: thread.id)) ?? []
        handoff = handoffs.first { $0.id == handoff.id } ?? handoff
        await t.check("전달 상태가 기록됨",
                      handoff.deliveryState == .delivered || handoff.deliveryState == .unknown,
                      handoff.deliveryState.koreanName + " / " + (handoff.note ?? ""))
        if handoff.deliveryState == .delivered {
            await t.check("대상 세션 ID 기록", handoff.toSessionID != nil)
            let codexSession = try? await store.session(threadID: thread.id, provider: .codex,
                                                        accountID: "")
            await t.equal("전달 지점(lastDeliveredSeq) 기록",
                          codexSession?.lastDeliveredSeq ?? -1, handoff.baseSeq)
        }
        await t.check("전달 확인 후 재전송 금지", !coordinator.canSend(handoff: handoff))

        let afterCodex = (try? String(contentsOf: statePath, encoding: .utf8)) ?? ""
        await t.check("Codex 가 인계를 받아 파일 수정", afterCodex.contains("\"count\":2")
                        || afterCodex.contains("\"count\": 2"),
                      JSONUtil.truncate(afterCodex, max: 160))
        await t.check("marker 보존", afterCodex.contains(marker))

        // 10) 인계 이벤트가 대화에 남았는지
        let finalEvents = (try? await store.events(threadID: thread.id)) ?? []
        await t.check("인계 전송 이벤트 기록",
                      finalEvents.contains { $0.kind == .handoffSent })
        await t.check("인계 수신 상태 이벤트 기록",
                      finalEvents.contains { $0.kind == .handoffReceived })

        // 11) 늦은 승인 응답은 적용되지 않는다
        let stale = ApprovalRequest(id: "stale-id", runID: "already-finished-run",
                                    provider: .claude, kind: .tool, toolName: "Write",
                                    title: "t", detail: "d")
        await coordinator.respond(approval: stale, decision: .allow)
        await t.check("종료된 실행의 늦은 승인은 무시",
                      coordinator.lastErrorMessage?.contains("이미 종료된") == true,
                      coordinator.lastErrorMessage ?? "메시지 없음")

        // 12) 앱 재시작 복구: 활성 실행 자동 완료 금지
        var orphan = Run(threadID: thread.id, sessionID: claudeSession?.id ?? "s",
                         provider: .claude, requestText: "강제 종료된 실행", state: .running)
        try? await store.insertRun(orphan)
        let dangling = (try? await store.danglingActiveRuns()) ?? []
        await t.check("재시작 시 미확정 실행 보존", dangling.contains { $0.id == orphan.id })
        orphan.state = .handoffDeliveryUnknown
        try? await store.updateRun(orphan)

        await store.db.close()
    }
}
