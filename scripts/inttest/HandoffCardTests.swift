import Foundation

// MARK: - 인계 카드 (B 설계 C1) · 입력창이 받는 쪽을 보인다 · 대기열 보류 (C2)

/// 대화 끝의 인계 카드: 순수 판정(단계 · 주의 · 막힘 · 요약 · 글)과, 실제 `AppModel` · `RunCoordinator` · SQLite 를 거치는 흐름
/// (CLI 만 가짜 — `ScriptedAgentAdapter`, Gemini 정리는 가짜 agy 스크립트). 보내기는 동기 점유 → DB 점유, 칩은 전달이 확인될 때.
@MainActor
enum HandoffCardTests {

    static func run(_ t: TestKit) async {
        await pure(t)
        await summary(t)
        await orchestrationRequests(t)
        await approvalsInPacket(t)
        await answersInPacket(t)
        await approvalSecrets(t)
        await packetFacts(t)
        await essentialFacts(t)
        await receiverAndText(t)
        await scenario(t, "인계 카드: 카운트다운 중 사람이 먼저 [지금 넘기기] — 한 번만 간다", countdownHumanFirst)
        await scenario(t, "인계 카드: 카운트다운이 먼저 울린 뒤의 [지금 넘기기] — 한 번만 간다", countdownTimerFirst)
        await scenario(t, "인계 카드: 자동 준비는 사람이 연 카드 · 전달 중을 덮지 않는다", automaticDoesNotOverwrite)
        await scenario(t, "인계 카드: 자동 인계의 조회 사이 사람이 연 · 취소한 · 넘긴 인계가 이긴다", automaticYieldsToHuman)
        await scenario(t, "인계 카드: 자동 준비 중에 사람이 손대면 카운트다운 없이 확인 길로", automaticTouchedDuringPreparation)
        await scenario(t, "인계 카드: 자동 전송이 막히면 지난 일로 남기고 넘길 수 있는 카드로", automaticSendBlocked)
        await scenario(t, "인계 카드: 앱 종료를 묻는 동안 카운트다운 · 전달을 막는다", quitSuspension)
        await scenario(t, "인계 카드: 전달 중 앱 종료가 이어지면 전달된 칩을 옮긴다", quitAfterDelivered)
        await scenario(t, "인계 카드: 전달 중의 알림 취소 · 전달 중 받는 계정 해제", lateCancelAndRemovedReceiver)
        await scenario(t, "인계 카드: 전달된 행 · 보내는 중 취소", deliveredAndSending)
        await scenario(t, "인계 카드: 받는 에이전트가 바뀌면 자동 승인을 끈다", autoApprovalOffOnProviderChange)
        await scenario(t, "인계 카드: 카운트다운을 멈추는 것 · 고친 글 · 덧붙인 말", pauseEditMemo)
        await scenario(t, "인계 카드: 두 대화 · 지문 · 받는 계정 · 막는 대화", cardsAndBlocks)
        await scenario(t, "인계 지문: 이미 바뀐 파일을 다시 고치거나 추적 안 하는 파일을 고쳐도 바뀐다", fingerprintContent)
        await scenario(t, "인계 카드: 늦게 끝난 준비 · Gemini 재정리와 보내기의 경합", geminiRace)
        await scenario(t, "인계 카드: 받는 쪽 계정의 모델", receiverScope)
        await scenario(t, "인계 카드: 카드에서 고른 받는 모델 (Codex · Claude)", receiverModelPicked)
        await scenario(t, "대기열 보류: 카드가 있는 동안 · 전달됨 · 실패 · 미확인 · 취소", holds)
        await scenario(t, "대기열 보류: 다시 켬 · 한도로 멈춘 앞 메시지", holdsRelaunch)
        await scenario(t, "인계 카드: 칸 머리 · 응답 필요 · Dock", attention)
        await scenario(t, "인계 카드: 받는 쪽을 쓸 수 없으면 넘기기를 막고 다시 확인으로 푼다", receiverUnavailable)
        await scenario(t, "인계 카드: 걸어 둔 메시지를 덧붙일 말로 · 키보드로 확인하고 넘기기", heldMemoAndKeyboard)
        await scenario(t, "인계 카드: 전달 여부 미확인 카드를 닫고 다시 만들기 · 받는 쪽 다시 확인", unknownAndRecheck)
        await scenario(t, "자동 인계: 받을 수 있는 에이전트가 없으면 카드 · 알림을 만들지 않는다", automaticWithoutReceiver)
        await scenario(t, "이어 받을 순서: 받지 않음으로 둔 대상은 고르지 않는다", excludedTargets)
    }

    private static func scenario(_ t: TestKit, _ name: String, _ body: (TestKit) async throws -> Void) async {
        await t.group(name)
        do { try await body(t) } catch { await t.check("시나리오 실행 중 예외", false, "\(error)") }
    }

    // MARK: 도우미

    nonisolated static func packet(nextActions: [String] = ["아직 처리되지 않은 사용자 지시: 워커 테스트도 붙여 줘."],
                       git: GitSnapshot = GitSnapshot(), tests: [String] = [], unverified: [String] = [],
                       goal: String = "웹훅 재시도 큐") -> HandoffPacket {
        HandoffPacket(goal: goal, constraints: "미확인 — 고정 메모에 기록된 제약이 없습니다.", completed: [], inProgress: [],
                      decisions: [], failedAttempts: [], changedFiles: git, testsRun: tests, interrupted: [],
                      nextActions: nextActions, references: [], unverified: unverified, transcriptExcerpt: "",
                      fromProvider: .claude, toProvider: .codex, baseSeq: 0)
    }

    nonisolated static func card(phase: HandoffCard.Phase = .ready, review: HandoffCard.Review? = nil, confirmed: Bool = false,
                     summarizing: Bool = false) -> HandoffCard {
        var card = HandoffCard(draft: HandoffDraft(handoff: Handoff(threadID: "t", fromProvider: .claude, toProvider: .codex,
                                                                    baseSeq: 0, draftJSON: "{}", finalText: "x"),
                                                   packet: packet(), text: "x", threadTitle: "t"),
                               origin: .manual)
        card.phase = phase
        card.review = review
        card.confirmed = confirmed
        card.summarizing = summarizing
        return card
    }

    /// 가짜 받는 쪽의 행동.
    final class Behavior {
        enum Mode { case reply, setupFails, unknown, waitThenReply, replyThenWait }
        var mode: Mode = .reply
        var adapters: [ScriptedAgentAdapter] = []
        var requests: [AgentTurnRequest] { adapters.flatMap(\.requests) }
    }

    /// 임시 폴더(원하면 git 저장소) · 임시 DB · 프로젝트 · 기록 있는 대화들 · 가짜 CLI 로 띄운 `AppModel`.
    @MainActor
    struct Env {
        let root: URL
        let folder: URL
        let store: Store
        let project: Project
        let model: AppModel
        let threads: [ConversationThread]
        let behavior: Behavior

        func current(_ id: String) -> ConversationThread? { model.allThreads().first { $0.id == id } }

        func settle(_ seconds: Double = 10, _ condition: @MainActor () -> Bool) async {
            for _ in 0..<Int(seconds * 100) where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        }

        func sentCount(_ threadID: String) async -> Int {
            ((try? await store.events(threadID: threadID)) ?? []).filter { $0.kind == .handoffSent }.count
        }

        func row(_ threadID: String, _ id: String) async -> Handoff? {
            ((try? await store.handoffs(threadID: threadID)) ?? []).first { $0.id == id }
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    static func makeEnv(_ name: String, threads titles: [String] = ["대화"], git: Bool = false,
                        history: Bool = true) async throws -> Env {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-card-\(name)-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# 카드 시험\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        if git {
            for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.invalid"], ["config", "user.name", "t"],
                              ["add", "."], ["commit", "-q", "-m", "base"]] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                process.currentDirectoryURL = folder
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
            }
        }
        let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
        try await store.bootstrap()
        let project = Project(name: "p", path: folder.path)
        try await store.upsertProject(project)
        var threads: [ConversationThread] = []
        for title in titles {
            var thread = ConversationThread(projectID: project.id, title: title)
            thread.preferredProvider = .claude
            thread.claudeSelection = ModelSelection(model: "sonnet", effort: "high")      // 모델 목록 조회(CLI)를 타지 않게
            thread.codexSelection = ModelSelection(model: "gpt-5.6-sol", effort: "high")
            try await store.upsertThread(thread)
            if history {
                // 기록: Claude 가 한 턴 일했고, 사람이 다음 일을 남겼다 (인계는 기록이 있는 대화만 한다).
                let session = try await store.ensureSession(threadID: thread.id, provider: .claude, accountID: "")
                let run = Run(threadID: thread.id, sessionID: session.id, provider: .claude, requestText: "첫 일",
                              state: .completed, startedAt: Date().addingTimeInterval(-60), endedAt: Date().addingTimeInterval(-50),
                              terminalReason: "completed")
                try await store.insertRun(run)
                _ = try await store.appendEvent(ThreadEvent(threadID: thread.id, runID: run.id, kind: .userMessage,
                                                            title: "사용자", text: "첫 일"))
                _ = try await store.appendEvent(ThreadEvent(threadID: thread.id, runID: run.id, kind: .agentMessage,
                                                            provider: .claude, text: "했습니다."))
                _ = try await store.appendEvent(ThreadEvent(threadID: thread.id, kind: .userMessage,
                                                            title: "사용자", text: "워커 테스트도 붙여 줘."))
            }
            threads.append(thread)
        }
        let model = AppModel(store: store)
        let behavior = Behavior()
        model.claudeLoginCheck = { nil }
        model.runner.adapterFactory = { [behavior] provider in
            let adapter = ScriptedAgentAdapter(provider: provider) { [behavior] _ in
                switch behavior.mode {
                case .reply:
                    return [.emit(.sessionEstablished(sessionID: "s-\(provider.rawValue)", model: "fake", cliVersion: nil)),
                            .emit(.assistantMessage("받았습니다.")),
                            .finish(AgentTurnResult(state: .completed, terminalReason: "completed", sessionID: "s"))]
                case .setupFails:
                    return [.finish(AgentTurnResult(state: .failed, terminalReason: "setup_failed", isError: true,
                                                    errorMessage: "세션을 만들지 못했습니다"))]
                case .unknown:
                    return [.finish(AgentTurnResult(state: .failed, terminalReason: "exit_9", isError: true,
                                                    errorMessage: "끊겼습니다"))]
                case .replyThenWait:
                    // 받는 쪽이 답을 시작했고(수신 확인) 아직 끝나지 않았다 — 앱 종료로 끊는 장면.
                    return [.emit(.sessionEstablished(sessionID: "s-\(provider.rawValue)", model: "fake", cliVersion: nil)),
                            .emit(.assistantMessage("받았습니다. 일하는 중입니다.")),
                            .waitSignal("never")]
                case .waitThenReply:
                    // 검증이 `signal("go")` 를 부를 때까지 받는 쪽 실행이 돈다 (전달 중인 동안의 일을 보려고).
                    return [.waitSignal("go"),
                            .emit(.sessionEstablished(sessionID: "s-\(provider.rawValue)", model: "fake", cliVersion: nil)),
                            .emit(.assistantMessage("받았습니다.")),
                            .finish(AgentTurnResult(state: .completed, terminalReason: "completed", sessionID: "s"))]
                }
            }
            behavior.adapters.append(adapter)
            return adapter
        }
        await model.reloadProjects()
        await model.selectThread(threads[0].id)
        for thread in threads.dropFirst() { await model.reloadThreadData(threadID: thread.id, create: true) }
        return Env(root: root, folder: folder, store: store, project: project, model: model, threads: threads, behavior: behavior)
    }

    // MARK: 순수 판정

    static func pure(_ t: TestKit) async {
        await t.group("인계 카드: 단계 · 주의 · 막힘 (순수)")
        await t.check("넘길 수 있는 단계: 준비 · 카운트다운 · 실패 (재정리 중이 아니면)",
                      card().canBeginSend && card(phase: .countingDown(deadline: Date(), delay: 5)).canBeginSend
                        && card(phase: .failed("x")).canBeginSend && !card(phase: .sending).canBeginSend
                        && !card(phase: .unknown).canBeginSend && !card(summarizing: true).canBeginSend)
        await t.equal("주의: 수동 카드 · 사람이 멈춘 카드 · 보내는 중은 초안 (답을 기다리지 않는다)",
                      [card().attention, card(review: .pausedByHuman).attention, card(phase: .sending).attention],
                      [.draft, .draft, .draft])
        await t.equal("주의: 게이트 막힘 · 실패 · 미확인 · 계정 해제 · 낡음은 검토, 카운트다운은 카운트다운",
                      [card(review: .automaticBlocked(["x"])).attention, card(phase: .failed("x")).attention,
                       card(phase: .unknown).attention, card(review: .accountRemoved("둘째")).attention,
                       card(review: .stale("x")).attention, card(phase: .countingDown(deadline: Date(), delay: 3)).attention],
                      [.review, .review, .review, .review, .review, .countdown])
        await t.check("승인 바탕은 카운트다운 · 검토 · 실패 카드만 (수동 · 사람이 멈춘 카드는 보통 바탕)",
                      card(phase: .countingDown(deadline: Date(), delay: 3)).highlighted && card(phase: .failed("x")).highlighted
                        && !card().highlighted && !card(review: .pausedByHuman).highlighted)
        await t.check("사람이 넘길 수 있는 카드: 체크 · 준비/실패 · 재정리 아님 · 낡지 않음",
                      card(confirmed: true).sendableByHuman && card(phase: .failed("x"), confirmed: true).sendableByHuman
                        && !card().sendableByHuman && !card(phase: .countingDown(deadline: Date(), delay: 3), confirmed: true).sendableByHuman
                        && !card(review: .stale("x"), confirmed: true).sendableByHuman
                        && !card(confirmed: true, summarizing: true).sendableByHuman)

        var facts = HandoffSendFacts()
        await t.check("막힘 없음", HandoffSendBlock.first(facts) == nil)
        facts.gitOperation = "커밋"
        facts.runActive = true
        facts.runWaitingNote = " (백그라운드 작업 2개)"
        await t.equal("실행 중이 git 명령보다 먼저 · 백그라운드 수를 적는다", HandoffSendBlock.first(facts),
                      .running(" (백그라운드 작업 2개)"))
        facts.summarizing = true
        await t.equal("재정리 중이 가장 먼저", HandoffSendBlock.first(facts), .summarizing)
        await t.equal("자동 전송이 막혀 넘기지 않은 까닭은 지난 일로 (막힘이 풀린 뒤에도 남는다)",
                      HandoffSendBlock.gitRunning("가져오기(fetch)").automaticSkipReason,
                      "보내려던 때 git 명령(가져오기(fetch))이 돌고 있어 자동으로 넘기지 않았습니다")
        await t.check("막힘 문장은 한 형식 (실행 중)", HandoffSendBlock.running(" (백그라운드 작업 2개)").message
                        == "이 대화에서 에이전트가 실행 중입니다 (백그라운드 작업 2개) — 끝나면 넘길 수 있습니다")

        await t.group("인계 카드: 글 (순수)")
        let now = Date()
        await t.equal("머리: 한도 · 초기화 시각", HandoffCardText.headline(origin: .limitReached(scope: .claude, resetsAt: now),
                                                                    source: "Claude", target: "Codex", reset: "20:30 초기화"),
                      "Claude 사용 한도에 닿았습니다 · 20:30 초기화")
        await t.equal("머리: 한도 · 시각 모름", HandoffCardText.headline(origin: .limitReached(scope: .claude, resetsAt: nil),
                                                                  source: "Claude", target: "Codex", reset: nil),
                      "Claude 사용 한도에 닿았습니다 · 초기화 시각 미확인")
        await t.equal("머리: 제안 (받는 쪽과 동사까지)", HandoffCardText.headline(origin: .suggestion(scope: .claude, peak: 0.81, windowLabel: "5시간"),
                                                                       source: "Claude", target: "Codex", reset: nil),
                      "Claude 5시간 사용률 81% — Codex 에게 이어 맡깁니다")
        await t.equal("머리: 수동 · 칩", [HandoffCardText.headline(origin: .manual, source: "Claude", target: "Codex", reset: nil),
                                       HandoffCardText.headline(origin: .chip, source: "Claude", target: "Codex", reset: nil)],
                      ["Codex 에게 이어서 맡깁니다", "Codex 에게 이어서 맡깁니다"])
        await t.equal("머리: 접힌 카드의 한도 머리는 초기화 구절 없이 짧게",
                      HandoffCardText.headline(origin: .limitReached(scope: .claude, resetsAt: nil), source: "Claude", target: "Codex",
                                               reset: "20:30 초기화", folded: true),
                      "Claude 사용 한도 도달")
        let later = now.addingTimeInterval(3600), earlier = now.addingTimeInterval(-3600)
        await t.equal("초기화 사실: 지금 스냅샷 > 적어 둔 값 · 지난 값은 지난 사실 · 풀림 · 모름",
                      [HandoffCardText.resetPhrase(current: later, fixed: earlier, releasedSince: false, now: now),
                       HandoffCardText.resetPhrase(current: nil, fixed: earlier, releasedSince: true, now: now),
                       HandoffCardText.resetPhrase(current: nil, fixed: later, releasedSince: true, now: now),
                       HandoffCardText.resetPhrase(current: nil, fixed: later, releasedSince: false, now: now),
                       HandoffCardText.resetPhrase(current: nil, fixed: nil, releasedSince: false, now: now)],
                      ["\(HandoffCardText.resetClock(later, now: now)) 초기화", "\(HandoffCardText.resetClock(earlier, now: now)) 에 초기화됨",
                       "한도 풀림", "\(HandoffCardText.resetClock(later, now: now)) 초기화", "초기화 시각 미확인"])
        var freed = LimitSnapshot(provider: .claude, accountID: "")
        freed.status = .ok
        freed.fetchedAt = now
        // 5시간 창이 10분 전에 새로 시작했다 (초기화 시각 = 지금 + 4시간 50분) — 근거 규칙은 LimitLineTests.
        freed.windows = [LimitWindow(label: "5시간", utilization: 0.2, resetsAt: now.addingTimeInterval(5 * 3600 - 600), spanMinutes: 300)]
        await t.check("풀림: 한도에 닿은 뒤 창이 다시 시작했다 (그 전에 읽은 값은 아니다)",
                      HandoffCardText.released(freed, since: earlier) && !HandoffCardText.released(freed, since: later))
        await t.equal("실패 줄은 쌍점을 겹치지 않는다 (이유가 이미 '…못했습니다: …' 꼴)",
                      HandoffCardText.subline(card(phase: .failed("대상 세션을 시작하지 못했습니다: CLI 없음")), target: "Codex"),
                      "보내지 못했습니다 — 대상 세션을 시작하지 못했습니다: CLI 없음")
        await t.equal("카운트다운 카드의 머리 아래 줄 — 초는 링만 센다", HandoffCardText.countdownSubline(target: "Codex"),
                      "카운트다운이 끝나면 Codex 에게 넘깁니다")
        await t.check("카운트다운 중 입력창 자리 글은 걸면 자동 인계가 멈춘다는 것을 말한다",
                      HandoffCardText.countdownComposerPlaceholder(target: "Codex").contains("자동 인계가 멈추고")
                        && HandoffCardText.countdownComposerPlaceholder(target: "Codex").contains("Codex 에게"))
        await t.equal("보류 칩의 도움말: 바꿀 수 있을 때만 바꾸는 곳을 말한다",
                      [HandoffCardText.composerChipHelp(target: "Codex", changeable: true),
                       HandoffCardText.composerChipHelp(target: "Codex", changeable: false)],
                      ["인계가 끝나면 다음 메시지는 Codex 에게 갑니다 — 받는 쪽은 대화 끝의 카드나 이 메뉴에서 바꿉니다.",
                       "인계를 준비하거나 보내는 중입니다 — 끝나면 다음 메시지는 Codex 에게 갑니다."])
        await t.equal("카운트다운 문장 · 알림 문장", [HandoffCardText.countdown(seconds: 9, target: "Codex"),
                                                HandoffCardText.announcement(seconds: 10, target: "Codex")],
                      ["9초 뒤 Codex 에게 넘깁니다", "자동 인계: 10초 뒤 Codex 에게 넘깁니다"])
        await t.equal("입력창 위 한 줄 (따라가지 않을 때)", [HandoffCardText.peekCountdown(seconds: 7), HandoffCardText.peekReview],
                      ["자동 인계 7초 · 보기", "인계 검토 필요 · 보기"])
        await t.equal("사실: 로그인 확인 · 나이", HandoffCardText.loginFact(provider: .codex, authenticated: true,
                                                                       checkedAt: now.addingTimeInterval(-180), now: now)?.text,
                      "로그인 확인 · 3분 전")
        await t.equal("사실: 모르는 로그인에 ✓ 를 붙이지 않는다", HandoffCardText.loginFact(provider: .claude, authenticated: nil,
                                                                                checkedAt: nil, now: now)?.tone, .unknown)
        let limit = LimitSnapshot(provider: .codex, accountID: "a", status: .ok,
                                  windows: [LimitWindow(label: "5시간", utilization: 0.12)], fetchedAt: now.addingTimeInterval(-180))
        await t.equal("사실: 사용률 · 확인한 때", HandoffCardText.limitFact(provider: .codex, limit: limit, now: now)?.text,
                      "사용률 12% · 3분 전 확인")
        await t.equal("사실: 한도 정보 없음", HandoffCardText.limitFact(provider: .codex, limit: LimitSnapshot(provider: .codex), now: now)?.text,
                      "한도 정보 없음")
        await t.equal("세션 줄", [HandoffCardText.session(.resumes, target: "Codex"), HandoffCardText.session(.fresh, target: "Codex")],
                      ["이 대화의 Codex 세션을 이어 갑니다", "새 세션에서 이 문서로 시작합니다"])
        // 카드의 "대기 중인 메시지 n개는 …" 줄은 없앴다 — 바로 아래 입력창의 대기열 머리가 같은 사실을 한 번 말한다.
        await t.equal("보류 문장 (입력창 · 목록 머리)", [HandoffCardText.composerPlaceholder(target: "Codex"),
                                                  HandoffCardText.queueHeader(target: "Codex")],
                      ["인계가 끝나면 Codex 에게 이어서 보냅니다…", "Codex 에게 인계한 뒤 보냅니다"])
        await t.equal("보류를 풀 때의 멈춤 이유 — 지금 칩을 적는다",
                      [HandoffCardText.pauseReason(.cancelled, chip: "Claude", chipHasContext: true),
                       HandoffCardText.pauseReason(.delivered, chip: "Claude", chipHasContext: true)],
                      ["인계를 취소했습니다 — 이어서 보내면 Claude 에게 갑니다", nil])
        await t.equal("'맥락 없이' 는 까닭이 아니라 칩이 맥락을 가졌는지로 — 해제 · 다시 켬도 보내는 쪽 칩이면 붙이지 않는다",
                      [HandoffCardText.pauseReason(.receiverRemoved("둘째"), chip: "Claude", chipHasContext: true),
                       HandoffCardText.pauseReason(.cancelled, chip: "Codex", chipHasContext: false),
                       HandoffCardText.relaunchPauseReason(chip: "Claude", chipHasContext: true),
                       HandoffCardText.relaunchPauseReason(chip: "Codex", chipHasContext: false)],
                      ["받는 Codex 계정(둘째)의 등록이 해제됐습니다 — 이어서 보내면 Claude 에게 갑니다",
                       "인계를 취소했습니다 — 이어서 보내면 Codex 에게 맥락 없이 갑니다",
                       "인계 카드가 사라졌습니다 — 이어서 보내면 Claude 에게 갑니다",
                       "인계 카드가 사라졌습니다 — 이어서 보내면 Codex 에게 맥락 없이 갑니다"])
        await t.equal("늦은 알림 취소의 제목", [HandoffLateCancel.sending.title, HandoffLateCancel.delivered.title],
                      ["이미 보내는 중입니다", "이미 넘겼습니다"])
        await t.check("전달 여부 미확인 카드의 입력창 · 대기열 글은 받는 쪽에게 간다고 약속하지 않는다",
                      !HandoffCardText.unknownComposerPlaceholder.contains("에게") && !HandoffCardText.unknownQueueHeader.contains("에게")
                        && HandoffCardText.unknownQueueHeader.contains("멈춥니다"))
        await t.equal("입력창 이어 맡기기 행 도움말 — 이름은 하나의 값, 문장은 형식 하나",
                      ContinueChoice.help(for: .continueWith, name: "Codex · 둘째"),
                      "현재 맥락을 Codex · 둘째 에게 넘길 초안을 대화 끝의 카드로 만듭니다. 내용을 확인하고 넘기기를 눌러야 전송되고, "
                        + "받는 쪽은 받자마자 일을 시작합니다.")
        await t.equal("같은 Codex 의 다른 계정 행 도움말 — 인계하지 않고 같은 세션을 이어 간다",
                      ContinueChoice.help(for: .switchAccount, name: "Codex · 둘째"),
                      "다음 메시지부터 Codex · 둘째 에서 실행합니다. 이 대화의 Codex 세션을 그대로 이어 가므로 지금까지의 대화를 압니다 — "
                        + "인계 문서를 만들지 않습니다.")
        await t.equal("⇧⌘H 메뉴 이름 = 메뉴바 이름 (카드가 있으면 그 카드로 가므로 '만들기' 가 아니다)",
                      MenuShortcut.handoff.title, "인계 카드 열기")

        await t.group("인계 카드: 접힌 카드 · 막은 이유 (순수)")
        await t.check("접힌 카드에서 확인 전이면 주 단추는 [펼쳐서 확인] (펼친 카드 · 확인한 카드 · 카운트다운은 아니다)",
                      card().foldedNeedsExpand(folded: true) && !card().foldedNeedsExpand(folded: false)
                        && !card(confirmed: true).foldedNeedsExpand(folded: true)
                        && !card(phase: .countingDown(deadline: Date(), delay: 3)).foldedNeedsExpand(folded: true))
        let blocked = card(review: .automaticBlocked(["대상 한도 여유를 확인할 수 없습니다.", "Codex 제외: 로그인 미확인"]))
        await t.equal("접힌 카드는 게이트의 첫 이유를 보인다", blocked.foldedReviewReason, "대상 한도 여유를 확인할 수 없습니다.")
        await t.check("수동 · 사람이 멈춘 카드에는 접힌 이유가 없다",
                      card().foldedReviewReason == nil && card(review: .pausedByHuman).foldedReviewReason == nil)
        await t.check("확인 체크는 펼친 카드에만 (접힌 카드에서 보지 않고 체크해 넘기지 않게)",
                      blocked.showsConfirm(folded: false) && !blocked.showsConfirm(folded: true)
                        && !card(phase: .countingDown(deadline: Date(), delay: 3)).showsConfirm(folded: false)
                        && !card(phase: .unknown).showsConfirm(folded: false))
        await t.equal("'아래 이유' 는 이유가 있을 때만",
                      [HandoffCardText.subline(blocked, target: "Codex"),
                       HandoffCardText.subline(card(review: .automaticBlocked([])), target: "Codex")],
                      ["자동으로 넘기지 않았습니다 — 아래 이유를 확인하고 넘기세요",
                       "자동으로 넘기지 않았습니다 — 내용을 확인하고 넘기세요"])

        await t.group("한도가 풀리는 시각 = 다 찬 계정 전체 창 (순수)")
        let soon = now.addingTimeInterval(3_600)
        let week = now.addingTimeInterval(4 * 86_400)
        let weekly = LimitSnapshot(provider: .claude, status: .subscriptionCap, windows: [
            LimitWindow(label: "5시간", utilization: 0.4, resetsAt: soon),
            LimitWindow(label: "이번 주", utilization: 1.0, resetsAt: week),
            LimitWindow(label: "이번 주 (Fable)", utilization: 1.0, resetsAt: soon, model: "Fable")])
        await t.equal("주간 창이 찼으면 5시간 창 · 모델 창의 이른 시각이 아니라 주간 창의 시각", weekly.capResetsAt(now: now), week)
        let both = LimitSnapshot(provider: .claude, status: .subscriptionCap, windows: [
            LimitWindow(label: "5시간", utilization: 1.0, resetsAt: soon), LimitWindow(label: "이번 주", utilization: 1.0, resetsAt: week)])
        await t.equal("둘 다 찼으면 가장 늦은 것", both.capResetsAt(now: now), week)
        let unknownCap = LimitSnapshot(provider: .claude, status: .subscriptionCap, windows: [
            LimitWindow(label: "5시간", utilization: 0.3, resetsAt: soon)])
        await t.check("다 찬 창을 모르면 미확인", unknownCap.capResetsAt(now: now) == nil)
        let noClock = LimitSnapshot(provider: .claude, status: .subscriptionCap, windows: [
            LimitWindow(label: "5시간", utilization: 1.0, resetsAt: soon), LimitWindow(label: "이번 주", utilization: 1.0)])
        await t.check("다 찬 창의 시각을 모르면 미확인 (이른 시각을 적지 않는다)", noClock.capResetsAt(now: now) == nil)
    }

    static func summary(_ t: TestKit) async {
        await t.group("인계 카드: 요약 = 받는 문서의 절 순서")
        var git = GitSnapshot()
        git.isRepository = true
        git.unstaged = ["M src/stripe.ts", "M src/webhookJobs.ts"]
        git.untracked = ["test/webhookWorker.test.ts", "a.ts", "b.ts"]
        let rows = HandoffCardSummary.rows(packet(
            nextActions: ["아직 처리되지 않은 사용자 지시: 워커 테스트도 붙여 줘.", "이어서 처리 필요: 한도로 중단됨"],
            git: git, tests: ["실행됨(관찰): npm test -- webhookWorker → 종료 코드 1"],
            unverified: ["각 변경의 의도와 설계 근거는 앱이 판단할 수 없습니다. 필요하면 사용자가 보완하세요.",
                         "중단된 작업의 실제 진행 정도와 부분 변경 여부는 확인되지 않았습니다."]))
        await t.equal("절 순서", rows.map(\.label), ["다음 행동", "목표", "파일 상태", "테스트", "확인 필요"])
        await t.equal("다음 행동: 머리말을 벗기고 나머지는 개수로", rows[0].text, "워커 테스트도 붙여 줘. 외 1개")
        await t.equal("파일 상태: 수 · 이름 셋 · 나머지 수", rows[2].text, "5개 바뀜, 커밋 안 함 — stripe.ts · webhookJobs.ts · webhookWorker.test.ts 외 2개")
        await t.equal("테스트: 관찰한 마지막 명령 · 종료 코드", rows[3].text, "npm test -- webhookWorker → 종료 코드 1")
        await t.check("확인 필요: 고정 문장은 세지 않는다 — 고유 항목 하나면 개수 없이 그 문장 · 황색",
                      rows[4].text == "중단된 작업의 실제 진행 정도와 부분 변경 여부는 확인되지 않았습니다." && rows[4].warn, rows[4].text)
        let two = HandoffCardSummary.rows(packet(unverified: Array(HandoffCardSummary.fixedUnverified)
                                                 + ["중단된 작업의 실제 진행 정도와 부분 변경 여부는 확인되지 않았습니다.",
                                                    "이 실행의 종료 여부가 확인되지 않았습니다. 파일이 더 변경되었을 수 있습니다."]))
        await t.equal("확인 필요: 고유 항목이 둘이면 그 수 (고정 문장은 빼고)", two.last?.text,
                      "2개 — 중단된 작업의 실제 진행 정도와 부분 변경 여부는 확인되지 않았습니다.")
        let fixedOnly = HandoffCardSummary.rows(packet(unverified: Array(HandoffCardSummary.fixedUnverified)))
        await t.check("고정 문장만 있으면 '확인 필요' 줄이 없다 (판단할 것이 없는 카드에 황색을 붙이지 않는다)",
                      !fixedOnly.contains { $0.kind == .unverified }, "\(fixedOnly.map(\.label))")
        let plain = HandoffCardSummary.rows(packet(nextActions: ["미확인 — 다음 행동을 사용자가 직접 적어 주세요."]))
        await t.check("다음 행동을 모르면 지어내지 않고 덧붙일 말로", plain[0].warn && plain[0].text.contains("찾지 못했습니다"))
        await t.equal("테스트 기록 없음", plain[3].text, "관찰된 테스트 실행 기록 없음")
        await t.equal("저장소가 아님", HandoffCardSummary.files(GitSnapshot()), "Git 저장소가 아님 — 최근 수정 파일 없음")
        var noGit = GitSnapshot()
        noGit.error = "git 실행 파일을 찾지 못했습니다."
        noGit.recentlyModified = ["a.swift"]
        await t.equal("git 을 돌리지 못했으면 저장소가 아니라고 단정하지 않는다", HandoffCardSummary.files(noGit),
                      "Git 상태를 읽지 못함 — git 실행 파일을 찾지 못했습니다")
    }

    /// 자동 작업에 준 요청 · 답(`ThreadEvent.orchestrationRequestKey`)은 그 작업이 맡았다 — 인계 초안이 "아직 처리되지 않은
    /// 사용자 지시" · 마지막 지시로 넘기지 않는다. 표시 없는 사람의 지시는 그대로 넘긴다.
    static func orchestrationRequests(_ t: TestKit) async {
        await t.group("인계 패킷: 자동 작업 요청은 다음 행동에서 뺀다")
        let project = Project(name: "p", path: "/tmp/p")
        let thread = ConversationThread(projectID: project.id, title: "대화")
        let marked = JSONUtil.line([ThreadEvent.orchestrationRequestKey: true])
        func user(_ seq: Int64, _ text: String, orchestration: Bool) -> ThreadEvent {
            ThreadEvent(threadID: thread.id, seq: seq, kind: .userMessage, title: "사용자", text: text,
                        payloadJSON: orchestration ? marked : nil)
        }
        func build(_ events: [ThreadEvent]) -> [String] {
            HandoffPacketBuilder.build(HandoffPacketBuilder.Input(
                thread: thread, project: project, fromProvider: .claude, toProvider: .codex,
                events: events, runs: [], lastConfirmedPacket: nil, git: GitSnapshot(), baseSeq: 0)).nextActions
        }
        await t.check("표시는 사용자 메시지에만 · 다른 키로는 판정하지 않는다",
                      user(1, "x", orchestration: true).isOrchestrationRequest && !user(1, "x", orchestration: false).isOrchestrationRequest)
        let afterAgent = build([user(1, "첫 일", orchestration: false),
                                ThreadEvent(threadID: thread.id, seq: 2, kind: .agentMessage, provider: .claude, text: "했습니다."),
                                user(3, "나눠서 리팩터해 줘", orchestration: true),
                                user(4, "README 도 고쳐 줘", orchestration: false)])
        await t.check("에이전트 응답 뒤: 표시된 요청은 빼고 표시 없는 지시만",
                      afterAgent.contains("아직 처리되지 않은 사용자 지시: README 도 고쳐 줘")
                        && !afterAgent.contains { $0.contains("나눠서 리팩터해 줘") }, "\(afterAgent)")
        let noAgent = build([user(1, "README 도 고쳐 줘", orchestration: false), user(2, "나눠서 리팩터해 줘", orchestration: true)])
        await t.check("에이전트 응답이 없을 때: 마지막 지시는 표시 없는 것",
                      noAgent.contains("사용자 지시: README 도 고쳐 줘") && !noAgent.contains { $0.contains("나눠서") }, "\(noAgent)")
    }

    // MARK: 흐름

    /// 카운트다운 중 사람이 [지금 넘기기] 를 (두 번) 누른다 — 동기 점유(`beginSend`)가 하나만 받고, 타이머는 꺼져 다시 보내지 않는다.
    /// 지금 넘기기는 사람 검토가 아니다 (기록 "자동 인계 · 사람 검토 없음"). 타이머가 먼저인 경우는 `countdownTimerFirst`.
    static func countdownHumanFirst(_ t: TestKit) async throws {
        let env = try await makeEnv("race")
        defer { env.cleanup() }
        let id = env.threads[0].id
        await env.model.prepareHandoff(to: .codex, threadID: id)
        guard let card = env.model.handoffCards[id] else {
            await t.check("카드를 만든다", false, env.model.banner?.text ?? "")
            return
        }
        let rowBefore = await env.row(id, card.id)
        await t.check("수동 카드: 준비 단계 · 받는 쪽 Codex · 행은 아직 없다 (넘길 때 넣는다)",
                      card.phase == .ready && card.targetProvider == .codex && !card.automatic && rowBefore == nil)
        await t.check("카드가 있는 동안 대기열 보류 · 입력창은 받는 쪽", env.model.queueHolds[id]?.target.provider == .codex
                        && env.current(id)?.preferredProvider == .claude)
        env.model.automaticHandoffDelay = 2
        env.model.startAutomaticHandoffCountdown(threadID: id)
        await t.check("카운트다운", env.model.handoffCards[id]?.isCountingDown == true)
        async let first = env.model.sendHandoffNow(threadID: id)
        async let second = env.model.sendHandoffNow(threadID: id)
        let results = await [first, second]
        await t.equal("사람의 넘기기 둘 중 정확히 하나가 점유했다", results.filter { $0 }.count, 1)
        await env.settle { env.model.deliveringHandoffs[id] == nil && env.model.handoffCards[id] == nil
                            && !env.model.runner.isBusy(threadID: id) }
        try await Task.sleep(nanoseconds: 2_300_000_000)   // 카운트다운의 마감이 지나도
        await t.equal("인계 전송 기록은 하나", await env.sentCount(id), 1)
        await t.equal("받는 쪽 실행은 하나", env.behavior.requests.count, 1)
        let row = await env.row(id, card.id)
        await t.check("전달 확인 · 자동 인계 표시 (지금 넘기기는 사람 검토가 아니다)",
                      row?.deliveryState == .delivered && row?.note?.hasPrefix("자동 인계 · 사람 검토 없음") == true, row?.note ?? "")
        await t.check("전달이 확인되면 칩이 받는 쪽으로 · 보류가 풀린다",
                      env.current(id)?.preferredProvider == .codex && env.model.queueHolds[id] == nil)
    }

    /// 받는 에이전트(제공자)가 바뀌는 인계는 자동 승인을 끄고 대화에 안내를 남긴다 — 다른 회사 에이전트가 모든 승인을 받은 채
    /// (자동 인계면 사람도 없이) 돌지 않게.
    static func autoApprovalOffOnProviderChange(_ t: TestKit) async throws {
        let env = try await makeEnv("autoapproval")
        defer { env.cleanup() }
        let id = env.threads[0].id
        await env.model.setAutoApproval(true, threadID: id)
        await env.model.prepareHandoff(to: .codex, threadID: id)
        guard env.model.handoffCards[id] != nil else {
            await t.check("카드를 만든다", false, env.model.banner?.text ?? "")
            return
        }
        env.model.handoffCards[id]?.confirmed = true
        let sent = await env.model.sendHandoff(threadID: id)
        await env.settle { env.model.deliveringHandoffs[id] == nil && env.model.handoffCards[id] == nil
                            && !env.model.runner.isBusy(threadID: id) }
        let notices = ((try? await env.store.events(threadID: id)) ?? [])
            .filter { $0.kind == .systemNotice && $0.title == "자동 승인을 껐습니다" }
        await t.check("Claude → Codex 로 넘기면 자동 승인이 꺼지고 대화에 안내가 한 번 남는다",
                      sent && !env.model.isAutoApproving(threadID: id) && notices.count == 1,
                      "sent=\(sent) auto=\(env.model.isAutoApproving(threadID: id)) notices=\(notices.count)")
    }

    /// 타이머가 먼저 울려 보내는 중이면 [지금 넘기기] 는 점유하지 못한다 — 한 번만 간다.
    static func countdownTimerFirst(_ t: TestKit) async throws {
        let env = try await makeEnv("race-timer")
        defer { env.cleanup() }
        let id = env.threads[0].id
        await env.model.prepareHandoff(to: .codex, threadID: id)
        guard let card = env.model.handoffCards[id] else { return await t.check("카드", false, env.model.banner?.text ?? "") }
        env.model.automaticHandoffDelay = 1
        env.model.startAutomaticHandoffCountdown(threadID: id)
        await env.settle(5) { env.model.handoffCards[id]?.isCountingDown != true }
        let late = await env.model.sendHandoffNow(threadID: id)
        await t.check("타이머가 점유한 뒤의 지금 넘기기는 거절", !late)
        await env.settle { env.model.deliveringHandoffs[id] == nil && env.model.handoffCards[id] == nil
                            && !env.model.runner.isBusy(threadID: id) }
        await t.equal("인계 전송 기록은 하나", await env.sentCount(id), 1)
        await t.equal("받는 쪽 실행은 하나", env.behavior.requests.count, 1)
        let row = await env.row(id, card.id)
        await t.check("타이머가 보낸 행: 전달 확인 · 자동 인계 표시",
                      row?.deliveryState == .delivered && row?.note?.hasPrefix("자동 인계 · 사람 검토 없음") == true, row?.note ?? "")
    }

    /// 자동 인계가 한도 · 로그인 조회를 기다리는 사이 사람이 카드를 열었다 — 자동 준비가 그 카드(받는 쪽 · 덧붙인 말 · 체크)를
    /// 바꾸거나 카운트다운을 걸지 않는다. 전달 중이어도 새 카드를 놓지 않는다. (`startAutomaticHandoff` 는 실제 한도 CLI 를 부르므로
    /// 그 끝의 `prepareCard(automatic: true)` 를 바로 부른다.)
    static func automaticDoesNotOverwrite(_ t: TestKit) async throws {
        let env = try await makeEnv("auto-overwrite")
        defer { env.cleanup() }
        let id = env.threads[0].id
        await env.model.prepareHandoff(to: .codex, threadID: id)
        guard let manual = env.model.handoffCards[id] else { return await t.check("수동 카드", false, env.model.banner?.text ?? "") }
        env.model.setHandoffMemo("결제 모듈은 건드리지 말아", threadID: id)
        env.model.setHandoffConfirmed(true, threadID: id)
        let placed = await env.model.prepareCard(threadID: id, target: .codex, toAccountID: nil,
                                                 origin: .limitReached(scope: .claude, resetsAt: nil), automatic: true,
                                                 source: HandoffSource.Agent(provider: .claude, codexAccountID: nil))
        let after = env.model.handoffCards[id]
        await t.check("자동 준비는 놓지 않는다 — 사람이 연 카드 · 덧붙인 말 · 체크가 그대로, 카운트다운 없음",
                      !placed && after?.id == manual.id && after?.userMemo == "결제 모듈은 건드리지 말아" && after?.confirmed == true
                        && after?.isCountingDown == false && after?.automatic == false
                        && env.model.automaticHandoffTasks[id] == nil && env.model.handoffPreparations[id] == nil,
                      "\(String(describing: after?.phase))")
        await t.check("보류는 그대로", env.model.queueHolds[id] != nil)
        let manualAgain = await env.model.prepareCard(threadID: id, target: .gemini, toAccountID: nil, origin: .manual, automatic: false)
        await t.check("바꾸기가 아닌 수동 준비도 있는 카드를 갈아 끼우지 않는다", !manualAgain && env.model.handoffCards[id]?.id == manual.id)

        // 전달 중: 카드는 사라지고 `deliveringHandoffs` 만 있다 — 자동 준비가 새 카드를 놓지 않는다.
        env.model.handoffCards[id] = nil
        env.model.deliveringHandoffs[id] = DeliveringHandoff(handoffID: manual.id, source: manual.draft.source,
                                                             target: manual.draft.target, card: manual, filledModel: nil, runID: nil)
        let duringDelivery = await env.model.prepareCard(threadID: id, target: .codex, toAccountID: nil,
                                                         origin: .limitReached(scope: .claude, resetsAt: nil), automatic: true)
        await t.check("전달 중이면 자동 준비가 카드를 놓지 않는다", !duringDelivery && env.model.handoffCards[id] == nil
                        && env.model.handoffPreparations[id] == nil)
        env.model.deliveringHandoffs[id] = nil
    }

    /// 자동 인계가 한도 · 로그인 조회(실제 CLI — 몇 초)를 기다리는 사이 사람이 카드를 열어 취소했거나 넘겼으면, 조회 뒤 자동 카드 ·
    /// 카운트다운을 다시 세우지 않는다. 조회는 `claudeLoginCheck` 갈고리 안에서 사람의 동작을 흉내 낸다.
    static func automaticYieldsToHuman(_ t: TestKit) async throws {
        // 한도에 걸린 실행: Codex (계정 목록이 비어 대상은 Claude 뿐 — 조회 중 Claude 로그인 확인을 부른다).
        func limitedRun(_ id: String) -> Run {
            Run(threadID: id, sessionID: "s", provider: .codex, requestText: "일", state: .rateLimited,
                startedAt: Date(), endedAt: Date(), terminalReason: "rate_limited")
        }
        // (a) 조회 사이 사람이 카드를 열었다가 취소했다 → 취소가 이긴다.
        let env = try await makeEnv("auto-yield-cancel")
        defer { env.cleanup() }
        let id = env.threads[0].id
        env.model.messageQueues[id] = [QueuedMessage(text: "한도 뒤 일", images: [])]   // 한도로 멈춘 대기열 (보내지 않게 이유를 둔다)
        env.model.queuePauseReasons[id] = "실행이 '한도 도달'(으)로 끝나 보내지 않았습니다"
        var acted = false
        env.model.claudeLoginCheck = { @MainActor in
            if !acted {
                acted = true
                await env.model.prepareHandoff(to: .codex, threadID: id)
                env.model.cancelHandoff(threadID: id, origin: .card)
            }
            return true
        }
        await env.model.startAutomaticHandoff(after: limitedRun(id))
        await t.check("사람의 취소 뒤 자동 카드를 다시 세우지 않는다 · 멈춤 이유 그대로",
                      acted && env.model.handoffCards[id] == nil && env.model.automaticHandoffTasks[id] == nil
                        && env.model.queueHolds[id] == nil
                        && env.model.queuePauseReasons[id] == "인계를 취소했습니다 — 이어서 보내면 Claude 에게 갑니다",
                      "\(String(describing: env.model.handoffCards[id]?.phase)) \(env.model.queuePauseReasons[id] ?? "-")")

        // (b) 조회 사이 사람이 카드를 넘겨 전달됐다 → 같은 실행을 근거로 두 번째 인계를 보내지 않는다.
        let sent = try await makeEnv("auto-yield-sent")
        defer { sent.cleanup() }
        let sid = sent.threads[0].id
        var delivered = false
        sent.model.claudeLoginCheck = { @MainActor in
            if !delivered {
                delivered = true
                await sent.model.prepareHandoff(to: .codex, threadID: sid)
                sent.model.setHandoffConfirmed(true, threadID: sid)
                _ = await sent.model.sendHandoff(threadID: sid)
                await sent.settle { sent.model.deliveringHandoffs[sid] == nil && !sent.model.runner.isBusy(threadID: sid) }
            }
            return true
        }
        await sent.model.startAutomaticHandoff(after: limitedRun(sid))
        await t.check("사람이 넘긴 뒤 자동 인계를 또 준비하지 않는다", delivered && sent.model.handoffCards[sid] == nil
                        && sent.model.automaticHandoffTasks[sid] == nil)
        await t.equal("인계 전송은 한 번", await sent.sentCount(sid), 1)
    }

    /// 자동 인계 준비 중(카드가 놓이기 전)에 입력창에 메시지를 걸면, 놓이는 카드는 카운트다운이 아니라 사람이 멈춘 카드다.
    static func automaticTouchedDuringPreparation(_ t: TestKit) async throws {
        let env = try await makeEnv("auto-touched")
        defer { env.cleanup() }
        let id = env.threads[0].id
        var touched = false
        var marked = false
        // 받는 쪽 Claude 의 게이트가 로그인을 확인하는 사이 (준비 중) 사람이 메시지를 건다.
        env.model.claudeLoginCheck = { @MainActor in
            if env.model.handoffPreparations[id] != nil, !touched {
                touched = true
                env.model.enqueueMessage("테스트도 돌려 줘", images: [], threadID: id)
                marked = env.model.handoffTouchedDuringPreparation.contains(id)
            }
            return true
        }
        env.model.automaticHandoffDelay = 30
        let placed = await env.model.prepareCard(threadID: id, target: .claude, toAccountID: nil,
                                                 origin: .limitReached(scope: .codex(CodexAccount.defaultID), resetsAt: nil),
                                                 automatic: true, source: HandoffSource.Agent(provider: .codex, codexAccountID: nil))
        let card = env.model.handoffCards[id]
        // 시험 환경에는 받는 CLI 가 없어 게이트도 막는다 (검토 카드) — 어느 쪽이든 카운트다운 없이 사람 확인 길이다.
        await t.check("준비 중 사람이 건 메시지는 표시로 남고, 놓인 카드는 카운트다운 없이 확인 길 · 타이머 없음 · 표시는 지운다",
                      placed && touched && marked && card?.isCountingDown == false && card?.review != nil
                        && env.model.automaticHandoffTasks[id] == nil && env.model.queuedMessages(threadID: id).count == 1
                        && !env.model.handoffTouchedDuringPreparation.contains(id),
                      "\(String(describing: card?.phase)) \(String(describing: card?.review))")
        // 손대지 않은 다음 준비는 다시 카운트다운으로 (표시는 준비마다 새로).
        env.model.cancelHandoff(threadID: id, origin: .card)
        env.model.queuePauseReasons[id] = nil
        env.model.messageQueues[id] = nil
        _ = await env.model.prepareCard(threadID: id, target: .claude, toAccountID: nil,
                                        origin: .limitReached(scope: .codex(CodexAccount.defaultID), resetsAt: nil),
                                        automatic: true, source: HandoffSource.Agent(provider: .codex, codexAccountID: nil))
        let next = env.model.handoffCards[id]
        await t.check("손대지 않은 자동 준비는 사람이 멈춘 카드가 아니다 (카운트다운 또는 게이트의 검토)",
                      next != nil && next?.review != .pausedByHuman,
                      "\(String(describing: next?.phase)) \(String(describing: next?.review))")
        env.model.cancelHandoff(threadID: id, origin: .card)

    }

    /// 카운트다운이 울린 순간 git · 작업 폴더 명령이 돌고 있었다 — 보낸 것이 없으니 실패 카드가 아니라 넘길 수 있는 검토 카드이고,
    /// 까닭은 지난 일로 남는다 (막힘이 풀린 뒤에도 "…하는 중입니다" 가 남지 않게).
    static func automaticSendBlocked(_ t: TestKit) async throws {
        let env = try await makeEnv("auto-blocked")
        defer { env.cleanup() }
        let id = env.threads[0].id
        await env.model.prepareHandoff(to: .codex, threadID: id)
        guard env.model.handoffCards[id] != nil else { return await t.check("카드", false, env.model.banner?.text ?? "") }
        env.model.automaticHandoffDelay = 30
        env.model.startAutomaticHandoffCountdown(threadID: id)
        env.model.worktreeOperation = WorktreeOperation(threadID: "다른 대화", kind: .merge, paths: [env.project.path])
        let sent = await env.model.sendHandoffNow(threadID: id)
        let card = env.model.handoffCards[id]
        let skip = HandoffSendBlock.worktreeOperation(WorktreeOperation.Kind.merge.koreanName).automaticSkipReason
        await t.check("막힌 자동 전송 → 넘길 수 있는 검토 카드 (실패 아님) · 까닭은 지난 일 · 보낸 것 없음",
                      sent && card?.phase == .ready && card?.lastError == nil && card?.review == .automaticBlocked([skip])
                        && env.behavior.requests.isEmpty && env.model.deliveringHandoffs[id] == nil,
                      "\(String(describing: card?.phase)) \(String(describing: card?.review))")
        env.model.worktreeOperation = nil
        env.model.setHandoffConfirmed(true, threadID: id)
        _ = await env.model.sendHandoff(threadID: id)
        await env.settle { env.model.deliveringHandoffs[id] == nil && env.model.handoffCards[id] == nil
                            && !env.model.runner.isBusy(threadID: id) }
        await t.equal("막힘이 풀린 뒤 사람이 넘기면 한 번 간다", await env.sentCount(id), 1)
    }

    /// ⌘Q 의 확인창보다 먼저 카운트다운을 멈추고 새 전달을 막는다 — 확인창이 떠 있는 동안 타이머가 전달 CLI 를 띄우지 않는다.
    /// 종료를 취소하면 다시 보낼 수 있다 (멈춘 카드는 확인 길로).
    static func quitSuspension(_ t: TestKit) async throws {
        let env = try await makeEnv("quit")
        defer { env.cleanup() }
        let id = env.threads[0].id
        await env.model.prepareHandoff(to: .codex, threadID: id)
        guard env.model.handoffCards[id] != nil else { return await t.check("카드", false, env.model.banner?.text ?? "") }
        env.model.automaticHandoffDelay = 1
        env.model.startAutomaticHandoffCountdown(threadID: id)
        env.model.suspendHandoffsForQuit()
        await t.check("종료를 물으면 카운트다운이 멈춘다 (사람이 멈춘 카드 · 타이머 없음)",
                      env.model.handoffCards[id]?.isCountingDown == false && env.model.handoffCards[id]?.review == .pausedByHuman
                        && env.model.automaticHandoffTasks.isEmpty)
        try await Task.sleep(nanoseconds: 1_400_000_000)   // 마감이 지나도
        await t.check("확인창이 떠 있는 동안 전달하지 않는다", env.behavior.requests.isEmpty && env.model.deliveringHandoffs[id] == nil)
        await t.equal("인계 전송 기록 없음", await env.sentCount(id), 0)
        env.model.setHandoffConfirmed(true, threadID: id)
        let sent = await env.model.sendHandoff(threadID: id)
        await t.check("종료를 묻는 동안 사람의 넘기기도 점유하지 않는다", !sent && env.model.handoffCards[id]?.isSending == false
                        && env.behavior.requests.isEmpty)
        env.model.startAutomaticHandoffCountdown(threadID: id)
        await t.check("그 사이 놓인 자동 카드는 타이머 없이 확인 길로", env.model.handoffCards[id]?.isCountingDown == false
                        && env.model.automaticHandoffTasks[id] == nil)
        await t.check("거둘 실행 없음 — 카드만 있으면 그냥 끝낸다", !env.model.hasRunsToShutDownForQuit)
        env.model.resumeHandoffsAfterCancelledQuit()
        let resumed = await env.model.sendHandoff(threadID: id)
        await env.settle { env.model.deliveringHandoffs[id] == nil && env.model.handoffCards[id] == nil
                            && !env.model.runner.isBusy(threadID: id) }
        await t.check("종료를 취소하면 다시 넘길 수 있다", resumed && env.behavior.requests.count == 1)
    }

    /// 받는 쪽이 답을 시작한 뒤 ⌘Q → "중단하고 종료" 가 이어지면 (`shutDownAndTerminate`) 전달됨으로 판정된 인계의 칩을 받는 쪽으로
    /// 옮기고 보류를 푼다 — 다시 켜면 다음 메시지가 받는 쪽에게 가고, 걸어 둔 메시지는 "카드가 사라졌다" 가 아니라 "다시 켜서 멈춤".
    static func quitAfterDelivered(_ t: TestKit) async throws {
        let env = try await makeEnv("quitdelivered")
        defer { env.cleanup() }
        let id = env.threads[0].id
        await env.model.prepareHandoff(to: .codex, threadID: id)
        guard let card = env.model.handoffCards[id] else { return await t.check("카드", false, env.model.banner?.text ?? "") }
        env.model.enqueueMessage("인계 뒤 첫 일", images: [], threadID: id)
        env.behavior.mode = .replyThenWait
        env.model.setHandoffConfirmed(true, threadID: id)
        _ = await env.model.sendHandoff(threadID: id)
        for _ in 0..<500 {
            let events = (try? await env.store.events(threadID: id)) ?? []
            if events.contains(where: { $0.kind == .agentMessage && $0.text.contains("일하는 중") }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await t.check("받는 쪽이 답을 시작했고 실행은 돈다 · 칩은 아직 Claude",
                      env.model.runner.isBusy(threadID: id) && env.current(id)?.preferredProvider == .claude)
        env.model.suspendHandoffsForQuit()
        _ = await env.model.runner.shutdownForQuit()
        await env.model.recordQuitDeliveriesBeforeExit()
        let row = await env.row(id, card.id)
        await t.check("종료로 끊긴 전달 → 전달됨 · 칩이 받는 쪽(Codex) · 보류 풀림 · 대기열은 남음",
                      row?.deliveryState == .delivered && env.current(id)?.preferredProvider == .codex
                        && env.model.queueHolds[id] == nil && env.model.queuedMessages(threadID: id).count == 1,
                      "\(String(describing: row?.deliveryState)) \(String(describing: env.current(id)?.preferredProvider))")
        await t.check("걸어 둔 메시지를 보내지 않았다", env.behavior.requests.count == 1)
        let relaunched = AppModel(store: env.store)
        await relaunched.reloadProjects()
        await relaunched.restoreMessageQueues()
        await t.check("다시 켬 → 칩은 Codex", relaunched.allThreads().first { $0.id == id }?.preferredProvider == .codex)
        await t.equal("다시 켬 → 대기열은 '다시 켜서 멈춤' (카드가 사라졌다고 적지 않는다)", relaunched.queuePauseReasons[id],
                      "앱을 다시 켜서 멈췄습니다")
    }

    /// 카드가 사라진 뒤(전달 실행이 도는 중 · 넘긴 뒤) 누른 알림의 [자동 인계 취소] 는 말없이 버리지 않는다.
    /// 전달하는 사이 받는 Codex 계정을 지우면 칩을 지운 계정으로 옮기지 않고, 걸어 둔 메시지를 멈춤 이유와 함께 둔다.
    static func lateCancelAndRemovedReceiver(_ t: TestKit) async throws {
        let env = try await makeEnv("late-cancel")
        defer { env.cleanup() }
        let id = env.threads[0].id
        await env.model.prepareHandoff(to: .codex, threadID: id)
        env.model.setHandoffConfirmed(true, threadID: id)
        env.behavior.mode = .waitThenReply
        let sending = Task { await env.model.sendHandoff(threadID: id) }
        await env.settle { env.model.deliveringHandoffs[id] != nil && env.model.handoffCards[id] == nil && !env.behavior.adapters.isEmpty }
        await t.equal("전달 실행이 도는 중의 알림 취소 → '이미 보내는 중'", env.model.lateNotificationCancel(threadID: id), .sending)
        await t.check("알림 취소는 받지 않는다", !env.model.cancelHandoff(threadID: id, origin: .notification))
        env.behavior.adapters.last?.signal("go")
        _ = await sending.value
        await env.settle { env.model.deliveringHandoffs[id] == nil && !env.model.runner.isBusy(threadID: id) }
        await t.equal("넘긴 뒤의 알림 취소 → '이미 넘겼습니다'", env.model.lateNotificationCancel(threadID: id), .delivered)
        // 칸에 열려 있지 않은 대화 — 메모리의 인계 기록이 없어도 저장소로 판정한다 (대화 상자를 읽지 않은 모델로).
        let unopened = AppModel(store: env.store)
        await t.equal("칸에 없는 대화: 메모리로는 모른다", unopened.lateNotificationCancel(threadID: id), nil)
        await t.equal("칸에 없는 대화: 저장소의 마지막 인계로 '이미 넘겼습니다'",
                      await unopened.lateNotificationCancelFromStore(threadID: id), .delivered)

        // 전달 중 받는 계정 해제.
        let removed = try await makeEnv("receiver-removed")
        defer { removed.cleanup() }
        let rid = removed.threads[0].id
        let home = removed.root.appendingPathComponent("codex-b").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        // 로그인된 계정 (로그인 안 됨이 확인된 받는 쪽은 넘기기를 막는다 — `receiverUnavailable`).
        try #"{"tokens":{"access_token":"x"}}"#.write(to: URL(fileURLWithPath: home).appendingPathComponent("auth.json"),
                                                      atomically: true, encoding: .utf8)
        try await removed.store.upsertCodexAccount(CodexAccount(id: "acct-b", label: "둘째", homePath: home, sortOrder: 1))
        await removed.model.accounts.load()
        await removed.model.prepareHandoff(to: .codex, toAccountID: "acct-b", threadID: rid)
        guard removed.model.handoffCards[rid]?.draft.handoff.toAccountID == "acct-b" else {
            return await t.check("둘째 계정에게 가는 카드", false, removed.model.banner?.text ?? "")
        }
        removed.model.enqueueMessage("인계 뒤 일", images: [], threadID: rid)
        removed.model.setHandoffConfirmed(true, threadID: rid)
        removed.behavior.mode = .waitThenReply
        let delivering = Task { await removed.model.sendHandoff(threadID: rid) }
        await removed.settle { removed.model.deliveringHandoffs[rid] != nil && !removed.behavior.adapters.isEmpty }
        await removed.model.removeCodexAccount("acct-b")
        removed.behavior.adapters.last?.signal("go")
        _ = await delivering.value
        await removed.settle { removed.model.deliveringHandoffs[rid] == nil && !removed.model.runner.isBusy(threadID: rid) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let thread = removed.current(rid)
        await t.check("칩을 지운 계정으로 옮기지 않는다 · 걸어 둔 메시지는 보내지 않는다",
                      thread?.preferredProvider == .claude && removed.behavior.requests.count == 1
                        && removed.model.queuedMessages(threadID: rid).count == 1,
                      "칩 \(String(describing: thread?.preferredProvider)) · 요청 \(removed.behavior.requests.map(\.prompt))")
        await t.equal("보류는 멈춤 이유로 (계정 이름 · 받을 칩 — 칩은 보내는 쪽 그대로라 맥락이 있다)", removed.model.queuePauseReasons[rid],
                      "받는 Codex 계정(둘째)의 등록이 해제됐습니다 — 이어서 보내면 Claude 에게 갑니다")
        await t.check("보류가 풀렸다", removed.model.queueHolds[rid] == nil)
    }

    /// 이미 전달된 행의 카드는 다시 못 보낸다 (DB 점유) · 보내는 중에는 취소를 받지 않는다.
    static func deliveredAndSending(_ t: TestKit) async throws {
        let env = try await makeEnv("delivered")
        defer { env.cleanup() }
        let id = env.threads[0].id
        await env.model.prepareHandoff(to: .codex, threadID: id)
        guard var card = env.model.handoffCards[id] else { return await t.check("카드", false, env.model.banner?.text ?? "") }
        env.model.setHandoffConfirmed(true, threadID: id)
        let sent = await env.model.sendHandoff(threadID: id)
        await env.settle { env.model.deliveringHandoffs[id] == nil && !env.model.runner.isBusy(threadID: id) }
        let deliveredRow = await env.row(id, card.id)
        await t.check("사람이 넘긴 카드는 전달 · 사람 검토함", sent && deliveredRow?.deliveryState == .delivered
                        && deliveredRow?.note?.hasPrefix("사람 검토함") == true, deliveredRow?.note ?? "")
        // 옛 사본(같은 행)을 카드로 되살려 다시 넘긴다 — 지문은 지운다 (지문은 전달 실행으로 이미 달라졌다).
        card.phase = .ready
        card.confirmed = true
        card.fingerprint = nil
        env.model.handoffCards[id] = card
        _ = await env.model.sendHandoff(threadID: id)
        await env.settle { env.model.handoffCards[id]?.isFailed == true }
        await t.check("이미 전달된 행은 DB 점유에서 거절 — 실패 카드로 (다시 보내지 않음)",
                      env.model.handoffCards[id]?.isFailed == true && env.behavior.requests.count == 1,
                      env.model.handoffCards[id]?.lastError ?? "")
        await t.equal("인계 전송 기록은 그대로 하나", await env.sentCount(id), 1)
        env.model.handoffCards[id] = nil

        // 보내는 중: 동기 점유 뒤에는 취소를 받지 않는다 (카드 · 알림 둘 다).
        let other = try await makeEnv("sending")
        defer { other.cleanup() }
        let oid = other.threads[0].id
        await other.model.prepareHandoff(to: .codex, threadID: oid)
        guard let fresh = other.model.handoffCards[oid] else { return await t.check("둘째 카드", false) }
        await t.check("점유", other.model.beginSend(threadID: oid, draftID: fresh.id))
        await t.check("두 번째 점유는 거절", !other.model.beginSend(threadID: oid, draftID: fresh.id))
        await t.check("보내는 중 카드의 취소는 거절 · 이유를 카드에",
                      !other.model.cancelHandoff(threadID: oid, origin: .card) && other.model.handoffCards[oid]?.isSending == true
                        && other.model.handoffCards[oid]?.lastError == "이미 보내는 중입니다")
        await t.check("알림의 취소도 거절", !other.model.cancelHandoff(threadID: oid, origin: .notification)
                        && other.model.handoffCards[oid]?.isSending == true)
    }

    /// 카운트다운은 사람이 손대면 멈춘다 (덧붙일 말 칸의 포커스 · 문서 고치기 · 체크 · 대기열). 멈춘 카드는 확인 길로 보내고,
    /// 고친 글과 덧붙인 말이 간다 — 덧붙인 말은 앞머리 뒤, "다음 행동" 앞.
    static func pauseEditMemo(_ t: TestKit) async throws {
        let env = try await makeEnv("pause")
        defer { env.cleanup() }
        let id = env.threads[0].id
        await env.model.prepareHandoff(to: .codex, threadID: id)
        guard env.model.handoffCards[id] != nil else { return await t.check("카드", false, env.model.banner?.text ?? "") }
        env.model.automaticHandoffDelay = 30
        env.model.startAutomaticHandoffCountdown(threadID: id)
        env.model.setHandoffCardFocus(threadID: id, focused: true, pausesCountdown: true)
        await t.check("덧붙일 말 칸에 포커스가 들어오면 멈춘다 (사람이 멈춤 · 답을 기다리는 카드가 아님)",
                      env.model.handoffCards[id]?.phase == .ready && env.model.handoffCards[id]?.review == .pausedByHuman
                        && env.model.handoffCardFocusThreadID == id && env.model.handoffCards[id]?.attention == .draft)
        env.model.setHandoffCardFocus(threadID: id, focused: false)
        env.model.startAutomaticHandoffCountdown(threadID: id)
        let edited = (env.model.handoffCards[id]?.draft.editedText ?? "") + "\n고친 줄: 받는 쪽은 README 를 먼저 읽으세요.\n"
        env.model.setHandoffEditedText(edited, threadID: id)
        await t.check("카운트다운 중 문서를 고치면 멈춘다", env.model.handoffCards[id]?.review == .pausedByHuman
                        && env.model.handoffCards[id]?.isCountingDown == false && env.model.handoffCards[id]?.draft.isEdited == true)
        env.model.startAutomaticHandoffCountdown(threadID: id)
        env.model.enqueueMessage("인계 뒤에 할 일", images: [], threadID: id)
        await t.check("입력창에서 대기열에 걸면 멈춘다 · 보내지 않는다",
                      env.model.handoffCards[id]?.isCountingDown == false && env.behavior.requests.isEmpty
                        && env.model.queuedMessages(threadID: id).count == 1)
        env.model.setHandoffMemo("결제 모듈은 건드리지 말아 주세요.", threadID: id)
        let blocked = await env.model.sendHandoff(threadID: id)
        await t.check("체크 전에는 넘기지 않는다", !blocked && env.behavior.requests.isEmpty)
        env.model.setHandoffConfirmed(true, threadID: id)
        _ = await env.model.sendHandoff(threadID: id)
        await env.settle { env.model.deliveringHandoffs[id] == nil && env.model.handoffCards[id] == nil
                            && !env.model.runner.isBusy(threadID: id) }
        let prompt = env.behavior.requests.first?.prompt ?? ""
        await t.check("고친 글이 간다 · 사람 검토함", prompt.contains("고친 줄: 받는 쪽은 README 를 먼저 읽으세요.")
                        && prompt.contains("사람 검토함"))
        let preamble = prompt.range(of: "이 메시지는 Agent Handoff Console 앱이 보냈습니다")
        let memo = prompt.range(of: "## 사용자가 덧붙인 말 (사용자가 직접 씀)\n결제 모듈은 건드리지 말아 주세요.")
        let next = prompt.range(of: "## 다음 행동")
        await t.check("덧붙인 말: 앞머리 뒤 · 다음 행동 앞", preamble != nil && memo != nil && next != nil
                        && preamble!.lowerBound < memo!.lowerBound && memo!.lowerBound < next!.lowerBound)
        await env.settle { env.behavior.requests.count == 2 }
        await t.check("전달이 확인되면 걸어 둔 메시지가 받는 쪽(Codex)에게 간다",
                      env.behavior.requests.count == 2 && env.behavior.requests.last?.prompt == "인계 뒤에 할 일"
                        && env.behavior.adapters.last?.provider == .codex)
        // 걸어 둔 메시지의 실행이 끝난 뒤에 환경을 치운다 — 도는 실행을 두고 끝내면 그 통지가 사라진 관리자에게 갔다.
        await env.settle { !env.model.runner.isBusy(threadID: id) }
    }

    /// 지문은 변경 파일 목록만이 아니라 내용도 본다 — 예전에는 이미 M 인 파일을 다시 고치거나 같은 폴더의 다른 대화가 고쳐도 지문이
    /// 그대로라 문서의 diff 발췌가 낡은 채 넘어갔다.
    static func fingerprintContent(_ t: TestKit) async throws {
        let env = try await makeEnv("fingerprint", git: true)
        defer { env.cleanup() }
        let thread = env.threads[0]
        func measure() async -> HandoffCard.Fingerprint {
            await env.model.handoffFingerprint(thread: thread, project: env.project)
        }
        let readme = env.folder.appendingPathComponent("README.md")
        let clean = await measure()
        await t.check("저장소면 git 상태를 잰다", clean.gitState != nil)
        try "# 카드 시험\n첫 고침\n".write(to: readme, atomically: true, encoding: .utf8)
        let first = await measure()
        await t.check("파일을 고치면 바뀐다", first != clean)
        try "# 카드 시험\n두 번째 고침\n".write(to: readme, atomically: true, encoding: .utf8)
        let second = await measure()
        await t.check("이미 바뀐(M) 파일을 다시 고쳐도 바뀐다 (목록은 그대로)", second != first)
        let untracked = env.folder.appendingPathComponent("notes.txt")
        try "메모\n".write(to: untracked, atomically: true, encoding: .utf8)
        let added = await measure()
        await t.check("추적 안 하는 파일이 생기면 바뀐다", added != second)
        try "메모를 더 길게 고쳤다\n".write(to: untracked, atomically: true, encoding: .utf8)
        let edited = await measure()
        await t.check("추적 안 하는 파일을 다시 고쳐도 바뀐다 (목록은 그대로)", edited != added)
        let again = await measure()
        await t.equal("아무것도 바꾸지 않으면 그대로", again, edited)
    }

    /// 두 대화의 카드는 따로 돈다 · 지문이 바뀌면 보내지 않는다 · 받는 계정을 지우면 검토 · 인계하지 않는 대화.
    static func cardsAndBlocks(_ t: TestKit) async throws {
        // 기록 없는 대화의 인계 진입: 실패가 아니라 안내 — 오류 배너(빨간 선)로 올리지 않는다.
        let noHistory = try await makeEnv("nohistory", history: false)
        defer { noHistory.cleanup() }
        await noHistory.model.prepareHandoff(to: .codex, threadID: noHistory.threads[0].id)
        await t.check("기록 없는 대화: 카드 없음 · 안내 배너 (오류 아님) · 보류 없음",
                      noHistory.model.handoffCards.isEmpty && noHistory.model.banner?.isError == false
                        && noHistory.model.banner?.text.hasPrefix("기록이 없는 대화는 인계하지 않습니다") == true
                        && noHistory.model.queueHolds.isEmpty, noHistory.model.banner?.text ?? "-")

        let env = try await makeEnv("two", threads: ["가", "나"], git: true)
        defer { env.cleanup() }
        let (a, b) = (env.threads[0].id, env.threads[1].id)
        await env.model.prepareHandoff(to: .codex, threadID: a)
        await env.model.prepareHandoff(to: .codex, threadID: b)
        await t.check("두 대화가 함께 카드를 가진다", env.model.handoffCards[a] != nil && env.model.handoffCards[b] != nil)
        env.model.automaticHandoffDelay = 30
        env.model.startAutomaticHandoffCountdown(threadID: a)
        env.model.startAutomaticHandoffCountdown(threadID: b)
        env.model.cancelHandoff(threadID: a, origin: .card)
        await t.check("한 대화의 카드를 취소해도 다른 대화의 카운트다운은 남는다",
                      env.model.handoffCards[a] == nil && env.model.handoffCards[b]?.isCountingDown == true)
        env.model.pauseCountdown(threadID: b)

        // 지문: 초안 뒤에 파일이 바뀌면 보내지 않고 낡은 카드로.
        try "바뀐 줄\n".write(to: env.folder.appendingPathComponent("NEW.md"), atomically: true, encoding: .utf8)
        env.model.setHandoffConfirmed(true, threadID: b)
        _ = await env.model.sendHandoff(threadID: b)
        let staleSent = await env.sentCount(b)
        await t.check("초안 이후 폴더가 바뀌면 보내지 않는다 (낡음 · 다시 만들기)",
                      env.model.handoffCards[b]?.isStale == true && env.behavior.requests.isEmpty && staleSent == 0,
                      "\(String(describing: env.model.handoffCards[b]?.review))")
        await t.equal("낡은 카드의 막힘", env.model.handoffSendBlock(threadID: b), .stale)
        env.model.setHandoffMemo("결제 모듈은 건드리지 마세요.", threadID: b)
        let staleID = env.model.handoffCards[b]?.id
        await env.model.remakeHandoff(threadID: b)
        await t.check("다시 만들면 새 초안 (덧붙인 말은 옮겨 간다 · 확인은 다시)",
                      env.model.handoffCards[b]?.id != staleID && env.model.handoffCards[b]?.isStale == false
                        && env.model.handoffCards[b]?.confirmed == false
                        && env.model.handoffCards[b]?.userMemo == "결제 모듈은 건드리지 마세요.",
                      env.model.handoffCards[b]?.userMemo ?? "카드 없음")

        // 막는 대화: 내부 대화 · 끝나지 않은 자동 작업의 부모 · 기록 없는 대화.
        var inner = ConversationThread(projectID: env.project.id, title: "내부")
        inner.orchestrationJobID = "job-x"
        inner.orchestrationRole = "task"
        try await env.store.upsertThread(inner)
        let fresh = await env.model.addThread(projectID: env.project.id, title: "새 대화")
        var job = OrchestrationJob(projectID: env.project.id, parentThreadID: a, request: "나눠서 해 줘")
        job.state = .planning
        try await env.store.insertOrchestrationJob(job)
        await env.model.reloadProjects()
        await env.model.orchestration.load(parentThreadID: a)
        for (threadID, label) in [(inner.id, "내부 대화"), (a, "자동 작업 부모"), (fresh.id, "기록 없는 대화")] {
            env.model.banner = nil
            await env.model.prepareHandoff(to: .codex, threadID: threadID)
            await t.check("\(label)는 인계하지 않는다 (카드 · 보류 없음, 이유는 그 대화의 배너)",
                          env.model.handoffCards[threadID] == nil && env.model.queueHolds[threadID] == nil
                            && env.model.banner?.threadID == threadID, env.model.banner?.text ?? "배너 없음")
        }
        await t.check("진입점이 끄는 이유 — 자동 작업 부모", env.model.paneThread(a).flatMap(env.model.handoffEntryBlock) != nil)

        // 받는 계정을 지우면 검토 카드로 (기본 계정으로 떨어뜨리지 않는다).
        let accounts = try await makeEnv("account")
        defer { accounts.cleanup() }
        let cid = accounts.threads[0].id
        // 바꾸기 ▾: 기본 계정에게 가던 카드를 둘째 계정에게로 — 덧붙인 말이 옮겨 간다.
        await accounts.model.prepareHandoff(to: .codex, threadID: cid)
        accounts.model.setHandoffMemo("테스트부터 돌려 주세요.", threadID: cid)
        let home = accounts.root.appendingPathComponent("codex-b").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try await accounts.store.upsertCodexAccount(CodexAccount(id: "acct-b", label: "둘째", homePath: home, sortOrder: 1))
        await accounts.model.accounts.load()
        await accounts.model.replaceHandoffTarget(threadID: cid, to: .codex, toAccountID: "acct-b")
        await t.equal("바꾸기: 둘째 계정에게 가는 카드", accounts.model.handoffCards[cid]?.draft.handoff.toAccountID, "acct-b")
        await t.equal("바꾸기: 덧붙인 말은 옮겨 간다", accounts.model.handoffCards[cid]?.userMemo, "테스트부터 돌려 주세요.")
        await t.equal("자동 인계 제외 사유의 이름 = 카드의 받는 쪽 이름", accounts.model.automaticCandidateName(provider: .codex, accountID: "acct-b"),
                      accounts.model.handoffPartyName(HandoffSource.Agent(provider: .codex, codexAccountID: "acct-b")))
        await t.equal("계정이 하나면 제외 사유도 'Codex' (설정 목록의 'Codex · 기본 계정' 이 아니다)",
                      env.model.automaticCandidateName(provider: .codex, accountID: CodexAccount.defaultID), "Codex")
        await accounts.model.removeCodexAccount("acct-b")
        await t.check("받는 계정을 지우면 검토 카드 · 보낼 수 없다",
                      accounts.model.handoffCards[cid]?.review == .accountRemoved("둘째")
                        && accounts.model.handoffSendBlock(threadID: cid) == .receiverAccountMissing,
                      "\(String(describing: accounts.model.handoffCards[cid]?.review))")
    }

    /// 늦게 끝난 준비는 버린다 (취소한 뒤 끝난 Gemini 정리) · 재정리 중에는 보내지 않고, 끝나면 지금 카드 값에 합친다
    /// (덧붙인 말 · 체크는 남는다). 가짜 agy 가 문 파일을 기다려 순서를 되풀이할 수 있게 한다.
    static func geminiRace(_ t: TestKit) async throws {
        let env = try await makeEnv("gemini")
        defer { env.cleanup() }
        let id = env.threads[0].id
        let bin = env.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let agy = bin.appendingPathComponent("agy")
        let gate = bin.appendingPathComponent("go")
        let script = """
        #!/bin/sh
        dir="$(cd "$(dirname "$0")" && pwd)"
        case "$1" in
          --version) echo "1.2.2-stub"; exit 0 ;;
          models) echo "gemini-3.8-flash-high"; exit 0 ;;
        esac
        cat > /dev/null
        if [ -f "$dir/fail" ]; then echo "agy: 로그인이 필요합니다" >&2; exit 3; fi
        while [ ! -f "$dir/go" ]; do sleep 0.05; done
        echo '{"event":"result","result":{"status":"SUCCESS","structured_output":{"progress":[],"nextActions":[{"text":"워커 테스트를 붙인다","evidence":[3]}],"decisions":[],"failedAttempts":[],"cautions":[],"unverified":[]},"usage":{}}}'
        """
        try script.write(to: agy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agy.path)
        env.model.geminiPathOverride = agy.path
        await env.settle(5) { env.model.geminiCLIPath != nil }

        // 1) 늦게 끝난 준비: Gemini 정리를 기다리는 준비를 취소한 뒤 정리가 끝나도 카드를 놓지 않는다.
        env.model.geminiSummaryEnabled = true
        let preparing = Task { await env.model.prepareHandoff(to: .codex, threadID: id) }
        await env.settle(5) { env.model.handoffPreparations[id] != nil }
        env.model.banner = nil
        await env.model.prepareHandoff(to: .codex, threadID: id)
        await t.check("준비가 도는 대화에 또 부르면 조용히 돌아가지 않고 알린다",
                      env.model.banner?.text.contains("만드는 중") == true, env.model.banner?.text ?? "")
        await t.check("준비 중도 보류", env.model.queueHolds[id] != nil && env.model.handoffStage(threadID: id) == .preparing)
        await t.check("준비 중인 카드의 취소", env.model.cancelHandoff(threadID: id, origin: .card))
        FileManager.default.createFile(atPath: gate.path, contents: nil)
        await preparing.value
        await t.check("늦게 끝난 준비는 버린다 (카드 · 보류 없음)", env.model.handoffCards[id] == nil && env.model.queueHolds[id] == nil)
        try FileManager.default.removeItem(at: gate)

        // 2) 재정리와 보내기의 경합.
        env.model.geminiSummaryEnabled = false
        await env.model.prepareHandoff(to: .codex, threadID: id)
        guard env.model.handoffCards[id] != nil else { return await t.check("카드", false, env.model.banner?.text ?? "") }
        env.model.geminiSummaryEnabled = true
        env.model.setHandoffMemo("결제 모듈은 건드리지 말아 주세요.", threadID: id)
        env.model.setHandoffConfirmed(true, threadID: id)
        let summarizing = Task { await env.model.requestSummaryAssist(threadID: id) }
        await env.settle(5) { env.model.handoffCards[id]?.summarizing == true }
        let duringSend = await env.model.sendHandoff(threadID: id)
        await t.check("재정리 중에는 보내지 않는다", !duringSend && env.behavior.requests.isEmpty
                        && env.model.handoffSendBlock(threadID: id) == .summarizing)
        FileManager.default.createFile(atPath: gate.path, contents: nil)
        await summarizing.value
        let merged = env.model.handoffCards[id]
        await t.check("재정리가 끝나면 지금 카드 값에 합친다 — 정리본 · 덧붙인 말은 그대로, 문서가 바뀌었으니 확인은 다시",
                      merged?.summarizing == false && merged?.draft.packet.summarySource == "gemini"
                        && merged?.userMemo == "결제 모듈은 건드리지 말아 주세요." && merged?.confirmed == false,
                      "\(String(describing: merged?.draft.packet.summarySource))")

        // 2-2) 정리가 실패하면 문서를 바꾸지 않는다 — 사람이 고친 글이 그대로 남고 까닭은 카드의 오류 줄에 (hnd-5).
        let edited = (env.model.handoffCards[id]?.draft.editedText ?? "") + "\n사람이 고친 줄\n"
        env.model.setHandoffEditedText(edited, threadID: id)
        let failMarker = bin.appendingPathComponent("fail")
        FileManager.default.createFile(atPath: failMarker.path, contents: nil)
        await env.model.requestSummaryAssist(threadID: id)
        try? FileManager.default.removeItem(at: failMarker)
        await t.check("정리가 실패하면 고친 문서를 그대로 두고 까닭을 카드에",
                      env.model.handoffCards[id]?.draft.editedText == edited && env.model.handoffCards[id]?.summarizing == false
                        && env.model.handoffCards[id]?.lastError?.hasPrefix("Gemini 로 정리하지 못했습니다") == true,
                      env.model.handoffCards[id]?.lastError ?? "오류 없음")

        // 3) 다시 만드는 동안(Gemini 정리를 기다림) 덧붙일 말 칸에 더 쓴 글은 새 카드로 간다 — 누른 순간의 글로 되돌리지 않는다.
        // 기록을 하나 더해 정리 입력을 바꾼다 (같은 입력이면 저장해 둔 정리를 써서 기다리지 않는다).
        _ = try await env.store.appendEvent(ThreadEvent(threadID: id, kind: .userMessage, title: "사용자", text: "마이그레이션은 그대로."))
        try FileManager.default.removeItem(at: gate)
        let beforeRemake = env.model.handoffCards[id]?.id
        let remaking = Task { await env.model.remakeHandoff(threadID: id) }
        await env.settle(5) { env.model.handoffPreparations[id] != nil }
        env.model.setHandoffMemo("결제 모듈은 건드리지 말아 주세요. 마이그레이션도 그대로.", threadID: id)
        FileManager.default.createFile(atPath: gate.path, contents: nil)
        await remaking.value
        await t.check("다시 만드는 동안 쓴 덧붙일 말이 새 카드에 남는다",
                      env.model.handoffCards[id]?.id != beforeRemake
                        && env.model.handoffCards[id]?.userMemo == "결제 모듈은 건드리지 말아 주세요. 마이그레이션도 그대로.",
                      env.model.handoffCards[id]?.userMemo ?? "카드 없음")
        env.model.setHandoffConfirmed(true, threadID: id)
        _ = await env.model.sendHandoff(threadID: id)
        await env.settle { env.model.handoffCards[id] == nil && env.model.deliveringHandoffs[id] == nil }
        let prompt = env.behavior.requests.first?.prompt ?? ""
        await t.check("재정리 뒤에도 덧붙인 말이 간다", prompt.contains("## 사용자가 덧붙인 말 (사용자가 직접 씀)\n결제 모듈은 건드리지 말아 주세요."))
    }

    /// 받는 쪽의 모델은 받는 쪽 계정의 목록으로 — 카드 · 입력창 표시와 실제 전달이 같은 값.
    /// 카드의 "받는 모델" 칩(Claude · Codex 도 — 예전에는 Antigravity 에만 있었다): 고르면 이 대화의 그 에이전트 선택을 바꾸고
    /// 카운트다운을 멈춘다(사람이 판단하는 중), 전달 직전 `pinEffectiveSelection` 이 그 값을 그대로 쓴다.
    static func receiverModelPicked(_ t: TestKit) async throws {
        let env = try await makeEnv("pick")
        defer { env.cleanup() }
        let id = env.threads[0].id
        // 받는 Codex 계정은 로그인된 임시 계정 폴더 — 기본 계정은 이 Mac 의 ~/.codex 를 읽어, 로그인이 없는 곳(CI 러너)에서는
        // "받는 쪽 로그인 안 됨" 으로 넘기기가 막힌다.
        let home = env.root.appendingPathComponent("codex-pick").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try #"{"tokens":{"access_token":"x"}}"#.write(to: URL(fileURLWithPath: home).appendingPathComponent("auth.json"),
                                                      atomically: true, encoding: .utf8)
        try await env.store.upsertCodexAccount(CodexAccount(id: "acct-pick", label: "받는 계정", homePath: home, sortOrder: 1))
        func efforts(_ values: [String]) -> [[String: Any]] { values.map { ["reasoningEffort": $0] } }
        try await env.store.replaceModelOptions(ModelCatalog.parseCodexModels([
            ["id": "gpt-5.6-sol", "displayName": "GPT-5.6 Sol", "supportedReasoningEfforts": efforts(["low", "high"])],
            ["id": "gpt-5.6-luna", "displayName": "GPT-5.6 Luna", "supportedReasoningEfforts": efforts(["low", "medium"])]]),
                                                scope: .codex("acct-pick"))
        await env.model.accounts.load()
        await env.model.loadModelCatalogs()
        await env.model.prepareHandoff(to: .codex, toAccountID: "acct-pick", threadID: id)
        guard env.model.handoffCards[id] != nil else { return await t.check("카드", false, env.model.banner?.text ?? "") }
        env.model.automaticHandoffDelay = 30
        env.model.startAutomaticHandoffCountdown(threadID: id)
        await t.check("카운트다운 중", env.model.handoffCards[id]?.isCountingDown == true)
        await env.model.setModelSelection(ModelSelection(model: "gpt-5.6-luna", effort: "medium"), for: .codex, threadID: id)
        await t.check("받는 모델을 고르면 카운트다운이 멈춘다 (사람이 멈춤)",
                      env.model.handoffCards[id]?.isCountingDown == false && env.model.handoffCards[id]?.review == .pausedByHuman)
        await t.equal("카드 · 입력창의 받는 모델 글이 고른 값", env.model.handoffReceiverModelText(threadID: id), "GPT-5.6 Luna · Medium")
        env.model.startAutomaticHandoffCountdown(threadID: id)
        await env.model.setEffort("low", for: .codex, threadID: id, accountID: "acct-pick")
        await t.check("강도만 바꿔도 멈춘다", env.model.handoffCards[id]?.isCountingDown == false)
        env.model.setHandoffConfirmed(true, threadID: id)
        _ = await env.model.sendHandoff(threadID: id)
        await env.settle { env.model.deliveringHandoffs[id] == nil && env.model.handoffCards[id] == nil
                            && !env.model.runner.isBusy(threadID: id) }
        let request = env.behavior.requests.first
        await t.equal("전달은 카드에서 고른 모델 · 강도로 (pinEffectiveSelection 이 덮지 않는다)",
                      [request?.model, request?.effort], ["gpt-5.6-luna", "low"])
        await t.equal("받는 쪽은 Codex", env.behavior.adapters.first?.provider, .codex)

        // 받는 쪽이 Claude 일 때도 같은 칩 — 그 대화의 Claude 선택을 바꾸고 그 값으로 간다.
        let claude = try await makeEnv("pick-claude")
        defer { claude.cleanup() }
        let cid = claude.threads[0].id
        // 마지막으로 일한 에이전트가 Codex 인 대화 (보내는 쪽 = Codex).
        let session = try await claude.store.ensureSession(threadID: cid, provider: .codex, accountID: CodexAccount.defaultID)
        var codexRun = Run(threadID: cid, sessionID: session.id, provider: .codex, requestText: "둘째 일", state: .completed,
                           startedAt: Date().addingTimeInterval(-30), endedAt: Date().addingTimeInterval(-20), terminalReason: "completed")
        codexRun.codexAccountID = CodexAccount.defaultID
        try await claude.store.insertRun(codexRun)
        _ = try await claude.store.appendEvent(ThreadEvent(threadID: cid, runID: codexRun.id, kind: .agentMessage,
                                                           provider: .codex, text: "둘째 일을 했습니다."))
        if var thread = claude.current(cid) {
            thread.preferredProvider = .codex
            thread.codexAccountID = CodexAccount.defaultID
            await claude.model.updateThread(thread)
        }
        await claude.model.threadStates[cid]?.reload(store: claude.store)
        await claude.model.prepareHandoff(to: .claude, threadID: cid)
        guard claude.model.handoffCards[cid]?.targetProvider == .claude else {
            return await t.check("Claude 가 받는 카드", false, claude.model.banner?.text ?? "")
        }
        await claude.model.setModelSelection(ModelSelection(model: "haiku", effort: "low"), for: .claude, threadID: cid)
        claude.model.setHandoffConfirmed(true, threadID: cid)
        _ = await claude.model.sendHandoff(threadID: cid)
        await claude.settle { claude.model.deliveringHandoffs[cid] == nil && claude.model.handoffCards[cid] == nil
                               && !claude.model.runner.isBusy(threadID: cid) }
        let claudeRequest = claude.behavior.requests.first
        await t.equal("Claude 가 받아도 카드에서 고른 모델 · 강도로", [claudeRequest?.model, claudeRequest?.effort], ["haiku", "low"])
    }

    static func receiverScope(_ t: TestKit) async throws {
        let env = try await makeEnv("scope")
        defer { env.cleanup() }
        let id = env.threads[0].id
        let home = env.root.appendingPathComponent("codex-b").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try await env.store.upsertCodexAccount(CodexAccount(id: "acct-b", label: "둘째", homePath: home, sortOrder: 1))
        func efforts(_ values: [String]) -> [[String: Any]] { values.map { ["reasoningEffort": $0] } }
        try await env.store.replaceModelOptions(ModelCatalog.parseCodexModels([
            ["id": "gpt-6-sol", "displayName": "GPT-6 Sol", "supportedReasoningEfforts": efforts(["low", "high"])]]),
                                                scope: .codex(CodexAccount.defaultID))
        try await env.store.replaceModelOptions(ModelCatalog.parseCodexModels([
            ["id": "gpt-5.6-sol", "displayName": "GPT-5.6 Sol", "supportedReasoningEfforts": efforts(["low", "high"])]]),
                                                scope: .codex("acct-b"))
        await env.model.accounts.load()
        await env.model.loadModelCatalogs()
        if var thread = env.current(id) {
            thread.codexSelection = ModelSelection(model: "gpt-*-sol", effort: "high")
            await env.model.updateThread(thread)
        }
        // 파일이 아닌 자격 저장소(keyring)의 계정: auth.json 이 없어도 점검표처럼 "모름" — 카드가 "로그인 안 됨" 이라 단정하지 않는다.
        env.model.codexNonFileStores["acct-b"] = true
        await env.model.prepareHandoff(to: .codex, toAccountID: "acct-b", threadID: id)
        await t.check("파일이 아닌 자격 저장소의 Codex 계정: 카드의 로그인 사실은 모름",
                      env.model.handoffCards[id] != nil && env.model.handoffCards[id]?.receiver.authenticated == nil)
        env.model.cancelHandoff(threadID: id, origin: .card)
        env.model.codexNonFileStores["acct-b"] = nil
        await env.model.prepareHandoff(to: .codex, toAccountID: "acct-b", threadID: id)
        await t.check("auth.json 이 없는 파일 저장소 계정: 로그인 안 됨", env.model.handoffCards[id]?.receiver.authenticated == false)
        await t.equal("카드 · 입력창의 받는 모델은 받는 계정의 목록으로", env.model.handoffReceiverModelText(threadID: id), "GPT-5.6 Sol · High")
        // 로그인 안 됨이 확인된 받는 쪽은 넘기기를 막는다 — 터미널에서 로그인하고 [받는 쪽 다시 확인] 뒤에 넘긴다.
        try #"{"tokens":{"access_token":"x"}}"#.write(to: URL(fileURLWithPath: home).appendingPathComponent("auth.json"),
                                                      atomically: true, encoding: .utf8)
        await env.model.recheckHandoffReceiver(threadID: id)
        env.model.setHandoffConfirmed(true, threadID: id)
        _ = await env.model.sendHandoff(threadID: id)
        await env.settle { env.model.deliveringHandoffs[id] == nil && env.model.handoffCards[id] == nil }
        await t.equal("전달도 받는 계정의 목록에서 푼다", env.behavior.requests.first?.model, "gpt-5.6-sol")
        await t.check("전달이 확인되면 칩이 받는 계정으로",
                      env.current(id)?.preferredProvider == .codex && env.current(id)?.codexAccountID == "acct-b")
        await env.settle { !env.model.runner.isBusy(threadID: id) }

        // 둘째 → 첫 계정: Codex 계정끼리는 인계하지 않는다 — 카드 없이 그 까닭 (계정만 바꾸면 같은 세션을 이어 간다, `CodexAccountSwitch`).
        let firstID = env.model.accounts.accountOrDefault(CodexAccount.defaultID).id
        env.model.banner = nil
        await env.model.prepareHandoff(to: .codex, toAccountID: firstID, threadID: id)
        await t.check("Codex 계정끼리는 인계 카드를 만들지 않는다 — 까닭을 알린다",
                      env.model.handoffCards[id] == nil && env.model.banner?.text == CodexAccountSwitch.notHandoffText,
                      env.model.banner?.text ?? "")
        guard let thread = env.current(id) else { return await t.check("대화", false) }
        await t.check("카드의 받는 쪽 바꾸기 목록도 같은 Codex 의 다른 계정을 막는다",
                      env.model.handoffTargetBlock(HandoffSource.Agent(provider: .codex, codexAccountID: firstID), thread: thread)
                        == CodexAccountSwitch.notHandoff)
        await t.equal("⇧⌘H 의 기본 받는 쪽은 같은 Codex 의 다른 계정이 아니라 반대편",
                      HandoffSource.defaultTarget(source: HandoffSource.Agent(provider: .codex, codexAccountID: "acct-b"),
                                                  chip: HandoffSource.Agent(provider: .codex, codexAccountID: firstID)).provider,
                      .claude)
    }

    /// 대기열 보류: 카드가 있는 동안은 보내지 않는다 · 전달됨 → 받는 쪽에게 · 실패 → 같은 행을 다시 보낼 카드 · 미확인 →
    /// 보낼 수 없는 카드(닫으면 멈춤 이유) · 취소 → 멈춤 이유.
    static func holds(_ t: TestKit) async throws {
        let env = try await makeEnv("holds")
        defer { env.cleanup() }
        let id = env.threads[0].id
        await env.model.prepareHandoff(to: .codex, threadID: id)
        guard let card = env.model.handoffCards[id] else { return await t.check("카드", false, env.model.banner?.text ?? "") }
        env.model.enqueueMessage("인계 뒤 첫 일", images: [], threadID: id)
        try await Task.sleep(nanoseconds: 300_000_000)
        await t.check("카드 + 대기열 → 실행 없음", env.behavior.requests.isEmpty && env.model.queuedMessages(threadID: id).count == 1)
        env.model.banner = nil
        let direct = await env.model.send("바로 보내기", provider: .claude, threadID: id)
        await t.check("보내기는 대화 배너와 함께 거절 · 카드는 그대로",
                      !direct && env.model.banner?.threadID == id && env.model.handoffCards[id]?.id == card.id)
        await env.model.resumeQueue(threadID: id)
        try await Task.sleep(nanoseconds: 200_000_000)
        await t.check("이어서 보내기도 보류 중에는 보내지 않는다", env.behavior.requests.isEmpty)

        // 실패 → 같은 행 · 같은 localToken 의 실패 카드, 칩은 그대로, 보류는 남는다.
        env.behavior.mode = .setupFails
        env.model.setHandoffConfirmed(true, threadID: id)
        _ = await env.model.sendHandoff(threadID: id)
        await env.settle { env.model.deliveringHandoffs[id] == nil && env.model.handoffCards[id]?.isFailed == true }
        let failed = env.model.handoffCards[id]
        await t.check("받는 쪽이 받지 못함 → 실패 카드 (같은 행 · 같은 localToken)",
                      failed?.isFailed == true && failed?.id == card.id && failed?.draft.handoff.localToken == card.draft.handoff.localToken
                        && failed?.review.map { if case .deliveryFailed = $0 { return true } else { return false } } == true,
                      "\(String(describing: failed?.phase))")
        await t.check("칩은 그대로 · 보류 · 대기열 남음", env.current(id)?.preferredProvider == .claude && env.model.queueHolds[id] != nil
                        && env.model.queuedMessages(threadID: id).count == 1)

        // 다시 보낸다 → 이번에는 받는다 → 받는 쪽에게 대기열.
        env.behavior.mode = .reply
        _ = await env.model.sendHandoff(threadID: id)
        await env.settle { env.behavior.requests.count == 3 }
        let retried = await env.row(id, card.id)
        await t.check("다시 넘긴 실패 행이 전달되면 대기열이 받는 쪽(Codex)에게 간다",
                      retried?.deliveryState == .delivered && env.behavior.requests.last?.prompt == "인계 뒤 첫 일"
                        && env.behavior.adapters.last?.provider == .codex && env.model.queueHolds[id] == nil,
                      "요청 \(env.behavior.requests.map(\.prompt))")
        await env.settle { !env.model.runner.isBusy(threadID: id) }

        // 미확인 → 보낼 수 없는 카드, 닫으면 보류가 멈춤 이유로.
        let unknown = try await makeEnv("unknown")
        defer { unknown.cleanup() }
        let uid = unknown.threads[0].id
        await unknown.model.prepareHandoff(to: .codex, threadID: uid)
        unknown.model.enqueueMessage("미확인 뒤 일", images: [], threadID: uid)
        unknown.behavior.mode = .unknown
        unknown.model.setHandoffConfirmed(true, threadID: uid)
        _ = await unknown.model.sendHandoff(threadID: uid)
        await unknown.settle { unknown.model.handoffCards[uid]?.phase == .unknown }
        await t.check("전달 여부 미확인 → 보낼 수 없는 카드 · 보류 유지",
                      unknown.model.handoffCards[uid]?.phase == .unknown && !(unknown.model.handoffCards[uid]?.canBeginSend ?? true)
                        && unknown.model.queueHolds[uid] != nil)
        unknown.model.cancelHandoff(threadID: uid, origin: .card)
        await t.check("닫으면 보류가 멈춤 이유로 (지금 칩에게 간다고 적는다)",
                      unknown.model.queueHolds[uid] == nil
                        && unknown.model.queuePauseReasons[uid] == "전달 여부를 확인하지 못한 인계를 닫았습니다 — 이어서 보내면 Claude 에게 갑니다",
                      unknown.model.queuePauseReasons[uid] ?? "")

        // 취소 → 멈춤 이유.
        let cancel = try await makeEnv("cancel")
        defer { cancel.cleanup() }
        let kid = cancel.threads[0].id
        await cancel.model.prepareHandoff(to: .codex, threadID: kid)
        cancel.model.enqueueMessage("취소 뒤 일", images: [], threadID: kid)
        cancel.model.cancelHandoff(threadID: kid, origin: .card)
        await t.check("카드의 취소 → 카드 · 보류가 사라지고 멈춤 이유로",
                      cancel.model.handoffCards[kid] == nil && cancel.model.queueHolds[kid] == nil
                        && cancel.model.queuePauseReasons[kid] == "인계를 취소했습니다 — 이어서 보내면 Claude 에게 갑니다"
                        && cancel.behavior.requests.isEmpty)
        // 알림의 취소는 카운트다운만 멈춘다 (검토 카드 · 보류 유지).
        await cancel.model.prepareHandoff(to: .codex, threadID: kid)
        cancel.model.automaticHandoffDelay = 30
        cancel.model.startAutomaticHandoffCountdown(threadID: kid)
        cancel.model.cancelHandoff(threadID: kid, origin: .notification)
        await t.check("알림의 취소 → 검토 카드(사람이 멈춤) · 보류 유지",
                      cancel.model.handoffCards[kid]?.review == .pausedByHuman && cancel.model.queueHolds[kid] != nil)
        await cancel.model.deleteThread(cancel.threads[0])
        await t.check("대화를 지우면 카드 · 보류 · 대기열을 함께 지운다",
                      cancel.model.handoffCards[kid] == nil && cancel.model.queueHolds[kid] == nil
                        && cancel.model.messageQueues[kid] == nil && cancel.model.queuePauseReasons[kid] == nil)
    }

    /// 다시 켜면 카드가 없다 — 보류였던 대기열은 멈춤 이유로. 한도로 멈춘 앞 메시지도 준비가 시작되면 보류 아래로 간다.
    static func holdsRelaunch(_ t: TestKit) async throws {
        let env = try await makeEnv("relaunch")
        defer { env.cleanup() }
        let id = env.threads[0].id
        await env.model.prepareHandoff(to: .codex, threadID: id)
        env.model.enqueueMessage("다시 켠 뒤 일", images: [], threadID: id)
        // 설정은 뒤에서 쓴다 — 보류 표시와 대기열이 저장될 때까지.
        for _ in 0..<200 {
            let holds = (try? await env.store.setting("message_queue_holds")) ?? nil
            let queue = (try? await env.store.setting("message_queue")) ?? nil
            if holds?.contains(id) == true, queue?.contains("다시 켠 뒤 일") == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let relaunched = AppModel(store: env.store)
        await relaunched.reloadProjects()
        await relaunched.restoreMessageQueues()
        await t.equal("다시 켬 → 멈춤 이유 (카드가 사라졌다 · 칩에게 이어 갈 CLI 세션이 없으면 맥락 없이)", relaunched.queuePauseReasons[id],
                      "인계 카드가 사라졌습니다 — 이어서 보내면 Claude 에게 맥락 없이 갑니다")
        await t.check("다시 켠 앱에는 보류가 없다", relaunched.queueHolds.isEmpty && relaunched.handoffCards.isEmpty)

        // 한도로 멈춘 앞 메시지: 준비를 시작하면 보류 아래로 (멈춤 이유를 지운다) → 전달되면 받는 쪽에게.
        let limited = try await makeEnv("limited")
        defer { limited.cleanup() }
        let lid = limited.threads[0].id
        limited.model.messageQueues[lid] = [QueuedMessage(text: "한도 전에 걸어 둔 일", images: [])]
        limited.model.queuePauseReasons[lid] = "실행이 '한도 도달'(으)로 끝나 보내지 않았습니다"
        await limited.model.prepareHandoff(to: .codex, threadID: lid)
        await t.check("준비가 시작되면 한도로 멈춘 대기열도 보류 아래로", limited.model.queueHolds[lid] != nil
                        && limited.model.queuePauseReasons[lid] == nil)
        limited.model.setHandoffConfirmed(true, threadID: lid)
        _ = await limited.model.sendHandoff(threadID: lid)
        await limited.settle { limited.behavior.requests.count == 2 }
        await t.check("전달되면 그 메시지가 받는 쪽에게", limited.behavior.requests.last?.prompt == "한도 전에 걸어 둔 일"
                        && limited.behavior.adapters.last?.provider == .codex)
    }

    /// 칸 머리 · 응답 필요 · Dock: 검토 · 실패 카드는 답을 기다리고, 카운트다운은 Dock 이 세며, 수동 · 사람이 멈춘 카드는 세지 않는다.
    static func attention(_ t: TestKit) async throws {
        let env = try await makeEnv("attention", threads: ["검토", "카운트다운", "수동"])
        defer { env.cleanup() }
        let (review, countdown, manual) = (env.threads[0], env.threads[1], env.threads[2])
        for thread in env.threads { await env.model.prepareHandoff(to: .codex, threadID: thread.id) }
        env.model.handoffCards[review.id]?.review = .automaticBlocked(["대상 한도 여유를 확인할 수 없습니다."])
        env.model.automaticHandoffDelay = 30
        env.model.startAutomaticHandoffCountdown(threadID: countdown.id)
        let reviewStatus = PaneStatus.make(env.model.paneStatusInput(for: review))
        await t.check("검토 카드: 인계 검토 필요 · 답을 기다린다 · 도움말은 카드", reviewStatus?.text == "인계 검토 필요"
                        && reviewStatus?.needsResponse == true && reviewStatus?.help == PaneStatus.handoffHelp)
        await t.check("카운트다운: 자동 인계 대기 · 답을 기다리지는 않는다",
                      PaneStatus.make(env.model.paneStatusInput(for: countdown)).map { $0.text == "자동 인계 대기" && !$0.needsResponse } == true)
        await t.check("수동 카드: 인계 초안 · 조용히",
                      PaneStatus.make(env.model.paneStatusInput(for: manual)).map { $0.text == "인계 초안" && $0.tone == .quiet && !$0.needsResponse } == true)
        await t.equal("Dock: 검토 · 카운트다운 카드를 센다 (수동 카드는 빼고)", Set(env.model.dockAttentionThreadIDs),
                      Set([review.id, countdown.id]))
        // 검토 카드의 대화가 포커스면 응답 필요에서 빠진다 — 다른 대화로 포커스를 옮겨서 본다.
        await env.model.selectThread(manual.id)
        await t.equal("응답 필요: 포커스가 아닌 대화의 검토 카드", env.model.responseNeeded.map(\.threadID), [review.id])
        env.model.pauseCountdown(threadID: countdown.id)
        await t.check("사람이 멈춘 카드는 Dock 에서 빠진다", !env.model.dockAttentionThreadIDs.contains(countdown.id))

        await t.group("칸 머리: 인계 카드의 우선순위 (순수)")
        var input = PaneStatusInput()
        input.handoffDraft = true
        input.lastRunState = .rateLimited
        await t.equal("인계 초안은 끝난 실행보다 먼저", PaneStatus.make(input)?.text, "인계 초안")
        input.runState = .running
        await t.equal("도는 실행은 인계 초안보다 먼저", PaneStatus.make(input)?.text, "실행 중")
        input.handoffCountdown = true
        await t.equal("카운트다운은 도는 실행보다 먼저", PaneStatus.make(input)?.text, "자동 인계 대기")
        input.orchestration = .planApproval
        await t.equal("자동 작업은 카운트다운보다 먼저", PaneStatus.make(input)?.text, "계획 승인 대기")
        input.handoffReview = true
        await t.equal("인계 검토는 자동 작업보다 먼저", PaneStatus.make(input)?.text, "인계 검토 필요")
        input.pendingQuestions = 1
        await t.equal("질문은 인계 검토보다 먼저", PaneStatus.make(input)?.text, "질문 대기")
    }

    // MARK: 인계 문서 — 승인 결정 · 사람이 한 일 (H2 · hnd-2 · txt-9 · H22)

    /// 승인 결정이 인계 문서에 들어가는 모양: 사람의 거절 = "주요 결정 … (다시 하지 말 것)" — 다음 행동 · 진행 중이 아니다.
    /// 거절 사유를 돌려준 오류 도구 결과 · 앱의 거절 안내는 실패가 아니다. 발췌의 승인 줄에 무엇과 사유. 승인 결정 기록의 약속
    /// (payload "ahc.approval")과 그 표시가 없는 옛 행(앞의 승인 요청 행과 짝짓기)을 모두 읽는다.
    static func approvalsInPacket(_ t: TestKit) async {
        await t.group("인계 문서: 승인 결정 (거절은 주요 결정)")
        let project = Project(name: "p", path: "/tmp/p")
        let thread = ConversationThread(projectID: project.id, title: "대화")
        func build(_ events: [ThreadEvent]) -> HandoffPacket {
            HandoffPacketBuilder.build(.init(thread: thread, project: project, fromProvider: .claude, toProvider: .codex,
                                             events: events, runs: [], lastConfirmedPacket: nil, git: GitSnapshot(), baseSeq: 0))
        }
        let input = #"{"command":"git commit -m \"고침\"","description":"커밋"}"#
        // 옛 행: 결정 행에 표시가 없다 — 앞의 승인 요청 행과 짝짓고, 사유는 직후의 오류 도구 결과에서.
        let legacy: [ThreadEvent] = [
            ThreadEvent(threadID: thread.id, runID: "r", seq: 1, kind: .userMessage, title: "사용자", text: "고쳐 줘"),
            ThreadEvent(threadID: thread.id, runID: "r", seq: 2, kind: .approvalRequest, provider: .claude,
                        title: "도구 사용: Bash — 커밋", text: input, toolUseID: "tu-1"),
            ThreadEvent(threadID: thread.id, runID: "r", seq: 3, kind: .approvalDecision, provider: .claude, title: "승인 결정", text: "거절"),
            ThreadEvent(threadID: thread.id, runID: "r", seq: 4, kind: .toolResult, provider: .claude, title: "Bash — 오류",
                        text: "커밋은 제가 직접 할게요", toolUseID: "tu-1"),
            ThreadEvent(threadID: thread.id, runID: "r", seq: 5, kind: .agentMessage, provider: .claude, text: "알겠습니다. 커밋하지 않겠습니다."),
            ThreadEvent(threadID: thread.id, runID: "r", seq: 6, kind: .systemNotice, provider: .claude, title: "안내",
                        text: "승인 거절로 실행되지 않은 도구: Bash"),
        ]
        let packet = build(legacy)
        // 조사 없는 꼴 (2차 시험 copy-13 — "main.swift 을" 처럼 틀리지 않게).
        let rejection = "사용자가 거절함: 명령 `git commit -m \"고침\"` · 사유: 커밋은 제가 직접 할게요 (다시 하지 말 것)"
        await t.check("옛 행: 거절은 주요 결정 (무엇을 · 사유 · 다시 하지 말 것)", packet.decisions.contains(rejection), "\(packet.decisions)")
        await t.check("거절은 다음 행동 · 진행 중이 아니다",
                      !packet.nextActions.contains { $0.contains("거절") } && !packet.inProgress.contains { $0.contains("거절") },
                      "\(packet.nextActions) \(packet.inProgress)")
        await t.check("거절 사유를 돌려준 도구 결과 · 앱의 거절 안내는 실패가 아니다", packet.failedAttempts.isEmpty, "\(packet.failedAttempts)")
        await t.check("발췌의 승인 줄: 무엇을 · 사유",
                      packet.transcriptExcerpt.contains("[3] 승인: 거절 — 명령 `git commit -m \"고침\"` · 사유: 커밋은 제가 직접 할게요"),
                      packet.transcriptExcerpt)

        // 새 기록: 결정 행의 payload 가 요청 제목 · 사유를 담는다 (사람이 적은 사유가 먼저).
        let decision: [String: Any] = ["decision": "deny", "reason": "배포는 하지 마세요", "requestTitle": "Bash — 배포",
                                       "toolName": "Bash", "approvalKind": "tool", "requestID": "q-2"]
        let payload = JSONUtil.line(["ahc.approval": decision])
        let modern: [ThreadEvent] = [
            ThreadEvent(threadID: thread.id, runID: "r2", seq: 11, kind: .approvalRequest, provider: .claude,
                        title: "도구 사용: Bash — 배포", text: "{}", toolUseID: "tu-2"),
            ThreadEvent(threadID: thread.id, runID: "r2", seq: 12, kind: .approvalDecision, provider: .claude, title: "승인 결정",
                        text: "거절", payloadJSON: payload, toolUseID: "tu-2"),
            ThreadEvent(threadID: thread.id, runID: "r2", seq: 13, kind: .toolResult, provider: .claude, title: "Bash — 오류",
                        text: "배포는 하지 마세요", toolUseID: "tu-2"),
            ThreadEvent(threadID: thread.id, runID: "r2", seq: 14, kind: .approvalRequest, provider: .claude,
                        title: "도구 사용: Read", text: #"{"file_path":"/tmp/p/a.swift"}"#, toolUseID: "tu-3"),
            ThreadEvent(threadID: thread.id, runID: "r2", seq: 15, kind: .approvalDecision, provider: .claude, title: "승인 결정",
                        text: "허용", toolUseID: "tu-3"),
        ]
        let modernPacket = build(modern)
        await t.check("새 기록(payload): 요청 제목 · 사람이 적은 사유",
                      modernPacket.decisions.contains("사용자가 거절함: Bash — 배포 · 사유: 배포는 하지 마세요 (다시 하지 말 것)"),
                      "\(modernPacket.decisions)")
        await t.check("허용은 결정으로 적지 않는다 · 거절 사유 결과는 실패가 아니다",
                      !modernPacket.decisions.contains { $0.contains("Read") } && modernPacket.failedAttempts.isEmpty,
                      "\(modernPacket.decisions) \(modernPacket.failedAttempts)")
        await t.check("발췌의 허용 줄: 무엇을", modernPacket.transcriptExcerpt.contains("[15] 승인: 허용 — Read /tmp/p/a.swift"),
                      modernPacket.transcriptExcerpt)
        let stopped = build([ThreadEvent(threadID: thread.id, runID: "r3", seq: 21, kind: .approvalDecision, title: "승인 결정",
                                         text: "거절 (작업 멈춤)")])
        await t.check("작업 멈춤으로 닫힌 승인은 사람의 거절이 아니다", !stopped.decisions.contains { $0.hasPrefix("사용자가 ") })
        let empty = GeminiAssistSummary(progress: [], nextActions: [], decisions: [], failedAttempts: [], cautions: [], unverified: [])
        let merged = GeminiAssistValidator.merge(GeminiValidationResult(summary: empty, warnings: []), into: packet, model: "gemini-test")
        await t.check("Gemini 정리본에도 사람의 거절이 남는다", merged.decisions.contains(rejection), "\(merged.decisions)")
        let editDenied = build([
            ThreadEvent(threadID: thread.id, runID: "r4", seq: 31, kind: .approvalRequest, provider: .claude, title: "도구 사용: Edit",
                        text: #"{"file_path":"/tmp/p/main.swift","old_string":"a","new_string":"b"}"#, toolUseID: "tu-4"),
            ThreadEvent(threadID: thread.id, runID: "r4", seq: 32, kind: .approvalDecision, provider: .claude, title: "승인 결정",
                        text: "거절 후 중단", toolUseID: "tu-4"),
        ])
        await t.check("거절 줄은 무엇이든 조사가 붙지 않는다 · 거절하고 멈춤",
                      editDenied.decisions.contains("사용자가 거절하고 작업을 멈춤: Edit /tmp/p/main.swift (다시 하지 말 것)")
                        && !editDenied.decisions.contains { $0.contains(" 을 ") || $0.contains(" 를 ") }, "\(editDenied.decisions)")
    }

    // MARK: 인계 문서 — 질문에 적은 답 · 승인 줄의 비밀값 (2차 시험 conv-1 · copy-1 · hand-7)

    /// 질문(Claude `AskUserQuestion`)에 적은 답은 "사용자 답: <질문> → <답>" — "다시 하지 말 것" 이 붙은 거절이 아니다. 답을 돌려준
    /// 오류 결과는 실패가 아니다, 발췌 · Gemini 입력 · Gemini 정리본도 답으로. 답이 거절로 적힌 옛 행(10-04 빌드 · 그 전)도.
    static func answersInPacket(_ t: TestKit) async {
        await t.group("인계 문서: 질문에 적은 답은 사용자 답 (거절 아님)")
        let project = Project(name: "p", path: "/tmp/p")
        let thread = ConversationThread(projectID: project.id, title: "대화")
        let input = #"{"questions":[{"question":"어느 방식으로 할까요?","header":"방식","options":[{"label":"A"},{"label":"B"}]}]}"#
        func events(_ decision: ThreadEvent, payload: Bool) -> [ThreadEvent] {
            let requestPayload = payload
                ? ThreadEvent.approvalRequestPayload(requestID: "c-1", toolName: AskedQuestion.claudeToolName, approvalKind: "tool") : nil
            return [ThreadEvent(threadID: thread.id, runID: "r", seq: 1, kind: .userMessage, title: "사용자", text: "정리해 줘"),
                    ThreadEvent(threadID: thread.id, runID: "r", seq: 2, kind: .approvalRequest, provider: .claude,
                                title: "도구 사용: AskUserQuestion", text: input, payloadJSON: requestPayload, toolUseID: "ask-1"),
                    decision,
                    ThreadEvent(threadID: thread.id, runID: "r", seq: 4, kind: .toolResult, provider: .claude,
                                title: "AskUserQuestion — 오류", text: "B 방식으로", toolUseID: "ask-1"),
                    ThreadEvent(threadID: thread.id, runID: "r", seq: 5, kind: .agentMessage, provider: .claude, text: "B 방식으로 하겠습니다.")]
        }
        func decision(_ info: ApprovalDecisionInfo?, text: String) -> ThreadEvent {
            ThreadEvent(threadID: thread.id, runID: "r", seq: 3, kind: .approvalDecision, provider: .claude, title: "승인 결정", text: text,
                        payloadJSON: info.map(ThreadEvent.approvalDecisionPayload), toolUseID: "ask-1")
        }
        func build(_ list: [ThreadEvent]) -> HandoffPacket {
            HandoffPacketBuilder.build(.init(thread: thread, project: project, fromProvider: .claude, toProvider: .codex,
                                             events: list, runs: [], lastConfirmedPacket: nil, git: GitSnapshot(), baseSeq: 0))
        }
        let answerLine = "사용자 답: 어느 방식으로 할까요? → B 방식으로"
        let modern = events(decision(ApprovalDecisionInfo(decision: .answered, requestTitle: "AskUserQuestion",
                                                          toolName: AskedQuestion.claudeToolName, approvalKind: "tool",
                                                          requestID: "c-1", answer: "B 방식으로"), text: "답함"), payload: true)
        let packet = build(modern)
        await t.check("답은 주요 결정의 '사용자 답' — 거절 · 다시 하지 말 것이 아니다",
                      packet.decisions.contains(answerLine) && !packet.decisions.contains { $0.contains("다시 하지 말 것") || $0.contains("거절") },
                      "\(packet.decisions)")
        await t.check("답을 돌려준 오류 결과는 실패가 아니다", packet.failedAttempts.isEmpty, "\(packet.failedAttempts)")
        await t.check("발췌: '[3] 사용자 답: …' (승인 · 거절이 아니다)",
                      packet.transcriptExcerpt.contains("[3] \(answerLine)") && !packet.transcriptExcerpt.contains("거절"),
                      packet.transcriptExcerpt)
        let empty = GeminiAssistSummary(progress: [], nextActions: [], decisions: [], failedAttempts: [], cautions: [], unverified: [])
        let merged = GeminiAssistValidator.merge(GeminiValidationResult(summary: empty, warnings: []), into: packet, model: "gemini-test")
        await t.check("Gemini 정리본에도 사람의 답이 남는다", merged.decisions.contains(answerLine), "\(merged.decisions)")
        let geminiInput = GeminiAssistInputBuilder.build(thread: thread, project: project, events: modern, runs: [], previousPacket: nil,
                                                         rulePacket: packet, git: GitSnapshot())
        let decisionLines = geminiInput.split(separator: "\n").filter { $0.contains("approvalDecision") }
        await t.check("Gemini 입력: 결정 행은 사용자 답으로 (거절로 넣지 않는다)",
                      decisionLines.count == 1 && decisionLines.allSatisfy { $0.contains(answerLine) && !$0.contains("거절") },
                      decisionLines.joined(separator: "\n"))

        // 답이 거절로 적힌 옛 행: 10-04 빌드(도구 이름 · 사유 = 답)와 그 전(표시 없음 — 요청 입력 · 결과의 글).
        let october = build(events(decision(ApprovalDecisionInfo(decision: .deny, reason: "B 방식으로", requestTitle: "AskUserQuestion",
                                                                 toolName: AskedQuestion.claudeToolName, approvalKind: "tool",
                                                                 requestID: "c-1"), text: "거절"), payload: true))
        await t.check("10-04 빌드의 거절로 적힌 답도 사용자 답", october.decisions.contains(answerLine)
                        && !october.decisions.contains { $0.contains("다시 하지 말 것") }, "\(october.decisions)")
        let older = build(events(decision(nil, text: "거절"), payload: false))
        await t.check("표시 없는 옛 행도 사용자 답 (요청 입력이 질문 · 결과의 글이 답)", older.decisions.contains(answerLine)
                        && older.failedAttempts.isEmpty, "\(older.decisions) \(older.failedAttempts)")
        let stopped = build(events(decision(ApprovalDecisionInfo(decision: .denyAndCancel, reason: "그만", toolName: AskedQuestion.claudeToolName,
                                                                 requestID: "c-1"), text: "거절 후 중단"), payload: true))
        await t.check("질문을 [거절 후 중단] 해도 '다시 하지 말 것' 줄은 없다 (물음은 금지할 일이 아니다)",
                      !stopped.decisions.contains { $0.hasPrefix(HandoffPacketBuilder.rejectionPrefix + "거절") || $0.hasPrefix("사용자 답") }
                        && stopped.failedAttempts.isEmpty, "\(stopped.decisions)")
    }

    /// 승인 · 거절 줄의 명령 원문에 든 비밀값은 줄 가운데여도 가린다 (`SecretMasker`) — 자른 뒤가 아니라 가린 뒤 자른다.
    static func approvalSecrets(_ t: TestKit) async {
        await t.group("인계 문서: 승인 · 거절 줄의 비밀값")
        let project = Project(name: "p", path: "/tmp/p")
        let thread = ConversationThread(projectID: project.id, title: "대화")
        let command = #"{"command":"PGPASSWORD=hunter2-secret psql -h prod-db -c 'select 1'"}"#
        let allowed = #"{"command":"STRIPE_SECRET_KEY=sk_live_secretvalue node pay.js"}"#
        let list: [ThreadEvent] = [
            ThreadEvent(threadID: thread.id, runID: "r", seq: 1, kind: .approvalRequest, provider: .claude, title: "도구 사용: Bash",
                        text: command, toolUseID: "b-1"),
            ThreadEvent(threadID: thread.id, runID: "r", seq: 2, kind: .approvalDecision, provider: .claude, title: "승인 결정",
                        text: "거절", payloadJSON: ThreadEvent.approvalDecisionPayload(ApprovalDecisionInfo(
                            decision: .deny, reason: "운영 DB 금지", toolName: "Bash", approvalKind: "tool", requestID: "1")),
                        toolUseID: "b-1"),
            ThreadEvent(threadID: thread.id, runID: "r", seq: 3, kind: .approvalRequest, provider: .claude, title: "도구 사용: Bash",
                        text: allowed, toolUseID: "b-2"),
            ThreadEvent(threadID: thread.id, runID: "r", seq: 4, kind: .approvalDecision, provider: .claude, title: "승인 결정",
                        text: "허용", toolUseID: "b-2"),
            ThreadEvent(threadID: thread.id, seq: 5, kind: .commandExecution, provider: nil, title: "pnpm install && export NPM_TOKEN=npm-secret",
                        text: "pnpm install && export NPM_TOKEN=npm-secret", payloadJSON: JSONUtil.line(["exitCode": 0, "source": "app"])),
        ]
        let packet = HandoffPacketBuilder.build(.init(thread: thread, project: project, fromProvider: .claude, toProvider: .codex,
                                                      events: list, runs: [], lastConfirmedPacket: nil, git: GitSnapshot(), baseSeq: 0))
        let document = HandoffPacketBuilder.render(packet, threadTitle: "대화", projectPath: "/tmp/p")
        await t.check("거절 줄 · 발췌 · 앱이 실행한 명령에 줄 가운데의 비밀값이 없다",
                      !["hunter2-secret", "sk_live_secretvalue", "npm-secret"].contains { document.contains($0) || packet.decisions.joined().contains($0) }
                        && document.contains("PGPASSWORD=[REDACTED] psql"), document)
        await t.check("명령의 나머지는 남는다 (받는 쪽이 무엇을 거절했는지 안다)",
                      packet.decisions.contains("사용자가 거절함: 명령 `PGPASSWORD=[REDACTED] psql -h prod-db -c 'select 1'` · 사유: 운영 DB 금지 (다시 하지 말 것)"),
                      "\(packet.decisions)")
        let masked = SecretMasker.mask("mysql --password=hunter2 · curl 'https://x.test/a?access_token=abc123&page=2' · llm --max-tokens=100 MAX_TOKENS=4096 · if token == nil")
        await t.check("플래그 · 주소 매개변수의 비밀값은 가리고, 수 · 코드는 그대로",
                      !masked.contains("hunter2") && !masked.contains("abc123") && masked.contains("&page=2")
                        && masked.contains("--max-tokens=100") && masked.contains("MAX_TOKENS=4096") && masked.contains("token == nil"), masked)
        // 자르는 자리가 토큰 가운데면, 먼저 자른 조각("ghp_abcdefghijklmno")은 토큰 모양이 아니라 가려지지 않는다.
        let cut = String(repeating: "x", count: 100) + " ghp_abcdefghijklmnopqrstuvwxyz0123"
        await t.check("가린 뒤 자른다 (잘린 토큰 조각이 남지 않는다)",
                      HandoffPacketBuilder.maskedLine(cut, max: 120).map { !$0.contains("ghp_") && $0.contains("[REDACTED]") } == true,
                      HandoffPacketBuilder.maskedLine(cut, max: 120) ?? "nil")
        await t.equal("줄의 일부로 들어갈 명령은 값만 가리고 나머지를 남긴다",
                      SecretMasker.maskInline("PGPASSWORD=hunter2 psql -h prod"), "PGPASSWORD=[REDACTED] psql -h prod")
    }

    /// 인계 문서의 사실: 사람이 앱에서 한 커밋 · 구간의 새 커밋은 완료한 작업, 받지 못한 인계는 "인계 수행" 이 아니다, 진단 행은 넣지
    /// 않는다, 보낼 글에 내부 값(패킷 버전 · seq)이 없다, 목표를 적지 않았으면 중립 문장, 다음 행동을 모르면 덧붙인 말을 따르게.
    /// 받는 쪽이 꼭 알아야 할 것이 문서에 다 들어가는가 — 실제와 같은 대화 하나(Claude 가 일한 대로 저장된 행: 명령 · 편집은 도구
    /// 요청 · 결과)로: 목표 · 다음 행동 = 마지막 미완료 지시 · 실패한 명령과 원인 · 실패한 시도 · 바뀐 파일(편집 · 실행 전후 비교) ·
    /// 시험 결과 · 브랜치 / HEAD / 새 커밋 · 사람의 거절("다시 하지 말 것") · 질문의 답 · 앱에서 한 커밋 · 덧붙인 말의 자리 ·
    /// 비밀 가림 · 진단 없음. 이 시험이 Claude 의 시험 실행 · 실패한 명령이 문서에서 빠지던 결함을 찾았다 (2026-10-09).
    static func essentialFacts(_ t: TestKit) async {
        await t.group("인계 문서: 받는 쪽이 꼭 알아야 할 것 (실제와 같은 대화 하나)")
        let project = Project(name: "pay", path: "/tmp/pay")
        var thread = ConversationThread(projectID: project.id, title: "결제 재시도")
        thread.goal = "결제 재시도를 3회로 바꾸고 결제 테스트를 통과시킨다"
        let tid = thread.id
        let secret = "sk_live_51HqTESTsecretVALUE0000"
        func ev(_ seq: Int64, _ kind: EventKind, provider: AgentProvider? = .claude, run: String? = "r1", title: String = "",
                text: String, payload: String? = nil, tool: String? = nil) -> ThreadEvent {
            ThreadEvent(threadID: tid, runID: run, seq: seq, kind: kind, provider: provider, title: title, text: text,
                        payloadJSON: payload, toolUseID: tool)
        }
        func bash(_ command: String, description: String, background: Bool = false) -> String {
            var input: [String: Any] = ["command": command, "description": description]
            if background { input["run_in_background"] = true }
            return JSONUtil.prettyString(input)
        }
        typealias Entry = RunFileSnapshot.Entry
        let t1 = Date(timeIntervalSince1970: 1_800_000_005)
        let changes = RunFileChanges.compare(
            runID: "r1", before: RunFileSnapshot(entries: [:], head: "h1"),
            after: RunFileSnapshot(entries: ["Sources/Pay/PaymentService.swift": Entry(code: "M", added: 6, removed: 2, size: 900, modifiedAt: t1),
                                            "Tests/PayTests/PaymentTests.swift": Entry(code: "M", added: 3, removed: 0, size: 400, modifiedAt: t1)],
                                   head: "h1"))
        var changesRow = changes.event(threadID: tid, provider: .claude)
        changesRow.seq = 17
        changesRow.runID = "r1"
        let question = #"{"questions":[{"question":"재시도 사이 대기는 몇 초로 할까요?","header":"대기","options":[{"label":"1초"},{"label":"2초"}]}]}"#
        let events: [ThreadEvent] = [
            ev(1, .userMessage, provider: nil, title: "사용자",
               text: "결제 재시도를 3회로 바꿔 줘. 테스트는 STRIPE_SECRET_KEY=\(secret) 로 돌려."),
            ev(2, .agentMessage, text: "PaymentService.swift 를 고치겠습니다."),
            ev(3, .toolRequest, title: "Edit", text: JSONUtil.prettyString(["file_path": "/tmp/pay/Sources/Pay/PaymentService.swift",
                                                                              "old_string": "retries = 1", "new_string": "retries = 3"]),
               tool: "tu-edit"),
            ev(4, .toolResult, title: "Edit", text: "The file has been updated.", tool: "tu-edit"),
            ev(5, .toolRequest, title: "Bash", text: bash("swift build", description: "빌드"), tool: "tu-build"),
            ev(6, .toolResult, title: "Bash — 오류", text: "Exit code 1\nerror: cannot find 'retryCount' in scope\n1 error", tool: "tu-build"),
            ev(7, .toolRequest, title: "Bash",
               text: bash("STRIPE_SECRET_KEY=\(secret) swift test --filter PaymentTests", description: "결제 테스트"), tool: "tu-test"),
            ev(8, .toolResult, title: "Bash — 오류", text: "Exit code 1\nTest Case 'PaymentTests.testRetry' failed", tool: "tu-test"),
            ev(9, .toolRequest, title: "Bash", text: bash("psql prod -f migrate.sql", description: "운영 DB 마이그레이션"), tool: "tu-db"),
            ev(10, .approvalRequest, title: "도구 사용: Bash — 운영 DB 마이그레이션", text: #"{"command":"psql prod -f migrate.sql"}"#,
               tool: "tu-db"),
            ev(11, .approvalDecision, title: "승인 결정", text: "거절",
               payload: ThreadEvent.approvalDecisionPayload(ApprovalDecisionInfo(
                decision: .deny, reason: "운영 DB 에는 손대지 마세요", requestTitle: "Bash — 운영 DB 마이그레이션", toolName: "Bash",
                approvalKind: "tool", requestID: "q-db")),
               tool: "tu-db"),
            ev(12, .toolResult, title: "Bash — 오류", text: "운영 DB 에는 손대지 마세요", tool: "tu-db"),
            ev(13, .approvalRequest, title: "도구 사용: AskUserQuestion", text: question,
               payload: ThreadEvent.approvalRequestPayload(requestID: "q-ask", toolName: AskedQuestion.claudeToolName, approvalKind: "tool"),
               tool: "ask-1"),
            ev(14, .approvalDecision, title: "승인 결정", text: "답함",
               payload: ThreadEvent.approvalDecisionPayload(ApprovalDecisionInfo(
                decision: .answered, requestTitle: "AskUserQuestion", toolName: AskedQuestion.claudeToolName, approvalKind: "tool",
                requestID: "q-ask", answer: "2초")),
               tool: "ask-1"),
            ev(15, .toolResult, title: "AskUserQuestion — 오류", text: "2초", tool: "ask-1"),
            ev(16, .agentMessage, text: "재시도를 3회 · 대기 2초로 바꿨습니다. PaymentTests 하나가 아직 실패합니다."),
            changesRow,
            ev(18, .commandExecution, provider: nil, run: nil, title: "git commit -F -", text: "git commit -F -",
               payload: JSONUtil.line(["status": "completed", "source": "app", "exitCode": 0])),
            ev(19, .systemNotice, title: ThreadEvent.diagnosticTitle, text: "claude -p --output-format stream-json --verbose",
               payload: ThreadEvent.noticePayload(ThreadEvent.diagnosticKey)),
            ev(20, .userMessage, provider: nil, run: nil, title: "사용자",
               text: "실패하는 PaymentTests 를 고치고 README 의 재시도 절도 갱신해 줘."),
        ]
        let runs = [Run(id: "r0", threadID: tid, sessionID: "s", provider: .claude, requestText: "결제 모듈 정리", state: .failed,
                        errorMessage: "API Error: 529 Overloaded"),
                    Run(id: "r1", threadID: tid, sessionID: "s", provider: .claude, requestText: "결제 재시도를 3회로 바꿔 줘.",
                        state: .completed)]
        var git = GitSnapshot()
        git.isRepository = true
        git.branch = "feature/pay-retry"
        git.head = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
        git.unstaged = ["Tests/PayTests/PaymentTests.swift"]
        git.commitsSinceBase = ["a1b2c3d 결제 재시도 3회로"]
        let packet = HandoffPacketBuilder.build(.init(thread: thread, project: project, fromProvider: .claude, toProvider: .codex,
                                                      events: events, runs: runs, lastConfirmedPacket: nil, git: git, baseSeq: 0))
        let rendered = HandoffPacketBuilder.render(packet, threadTitle: thread.title, projectPath: project.path)
        let memo = "운영 키는 절대 쓰지 마세요."
        let document = HandoffPacketBuilder.insertUserMemo(rendered, memo: memo)
        func section(_ title: String) -> String {
            guard let start = document.range(of: "## \(title)\n") else { return "" }
            let rest = document[start.upperBound...]
            return String(rest[..<(rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex)])
        }
        await t.check("목표", section("목표").contains("결제 재시도를 3회로 바꾸고 결제 테스트를 통과시킨다"), section("목표"))
        await t.check("다음 행동 = 마지막 미완료 지시",
                      section("다음 행동").hasPrefix("- 아직 처리되지 않은 사용자 지시: 실패하는 PaymentTests 를 고치고 README 의 재시도 절도 갱신해 줘."),
                      section("다음 행동"))
        await t.check("실패한 명령과 원인 (Claude 의 Bash — 명령 · 종료 코드 · 원인 줄)",
                      section("실패·중단").contains("명령 실패(관찰): swift build → 종료 코드 1 · error: cannot find 'retryCount' in scope"),
                      section("실패·중단"))
        await t.check("실패한 시도 (실패로 끝난 실행)",
                      section("실패·중단").contains("실패한 시도: 결제 모듈 정리 → API Error: 529 Overloaded"), section("실패·중단"))
        await t.check("시험 결과 (Claude 가 돌린 시험 — 예전에는 '관찰된 테스트 실행 기록 없음')",
                      section("테스트").contains("swift test --filter PaymentTests → 종료 코드 1 · Test Case 'PaymentTests.testRetry' failed"),
                      section("테스트"))
        await t.check("바뀐 파일 — 편집 도구 · 실행 전후 비교",
                      section("완료한 작업").contains("Claude 가 편집 도구로 고친 파일(관찰) 1개: Sources/Pay/PaymentService.swift")
                        && section("완료한 작업").contains("Claude 실행에서 바뀐 파일(실행 전후 비교, 관찰) 2개"), section("완료한 작업"))
        await t.check("브랜치 · HEAD · 새 커밋",
                      section("현재 파일 상태").contains("브랜치: feature/pay-retry") && section("현재 파일 상태").contains("HEAD: a1b2c3d4e5f6")
                        && section("완료한 작업").contains("새 커밋(관찰): a1b2c3d 결제 재시도 3회로"), document)
        await t.check("사람의 거절은 '다시 하지 말 것' (거절 사유를 돌려준 결과는 실패가 아니다)",
                      section("주요 결정").contains("사용자가 거절함: 명령 `psql prod -f migrate.sql` · 사유: 운영 DB 에는 손대지 마세요 (다시 하지 말 것)")
                        && !section("실패·중단").contains("운영 DB"), document)
        await t.check("질문의 답", section("주요 결정").contains("사용자 답: 재시도 사이 대기는 몇 초로 할까요? → 2초"), section("주요 결정"))
        await t.check("앱에서 한 커밋", section("완료한 작업").contains("사용자가 앱에서 직접 커밋함(관찰) — 다시 커밋하지 마세요"),
                      section("완료한 작업"))
        let memoRange = document.range(of: "## 사용자가 덧붙인 말 (사용자가 직접 씀)\n\(memo)")
        let nextRange = document.range(of: "## 다음 행동")
        let preamble = document.range(of: "이 메시지는 Agent Handoff Console 앱이 보냈습니다")
        await t.check("덧붙인 말은 앞머리 뒤 · 다음 행동 앞",
                      preamble != nil && memoRange != nil && nextRange != nil
                        && preamble!.lowerBound < memoRange!.lowerBound && memoRange!.lowerBound < nextRange!.lowerBound, document)
        await t.check("비밀 값은 가린다 (지시 · 시험 명령 · 발췌)",
                      !document.contains(secret) && document.contains("STRIPE_SECRET_KEY=[REDACTED]"), document)
        await t.check("진단 행은 없다", !document.contains("stream-json"), document)
        await t.check("거절된 · 답한 도구는 실패 · 시험으로 세지 않는다",
                      !section("테스트").contains("psql") && !section("실패·중단").contains("AskUserQuestion"), document)
        await t.equal("Claude 의 도구 요청 읽기: 명령 · 편집 · 그 밖", [
            HandoffPacketBuilder.claudeCall(ev(1, .toolRequest, title: "Bash", text: bash("ls", description: "")), projectPath: "/tmp/pay"),
            HandoffPacketBuilder.claudeCall(ev(1, .toolRequest, title: "Write", text: #"{"file_path":"/elsewhere/a.md","content":"x"}"#),
                                            projectPath: "/tmp/pay"),
            HandoffPacketBuilder.claudeCall(ev(1, .toolRequest, title: "Read", text: #"{"file_path":"/tmp/pay/a.swift"}"#),
                                            projectPath: "/tmp/pay")],
                      [.command("ls", background: false), .edit("/elsewhere/a.md"), nil])
        await t.equal("뒤에서 돌린 명령 · 결과 없음 · 종료 코드 없는 오류",
                      [HandoffPacketBuilder.claudeCommandOutcome(ev(1, .toolResult, title: "Bash", text: "Command running in background with ID: b1"),
                                                                 background: true).text,
                       HandoffPacketBuilder.claudeCommandOutcome(nil, background: false).text,
                       HandoffPacketBuilder.claudeCommandOutcome(ev(1, .toolResult, title: "Bash — 오류",
                                                                    text: "<tool_use_error>Blocked: standalone sleep 40.</tool_use_error>"),
                                                                 background: false).text],
                      ["뒤에서 실행 — 결과 미확인", "결과 미확인", "오류 · <tool_use_error>Blocked: standalone sleep 40.</tool_use_error>"])
    }

    static func packetFacts(_ t: TestKit) async {
        await t.group("인계 문서: 사람이 한 일 · 받지 못한 인계 · 내부 값")
        let project = Project(name: "p", path: "/tmp/p")
        let thread = ConversationThread(projectID: project.id, title: "대화")
        var git = GitSnapshot()
        git.isRepository = true
        git.head = "87450eb1234567890abcdef1234567890abcdef1"
        git.commitsSinceBase = ["87450eb 결제 재시도 고침"]
        let commitPayload: [String: Any] = ["status": "completed", "source": "app", "exitCode": 0]
        let commit = ThreadEvent(threadID: thread.id, seq: 1, kind: .commandExecution, provider: nil, title: "git commit -F -",
                                 text: "git commit -F -", payloadJSON: JSONUtil.line(commitPayload))
        let stage = ThreadEvent(threadID: thread.id, seq: 2, kind: .commandExecution, provider: nil, title: "git add -- a.swift",
                                text: "git add -- a.swift", payloadJSON: JSONUtil.line(commitPayload))
        let diagnosticPayload: [String: Any] = [HandoffPacketBuilder.diagnosticKey: true]
        let diagnostic = ThreadEvent(threadID: thread.id, seq: 3, kind: .error, provider: .codex, title: "진단", text: "app-server 시작",
                                     payloadJSON: JSONUtil.line(diagnosticPayload))
        var failedHandoff = Handoff(threadID: thread.id, fromProvider: .claude, toProvider: .codex, baseSeq: 0, draftJSON: "{}", finalText: "x")
        failedHandoff.deliveryState = .failed
        failedHandoff.deliveryRunID = "delivery-run"
        let tokenPayload: [String: Any] = ["localToken": failedHandoff.localToken]
        let sent = ThreadEvent(threadID: thread.id, seq: 4, kind: .handoffSent, provider: .claude, title: "Claude → Codex 인계 전송",
                               text: "x", payloadJSON: JSONUtil.line(tokenPayload))
        let deliveryRun = Run(id: "delivery-run", threadID: thread.id, sessionID: "s", provider: .codex, requestText: "이 메시지는 … 긴 문서",
                              state: .failed, isHandoffDelivery: true)
        func build(_ handoffs: [Handoff]) -> HandoffPacket {
            HandoffPacketBuilder.build(.init(thread: thread, project: project, fromProvider: .claude, toProvider: .codex,
                                             events: [commit, stage, diagnostic, sent], runs: [deliveryRun], lastConfirmedPacket: nil,
                                             git: git, baseSeq: 4, handoffs: handoffs))
        }
        let packet = build([failedHandoff])
        await t.check("사람이 앱에서 한 커밋 · 구간의 새 커밋은 완료한 작업 (스테이지는 뺀다)",
                      packet.completed.contains("사용자가 앱에서 직접 커밋함(관찰) — 다시 커밋하지 마세요")
                        && packet.completed.contains("새 커밋(관찰): 87450eb 결제 재시도 고침")
                        && !packet.completed.contains { $0.contains("git add") }, "\(packet.completed)")
        await t.check("받지 못한 인계는 '인계 수행' 이 아니다 · 그 전달 실행은 실패한 시도가 아니다",
                      !packet.decisions.contains { $0.hasPrefix("인계 수행") } && !packet.failedAttempts.contains { $0.contains("실패한 시도") },
                      "\(packet.decisions) \(packet.failedAttempts)")
        await t.check("진단 행은 문서에 넣지 않는다", !packet.failedAttempts.contains { $0.contains("app-server") }, "\(packet.failedAttempts)")
        var delivered = failedHandoff
        delivered.deliveryState = .delivered
        await t.check("전달된 인계는 '인계 수행'", build([delivered]).decisions.contains("인계 수행: Claude → Codex 인계 전송"))
        let rendered = HandoffPacketBuilder.render(packet, threadTitle: "대화", projectPath: "/tmp/p")
        await t.check("보낼 글에 내부 값(패킷 버전 · seq)이 없다 · HEAD 는 있다",
                      !rendered.contains("기술 정보") && !rendered.contains("seq ") && !rendered.contains("패킷 v")
                        && rendered.contains("HEAD: 87450eb12345"), rendered)
        await t.check("목표 · 제약을 적지 않았으면 중립 문장 ('미확인' 이 아니다)",
                      packet.goal == HandoffPacketBuilder.goalNotSet && packet.constraints == HandoffPacketBuilder.constraintsNotSet)
        await t.check("작성 줄은 설정과 같은 말 (규칙 초안이라 하지 않는다)",
                      rendered.contains("> 작성: 앱이 기록으로 정리 · 사람 검토 전") && !rendered.contains("규칙 초안"), rendered)
        let withMemo = HandoffPacketBuilder.insertUserMemo(rendered, memo: "README 의 설치 절을 고쳐 줘")
        await t.check("다음 행동을 모르면 덧붙인 말을 따르게 (미확인 문장을 남기지 않는다)",
                      packet.nextActions == [HandoffPacketBuilder.unknownNextAction]
                        && withMemo.contains("- \(HandoffPacketBuilder.followMemoNextAction)\n")
                        && !withMemo.contains(HandoffPacketBuilder.unknownNextAction), withMemo)
        let lines: [String?] = [HandoffPacketBuilder.appCommandLine("git push origin main"),
                                HandoffPacketBuilder.appCommandLine("git fetch --prune"),
                                HandoffPacketBuilder.appCommandLine("npm install")]
        await t.equal("앱 명령 줄: push · 조회는 빼고 · 그 밖", lines,
                      ["사용자가 앱에서 원격에 올림(관찰): git push origin main", nil, "사용자가 앱에서 실행함(관찰): npm install"])

        await t.group("인계 문서: 구간의 새 커밋 (실제 git)")
        let repo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-commits-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repo) }
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func runGit(_ arguments: [String]) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = repo
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        runGit(["init", "-q", "-b", "main"])
        runGit(["config", "user.email", "t@example.invalid"])
        runGit(["config", "user.name", "t"])
        try? "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        runGit(["add", "."])
        runGit(["commit", "-q", "-m", "첫 커밋"])
        let environment = ProcessInfo.processInfo.environment
        let first = await GitInspector.snapshot(at: repo, environment: environment)
        try? "b\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        runGit(["add", "."])
        runGit(["commit", "-q", "-m", "둘째 커밋"])
        let second = await GitInspector.snapshot(at: repo, environment: environment, baseHead: first.head)
        await t.check("HEAD 를 읽고, 앞 인계의 HEAD 이후의 커밋만 센다",
                      first.head?.count == 40 && second.commitsSinceBase?.count == 1
                        && second.commitsSinceBase?.first?.hasSuffix(" 둘째 커밋") == true, "\(String(describing: second.commitsSinceBase))")
        let bySince = await GitInspector.snapshot(at: repo, environment: environment, since: Date().addingTimeInterval(-3600))
        await t.equal("앞 인계가 없으면 구간을 시작한 때 이후", bySince.commitsSinceBase?.count, 2)
        let noBase = await GitInspector.snapshot(at: repo, environment: environment)
        await t.check("기준이 없으면 세지 않는다", noBase.commitsSinceBase == nil)
    }

    /// 받는 쪽 · 카드 글의 순수 판정: 쓸 수 없는 받는 쪽의 막힘 순서 · 한도 사실의 경고 · 제안 카드 머리 · 문서 머리 · 원문의 초기화
    /// 시각 · 이름과 조사 · 덧붙인 말이 할 일인 요약 · 게이트 이유의 다음 행동.
    static func receiverAndText(_ t: TestKit) async {
        await t.group("인계 카드: 받는 쪽 · 글 (순수)")
        var facts = HandoffSendFacts()
        facts.receiverUnavailable = "Codex CLI 를 찾지 못했습니다"
        facts.gitOperation = "커밋"
        await t.equal("받는 쪽을 쓸 수 없음은 실행 · git 보다 먼저 (보내면 실패할 것을 먼저 말한다)", HandoffSendBlock.first(facts),
                      .receiverUnavailable("Codex CLI 를 찾지 못했습니다"))
        facts.sameAccount = true
        await t.equal("같은 계정이 받는 쪽 상태보다 먼저", HandoffSendBlock.first(facts), .sameAccount)
        let now = Date()
        let hot = LimitSnapshot(provider: .codex, accountID: "a", status: .ok,
                                windows: [LimitWindow(label: "5시간", utilization: 0.95, resetsAt: now.addingTimeInterval(3600))],
                                fetchedAt: now)
        await t.equal("받는 쪽 사용률이 제안 문턱(75%) 이상이면 ✓ 가 아니라 경고",
                      HandoffCardText.limitFact(provider: .codex, limit: hot, now: now)?.tone, .bad)
        let reset = LimitSnapshot(provider: .codex, accountID: "a", status: .ok,
                                  windows: [LimitWindow(label: "5시간", utilization: 0.95, resetsAt: now.addingTimeInterval(-60)),
                                            LimitWindow(label: "7일", utilization: 0.2, resetsAt: now.addingTimeInterval(86_400))],
                                  fetchedAt: now)
        await t.equal("이미 초기화된 창은 빼고 본다", HandoffCardText.limitFact(provider: .codex, limit: reset, now: now)?.tone, .good)
        let suggestion = HandoffCard.Origin.suggestion(scope: .claude, peak: 0.81, windowLabel: "5시간")
        await t.equal("제안 카드 머리: 받는 쪽과 동사까지 · 접힌 카드는 짧게",
                      [HandoffCardText.headline(origin: suggestion, source: "Claude", target: "Codex", reset: nil),
                       HandoffCardText.headline(origin: suggestion, source: "Claude", target: "Codex", reset: nil, folded: true)],
                      ["Claude 5시간 사용률 81% — Codex 에게 이어 맡깁니다", "Claude 5시간 사용률 81%"])
        await t.equal("문서 머리: 설정과 같은 말 ('규칙 초안' 이 아니다)",
                      HandoffCardText.documentHeader(target: "Codex", gemini: false, tokens: "1.2k"), "Codex 에게 가는 문서 · 앱이 정리 · 약 1.2k 토큰")
        let phrases: [String] = [
            HandoffCardText.resetPhrase(HandoffCardText.unknownReset, rawText: "Claude usage limit reached. Your limit will reset at 8pm."),
            HandoffCardText.resetPhrase(HandoffCardText.unknownReset, rawText: "usage limit reached"),
            HandoffCardText.resetPhrase("20:30 초기화", rawText: "resets at 8pm")]
        await t.equal("초기화 시각: 앱이 모르는데 원문이 시각을 말하면 원문을 가리킨다", phrases,
                      [HandoffCardText.resetInSourceText, HandoffCardText.unknownReset, "20:30 초기화"])
        await t.equal("이름과 조사를 붙여 둔다 (좁은 칸에서 꺾이지 않게)", HandoffCardText.keepingParticle("카운트다운이 끝나면 Codex 에게 넘깁니다"),
                      "카운트다운이 끝나면 Codex\u{00A0}에게 넘깁니다")
        await t.equal("전달 미확인 카드: 머리 · 확인하는 방법 (앱 안에서 할 수 있는 일)",
                      [HandoffCardText.unknownHeadline(target: "Codex"), HandoffCardText.subline(card(phase: .unknown), target: "Codex") ?? ""],
                      ["Codex 에게 전달됐는지 확인하지 못했습니다",
                       "이 대화 위쪽에 Codex 의 응답이 있으면 전달된 것입니다 — 없으면 [닫고 다시 만들기] 로 다시 이어 맡기세요"])
        let unknownNext = packet(nextActions: [HandoffPacketBuilder.unknownNextAction])
        let memoRows = HandoffCardSummary.rows(unknownNext, memo: "테스트를 고쳐 줘")
        await t.check("다음 행동을 모르면 경고 · 덧붙인 말이 있으면 그것이 할 일",
                      HandoffCardSummary.rows(unknownNext).first?.warn == true
                        && memoRows.first?.text == "덧붙인 말을 할 일로 보냅니다" && memoRows.first?.warn == false)
        let kinds: [AutomaticHandoffGate.ReasonKind] = [AutomaticHandoffGate.kind(of: AutomaticHandoffGate.reasonLimitUnknown),
                                                        AutomaticHandoffGate.kind(of: AutomaticHandoffGate.reasonCapped),
                                                        AutomaticHandoffGate.kind(of: AutomaticHandoffGate.reasonUserActed)]
        await t.equal("게이트 이유의 다음 행동 — 받는 쪽 확인 · 한도 도달 · 그 밖", kinds, [.receiverUnchecked, .receiverCapped, .other])
        let uncheckedJudgement = AutomaticHandoffGate.judgement([AutomaticHandoffGate.reasonLimitUnknown, AutomaticHandoffGate.reasonLogin])
        await t.check("판단 기준 한 줄: 확인하지 못한 것뿐이면 넘길 수 있다고 · 한도 도달이면 바꾸기로 · 그 밖은 없음",
                      uncheckedJudgement?.hasPrefix("넘길 수는 있습니다") == true
                        && AutomaticHandoffGate.judgement([AutomaticHandoffGate.reasonCapped])?.contains("바꾸기") == true
                        && AutomaticHandoffGate.judgement([AutomaticHandoffGate.reasonActiveRun]) == nil)
        await t.check("받는 쪽 이름은 '대상' 이 아니라 '받는 쪽'",
                      AutomaticHandoffGate.targetProblems(cliUsable: false, authenticated: false, limit: LimitSnapshot(provider: .codex))
                        .allSatisfy { $0.hasPrefix("받는 쪽") })
        await t.check("넘기면 받는 쪽이 곧바로 시작한다는 줄 (승인 방식과 함께)",
                      HandoffCardText.startsImmediately(policy: "폴더 안은 자동").contains("바로 시작"))
        await t.equal("넘긴 뒤 받는 쪽이 일하는 동안의 입력창 · 대기열 글",
                      [HandoffCardText.composerDeliveringNote, HandoffCardText.deliveringComposerPlaceholder(target: "Codex"),
                       HandoffCardText.deliveringQueueHeader(target: "Codex")],
                      ["인계받아 일하는 중", "Codex 에게 넘긴 인계가 끝나면 이어서 보냅니다…", "Codex 에게 넘긴 인계가 끝나면 보냅니다"])
    }

    // MARK: 흐름 — 받는 쪽 · 보류 메시지 · 키보드 · 미확인 · 자동 인계 대상

    /// 받는 쪽을 쓸 수 없다고 확인된 카드(로그인 안 됨 · CLI 없음)는 [넘기기] 를 막고 그 까닭을 카드에 적는다 — 보내면 실패한다.
    /// [받는 쪽 다시 확인] 이 사실을 새로 읽어 풀어 준다. 받는 CLI 를 띄울 수 없으면 "인계 전송" 기록 전에 멈춘다 (전송 줄이 남지 않는다).
    static func receiverUnavailable(_ t: TestKit) async throws {
        let env = try await makeEnv("receiver")
        defer { env.cleanup() }
        let id = env.threads[0].id
        let home = env.root.appendingPathComponent("codex-b")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try await env.store.upsertCodexAccount(CodexAccount(id: "acct-b", label: "둘째", homePath: home.path, sortOrder: 1))
        await env.model.accounts.load()
        await env.model.prepareHandoff(to: .codex, toAccountID: "acct-b", threadID: id)
        guard env.model.handoffCards[id] != nil else { return await t.check("카드", false, env.model.banner?.text ?? "") }
        let loginHelp = ContinueChoice.handoffBlock(.notLoggedIn, provider: .codex)?.help ?? ""
        await t.check("로그인 안 됨이 확인된 받는 쪽: 넘기기를 막는다 (그 까닭은 칩 메뉴와 같은 말)",
                      env.model.handoffCards[id]?.receiver.authenticated == false
                        && env.model.handoffSendBlock(threadID: id) == .receiverUnavailable(loginHelp),
                      "\(String(describing: env.model.handoffSendBlock(threadID: id)))")
        env.model.setHandoffConfirmed(true, threadID: id)
        let blockedSend = await env.model.sendHandoff(threadID: id)
        let sentWhileBlocked = await env.sentCount(id)
        await t.check("막힌 카드는 보내지 않는다 (받는 쪽 실행 · 전송 줄 없음)",
                      env.behavior.requests.isEmpty && sentWhileBlocked == 0 && env.model.handoffCards[id]?.phase == .ready,
                      "sent=\(blockedSend) \(String(describing: env.model.handoffCards[id]?.phase))")
        // 터미널에서 로그인했다 → [받는 쪽 다시 확인] 이 풀어 준다.
        try #"{"tokens":{"access_token":"x"}}"#.write(to: home.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        await env.model.recheckHandoffReceiver(threadID: id)
        await t.check("다시 확인하면 막힘이 풀린다", env.model.handoffCards[id]?.receiver.authenticated == true
                        && env.model.handoffSendBlock(threadID: id) == nil, "\(String(describing: env.model.handoffSendBlock(threadID: id)))")
        // 주입한 어댑터가 없으면(실제 CLI 길) CLI 를 실행할 수 없다고 확인된 받는 쪽도 막는다.
        env.model.handoffCards[id]?.receiver.cliUsable = false
        let factory = env.model.runner.adapterFactory
        env.model.runner.adapterFactory = nil
        let installHelp = ContinueChoice.handoffBlock(.notInstalled, provider: .codex)?.help ?? ""
        await t.check("CLI 를 실행할 수 없는 받는 쪽은 막는다 ('설치 안 됨')",
                      env.model.handoffSendBlock(threadID: id) == .receiverUnavailable(installHelp))
        env.model.runner.adapterFactory = factory
        env.model.cancelHandoff(threadID: id, origin: .card)

        await t.group("인계 전송: 받는 CLI 를 띄울 수 없으면 '인계 전송' 기록 전에 멈춘다")
        let coordinator = RunCoordinator(store: env.store, environment: CLIEnvironment())   // 오프라인 하네스 — 실제 CLI 를 찾지 않는다
        guard let thread = env.current(id) else { return await t.check("대화", false) }
        let handoff = Handoff(threadID: id, fromProvider: .claude, toProvider: .codex, baseSeq: 0, draftJSON: "{}", finalText: "인계 문서")
        var threw = false
        do { _ = try await coordinator.deliver(handoff: handoff, thread: thread, project: env.project) } catch { threw = true }
        let row = await env.row(id, handoff.id)
        let sentAfter = await env.sentCount(id)
        await t.check("거절 · 전송 줄 없음 · 행은 다시 보낼 수 있는 실패", threw && sentAfter == 0 && row?.deliveryState == .failed,
                      "\(threw) \(String(describing: row?.deliveryState))")
    }

    /// 다음 행동을 앱이 찾지 못한 카드: 입력창에 걸어 둔 메시지를 덧붙일 말로 옮겨 인계와 함께 한 번에 보낸다 (hnd-6).
    /// 키보드: ⌘↵ 한 번 = 확인, 한 번 더 = 넘기기 (hnd-18). ⇧⌘H(origin 수동)로 연 카드는 덧붙일 말 칸에 포커스를 달라고 한다.
    static func heldMemoAndKeyboard(_ t: TestKit) async throws {
        let env = try await makeEnv("held")
        defer { env.cleanup() }
        let id = env.threads[0].id
        // 마지막이 에이전트의 답 — 앱이 다음 행동을 찾지 못한다.
        _ = try await env.store.appendEvent(ThreadEvent(threadID: id, kind: .agentMessage, provider: .claude, text: "워커 테스트도 붙였습니다."))
        await env.model.reloadThreadData(threadID: id)
        await env.model.prepareHandoff(to: .codex, threadID: id)
        guard let card = env.model.handoffCards[id] else { return await t.check("카드", false, env.model.banner?.text ?? "") }
        await t.check("다음 행동을 앱이 찾지 못한 카드 · ⇧⌘H 는 덧붙일 말 칸에 포커스를 달라고 한다",
                      HandoffCardSummary.nextActionUnknown(card.draft.packet) && card.memoFocusPending,
                      "\(card.draft.packet.nextActions)")
        env.model.consumeHandoffMemoFocus(threadID: id)
        env.model.enqueueMessage("README 의 설치 절도 고쳐 줘", images: [], threadID: id)
        await t.equal("걸어 둔 메시지 중 옮길 수 있는 것", env.model.heldMessagesForMemo(threadID: id).map(\.text), ["README 의 설치 절도 고쳐 줘"])
        env.model.moveHeldMessagesToMemo(threadID: id)
        await t.check("덧붙일 말로 옮기면 대기열에서 빠진다",
                      env.model.handoffCards[id]?.userMemo == "README 의 설치 절도 고쳐 줘" && env.model.queuedMessages(threadID: id).isEmpty)
        let first = await env.model.handoffReturnKey(threadID: id)
        await t.check("⌘↵ 첫 번째 = 확인 (넘기지 않는다)", first == .confirmed && env.model.handoffCards[id]?.confirmed == true
                        && env.behavior.requests.isEmpty)
        let second = await env.model.handoffReturnKey(threadID: id)
        await env.settle { env.model.deliveringHandoffs[id] == nil && env.model.handoffCards[id] == nil && !env.model.runner.isBusy(threadID: id) }
        let prompt = env.behavior.requests.first?.prompt ?? ""
        await t.check("⌘↵ 두 번째 = 넘기기 · 할 일은 덧붙인 말 하나로 (따로 한 턴을 쓰지 않는다)",
                      second == .sent && env.behavior.requests.count == 1
                        && prompt.contains("## 사용자가 덧붙인 말 (사용자가 직접 씀)\nREADME 의 설치 절도 고쳐 줘")
                        && prompt.contains("- \(HandoffPacketBuilder.followMemoNextAction)")
                        && !prompt.contains(HandoffPacketBuilder.unknownNextAction), prompt)
    }

    /// 전달 여부 미확인 카드: [닫고 다시 만들기] 는 카드를 닫고 같은 받는 쪽으로 새 카드를 만든다 (넘기는 것은 다시 사람의 확인으로).
    /// 검토 카드의 [받는 쪽 다시 확인] 은 받는 쪽에 관한 이유만 지금 사실로 다시 적는다.
    static func unknownAndRecheck(_ t: TestKit) async throws {
        let env = try await makeEnv("unknown-remake")
        defer { env.cleanup() }
        let id = env.threads[0].id
        await env.model.prepareHandoff(to: .codex, threadID: id)
        guard let card = env.model.handoffCards[id] else { return await t.check("카드", false, env.model.banner?.text ?? "") }
        env.model.setHandoffMemo("결제 모듈은 건드리지 마세요", threadID: id)
        env.model.handoffCards[id]?.phase = .unknown
        await env.model.remakeUnknownHandoff(threadID: id)
        let fresh = env.model.handoffCards[id]
        await t.check("닫고 다시 만들기: 새 카드 · 넘길 수 있는 단계 · 확인은 다시 · 덧붙인 말은 옮겨 간다",
                      fresh != nil && fresh?.id != card.id && fresh?.phase == .ready && fresh?.confirmed == false
                        && fresh?.userMemo == "결제 모듈은 건드리지 마세요", "\(String(describing: fresh?.phase))")

        env.model.handoffCards[id]?.review = .automaticBlocked([AutomaticHandoffGate.reasonLimitUnknown, AutomaticHandoffGate.reasonUserActed])
        // 한도 서비스가 받는 계정을 알아야 그 계정의 한도를 읽는다 (등록되지 않은 계정은 "정보 없음").
        env.model.limits.setCodexAccounts([CodexAccountRef(id: CodexAccount.defaultID, label: "기본", homePath: env.root.path)])
        await env.model.recheckHandoffReceiver(threadID: id)
        let reasons: [String]
        if case .automaticBlocked(let listed)? = env.model.handoffCards[id]?.review { reasons = listed } else { reasons = [] }
        await t.check("다시 확인: 받는 쪽 한도는 새로 읽어 이유에서 빠지고, 받는 쪽과 무관한 이유는 남는다 (시험 환경엔 받는 CLI 가 없다)",
                      !reasons.contains(AutomaticHandoffGate.reasonLimitUnknown) && reasons.contains(AutomaticHandoffGate.reasonUserActed)
                        && reasons.contains(AutomaticHandoffGate.reasonCLI) && env.model.handoffCards[id]?.receiver.cliUsable == false
                        && env.model.handoffCards[id]?.recheckingReceiver == false, "\(reasons)")
        env.model.cancelHandoff(threadID: id, origin: .card)
    }

    /// 자동 인계: 받을 수 있는 에이전트가 하나도 없고 그 까닭이 CLI 없음이면 카드도 "검토가 필요합니다" 알림도 만들지 않는다 (hnd-1).
    /// 오프라인 하네스는 실제 CLI 를 찾지 않는다 — 모든 대상의 CLI 가 없다.
    static func automaticWithoutReceiver(_ t: TestKit) async throws {
        let env = try await makeEnv("auto-none")
        defer { env.cleanup() }
        let id = env.threads[0].id
        let run = Run(threadID: id, sessionID: "s", provider: .claude, requestText: "일", state: .rateLimited,
                      startedAt: Date(), endedAt: Date(), terminalReason: "rate_limited")
        env.model.banner = nil
        await env.model.startAutomaticHandoff(after: run)
        await t.check("카드 · 보류 없음 · 안내는 오류가 아니다",
                      env.model.handoffCards[id] == nil && env.model.queueHolds[id] == nil && env.model.banner?.isError == false
                        && env.model.banner?.text.contains("이어 맡길 에이전트가 없습니다") == true, env.model.banner?.text ?? "배너 없음")
    }

    /// 설정의 이어 받을 순서에서 "받지 않음" 으로 둔 대상은 자동 인계 · 이어 가기 제안 · 한도 줄이 고르지 않는다 (set-15).
    static func excludedTargets(_ t: TestKit) async throws {
        let env = try await makeEnv("excluded")
        defer { env.cleanup() }
        let all = env.model.automaticHandoffTargetOrder.map(\.key)
        env.model.setAutomaticHandoffTarget("claude", receives: false)
        await t.check("받지 않음: 설정 목록에는 남고 고르는 목록에서는 빠진다",
                      env.model.automaticHandoffTargetOrder.map(\.key) == all && !env.model.automaticHandoffTargets.map(\.key).contains("claude")
                        && !env.model.continueTargets().map(\.agent.key).contains("claude"))
        let source = HandoffSource.Agent(provider: .codex, codexAccountID: CodexAccount.defaultID)
        let limitLine = env.model.limitHandoffTarget(after: source, thread: env.current(env.threads[0].id))
        await t.check("한도 줄도 받지 않음으로 둔 반대편을 권하지 않는다", limitLine.agent?.provider != .claude, "\(limitLine)")
        // hand-4 · set-n4: 그때 한도 줄은 "설치하거나 로그인하면 …" 이 아니라 설정에서 뺀 사실을 말한다.
        await t.check("한도 줄의 받는 쪽이 없는 까닭은 '받지 않음' 으로 뺀 Claude (설치 · 로그인이 아니다)",
                      limitLine.agent == nil && limitLine.empty == .excluded(["Claude"]), "\(limitLine)")
        // 자동 인계도 'CLI 를 찾지 못했다' 가 아니라 설정 > 인계로.
        let id = env.threads[0].id
        env.model.cliStatus[.claude] = CLIStatus(provider: .claude, resolvedPath: "/fake/claude", executable: true)
        let run = Run(threadID: id, sessionID: "s", provider: .codex, requestText: "일", state: .rateLimited,
                      startedAt: Date(), endedAt: Date(), terminalReason: "rate_limited", codexAccountID: CodexAccount.defaultID)
        env.model.banner = nil
        await env.model.startAutomaticHandoff(after: run)
        let banner = env.model.banner
        await t.check("자동 인계: 뺀 에이전트만 남았으면 그 사실과 [인계 설정 열기] — 카드는 만들지 않는다",
                      env.model.handoffCards[id] == nil && banner?.opens == .handoffSettings && banner?.actionTitle == "인계 설정 열기"
                        && (banner?.text.contains("Claude 에게는") ?? false) && !(banner?.text.contains("CLI") ?? true),
                      banner?.text ?? "배너 없음")
        env.model.cliStatus[.claude] = nil
        env.model.setAutomaticHandoffTarget("claude", receives: true)
        await t.check("다시 켜면 고른다", env.model.automaticHandoffTargets.map(\.key).contains("claude"))
    }
}
